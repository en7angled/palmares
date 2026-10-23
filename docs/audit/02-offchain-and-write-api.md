# Audit 02 — Off-chain transaction building, write HTTP API, admin CLI

> **Reconciled 2026-10-23 against `main` @ `2bf5bde`.** Every finding below has been re-judged; the per-finding verdicts, with current `path:line`, are in [`07-reconciliation-2026-10-23.md`](07-reconciliation-2026-10-23.md). Line references in this file are as of `4eb9117` and several have moved.

- Repo: `github.com/mariusgeorgescu/palmares`, branch `main`, HEAD `4eb9117` (2026-10-22).
- Method: static reading only (no GHC/cabal on the audit machine; nothing was built or run). Every
  claim in a comment was treated as a hypothesis and checked against the code it describes; the
  on-chain validators were read to cross-check each skeleton. Atlas (`atlas-cardano 0.14.1`,
  git `bf0d2d1`) is not vendored here, so a handful of Atlas-internal behaviours are listed under
  "Could not verify" rather than asserted.
- Scope: `src/lib/offchain-lib/Palmares/TxBuilding/*`, `DomainTypes/Core/*`, `Transfer/Types.hs`,
  `Utils.hs`, `Constants.hs`; `src/exe/interaction-api/*`; `src/exe/admin/Main.hs` (not
  `Reconcile.hs`); `src/lib/webapi-lib/Palmares/WebAPI/*`; `config/*.example.json`, `.env.example`.
- Severity scale: Critical / High / Medium / Low / Info. Effort: S (< ½ day), M (1–3 days), L (> 3 days).

## 1. Summary

The pipeline (`Interaction → interactionToTxSkeleton → Operations → buildTxBody`) is sound where it
matters most: every operation's output layout matches the index its redeemer carries, every mint path
carries the oracle reference input and the fee output, the validity window is half the on-chain
`maxDateWindow`, and no on-chain function that can `traceError` is reachable from the server. The
defects are at the edges — where the builder's defaults meet the validator's newer rules (Md8, O5,
D7), where errors are translated for clients, and in the admin tooling.

Top findings:

| ID | Sev | Title |
|---|---|---|
| OF-01 | High | `admin rotate-admin` signs with one key and submits; O5 needs the incoming admin's signature, so the shipped tooling cannot rotate the admin at all |
| OF-02 | High | `open-dispute` defaults `deposit_to` to the change address, which Md8 does not guarantee is spent; multi-address wallets fail, caller-supplied addresses are unchecked |
| OF-03 | Medium | `resolveDisputeTX` builds while paused; the chain refuses with D7 and the API reports it as `InsufficientFunds` |
| OF-04 | Medium | `getFeeSkeleton` emits a 0-lovelace output for free actions when fees are configured; the balancer turns it into ~1 ADA paid to the fee address |
| OF-05 | Medium | Error translation: every `GYBuildTxException` becomes "Not enough ADA", provider/submit/await exceptions escape as bare 500s, `/tx-status` very likely 500s on an unconfirmed tx |
| OF-06 | Medium | `recipient` is documented on all six write requests and never read |
| OF-07 | Medium | `/submit-tx` relays any transaction through the operator's provider token |
| OF-08 | Medium | Reference scripts are locked at the operator's key address and are spendable |
| OF-09 | Medium | `admin sign-tx` is a blind signer holding the oracle-admin key |
| OF-10 | Medium | Write-path lookups accept any asset class; a forged dispute datum blocks `open-dispute` for a target |

## 2. Hypotheses, confirmed or refuted

**H1 — Output layout vs redeemer index.** Confirmed consistent for all seven operations. The index
is a hard-coded `0 :: Integer` in each builder (`updateOracleTX` uses the literal in the redeemer,
`Operations.hs:779`), never computed. Skeleton `mconcat` order and the on-chain check:

| Operation | Declared outputs in `mconcat` order | Redeemer index | On-chain check |
|---|---|---|---|
| `claimProfileTX` (`Operations.hs:319-328`) | 0 profile state, 1 fee (optional) | `MintProfile … 0` (`:298`) | Mp5/Mp6 idx (`MintingPolicy.hs:291,315`) |
| `updateProfileTX` (`:189-196`) | 0 updated profile | `UpdateProfile … 0` (`:177`) | P5 (`ProfilesValidator.hs:156`) |
| `issueAttestationTX` (`:468-477`) | 0 attestation, 1 fee (optional) | `NewAttestation … 0` (`:431-441`) | Mk (`MintingPolicy.hs:252`) |
| `acceptAttestationTX` (`:539-546`) | 0 updated attestation | `AcceptAttestation 0` (`:526`) | A1 (`AttestationsValidator.hs:131-139`) |
| `openDisputeTX` (`:662-671`) | 0 dispute + deposit, 1 fee (always empty by intent, see OF-04) | `OpenDispute … 0` (`:624-634`) | Md5 (`MintingPolicy.hs:407`) |
| `resolveDisputeTX` (`:754-761`) | 0 resolved dispute, 1 returned deposit | `ResolveDispute v 0` (`:734`) | D2 idx, D4 `any` (`DisputesValidator.hs:154-167,183`) |
| `updateOracleTX` (`:810`) | 0 re-locked oracle | `OracleUpdate 0 …` (`:779`) | O2 (`OracleValidator.hs:85`) |

Fee outputs are found with `any` (`Lookup.hs:127-130`), so index 1 is never asserted on chain.
Atlas's `GYTxSkeleton` semigroup appends `gytxOuts` in order and the balancer appends change after
the declared outputs; the emulator suite (`TestRuns.hs` runs every operation through
`interactionToTxSkeleton` + `buildTxBody`) pins that behaviour, which is the right place for it.

