# Palmares — On-chain security audit (01)

> **Reconciled 2026-10-23 against `main` @ `2bf5bde`.** Every finding below has been re-judged; the per-finding verdicts, with current `path:line`, are in [`07-reconciliation-2026-10-23.md`](07-reconciliation-2026-10-23.md). Line references in this file are as of `4eb9117` and several have moved.

| | |
|---|---|
| Repository | `github.com/mariusgeorgescu/palmares`, branch `main`, HEAD `4eb9117` (2026-10-22) |
| Scope | `src/lib/onchain-lib/` — `Protocol/Types.hs`, `Protocol/Lookup.hs`, `Protocol/Id.hs`, `CIP68.hs`, `Utils.hs`, `Blueprint.hs`, and the six scripts under `Validators/` |
| Method | Static reading only (no toolchain on the audit machine; nothing was built, run or tested). Off-chain code and tests were read only to learn how transactions are built and which rules are covered. |
| Pinned platform | Plutus V3, `plutus-ledger-api`/`plutus-tx` 1.43.1.0 (`cabal.project.freeze`), Atlas 0.14.1 |
| Caveat | Library semantics (`mintValueMinted`, `geq`, `Eq Value`, `!!`) were confirmed against `IntersectMBO/plutus` `master`; the 1.43.1.0 tag is not fetchable from CHaP, so "verified" below means "verified on master, consistent with the code's own claims". |

Paths below are relative to the repository root; `MP` = `src/lib/onchain-lib/Palmares/Onchain/Validators/MintingPolicy.hs`, `PV` = `…/ProfilesValidator.hs`, `AV` = `…/AttestationsValidator.hs`, `DV` = `…/DisputesValidator.hs`, `OV` = `…/OracleValidator.hs`, `NP` = `…/OracleNFTPolicy.hs`, `U` = `src/lib/onchain-lib/Palmares/Onchain/Utils.hs`, `T` = `…/Protocol/Types.hs`, `L` = `…/Protocol/Lookup.hs`, `C` = `…/CIP68.hs`, `B` = `…/Blueprint.hs`.

## 1. Executive summary

The on-chain layer is small, deliberately conservative, and in better shape than most pre-deployment Plutus code: every mint constrains the whole minted value including burns, every state transition's output datum is computed on chain and compared whole, every spend authenticates its own input by the NFT its datum names, the oracle is authenticated by a token recorded in the datum (not by address), the validity window is width-bounded, and the control proof for claims uses only the payment credential. The repository also carries an unusual amount of self-review in comments; almost all of the claims I checked are true of the code as it stands (the exceptions are listed in OC-11).

No Critical finding. Nothing I found lets a third party forge, hide or delete a record. The important findings are design decisions that must be taken **before the first deployment**, because the datum formats and the minting-policy parameter are frozen by it:

1. **OC-01 (High)** — the oracle admin is a single `PubKeyHash`; key loss freezes the protocol and locks every open dispute deposit forever, key compromise gives an attacker pause/fees/verdicts. A `Credential` admin (native multisig) costs one type change and three call sites on chain.
2. **OC-02 (Medium)** — `AcceptAttestation` has no pause gate and cannot have one with the current `OnchainAttestation`; the comments that say "a pause stops writes" overclaim.
3. **OC-03 (Medium)** — `Mp6` closed the "authority token locked inside the state UTxO" hole on the mint path only; `P5`, `Mk`, `A1`, `Md5` still permit it (`geq`), and on `P5` it turns a profile into a permanently world-writable identity that anyone can issue attestations as.
4. **OC-04 (Medium)** — `profileCredential :: Maybe Credential` drops the CIP-129 role; the read layer renders every claim as `drep1…`, so a committee cold credential is published as a DRep id.
5. **OC-05 (Medium)** — profile, attestation and dispute ids share one CIP-67 label, so the validators cannot type an id: subjects need not exist, self-attestation is accepted by the same token that issued it, lineage attestations can never be accepted, and a dispute may target a profile.

## 2. Model of each script

### 2.1 Minting policy (`MP`) — parameterised by `ProtocolParams` (`T:24-38`)
Reads the oracle as a reference input for every redeemer (`MP:160`, `L:66-78`, code `K1`), then `M0` pause gate (`MP:174`) and `checkFee` (`L:111-131`, `K2`). Purpose other than minting → `M1`.

| Redeemer (`MP:103-133`) | Checks (code → rule) | Never checked |
|---|---|---|
| `NewAttestation seed meta other subject issuer kind date period idx` | `Mq` date ∈ width-bounded validity range (`MP:243`, `U:243-248`); `Mm` 222 field sizes; `Mn` other-metadata count/size/dup/reserved (`C:153-190`); `Mf` issuer's **user** token in `valueSpent` (`MP:246`); `Mg` subject and issuer are protocol **ref**-prefixed tokens (`MP:247`, `C:217-219`); `Mh` seed spent; `Mj` whole mint == 1 attestation ref NFT, no burns (`MP:249-251`); `Mk` output `idx` at Attestations address, inline datum == computed CIP-68 datum, value ≥ NFT+minLv (`MP:252`) | subject exists; subject ≠ issuer; subject is a *profile*; period sanity; issuer's user token not re-locked into the output |
| `MintProfile seed kind cred meta idx` | `Mp1` seed; `Mp2` whole mint == ref+user NFT, no burns; `Mp3` `checkCredentialControl` for `Just cred` (`MP:289,320-321`, `U:310-318`); `Mp4` sizes; `Mp5` output at Profiles address with computed datum (`otherMetadata = []`), value ≥ ref+minLv; `Mp6` user token not in that output (`MP:315`) | credential uniqueness; kind/credential consistency; where the user token goes |
| `OpenDispute seed target openedBy depositTo meta openedAt idx` | `Md1` seed; `Md2` whole mint == dispute ref NFT; `Md3` opener's user token spent; `Md4` target and opener ref-prefixed protocol tokens; `Md8` some input's address == `depositTo` (`MP:406`); `Md5` output at Disputes address, computed datum (deposit amount and oracle token recorded), value ≥ NFT+minLv+deposit; `Md6` `openedAt` in range; `Md7` sizes | target is an attestation / exists; `depositTo` payment-credential kind; opener's user token not re-locked |