**H2 — Validity windows.** Confirmed. `txIsValidForSafeEra now = isValidBetween now (now+25920)`
(`Skeletons.hs:55-56`), slot-based from `slotOfCurrentBlock`; no wall clock is involved, so client
clock skew cannot matter. On 1-second-slot networks the width is 25,920,000 ms, exactly half of
`maxDateWindow = 51,840,000` (`Onchain/Utils.hs:240-241`) and `checkDateInRange` accepts `hi - lo <=`
(`:244-248`). The date stored is `slotToBeginTime now` (`TxBuilding/Utils.hs:117-118`), i.e. the
closed lower bound, so Mq/Md6 `member` holds. A stale provider tip only moves the window into the
past, which the ledger accepts. The only way an honest tx fails is being submitted > 7.2 h after
being built. Two cosmetic points: the comment says "seconds" where the unit is slots
(`Skeletons.hs:46`), and `issueAttestationTX`/`openDisputeTX` read the tip twice
(`Operations.hs:73` then `:406`; `:600` then `:607`) — harmless (date ≥ lower bound either way) but
`getOracleFeeAndValiditySkeleton` should return `now`.

**H3 — Oracle ref input, fee, signatures.** Confirmed. All three mint paths go through
`getOracleFeeAndValiditySkeleton` (`:279-280`, `:391`, `:599-600`), which attaches the oracle ref
input, the pause check and the fee skeleton. `claimProfileTX` adds `mustBeSignedBy` for a key
credential (`:236-238`, Mp3); `resolveDisputeTX` adds `mustBeSignedBy gyAdminPkh` read from the
oracle datum (`:725`, `:760`, D1); `updateOracleTX` adds the current admin and, for a rotation, the
incoming admin (`:795`, `:806-808`, O1/O5). The API builds `/resolve-dispute` for whoever asks
(`ServiceHandlers.hs:87-91`) and the admin signs the returned CBOR — see OF-01/OF-09 for what that
implies for the signer.

**H4 — ResolveDispute while paused.** Confirmed: `resolveDisputeTX` calls `queryOracleParams`
directly (`Operations.hs:724`) and never reads `opPaused`; `getOracleRefInputSkeleton` (`:35-42`) is
the only place the `ProtocolPaused` refusal lives. The validator refuses with D7
(`DisputesValidator.hs:146`), and `UnitTests.Pause` 7.2 pins exactly that (`Pause.hs:99-114`). Fix in
OF-03.

**H5 — Authenticate before trust.** Partially refuted. `authenticateStateUTxO` (`TxBuilding/Utils.hs:96-103`)
is called only from `Ingestion.hs:111` and tests — never from `TxBuilding/*`. The write path finds
UTxOs *by* NFT (`getUTxOWithNFT`, `Lookups.hs:48-52`), so the asset is in the value by
construction, but nothing checks that the asset is *ours* and a *reference* token. Lookups that read a
datum without that check: `getProfileStateDatumAndValue` (`:88-90`), `getAttestationDatumAndValue`
(`:165-167`), `getDisputeDatumAndValue` (`:193-195`), `ensureSubjectProfileExists` (`:182-184`),
`getOpenDisputesForAttestation` (`:208-214`, which also reads every datum at the address without
checking the value backs it). `queryOracleParams` (`:125-137`) does check address + NFT. See OF-10.

**H6 — On-chain functions used off-chain.** No `traceError` reachable. Sites: `Lookup.feeFor`
(`Operations.hs:58`, total), `checkNoOpenDispute` (`Lookups.hs:214`, pure `any`), `resolveDispute`
(`Operations.hs:742`, record update), `mkCIP68Datum`/`getMetadataFields`/`updateCIP68DatumMetadata`
(`:310,170,184`; `fromMaybe ""` and `AssocMap.insert`, total), `deriveUserFromRefTN`/
`deriveRefFromUserAC`/`isRefTokenName`/`userTokenPrefixBS` (`Skeletons.hs:38`, `Lookups.hs:237-239`,
`TxBuilding/Utils.hs:101`; `sliceByteString` is total on the Haskell side), `nameFromTxOutRef`
(`Skeletons.hs:24`; `integerToByteString` could only fail on a negative index, which `GYTxOutRef`
cannot produce). The rule is respected. The opposite smell exists: `applyAdminAction` re-implements
`applyOracleAdminAction` instead of calling it (OF-18).

**H7 — Exceptions → HTTP.** Every constructor is mapped, seven of them through the `_ -> 400`
fallthrough (`Exceptions.hs:147`). Bodies are `{"code","message"}` built from `displayException`
(`InteractionAppMonad.hs:70-72`); `show ex` goes to stdout only (`:96,101`), so nothing internal
leaks. Provider errors are not mapped to 502/503 — they are not caught at all (OF-05). No `fromJust`,
`head`, `undefined` or `error` in the request path; the only partial calls are `unsafeAddressFromText`
in the CLI (`admin/Main.hs:519`) and the unreachable `error` in `Ids.hs:55`.

**H8 — Write API surface.** Basic auth with `constEq` (`Auth.hs:42`), fail-closed env (`:54-62`),
over plain HTTP on `0.0.0.0` (`interaction-api/Main.hs:68-71`; TLS termination is assumed and not
documented in `deploy/`). CORS is fail-closed (`CORS.hs:62-78`, pinned by `ApiHardening.hs:48-65`).
No request-size limit and no cache on the provider-backed probes (OF-13). `/build-tx` accepts
`ProfileAction`, `DisputeAction` (incl. `ResolveDisputeAction`), `ProtocolAction CleanupDustAction`;
every `AdminActionType` fails `FromJSON` (`Actions.hs:394-399`, pinned by
`InteractionApi.hs:195-204`). `/submit-tx` does `getTxBody` + `makeSignedTransaction`
(`RestAPI.hs:103-107`): scripts/datums/redeemers survive, key witnesses are replaced, and signature
validity is left to the node — correct, but it binds nothing (OF-07). `/status` is truthful and
distinguishes "paused" from "oracle unreadable" (`ServiceStatus.hs:114-120`). The Swagger `GYAddress`
prose is wrong *and it is the project's own line*, not Atlas's (`WebAPI/Utils.hs:44`; OF-15).

**H9 — Reference scripts.** Confirmed: `deployReferenceScript` locks each script at `my_addr`, the
operator's key address (`Transactions.hs:148,152`). `addRefScriptSkeleton` targeting
`limboValidatorV2` exists and is unused (`Skeletons.hs:177-180`). OF-08.

**H10 — Admin CLI.** `operation.prv` is read for every on-chain command including read-only
`query-oracle` (`admin/Main.hs:834-835`), contradicting `src/exe/CLAUDE.md` ("Read-only commands … no
signing"). `sign-tx` reads the key quietly and signs whatever arrives on stdin (`:807-822`). The command
set matches the smoke doc's table: no `claim-profile`, `open-dispute`, `resolve-dispute`.
`Either ProviderCtx TxBuildingContext` discipline is kept (`:530-547` vs `:548-635`).
`deploy-reference-scripts` overwrites the validators config without confirmation (`:557`; OF-14).
`rotate-admin` cannot work (OF-01).

**H11 — DomainTypes.** Conversions are arm-by-arm and total both ways (`Conversions.hs:54-89,150-157`);
enum spellings are read back from `ToJSON` (`Core/Types.hs:68-72,161-174`) and pinned by
`UnitTests.Conversions`. Ids: `parseCredentialCip129` keeps the key/script bit and validates HRP vs
header (`Ids.hs:120-129`), but the *role* is dropped on the way to `Credential`, and
`claimCredentialToText` always renders `drep` (`Conversions.hs:119-121`). A `cc_cold1…` claim is
echoed as `drep1…`, and a hash lookup conflates roles (OF-16).

**H12 — ClaimWitness paths.** Key: `mustBeSignedBy`. Simple/Plutus script: the first datum-less-or-
inline UTxO at the script's payment credential is spent with the caller's witness
(`Operations.hs:239-247`, `Conversions.hs:133-138`). `ScriptCredentialHasNoUtxo` is not the only
limitation: a UTxO carrying a datum *hash* cannot be spent with `Nothing` datum; the witness's hash
is never compared with the claimed hash; the spent UTxO's whole value goes to the claimant's change
address (OF-11); and nothing after the claim can be done with a script-held user token (OF-12).

**H13 — Collateral / multi-address.** `reservedCollateral` is passed with the 5-ADA-only check
(`Context.hs:93-94`), falling back to framework selection — fine. User tokens are searched across all
`usedAddresses` (`Skeletons.hs:127-128`), so a token at a non-change address is found. The
multi-address hazard is Md8 (OF-02), not token lookup. A token outside the wallet's addresses yields
`ProfileNotFound` ("Profile not found"), which misdescribes the situation (OF-10).

**H14 — Contention.** The oracle is a reference input for every user tx, by its *current* `TxOutRef`
(`Operations.hs:42`); an admin update spends it, so every user tx built before the update and
submitted after it fails ledger validation (reference inputs must exist). Per-wallet: each
issue/accept/dispute spends the user NFT and a seed UTxO and gets them back only in change, so two
writes from one wallet in one block conflict unless the second is built after the first confirms
(Maestro does not expose the mempool). Nothing documents this for the UI (OF-25).

**H15 — Code quality.** `Operations.hs` is 870 lines, 174 of them comments (20%), five concerns in
one module. Duplication: three operations look the same UTxO up twice (OF-21). Dead code and stale
comments: OF-19. `-Wno-partial-fields` hides partial selectors in `Actions.hs:1`,
`Transfer/Types.hs:1`; `Validators.hs:1` disables `-Wincomplete-patterns` for no visible reason.
Module-level Haddock is missing on 10 in-scope modules; 15 lines > 120 chars in `admin/Main.hs`,
11 in `Operations.hs`/`Skeletons.hs`/`RestAPI.hs`.

## 3. Findings

### OF-01 — High — `rotate-admin` cannot satisfy O5 with the shipped tooling
- Location: `src/exe/admin/Main.hs:583-587`, `src/lib/offchain-lib/Palmares/TxBuilding/Transactions.hs:127-137`,
  `Operations.hs:797-808`, `src/lib/onchain-lib/Palmares/Onchain/Validators/OracleValidator.hs:86,111`.
- What: `updateOracleTX` adds `mustBeSignedBy newAdmin` for `RotateAdminAction`; the CLI runs it
  through `runActionWithPK`, which does `signGYTxBody txBody [skey]` with the single `operation.prv`
  key and submits immediately. The ledger refuses a tx whose required signer has no witness, and O5
  refuses it on chain anyway. The only alternative, `/build-tx` with an `AdminAction`, is a 400 by
  design. The emulator harness had to write its own two-key runner (`TestRuns.hs:1064-1100`) — and
  says so: "`adminInteraction` cannot do this. It runs under `asUser`, which signs with exactly one
  key" (`:1066`).
- Why it matters: inherited fix #2 ("the admin key must be rotatable") is not usable in production.
  An operator who must hand over the oracle — key compromise, personnel change, moving to a
  hardware key — has no path except rotating to a key they *also* hold in `operation.prv`, which is
  not a rotation.
- Evidence: `Operations.hs:804-805` "`admin rotate-admin` has to be run with both keys available" —
  the command takes only `--new-admin PUBKEYHASH_HEX` (`admin/Main.hs:432-446`).
- Fix: two-step handover. `rotate-admin --new-admin H` builds, signs with the current key and prints
  the partially-signed tx hex; the incoming admin runs `sign-tx` (in its own checkout) and the
  witness is attached by a new `admin submit-tx --tx … --wit …` (or `/submit-tx`). Alternatively
  accept `--new-admin-mnemonic-file` for the co-located case. Add an emulator test that drives the
  CLI code path (`runActionWithPK`) and expects it to fail today.
- Effort: M.

### OF-02 — High — `deposit_to` default is not guaranteed to satisfy Md8; caller value unchecked
- Location: `Interactions.hs:128-138` (default `changeAddress userAddresses`), `Operations.hs:585-673`,
  `MintingPolicy.hs:406` (`Md8`: `any ((== depositTo) . txOutAddress . txInInfoResolved) txInfoInputs`).
- What: the builder chooses inputs from `usedAddresses` by Atlas coin selection; nothing forces an
  input from `changeAddress`. For a wallet whose change address holds no UTxO (Yoroi, Eternl in
  multi-address mode, any fresh HD change address), or whenever coin selection happens to pick
  inputs from other addresses, Md8 fails. The script failure surfaces during balancing as
  `GYBuildTxException`, which the API reports as `400 InsufficientFunds` "Not enough ADA in your
  wallet" (OF-05). A caller-supplied `od_deposit_to` is "deliberately not constrained off chain"
  (`UnitTests/Dispute.hs:517-520`), but the production builder can only spend from `usedAddresses`,
  so an outside address can never succeed through this API.
- Why it matters: disputes are the protocol's only correction mechanism; for a class of wallets
  the route is dead on arrival with a misleading error. The smoke test hides it because it uses one
  address for everything (`scripts/smoke_attest_flow.sh:196,384`); the emulator hides it because
  `userChangeAddress` is funded (`Dispute.hs:397`).
- Fix: in `openDisputeTX`, default `depositTo` to the address of the opener's user-NFT UTxO (already
  spent by construction — return it from `txMustSpendFromAddress`), and when the caller supplies an
  address, require it to be in `usedAddresses` and add an explicit `mustHaveInput` of one UTxO at
  that address, failing early with a new `DepositAddressNotSpendable` (400). Correct the Swagger
  text at `ServiceRequests.hs:187-190` (OF-17). Add an emulator case with a funded wallet whose
  change address is empty.