### 2.2 Profiles validator (`PV`) — unparameterised, datum `CIP68Datum OnchainProfile`
`Cleanup` (`PV:82-91`): absent/unparseable datum → anyone may spend; parseable → `P7` unless `isUnbackedDatum` (`U:404-408`). `UpdateProfile fields idx` (`PV:113-130`, `PV:139-157`): oracle read through `oracleToken (protocolParams profile)` (`PV:111`); `P6` not paused; `P2` own value holds the ref NFT; `P3` user token in `valueSpent`; `P4` sizes; `P5` output `idx` at own address with `updateCIP68DatumMetadata` datum (name immutable, `C:259-265`), value ≥ own value. Never checked: user token not re-locked into the output; the three validator hashes in `protocolParams` are never read by any validator.

### 2.3 Attestations validator (`AV`) — unparameterised, datum `CIP68Datum OnchainAttestation`
`Cleanup` as above (`A4`, `AV:91-96`). `AcceptAttestation idx` (`AV:97-145`): `A3` not already accepted; `A1` output `idx` at own address, datum == own datum with `attestationIsAccepted = True`, value ≥ own value; `A5` subject's user token in `valueSpent`; `A6` own value holds the attestation NFT. **Reads no reference input at all** — no oracle, no pause (`AV:80-146`).

### 2.4 Disputes validator (`DV`) — unparameterised, datum `CIP68Datum OnchainDispute`
`Cleanup` (`D8`, `DV:95-103`). `ResolveDispute verdict idx` (`DV:104-184`): oracle read through `disputeOracleToken` (`DV:123`); `D7` not paused; `D3` no verdict yet; `D1` `opAdminPkh ∈ txInfoSignatories`; `D2` output at own address with `resolveDispute` datum and value ≥ own − recorded deposit, plus own value holds the dispute NFT; `D4` `any` output at `disputeDepositTo` with lovelace ≥ recorded deposit; `D6` exactly one input from own address (`U:165-175`).

### 2.5 Oracle validator (`OV`) — unparameterised, datum `OracleParams`
`OracleUpdate idx action` (`OV:68-112`): `O1` current admin signs; `O2` output at own address with `applyOracleAdminAction action params` datum, value ≥ own; `O5` `OracleSetAdmin` also signed by the incoming key; `O6` `oracleParamsAreWellFormed` on the result (`T:173-176`). No `Cleanup`; no check that the own input carries the oracle NFT; `O0/O3/O4` for malformed datum/purpose/redeemer.

### 2.6 Oracle NFT policy (`NP`) — parameterised by a seed `TxOutRef`
`N0` seed spent; `N2` whole mint == 1 × empty-name token, no burns. Inlined at deployment, not in the blueprint (`B:384-386`).

## 3. The 14-rule checklist (`src/lib/onchain-lib/CLAUDE.md`)

| Rule | Verdict | Where |
|---|---|---|
| 1 Other redeemer | OK — every script pattern-matches its redeemer and purpose; unknown purposes `traceError` (`M1`, `P1`, `A2`, `D5`, `O3`, `N1`) | — |
| 2 Other token name | OK — `mintValueMinted == expected && mintValueBurned == mempty` on all four mint paths (`MP:251,288,403`, `NP:41`) | §5 (h) |
| 3 Arbitrary datum | OK — every spend path decodes the full datum and authenticates it by NFT (`P2`, `A6`, `D2`); oracle only by `fromBuiltinData` (benign, §6) | — |
| 4 Unbounded datum | OK — 222 fields bounded, other-metadata bounded 16×(64+256), profiles/disputes pinned to `[]` on chain | §5 (k) |
| 5 Unbounded value | **Partial** — all state outputs use `geq`; foreign tokens and the holder's own authority token may be locked in | OC-03 |
| 6 Unbounded inputs | OK — cost is the builder's; no shared state is traversed | §5 (p) |
| 7 Double satisfaction | OK — datum-bound output checks + own-NFT checks + `D6` for the `any`-based `D4` | §5 (g) |
| 8 UTxO authentication | OK for oracle/profile/attestation/dispute; oracle validator does not check its own NFT (benign) | §6 |
| 9 Time handling | OK — containment with width bound; both bounds finite; closures honoured | §5 (i) |
| 10 Token security | **Partial** — same as rule 5 | OC-03 |
| 11 UTxO contention | OK for protocol state; the oracle is reference-only for users; the issuer's user-token UTxO serialises an issuer | OC-13 |
| 12 Cheap spam | OK — dust is permissionlessly sweepable with the ADA as bounty; parked foreign-ref-token datums are attacker-paid and permanent (acknowledged `U:388-393`) | OC-07, OC-14 |
| 13 Staking control | OK — whole-address equality on every output check and `Md8`/`D4`/`K2`; `checkCredentialControl` uses the payment half only (`U:93-124`, `U:310-318`) | — |
| 14 Locked value | Documented (`U:114-119`); dispute deposits depend on admin liveness | OC-06 |

## 4. Findings

### OC-01 — Single-key oracle admin is a protocol-wide single point of failure
**Severity: High · Effort: S (on-chain) / M (off-chain tooling)**

*Location.* `T:75` (`opAdminPkh :: PubKeyHash`), `OV:84` (`O1`), `OV:111` (`O5`), `DV:153` (`D1`), off-chain `Operations.hs:760,795,807` (`mustBeSignedBy`).

*What the code does.* Every admin action and every dispute verdict is authorised by one key hash held in the oracle datum: `traceIfFalse "O1" $ elem (opAdminPkh currentParams) txInfoSignatories` (`OV:84`) and `traceIfFalse "D1" (PlutusTx.List.elem (opAdminPkh oracle) txInfoSignatories)` (`DV:153`). No script or multisig admin is expressible.