- Effort: S–M.

### OF-03 — Medium — `resolveDisputeTX` does not refuse while paused
- Location: `Operations.hs:714-761` (`queryOracleParams` at `:724`), `DisputesValidator.hs:137-146`.
- What: the builder reads the oracle for the admin hash but ignores `opPaused`; the chain refuses
  with D7. Through the API that is a build-time script failure → `400 InsufficientFunds`; through
  the smoke flow it reads as a broken deployment.
- Evidence: `Operations.hs:698-703` admits the defect and defers it because "doing it twice needs a
  careful look at the resulting input set".
- Fix: no second ref input is needed — keep `mustHaveRefInput oracleRef` and add
  `when (OnchainTypes.opPaused oracleParams) $ throwError (GYApplicationException ProtocolPaused)`
  right after `:724`. Change `UnitTests.Pause` 7.2 to expect the off-chain refusal and keep a
  malicious-builder case for D7.
- Effort: S.

### OF-04 — Medium — Zero-priced actions still emit a fee output when fees are configured
- Location: `Operations.hs:50-61` (`getFeeSkeleton`), `:670` (comment "always empty"),
  `Onchain/Protocol/Lookup.hs:100-103,121`.
- What: `feeFor MintActionDispute = const 0`, and on chain a fee `<= 0` means "no output required"
  (`checkFee`, `:121`). Off chain `getFeeSkeleton` returns `mempty` only when `opFeeConfig` is
  `Nothing`; with any `FeeConfig` set it builds `txMustPayValueToAddress feeAddr (lovelace 0)`.
  Atlas raises outputs below min-ADA, so every dispute (and every claim/attestation priced at 0 by
  `set-fees`) pays ~1 ADA to `fcFeeAddress`. The comment at `:670` ("always empty") is false.
- Why it matters: the protocol promises that contesting costs only network fees and that "zero is
  the configured value on preprod" (`UnitTests/Fees.hs:44-46`); the moment an admin runs `set-fees`
  with any non-zero field, disputers are charged a hidden fee. No emulator test opens a dispute with
  fees configured (`UnitTests/Dispute.hs` tests `checkFee` purely).
- Fix: `getFeeSkeleton`: `let feeAmount = …; if feeAmount <= 0 then return mempty else …`, mirroring
  `checkFee`. Add a `PropertyTests` case: for every `MintAction` and `FeeConfig`, the off-chain
  skeleton has a fee output iff `checkFee` with `[]` is `False`.
- Effort: S.

### OF-05 — Medium — Error translation collapses or drops the failures a client needs to distinguish
- Location: `src/exe/interaction-api/InteractionAppMonad.hs:77-109,125-134`, `Errors.hs:33-44`.
- What: (a) `GYBuildTxException {} -> insufficientFunds` (`:93`) covers every balancing failure,
  including Plutus evaluation failures (Md8, D7, Mq, K2, …), fee-too-big and size-too-big; all
  become "Not enough ADA in your wallet". (b) `try action` is typed by the patterns to
  `GYTxMonadException`; Maestro HTTP errors, submit rejections and any other exception type
  propagate to Warp's default handler — a text/plain 500 "Something went wrong" with no `code`,
  where 502/503 would be true. (c) `pollTxConfirmation` catches only `GYTxMonadException`
  (`:131`); Atlas's `gyAwaitTxConfirmed` signals exhaustion with its own `GYAwaitTxException`, so an
  unconfirmed or unknown tx id most likely yields a 500 rather than `{"confirmed": false}` — the
  smoke script survives only because `curl -f` treats the 500 as "not yet" (`smoke_attest_flow.sh:181`).
- Fix: catch `SomeException`; map `GYBuildTxException (GYBuildTxBodyErrorAutoBalance
  (TxBodyScriptExecutionError …))` to `400 ScriptRefused` carrying the trace codes (the project
  keeps traces for exactly this reason, `palmares.cabal` plinth options), balancing shortfalls to
  `InsufficientFunds`, provider errors to `502 ProviderError`, await exhaustion to
  `confirmed: false`. Add a unit test for the mapping function once it is pure.
- Effort: M.

### OF-06 — Medium — `recipient` is a documented no-op
- Location: `Interactions.hs:83-84`, `ServiceRequests.hs:69-71,93,132,154,189-190,217-219`,
  `Transactions.hs:127-131`.
- What: `Interaction.recipient` is bound by `Interaction {..}` in `interactionToTxSkeleton` and never
  used; no operation takes it. Six request types publish "Address to receive unlocked funds
  (defaults to change address if omitted)".
- Why: a client that sets `recipient` to a cold address expects a returned deposit or the returned
  user NFT there; both go to the change address. The contract lies.
- Fix: either remove the field from the six requests and `Interaction` (breaking, honest), or
  implement it for the one place it has meaning today (the returned deposit in `resolveDisputeTX`
  is fixed by the datum, so realistically: remove). Add the field to the `InteractionApi` arm test
  so a reintroduction is deliberate.
- Effort: S.

### OF-07 — Medium — `/submit-tx` is an unrestricted relay
- Location: `RestAPI.hs:103-107`, `InteractionAppMonad.hs:118-121`, `Transactions.hs:82-87`.
- What: any Basic-auth holder can submit any Conway transaction through the operator's Maestro
  token (`turboSubmit: true`, `config/config_atlas.example.json`). The service never checks the tx
  touches a protocol script, nor that it built it.
- Why: provider quota and rate limits are the operator's; the credential is shared by every client
  of the SPA (see open question Q1). Abuse is cheap and invisible in the registry's own logs.
- Fix: require that the body's inputs/mints reference one of the five deployed script hashes
  (cheap, pure over `GYTxBody`), or keep a short-lived cache of body hashes the service built and
  accept only those; log the tx id and auth principal on submit.
- Effort: M.

### OF-08 — Medium — Reference scripts sit at a spendable key address
- Location: `Transactions.hs:146-156` (locked at `my_addr`), `Skeletons.hs:177-184`.
- What: the five reference-script UTxOs are ordinary outputs at the operator's address. The
  operator (or whoever obtains `operation.prv`, which `new-operator-key` calls "disposable") can
  spend them; an external wallet restored from the same mnemonic will happily consume them as
  inputs. After that every `*TX` fails at `GYInReference` resolution and `/ready` goes red until a
  re-deploy of the reference outputs and a config rollout to both services.
- Fix: lock them at an always-fail script (Atlas's `limboValidatorV2`, already imported and wired
  in the unused `addRefScriptSkeleton`), or at a dedicated key never used for anything else, and
  document the ~50 ADA/script permanently locked. Make `verifyDeployedScriptsAreReady` compare the
  resolved script hash with the configured one (`Operations.hs:124-130` only checks `isJust`).
- Effort: S (+ redeploy).

### OF-09 — Medium — `sign-tx` signs anything with the oracle-admin key
- Location: `admin/Main.hs:807-822`, `docs/deployment/attest-flow-smoke.md` ("The signer the repo ships").
- What: the command reads `operation.prv` — the deploy key, the oracle admin and the fee wallet in
  one — and signs whatever CBOR is on stdin without displaying inputs, outputs, mints or required
  signers. The smoke flow pipes an HTTP response straight into it, over plain HTTP by default.
- Scenario: a compromised or mis-pointed interaction API (or a MITM on a non-TLS deployment)
  returns a transaction that spends the operator's funds or carries an `OracleUpdate` rotating the
  admin to the attacker; the operator's own script signs and submits it.
- Fix: print a summary (inputs by address, outputs, mint, required signers, whether the oracle UTxO
  is spent) to stderr and require `--yes`/`--expect-inputs-from <addr>`; refuse to sign a tx that
  spends the oracle UTxO unless `--allow-oracle-update`; recommend a separate key for day-to-day
  signing vs oracle admin.
- Effort: M.

### OF-10 — Medium — Lookups trust any asset class; a parked dispute datum blocks `open-dispute`
- Location: `Lookups.hs:48-52,74-90,165-167,182-184,193-195,208-214`.
- What: (a) `getUTxOWithNFT` is given client-supplied asset classes without checking policy or
  CIP-67 prefix. A user token or foreign asset finds a UTxO with no inline datum →
  `DatumParseError` → **500** for a client mistake; a foreign asset with a crafted inline datum is
  parsed as protocol state (harmless on chain, misleading off chain). (b)
  `getOpenDisputesForAttestation` reads every parseable datum at the Disputes address without
  requiring the value to hold `disputeId`. Anyone can pay min-ADA plus a hand-written
  `OnchainDispute` (target = victim's attestation, verdict `Nothing`) to that address — no script
  runs — and `openDisputeTX` then refuses every real dispute against that target with
  `DisputeAlreadyOpen` until someone sweeps the dust.
- Fix: add a pure pre-check `ensureProtocolRefToken :: GYAssetClass -> m ()` using
  `getMintingPolicyHash ctx` + `isRefTokenName` before any provider call (400 `InvalidAssetClass`),
  and filter `getOpenDisputesForAttestation` with `authenticateStateUTxO ourPolicy (disputeId …)
  (utxoValue utxo)`. Rename the "user token not in wallet" refusal from `ProfileNotFound` to a
  distinct `UserTokenNotInWallet`.
- Effort: S–M.

### OF-11 — Medium — Script-credential claims drain the spent script UTxO to the claimant
- Location: `Operations.hs:239-247`, `Conversions.hs:133-138`.
- What: the first spendable UTxO at the script's payment credential is added as an input with the
  caller's witness and no corresponding output; its entire value lands in the claimant's change
  address. For a multisig treasury that is a withdrawal disguised as a profile claim, co-signed by
  members who were asked to "approve the registry claim". Also unchecked: that the supplied script
  hashes to the claimed credential (a mismatch fails late as `InsufficientFunds`), and that the
  chosen UTxO has no datum hash (unspendable with `Nothing`).
- Fix: re-pay the spent UTxO's value and datum to the same address (`mustHaveOutput` mirroring the
  input); pick the smallest spendable UTxO; compare `scriptHash`/`simpleScriptHash` with the claimed
  hash and refuse with `WitnessDoesNotMatchCredential` (400); skip datum-hash UTxOs.
- Effort: M.

### OF-12 — Medium — "First-class script issuer" is not realised beyond the claim
- Location: `Skeletons.hs:117-134` (witness parameter), `Operations.hs:95-107,183,422,506,615`.
- What: every caller passes `GYTxInWitnessKey`. The Skeletons comment "Callers that hold their token
  in an ordinary wallet pass `GYTxInWitnessKey` and are unchanged" describes a choice no caller can
  make. Moreover `claimProfileTX` sends the freshly minted user token to the claimant's change
  address (a key address), so a script organisation's authority token never reaches the script in
  the first place.
- Fix: decide the product position. Either thread `ClaimWitness` through
  `IssueAttestation/Accept/OpenDispute/UpdateProfile` and let `claim-profile` pay the user token to
  an explicit `authority_address` (the script address), or state in `CLAUDE.md`/Swagger that
  organisations act through a key wallet after claiming.
- Effort: M–L (or S for the documentation route).

### OF-13 — Medium — No body-size limit; unauthenticated probes cost provider calls
- Location: `interaction-api/Main.hs:71` (`defaultSettings`), `RestAPI.hs:289-296`,
  `InteractionAppMonad.hs:137-142`, `ServiceStatus.hs:88-106`.