*Why it matters.* (1) **Key loss**: `O1` refuses every future update including rotation, so the protocol can never be unpaused, repriced or re-keyed, and `D1` can never be satisfied — every open dispute's deposit (`opDisputeDeposit`, 5 ADA at deployment, `Transactions.hs:224`) is locked forever. The code says as much for a mistyped rotation (`OV:96-102`) and fixed that half with `O5`, but the same outcome follows from a lost or destroyed key. (2) **Key compromise**: the attacker can pause indefinitely (freezing all writes), set `fcFeeAddress` to themselves and any fee amount — the API builds whatever the oracle prices (`Operations.hs:55-61`), so users signing in wallets pay it — raise `opMinUTxOValue` to grief every mint, write arbitrary verdicts that the read layer displays beside true records, and rotate the admin to themselves (`O5` is satisfied by their own signature). For a registry that organisations are meant to trust, one hot key is not an acceptable root of trust.

*Fix.* Change `opAdminPkh :: PubKeyHash` to `opAdmin :: Credential` and replace the three membership tests with `Utils.checkCredentialControl (opAdmin params) txInfoSignatories txInfoInputs` (a key admin is unchanged; a native multisig admin proves control by spending a UTxO at its own address, exactly as claims do). `O5` becomes `checkCredentialControl newAdmin …`. Off-chain: `updateOracleTX`/`resolveDisputeTX` need a witness parameter like `claimProofSkeleton`, and the admin CLI needs multisig assembly. The datum format changes, so this is pre-deployment only.

### OC-02 — Pause semantics are inconsistent: acceptance is not pausable
**Severity: Medium · Effort: S (pre-deployment)**

*Location.* `AV:80-146` (no `txInfoReferenceInputs` use); `T:328-363` (`OnchainAttestation` carries no oracle token); comments `PV:114` and `DV:126` ("A PAUSE STOPS WRITES, NOT READS"); `src/test/UnitTests/Pause.hs:24-33` (documents the gap).

*What the code does.* `M0`, `P6`, `D7` gate minting, profile updates and verdicts on `opPaused`. `AcceptAttestation` flips `attestationIsAccepted` — the protocol's single irreversible write — without reading the oracle; the datum has no route to it.

*Why it matters.* The pause exists to contain a bug. Scenario: a flaw in the mint path lets an attacker mint a *pending* attestation whose `attestationIssuer` is a reputable profile (any future `Mf` regression). The admin pauses. Subjects, who have no way to tell the forged pending record from a real one, keep accepting, and each acceptance is permanent. The lever halts the cheap step and leaves the irreversible one running — the exact objection the comments raise for `D7`. The off-chain refusal (`Operations.hs:495-497`) is a courtesy a hand-built transaction skips.

*Fix.* Add `attestationOracleToken :: AssetClass` to `OnchainAttestation` (as `disputeOracleToken` does, `T:430`), set it from `oracleToken protocolParams` in `handleNewAttestation`, and in `AcceptAttestation` add `traceIfFalse "A7" (not (opPaused (readOracleParams (attestationOracleToken attestation) txInfoReferenceInputs)))`. Cost: ~33 datum bytes (~0.14 ADA min-ADA per attestation), one reference input per acceptance (the honest builder already attaches it, `Operations.hs:544`), ~100 script bytes. If the owner prefers acceptance to stay un-pausable, delete the "stops writes" claims and state the exception in the blueprint.

### OC-03 — Authority tokens can be locked inside state outputs; on `P5` this makes a profile world-writable
**Severity: Medium · Effort: S**

*Location.* `U:130-133` (`geq`), `PV:156` (`P5`), `MP:252` (`Mk`), `AV:131-139` (`A1`), `MP:407` (`Md5`); the hole and its mint-path fix are described at `MP:292-315` (`Mp6`).

*What the code does.* All four continuing/new state checks require `txOutValue geq minValue` and nothing else about the value. `Mp6` refuses the profile user token at the mint output only. `P3` and `Mf` test `assetClassValueOf (valueSpent txInfo) userAC == 1`, and `valueSpent` sums **all** inputs including the script input.

*Why it matters.* A profile holder (or a malicious front-end building a transaction the holder signs) performs one `UpdateProfile` whose output `idx` carries ref NFT + user NFT; `P5` accepts (`geq`), the datum is byte-identical. From then on, anyone can spend the profile UTxO with `UpdateProfile`: `P3` is satisfied by the profile's own input, `P5` re-locks ≥ own value so the user token never leaves. Worse, the same transaction can mint `NewAttestation` with `issuer = thatProfile`: `Mf` is satisfied by the same input, so **anyone can issue attestations as that profile forever** — the "permanently world-writable identity" the `Mp6` comment describes, reopened through the update path. On `Mk`/`A1`/`Md5` the consequence is milder but irreversible: the issuer's, subject's or opener's user token is locked into a record that nothing ever burns, destroying that identity's authority. Only the token holder can trigger it (self-harm or phishing); a third party never holds the token.

*Fix.* One conjunct each, mirroring `Mp6`: in `handleUpdateProfile` `traceIfFalse "P8" (assetClassValueOf (Utils.valueAtOutputIdx profileOutputIdx txInfoOutputs) profileUserAssetClass == 0)`; in `handleNewAttestation` the issuer's user token `== 0` at `attestationOutputIdx`; in `AcceptAttestation` the subject's user token `== 0` at `outputIdx`; in `handleOpenDispute` the opener's user token `== 0` at `disputeOutputIdx`. ~30-55 bytes each (the `Mp6` increment was 55, `UnitTests/ScriptSize.hs:156`).

### OC-04 — The claimed credential loses its CIP-129 role
**Severity: Medium · Effort: S/M (pre-deployment)**

*Location.* `T:265-276` (`profileCredential :: Maybe Credential`), `MP:115` (redeemer), `U:310-318`; read layer `src/lib/offchain-lib/Palmares/TxBuilding/Conversions.hs:113-121`, `DomainTypes/Core/Ids.hs:14-21`.