- What: `wai-extra` is a dependency but `requestSizeLimitMiddleware` is not applied; a client can
  POST an arbitrarily large JSON body that Aeson materialises. `/ready` performs five
  `utxoAtTxOutRef` calls and `/status` six provider calls per hit, with no auth and no cache; a
  10-second readiness probe alone is ~43k Maestro calls/day, and anyone can multiply it.
- Fix: `requestSizeLimitMiddleware (setMaxLengthForRequest (const 256 KiB))` outermost; memoise the
  probe results in an `IORef` with a 30–60 s TTL; add `setServerName ""`.
- Effort: S.

### OF-14 — Medium — `deploy-reference-scripts` silently overwrites the live validators config
- Location: `admin/Main.hs:554-558` (`B.writeFile Constants.defaultTxBuildingContextFile`).
- What: a second run (typo, retry after a partial failure, wrong shell) mints a second oracle NFT, a
  second minting policy and five new reference outputs, then overwrites
  `config/config_palmares_validators.json`. Running services keep the old context; the CLI now
  points at a different protocol instance; both have valid-looking state.
- Fix: refuse if the file exists unless `--force`, the way `new-operator-key` does (`:747-755`);
  print the oracle NFT and policy hash before spending anything and ask for confirmation.
- Effort: S.

### OF-15 — Low — Swagger says `GYAddress` is bech32; only raw hex is accepted — and the text is ours
- Location: `src/lib/webapi-lib/Palmares/WebAPI/Utils.hs:44`, `docs/generated/swagger/interaction-swagger-api.json`
  (`GYAddress.description`), `docs/deployment/attest-flow-smoke.md`, `admin/Main.hs:791-799`.
- What: `addSharedSwaggerDescriptions` overrides Atlas's schema description with "Bech32-encoded
  Cardano address (addr_test1…)" while the same definition says `format: cbor hex`, length 114.
  Two documents blame "the generated document"; the line is in this repository.
- Fix: correct the sentence (one line) now. Then introduce `newtype ApiAddress = ApiAddress GYAddress`
  whose `FromJSON` accepts both `addr…`/`addr_test…` (`addressFromTextMaybe`) and raw hex, with
  `ToSchema` describing both; use it in `UserAddresses` and the request types. Keep hex output for
  compatibility. Fix the misleading `UserAddresses` camelCase fields (`usedAddresses`,
  `changeAddress`, `reservedCollateral`) in the same breaking change, since every other field is
  snake_case.
- Effort: S (text) / M (newtype).

### OF-16 — Low — Credential role is dropped; `cc_cold` echoes as `drep`; kind vs HRP unchecked
- Location: `Conversions.hs:107-121`, `Ids.hs:120-129`, `Operations.hs:275`.
- What: `parseCredentialCip129` accepts `cc_hot`, `cc_cold` and `drep` HRPs and returns only
  (script?, 28 bytes); `claimCredentialToText` re-renders every credential as `drep1…`. A profile
  of kind `person_drep` may claim a `cc_cold1…`; a committee member's claim is published as a DRep
  id; a credential lookup by hash cannot tell the two roles apart. `cc_hot` (a rotatable key, "not a
  stable identity" per `Ids.hs:165-168`) is claimable.
- Fix: derive the HRP from `profileKind` when rendering (Committee → `cc_cold`, PersonDRep → `drep`),
  refuse `cc_hot` at claim time, and validate HRP against kind with a new `CredentialKindMismatch`
  (400). Record the role in the datum only if a redeploy is on the table anyway.
- Effort: M.

### OF-17 — Low — Stale security statement published in Swagger
- Location: `ServiceRequests.hs:184-190` ("pointing it somewhere useless costs only the disputer").
- What: `Actions.hs:305-311` and `MintingPolicy.hs:348-356` document that this sentence was wrong
  and why (an unpayable address made D4 unsatisfiable); the request-type description still says
  it, and it is the text clients read.
- Fix: replace with "must be an address this transaction spends from (Md8); defaults to the address
  holding your profile's user token" once OF-02 lands.
- Effort: S.

### OF-18 — Low — Duplicated on-chain logic and a non-total status map
- Location: `Operations.hs:823-829` vs `Onchain/Protocol/Types.hs:141-147`; `Exceptions.hs:147`.
- What: `applyAdminAction` re-implements `applyOracleAdminAction` field by field ("must stay in
  sync"), while `resolveDisputeTX` correctly reuses `resolveDispute` "so the two cannot disagree".
  `txBuildingExceptionToHttpStatus` ends in `_ -> 400`, the fallthrough `Envelope.hs:161-163`
  explicitly argues against for the read surface.
- Fix: `applyAdminAction = applyOracleAdminAction . adminActionToOracleAdminAction`; make the status
  map exhaustive.
- Effort: S.

### OF-19 — Low — Dead code and stale prose
- Location (all unused outside their defining module, confirmed by grep): `Lookups.hs:101-114`
  `getOrganizationInformation` (its DTO is used by query-api, the lookup is not), `:220-242`
  `getProfileRefACsAtAddress` (also lacks a policy filter), `Operations.hs:332-339` `hasUserNFTAt`,
  `Skeletons.hs:114-115,173-180` `txMustHaveUTxOsAsRefInputs`/`txMustBurnCIP68UserAndRef`/
  `addRefScriptSkeleton`, `TxBuilding/Utils.hs:49-56,120-122` `extractNFTAssetClass`/
  `gySlotFromPOSIXTime`, `Validators.hs:185-202` `export*Validator` plus
  `Constants.hs:11-24`, `admin/Main.hs:208-218` `optionalPosixTimeParser`, `Onchain/Protocol/Id.hs`
  (zero callers, as its own CLAUDE.md says), `Onchain/Protocol/Lookup.hs:26-55` `unsafeGet*`.
  Stale text: `Operations.hs:1` ("ranks, memberships"), `Skeletons.hs:46` ("seconds … UpdateEndDate"),
  `Transfer/Types.hs:51-90` DTOs with no interaction-api route, `RestAPI.hs:220` license
  "GPL-3.0" vs Apache-2.0 in `LICENSE`, `info.version "3.0.0"` vs `appVersion = "1.0.0"`.
- Fix: delete, or export deliberately with a test; one commit.
- Effort: S.

### OF-20 — Low — `cleanupDustTX` is unbounded and narrower than the on-chain rule
- Location: `Operations.hs:838-870`, `Lookups.hs:148-156`.
- What: every dust UTxO at three addresses goes into one transaction (ExUnits/size blow past the
  limits once a griefer has parked a few dozen outputs), and the off-chain predicate ("no token of
  our policy") never offers UTxOs the chain *would* let it sweep — a user token mis-sent with a
  hand-written datum (`Onchain/Utils.hs:361-367`).
- Fix: cap at N inputs per tx (e.g. 20) and report `remaining`; mirror `isUnbackedDatum` off chain.
- Effort: S.

### OF-21 — Low — Hot-path lookups scan addresses and read state twice
- Location: `Lookups.hs:125-137` (`utxosAtAddresses [oracleAddr]`), `Operations.hs:500/529`,
  `:167/180`, `:717/735`.
- What: every write and `/status` lists the whole oracle address, which anyone can bloat with
  outputs the oracle validator can never sweep (it has no `Cleanup`). Accept/update/resolve fetch
  the same UTxO twice (two provider calls, and a window in which the state can change between the
  datum read and the input chosen).
- Fix: `getUTxOWithNFT oracleAC` + address check; reuse `txMustSpendFromRefScriptWithKnownDatum`
  (already used by `updateOracleTX`) for the other three.
- Effort: S.

### OF-22 — Low — Admin CLI rough edges
- Location: `admin/Main.hs:834-835` (key required for `query-oracle`), `:519`
  (`unsafeAddressFromText` → Haskell `error` on a typo), `:583-587` (no confirmation for
  `rotate-admin`/`pause-protocol`), `:75-76` of `interaction-api/Main.hs` (config echoed to stdout).
- Fix: read the key only for signing commands; `addressFromTextMaybe` + `die`; `--yes` for
  irreversible commands; log provider *family* only.
- Effort: S.

### OF-23 — Info — Style and documentation debt
- `Actions.hs:238-275` snake_case record fields (`profile_id`, `cp_kind`) against the camelCase
  rule, chosen to drive aeson; `CustomJSON` with `StripPrefix`+`CamelToSnake` would give both.
  `-Wno-partial-fields` in `Actions.hs:1`, `Transfer/Types.hs:1`; `-Wno-incomplete-patterns` in
  `Validators.hs:1`. Missing module Haddock: `Exceptions.hs`, `Transactions.hs`, `Validators.hs`,
  `Actions.hs`, `Core/Types.hs`, `Transfer/Types.hs`, `interaction-api/Main.hs`, `RestAPI.hs`,
  `admin/Main.hs`, `ServiceProbe.hs`. `Operations.hs` would split naturally into
  `Operations/{Profiles,Attestations,Disputes,Oracle,Cleanup}.hs` with `Operations.hs` re-exporting.
- Effort: S–M.

### OF-24 — Info — Auth and transport details
- `Auth.hs:42`: `constEq u eu && constEq p ep` short-circuits, so a wrong username returns faster
  than a wrong password (one shared credential; negligible, but `.&.` over the two results is free).
  `CORS.hs:72` exposes `Authorization` to scripts for no reason. Plain HTTP on `0.0.0.0` with no
  TLS guidance anywhere in `deploy/` or `README.md` §11; Basic credentials over HTTP are plaintext.
- Effort: S.

### OF-25 — Low — Undocumented concurrency constraints for clients
- `Operations.hs:42` (oracle by current ref), `:288,419,612` (seed UTxO), `:107` (user NFT spend).
  An oracle update invalidates every in-flight user transaction; two writes from one wallet must be
  serialised through `/tx-status`. Document in Swagger and the SPA, and have the API return
  `409 StateChanged`/`InputsSpent` when the provider reports a `BadInputsUTxO`-class rejection
  (part of OF-05).
- Effort: S (docs).

## 4. Reviewed and not an issue

- Output-index consistency for all seven operations (table in H1), including Mp6's "no user token
  at index 0" (the user token is only ever in change).
- Validity window ≤ `maxDateWindow` with a 2× margin; stored dates equal the closed lower bound;
  no wall-clock dependency (H2).
- Oracle reference input, pause gate and fee output on every mint path; required signers for
  Mp3/D1/O1/O5 (H3). `resolveDisputeTX` pays the deposit recorded in the datum, not the oracle's
  current price (`Operations.hs:739`), as the validator demands.
- `/build-tx` refuses all six `AdminActionType` constructors, pinned by
  `UnitTests/InteractionApi.hs:195-204` and `scripts/smoke_interaction_api.sh:98-103`.
- No `traceError`-capable on-chain function is called off chain (H6).
- Error bodies carry only `displayException` text; `show ex` is logged server-side only.
- `/submit-tx` witness handling: `getTxBody` keeps scripts/datums/redeemers, `makeSignedTransaction`
  replaces key witnesses, the node validates signatures; `keyWitnessesOf`/`txWitToHex` round-trip is
  pinned by `UnitTests/SignTx.hs:42-61`.
- Basic auth: constant-time compare, no UTF-8 decoding of attacker bytes, fail-closed env; CORS
  allowlist fail-closed (`ApiHardening.hs`).
- `reservedCollateral` honoured only when it is the 5-ADA UTxO wallets reserve, else framework
  selection (`Context.hs:93-94`).
- Maestro token: `interaction-api/Main.hs:75` prints `show atlasConfig`; Atlas wraps the token in
  `Confidential`, whose `Show` redacts (`ServiceStatus.hs:54-56` relies on the same). Not a leak,
  though logging the config at all is unnecessary (OF-22).
- Conversions total and arm-by-arm; JSON/Swagger enum spellings pinned by `UnitTests.Conversions`.
- `DatumParseError`/`OracleDatumInvalid` as 500 is right when the datum is ours; the problem is
  reaching them with client-chosen asset classes (OF-10), not the status.
- Md8 and D7 are tested on chain (`Dispute.hs` 6.8, `Pause.hs` 7.2); the gaps are off-chain.

## 5. What is done well

- The skeleton discipline: index tracking comments beside every `mconcat`, one validity helper, one
  oracle helper, the fee amount selected in exactly one function (`feeFor`) on both sides.
- `taggedSumSchema` and the enum-from-`ToJSON` pattern make the published document derive from the
  encoder; `UnitTests.InteractionApi` closes the loop against the committed Swagger.
- Admin actions are structurally unreachable over HTTP (a failing `FromJSON`), not filtered.
- `claimProofSkeleton` resolves the script-credential case *before* the balancer and returns a
  400 that names the fix; `parseClaimCredential` refuses CIP-105 for a stated reason.
- `keyWitnessesOf`/`txWitToHex` moved into the library so the signer is tested with the same code
  the server runs; `sign-tx` keeps stdout clean on purpose.
- `new-operator-key` refuses to overwrite, writes 0600, never prints the phrase, and validates the
  phrase through the same loader the deploy uses.
- `/status` separates "paused" from "oracle unreadable", and reports the provider family only.
- Negative tests exist for the rules the builders rely on (Mp3, Mq, Mf, Md4, Md8, D6, D7, O5).

## 6. Open questions for the owner

1. Who holds `BASIC_USER`/`BASIC_PASS`? If the SPA sends them from the browser, the credential is
   public and OF-07/OF-13 become unauthenticated exposures of the provider token's quota. If they
   are per-operator secrets, the explorer cannot call the write API at all — which is it?
2. Is TLS termination part of the deployment (ingress, proxy)? Nothing in the repo says so, and the
   smoke flow defaults to `http://localhost:8082` with Basic auth.
3. Should organisations acting through a script be supported end-to-end now (OF-12), or is "claim,
   then act from a key wallet" the intended product position for the first milestone?
4. Is `recipient` meant to exist? If so, for which operation — the only candidate flow is the
   returned deposit, which the datum fixes at open time.
5. `operation.prv` is the deploy key, the oracle admin, and the fee recipient's wallet in the smoke
   setup. Is a separate oracle-admin key (ideally hardware-backed, used only through the two-step
   rotation in OF-01) on the roadmap before mainnet?
6. Should a profile's `kind` be validated against the credential's HRP (OF-16), and should `cc_hot`
   be claimable at all?
7. Are the ~50 ADA/script locked by an always-fail reference address (OF-08) acceptable, or is a
   dedicated cold key preferred?

## 7. Improvement backlog (ranked)

| Rank | ID | Severity | Effort | Action |
|---|---|---|---|---|
| 1 | OF-02 | High | S–M | Default `deposit_to` to the user-NFT UTxO's address; force an input at the chosen address; 400 otherwise |
| 2 | OF-01 | High | M | Two-step `rotate-admin` (print partially-signed tx → `sign-tx` by incoming admin → submit) |
| 3 | OF-05 | Medium | M | Catch `SomeException`; split script failures / shortfall / provider / await into distinct codes and statuses |
| 4 | OF-04 | Medium | S | `getFeeSkeleton` returns `mempty` when `feeFor … <= 0`; property test against `checkFee` |
| 5 | OF-03 | Medium | S | Pause guard in `resolveDisputeTX` |
| 6 | OF-10 | Medium | S–M | Pure protocol-ref-token pre-check on every client asset class; authenticate dispute UTxOs in the duplicate check |
| 7 | OF-09 | Medium | M | `sign-tx` prints a summary and refuses oracle spends without an explicit flag |
| 8 | OF-07 | Medium | M | `/submit-tx` accepts only transactions touching protocol scripts (or ones the service built) |
| 9 | OF-08 | Medium | S | Lock reference scripts at an always-fail address; verify hashes in `/ready` |
| 10 | OF-13 | Medium | S | Request-size limit; cache `/ready` and `/status` probes |
| 11 | OF-14 | Medium | S | `deploy-reference-scripts` refuses to overwrite without `--force` |
| 12 | OF-11 | Medium | M | Script claims re-pay the spent UTxO to its address; hash-vs-witness pre-check |
| 13 | OF-06 | Medium | S | Remove `recipient` from the six requests (or implement it) |
| 14 | OF-12 | Medium | M–L | Decide and implement/document script-held authority after the claim |
| 15 | OF-15 | Low | S / M | Fix the `GYAddress` sentence; `ApiAddress` newtype accepting bech32 and hex; snake_case `UserAddresses` |
| 16 | OF-16 | Low | M | Role-aware credential rendering; refuse `cc_hot`; kind-vs-HRP check |
| 17 | OF-17 | Low | S | Correct the `deposit_to` Swagger text |
| 18 | OF-21 | Low | S | Oracle lookup by asset; single read per state UTxO |
| 19 | OF-20 | Low | S | Cap cleanup inputs; mirror `isUnbackedDatum` off chain |
| 20 | OF-18 | Low | S | Reuse `applyOracleAdminAction`; exhaustive status map |
| 21 | OF-19 | Low | S | Delete dead code; fix stale comments, license and version strings |
| 22 | OF-22 | Low | S | CLI: key only when signing, safe address parse, confirmations |
| 23 | OF-25 | Low | S | Document write serialisation and oracle-update invalidation for the UI |
| 24 | OF-23 | Info | S–M | Haddock, line length, partial-field pragmas, split `Operations.hs` |
| 25 | OF-24 | Info | S | Non-short-circuit auth compare; drop `Authorization` from exposed headers; document TLS |

## 8. Could not verify (no toolchain, Atlas not vendored)

- That `GYAwaitTxException` is not a `GYTxMonadException` constructor (OF-05c). The reasoning is
  from Atlas's `GeniusYield.Types.Providers`; the one-line check is `cabal repl` + `:i GYAwaitTxException`.
- That Atlas raises a 0-lovelace output to min-ADA rather than failing the build (OF-04). Either
  outcome is a defect (hidden fee vs unbuildable dispute); the fix is the same.
- That `GYTxSkeleton` de-duplicates reference inputs (irrelevant to the OF-03 fix proposed, which
  adds none).
- Whether Atlas's coin selection excludes reference-script UTxOs at the operator address (OF-08
  holds regardless: a non-Atlas wallet or a deliberate spend is enough).
- Whether `slotOfCurrentBlock` is cached between the two reads in `issueAttestationTX` (harmless
  either way, H2).
- Build and test status of HEAD; all test references above are to test *source*, not to a run.