*What the code does.* CIP-129 encodes a header byte `(keyType << 4) | kind`: DRep `0x22/0x23`, CC cold `0x12/0x13`, CC hot `0x02/0x03`. `parseClaimCredential` keeps only key-vs-script (`Conversions.hs:107-111`); the datum stores a bare `Credential`; `claimCredentialToText` renders **every** claim with `drepIdCip129` (`Conversions.hs:119-121`), with the comment "which governance role those bytes play is the profile's kind".

*Why it matters.* A `Committee` profile that claims `cc_cold1…` is published as `drep1…` of the same bytes — an identifier that resolves to nothing in GovTool or db-sync, so a reader cannot verify the claim they are shown. `profileKind` is not a role (an `Organization` may be a DRep; a `Committee` may claim hot or cold), and nothing on chain ties the two. The proof rule itself is fine; the record is lossy.

*Fix.* Store the role on chain, e.g. `data ClaimedCredential = ClaimedDRep Credential | ClaimedCCCold Credential | ClaimedCCHot Credential` (indices 0-2, `makeIsDataSchemaIndexed`), with `checkCredentialControl` applied to the inner credential; render with the matching `*IdCip129`. One byte per datum. Decide at the same time whether `cc_hot` (rotatable) and stake credentials (not CIP-129, not accepted by `parseCredentialCip129` although `T:269-270` says they are covered) are claimable at all.

### OC-05 — Ids are untyped: subjects need not exist, self-attestation passes, lineage can never be accepted, disputes may target anything
**Severity: Medium · Effort: M (pre-deployment if labels change)**

*Location.* `C:209-219` (`isRefTokenName`/`isProtocolRefToken`), `MP:247` (`Mg`), `MP:405` (`Md4`), `AV:14-33` (lineage limit), `Lookups.hs:182-184` (existence only off chain).

*What the code does.* Every id is `CIP-67 label 100 ‖ blake2b_224(seed)` under one policy, so `Mg`/`Md4` can only check "ref-prefixed token of this policy". `Mf`/`A5` derive the user token by replacing the prefix.

*Why it matters.* (a) `subject` may be an id that was never minted or is an attestation/dispute id: the record is minted, can never be accepted (`A5` needs a user token that `handleNewAttestation` never mints) and can never be removed — the off-chain `ensureSubjectProfileExists` is bypassable. (b) `subject == issuer` is accepted by the same token that issued it (`Mf` and `A5` both read `valueSpent`): an `AuditPassed` or `Endorsement` by X about X lands as an *accepted* record unless the read layer flags it. (c) A dispute may `target` a profile, another dispute or a never-minted name; the projection column `targetAttestationId` then points at a non-attestation. None of this forges a record; all of it is permanent clutter or misleading presentation that a 4-byte check could prevent.

*Fix.* Give each kind its own CIP-67 label (keep 100/222 for profiles; e.g. a dedicated label for attestation refs and one for dispute refs — neither has a user token, so CIP-68 wallet pairing is irrelevant). Then `Mg` requires issuer ∈ profile-label and subject ∈ profile-label ∪ attestation-label, `Md4` requires target ∈ attestation-label and opener ∈ profile-label, and `isUnbackedDatum` can check the kind-specific label. Add `traceIfFalse "Mr" (subject /= issuer)` unless self-attestation is wanted. If lineage is kept, decide who consents (the inner subject via a reference input) or drop the feature; today it is a record that is pending forever and presented as "pending" to a subject that cannot act.

### OC-06 — Dispute deposits depend on admin liveness; two `depositTo` shapes lose the deposit
**Severity: Medium · Effort: S–M**

*Location.* `DV:104-184`, `MP:406` (`Md8`), `DV:124-125,183` (`D4`), off-chain `Operations.hs:752` and `Skeletons.hs:64-73` (payout with `gyTxOutDatum = Nothing`).

*What the code does.* The only exit for a dispute UTxO is `ResolveDispute`, which needs the admin's signature (`D1`). `D4` checks address and lovelace of the payout, not its datum. `Md8` only requires that the opening transaction spends *some* input at `depositTo`.

*Why it matters.* (1) If the admin is unavailable (OC-01) or simply declines, N disputes lock N deposits with no timeout, cancel or refund path. (2) `depositTo` = a Plutus script address: `Md8` is satisfiable (the org spends a datum-carrying UTxO there), but the resolution pays a datum-less output to it, which is unspendable forever — an organisation acting through a Plutus script loses every deposit. (3) `depositTo` = one of the protocol validator addresses, reachable by sweeping dust there with `Cleanup` in the same transaction: the payout becomes a datum-less UTxO at that validator, i.e. dust anyone may sweep. (4) `D4` can also be discharged by the dispute's own continuing output when `depositTo == ownAddress` and the resolver leaves ≥ deposit in it (the honest builder does not), locking the deposit in the resolved record. (2)–(4) are chosen by the disputer, so self-harm; (1) is structural.

*Fix.* Add a `WithdrawDispute` arm: after `disputeOpenedAt + opDisputeTimeout` (new oracle field) and while `disputeVerdict == Nothing`, the opener (proven by the opener's user token) may take the deposit, with the dispute re-locked as `VerdictWithdrawn`/closed; or document that deposits are at the admin's mercy. For (2)/(3): require `depositTo`'s payment credential to be a `PubKeyCredential`, or let the opener record an optional inline datum for the payout; at minimum refuse the protocol's own addresses by comparing against the datum's known script hashes.

### OC-07 — Permissionless `Cleanup` hands a mis-sent user token to the first sweeper
**Severity: Low · Effort: S**

*Location.* `PV:82-85`, `AV:91-94`, `DV:95-98` (absent/unparseable datum → unconditional `True`), `U:404-408`, acknowledgement at `U:361-367`.

*What the code does.* A UTxO at a state address with no datum, an unparseable datum, or a datum naming a non-ref-prefixed token may be spent by anyone with no constraint on where its value goes.

*Why it matters.* A holder who sends their profile's user token (the authority for `P3`, `Mf`, `A5`, `Md3`) to a validator address by mistake loses it to whoever sweeps first — typically a bot. The sweeper then updates the profile, issues attestations as it and accepts attestations about it: a hijacked identity in a registry whose promise is that records are not forged. The code chose "sweepable" over "stuck forever"; for an identity token the stuck outcome is the safer one, since the holder can mint a fresh profile and the old one cannot be impersonated.

*Fix.* In the two permissive arms, require that the swept UTxO's value holds no token whose name starts with `userTokenPrefixBS` (policy-independent, like `isRefTokenName`), e.g. `traceIfFalse "P9" (not (anyUserToken ownValue))`. Document "never send a user token to a protocol address".

### OC-08 — Every profile datum carries `ProtocolParams`, of which only the oracle token is used
**Severity: Low · Effort: S (pre-deployment)**

*Location.* `T:277` (`protocolParams :: ProtocolParams`), `PV:111` (only `oracleToken (protocolParams profile)` is read), `MP:282`; claims at `src/lib/onchain-lib/CLAUDE.md` ("they get validator addresses from the datum's `protocolParams`") and `B:200-201`.

*Why it matters.* No validator reads the three script hashes from any datum; the Profiles validator never needs a sibling address. The field costs ≈127 datum bytes ≈ 0.55 ADA of min-ADA per profile, locked for the life of the record, of which ≈94 bytes (≈0.4 ADA) buy nothing. The published blueprint describes a mechanism that does not exist.

*Fix.* Replace with `profileOracleToken :: AssetClass` (the shape `OnchainDispute` already uses), update `handleMintProfile`, `profilesLambda`, the blueprint prose and the CLAUDE.md bullet. Alternatively keep it and fix the prose.

### OC-09 — No version field and no migration path; a validator fix is a new registry
**Severity: Low · Effort: M (decision) / L (migration design)**

*Location.* `T:24-38`, `MP:424-425` (`unsafeApplyCode … params`), `B:7-15,148-153` ("the three script hashes are the same in every deployment"), `Storage.hs:98-103` (policy change at startup "optionally wipe").

*Why it matters.* The minting policy hash is a function of all three validator hashes plus the oracle token. Fixing any validator changes its hash → new `ProtocolParams` → new policy → new currency symbol: every existing profile, user token, attestation and dispute belongs to a dead policy, `Mg`/`Mf` refuse old ids and tokens under the new policy, and the chain-sync detects the policy change and may wipe its projections. The blueprint's "same in every deployment" holds only until the first fix. Nothing in the datums says which deployment they belong to.

*Fix (decide before deployment).* Either (a) state the stance: "redeploy = new registry; the read layer unions deployments by policy id and old records remain readable", and make `attest-sync` index a list of policies rather than one; or (b) design migration now: a `protocolVersion :: Integer` in `ProtocolParams` (free, it is a compile-time parameter) and a `MigrateProfile` redeemer in the *next* policy that accepts an old-policy user token (previous policy id as a second parameter) and re-mints the same names. (b) is the only way a user keeps their identity across a fix.

### OC-10 — Claim semantics: consent to a transaction is not consent to the token's destination; claims are not unique
**Severity: Low (accepted risk, document) · Effort: S**

*Location.* `MP:308-314` (acknowledged), `U:310-318`, `Storage.hs:123-127` (duplicates presented as `contested`).

*What the code does.* `Mp3` proves that the claimed credential signed (key) or spent (script) in *this* transaction; `Mp2` lets the user token go anywhere. Nothing prevents two profiles from claiming the same credential.

*Why it matters.* A phishing dApp asks a DRep to sign a transaction that mints a profile claiming the DRep's credential and sends the user token to the attacker; CIP-95 wallets will witness with the DRep key when it is a required signer. The attacker now controls a "verified" profile with the victim's id. Binding the user token to an address whose payment credential is the claimed key would break ordinary wallets (DRep keys are not payment keys), so there is no cheap on-chain close. Duplicate claims are the victim's remedy: re-claiming with a fresh profile is always possible for the real holder.

*Fix.* Document the risk; in the read layer rank claims by chain order ("latest claim by the credential is current, earlier ones contested") and link every claim to its minting transaction. Optionally accept a vote in `txInfoVotes` by the claimed DRep/CC credential as an alternative proof of control — it is ledger-authenticated, works for script DReps with no UTxO (the documented limitation, `U:298-302`), and makes the claim transaction recognisably governance-shaped.

### OC-11 — Dead on-chain code, stale documentation and comment/code mismatches
**Severity: Info · Effort: S**

| Item | Evidence |
|---|---|
| `Protocol/Id.hs` has zero callers (`deriveSeededId`, `deriveIndexedId` appear only in the barrel `Protocol.hs:6,11`) | `grep -rn deriveSeededId src` → no call sites; yet root `CLAUDE.md` ("New on-chain type → `Protocol/Id.hs`") and `offchain-lib/CLAUDE.md` ("ID derivation (`Id.hs`)") still send readers there, contradicting `onchain-lib/CLAUDE.md` |
| `unsafeGetProfile`, `unsafeGetProfileDatumAndValue`, `unsafeGetProtocolParamsFromProfileRefInput` (`L:26-55`) uncalled; trace code `K3` unreachable | grep |
| `Utils` dead helpers: `checkTxOutAtIndexWithDatumValueAndAddress`, `hasTxInAtAddressWithNFT`, `checkAndGetCurrentStateDatumAndValue` (`U2`), `checkAndGetInlineDatum` (`U3`), `hasCurrencySymbol`; `CIP68` `updateCIP68DatumImage`, `validateImageURI` | grep; `onchain-lib/CLAUDE.md` still prescribes `hasCurrencySymbol`, which the code replaced with `isProtocolRefToken` |
| `onchain-lib/CLAUDE.md` "Address resolution … get validator addresses from the datum's `protocolParams`" and `B:200-201` — false | OC-08 |
| Blueprint prose stale: oracle datum description omits `opDisputeDeposit` (`B:373-375`); minting description names "Profiles and Attestations" hashes only (`B:131-133`); profile datum description omits `profileCredential` (`B:222-223`) | `B` |
| Haddock misattachment: the `isUnbackedDatum` doc block (`U:334-393`) is followed by the `valueAtOutputIdx` doc and definition (`U:394-402`) before `isUnbackedDatum` (`U:404`); the `OnchainProfileKind` doc (`T:196-207`) precedes the `MintAction` doc and `data MintAction` (`T:209-236`), `data OnchainProfileKind` (`T:238`) is undocumented | — |
| `checkDateInRange` comments speak only of back-dating (`U:216-225`); the same bound permits **future**-dating by up to 14.4 h (`[now, now+maxDateWindow]` is ledger-valid) | §5 (i) |
| `T:269-270` says a stake credential is claimable; `parseCredentialCip129` (`Ids.hs:120-129`) accepts only `cc_hot`/`cc_cold`/`drep` | OC-04 |

*Fix.* Delete the dead modules/functions and codes; correct the three CLAUDE.md files and the blueprint strings; move the two doc blocks.

### OC-12 — Deployment-time oracle datum is not validated; oracle address has no sweep
**Severity: Info · Effort: S**

`O6` only runs on updates. `mintOracleNFTAndLockDatum` writes `opMinUTxOValue = 1_000_000`, `opDisputeDeposit = 5_000_000` (`Transactions.hs:217-224`) — fine today, but a future edit to that literal would reopen the `geq`-vacuity drain described at `T:149-172` from block one. Assert `oracleParamsAreWellFormed` (and a decode round-trip) off chain before submitting. Separately, dust sent to the oracle address is unspendable forever (`O0`/`O3`), which is harmless but differs from the three state validators.

### OC-13 — Exact-mint plus one user-token UTxO serialises an issuer's throughput
**Severity: Info · Effort: M if ever needed**

`Mj` means one attestation per transaction; `Mf` means every issuance spends the issuer's single user-token UTxO. A busy organisation issues at most one attestation per transaction, with transactions chained on one UTxO and in-mempool conflicts if built concurrently. Acceptable for the stated volumes; if batching is wanted, `NewAttestation` would carry a list and `Mj` the summed value.

### OC-14 — Pending-attestation spam about a subject is permanent
**Severity: Info · Effort: M (product decision)**

Anyone with a profile may mint unlimited pending attestations about any subject (≈1.3 ADA each, plus fee if priced). Nothing burns, so a subject's "pending" list can be polluted forever. The blueprint promise ("a claim cannot enter the record unilaterally") holds; the presentation cost is the read layer's. A subject-side `Reject` (burn, returning min-ADA) for *pending* records would keep "records are never deleted" intact, since a pending attestation is not yet a record.

### OC-15 — `mkUntypedLambda` validates the entire `ScriptContext` with `fromBuiltinData`
**Severity: Info · Effort: S**

`U:58-66` decodes and validates every field of `TxInfo` (all inputs, outputs, votes, proposals, redeemers) before any check runs. `unsafeFromBuiltinData` on the context is the usual Plinth idiom and cheaper; the saving is ExUnits proportional to transaction size, paid by the builder. Measure before changing (`UnitTests.ScriptSize` pins sizes, not ExUnits).

## 5. Hypotheses a–p

**a. Pause.** Confirmed (OC-02). `attestationsLambda` never touches `txInfoReferenceInputs`; the only routes are a datum field or a profile reference input per acceptance, both protocol changes. Closing it: ~0.14 ADA per attestation, one ref input per accept, pre-deployment.

**b. Single-PKH admin.** Confirmed (OC-01). `Credential` admin with the `checkCredentialControl` rule: on chain, one field type and three call sites; off chain, witness-threading for `updateOracleTX`/`resolveDisputeTX` and multisig assembly in the admin CLI; blueprint regenerated. Pre-deployment only.

**c. Claim uniqueness.** Confirmed: nothing on chain prevents two profiles claiming one credential; `Storage.hs:123-127` deliberately stores both and reports `contested`. On-chain uniqueness would need an index UTxO (contention) or a per-credential slot UTxO; not worth it. Options: read-layer "latest claim wins" ranking; a `RevokeClaim` profile redeemer (`checkCredentialControl` again, writes `profileCredential = Nothing`) so a holder can retire an old profile's claim. See OC-10.

**d. `handleNewAttestation`.** Confirmed on all four points (OC-05). Note the issuer *does* always exist: `Mf` needs a user token, which only `MintProfile` mints.

**e. `handleOpenDispute`.** Confirmed; edge cases analysed in OC-06. `D4` can be satisfied by the dispute's own continuing output only when `depositTo == ownAddress` and ≥ deposit lovelace is left in it. A deposit is permanently locked when the admin never resolves, when `depositTo` is a Plutus script address (datum-less payout), or when it is a protocol address (payout becomes sweepable dust).

**f. Min-value checks.** Confirmed (OC-03). Extra lovelace and foreign tokens are permitted everywhere; the read layer tolerates them (`authenticateStateUTxO` checks the named asset's quantity only). Authority-token lock-in is holder-triggered only, but on `P5` it becomes a third-party forgery channel afterwards.

**g. Double satisfaction.** Refuted as a vulnerability. `P5`/`A1`/`D2`/`O2` compare the whole inline datum, which embeds the unique id (`profileId`, `attestationId`, `disputeId`), so one output cannot satisfy two inputs; two inputs with identical datums cannot both pass their own-NFT checks (`P2`, `A6`, `D2`). `D4`'s `any` is the one obligation not bound to an output and `D6` serialises it (`U:165-175`; tests `MutationGuards` 8.10/8.11, `Satisfaction`). Mint+spend mixing is fine: `Mj` constrains the mint, the spends constrain their outputs. `A5` reuse across several attestation inputs is intended batch acceptance. Benign quirk: `D6` counts dust inputs at the Disputes address, so "resolve + cleanup" in one transaction is refused.

**h. Exact-mint semantics.** Confirmed. `MintValue` is `Map CurrencySymbol (Map TokenName Integer)` for the whole transaction; `mintValueMinted = filterQuantities (\x -> [x | x > 0])`, `mintValueBurned = filterQuantities (\x -> [abs x | x < 0])`; `Eq Value` ignores zero entries. Consequences: no other policy may mint or burn in the same transaction; a profile and an attestation cannot be minted together; one token kind per transaction (OC-13). Tests `DisputeRules` "another policy's token alongside the attestation is refused (Mj)" cover this.

**i. `checkDateInRange`.** Confirmed: both bounds `Finite`, `hi - lo <= 51_840_000` ms = 14.4 h = 2 × `safeEraTime` (25 920 s, `Skeletons.hs:47-48`), `member` honours closures. An issuer can back-date **or future-date** by up to 14.4 h (any interval containing the current slot is ledger-valid; `[now−14.4h, now]` and `[now, now+14.4h]` both pass). Comments mention only back-dating (OC-11). `UnitTests.OracleRules` pins width and closure behaviour.

**j. Credential role.** Confirmed lossy (OC-04). No validator depends on the role; the read layer depends on it and guesses `drep`.

**k. Datum bounds.** Name ≤128, description ≤1024, image ≤256, other-metadata ≤16 × (64+256) B → attestation datum ≤ ~6.9 KB → min-ADA up to ~30 ADA, paid by the issuer; the subject only pays the acceptance fee. Profiles and disputes pin `otherMetadata = []` on chain (`MP:284,399`); `updateCIP68DatumMetadata` only replaces existing keys, so the map cannot grow. Nothing unbounded. `ProtocolParams` ≈ 127 B ≈ 0.55 ADA per profile (OC-08). `validateOtherMetadata` bounds the count before the quadratic scan (`C:153-164`).

**l. `Cleanup`.** Backed state cannot be swept: a state NFT is minted once into an output whose datum the policy computed, nothing burns, and the only redeemers that move it re-lock it with a validator-computed datum, so a genuine NFT always sits under a datum that names it and `isUnbackedDatum` returns `False`. Mis-sent user tokens *are* sweepable by anyone (OC-07). Not pause-gated — correct. Residual: a parked datum naming a ref-prefixed token of the attacker's own policy is unsweepable (acknowledged `U:388-393`), attacker-paid.

**m. Lookups.** `readOracleParams` takes the first reference input holding the NFT; the NFT is unique (`N0`/`N2`, one-shot), so "first" is "the". `unsafeGetProtocolParamsFromProfileRefInput` and both `unsafeGetProfile*` have no callers; `Protocol/Id.hs` has no callers. Delete (OC-11).

**n. Upgradeability.** Confirmed (OC-09).

**o. Hygiene.** Trace codes are unique per script (`M0 M1 Mf Mg Mh Mj Mk Mm Mn Mq Mp1-6 Md1-8`; `P0-P7`; `A0-A6`; `D0-D8`; `O0-O6`; `N0-N2`; `K1-K3`; `U0-U3`); the repeated `A0`/`P0`/`D0`/`K1` are one meaning in several branches. `K3`, `U2`, `U3` live in dead code. Every exported function carries `INLINEABLE`. All data types use `makeIsDataSchemaIndexed` with explicit, append-only indices. The blueprint declares five validators, four datums and five redeemers, and publishes no compiled code or hash for the minting policy (`B:187`), exactly as `TxBuilding/Validators.hs:126-131` says; `OracleNFTPolicy` is omitted and the omission documented (`B:384-386`). Prose drift is listed in OC-11.

**p. Remaining rules.** Unbounded inputs: every traversal is over the builder's own transaction. Oracle contention: users only reference it; an admin update makes in-flight transactions that referenced the old oracle UTxO fail phase-1 (no collateral loss) — transient. Cheap spam: dust sweepable with the ADA as bounty (`Operations.hs:852-870`). Staking: whole-address equality in every output check, `Md8`, `D4` and `K2`; `checkCredentialControl` payment-half only (`U:316-318`), which closes the stake-script-hash claim described at `U:273-285`; `UnitTests.Claim` pins both.

## 6. Reviewed and not an issue

- **Oracle validator does not check its own NFT** (`OV:68-94`): a UTxO at the oracle address with a hand-written `OracleParams` datum is spendable by the key that datum names — it is that person's own ADA; the real oracle is always located by NFT (`L:66-78`) and `O2` keeps the NFT at the address forever.
- **Oracle value ratchet**: `O2` uses `geq`, so the oracle UTxO's value can only grow across updates and foreign tokens may accumulate — admin-inflicted, harmless.
- **Out-of-range output index**: `outputs !! idx` traces on negative and too-large indices (plutus-tx `(!!)`), so a bad redeemer index fails the script rather than reading something (`U:396-399` is accurate).
- **Negative lovelace parameters**: `O6` refuses them on every update; the `geq`-vacuity analysis at `T:149-172` is correct (`geq = checkBinRel (>=)`, missing entries count as 0).
- **Seed-derived names are injective**: `blake2b_224 (txId ‖ index)` with a fixed 32-byte `txId`; the seed must be spent (`Mh`/`Mp1`/`Md1`), so it is a real `TxOutRef`.
- **Inline datums everywhere**: all state outputs are pinned with `isGivenInlineDatum`, so no datum-hash substitution path exists.
- **Reference input == spent input overlap**: not exploitable here, and Conway rejects the overlap anyway.
- **`validateMetadataFields` on `UpdateProfile` validates a `metadataName` that `updateCIP68DatumMetadata` then ignores** — harmless; the name is immutable as the blueprint states.
- **`checkFee` `any` over outputs**: could coincide with a state output only if the admin sets the fee address to a validator address — configuration error, not an attack.
- **`claimedPeriod` unvalidated on chain**: by design and clearly labelled self-reported (`T:337-356`); `issueAttestationTX` refuses inverted periods.
- **Attestation metadata not re-validated on accept**: it was pinned at mint and `A1` compares the whole datum.
- **Resolution leaves NFT + minLv locked per dispute**: consistent with the documented "permanent min-ADA per record" trade-off (`U:114-119`).

## 7. What is done well

- Whole-mint constraint including burns on all four mint paths, with tests that mint a second token, a foreign policy's token, two of the NFT, and a burn (`UnitTests/DisputeRules.hs:573-597,716-733`, `Oracle.hs:319-323`).
- State transitions are computed on chain and compared whole: `applyOracleAdminAction` (`T:140-147`), `resolveDispute` (`T:445-447`), `updateCIP68DatumMetadata`, the accept flip; off-chain uses the same functions, so the two cannot disagree.
- Own-input authentication by the NFT the datum names on every spend (`P2`, `A6`, `D2`) and in `Cleanup` (`isUnbackedDatum`), closing the parked-datum forgery described at `TxBuilding/Utils.hs:58-95`.
- Oracle authenticated through a token recorded by the policy (`protocolParams`, `disputeOracleToken`), never by address; recorded deposit amount, never the live oracle value (`DV:114-119`).
- Explicit multiple-satisfaction guard (`D6`) with a written rationale for why input uniqueness beats output tagging (`U:143-164`), and an exploit-shaped test (8.11).
- Width-bounded validity window with both bounds finite and closures honoured; the hole in "containment only" is documented and tested (`OracleRules` 91-139).
- Payment-credential-only control proof, with the stake-half hole removed and pinned by `UnitTests.Claim`.
- Two-sided admin handover (`O5`) and result-level well-formedness (`O6`).
- CIP-67 prefix as a cheap type check at every site an id is read (`Mg`, `Md4`, `isUnbackedDatum`), with the user-token-as-id attack written down (`C:192-208`).
- Bounded metadata with the count checked before the quadratic scan; traces kept in production builds with unique per-script codes (`palmares.cabal`, plinth options block).
- Tests drive the lambdas directly with hand-built contexts and one-field mutations (`DisputeRules.hs:3-36`) and the emulator with malicious builders (`TestRuns.hs:495-1073`); script sizes are pinned (`ScriptSize.hs`).
- Blueprint deployment-independence is an asserted invariant, and the placeholder-hash mistake was removed rather than papered over (`B:102-124`).

## 8. Open questions for the owner

1. Who is the oracle admin on mainnet — one key, a native multisig, or a DAO? (OC-01 must be answered before the datum format freezes.)
2. Should acceptance be pausable? If not, say so in the blueprint. (OC-02)
3. Are self-attestations a feature or a defect? Is lineage (attestation about an attestation) a feature worth a consent rule, or should it be refused on chain? (OC-05)
4. Should an open dispute ever be withdrawable, and after how long? May an organisation acting through a Plutus script receive a deposit back at all? (OC-06)
5. Mis-sent user tokens: sweepable (today) or locked (safer)? (OC-07)
6. Which roles are claimable — DRep, CC cold, CC hot, stake? Must `profileKind` be consistent with the claimed role (`PersonDRep` with no credential, `Community` with a DRep id)? (OC-04)
7. Upgrade stance: "redeploy = new registry" or a migration path with a version field? Does `attest-sync` need to index several policies? (OC-09)
8. Name squatting: an unclaimed profile named "Intersect" costs 1.5 ADA; what does the read layer show beside unclaimed names?
9. Should subjects be able to reject (burn) pending attestations about them? (OC-14)
10. Fee transparency: the API pays whatever the oracle prices; should the response state the fee and cap it client-side?
11. Is a governance vote in the same transaction an acceptable (or preferable) proof of DRep control? (OC-10)

## 9. Improvement backlog (ranked)

| # | ID | Severity | Effort | Action |
|---|---|---|---|---|
| 1 | OC-01 | High | S/M | `opAdmin :: Credential`; `O1`/`O5`/`D1` via `checkCredentialControl`; multisig admin tooling |
| 2 | OC-03 | Medium | S | Add user-token `== 0` output checks to `P5`, `Mk`, `A1`, `Md5` (mirror `Mp6`) |
| 3 | OC-02 | Medium | S | `attestationOracleToken` in `OnchainAttestation` + `A7` pause gate, or document the exception |
| 4 | OC-04 | Medium | S/M | Role-tagged `ClaimedCredential`; render with the matching CIP-129 HRP; decide hot/stake |
| 5 | OC-05 | Medium | M | Per-kind CIP-67 labels; typed `Mg`/`Md4`; `subject /= issuer`; decide lineage |
| 6 | OC-06 | Medium | S–M | `WithdrawDispute` after timeout; restrict/validate `depositTo` shape |
| 7 | OC-09 | Low | M/L | Decide upgrade stance; `protocolVersion`; multi-policy chain-sync or migration redeemer |
| 8 | OC-07 | Low | S | `Cleanup` refuses to sweep values holding a 222-labelled token |
| 9 | OC-08 | Low | S | Replace `protocolParams` in the profile datum with `profileOracleToken` (or fix the prose) |
| 10 | OC-10 | Low | S | Document the co-signing risk; "latest claim wins" in the read layer; consider vote-based proof |
| 11 | OC-11 | Info | S | Delete `Protocol/Id.hs`, `unsafeGet*`, dead `Utils`/`CIP68` helpers and codes; fix CLAUDE.md ×3, blueprint strings, two Haddock misattachments, future-dating note |
| 12 | OC-12 | Info | S | Assert `oracleParamsAreWellFormed` in `mintOracleNFTAndLockDatum` |
| 13 | OC-15 | Info | S | Consider `unsafeFromBuiltinData` for the context; measure ExUnits |
| 14 | OC-14 | Info | M | Product decision on rejecting pending attestations |
| 15 | OC-13 | Info | M | Only if issuance volume demands batching |
