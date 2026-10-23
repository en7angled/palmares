# Reconciliation of the audit against `main` @ `2bf5bde` (2026-10-23)

The six reports in this directory were written against `4eb9117` (2026-10-22). `main` then advanced
**14 commits**, six of them after the drift table in [`README.md`](README.md) §9 was written. This
document re-judges **every** finding against the code as it stands, with evidence taken from `2bf5bde`
rather than from the snapshot.

**Method.** One pass per report, each confined to its own report and its own layer, none given the
others' conclusions; the on-chain report was reconciled by the session that wrote the six upstream
commits, which is why its notes name what the commits were trying to do. Unlike the original review,
this pass had a working Haskell toolchain, a running PostgreSQL, the pinned Atlas source tree and web
access — so several items the reviewers could only mark **VERIFY** are settled here, and some are
settled *against* the finding.

**Status vocabulary.** **OPEN** — still true, with the current `path:line`. **FIXED** — closed, with
the commit and the code that proves it. **PARTIAL** — one half closed, the other named. **MOOT** — the
code it describes no longer exists. **INVALID** — wrong when written, with the reason.

| | Rows judged | OPEN | PARTIAL | FIXED | MOOT | INVALID |
|---|---|---|---|---|---|---|
| 01 on-chain security | 23 | 15 | 4 | 3 | 1 | 0 |
| 02 off-chain and write API | 25 | 24 | 1 | 0 | 0 | 0 |
| 03 chain-sync and projections | 26 | 23 | 3 | 0 | 0 | 0 |
| 04 governance read path | 36 | 31 | 1 | 0 | 0 | 4 |
| 05 tests, CI and delivery | 20 | 18 | 2 | 0 | 0 | 0 |
| 06 docs, spec and product gaps | 59 | 52 | 6 | 0 | 1 | 0 |
| **total** | **189** | **163** | **17** | **3** | **2** | **4** |

Rows exceed findings because several findings have sub-items with their own verdicts.

**The one-line answer: the audit held.** Three findings are closed and four were wrong — out of 189
rows. The fourteen commits were on-chain design decisions, a warning sweep and tests; they touched
almost nothing this audit is about. Everything in `.dockerignore`, `compose.yaml`, the `Dockerfile.*`
files, `README.md`, `.env.example`, `NOTICE`, both ADRs and both deployment documents is **byte-identical
to the snapshot**, so those findings keep their line numbers as written.

---

## 1. [`01-onchain-security.md`](01-onchain-security.md)
Verified by reading the code at HEAD, not by trusting commit messages. `OC-02` and the structural half
of `OC-06` are the two the last 14 commits closed; the other thirteen stand.

| ID | Sev. | Status | Evidence |
|---|---|---|---|
| OC-01 | High | **OPEN** (impact reduced) | `Protocol/Types.hs:75` is still `opAdminPkh :: PubKeyHash`; `O1`/`O5`/`D1` unchanged. But the "every open deposit is locked forever" half is no longer true: `ExpireDispute` (`DisputesValidator.hs:197-200`) needs no key, so after `opDisputeTimeoutMs` anyone recovers the deposit |
| OC-02 | Medium | **FIXED** `26d53f7` | Exactly the prescribed fix: `attestationOracleToken :: AssetClass` at `Types.hs:445`, `traceIfFalse "A7" (not (opPaused oracle))` as the **first** conjunct at `AttestationsValidator.hs:139`. Cost estimate was wrong — see note 1 |
| OC-03 | Medium | **OPEN** (fix text now wrong) | all four sites still `checkTxOutAtIndexWithDatumMinValueAndAddress`: `ProfilesValidator.hs:161` (`P5`), `MintingPolicy.hs:316` (`Mk`), `AttestationsValidator.hs:164` (`A1`), `MintingPolicy.hs:469` (`Md5`). The fix proposes trace code `P8`, which ADR 0003 **burnt** (`ProfilesValidator.hs:164`) — it must pick a fresh code |
| OC-04 | Medium | **OPEN, relocated** | the role is still dropped, but the field moved: `profileCredential` is gone, `attestationCredential :: Maybe Credential` at `Types.hs:428` is the new home. Still rendered through `claimCredentialToText` → `drepIdCip129` for every credential (`Conversions.hs:124-125`, now also at `:237` for attestations). The "nothing on chain ties the role to the kind" argument is *stronger* now: an attestation has no profile kind at all |
| OC-05 | Medium | **OPEN** (one clause inverted) | `Mg`/`Md4` still only test `isProtocolRefToken` (`MintingPolicy.hs:228-229,467`). But "add `subject /= issuer`" is now wrong as written: `Mc1` **requires** `subject == issuer` for `CredentialClaim`/`CredentialWithdrawal` (`MintingPolicy.hs:308`), so the rule must be scoped to the other five kinds |
| OC-06 | Medium | **PARTIAL** | (1) admin-liveness **FIXED** `26d53f7`: `ExpireDispute` at `DisputesValidator.hs:195-201` + `D9` + `disputeStaleAfter` (`Types.hs:556`); the deposit returns on every outcome via the shared `disputeClosesWith`. (2)(3)(4) the three `depositTo` shapes that lose the deposit are **OPEN** and untouched (`MintingPolicy.hs:468` `Md8`) |
| OC-07 | Low | **OPEN** (fix text now wrong) | permissive `Cleanup` arms unchanged (`ProfilesValidator.hs:96`, `AttestationsValidator.hs:96`, `DisputesValidator.hs:107`). The fix proposes code `P9`, also **burnt** by ADR 0003 |
| OC-08 | Low | **OPEN** | `protocolParams` still in the profile datum; no validator reads a script hash from any datum — `ProfilesValidator` reads only `oracleToken (protocolParams profile)`. The false blueprint sentence is still there verbatim: `Blueprint.hs:200-201` "it reads the validator addresses it needs from the datum's protocolParams". ADR 0003 made this *proportionally* worse: with `profileCredential` gone the datum is `{profileId, profileKind, protocolParams}`, so the dead weight is now the majority of it |
| OC-09 | Low | **OPEN** | no version field; `ProtocolParams` unchanged at `Types.hs:24-38` |
| OC-10 | Low | **OPEN, premise changed** | `Mp3` is gone; the proof is now `Mc3` on a self-issued `CredentialClaim` whose whole visible purpose is the binding, which weakens the blind-co-signing scenario without closing it. Duplicate claims still permitted and still presented as `contested` (`Storage.hs:125`, `query-api/RestAPI.hs:1436`). **Its recommended remedy was built and then removed — see note 2** |
| OC-11 | Info | **PARTIAL** — 6 of 9 sub-items fixed | per sub-item below |
| OC-11a `Protocol/Id.hs` zero callers | | **FIXED** `3654f57` | file deleted |
| OC-11b `unsafeGetProfile*`, `K3` | | **FIXED** `3654f57` | gone; `K3` no longer exists |
| OC-11c dead `Utils`/`CIP68` helpers | | **PARTIAL** | `checkTxOutAtIndexWithDatumValueAndAddress`, `hasTxInAtAddressWithNFT`, `updateCIP68DatumImage`, `validateImageURI` deleted (now named-and-gone comments at `Utils.hs:76,129`, `CIP68.hs:10,13`). **Still dead:** `checkAndGetCurrentStateDatumAndValue` (`Utils.hs:445`), its only caller `checkAndGetInlineDatum` (`Utils.hs:452`, called only from the dead function at `:448`), and `hasCurrencySymbol` (`Utils.hs:465`) — so `U2` and `U3` remain unreachable |
| OC-11d `CLAUDE.md` `protocolParams` claim | | **OPEN** | `src/lib/onchain-lib/CLAUDE.md:33` unchanged; `:47` still prescribes `hasCurrencySymbol`, which no validator calls |
| OC-11e blueprint prose stale | | **OPEN and worse** | `opDisputeDeposit` still missing from the oracle datum description (`Blueprint.hs:371-377`); "Profiles and Attestations validator script hashes" still at `:132` and contradicts `:148-149`; the `profileCredential` omission is **MOOT** (field deleted, so the description is now accurate by accident). Four *new* omissions — see NEW-OC-2/3/4 |
| OC-11f Haddock misattachment | | **PARTIAL** | `isUnbackedDatum`/`valueAtOutputIdx` order fixed `3654f57` (`Utils.hs:355,433`). `MintAction` now has its own block (`Types.hs:244-253`) but **`data OnchainProfileKind` (`Types.hs:272`) is still undocumented** |
| OC-11g `checkDateInRange` future-dating | | **OPEN** | `Utils.hs:183` describes future-dating only as what the *old* check blocked; no comment states that the current rule **permits** future-dating by up to `maxDateWindow` |
| OC-11h stake credential claimable | | **MOOT** | the sentence lived on `profileCredential`'s Haddock and went with it; no "stake" claim remains in `Types.hs` |
| OC-12 | Info | **OPEN and sharper** | `O6` still runs only on updates; genesis writes the datum unchecked (`Transactions.hs:217-229`). The new field makes this concrete rather than hypothetical — see NEW-OC-1 |
| OC-13 | Info | **OPEN** | `Mj` unchanged; one attestation per transaction |
| OC-14 | Info | **OPEN** (narrowed) | pending spam unchanged for the five ordinary kinds; the two credential kinds cannot be used to spam a third party because `Mc1` forces self-issuance |
| OC-15 | Info | **OPEN** | `mkUntypedLambda` still `fromBuiltinData` on the whole context (`Utils.hs:60`) |

Checklist and hypotheses that moved: §3 rule 14 and §5 **(a)** are now FIXED (pause reaches acceptance);
§5 **(c)**'s recommendation is superseded (note 2); §5 **(o)**'s code census is stale — it lists
`Mp1-6`, `K1-K3`, `U0-U3` and 65 codes, where HEAD has **70**: no `Mp3`, no `K3`, plus `A7 D9 Da Mc1
Mc2 Mc3 Mc4`. §6 and §7 re-read and still true, except that §7's "Two-sided admin handover" is now
the only remaining admin-liveness dependency rather than one of two.

### Notes

**1. OC-02's cost estimate was out by ~5×, in the direction that matters.** The report estimated
"~100 script bytes"; measured, `A7` cost **+494** (`AttestationsValidator` 7640 → 8134,
`ScriptSize.hs:241`), because `A7` brought this validator's *first* oracle read — the lookup
machinery, not just a conjunct. The recommendation was right and was taken; the number was not. The
datum estimate was closer: "~33 bytes" against a measured +29 for the field
(`ScriptSize.hs:301`, a later round).

**2. OC-10/§5(c) recommended the thing we built and then deleted.** Hypothesis (c) proposes
"a `RevokeClaim` profile redeemer (`checkCredentialControl` again, writes `profileCredential =
Nothing`) so a holder can retire an old profile's claim". That is precisely decision D-E
(`800a39d`), and an independent audit of it found it **more dangerous than the problem**: it took the
same weak proof the claim took and its effect was irreversible, severing a credential from its whole
track record with no redeemer able to set it again. ADR 0003 (`6d0a76a`) removed it and replaced it
with an append-only `CredentialWithdrawal` attestation. The reviewer's instinct — give the holder a
remedy — was right; the shape they proposed was the one that had to be thrown away. Recorded in
`docs/adr/0003-credential-claim-as-attestation.md`.

### Findings I judge wrong

- **None are factually wrong.** Every `OC-` finding I checked was true of the code at the snapshot,
  and the two the reviewers marked as needing a decision were the two the owner then decided.
- Three *recommendations* are now unusable as written and need one line changed each: `OC-03` and
  `OC-07` propose trace codes `P8`/`P9` that ADR 0003 burnt, and `OC-05` proposes `subject /= issuer`
  globally where `Mc1` now requires the opposite for two of the seven kinds.
- One *severity argument* is now overstated: `OC-01`'s "every open dispute's deposit is locked
  forever" no longer follows from key loss, because `ExpireDispute` needs no key. The finding stands
  on pause/fees/verdicts; the deposit clause should be struck.
- §5(o) and the §2 per-script tables are stale rather than wrong — they describe `4eb9117`.

### New findings

**NEW-OC-1 — `opDisputeTimeoutMs = 0` is well-formed and voids the dispute mechanism.** Medium.
`oracleParamsAreWellFormed` checks `opDisputeTimeoutMs params >= 0` (`Types.hs:210`), and the comment
directly above it (`:207-209`) says a timeout that puts `disputeStaleAfter` in the past "voids the
dispute mechanism with one keystroke". Zero does exactly that: `disputeStaleAfter = openedAt + 0`,
and `Md6` already forces `openedAt` into the validity range, so every dispute is stale the moment it
opens and anyone may close it as `VerdictExpired` in the next block — deposit returned, no decision
ever recorded. The guard admits precisely the value its own comment argues against. One admin action
(`OracleSetDisputeTimeout 0`) reaches it, and `O6` runs on updates, so this is live, not only a
genesis risk. Fix: `> 0`. **This is a defect in code added this session, not inherited.**

**NEW-OC-2 — the published blueprint's minting redeemer is missing an argument and a constructor.**
Low (contract hygiene, but the blueprint is what clients generate from). `Blueprint.hs:163` lists
`NewAttestation seedTxOutRef metadata otherMetadata subject issuer kind date claimedPeriod outputIdx`
— ADR 0003 inserted a `Maybe Credential` before `outputIdx`, so the published arity is wrong. The
same description documents `NewAttestation` and `OpenDispute` and **never mentions `MintProfile`**,
which was already true at the snapshot and which report 01 did not catch.

**NEW-OC-3 — the blueprint does not mention `ExpireDispute` or `VerdictExpired`.** Low.
`Blueprint.hs:310-313` describes `ResolveDispute` and `Cleanup` only, and names `VerdictUpheld`/
`VerdictRejected`. The one path that closes a dispute without the admin — the answer to `OC-06`(1) —
is absent from the published contract, as is the third terminal verdict.

**NEW-OC-4 — the blueprint's oracle datum omits two of its six fields.** Low.
`Blueprint.hs:371-377` lists admin pkh, pause flag, min-UTxO and fee config: `opDisputeDeposit` was
already missing (report 01 caught it) and `opDisputeTimeoutMs` is newly missing. The second is the
field that decides when anyone may close a dispute.

**NEW-OC-5 — `Protocol/Lookup.hs:7` asserts a call that does not exist.** Info. Its Haddock says
every validator reads a profile "through `Utils.checkAndGetCurrentStateDatumAndValue` directly".
`git grep checkAndGetCurrentStateDatumAndValue -- src` finds the definition, the export and two
comments, and no caller. So the sentence is false, the helper is dead, and `U2`/`U3` are unreachable
— exactly as `docs/architecture/onchain-protocol.md` §8 states. The claim was introduced by
`3654f57`, the commit whose subject was deleting dead code. (This is the claim the reconciliation
brief asked me to check: **confirmed**.)

---

## 2. [`02-offchain-and-write-api.md`](02-offchain-and-write-api.md)
Snapshot `4eb9117` → HEAD `2bf5bde` (14 commits). Verified by reading the worktree; Atlas 0.14.1
(tag `bf0d2d1`, the exact pin) was read from the hie-bios source cache, which closed four of the
report's five "could not verify" items. Nothing was built.

**Headline: not one finding in this report is closed.** The 14 commits are on-chain decisions
(D-C, D-A, ADR 0003), a warning sweep and tests; the only one that touches this report's list is
`3654f57`, which closed part of OF-19's dead-code half. Three findings got *worse* in the drift
(OF-06, OF-21, OF-23) and two now carry a recommended fix the drift invalidated (OF-13, OF-16).

| ID | Sev. | Status | Evidence |
|---|---|---|---|
| OF-01 | High | OPEN | `src/exe/admin/Main.hs:614-618` still `runActionWithPK` (one key, `Transactions.hs:134`); no `submit-tx`/`add-wit` command in `Command` (`:62-84`); `TestRuns.hs:1132` still says `adminInteraction` "signs with exactly one key" |
| OF-02 | High | OPEN | `Interactions.hs:158` still `fromMaybe (changeAddress userAddresses) mDepositTo`; `Md8` unchanged at `MintingPolicy.hs:468` |
| OF-03 | Medium | OPEN | `Operations.hs:854` reads `queryOracleParams` and never `opPaused`; `:823-828` still admits the defect verbatim. D-C's `A7` gave accept the off-chain gate, so this is now the **only** write that hands back a tx the chain refuses as `D7` |
| OF-04 | Medium | OPEN | `Operations.hs:65-71` builds `lovelace 0` for any `Just feeConfig`; `checkFee` short-circuits at `Lookup.hs:84-89`. The hedge resolves: Atlas `adjustTxOut` (`Transaction/Common.hs:182-194`) raises it, applied to every declared output at `Transaction.hs:293`. `Operations.hs:795` "always empty" still false |
| OF-05 | Medium | OPEN (a, b, c) | (a) `InteractionAppMonad.hs:92`; (b) `:78-97` patterns still fix `try` at `GYTxMonadException`; (c) **confirmed** — `GYAwaitTxException` is a standalone `newtype` at `GeniusYield/Types/Providers.hs:293`, not a `GYTxMonadException` constructor (`TxBuilder/Errors.hs:104-125`), so `:130` cannot catch it |
| OF-06 | Medium | OPEN, worse | `Interactions.hs:95` still binds `recipient` unused; the field is now on **nine** request types, not six (`ServiceRequests.hs:53,79,110,142,172,210,245,278,305`) |
| OF-07 | Medium | OPEN | `RestAPI.hs:103-107` unchanged; `config/config_atlas.example.json:4` still `turboSubmit: true` |
| OF-08 | Medium | OPEN | `Transactions.hs:148,152` still lock at `my_addr`; `verifyDeployedScriptsAreReady` (`Operations.hs:137-140`) still only `all isJust`. Hedge resolves in the report's favour: Atlas *does* exclude ref-script UTxOs from own-UTxOs (`TxBuilder/Common.hs:253`), so only a non-Atlas wallet or a deliberate spend eats them |
| OF-09 | Medium | OPEN | `admin/Main.hs:866-881` — reads `operation.prv`, signs stdin, no summary, no `--yes`, no oracle-spend guard |
| OF-10 | Medium | OPEN (both) | `Lookups.hs` has **zero diff** since `4eb9117`: (a) `:48-52`, (b) `:208-214`. Fix still implementable — `isRefTokenName` (`CIP68.hs:211`) and `getMintingPolicyHash` (`Context.hs:35`) both exist |
| OF-11 | Medium | OPEN, relocated | `Operations.hs:249-257` picks the first spendable UTxO, no re-pay output, no hash/witness compare, no datum-hash skip; the caller is now `credentialAttestationTX:531`, not `claimProfileTX`. Wider: a `CredentialWithdrawal` spends no profile token (`:535-539`), so the drain needs only the script's own witness |
| OF-12 | Medium | OPEN | All four `txMustSpendFromAddress` call sites still pass `GYTxInWitnessKey` (`Operations.hs:117,193,539,627`), so the `Skeletons.hs:123-124` claim is still a choice no caller makes; `claimProfileTX` still pays the user token into change (`:267-268`) |
| OF-13 | Medium | OPEN; fix needs amending | `interaction-api/Main.hs:71` still bare `defaultSettings`, no `setServerName`; `/ready` 5 × `utxoAtTxOutRef` (`Operations.hs:125-140`), `/status` those plus one (`ServiceStatus.hs:92-93`), no cache, no auth. `a9bfd71` removed `wai-extra` from the executable, so the fix must re-add it |
| OF-14 | Medium | OPEN | Two unguarded `B.writeFile Constants.defaultTxBuildingContextFile` sites now, `admin/Main.hs:563` and `:583`; `new-operator-key`'s refusal pattern (`:780-786`) still not applied |
| OF-15 | Low | OPEN, worse | `webapi-lib/.../Utils.hs:44` unchanged; committed `docs/generated/swagger/interaction-swagger-api.json:221` still carries it; `admin/Main.hs:855-856` is now a **third** place blaming "the generated Swagger" for this repo's own line |
| OF-16 | Low | OPEN; fix now wrong | `Conversions.hs:123-125` still renders every credential `drep`; `Ids.hs` HRP accept-set unchanged. One cited location is MOOT (`Operations.hs:275` — `claimProfileTX` takes no credential), and the fix is now unimplementable as written: see below |
| OF-17 | Low | OPEN | `ServiceRequests.hs:262` still ships "pointing it somewhere useless costs only the disputer", contradicted at `Actions.hs:340`, `Protocol/Types.hs:525-527`, `MintingPolicy.hs:130` |
| OF-18 | Low | OPEN; one citation wrong | `Operations.hs:1019-1026` still re-implements `Protocol/Types.hs:169-176` field by field (both now 7 arms, `OracleSetDisputeTimeout` added to each); `Exceptions.hs:168` still `_ -> 400`. Its `Envelope.hs:161-163` citation names misattached Haddock (NEW-OF-5) |
| OF-19 | Low | PARTIAL | Closed by `3654f57`: `hasUserNFTAt`, `Onchain/Protocol/Id.hs` (deleted), `Protocol/Lookup.hs` `unsafeGet*`. Still dead: `Lookups.hs:101-114`, `:220-242`, `Skeletons.hs:114-115,174-175,177-180`, `TxBuilding/Utils.hs:49-56,120-122`, `Validators.hs:185-201`+`Constants.hs:11-24`, `admin/Main.hs:211-220`, `Transfer/Types.hs:52-90` (verified zero consumers). Stale text all still there: `Operations.hs:1`, `Skeletons.hs:46`, `RestAPI.hs:243` GPL-3.0 vs `LICENSE` Apache-2.0, `info.version` now 3.1.0 vs `appVersion = "1.0.0"` (`Constants.hs:31`) |
| OF-20 | Low | OPEN | `Operations.hs:1053-1067` still unbounded; `getDustUTxOs` (`Lookups.hs:148-156`) still "no token of our policy", no `isUnbackedDatum` mirror |
| OF-21 | Low | OPEN, worse | `Lookups.hs:128-131` still `utxosAtAddresses [oracleAddr]`; double reads at `Operations.hs:177/190`, `621/650`, `842/865`, and `expireDisputeTX` adds a **fourth** at `913/933` |
| OF-22 | Low | OPEN (all four) | `admin/Main.hs:893-894` reads the key for `query-oracle` against `src/exe/CLAUDE.md:12`; `unsafeAddressFromText` at `:539`; no `--yes` at `:586-589,614-618`; config echoed at `interaction-api/Main.hs:75-76`. `307b534` (which §9 flagged) fixed a non-exhaustive `case`, which is none of these bullets |
| OF-23 | Info | OPEN, worse | Pragmas at `Actions.hs:1`, `Transfer/Types.hs:1`, `Validators.hs:1`; snake_case at `Actions.hs:238-310`; all 10 listed modules still lack module Haddock; `Operations.hs` now 1067 lines / 359 comment lines (34 %, was 20 %), 11 over 120 chars, `admin/Main.hs` 18 (was 15) |
| OF-24 | Info | OPEN | `Auth.hs:42` still short-circuiting `&&`; `CORS.hs:72` still exposes `Authorization`; `interaction-api/Main.hs:68-71` still plain HTTP on `0.0.0.0` |
| OF-25 | Low | OPEN | `Operations.hs:49` oracle by current ref, seeds at `:290,413,544,732`, user NFT at `:117`; no `409`, and no doc outside this audit mentions `StateChanged`/`BadInputsUTxO` |

### Findings I judge wrong

- **OF-16's recommended fix is no longer implementable as written.** "Derive the HRP from
  `profileKind` when rendering" and "validate HRP against kind" both assume the credential sits on
  the profile. ADR 0003 (`6d0a76a`) moved it to `OnchainAttestation.attestationCredential`, which
  carries no profile kind — `onchainAttestationToAttestation` renders it at `Conversions.hs:237`
  with no kind in scope, and `credentialAttestationTX` never reads the profile datum (it only calls
  `ensureSubjectProfileExists`, existence-only by design). Any kind-aware rendering now needs a
  profile lookup that neither site does today. The substance of the finding (role dropped, `cc_cold`
  echoes as `drep`, `cc_hot` claimable) stands.
- **OF-18's `Envelope.hs:161-163` citation points at the wrong function.** The prose it invokes as
  its authority ("a `case` and not a lookup table with a fallthrough") is misattached Haddock — see
  NEW-OF-5. The argument against `Exceptions.hs:168`'s `_ -> 400` survives; the citation does not.
- **No finding in this file was wrong when written.** I tried to break several and failed: OF-04's
  `checkFee` zero-fee short-circuit, OF-05's exception typing, OF-10's 500-on-client-mistake path,
  OF-13's ~43k calls/day arithmetic and OF-19's `Transfer/Types.hs:52-90` dead-DTO claim (zero
  consumers, verified by grep) all check out. Two of the report's own hedges resolve in its favour
  (OF-04's min-ADA raise, OF-05c's `GYAwaitTxException`) and one against its worst case (OF-08:
  Atlas will not eat the reference scripts by accident).

### New findings

- **NEW-OF-1 — Medium — `/claim-profile` still advertises the `credential` and `witness` ADR 0003
  deleted.** `ServiceRequests.hs:66-70`: the schema description tells clients "`witness` says how
  the input that proves control of `credential` is spent; both are omitted for an unclaimed
  profile", and `& describeField "credential" …` targets a property that no longer exists —
  `describeField` is `at field . mapped`, so a missing key is a silent no-op. `RestAPI.hs:129`
  repeats it in the route description. Measured in the committed document:
  `interaction-swagger-api.json` `ClaimProfileRequest.properties` is exactly
  `[description, image_uri, kind, name, recipient, user_addresses]`. A client written against the
  published contract sends two fields the server ignores and never calls `/claim-credential`, so the
  binding silently never happens. One line to delete, one sentence to rewrite.
- **NEW-OF-2 — Medium — the shared `AttestationType` description is stale and its last sentence is
  now false.** `webapi-lib/.../Utils.hs:53-59` enumerates five spellings and stops at
  `endorsement`, while the published `enum` carries seven (`credential_claim`,
  `credential_withdrawal` — verified in both swagger documents), and it ends "No validator branches
  on it: the kind says what a reader is being told, not what the protocol permits." `Mf`
  (`MintingPolicy.hs:304`) and `Mc1`–`Mc4` (`:308-311`) all branch on the kind. The row lives in
  `addSharedSwaggerDescriptions`, so it is wrong in the interaction **and** query documents.
- **NEW-OF-3 — Medium — `/issue-attestation` accepts the two credential kinds and hands back a
  transaction the chain refuses.** `iarKind :: AttestationType` (`ServiceRequests.hs:99`) admits all
  seven constructors (`Core/Types.hs:143-162`, `Enum, Bounded`, published enum lists seven);
  `issueAttestationTX` passes the kind straight into the redeemer and hard-codes `Nothing` for the
  credential (`Operations.hs:438,460`); `Mc2` (`MintingPolicy.hs:309`) refuses a credential kind
  that names none. There is no off-chain guard, unlike every sibling rule the builders mirror
  (`AttestationPeriodInverted`, `DisputeVerdictNotAFinding`, `DisputeNotStaleYet`,
  `AttestationAlreadyAccepted`), so the failure arrives as a script error and is reported as
  `400 InsufficientFunds` by OF-05a. `admin issue-attestation --kind` advertises both spellings too,
  because its help is derived from `[minBound .. maxBound]` (`admin/Main.hs:180`). Symmetrically,
  `credentialAttestationTX`'s own Haddock says of its kind argument "anything else is a caller
  error" (`Operations.hs:506`) and nothing enforces that either. Fix: one guard in each builder
  mirroring `Mc4`/the kind contract, with a new 400.
- **NEW-OF-4 — Low — `ProfileClaimsNoCredential` is a dead exception whose Haddock cites a burnt
  trace code.** `Exceptions.hs:74-79` and `:131`. ADR 0003 removed `revokeCredential`, its only
  thrower (grep: zero throw sites), and the Haddock still says "@P8@ refuses it on chain as well"
  while `ProfilesValidator.hs:164-168` records that `P8`/`P9` are gone and deliberately not reused.
  It also quietly enlarges OF-18's fix: making the status map exhaustive would add an arm for a
  constructor that should be deleted instead.
- **NEW-OF-5 — Info — `Envelope.hs:160-164`'s Haddock is stranded on the wrong function, and it is
  the opposite of true there.** Two `-- |` blocks sit back to back (`:160-164` and `:165-172`) with
  one declaration after them, so "The status each code is served with … a `case` and not a lookup
  table with a fallthrough" attaches to `errorCodeFromText` (`:173-179`), which is literally
  `fromMaybe InvalidParameter (lookup …)`; `errorCodeToHttpStatus` (`:181`) ends up with no Haddock
  at all. `Envelope.hs` has had only its imports touched since `4eb9117`, so this pre-dates the
  snapshot — an audit miss rather than drift, and it is the line OF-18 cites as its authority.
- **NEW-OF-6 — Info — three constructor counts the drift made false.** `Core/Types.hs:137` says
  `AttestationType` is "the off-chain mirror of … `AttestationKind`, same five constructors in the
  same order" (there are seven); `Core/Types.hs:181-182` says "a sixth attestation kind becomes
  parseable and documented"; `admin/Main.hs:172` says "a sixth kind appears here by itself". All
  three were written when five was right. `Operations.hs:1`'s module line is the mirror image — it
  still lists the Belt System's "ranks, memberships" (OF-19) and now also omits the credential
  bindings and the dispute expiry that `6d0a76a` and `26d53f7` added.

---

## 3. [`03-chainsync-and-projections.md`](03-chainsync-and-projections.md)
Snapshot cited by the audit: `4eb9117`. Worktree HEAD: `b78767f` (merge of `2bf5bde` into `docs/audit-2026-10-22`).

Files the drift touched that this report depends on: `Storage.hs` (+41/-4), `Ingestion.hs` (+17/-10),
`Conversions.hs` (+10), `sql/050_roles.sql` (+20), `Query/Gov.hs`, `Query/ServiceStatus.hs`,
`QueryResponses.hs`, `Protocol/Types.hs`, `MintingPolicy.hs`, `ProfilesValidator.hs`, tests.
**Unchanged since the snapshot**, so every line cite into them still resolves:
`src/exe/attest-sync/{Main,ChainSyncLogic,ChainsyncAPI}.hs`, `src/lib/chainsync-lib/**`,
`src/exe/query-api/Query/Attest.hs`, `compose.yaml`, `Dockerfile.attest-sync`, `.env.example`,
`README.md`, `Constants.hs`, `.dockerignore`.

| ID | Sev. | Status | Evidence |
|---|---|---|---|
| CS-01 | Critical | OPEN | `Conversions.hs:227` still `bimap timeFromPlutus timeFromPlutus attestationPeriod`; `Storage.hs:151-152` are `(Maybe GYTime)` → `timestamptz` via `Storage.hs:65-66`; `MintingPolicy.hs:109` still "carries NO check" and `Mq` (`:288`) bounds only `attestationDate`; no `try` on `ChainSyncLogic.hs:125-127` / `Main.hs:143` |
| CS-02 | High | OPEN | `ChainSyncLogic.hs:35-36` unchanged (header consulted only on slot equality); `KupoClient.hs:279` `kupoCheckpointBySlot` still has zero callers outside its module |
| CS-03 | High | PARTIAL | Grant half FIXED by `5d50895` (`sql/050_roles.sql:111` adds the un-scoped `ALTER DEFAULT PRIVILEGES`, killing the ownership trap); compose service and `palmares_owner` DSN halves OPEN — `grep attest-sync compose.yaml deploy/` is empty, `Dockerfile.attest-sync:55` still `user=postgres` |
| CS-04 | Medium | OPEN | `Storage.hs:525` `deleteWhere [OnchainMatchEventCreatedSlot >. slot]`; `Ingestion.hs:88` `isJust amSpentAt = return (NoEvent am)`; nothing passes the rollback slot into the replay (`Storage.hs:533`) |
| CS-05 | Medium | OPEN | `ChainSyncLogic.hs:110-114` still `Left _err` + fixed 10 s; `Main.hs:143` bare `forever`; `ChainsyncAPI.hs:60-63` verdict reads only `smChainSyncState`; `KupoClient.hs:218` new `Manager` per call |
| CS-06 | Medium | OPEN | `Main.hs:103-108` unchanged; v3→v4 (`Storage.hs:278`) makes the `DROP TABLE … CASCADE` the *normal* upgrade path — see NEW-CS-7 |
| CS-07 | Medium | PARTIAL | Wire half FIXED (`ServiceStatus.hs:84` + `QueryResponses.hs:581` publish `attest_lag_seconds`; `Gov.hs:360` sums the lags). Silent-absence, green-during-first-sync and docs halves OPEN: `Gov.hs:360` guard is `Just lag <-`, no `PALMARES_EXPECT_ATTEST`; `attest-flow-smoke.md:138` + `smoke_attest_flow.sh:143,157` still say neither service reports the lag |
| CS-08 | Medium | OPEN | `Main.hs:139` still `putStrLn "Kupo: configured"`; `ChainSyncLogic.hs:93-108` has no health or range check; `kupoHealth`/`kupoMetrics` (`KupoClient.hs:302,326`) still uncalled |
| CS-09 | Medium | OPEN | `Main.hs:84-94` takes the policy from config only; `Ingestion.hs:89-107` compares against compiled validator hashes; no cross-check, no address log |
| CS-10 | Medium | OPEN | `Storage.hs:286-290` `upsertByUnique` is still `getBy` then `insert`/`replace`; no advisory lock in `Main.hs:101-170` |
| CS-11 | Low | OPEN | `Main.hs:137` `matchPattern = policyHexText <> ".*"`; `Storage.hs:360-362` stores every match unconditionally; `Storage.hs:532-533` replays all surviving rows |
| CS-12 | Low | OPEN | `Main.hs:114` default `10_000_000` vs `100000` at `README.md:152`/`.env.example:20`/`Dockerfile.attest-sync:57`; `BATCH_SIZE` documented in all three and `grep '"BATCH_SIZE"' src/` is empty; `CLAUDE.md:60` and `src/exe/CLAUDE.md:47` still route to `Query/Projected.hs` (uncompiled, `palmares.cabal:366`) and call it esqueleto; `src/exe/CLAUDE.md:55` names `Query/Metrics.hs`, which does not exist; `Common.hs:161-169` |
| CS-13.1 | Low | OPEN | `QueryResponses.hs:1818-1833` `AttestationRow` has no `open_disputes`/`contested`; `/disputes` takes one `target` (`RestAPI.hs:1529`) |
| CS-13.2 | Low | OPEN | `AttestationsValidator.hs:19,31` lineage/"pending" comment intact; no `subject_kind` anywhere in `Query/Attest.hs` |
| CS-13.3 | Low | OPEN | `Protocol/Types.hs:413` still prescribes `claimed_period` beside `issued_at`; `QueryResponses.hs:1823` publishes `attestationRowDate` → `date` |
| CS-13.4 | Low | OPEN | `RestAPI.hs:896` still "`profiles` and `attestations` are always empty here and are filled over the attestation schema later" |
| CS-13.5 | Low | OPEN (citation stale) | `QueryResponses.hs:1785` still says "nothing on chain checks that the claimant controls the credential"; `Mp3` is gone but `Mc3` (`MintingPolicy.hs:310`, `Utils.hs:326-334`) now proves control, so the comment is still false |
| CS-14 | Low | OPEN | `Storage.hs:118-121` (slot is the only time a row carries); `ProfileProjection`/`DisputeProjection` still have no tx pointer (`Storage.hs:128-138,164-177`); `Attest.hs:211` sorts `registered_at` on `created_at_slot`; `QueryResponses.hs:1775` |
| CS-15 | Low | OPEN | `Storage.hs:252-255` `runMigrations` still adds only `profile_projection_credential_idx`; `Attest.hs:327` filters `attestation_kind`, nothing indexes it |
| CS-16 | Low | OPEN | `Main.hs:79` `runStdoutLoggingT`; `Dockerfile.attest-sync:51` `COPY ./config /app/config`; `.dockerignore:20` excludes only `config/*.prv`; `Main.hs:135` unlinked `forkIO`; `KupoClient.hs:218` |
| CS-17 | Low | PARTIAL | Gaps still real: every DB fixture has `spent_at = Nothing` (`Projections.hs:296`, `StorageRoundtrip.hs:48`, `ChainSyncReplay.hs:48`); no hostile period (`Projections.hs:145,168` both `Nothing`); no wipe-decision test; `ChainSyncLogic` unimportable (`palmares.cabal:444` vs `:479`). The `readyVerdict`/attest-lag sub-gap is INVALID — see below |
| CS-18.a | Info | OPEN | `KupoAtlas.hs:61` matches `(Nothing, Just dh, Just "hash")`; a resolved hash datum falls to `GYOutDatumNone` at `:64` |
| CS-18.b | Info | OPEN | `KupoAtlas.hs:89` `mapM (maybeToEither "Invalid spent input index") (spent_input_index <$> spent_at)` fails the whole conversion on a null `input_index` |
| CS-18.c | Info | OPEN | `Storage.hs:93-94` columns; `ChainSyncLogic.hs:47` writes `Nothing Nothing` |
| CS-18.d | Info | OPEN | `QueryResponses.hs:1854` `disputeRowId :: Core.AttestationAC` |
| CS-18.e | Info | OPEN | `Main.hs:164,170` `KupoCheckpoint rollbackSlot ""` |

### Findings I judge wrong

- **CS-17, sub-gap "no `readyVerdict` case with `readyAttestLagSeconds` (grep finds none under `src/test`)" — INVALID, wrong when written.** At the snapshot itself, `git show 4eb9117:src/test/UnitTests/GovDto.hs` lines 264-266 and 273-276 hold five `readyVerdict` cases carrying `(Just 42)`, `(Just 301)` and `Nothing` in the `readyAttestLagSeconds` position. The grep returned nothing because those tests build `ReadyInputs` **positionally**, never naming the field. The auditor grepped a record selector and concluded the behaviour was untested. (At HEAD the coverage is larger still: `GovDto.hs:290-312`.)
- **CS-13.5 — substance holds, citation stale.** It argues the DTO comment contradicts `Mp3`. ADR 0003 (`6d0a76a`) deleted `Mp3` entirely. The comment is nonetheless still false, now because of `Mc3`, so I kept it OPEN rather than MOOT — but any fix must not go looking for `Mp3`.
- **CS-15's "only the three `Unique*` ids and `profile_credential` are indexed" undercounts.** `persistLowerCase` also emits `UniqueKupoMatch` over `(created_slot, created_header, created_tx_id, created_output_index)` (`Storage.hs:114`), whose leading column is what `rollbackTo`'s `deleteWhere` scans, plus the two singleton uniques. The finding's substance (read-side filter/sort columns unindexed) is unaffected.
- **README §9's instruction to re-judge CS-05 against `5978d28`'s "probe arithmetic" conflates two probes.** CS-05's green probe is attest-sync's own `/ready` (`ChainsyncAPI.hs:57-63`), which `5978d28` did not touch; the commit changed query-api's `/ready`, which is CS-07's. CS-05 is unchanged in every part.

### New findings

- **NEW-CS-1 — High — the ADR 0003 credential derivation is not replay-safe, and schema v4 forces the replay.**
  `Storage.hs:489-493` applies a `CredentialClaim` with `updateWhere [ProfileProjectionProfileId ==. subject]`, which is a **silent no-op when the profile row does not exist yet**. A profile row only exists for the profile's *latest unspent* UTxO, because `Ingestion.hs:88` returns `NoEvent` for any match carrying `spent_at`. So on any replay (`Storage.hs:522-533`) or fresh sync, a profile that was `UpdateProfile`d (`ProfilesValidator.hs:54`) *after* its claim replays as: pre-update profile UTxO → `NoEvent`; claim → `updateWhere` matches 0 rows, credential dropped; post-update profile UTxO → inserted with `credential = Nothing` (`putProfileProjection`'s carry-over at `Storage.hs:414` finds nothing to carry). `profile_credential` ends NULL while the chain says bound. Forward sync is fine, which is why the three new tests pass: `Projections.hs:419,429,438` all apply the profile match *first*. The v3→v4 bump (`Storage.hs:278`) makes a full re-sync mandatory on this very upgrade, so this fires on deploy, not hypothetically. Fix: order-independent derivation (recompute the column from `attestation_projection` after the replay, or insert a placeholder profile row), plus the missing fixture — a `kupoMatch` with `spent_at` set, which no test has (`Projections.hs:296`).
- **NEW-CS-2 — Medium — `attestation_credential` is written and never published.** The column exists (`Storage.hs:149`), is pinned by the tripwire (`AttestSchema.hs:137`) and is written (`Storage.hs:469`), but `AttestationRow` (`QueryResponses.hs:1818-1833`) has no credential field and `Query/Attest.hs` (unchanged since the snapshot) never selects it. A `GET /attestations?kind=credential_claim` row therefore arrives with no credential in it: the append-only claim/withdrawal log that ADR 0003 made the source of truth is unreadable, and only the derived `profile_credential` survives — the one value NEW-CS-1 can lose.
- **NEW-CS-3 — Low — `disputeStaleAfter` has no projection and no read surface.** Added to the datum by D-A (`Protocol/Types.hs:556`) and gating `D9` (`DisputesValidator.hs:198`), it is absent from `ProjectedDispute` (`Ingestion.hs:35-46`) and from `DisputeProjection` (`Storage.hs:164-177`, column count pinned at 12 by `AttestSchema.hs:159`). No client can tell when a dispute becomes closable by anyone, and a `verdict: expired` row carries no deadline to explain it. Not a CS-01 vector: the value is computed on chain (`MintingPolicy.hs:458`), not attacker-supplied.
- **NEW-CS-4 — Low — false comment, `Storage.hs:122`.** "profileCredential is the CIP-129 rendering of the credential **the datum claims**" — ADR 0003 deleted `OnchainProfile.profileCredential`; the column is derived from the attestation stream. The rest of that paragraph (non-unique index, contested) is still right, and `putProfileProjection`'s own Haddock at `:405-410` already says the opposite of line 122.
- **NEW-CS-5 — Low — false comment, `Gov.hs:498-503`.** It says publishing the projector's lag on `/status` "means a field on the `/status` body, which is a DTO change, a Swagger version bump … a follow-up, deliberately not smuggled in here. Until then the only signal for an unreadable cursor is the stderr line below." `9a8d79b` shipped exactly that field (`ServiceStatus.hs:84`, `QueryResponses.hs:581`, Swagger 1.1.0). The preceding sentences about absence being silent are still accurate.
- **NEW-CS-6 — Info — ADR 0003 left duplicated/incomplete Haddock in `Storage.hs`.** Two consecutive `-- |` one-liners on `putProfileProjection` (`:402` and `:403`, the first a stale leftover), and `currentSchemaVersion` carries two stacked `-- |` blocks (`:257` and `:273`) where the version bullet list stops at `* v3:` and v4 is described only in the second block.
- **NEW-CS-7 — Medium — the v3→v4 bump turns CS-06's unguarded wipe into the upgrade path.** `storedVersion < currentSchemaVersion` is now true for every existing database (`Main.hs:105`, `Storage.hs:278`), so the first boot at HEAD executes `DROP TABLE … CASCADE` over all six tables including `onchain_match_event` and `chain_cursor` (`Storage.hs:307-321`) after one `putStrLn`. Two consequences the audit's CS-06 only described as an accident: (a) with the Kupo "fast path" `KUPO_SINCE=<tip>` (`compose.yaml:196-202`) the dropped raw log cannot be rebuilt, so the re-sync ADR 0003 *requires* is the thing that destroys the history; (b) the dropped `chain_cursor` makes `attestCursorSlot` report `Nothing` (`Storage.hs:216-222`), so `/ready` is green and `/status.attest_lag_seconds` is `null` for the whole re-sync (`Gov.hs:360` passes on absence) while `/profiles` serves confident partial pages — CS-07's worst case, now scheduled rather than hypothetical.

### Verdict on the three directed items

1. **CS-01 end to end at HEAD: OPEN, mechanism fully intact, and the new code adds no further vector.**
   `Conversions.hs:227` → `Storage.hs:151-152` (`timestamptz`) → `ChainSyncLogic.hs:125-127` (one
   transaction per window, no `try`) → `Main.hs:143` (bare `forever`) → `Main.hs:159` (cursor after the
   whole range). `MintingPolicy.hs:109` still states the period carries no check and `Mq` (`:288`)
   bounds only `attestationDate`. Schema-4 additions are clean: `attestation_credential` is `text`, and
   `Mc3` bounds it to 28 bytes because `checkCredentialControl` (`Utils.hs:326-334`) compares against real
   signatories or a real input's payment credential; `claimCredentialToText` is total
   (`Ids.hs:52-56` uses `Bech32.encodeLenient`, no length error). `disputeStaleAfter` is a new `POSIXTime`
   but reaches no column, and is computed on chain anyway (`MintingPolicy.hs:458`). `deposit :: Integer`
   is still oracle-bounded (`MintingPolicy.hs:187,452`). One aggravation worth noting: with
   `FETCH_BATCH_SIZE`'s *code* default of `10_000_000` slots (`Main.hs:114`) the "window" is the entire
   chain, so one poison match aborts a single transaction covering everything.
2. **The new derivation arms are neither rollback-safe nor replay-safe → NEW-CS-1 (High), and yes, it is a new finding.**
   Rollback is safe only in the trivial sense that `rollbackTo` wipes and rebuilds all three projection
   tables together, so a claim cannot outlive its withdrawal. The defect is ordering: the claim's write is
   an `updateWhere` against a row the replay may not have created yet, and `spent_at` suppression
   (`Ingestion.hs:88`) guarantees exactly that whenever the profile's latest UTxO sits above the claim's.
   It is the CS-04 class applied to a derived column, it is reachable through the ordinary `UpdateProfile`
   redeemer, and it is untested — all three new derivation tests order the profile match first.
3. **The 3→4 bump does interact with CS-06, and it makes it worse → NEW-CS-7.** CS-06's code is byte-identical
   (`Main.hs:96-110`), so CS-06 stays OPEN; the bump changes its exposure, not its text. The wipe branch is
   now on the normal upgrade path for every deployed database, and it composes with CS-07's silent absence:
   the dropped `chain_cursor` reads as "no evidence", `/ready` stays 200 and `attest_lag_seconds` stays
   `null` for the entire rebuild. The version *downgrade* case is still unhandled. If one guard ships before
   this deploy, `ATTEST_SYNC_CONFIRM_WIPE` plus a red `/ready` on absence-when-expected is the pair.

---

## 4. [`04-governance-read-path.md`](04-governance-read-path.md)
Audit snapshot `4eb9117`; this worktree is current `main` merged (`b78767f`, code = `2bf5bde`).

**In-scope files that changed since the snapshot:** `.github/workflows/ci.yml`, `CLAUDE.md`,
`palmares.cabal`, `sql/050_roles.sql`, `src/exe/query-api/{RestAPI.hs,Query/Gov.hs,Query/ServiceStatus.hs}`,
`offchain-lib/.../{Transfer/QueryResponses.hs,Reconcile/Koios.hs,Core/Types.hs,Core/Actions.hs}`,
`webapi-lib/.../Envelope.hs`, tests.
**In-scope files that did NOT change:** all of `sql/` except `050_roles.sql`; all of `sql/checks/`,
`sql/indexes/`, `resources/metrics/`, `resources/metric-formulas.json`; `compose.yaml`, `README.md`,
`docs/metrics.md`, `docs/adr/`, `src/exe/CLAUDE.md`; `query-api/{Main.hs,Query/Views.hs,Query/Refresh.hs,
Query/Thresholds.hs,Query/Common.hs,Query/Csv.hs,QueryAppMonad.hs}`; `admin/Reconcile.hs`,
`Palmares/Reconcile.hs`, `config/reconcile-*`, `test/fixtures/`. Findings citing only those keep their
original line numbers; I verified the claim, not the offset.

**Counts.** 20 OPEN, 2 PARTIAL, 3 INVALID, 0 FIXED, 0 MOOT, 7 new.

| ID | Sev. | Status | Evidence |
|---|---|---|---|
| GV-01 | High | OPEN | `sql/000_schema.sql:10` is still `DROP SCHEMA IF EXISTS palmares CASCADE`; `Query/Views.hs:83` sets the 10 s `lock_timeout`, `:91` `die`s, and `:42` puts `030_metrics.sql` in the same transaction |
| GV-02 | High | OPEN | `src/exe/admin/Reconcile.hs:325` still fetches `/dreps?status=active&status=inactive` while `Gov.hs:1727-1729` puts `unknown` in the default page; `test/fixtures/snapshot/palmares/dreps.json` holds 294 rows of only `active`(17)/`inactive`(277), 90 with null `active_until_epoch`; `Reconcile.hs:178-179` makes a koios-only key a `membership` divergence and `:274-277` cannot waive it with a field-scoped `*` |
| GV-03 | High | OPEN (escalated) | `Query/Gov.hs:798` reads `palmares.drep_metrics`; only `Gov.hs:897` runs catalog bytes; `030_metrics.sql:30` calls itself "a second implementation". The two now **provably disagree** — §DC-01 and NEW-GV-1 |
| GV-04 | High | OPEN | `compose.yaml:267` `PG_CONN_STR: "host=postgres user=postgres …"`; `query-api/Main.hs:32` superuser default, `:87` silent fallback, `:100` owner DSN defaults to it; `PALMARES_ADMIN_CONN_STR` appears in no manifest (`compose.yaml`, `deploy/`) although `admin/Main.hs:733-742` implements `apply-roles` |
| GV-05 | Medium | OPEN | `webapi-lib/.../Envelope.hs:115` "unreachable"; `query-api/RestAPI.hs:1778` documents "429 a rate limit"; `src/exe/CLAUDE.md:77` says "rate-limited"; pool of 10 at `Main.hs:88`; `QueryAppMonad.hs:14` names the BFF as the limiter |
| GV-06 | Medium | OPEN | `Gov.hs:1321,1323` join `drep_epoch_power`/`drep` by `drep_raw`; `020_views.sql:147` weighs by `drep_raw` in a scalar subquery; `palmares.drep` is one row per `drep_hash` row (`010_gov_views.sql:298,305`), so the fan-out is mechanical, and the phantom of each pair is present as `never_registered`. Page/total asymmetry confirmed: the count uses `baseFrom` (`Gov.hs:1429`), only stage 4 uses `voteFrom` (`:1467`). The `drep_distr`-on-both-rows half still needs preprod |
| GV-07 | Medium | OPEN | `sql/020_views.sql:705` still emits `t.gov_action_id` as arm 11's `item_index`, one row per `palmares.treasury_withdrawal` row, against the uniqueness contract at `:391-393` |
| GV-08 | Medium | **INVALID** | The event at `020_views.sql:608` (`b.epoch_no = g.ratified_epoch`) is placed at the moment db-sync *determined* ratification, and the epoch-N votes the audit calls "the cause" provably did not count. See §Findings I judge wrong |
| GV-09a | Medium | OPEN | `Gov.hs:1965-1967` divides distinct voters by `with_power` (`amount > 0`) with the numerator ungated, so >1.0 is reachable; `QueryResponses.hs:1321-1327` `EpochParticipationPoint` carries no formula id, against `RestAPI.hs:1063-1066`'s stated contract |
| GV-09b | Medium | OPEN | `RestAPI.hs:1340` `dashboardTotalDreps = n DRepActive + n DRepInactive` against `Gov.hs:1729`'s three-status default; `RestAPI.hs:1289` still calls it "the universe /dreps lists by default"; no `unknown_dreps` field anywhere in `QueryResponses.hs` |
| GV-10 | Medium | OPEN (severity unproven) | `020_views.sql:282-296` per-row correlated count; `govActionProjection` ends `g.votes_cast` (`Gov.hs:1151`); 41.7 s measured at `Gov.hs:1895`. But `scripts/smoke_query_api.sh:272-274` asserts the 200-row page returns all 131 — see §Findings I judge wrong |
| GV-11 | Medium | OPEN | `010_gov_views.sql:171`, `:206`, `:215` order by `(slot_no, cert_index)` while `drep_cert` publishes `tx_index` at `:134` and `live_delegation` uses it at `:716` |
| GV-12 | Medium | OPEN — VERIFY SETTLED | `010_gov_views.sql:343-348` keeps bare `g.expiration` in the `LEAST` (and as the COALESCE fallback, so a still-open action's bound *is* `expiration`); `020_views.sql:35` gates on `<`. db-sync writes `expiration = gasExpiresAfter + 1` literally; votes are legal while `curEpoch <= gasExpiresAfter`. The fix needs a caveat — NEW-GV-5 |
| GV-13 | Medium | **INVALID** | db-sync's `is_valid IS NULL` does not mean "not checked"; it means the fetched body is **not valid JSON at all**. `010_gov_views.sql:47` mapping it to `invalid_schema` is defensible and withholding the content is right. See §Findings I judge wrong and NEW-GV-7 |
| GV-14 | Medium | OPEN (strengthened) | `010_gov_views.sql:480` maps `(ParameterChange, SPO) → pvtpp_security_group` unconditionally; `RestAPI.hs:689` fills only the DRep arm; `Thresholds.hs:180` `spoParamChangeApplies` has no production caller. The ledger makes it worse than "a bar never set" — see §VERIFY |
| GV-15 | Medium | OPEN | `Gov.hs:618` is `JOIN palmares.drep_metrics` (inner), reused by `drepSummaryByIdQuery` (`Gov.hs:781`); `Query/Refresh.hs:137-145` takes no advisory lock; `/drep/{id}/updates` reads `palmares.drep_cert` (`Gov.hs:979`) and so still finds the DRep |
| GV-16 | Medium | OPEN | `Gov.hs:949-952` takes `DISTINCT ON (addr_id)` over all of `palmares.vote_delegation` *before* the `drep_hash_id` filter is applied outside it; `RestAPI.hs:405-407` still promises history, and `:946-947` repeats the claim as a deliberate contrast |
| GV-17 | Medium | OPEN | `sql/indexes/001_gov_indexes.sql:35` creates `gov_idx_committee_reg_hot` with the "never finishes" note at `:30-32`; `ApplySql.hs:170` already has `declaredIndexes`; nothing in `Query/ServiceStatus.hs` or `Main.hs` compares it against `pg_indexes` |
| GV-18 | Low | OPEN — VERIFY SETTLED | `sql/020_views.sql:341-343` `EXISTS (… committee_de_registration …) THEN 'resigned'` with no bound on the current committee; duplicated at `Gov.hs:2227`. The ledger does permit re-election after a boundary, so "forever" is wrong — see §VERIFY for the exact correct predicate |
| GV-19 | Low | **INVALID** | db-sync writes `reward_rest.spendable_epoch` from the *same* `currentEpochNo` it writes to `gov_action_proposal.enacted_epoch`, two lines apart in one loop. `020_views.sql:386`'s join is exactly right. See §Findings I judge wrong |
| GV-20 | Low | OPEN | `sql/030_metrics.sql:188-190` iterates `palmares.drep d` with no interval gate; `resources/metrics/participation_rate_v1.sql:29-38` likewise — both copies, as the finding says |
| GV-21 | Low | OPEN | `Gov.hs:1077` filters `g.expiration < ?`; `Gov.hs:1920` uses `ga.last_votable_epoch >=` — two different columns, and `RestAPI.hs:1296-1298` documents the 12-vs-11 gap |
| GV-22 (dead modules) | Low | OPEN | `palmares.cabal:358,363,365,366` comment out `Query.{Aggregates,Metrics,Pages,Projected}`; `Query/Aggregates.hs:20` and `Query/Projected.hs:187` use `runWithQueryErrorHandling`, which is defined nowhere under `src/exe/query-api/` |
| GV-22 (CLAUDE.md routing) | Low | OPEN | `CLAUDE.md:57` points at `query-api/Metrics/Catalog.hs` (it lives in `offchain-lib`), `:59` at `Query/{Aggregates,Pages}.hs`, `:60` at `Query/Projected.hs` |
| GV-22 (one pool) | Low | OPEN | `src/exe/CLAUDE.md:43` "There is no second pool" against `Main.hs:88` and `:104` |
| GV-22 (`Query.Metrics`) | Low | OPEN | `src/exe/CLAUDE.md:55`, `docs/metrics.md:11`, `Palmares/Metrics/Catalog.hs:11` all name a module that does not exist |
| GV-22 (view count) | Low | OPEN | `docs/adr/0001-governance-data-substrate.md:12` "fourteen read-only views" against `:107` and `scripts/smoke_views.sh:37` "nineteen" |
| GV-22 (`docs/superpowers`) | Low | OPEN | 23 references outside `docs/audit/` (incl. `resources/metric-formulas.json:28,58,…` and `config/reconcile-sample.preprod.json:23`); `docs/` has no `superpowers/` |
| GV-22 (trigram) | Low | OPEN | `Transfer/Filters.hs:136` and `Query/Common.hs:130` promise a trigram index; zero `pg_trgm` anywhere in `sql/` |
| GV-22 (README §11) | Low | OPEN | `README.md:146` lists `PG_CONN_STR` as required although `Main.hs:87` defaults it; `PALMARES_PG_OWNER_CONN_STR`, `PALMARES_ADMIN_CONN_STR`, `PALMARES_NETWORK_NAME`, `PALMARES_FRESHNESS_POLL_MS` are absent |
| GV-22 (`invalid_drep_id`) | Low | OPEN | `RestAPI.hs:1425` documents that `/votes?voter_id=` answers `invalid_drep_id` for pool and committee ids too |
| GV-23 | Low | **PARTIAL** | FIXED half: `attest_lag_seconds` is on `/status` (`Query/ServiceStatus.hs:84`, `9a8d79b`, refined by `5978d28`). Still OPEN: `drep_distr_epoch` absent from `SyncStatus` (`QueryResponses.hs:488-500`); `amberLag` stored (`QueryAppMonad.hs:47`) and never read into any response; no matview `as_of_epoch`/refresh time; no `missing_indexes`; `X-Data-Lag-Seconds` (`Gov.hs:563`) absent from `docs/generated/swagger/query-swagger-api.json` |
| GV-24 | Low | OPEN | `.github/workflows/reconcile.yml:25` `continue-on-error: true`; `config/reconcile-sample.preprod.json:23` points the redraw at the missing `docs/superpowers/F1-PROGRESS.md`, `:26` pins epoch 320; `Reconcile.hs:596` hard-codes `epoch_skew`; `sample_age_epochs` appears nowhere under `src/` |
| GV-25 (checks not in CI) | Low | OPEN | zero `sql/checks` references in `.github/workflows/ci.yml`; the determinism job applies the skeleton and schema only (`ci.yml:217-229`) |
| GV-25 (no check covers thresholds) | Low | **INVALID** | `sql/checks/030_votes.sql:95` pins `gov_action_lifetime = 6`, `:98` pins one row per epoch, `:104-112` asserts every `threshold_param` names a real column; `040_power.sql:107` repeats the column check |
| GV-25 (other coverage gaps) | Low | OPEN | `UnitTests/MetricFixture.hs:241-248` skips without `PALMARES_FIXTURE_PG_CONN_STR`; `040_power.sql:81-85` is the single tip-agreement row; nothing covers the CSV route, `/search`, or `drep_metrics` beyond the one pinned DRep (`070_drep_metrics.sql:96-98`) |

### DC-01 / GV-03 — do the two implementations agree?

**They disagree, and the difference is arithmetic.** Five of six DRep metrics come from
`palmares.drep_metrics`; I compared each CTE against its catalog file.

Agree exactly: `rationale_rate` and its five grades (`030_metrics.sql:81-118` vs
`rationale_rate_v1.sql:41-71` — both one row per eligible action via `seq_last = 1`);
`vote_latency_*` (`030:119-136` vs `vote_latency_median_hours_v1.sql:21-33` — both `seq_first = 1`);
`open_actions_unvoted` (both ungated, which is GV-20); `votes_cast` (both
`count(DISTINCT gov_action_id)`). `eligible_actions()` carries `GROUP BY gov_action_id, action_type`
(`020_views.sql:38`), so neither side can duplicate the denominator set.

**`eligible_actions` differs, and it propagates into `participation_rate`.**

- Catalog: `eligible_actions = (SELECT count(*) FROM elig)` — `participation_rate_v1.sql:41`.
- Matview: `030_metrics.sql:68-80` computes `count(*)` **after** `LEFT JOIN dv v ON v.drep_voter_id =
  e.drep_hash_id AND v.gov_action_id = e.gov_action_id`, and `dv` (`030:44-60`) is every DRep vote
  **row**, re-votes included and no `DISTINCT`.

For each eligible action `a` with `n_a` vote rows the join yields `max(1, n_a)` rows, so the matview
reports `Σ max(1, n_a) = E + X`, where `X` counts the excess re-vote rows, against the catalog's `E`:

```
catalog   eligible_actions = E        participation_rate = V / E
matview   eligible_actions = E + X    participation_rate = V / (E + X)
                                      -- V = count(DISTINCT gov_action_id), identical on both sides
```

`X > 0` is not hypothetical. `sql/checks/030_votes.sql:33-38` pins preprod at **69 re-voted
(DRep, action) pairs, the worst voted 20 times** — so `X ≥ 69` corpus-wide and ≥ 19 for one DRep alone.
The served `participation_rate` is *understated* and the served `eligible_actions` *overstated* for
every DRep that ever changed its vote on a settled action. The matview's own comment (`030:72-73`)
applies `DISTINCT` to the numerator to stop a rate exceeding 100% and leaves `count(*)` in the
denominator of the same aggregate — achieving the bound by inflating it.

Both served surfaces carry it: `drepProjection` (`Gov.hs:728`) and `drepMetricsQuery` (`Gov.hs:823`)
select `m.eligible_actions` and `m.participation_rate`, and `palmares_idx_drep_metrics_part`
(`030:254`) orders the DRep list by the inflated rate.

The guards are all per-DRep: `070_drep_metrics.sql:154-158` asserts exactly this equality, but for one
pinned credential (`:96-97`) and only when run by hand (`scripts/verify_views.sh`);
`scripts/smoke_query_api.sh:140-141` asserts only that the served rate equals the served
`votes_cast / eligible_actions`, which the inflated pair satisfies by construction.

So GV-03 is right in substance and wrong in tense: the drift it warns a formula change "would" cause is
already present, and its recommended fix (a) — run the 070 agreement over all DReps — would fail on the
current corpus the day it ships.

### VERIFY items settled

| Question | Answer | Source | What it means for the finding |
|---|---|---|---|
| `GV-12` — is db-sync's `expiration` = `gasExpiresAfter + 1`? | **Yes, literally.** db-sync: `DB.govActionProposalExpiration = (\epochNum -> unEpochNo epochNum + 1) <$> govExpiresAt`, where `govExpiresAt = Ledger.addEpochInterval e ei` with `ei = ppGovActionLifetime` — the same two inputs and the same formula the ledger uses for `gasExpiresAfter` (`mkGovActionState`: `gasExpiresAfter = addEpochInterval curEpoch expiryInterval`, no `+1`). The schema comment does not disclose the `+1`. | [db-sync `Insert/GovAction.hs#L99`](https://github.com/IntersectMBO/cardano-db-sync/blob/13.7.2.1/cardano-db-sync/src/Cardano/DbSync/Era/Universal/Insert/GovAction.hs#L99), [`Ledger/Types.hs#L202-205`](https://github.com/IntersectMBO/cardano-db-sync/blob/master/cardano-db-sync/src/Cardano/DbSync/Ledger/Types.hs#L202-L205), [ledger `Rules/Gov.hs`](https://github.com/IntersectMBO/cardano-ledger/blob/master/eras/conway/impl/src/Cardano/Ledger/Conway/Rules/Gov.hs) | **GV-12 confirmed.** The repo's own three assertions that `expiration = proposed + lifetime + 1` (`sql/010_gov_views.sql:426`, `sql/checks/030_votes.sql:92`, `scripts/smoke_query_api.sh:276`) are right, and so is the inference: the last legal vote epoch is `expiration - 1`. The three pinned counts in `sql/checks/020_eligibility.sql` move by one. **But the fix must not be blanket — NEW-GV-5.** |
| `GV-12` — is a vote legal in the epoch *equal* to `gasExpiresAfter`? | **Yes.** `checkVotesAreNotForExpiredActions curEpoch votes = checkDisallowedVotes votes VotingOnExpiredGovAction $ \GovActionState{gasExpiresAfter} _ -> curEpoch <= gasExpiresAfter`; the lambda is the *allowed* predicate and the failure collects its negation. | [ledger `Rules/Gov.hs` L356-362, L646-650](https://github.com/IntersectMBO/cardano-ledger/blob/master/eras/conway/impl/src/Cardano/Ledger/Conway/Rules/Gov.hs) | The rule quoted in the view header (`010_gov_views.sql:311-313`) is correct; only the column it is applied to is off by one. Independently corroborated by the repo's own data: "no vote was ever observed later than `expired_epoch - 1`" (`010:325`). |
| `GV-08` — db-sync's `ratified_epoch` boundary | **Settled: `ratified_epoch` = the epoch just STARTED, written verbatim.** db-sync force-completes, at the first block of epoch N, the pulser the ledger freshly seeded at that same boundary (`finishDRepPulser`, then `updateRatified syncEnv epochNo`, `DB.updateGovActionRatified gaId (unEpochNo epochNo)` — no adjustment; `epochNo = sdEpochNo details`). That pulser's `dpProposals` was frozen at the boundary, so it holds votes **through the end of epoch N-1**. The ledger applies the *previous* boundary's pulser, so an action stamped `ratified_epoch = N` **stays a live, votable proposal all through epoch N** — GOV has no "already ratified" gate — and is only removed at the boundary into N+1, which db-sync records as `enacted_epoch = N+1`. | [db-sync `Insert/GovAction.hs#L427-430`](https://github.com/IntersectMBO/cardano-db-sync/blob/13.7.2.1/cardano-db-sync/src/Cardano/DbSync/Era/Universal/Insert/GovAction.hs), [`Universal/Block.hs#L74,L136-137`](https://github.com/IntersectMBO/cardano-db-sync/blob/master/cardano-db-sync/src/Cardano/DbSync/Era/Universal/Block.hs), [ledger `Rules/Epoch.hs#L296-320,L376`](https://github.com/IntersectMBO/cardano-ledger/blob/master/eras/conway/impl/src/Cardano/Ledger/Conway/Rules/Epoch.hs), [`Rules/Gov.hs#L604-608`](https://github.com/IntersectMBO/cardano-ledger/blob/master/eras/conway/impl/src/Cardano/Ledger/Conway/Rules/Gov.hs) | **GV-08 is INVALID** and the real defect is elsewhere: those epoch-N votes are legal, recorded, and *provably non-counting* — which `palmares.vote_tally` does not know (**NEW-GV-6**). `ratified_epoch = N` also means "in force from N+1", not N. |
| Which `drep_distr` epoch a ratification weighs | **The same label db-sync writes for that boundary.** `RatifyEnv.reCurrentEpoch = dpCurrentEpoch`, frozen at pulser creation, and db-sync's `insertDrepDistr epochNo drepSnapshot` writes `drepDistrEpochNo = unEpochNo e` for the *same* `e` it passes to `updateRatified` — one pulser, one call, two columns. | [ledger `Governance/DRepPulser.hs#L393-421`](https://github.com/IntersectMBO/cardano-ledger/blob/master/eras/conway/impl/src/Cardano/Ledger/Conway/Governance/DRepPulser.hs), [db-sync `Universal/Epoch.hs#L75-78`](https://github.com/IntersectMBO/cardano-db-sync/blob/13.7.2.1/cardano-db-sync/src/Cardano/DbSync/Era/Universal/Epoch.hs) | **Good news for `vote_tally`.** `last_votable_epoch` happens to equal the right `drep_distr` epoch in all three terminal shapes (ratified → `ratified_epoch`; expired → `expiration = expired_epoch`; open → `expiration`, the boundary of the last attempt). So `020_views.sql:144-148` and `Gov.hs:1320-1322` are correct today — and that is precisely why GV-12's fix is dangerous (NEW-GV-5). The audit's §4 VERIFY on the tally's power epoch resolves **in the code's favour**. |
| Bootstrap-phase vote rules at protocol major 9 | **Settled.** `hardforkConwayBootstrapPhase pv = pvMajor pv == natVersion @9`. Proposals: only `ParameterChange`, `HardForkInitiation`, `InfoAction` (`isBootstrapAction`) — and **no parameter-group restriction** at proposal time. Votes: `checkBootstrapVotes` **hard-rejects** a DRep vote on anything but `InfoAction` (the tx fails; it is not a silent ignore). Thresholds: every DRep threshold is reset to `def` = 0 during bootstrap. | [`Conway/Era.hs#L255-257`](https://github.com/IntersectMBO/cardano-ledger/blob/master/eras/conway/impl/src/Cardano/Ledger/Conway/Era.hs), [`Rules/Gov.hs#L377-391,L633-638`](https://github.com/IntersectMBO/cardano-ledger/blob/master/eras/conway/impl/src/Cardano/Ledger/Conway/Rules/Gov.hs), [`Governance/Internal.hs#L510-524`](https://github.com/IntersectMBO/cardano-ledger/blob/master/eras/conway/impl/src/Cardano/Ledger/Conway/Governance/Internal.hs) | Two consequences. (1) GV-14's bootstrap half is **confirmed**: a DRep tally on a bootstrap-era action carries a threshold the ledger set to zero, so `threshold_applies` is the right fix. (2) The audit's §4 complaint that `drep_votable` is "coarse" over the whole window is **wrong** — see §Findings I judge wrong. |
| `GV-14` — SPO threshold on `ParameterChange` | **Confirmed, and worse than stated.** `votingStakePoolThresholdInternal` returns `VotingThreshold pvtPPSecurityGroup` only when `any isSecurityRelevant (modifiedPPGroups ppu)`; otherwise `NoVotingAllowed`, which means both `isVotingAllowed = False` (the vote is rejected at GOV with `DisallowedVoters`) and `toRatifyVotingThreshold → SJust minBound` (threshold forced to zero in RATIFY). | [`Governance/Internal.hs#L343-354,L379-410`](https://github.com/IntersectMBO/cardano-ledger/blob/master/eras/conway/impl/src/Cardano/Ledger/Conway/Governance/Internal.hs) | A published `threshold_param = pvtpp_security_group` on a non-security `ParameterChange` does not merely name a bar the ledger never set — it names a bar for a voter the ledger would not have let vote at all. GV-14's fix is right, and the SPO row should carry no threshold. |
| `GV-18` — may `UpdateCommittee` re-add a resigned cold credential? | **Yes, with one condition.** ENACT cannot fail (`PredicateFailure (ENACT era) = Void`) and its `UpdateCommittee` branch is a pure `Map.union` that never consults `CommitteeState`, so the credential is re-added unconditionally. Whether it can then *vote* depends on pruning: `updateCommitteeState` runs `Map.intersection creds members` at every boundary, so a credential that ceased to be an elected member across a boundary loses its `CommitteeMemberResigned` entry and may re-authorize a hot key; one re-added while still a member keeps the entry and `AuthCommitteeHotKey` fails with `ConwayCommitteeHasPreviouslyResigned` (and RATIFY counts it abstain). A `NoConfidence` enactment sets the committee to `SNothing` and wipes `CommitteeState` entirely. GOV also rejects an `UpdateCommittee` whose add- and remove-sets intersect, so the clean-slate path needs two enacted actions or a `NoConfidence`. | [`Rules/Enact.hs#L73-78,L107-133`](https://github.com/IntersectMBO/cardano-ledger/blob/master/eras/conway/impl/src/Cardano/Ledger/Conway/Rules/Enact.hs), [`Rules/Epoch.hs#L344-347,L423-427`](https://github.com/IntersectMBO/cardano-ledger/blob/master/eras/conway/impl/src/Cardano/Ledger/Conway/Rules/Epoch.hs), [`Rules/GovCert.hs#L190-207,L273-276`](https://github.com/IntersectMBO/cardano-ledger/blob/master/eras/conway/impl/src/Cardano/Ledger/Conway/Rules/GovCert.hs), [`Rules/Ratify.hs#L158`](https://github.com/IntersectMBO/cardano-ledger/blob/master/eras/conway/impl/src/Cardano/Ledger/Conway/Rules/Ratify.hs) | **GV-18 confirmed OPEN**, and the fix is sharper than the audit's. The correct predicate is not "compare the latest de-registration against the current committee's establishment epoch" but "a resignation counts only within the credential's *current membership tenure*": ignore the row unless the cold credential is in today's `palmares.committee_member` set with no intervening enacted removal or `NoConfidence`. |
| `GV-13` — when does db-sync leave `is_valid` NULL? | **Settled, and it refutes the finding.** `NULL` = hash matched but the body **is not valid JSON at all** (the `json` column holds an error message); `FALSE` = valid JSON that failed the typed CIP decode; `TRUE` = both passed. Every anchor type gets a verdict — none is skipped. (A hash mismatch produces no `off_chain_vote_data` row at all.) | [db-sync `doc/schema.md#L1019-1022`](https://github.com/IntersectMBO/cardano-db-sync/blob/13.7.2.1/doc/schema.md), [`OffChain/Http.hs#L136-162`](https://github.com/IntersectMBO/cardano-db-sync/blob/master/cardano-db-sync/src/Cardano/DbSync/OffChain/Http.hs#L136-L162), [`OffChain.hs#L352-392`](https://github.com/IntersectMBO/cardano-db-sync/blob/master/cardano-db-sync/src/Cardano/DbSync/OffChain.hs#L352-L392) | **GV-13 is INVALID.** There is no "false accusation": a body that is not JSON does not conform to CIP-100, and there is no document worth publishing. The repo's *comment* is the thing that is wrong (**NEW-GV-7**), and the audit inherited the error from it. |
| `GV-19` — `reward_rest.spendable_epoch` for treasury payouts | **Settled, and it refutes the finding.** `insertRewardRests syncEnv ntw (subFromCurrentEpoch 1) currentEpochNo …` sits two lines below `DB.updateGovActionEnacted gaId (unEpochNo currentEpochNo)` in the same `forM_ enacted` body, so `spendable_epoch` and `enacted_epoch` are one identical value. `earned_epoch` is a Postgres `GENERATED ALWAYS AS (spendable_epoch - 1) STORED` column db-sync never inserts. | [db-sync `Insert/LedgerEvent.hs#L141-146`](https://github.com/IntersectMBO/cardano-db-sync/blob/13.7.2.1/cardano-db-sync/src/Cardano/DbSync/Era/Universal/Insert/LedgerEvent.hs), [`migration-2-0029-20240117.sql#L16`](https://github.com/IntersectMBO/cardano-db-sync/blob/master/schema/migration-2-0029-20240117.sql), [`doc/schema.md#L385-386`](https://github.com/IntersectMBO/cardano-db-sync/blob/13.7.2.1/doc/schema.md) | **GV-19 is INVALID.** `020_views.sql:386`'s `rr.spendable_epoch = ga.enacted_epoch` is exactly right. Even on the other reading of "enacted at epoch N" (the closing epoch), *both* columns shift together, so the join cannot be off by one. The `paid_heuristic` is still a heuristic — nothing ties a payout to a *particular* action — but the epoch match is not the weakness. |

Nothing in §6 of the README was left unsettled. The one item I did not pin independently is whether
the three preprod actions at 228/251/293 crossed their thresholds on pre-epoch-N votes alone; that
needs the database and is the discriminating test for NEW-GV-6's magnitude, not its existence.

### Findings I judge wrong

- **GV-08 — INVALID.** The finding turns on the inference "db-sync's `ratified_epoch` is the epoch whose
  votes were counted at its closing boundary". It is not. db-sync stamps `ratified_epoch = N` while
  processing the *first block of epoch N*, from a pulser whose vote snapshot closed at the end of epoch
  `N-1`. So the votes that ratified the action all precede the event, and arm 7's placement at the first
  block of `ratified_epoch` (`020_views.sql:605-611`) is the most accurate placement available — it is
  when db-sync learned the outcome. The repo's measurement (last vote *in* `ratified_epoch` on 3 of 9,
  `010_gov_views.sql:316-318`) is fully consistent with this: an action stays a live, votable proposal
  all through `ratified_epoch`, so late non-counting votes are expected. The recommended fix
  (`b.epoch_no = g.ratified_epoch + 1`) would move the event a whole epoch after db-sync determined it
  and collide it with enactment. Keeping `ratified_epoch` undecremented in `last_votable_epoch`
  (`010:345`) is also right, for the same reason.
- **GV-13 — INVALID.** "db-sync said 'not checked'" is false. `is_valid IS NULL` means the fetched body
  is not valid JSON; the `json` column holds a parse error instead of a document. Publishing
  `invalid_schema` for that is blunt but not a false accusation, and withholding content is correct —
  there is no document. The repo's view comment at `010_gov_views.sql:12-13` and `:53-55` is where the
  error lives (NEW-GV-7), not in the verdict mapping. The recommended `hash_verified` verdict would
  publish a parse-error blob as a hash-verified rationale.
- **GV-19 — INVALID.** The hypothesis "a payout earned at the enactment boundary may be recorded with
  `spendable_epoch = enacted_epoch + 1`" is not reachable: db-sync writes both from one
  `currentEpochNo` in one loop body. The committed skeleton's `earned_epoch = spendable_epoch - 1`
  (`test/fixtures/dbsync-skeleton.sql:397-401`), which the finding reads as evidence, is a generated
  column db-sync never writes — it says nothing about which column carries the enactment epoch.
- **GV-25, bullet "No check covers `palmares.thresholds` values" — INVALID.**
  `sql/checks/030_votes.sql:95` pins `gov_action_lifetime = 6` at epoch 320, `:98` pins exactly one
  `thresholds` row per epoch, `:104-112` asserts every non-NULL `threshold_param` in `threshold_map`
  names a real column, and `040_power.sql:107` repeats that check. The neighbouring clauses (no CSV
  check, `drep_metrics` over one DRep, `drep_epoch_delegators` over one row) are correct, so only this
  clause is wrong.
- **§4 table, `action_window` row: "bootstrap test over the whole window is coarse (an action proposed
  at PV9 is 'DRep-votable' even for the epochs before the fork)" — this is the right rule.**
  `checkBootstrapVotes` rejects a DRep vote on a non-`InfoAction` only *during* bootstrap and
  constrains nothing after, so "was this action ever DRep-votable" is exactly "is any epoch of its
  window past the fork, or is it an `InfoAction`" — which is what `010_gov_views.sql:359-362` computes.
  The code comment there is correct and the audit's VERIFY resolves in its favour.
- **§4 table, `vote_tally` row: the "power epoch choice" VERIFY resolves in the code's favour.**
  `last_votable_epoch` coincides with the `drep_distr.epoch_no` the ledger weighs in all three
  terminal shapes. No shared off-by-one with Koios; the current join is right.
- **GV-03 — right in substance, wrong in tense.** It says a drift "would" change every served number
  while the gates stay green. The drift is already there (§DC-01), so the severity is right and the
  framing is not; fix (a) would fail on the current corpus immediately.
- **GV-10 — mechanism real, predicted 503 not established.** The 41.7 s at `Gov.hs:1895` was measured
  on the dashboard's totals statement, and the same comment records that naming the needed columns
  drops it to 213 ms because PostgreSQL prunes the view's targetlist. The only live evidence about the
  *list* page — `scripts/smoke_query_api.sh:272-274`, asserting `/gov-actions?limit=200` returns all
  131 rows with `g.votes_cast` selected (`Gov.hs:1151`) — points the other way. The correlated count
  at `020_views.sql:282-296` is real and worth removing; "would answer 503" is unproven and the
  finding's own `EXPLAIN ANALYZE` caveat should be the headline, not a footnote.
- **GV-23 — the `/status` field list is stale.** The "not the attestation projector lag" clause closed
  in `9a8d79b` (`Query/ServiceStatus.hs:84`). Graded PARTIAL rather than listed as wrong.

### New findings

- **NEW-GV-1 — High — The served `eligible_actions`/`participation_rate` fan out on re-votes, and one
  `/drep/{id}` response contradicts itself.** `sql/030_metrics.sql:68-80` takes `count(*)` across a
  `LEFT JOIN` to every DRep vote **row**, so the denominator grows by one per re-vote, where
  `resources/metrics/participation_rate_v1.sql:41` counts the eligible set itself. Pinned corpus: 69
  re-voted (DRep, action) pairs, worst 20 (`sql/checks/030_votes.sql:33-38`). Worse than a
  formula/implementation split: within the single statement at `Query/Gov.hs:794-848`,
  `m.eligible_actions` (line 823, inflated) and the per-type `t.eligible_actions` (line 811, correct —
  `final` is joined at `seq_last = 1` and cannot fan out) are both published, so
  `sum(votes_by_type[].eligible_actions) ≠ metrics.eligible_actions` for any re-voting DRep. That is an
  invariant `scripts/smoke_query_api.sh:195` asserts — for one hand-picked DRep only. Fix:
  `count(DISTINCT e.gov_action_id)` in the `part` CTE, or aggregate `elig` before the join.
- **NEW-GV-2 — Medium — The `_no_confidence` committee thresholds are dismissed for the wrong reason,
  and the real selector is readable.** `Query/Thresholds.hs:16-19` and `sql/010_gov_views.sql:457-458`
  both justify always reporting `dvt_committee_normal`/`pvt_committee_normal` on the grounds that the
  `_no_confidence` variants "apply only while the committee is in a state of no confidence" and that
  `epoch_state.no_confidence_id` is upstream-documented as always NULL. The ledger selects on
  `isElectedCommittee = isSJust (ratifyState ^. rsEnactStateL . ensCommitteeL)` — *is there a currently
  elected committee at all* — and applies the variants to `UpdateCommittee` (db-sync's
  `NewCommittee`), while the `NoConfidence` action uses `*MotionNoConfidence`
  ([`Governance/Internal.hs#L379-410` SPO, `#L507-532` DRep](https://github.com/IntersectMBO/cardano-ledger/blob/master/eras/conway/impl/src/Cardano/Ledger/Conway/Governance/Internal.hs)).
  That selector is derivable from data the repo already reads —
  `palmares.committee_member.is_enacted` / `epoch_state.committee_id` (`sql/020_views.sql:347`).
  Latent on preprod, which has always had a committee; it mis-states the bar for the first
  `UpdateCommittee` after a successful `NoConfidence`, which is exactly when the number matters most.
- **NEW-GV-5 — Medium — GV-12's recommended fix would break the tally's power epoch.**
  `last_votable_epoch` is doing two jobs. As a *votability* bound it is one epoch too permissive
  (GV-12). As the *stake snapshot* at which the final ratification weighs votes it is exactly right:
  `020_views.sql:144-148` (`vote_tally`) and `Gov.hs:1320-1322` (`voteFrom`) read
  `drep_epoch_power` at `last_votable_epoch`, and `Gov.hs:1311-1313` says so explicitly — "that is
  the epoch the ledger weighs the vote in" — which the ledger confirms (the last ratification attempt
  on an action expiring at `expiration` runs at the boundary into `expiration`, weighing
  `drep_distr.epoch_no = expiration`). GV-12's "use `g.expiration - 1` in both `last_votable_epoch` and
  the `drep_votable` window" would therefore fix eligibility and silently shift every DRep vote weight
  back one epoch. The two quantities need two columns — e.g. keep `last_votable_epoch` for power and
  add `last_vote_legal_epoch = last_votable_epoch - (expiration arm only)` for eligibility — and
  `sql/checks/040_power.sql` should pin them apart.
- **NEW-GV-6 — Medium — `vote_tally` counts votes the ledger provably did not.** `final_votes`
  (`sql/020_views.sql:127-139`) takes every `seq_last = 1` vote with no epoch cut. For a ratified
  action the ledger's decision was computed from a snapshot frozen at the start of `ratified_epoch`, so
  votes cast *during* `ratified_epoch` are legal, recorded, and could not have affected the outcome
  ([`Rules/Epoch.hs#L296-320`](https://github.com/IntersectMBO/cardano-ledger/blob/master/eras/conway/impl/src/Cardano/Ledger/Conway/Rules/Epoch.hs);
  GOV has no already-ratified gate, `Rules/Gov.hs#L604-608`). The repo has measured this population:
  3 of 9 ratified preprod actions have their last DRep vote in `ratified_epoch`
  (`010_gov_views.sql:316-318`). The published `yes/(yes+no)` for those actions can therefore differ
  from the ratio the ledger used, and the Koios check cannot see it because both sides read the same
  `voting_procedure` rows. Fix: for a ratified action, cut `final_votes` at `vote_epoch <
  ratified_epoch` (or publish a `counted` flag per vote and a second ratio). This is the finding GV-08
  was reaching for.
- **NEW-GV-7 — Low — `cip100_valid`'s published contract mis-states db-sync.**
  `sql/010_gov_views.sql:12-13` says NULL means "the check was inconclusive" and `:53-55` offers
  `cip100_valid` so a consumer can tell "checked and failed (FALSE)" from "check was inconclusive
  (NULL)". db-sync's NULL means the fetched body **is not valid JSON at all** — the `json` column holds
  a parse error ([`doc/schema.md#L1019-1022`](https://github.com/IntersectMBO/cardano-db-sync/blob/13.7.2.1/doc/schema.md)).
  The field reaches clients at `Gov.hs:1517` (`'cip100_valid', a.cip100_valid` on every vote) and as
  `m.rationale_cip100_valid` (`Gov.hs:826`), so the wrong reading is published, not just commented.
  One-line fix in the comment; the verdict mapping needs no change.
- **NEW-GV-3 — Low — `voteFrom`'s Haddock is false in the one place GV-06 turns on.**
  `Query/Gov.hs:1313` says "The FROM clause the page and the count share." `listVotes` uses `baseFrom`
  for the count (`:1429`) and `voteFrom` only for stage 4 (`:1467`); `voteFrom` has no other caller.
  The sentence matters because that asymmetry is exactly why GV-06's fan-out shows up as `items`
  exceeding `limit` while `total` stays correct — a reader trusting the comment concludes the opposite.
- **NEW-GV-4 — Low — `attestation_credential` is written and never served.** ADR 0003 (`6d0a76a`)
  added the column (`Palmares/Storage.hs:149`) and writes it (`:469`), and
  `docs/generated/swagger/query-swagger-api.json` (1.2.0) now publishes `credential_claim` and
  `credential_withdrawal` as `AttestationType` values. But `AttestationRow`
  (`QueryResponses.hs:1818-1834`) has no credential field and `toAttestationRow`
  (`Query/Attest.hs:384-405`) never reads it, so `/attestations?kind=credential_claim` returns rows
  whose defining payload is absent: a client sees *that* a credential was claimed or withdrawn, never
  *which*, and cannot reconstruct a profile's credential history even though
  `AttestProfileRow.credential` (`QueryResponses.hs:1800`) publishes the current value. The write path
  and the Swagger vocabulary moved; the read projection did not.

### Drift checks that came back clean

Swagger is coherent at 1.2.0: `AttestationType` carries all seven kinds and `DisputeVerdict` all
three, and `scripts/check_swagger.sh:31,35-36,122-125` asserts both as sets.
`VerdictExpired` needs no read-path change — `disputeRowVerdict :: Maybe Core.DisputeVerdict`
(`QueryResponses.hs:1861`) was already nullable for open disputes.
`profile_credential` becoming derived leaves `Query/Attest.hs:220-223`'s filters valid as written.
The six governance metric files, `resources/metric-formulas.json` and `docs/metrics.md` are untouched
since the snapshot, so every §5 "reviewed and not an issue" item about them still holds.

---

## 5. [`05-tests-ci-and-delivery.md`](05-tests-ci-and-delivery.md)
Reconciled 2026-10-23 in the worktree `/private/tmp/palmares-audit` (branch `docs/audit-2026-10-22`,
current `main` merged in). Audit cites `4eb9117`; HEAD is 14 commits later. Toolchain used for
`TD-03` and `TD-06`; `cabal test` not run (627 tests green at this commit taken as given).

**The decisive drift fact:** `git diff --name-only 4eb9117..HEAD` outside `src/` and `docs/` touches
only `.github/workflows/ci.yml`, `CLAUDE.md`, `palmares.cabal`, `scripts/check_roles.sh`,
`scripts/check_swagger.sh`, `scripts/smoke_attest_flow.sh`, `sql/050_roles.sql`. Every delivery-side
finding that cites `.dockerignore`, `compose.yaml`, `Dockerfile.*`, `images.yml`, `reconcile.yml`,
`.envrc`, `.justfile`, `README.md`, `.env.example`, `check_vocabulary.sh`, `check_gitleaks_allowlist.sh`
or `deploy/` is unchanged in substance **and in line numbers**.

| ID | Sev. | Status | Evidence |
|---|---|---|---|
| TD-01 | High | OPEN | `.dockerignore:20` has `config/*.prv`, nothing for `config/config_atlas.json` (which `.gitignore:44` does exclude) or `config/config_palmares_validators.json`; `Dockerfile.{admin,attest-sync,interaction-api,query-api}:22` and `:51` both `COPY config`. `docs/adr/0002-write-path-provider.md:29` still claims exclusion "by both `.gitignore` and `.dockerignore`" — still false. `.cabal/`, `out/`, `experiments/`, `.vscode/` still absent. File untouched since snapshot. |
| TD-02 | High | OPEN | `compose.yaml` has exactly six services (`:32,:69,:106,:169,:233,:263`) — no `attest-sync` anywhere; `interaction-api` (`:233-261`) sets no `BASIC_USER`/`BASIC_PASS`, and `src/lib/webapi-lib/Palmares/WebAPI/Auth.hs:62` `die`s without both. `query-api` is in profile `app` only (`:264`) and serves the 7 attestation routes `check_swagger.sh` asserts. |
| TD-03 | High | OPEN (verified with toolchain) | `.github/workflows/ci.yml:102-108`: `actions/cache@v4`, `path: [cabal-store, dist-newstyle]`, `key: ${{runner.os}}-${{runner.arch}}-ghc9.6.6-${{hashFiles('cabal.project.freeze','cabal.project')}}`. `palmares.cabal` is **not** in the key, so a `ghc-options` edit there leaves the key byte-identical → exact cache hit → `dist-newstyle` restored verbatim from the previous commit. Commit `43ab998`'s own body: "changing `ghc-options` — including a flag's `default:` — does not reliably force cabal to recompile … Clearing dist-newstyle/cache was not enough; deleting the component's build tree was. A fresh checkout is never affected, so CI and Docker were always fine." With this cache CI is not a fresh checkout. The only ci.yml change since the snapshot is the added role-separation step (`:234-257`); the cache block is untouched. See "Findings I judge wrong" for one nuance. |
| TD-04 | Medium | OPEN, count restated | **21 of 70** codes (was 22 of 63) have no validator-level test. `K3` is gone with `Protocol/Id.hs` (`3654f57`), which removes it from the list; nothing else moved. The two 2026-10-22 security fixes still ship untested: `Mp6` (`Validators/MintingPolicy.hs:379`) and `O6` (`Validators/OracleValidator.hs:92`) — zero test references each. `P2` (`ProfilesValidator.hs:158`), `P5` (`:161`), `N0` (`OracleNFTPolicy.hs:38`), `Mg` (`MintingPolicy.hs:305`, helper-only in `MintInputs.hs:44-73`) likewise. Repo rule still at `src/test/CLAUDE.md:37`. All seven codes added since the snapshot (`A7`, `D9`, `Da`, `Mc1`–`Mc4`) **arrived with validator-level tests** — see §Trace-code coverage. |
| TD-05 | Medium | OPEN | `Dockerfile.base:4` `benz0li/ghc-musl:9.6.6` and `Dockerfile.runtime-base:5` `alpine:3.20` by tag; `apk add` without versions at `base:8,12,40`; libsodium 1.0.19 tarball unchecksummed (`base:50`, `runtime-base:24`); secp256k1 `--branch 'v0.3.2'` (`base:57`), blst via `ARG BLST_REF=v0.3.15` + `git checkout` (`base:66-68`). CI is `haskell-actions/setup@v2` + apt (`ci.yml:53-100`). No job runs `cabal test` inside the builder. |
| TD-06 | Medium | OPEN (verified with toolchain) | `bash scripts/check_vocabulary.sh` exits **0** ("vocabulary OK"). The `DORMANT` list (`scripts/check_vocabulary.sh:32`) excludes 8 paths and the filter works (150 candidate files → 142). All five test modules it calls "comment-prefixed out of the test-suite's `other-modules`" are in fact listed in `palmares.cabal`'s `test-suite` `other-modules` (`TestRuns`, `Test.Fixtures`, `UnitTests.Attestation`, `UnitTests.Cleanup`, `UnitTests.Oracle`) — all five compile. `src/test/TestRuns.hs:16` contains "the promotion-acceptance attack", matching the banned pattern `[Pp]romotion`, and is hidden by the exclusion. The three `Query/*.hs` exclusions are legitimate (not in `other-modules`; `Projected.hs` has 12 hits, `Aggregates.hs` 1). |
| TD-07 | Medium | OPEN | `.github/workflows/reconcile.yml:25` `continue-on-error: true`; `:58` `ghcr.io/mariusgeorgescu/palmares-admin:latest`; no `gh issue` / notification step anywhere in the file. |
| TD-08 | Medium | PARTIAL — substance OPEN, counts wrong | Substance stands: `compose.yaml:171` `cardanosolutions/kupo:v2.12.0` by tag, `:235` and `:265` by `${TAG:-latest}`; header `:18-19` still claims "every image is pinned by its multi-arch INDEX digest"; `:2` still claims "arm64 and amd64 both work" while `images.yml:74,:116` publish `linux/arm64` only; node/Postgres caps still absent (only db-sync, `:145-150`). But the arithmetic is wrong — see "Findings I judge wrong". |
| TD-09 | Medium | OPEN | `compose.yaml:96` `["${POSTGRES_PORT:-5432}:5432"]`, `:214` `["${KUPO_PORT:-1442}:1442"]`, `:251` `:8082`, `:274` `:8083` — all unprefixed, i.e. all interfaces; `:75` and `:122` `POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-devonly}`. |
| TD-10 | Medium | PARTIAL — gitleaks/blst/`permissions` OPEN, one citation wrong | `ci.yml:280-282` gitleaks 8.30.1 `curl … | tar -xz` with no checksum; `:68` blst `--branch v0.3.15`; `:29,:206,:262` `actions/checkout@v4`, `:96` `haskell-actions/setup@v2`, `:102` `actions/cache@v4` — all by major tag; no `permissions:` block in the file. The `docker/*@v3/v6` half of the citation is wrong: `ci.yml` contains no `docker/*` action (they are in `images.yml`). |
| TD-11 | Medium | OPEN | No `USER` in any of the six Dockerfiles; `Dockerfile.runtime-base:22,:32,:44` add three virtual package sets and `:57` deletes them in a fourth `RUN`; `Dockerfile.attest-sync:55` bakes `PG_CONN_STR="…password=postgres…"`; no `--enable-executable-stripping` anywhere. |
| TD-12 | Medium | OPEN | `.github/workflows/images.yml:2-5` — `push: tags: ["v*.*.*"]` + `workflow_dispatch` only. No `pull_request` trigger. |
| TD-13 | Low | OPEN (premise verified) | `src/test/Test/Pg.hs:77` `dbName = "palmares_test_" <> T.pack (show pid)`. The test-suite stanza carries no `-threaded` (only the three executables do, `palmares.cabal:351,:408,:445`), there is no `test-options`/`TASTY_NUM_THREADS` anywhere, so tasty's `numCapabilities` default is 1 — the 35 `withScratchDb` call sites are serialised today by accident of RTS config, which is exactly the finding. The breakdown in §1e (Views 4, AttestSchema 10, Refresh 5, Activity 6, Anchor/ThresholdMap/MetricCatalog/AttestRead/Projections 2 each = 35) is exact. |
| TD-14 | Low | OPEN | `README.md:105-111` is still the bare `cabal update / cabal build all / cabal test` block with no PostgreSQL and no variable named; `.env.example` (33 lines) lists neither `PALMARES_TEST_PG_CONN_STR` nor `PALMARES_FIXTURE_PG_CONN_STR`. `src/test/Test/Pg.hs:46-53` still `die`s. `src/test/UnitTests/MetricFixture.hs:239-250` still prints `SKIPPED` to stderr from inside a passing `testCase`; the case count grew from 8 to **10**. |
| TD-15 | Low | OPEN, and wider than the audit recorded | Still stale verbatim: `palmares.cabal:19-21` ("the SQL and metric-catalog globs below are deliberately commented out" — they are LIVE at `:29-32`), `:40-41` (leftover commented duplicates of `:29-30`), `:97-99` ("every `exposed-modules`/`other-modules` list … is comment-prefixed"), `:355-366` (`Metrics.Catalog`/`Query.Metrics` commented out — neither file exists under `src/exe/query-api/`); `README.md:71` (experiments "deleted once their numbers land in an ADR" — `docs/adr/0001` landed, directory remains); `README.md:143-144` (`BASIC_USER`/`BASIC_PASS` "interaction-api, admin" — `grep BASIC_ src/exe/admin` is empty, only `src/exe/interaction-api/Main.hs:64` reads them), `:149` (`BATCH_SIZE` default 1000000 — only `FETCH_BATCH_SIZE` is read, `src/exe/attest-sync/Main.hs:113`), `:150` (`FETCH_BATCH_SIZE` default 100000 vs code's `10_000_000`, `Main.hs:114`); `ci.yml:150-151` orphaned pasted instructions; `scripts/smoke_attest_flow.sh:33` "this repo ships no signer" vs `admin sign-tx` (`src/exe/admin/Main.hs:287`); `Test/Helpers.hs:37` and `UnitTests/Oracle.hs:23` still call `preserve-logging` a cabal *flag* "on by default" while `palmares.cabal:90-93` says it is deliberately not a flag; commented-out `remove-trace` pragmas survive at `Validators/AttestationsValidator.hs:6` and `Validators/ProfilesValidator.hs:8`; `extraction-keep.txt` still present. Two items got **worse**: `palmares.cabal:81-82` still points at `UnitTests.ScriptSize` as the authority and quotes **12296** while `ScriptSize.hs:373-380` now pins MintingPolicy at **12618** (three size moves stale, in a comment written to fix a stale number); and the 8 `@Ml@` references are now joined by 10 `@Mp3@` references to a rule ADR 0003 deleted — see NEW-TD-3. |
| TD-16 | Low | OPEN (verified with toolchain) | `env PATH=/usr/bin:/bin bash scripts/check_gitleaks_allowlist.sh` prints `skip gitleaks not found` and **exits 0** (`scripts/check_gitleaks_allowlist.sh:41-45`). |
| TD-17 | Low | OPEN | `.envrc:26` `nix build --print-out-paths nixpkgs#xz.dev`, `:41-42` `nix eval --raw nixpkgs#xz.dev` — unpinned flake registry on every load; `:38` unconditional `just link-hls`; `.justfile:11` `cabal run . -- {{OPTS}} 2>&1 \|\| true` (ambiguous across four executables, error swallowed). |
| TD-18 | Low | OPEN | `deploy/node-config/SOURCES.sha256:3` says "Verify with: shasum -a 256 -c"; `grep -rn SOURCES.sha256 .github/ scripts/` → nothing. Only `experiments/dbsync-preprod/run.sh:10` verifies, and only its own copy. |
| TD-19 | Low | OPEN | `src/exe/attest-sync/Main.hs:103-106`: `needWipe = … storedVersion < currentSchemaVersion || storedPolicy /= policyHexText` — `storedVersion > currentSchemaVersion` still falls through to `runMigrations` against a newer table shape. `currentSchemaVersion` is now **4** (`src/lib/offchain-lib/Palmares/Storage.hs:278`), i.e. the wipe-and-reproject path has fired since the snapshot. `docs/deployment/` still holds only `attest-flow-smoke.md` and `koios-parity-gate.md` — the three promised runbooks (deploy/rollback, `preprod-dbsync-sync.md` referenced at `scripts/check_determinism.sh:25-26`, key rotation) are still absent. |
| TD-20 | Info | OPEN — re-judged per README §9 | §9 flagged the determinism job's new steps; they do **not** change the finding. `ci.yml:217-232` still applies the empty `test/fixtures/dbsync-skeleton.sql` + the four `sql/*.sql` and runs `check_determinism.sh` over it; the added step (`:244-257`) creates a second empty database, applies the same skeleton and `sql/050_roles.sql`, then `CREATE TABLE palmares_attest.chain_cursor (slot_no bigint)` and reads `count(*)` as `palmares_ro`. Zero rows throughout, so a plan-order nondeterminism still cannot manifest. `check_determinism.sh:22-26` documents this itself and still names a runbook that does not exist. |

**Counts:** OPEN 17 · PARTIAL 2 (`TD-08`, `TD-10`) · OPEN-with-restated-count 1 (`TD-04`) · FIXED 0 · MOOT 0 · INVALID 0.
Sub-items reached INVALID inside `TD-08` and `TD-10`; the `K3` row of §1a and the `Mp3` row are MOOT (both codes deleted).

### Trace-code coverage at HEAD

Legend for the last column: **L** = pure `ScriptContext` `(True, False)` pair against the lambda;
**E** = emulator `mustFailWith (failedWithTrace "X")`; **no** = no validator-level case (a helper-only
test is named but does not count). Code locations are under
`src/lib/onchain-lib/Palmares/Onchain/`; tests under `src/test/`.

| Code | Rule (one phrase) | Test that pins it | Validator-level? |
|---|---|---|---|
| A0 | accept arm: datum absent or unparseable (`Validators/AttestationsValidator.hs:98,100`) | — | no (structural) |
| A1 | re-lock the attestation accepted at the same address (`:164`) | `UnitTests/MutationGuards.hs:204` | yes (L) |
| A2 | spending purpose only (`:178`) | — | no (structural) |
| A3 | not already accepted (`:151`) | `UnitTests/Attestation.hs:167` | yes (E) |
| A4 | cleanup refuses a backed attestation datum (`:96`) | `UnitTests/Cleanup.hs:179` | yes (E) |
| A5 | subject's user NFT spent (`:174`) | `UnitTests/MutationGuards.hs:217` | yes (L) |
| A6 | own input holds the attestation NFT its datum names (`:177`) | `UnitTests/MutationGuards.hs:224` | yes (L) |
| A7 | **new** — a paused protocol refuses an acceptance (`:139`) | `UnitTests/MutationGuards.hs:243` **and** `UnitTests/Pause.hs:173` | yes (L + E) |
| D0 | resolve/expire arms: datum absent or unparseable (`Validators/DisputesValidator.hs:109,111,186,188`) | — | no (structural) |
| D1 | oracle admin signed the resolution (`:153`) | `UnitTests/Dispute.hs:282` | yes (E) |
| D2 | dispute returns closed, value less deposit, NFT-backed (`:232`) | `UnitTests/DisputeRules.hs:408-459` and `:585` | yes (L) |
| D3 | a verdict is written once (`:152,:197`) | `UnitTests/Dispute.hs:299` (E) and `UnitTests/DisputeRules.hs:580` (L) | yes (E + L) |
| D4 | the deposit returns to the address the opener named (`:268`) | `UnitTests/DisputeRules.hs:470-501`, `:595` | yes (L) |
| D5 | spending purpose only (`:200`) | — | no (structural) |
| D6 | exactly one dispute input per transaction (`:269`) | `UnitTests/Dispute.hs:414` (E) and `UnitTests/MutationGuards.hs:970-972` (L); helper in `UnitTests/Satisfaction.hs` | yes (E + L) |
| D7 | a paused protocol refuses a resolution (`:146`) | `UnitTests/Pause.hs:118` | yes (E) |
| D8 | cleanup refuses a backed dispute datum (`:107`) | `UnitTests/Cleanup.hs:188` | yes (E) |
| D9 | **new** — an expiry needs the stale-after instant to have passed (`:198`) | `UnitTests/DisputeRules.hs:569-576` | yes (L) |
| Da | **new** — a resolution may not name `VerdictExpired` (`:165`) | `UnitTests/DisputeRules.hs:399` | yes (L) |
| K1 | the oracle reference input is present and decodes (`Protocol/Lookup.hs:41-43`) | `UnitTests/MutationGuards.hs:916` | yes (L, observes the exception only — the code string is not assertable) |
| K2 | the configured fee is paid to the fee address (`Protocol/Lookup.hs:94`) | `UnitTests/MutationGuards.hs:1152,1160`; helper in `UnitTests/Fees.hs` | yes (L) |
| M0 | mint gate: protocol not paused (`Validators/MintingPolicy.hs:192`) | `UnitTests/MutationGuards.hs:151` | yes (L) |
| M1 | minting purpose only (`:203`) | — | no (structural; `MutationGuards.hs:903` only notes it in prose) |
| Mc1 | **new** — a credential record is self-issued (`:308`) | `UnitTests/MutationGuards.hs:337` | yes (L) |
| Mc2 | **new** — a credential record must name a credential (`:309`) | `UnitTests/MutationGuards.hs:342` | yes (L) |
| Mc3 | **new** — the named credential controls this transaction (`:310`) | `UnitTests/MutationGuards.hs:346` (L) and `UnitTests/Profile.hs:187,238,267` (E); helper in `UnitTests/Claim.hs` | yes (L + E) |
| Mc4 | **new** — only a credential record may name a credential (`:311`) | `UnitTests/MutationGuards.hs:352` | yes (L) |
| Md1 | dispute mint spends the seed its redeemer names (`:462`) | `UnitTests/MutationGuards.hs:722` | yes (L) |
| Md2 | mint exactly the dispute ref NFT, burn nothing (`:464`) | `UnitTests/DisputeRules.hs:704-718` | yes (L) |
| Md3 | the opener's user NFT is spent (`:466`) | `UnitTests/DisputeRules.hs:728-747` | yes (L) |
| Md4 | target and opener are this protocol's REF tokens (`:467`) | `UnitTests/Dispute.hs:388` (E); helper in `UnitTests/MintInputs.hs:44-73` | yes (E) |
| Md5 | lock the dispute at the disputes address (`:469`) | `UnitTests/MetadataLimits.hs:173` | yes (L — staking-half variant only; a wrong script hash is not exercised) |
| Md6 | `openedAt` inside the validity interval (`:470`) | `UnitTests/DisputeRules.hs:759-768`; helper in `UnitTests/OracleRules.hs:62-139` | yes (L) |
| Md7 | dispute metadata byte limits (`:471`) | `UnitTests/MetadataLimits.hs:136` | yes (L) |
| Md8 | the deposit address is one the opening tx spends from (`:468`) | `UnitTests/Dispute.hs:364` | yes (E) |
| Mf | issuer's user NFT spent (exempt on `CredentialWithdrawal`) (`:304`) | `UnitTests/Attestation.hs:377` | yes (E) |
| Mg | subject and issuer are this protocol's REF tokens (`:305`) | only `UnitTests/MintInputs.hs:44-73` (helper `isProtocolRefToken`) | **no** |
| Mh | attestation mint spends the seed its redeemer names (`:312`) | `UnitTests/MutationGuards.hs:717` | yes (L) |
| Mj | mint exactly the attestation NFT, burn nothing (`:314`) | `UnitTests/DisputeRules.hs:849-866` | yes (L) |
| Mk | lock the attestation at the attestations address (`:316`) | `UnitTests/MetadataLimits.hs:169` | yes (L — staking-half variant only) |
| Mm | attestation metadata byte limits (`:289`) | `UnitTests/MetadataLimits.hs:118` | yes (L) |
| Mn | `otherMetadata` bounded, keys unique and unreserved (`:290`) | `UnitTests/Attestation.hs:340` (E); helper in `UnitTests/MintInputs.hs:92-120` | yes (E) |
| Mp1 | profile mint spends the seed its redeemer names (`:347`) | `UnitTests/MutationGuards.hs:712` | yes (L) |
| Mp2 | mint exactly the profile ref + user NFT, burn nothing (`:349`) | `UnitTests/Profile.hs:289,316` | yes (E) |
| Mp4 | profile metadata byte limits (`:356`) | `UnitTests/MetadataLimits.hs:123-132` | yes (L) |
| Mp5 | lock the profile at the profiles address (`:357`) | `UnitTests/MetadataLimits.hs:171` | yes (L — staking-half variant only) |
| Mp6 | the user token must not be locked with the state output (`:379`) | — (`MutationGuards.hs:160,304` only state that the positive contexts satisfy it, and the `P3` pair deliberately avoids it) | **no** |
| Mq | attestation date inside the validity interval (`:288`) | `UnitTests/Attestation.hs:354` (E); helper in `UnitTests/OracleRules.hs:62-139` | yes (E) |
| N0 | the oracle-NFT mint spends its seed (`Validators/OracleNFTPolicy.hs:38`) | — (zero references in `src/test`) | **no** |
| N1 | minting purpose only (`:42`) | — | no (structural) |
| N2 | mint exactly the oracle NFT, burn nothing (`:40`) | `UnitTests/Oracle.hs:319,323` | yes (E) |
| O0 | oracle datum parses (`Validators/OracleValidator.hs:74`) | — | no (structural) |
| O1 | the current admin signed (`:84`) | `UnitTests/Oracle.hs:203,272,281` | yes (E) |
| O2 | the oracle returns at the named index with the computed datum (`:85`) | `UnitTests/DisputeRules.hs:921-952` | yes (L) |
| O3 | spending purpose only (`:94`) | — | no (structural) |
| O4 | oracle redeemer parses (`:77`) | — | no (structural) |
| O5 | a handover is also signed by the incoming admin (`:86`) | `UnitTests/Oracle.hs:300` | yes (E) |
| O6 | the resulting params are well-formed, no negative lovelace (`:92`) | — (`oracleParamsAreWellFormed`, `Protocol/Types.hs:202-204`, has **no test at any level**; only `ScriptSize.hs:149` mentions it) | **no** |
| P0 | update arm: datum absent or unparseable (`Validators/ProfilesValidator.hs:98,100`) | — | no (structural) |
| P1 | spending purpose only (`:136`) | — | no (structural) |
| P2 | own value holds the profile's ref NFT (`:158`) | — (baseline positive only, `MetadataLimits.hs:441`) | **no** |
| P3 | the profile's user NFT is spent (`:159`) | `UnitTests/MutationGuards.hs:310` | yes (L) |
| P4 | update metadata byte limits (`:160`) | `UnitTests/MetadataLimits.hs:143-145` | yes (L) |
| P5 | re-lock the updated profile at its own address and value (`:161`) | — (baseline positive only, `MetadataLimits.hs:113`; `:141` says in as many words that `P5` still passes with `P4` deleted) | **no** |
| P6 | a paused protocol refuses a profile update (`:134`) | `UnitTests/Pause.hs:97` | yes (E) |
| P7 | cleanup refuses a backed profile datum (`:96`) | `UnitTests/Cleanup.hs:170` | yes (E) |
| U0 | the script context parses (`Utils.hs:60`, via `parseData`, not `traceIfFalse`) | — | no (structural) |
| U1 | own input found by its `TxOutRef` (`Utils.hs:370`) | — | no (structural) |
| U2 | the state NFT sits at the expected address (`Utils.hs:449`) | — | no (**unreachable** — see NEW-TD-1) |
| U3 | the output carries an inline datum (`Utils.hs:455`) | — | no (**unreachable** — see NEW-TD-1) |

**Uncovered: 21 of 70** — `A0 A2 D0 D5 M1 Mg Mp6 N0 N1 O0 O3 O4 O6 P0 P1 P2 P5 U0 U1 U2 U3`.
Fifteen are structural arms (wrong purpose, unparseable datum/redeemer, `U0`–`U3`) whose deletion
would not compile or would break every positive test; the six that matter behaviourally are
`Mp6`, `O6`, `P2`, `P5`, `N0`, `Mg` — the audit's list minus `K3`. Of the seven codes added since
the snapshot, **all seven** (`A7`, `D9`, `Da`, `Mc1`, `Mc2`, `Mc3`, `Mc4`) landed with a
validator-level test, four of them in the commit that introduced them (`26d53f7`, `5c0042a`) and
four in `2bf5bde`; `A7` and `Mc3` got both a pure pair and an emulator case. `K3` and `Mp3` are
deleted codes and their rows are gone.

### Findings I judge wrong

- **`TD-08` arithmetic — INVALID.** "The header … is false for five of seven" and "Kupo and the
  **four** palmares images are not digest-pinned". `compose.yaml` declares six services and six
  images (`:32,:69,:106,:169,:233,:263`). Three are digest-pinned (node, Postgres, db-sync), three
  are not (Kupo by tag, `interaction-api` and `query-api` by `${TAG:-latest}`). So it is **three of
  six**, and only **two** palmares images appear in compose. The claim is also self-contradictory
  with `TD-02`, which correctly says `attest-sync` is absent from the file — `admin` is absent too.
  The substance (not digest-pinned, arm64-only, caps dropped) holds; the counts do not.
- **`TD-10` location list — partly INVALID.** It cites "`:29, :96, :102` (`actions/*@v4`,
  `haskell-actions/setup@v2`, `docker/*@v3/v6`)" against `ci.yml`. `grep -n 'uses:'
  .github/workflows/ci.yml` returns five lines and no `docker/*` action at all; the
  `docker/login-action` / `docker/build-push-action` pins live in `images.yml`. The gitleaks
  checksum, the blst branch and the missing `permissions:` block are all real.
- **`TD-03`'s fix sentence is garbled** (not the finding, the remedy): "add a `cabal build all
  --enable-tests -v1 | grep -c Compiling` sanity line is optional" is an unfinished sentence. Also
  worth stating precisely, because the audit does not: the key does not merely "hash only
  `cabal.project*`" in a way that yields a *partial* restore — a `palmares.cabal`-only change leaves
  the key **identical**, so it is an exact hit and `restore-keys` never comes into play. The finding
  is stronger than its own wording.
- **`TD-04`'s fix list names `K3`** — INVALID at HEAD. `3654f57` deleted `Protocol/Id.hs` together
  with `unsafeGetProtocolParamsFromProfileRefInput` and the `K3` code; `grep -rn '"K3"'
  src/lib/onchain-lib` is empty. The §1a `K3` row goes with it, and so does the `Mp3` row
  (`6d0a76a`). Both are MOOT, not open work.
- **§1a header counts are stale, not wrong** — "63 codes; 19 E, 25 L, 22 U" was true at `4eb9117`;
  at HEAD it is 70 codes and 21 uncovered. Likewise §0's "537 `testCase`s, 60 CLB emulator cases,
  8 fixture-gated cases" is now 559 `testCase`s, 61 `mkTestFor` cases and 10 fixture-gated cases;
  §1d's "`ScriptSize.hs:237-241` … MintingPolicy 12276" is now `:373-380` and **12618**; §8's
  "0 of 121 Haskell files" is 0 of **120**. Recording these so nobody treats the drift as a finding.
- **`U0`'s citation** — §1a places it at `Utils.hs:63`; at HEAD it is `Utils.hs:60`, and it is
  handed to a local `parseData`, not to `traceIfFalse`, which is why no `traceIfFalse` grep finds
  it. The audit's "U" verdict is right; the mechanism is worth stating because it is the one code
  that a `traceIfFalse` census silently drops.
- **Nothing I could falsify in `TD-01`, `TD-02`, `TD-06`, `TD-13`.** I specifically tried: `.gitignore:44`
  does exclude `config/config_atlas.json` while `.dockerignore` does not (so `TD-01`'s asymmetry is
  real and ADR 0002 is wrong, not the reviewer); `Auth.hs:62` really does `die`; the vocabulary
  exclusion really does hide a live hit (ran it); and `TD-13`'s "single-threaded only because the
  test-suite has no `-threaded` flag" is corroborated by the suite being green at all — 35 call
  sites sharing one per-PID database name would collide under any real concurrency.
- **One check I ran that found no finding**, recorded so it is not re-run: `A7` makes the oracle
  reference input mandatory on every `AcceptAttestation` (via `attestationOracleToken` →
  `readOracleParams` → `K1`). `acceptAttestationTX`
  (`src/lib/offchain-lib/Palmares/TxBuilding/Operations.hs:614-618`) does call
  `getOracleAndValiditySkeleton` and includes `oracleRefSkeleton` in the `mconcat`, so the
  production accept path is wired for D-C. No regression.

### New findings

- **NEW-TD-1 — `U2` and `U3` are trace codes in unreachable code.**
  `Utils.checkAndGetCurrentStateDatumAndValue` (`src/lib/onchain-lib/Palmares/Onchain/Utils.hs:444-450`,
  holding `U2`) has no caller anywhere in `src` — only its own export (`:21`) and a Haddock at
  `Protocol/Lookup.hs:7` claiming "every validator reads a profile through
  `Utils.checkAndGetCurrentStateDatumAndValue` directly", which `git grep` refutes.
  `checkAndGetInlineDatum` (`:451-455`, holding `U3`) is called from exactly one place: that dead
  function (`:448`). So two of the 70 codes can never be emitted by any script, they inflate the
  `TD-04` untested count for no reason, and they are compiled into every validator's size budget.
  Why it matters: `TD-04`'s remedy list should not grow to cover them, and the right fix is deletion
  (hash-affecting, so it belongs with the other pre-deploy hash moves) rather than a test.
  README §9 noticed the false Haddock; the dead-code consequence is unrecorded.
- **NEW-TD-2 — `O6`'s predicate has no test at any level, not just no validator-level one.**
  `oracleParamsAreWellFormed` (`src/lib/onchain-lib/Palmares/Onchain/Protocol/Types.hs:202-204`) is
  exported and referenced by exactly one call site (`Validators/OracleValidator.hs:92`) and by three
  comments in `src/test/UnitTests/ScriptSize.hs`. `grep -rn oracleParamsAreWellFormed src/test`
  finds no test. Every other guard of this shape has at least a pure predicate suite
  (`Fees.hs` for `feeFor`, `Claim.hs` for `checkCredentialControl`, `Satisfaction.hs` for
  `spentExactlyOnceFromAddress`, `MintInputs.hs` for `isProtocolRefToken`). Why it matters: `O6`
  defends against a negative lovelace parameter that, per the validator's own comment, "would make
  every min-value check in the protocol vacuous" — and a six-line pure test costs nothing, so the
  `TD-04` effort estimate of M for this code is wrong by an order of magnitude.
- **NEW-TD-3 — ten live references to `Mp3`, a trace code ADR 0003 deleted, three of them in
  off-chain Haddock that describes the write path.**
  `src/test/TestRuns.hs:476,485,524`, `src/test/UnitTests/MetadataLimits.hs:361,364`
  ("a complete `MintProfile` mint: `Mp1`, `Mp2`, `Mp3`, `Mp5` and `Mp6` all pass as given"),
  `src/test/UnitTests/MutationGuards.hs:505`, plus
  `src/lib/offchain-lib/Palmares/TxBuilding/Utils.hs:80`,
  `Palmares/TxBuilding/Operations.hs:217` ("a required signer and `Mp3` finds it in
  `txInfoSignatories`") and `Palmares/DomainTypes/Core/Actions.hs:267`. `6d0a76a` was careful to
  record the burn in the validator (`Validators/MintingPolicy.hs:350-356`,
  `Validators/ProfilesValidator.hs:163-167` for `P8`/`P9`) but swept no call-site prose. Why it
  matters: `TD-15` lists `@Ml@` as the stale-code case; this is the same failure one commit later
  and in a worse place — `Operations.hs:217` tells a maintainer that the off-chain builder satisfies
  a rule that no longer exists, on the path ADR 0003 rewrote.
- **NEW-TD-4 — `palmares.cabal:81-82` is a self-defeating comment: it was written to correct a
  stale script size and is now three size moves stale itself.**
  It reads "`UnitTests.ScriptSize` is the authority on the current size and says 12296" and
  "the byte saving buys nothing at ~75% occupancy"; `ScriptSize.hs:373-380` pins MintingPolicy at
  **12618** (12296 → 12276 → 12310 → 12618 across `ScriptSize.hs:156,173,246,357`), i.e. 77 %.
  Why it matters beyond `TD-15`'s general sweep: this specific number is quoted as the justification
  for the `preserve-logging` owner decision, there is no gate that couples the two (CI diffs
  `docs/metrics.md` and both Swaggers, nothing diffs this), and the comment itself asserts which
  file is authoritative — so the cheap fix is to delete the number and keep the pointer.
</content>
</invoke>

---

## 6. [`06-docs-spec-and-product-gaps.md`](06-docs-spec-and-product-gaps.md)
Snapshot cited by the report: `4eb9117`. Code read at: `2bf5bde` (worktree `/private/tmp/palmares-audit`).

Files the report cites that have **zero** changes since the snapshot, so every line number in them still
resolves: `README.md`, `.env.example`, `compose.yaml`, `NOTICE`, `docs/adr/0001`, `docs/adr/0002`,
`docs/deployment/attest-flow-smoke.md`, `docs/deployment/koios-parity-gate.md`,
`src/lib/onchain-lib/Palmares/Onchain/Blueprint.hs`, `src/lib/webapi-lib/Palmares/WebAPI/{Utils,CORS,Auth,Envelope}.hs`,
`src/exe/CLAUDE.md`, `src/test/CLAUDE.md`, `src/lib/offchain-lib/CLAUDE.md`,
`scripts/smoke_interaction_api.sh`, `scripts/smoke_query_api.sh`.

| ID | Sev. | Status | Evidence |
|---|---|---|---|
| DC-01 | High | OPEN | `docs/metrics.md:10-12` still "`Query.Metrics` looks each statement up"; no such module (`src/lib/offchain-lib/Palmares/Metrics/` holds only `Catalog.hs`, `Doc.hs`) |
| DC-02 | High | OPEN | `README.md:31-33` unchanged; every write route behind `BasicAuth` at `src/exe/interaction-api/RestAPI.hs:269,279`; local-node provider at `compose.yaml:240-243` |
| DC-03 | High | OPEN | `README.md:143-144`; only `src/lib/webapi-lib/Palmares/WebAPI/Auth.hs:56-57` reads them; admin's env reads are `src/exe/admin/Main.hs:737-738,922` |
| DC-04 | High | OPEN | fail-open defaults still there: `src/exe/query-api/Main.hs:31-32` (read at `:87`), `src/exe/attest-sync/Main.hs:50-55` (read at `:76`) |
| DC-05 | High | OPEN | `src/exe/attest-sync/Main.hs:81,84` both `die`; `README.md:147-148` still says "interaction-api, admin" |
| DC-06 | Medium | OPEN | `BATCH_SIZE` read nowhere in `src`; `FETCH_BATCH_SIZE` default `10_000_000` at `src/exe/attest-sync/Main.hs:114`; CORS read by three services (`src/exe/attest-sync/Main.hs:73`) and never dies (`CORS.hs:37-44`) |
| DC-07 | Medium | OPEN | `README.md:138`; the 11 undocumented names all still read — see census below; no name added or removed since the snapshot |
| DC-08 | Medium | OPEN | `src/test/Test/Pg.hs:12-14,48-53` dies; `README.md:104-110` has no Postgres step; `src/test/CLAUDE.md:46-48` still "run with no database" |
| DC-09 | Medium | OPEN | `docs/generated/` = `.gitkeep` + `swagger/`; `Constants.hs:26-27` names an absent file; `.github/workflows/ci.yml` has no `write-blueprint` step |
| DC-10 | Medium | OPEN | `README.md:53`; compose services are `cardano-node:32 postgres:69 cardano-db-sync:106 kupo:169 interaction-api:233 query-api:263` — no `attest-sync` |
| DC-11 | Medium | OPEN | `deploy/` holds only `dbsync/db-sync-config.yaml` + `node-config/*`; `README.md:133-134` unchanged |
| DC-12 | Low | OPEN | `README.md:62-71` table unchanged; `src/test/PropertyTests.hs:23-29` ("the plan asked for hedgehog. Neither arrived"); `mkPrivnetTestFor` appears only at `src/test/CLAUDE.md:16` |
| DC-13 | Medium | OPEN | `CLAUDE.md:57` still `query-api/Metrics/Catalog.hs`, `:60` still `Query/Projected.hs`; real catalog at `palmares.cabal:228`; four dormant modules at `palmares.cabal:358,363,365,366`; `src/exe/CLAUDE.md:55` still `Query/Metrics.hs` |
| DC-14 | Low | PARTIAL | root fixed by `3654f57` (`CLAUDE.md:37,49` no longer name `Id.hs`); **`src/lib/offchain-lib/CLAUDE.md:78` still says "ID derivation (`Id.hs`)"** and the module is now deleted, so it points at a nonexistent file |
| DC-15 | Low | OPEN | `CLAUDE.md:83`, `src/exe/CLAUDE.md:20,81`; `src/exe/query-api/Main.hs:39-55` writes Swagger only under `--write-swagger-only` |
| DC-16 | Low | OPEN | `CLAUDE.md:51` "New validator" row still omits `Onchain/Blueprint.hs`, `admin/Main.hs`, the validators JSON, the `KUPO_MATCH` note and `Storage.hs`/`Ingestion.hs` |
| DC-17 | High | OPEN | `src/exe/CLAUDE.md:42-43`; real context = six fields, no auth, no provider (`src/exe/query-api/QueryAppMonad.hs:30-48`, stated at `:7-15`); second pool at `src/exe/query-api/Main.hs:100-104` |
| DC-18 | High | OPEN | `src/exe/CLAUDE.md:77-78`; `grep -i 'rate.?limit'` finds only prose: `Envelope.hs:114-117`, `RestAPI.hs:9`, `QueryAppMonad.hs:14`; sole guard is `SET LOCAL statement_timeout` at `Query/Gov.hs:255` |
| DC-19 | Medium | OPEN | `src/exe/CLAUDE.md:47`; live module is `src/exe/query-api/Query/Attest.hs:13` with 10 `rawSql` call sites and no esqueleto |
| DC-20 | Medium | OPEN | `src/exe/CLAUDE.md:50-52`; `sql/000_schema.sql:10-11` is `DROP SCHEMA … CASCADE`; `grep` over `sql/*.sql` = 19 `CREATE VIEW`, 1 matview, 1 function, **0** `CREATE OR REPLACE` |
| DC-21 | Medium | OPEN | `src/exe/CLAUDE.md:58-59`; `readyVerdict` now has five guards at `src/exe/query-api/Query/Gov.hs:345-361` |
| DC-22 | Low | OPEN | `mkPalmaresApp` 0 refs vs `mkWebApp` (`interaction-api/RestAPI.hs:312`, `query-api/RestAPI.hs:1879`); `runActionWithPK` at `TxBuilding/Transactions.hs:127`; `FullAPI` has five arms at `interaction-api/RestAPI.hs:285-290`; probe returns 200 for `Behind False` at `attest-sync/ChainsyncAPI.hs:60-63` |
| DC-23 | Medium | OPEN | `src/lib/onchain-lib/CLAUDE.md:31,87`; `OracleNFTPolicy.hs:57` is `TxOutRef -> CompiledCode …`, `MintingPolicy.hs:486` is `ProtocolParams -> …` |
| DC-24 | Medium | OPEN | `src/lib/onchain-lib/CLAUDE.md:79-80`; `attestationPeriod` at `Protocol/Types.hs:414` is still deliberately unbounded |
| DC-25 | Low | PARTIAL | code half done by `3654f57` (`Protocol/Lookup.hs:5-10` records the three deletions); **`src/lib/onchain-lib/CLAUDE.md:81-83` still says "the `unsafeGet*` profile helpers are currently UNCALLED"**, naming functions that no longer exist |
| DC-26 | Low | OPEN (worse) | `src/lib/onchain-lib/CLAUDE.md:9` "under ~80 lines"; at HEAD `disputesLambda` spans 132 lines (`DisputesValidator.hs:86-217`, 38 non-comment) and `attestationsLambda` 107 (`AttestationsValidator.hs:81-187`, 39 non-comment) |
| DC-27 | Low | PARTIAL | `src/lib/offchain-lib/CLAUDE.md:26-27` still names `utxoDatum'`/`utxosDatums` (0 refs in `src`); the `:92` "architecture docs" half is closed — `docs/architecture/` holds 4 docs + `diagrams/` since `fc550c9` |
| DC-28 | Medium | OPEN | `docs/adr/0001-governance-data-substrate.md:12` "fourteen" vs `:60`/`:107` "nineteen"; measured 19/1/1 |
| DC-29 | High | OPEN | `docs/adr/0002-write-path-provider.md:3` `Status: proposed`, `:8-9` "token is supplied from the environment", `:28` "only secret"; file untouched |
| DC-30 | Low | OPEN | `src/exe/attest-sync/Main.hs:52` cites ADR 0001 for role separation; ADR 0001 still has no roles paragraph. Note the report's proposed number ("ADR 0003 Co-location and role separation") is now taken by ADR 0003 |
| DC-31 | Low | PARTIAL (status half INVALID) | `docs/adr/0001:38-39` T1–T7 and `:46` T-SUBSTRATE-3/4 still unresolvable → open. The "Status accepted while PVC is open" half was already false at `4eb9117`: `git show 4eb9117:docs/adr/0001-…md` line 3-4 reads "accepted; … (PVC sizing and the memory fork still open — see the fork below)" |
| DC-32 | Medium | OPEN (doubly stale) | `docs/deployment/attest-flow-smoke.md:138-142` unchanged; `/ready` now sums the projector lag (`Query/Gov.hs:360`) **and** `/status` now publishes `attest_lag_seconds` (`9a8d79b`, asserted at `scripts/check_swagger.sh:131-132`), so both halves of the paragraph are false |
| DC-33 | Medium | OPEN | `src/lib/webapi-lib/Palmares/WebAPI/Utils.hs:44` still "Bech32-encoded Cardano address"; shipped in `docs/generated/swagger/interaction-swagger-api.json` |
| DC-34 | Low | OPEN | "F1 check N" cited by 7 scripts/workflows with no checklist in `docs/`; `operation.prv` is a 24-word mnemonic (`src/exe/admin/Main.hs:50-51,273,787-788`); `README.md` silent, `CLAUDE.md:15` says only "admin key" |
| DC-35 | High | OPEN | `src/exe/interaction-api/RestAPI.hs:243` `& info . license ?~ "GPL-3.0 license"`; the generated doc's `info.license.name` is `"GPL-3.0 license"`; `scripts/check_swagger.sh:14` still defaults to the query document only |
| DC-36 | Low | OPEN | `addSharedSwaggerDescriptions` called only at `interaction-api/RestAPI.hs:254`; `GYTime`, `GYPubKeyHash`, `DRepId`, `GovActionId` are absent from **both** generated documents (checked by loading the JSON) — still four silent no-ops |
| DC-37 | Low | OPEN | four numbers, two of which moved: see version census below |
| DC-38 | Low | OPEN | `DomainTypes/Core/Types.hs:47` and `:64` still say `person_drep`; both documents publish `person_d_rep`. Bonus: `:65-66` claims "`ProfileType` is absent from both generated Swagger documents today" — it is present in both |
| DC-39 | Low | OPEN | `palmares.cabal:19-21` says the globs are commented out (they are live at `:30-32`); `:40-41` still the stale duplicate; `:97-99` says every module list is comment-prefixed (only four are, `:358,363,365,366`); `:377` ✓ true |
| DC-40 | High | OPEN | `compose.yaml:231-232` `operation.prv` comment; `:236-245` has no `BASIC_USER`/`BASIC_PASS` and no `env_file`; `:246-250` mounts `node-ipc` + `./config` only; `Auth.hs:54-62` dies |
| DC-41 | Low | OPEN | `.env.example:4` still "interaction-api + admin"; `:19` `BATCH_SIZE`; `:20` `FETCH_BATCH_SIZE=100000` |
| DC-42 | Low | OPEN | `NOTICE:11-12`; the only in-repo hit for "license report" is `NOTICE` itself |
| DC-43 | High | OPEN | no `docs/spec/`; `docs/` = `adr architecture audit deployment generated metrics.md`; 10 `spec §` citations survive in `src` (e.g. `Protocol/Types.hs:325,465`, `MintingPolicy.hs:108`, `UnitTests/Claim.hs:6`); `docs/metrics.md` still carries 8 `docs/superpowers/design/f1-*.md` links |
| PG-01 | — | OPEN | no `web/`, `frontend/` or `explorer/`; `README.md:6-7,29-30,53` unchanged |
| PG-02 | — | OPEN | `compose.yaml` untouched: no `attest-sync` service, write profile still missing `BASIC_*` |
| PG-03 | — | OPEN (worse) | `.github/workflows/images.yml:74,116` still `platforms: linux/arm64`; ADR 0002 still `proposed`; no blueprint, no manifests; and three further validator-hash moves landed (`26d53f7`, `800a39d`, `6d0a76a`) |
| PG-04 | — | PARTIAL | DRep-id printer half FIXED by `39365fe` (`src/exe/admin/Main.hs:837-840`), `set-dispute-timeout` added (`:74`); still absent from `Command` (`:62-84`): `claim-profile`, `open-dispute`, `resolve-dispute`, any `palmares_attest` read — and now also `claim-credential`, `withdraw-credential`, `expire-dispute` |
| PG-05 | — | OPEN | `docs/adr/0002` and `compose.yaml:204-205` both untouched |
| PG-06 | — | OPEN (worse) | `README.md:33` is the only CIP-95 mention in the repo; the only signer is `admin sign-tx`; ADR 0003 makes a credentialled profile need **two** signed transactions (`/claim-profile` then `/claim-credential`) |
| PG-07 | — | OPEN (wording) | `.github/workflows/reconcile.yml` unchanged: nightly, `continue-on-error`, pinned sample |
| PG-08 | — | PARTIAL | the "`attest-sync` lag not on `/status`" half is CLOSED by `9a8d79b` (`scripts/check_swagger.sh:131-132`); still no Prometheus endpoint on our services (only Kupo's, `compose.yaml:218`) and no alerting |
| PG-09 | — | OPEN (wording) | CSV on the governance list routes (`query-api/RestAPI.hs:298,418,567,743,…`); none for attestations by design |
| PG-10 | — | MOOT | the report itself concludes "not a gap"; offset pagination + `/activity` cursor unchanged. It should not carry a PG id |
| PG-11 | — | OPEN (restated) | six profile kinds ✓, but attestation kinds are now **seven** — `AttestationKind` gained `CredentialClaim`/`CredentialWithdrawal` (`Protocol/Types.hs:341-360`) and both documents publish 7; `person_d_rep` still undecided |
| PG-12 | — | OPEN | nothing under `docs/generated/` but `.gitkeep` and `swagger/`; no CI step |
| PG-13 | — | OPEN | no rate limiting in `src`, `compose.yaml` or `.github` |
| PG-14 | — | OPEN | `AttestationRow` in the query document has `accepted`/`subject` and no `subject_kind` or three-valued status |
| PG-15 | — | OPEN | `AttestationRow` has no `dispute_count`; `AttestProfileRow` has no `claimant_count` (both read off `docs/generated/swagger/query-swagger-api.json`) |
| PG-16 | — | OPEN (holds) | no Koios read in the serving path, no composite-score field in any DTO |

Read-layer obligations re-graded at HEAD: **RL-1 PASS**, **RL-2 PASS**, **RL-3 PARTIAL**, **RL-4 FAIL**,
**RL-5 PASS**, **RL-6 PARTIAL** — unchanged. `AttestProfileRow` still publishes
`credential`/`credential_is_script` and no claim status; `AttestationRow` still publishes neither
`subject_kind` nor any dispute marker; disputes are still inlined on the detail route only
(`Query/Attest.hs:362-381`, bound 50 at `:423`). ADR 0003 adds one wrinkle worth a line:
`attestation_projection` now stores `attestation_credential` (`Storage.hs:149`) but **no published DTO
exposes it**, so a `credential_claim` attestation is served as a row whose whole content — which
credential — is invisible.

### Environment-variable census at HEAD

The *set* of names the code reads has not drifted: the same 21 runtime names and 2 test names as the
report's Appendix A. Only the line numbers moved, and the README is byte-identical, so every wrong
row is still wrong. Corrected table:

| Variable | Read by (file:line at HEAD) | Code default | Fail-closed? | README §11 verdict |
|---|---|---|---|---|
| `BASIC_USER`, `BASIC_PASS` | `webapi-lib/.../Auth.hs:56-57` ← `interaction-api/Main.hs` | none | yes (`die` at `Auth.hs:62`) | **wrong** — `:143-144` says "interaction-api, admin"; admin reads neither |
| `CORS_ALLOWED_ORIGINS` | `webapi-lib/.../CORS.hs:39` ← query-api, interaction-api, `attest-sync/Main.hs:73` | `[]` | **no** (silent deny-all) | **wrong** — `:145` says "required … both APIs"; neither is true |
| `PG_CONN_STR` | `query-api/Main.hs:87`, `attest-sync/Main.hs:76` | `host=postgres user=postgres password=postgres dbname=cexplorer port=5432` / `host=localhost …` | **no** | **wrong** — `:146` says "required"; unset starts against a guessed DB with a guessed password |
| `PALMARES_PG_OWNER_CONN_STR` | `query-api/Main.hs:100` | falls back to `PG_CONN_STR` | n/a | **missing** (only `.env.example:15`) |
| `ATLAS_CORE_CONFIG` | `interaction-api/Main.hs:58`, `attest-sync/Main.hs:81`, `admin/Main.hs:845,897` | `config/config_atlas.json` | yes, all three | **incomplete** — `:147` omits `attest-sync`, i.e. the read path |
| `DEPLOYED_VALIDATORS_CONFIG` | `interaction-api/Main.hs:59`, `attest-sync/Main.hs:84`, `admin/Main.hs:886` | `config/config_palmares_validators.json` | yes for the two services | **incomplete** — `:148` omits `attest-sync` |
| `PORT` | `webapi-lib/.../Utils.hs:20` ← `8082`/`8083`/`8084` (`interaction-api/Main.hs:69`, `query-api/Main.hs:126`, `attest-sync/Main.hs:72`) | per service | no | ✓ |
| `KUPO_URL` | `attest-sync/Main.hs:75` | `http://localhost:1442` | no | ✓ |
| `BATCH_SIZE` | **nowhere** | — | — | **delete** — `:151` and `.env.example:19` |
| `FETCH_BATCH_SIZE` | `attest-sync/Main.hs:113-114` | `10_000_000` | no | **wrong** — `:152` and `.env.example:20` say `100000` |
| `ROLLBACK_MARGIN` | `attest-sync/Main.hs:117-118` ← `Constants.hs:34-35` | 2160 | no | ✓ |
| `PALMARES_VIEW_REFRESH_SECONDS` | `query-api/Query/Refresh.hs:103-106` | 300 | no | ✓ |
| `PALMARES_READY_MAX_LAG_SECONDS` | `query-api/Query/Gov.hs:377`; also `admin/Reconcile.hs:93` | 300 | no | ✓ (the admin use is still undocumented) |
| `PALMARES_AMBER_LAG_SECONDS` | `query-api/Query/Gov.hs:381` | 120 | no | ✓ |
| `PALMARES_FRESHNESS_POLL_MS` | `query-api/Query/Gov.hs:385` | 5000 | no | **missing** |
| `PALMARES_NETWORK_NAME` | `query-api/Query/Gov.hs:393` | `preprod` — drives `/ready`'s network check (`Gov.hs:350`) | no | **missing** |
| `PALMARES_ADMIN_CONN_STR` | `admin/Main.hs:922` | none | yes | **missing** |
| `PALMARES_OWNER_PASSWORD`, `PALMARES_RO_PASSWORD` | `admin/Main.hs:737-738` | none | yes | **missing** |
| `PALMARES_API`, `KOIOS_API`, `KOIOS_API_TOKEN` | `admin/Reconcile.hs:91-92,403` | `""` / preprod Koios / none | `reconcile_koios.sh` requires `PALMARES_API` | **missing** |
| `PALMARES_TEST_PG_CONN_STR`, `PALMARES_FIXTURE_PG_CONN_STR` | `src/test/Test/Pg.hs:48`, `src/test/UnitTests/MetricFixture.hs:241` | none | test `die`s / fixture skips | **missing** |
| `MAESTRO_API_KEY` | nowhere | — | — | ✓ correctly excluded (`README.md:158`) |

Net: 14 README rows, 6 wrong or incomplete, 11 names absent, 1 name documented that nothing reads.
Identical to the snapshot's finding — nothing in the last 14 commits touched `README.md` §11 or
`.env.example`.

### Version census at HEAD

| Thing | Value | Source |
|---|---|---|
| query-api Swagger `info.version` | **1.2.0** | `src/exe/query-api/RestAPI.hs:1738`; same in `docs/generated/swagger/query-swagger-api.json` |
| interaction-api Swagger `info.version` | **3.1.0** | `src/exe/interaction-api/RestAPI.hs:241`; same in `docs/generated/swagger/interaction-swagger-api.json` |
| `appVersion` reported by every probe | **1.0.0** | `src/lib/offchain-lib/Palmares/Constants.hs:30-31` |
| cabal package version | **0.1.0** | `palmares.cabal:3` |

**Verdict: still inconsistent, and further apart than at the snapshot.** Two of the four moved
(`1.0.0`→`1.2.0` across `9a8d79b` and `6d0a76a`; `3.0.0`→`3.1.0` across `26d53f7` and `6d0a76a`) while
`appVersion` and the cabal version did not. The collision the report pointed at is now live: the query
document's `1.2.0` and the probes' `appVersion = 1.0.0` are different numbers in the same namespace,
served by the same process. DC-37 stands, and the drift is evidence for its "derive all three from the
cabal version, or document that the API versions are contract versions" fix rather than against it.

### Stale documentation ADR 0003 created

ADR 0003 (`6d0a76a`) and the two decisions before it (`26d53f7` D-C/D-A, `800a39d` D-E, now superseded)
removed `OnchainProfile.profileCredential`, rule `Mp3`, `MintProfile`'s credential argument, the
`RevokeCredential` redeemer and `/revoke-credential`, and added `CredentialClaim`/`CredentialWithdrawal`,
`attestationCredential`, `attestationOracleToken`, `disputeStaleAfter`, `ExpireDispute`, `VerdictExpired`,
`opDisputeTimeoutMs`, `/claim-credential`, `/withdraw-credential` and `/expire-dispute`. The source
Haddocks were mostly rewritten with it; **the published artefacts and the scripts were not.**
`src/lib/onchain-lib/Palmares/Onchain/Blueprint.hs` has a byte-identical diff against `4eb9117`.

| ID | Sev. | Location | The stale sentence | Correction |
|---|---|---|---|---|
| NEW-DC-1 | High | `scripts/smoke_attest_flow.sh:304-308` | `'{kind:"person_d_rep",name:$n,description:$d,image_uri:$i, credential:$c,witness:{tag:"key"},user_addresses:$ua}'` POSTed to `/claim-profile` | `ClaimProfileRequest` has neither field (`ServiceRequests.hs:47-54`). Split step 2: `/claim-profile` without them, then a new step posting `/claim-credential` with the credential and witness, signed |
| NEW-DC-2 | High | `scripts/smoke_attest_flow.sh:326`, `:393-395` | "`assert "/profiles/$SUBJECT" '[.credential != null, .credential_is_script]' '[true,false]'`" and "`assert "/profiles/by-credential/$ATTEST_SMOKE_DREP_ID" '.total >= 1'`" | With NEW-DC-1 unfixed the subject has no credential claim, so `profile_credential` derives to `null` and both assertions fail. They must move after the new `/claim-credential` step and poll for its projection |
| NEW-DC-3 | High | `scripts/smoke_interaction_api.sh:64` | `assert /swagger-api.json '.info.version' '"3.0.0"'` | The served document is `3.1.0` (`interaction-api/RestAPI.hs:241`). The script fails on a correct deployment |
| NEW-DC-4 | High | `scripts/smoke_interaction_api.sh:65-67` | `assert /swagger-api.json '[.paths\|keys[]]\|length' '12'` and a loop over nine route names | 15 paths now. Bump to 15 and add `/expire-dispute`, `/claim-credential`, `/withdraw-credential` to the loop — the pattern `scripts/check_swagger.sh:122` already uses (assert the set, not the count) |
| NEW-DC-5 | High | `src/exe/interaction-api/ServiceRequests.hs:66-70` | "Mint a profile, optionally claiming a Cardano credential. … `witness` says how the input that proves control of `credential` is spent; both are omitted for an unclaimed profile." — and `describeField "credential" …` at `:70` | Both properties are gone; the sentence ships in `docs/generated/swagger/interaction-swagger-api.json`'s `ClaimProfileRequest.description`, where its `properties` are only `kind name description image_uri user_addresses recipient`. Rewrite to the `:42-46` Haddock's text and move the `credential` field description to the `/claim-credential` request; `describeField "credential"` is now a silent no-op of exactly the class DC-36 is about |
| NEW-DC-6 | High | `src/lib/onchain-lib/Palmares/Onchain/Blueprint.hs:265-266` | "its kind (one of MilestoneDelivered, AuditPassed, Affiliation, RoleHeld, Endorsement)" | Seven constructors now (`Protocol/Types.hs:341-360`). Add `CredentialClaim` and `CredentialWithdrawal` |
| NEW-DC-7 | High | `src/lib/onchain-lib/Palmares/Onchain/Blueprint.hs:271-272` | "No validator branches on the kind — it says what a reader is being told, not what the protocol permits." | False since ADR 0003: `MintingPolicy.hs:276-307` branches on the kind for `Mc1`–`Mc4` (`Mc3` requires the credential's proof for the two credential kinds, `Mc4` requires its absence for the other five). Replace with "no validator branched on the kind until ADR 0003; the two credential kinds are the exception, and `Mc3`/`Mc4` are the rules" |
| NEW-DC-8 | Medium | `src/lib/onchain-lib/Palmares/Onchain/Blueprint.hs:163-164` | "NewAttestation seedTxOutRef metadata otherMetadata subject issuer kind date claimedPeriod outputIdx" | The constructor now takes `(Maybe Credential)` before the index (`MintingPolicy.hs:106,116`). Insert `claimedCredential`; a client decoding positionally off this prose builds a wrong redeemer |
| NEW-DC-9 | Medium | `src/lib/onchain-lib/Palmares/Onchain/Blueprint.hs:264-267` | "CIP-68 datum carrying the attestation: its id, the subject…, the issuer…, its kind…, the date it was ISSUED, an optional CLAIMED PERIOD, and whether the subject has accepted." | Omits `attestationCredential` (`Protocol/Types.hs:428`, ADR 0003) and `attestationOracleToken` (`:445`, D-C). Add both, and say the oracle token is what `A7` authenticates the pause through |
| NEW-DC-10 | Medium | `src/lib/onchain-lib/Palmares/Onchain/Blueprint.hs:310-315` | "ResolveDispute verdict outputIdx — the oracle admin records VerdictUpheld or VerdictRejected … Cleanup — permissionless dust removal" | `DisputesRedeemer` has a third arm at index 2 (`DisputesValidator.hs:72-79`): `ExpireDispute outputIdx`, which **anyone** may call after `disputeStaleAfter`. Add it — this is the only permissionless state transition in the protocol and the published blueprint does not mention it |
| NEW-DC-11 | Medium | `src/lib/onchain-lib/Palmares/Onchain/Blueprint.hs:297-299` | "a verdict is written once and cannot be rewritten. The deposit returns to the address the disputer named, on EITHER verdict" | Three verdicts now (`Protocol/Types.hs:468-482`: `VerdictUpheld`, `VerdictRejected`, `VerdictExpired`). "EITHER" → "any"; and the clause about the admin writing the verdict needs "or the timeout closing it with no decision" |
| NEW-DC-12 | Medium | `src/lib/onchain-lib/Palmares/Onchain/Blueprint.hs:325-330` | "CIP-68 datum carrying the dispute: its id, the attestation it contests, the profile that opened it, when it was opened, the deposit AMOUNT ACTUALLY PAID and the address it returns to, the oracle token …, and the verdict once set." | Omits `disputeStaleAfter` (`Protocol/Types.hs:556`, D-A) — the deadline the permissionless exit keys off, and the one field a client needs to show "expirable in N days" |
| NEW-DC-13 | Medium | `src/lib/onchain-lib/Palmares/Onchain/Blueprint.hs:373-375` | "Inline datum with the operational parameters: the admin public key hash, the pause flag, the minimum UTxO value, and an optional fee configuration (fee address plus per-action amounts)." | `OracleParams` has six fields (`Protocol/Types.hs:75,77,79,81,93,114`): also `opDisputeDeposit` and `opDisputeTimeoutMs`. The first omission predates ADR 0003 (raised as report 01's `B:373-375`); D-A added the second |
| NEW-DC-14 | Medium | `src/lib/onchain-lib/Palmares/Onchain/Blueprint.hs:346-353` | "This is how the protocol is paused, repriced (fees, minimum UTxO, and the dispute deposit for NEW disputes …) or re-keyed … Re-keying is OracleSetAdmin" | `OracleAdminAction` gained `OracleSetDisputeTimeout` at index 6 (`Protocol/Types.hs:151`). Add the dispute timeout to the repricing list |
| NEW-DC-15 | Medium | `src/lib/onchain-lib/Palmares/Onchain/Blueprint.hs:251-252` | "AcceptAttestation outputIdx — the subject accepts, flipping the acceptance flag and returning the token to this validator." | D-C made acceptance read the oracle through `attestationOracleToken` and refuse while paused (`AttestationsValidator.hs:139`, rule `A7`, the first unconditional conjunct). Say so — and that the transaction therefore needs the oracle UTxO as a reference input, which a client must supply |
| NEW-DC-16 | Medium | `src/lib/webapi-lib/Palmares/WebAPI/Utils.hs:54-59` | "What an attestation asserts about its subject: milestone_delivered …, audit_passed …, affiliation …, role_held …, endorsement. No validator branches on it: the kind says what a reader is being told, not what the protocol permits." | Published as `AttestationType.description` in **both** generated documents while the `enum` beside it lists seven values. Same two corrections as NEW-DC-6 and NEW-DC-7 |
| NEW-DC-17 | Medium | `docs/deployment/attest-flow-smoke.md:16-24` | the five-row "flow step / admin CLI command / over HTTP" table, closing "So the script goes over HTTP for all six, uniformly" | The flow now needs a sixth step (`/claim-credential`), and the API has three more routes with no CLI command (`/claim-credential`, `/withdraw-credential`, `/expire-dispute`). Add the rows; `/expire-dispute` is the one that needs **no** signature from any privileged party |
| NEW-DC-18 | Medium | `docs/deployment/attest-flow-smoke.md:96-100` | "**`ATTEST_SMOKE_DREP_ID` must be the DRep credential of the key the signer signs with.** Claiming a key credential puts `mustBeSignedBy <that key hash>` into the transaction (`TxBuilding/Operations.hs`, `claimProofSkeleton`)" | Still true of `claimProofSkeleton` (`Operations.hs:241-249`, now called from `:531`) but no longer of the profile mint: the requirement moved to the `/claim-credential` transaction. Name that route |
| NEW-DC-19 | Medium | `src/lib/offchain-lib/Palmares/Storage.hs:123-125` | "profileCredential is the CIP-129 rendering of the credential **the datum claims**, and it carries NO unique constraint on purpose" | Contradicts the same file at `:273-276` ("stopped being read off the profile datum and became a value derived from the attestation stream"). Rewrite the first clause to the derivation; the no-unique-constraint reason still holds and should stay |
| NEW-DC-20 | Low | `src/lib/offchain-lib/Palmares/TxBuilding/Operations.hs:216-217` | "a __key__ credential is proven by the transaction carrying its signature, so this adds a required signer and `@Mp3@` finds it in `@txInfoSignatories@`" | `Mp3` is burnt. The rule is now `Mc3` (`MintingPolicy.hs:276`) |
| NEW-DC-21 | Low | `src/lib/offchain-lib/Palmares/TxBuilding/Utils.hs:79-80` | "The same output shape at the Profiles address forges a profile that claims a victim's governance credential with no `@Mp3@` proof." | A profile claims no credential any more. Either retarget the sentence at the Attestations address and `Mc3`, or state it as the historical shape it now is |
| NEW-DC-22 | Low | `scripts/check_swagger.sh:116` | "# The five attestation kinds, as wire spellings." | Immediately contradicted by its own `:119-123` ("Seven since ADR 0003") and by the assertion. Delete the heading's "five" |
| NEW-DC-23 | Low | `docs/architecture/onchain-protocol.md:179,412,521,540,544,614`; `docs/architecture/onchain-flows.md:212,793-794,823,829` | e.g. `onchain-protocol.md:412` "`profileCredential :: Maybe Credential`"; `:521` the `Mp3` rule row; `:544` "MintProfile — spend the seed (`Mp1`); if a credential is claimed, prove control of it (`Mp3`)"; `:614` "`profileCredential` and `profileKind` are never re-validated" | These four documents (194 KB) were committed at the snapshot (`fc550c9`) and describe the pre-ADR-0003 protocol throughout, including the rule table, the ER diagram and the datum inventory. They are the longest-lived description of the removed field. Either stamp them "as of `4eb9117`" like the audit series, or regenerate the three affected sections |

### Items I judge wrong

- **DC-31, the status half — INVALID when written.** The report says ADR 0001 is "`Status: accepted` while
  the PVC verdict is 'open' (`:65`)". At the snapshot the status line already read "accepted; … (PVC sizing
  and the memory fork still open — see the fork below)" (`git show 4eb9117:docs/adr/0001-governance-data-substrate.md`,
  lines 3-4). The disclosure the finding asks for was already there. Its other half — T1–T7 and
  T-SUBSTRATE-3/4 naming nothing in the repo — is correct and stays open.
- **PG-10 is not a finding.** Its own "What exists" column concludes "Not a gap unless the explorer
  promises it". Carrying a PG id for a non-gap inflates the count of 16; the honest count is 15.
- **The audit `README.md` §9 mapping is wrong about DC-14 and DC-25.** It lists both as "resolved" by
  `3654f57`. The commit deleted the *code* (`Protocol/Id.hs`, the three `unsafeGet*` helpers) and fixed the
  *root* `CLAUDE.md`, but `src/lib/offchain-lib/CLAUDE.md:78` still routes new ID derivation to `Id.hs` and
  `src/lib/onchain-lib/CLAUDE.md:81-83` still describes `unsafeGet*` as "currently UNCALLED". Both
  documents now name symbols that do not exist, which is worse than the drift the findings recorded —
  a reader following either writes code against a deleted module. Graded PARTIAL above.
- **§9 is right that DC-34's `operator-address` row drifted, and the drift is bigger than "two forms →
  three".** Appendix B's row also says "config only (network id, `:780-799`)"; at HEAD the DRep id is
  printed **before** the config is loaded and before the `die` (`admin/Main.hs:837-840`, reasoned at
  `:826-831`), so the command now produces useful output with no Atlas config at all. The appendix's
  provider column is wrong, not just its note.
- **DC-32's fix text is now itself stale.** The report's proposed replacement — "`/status` does not yet
  expose the projector's lag" — was already false when §9 was written (`9a8d79b`). Applying the fix as
  drafted would re-introduce a false sentence. The correct replacement names both: `/ready` sums the two
  lags (`Query/Gov.hs:351-360`) and `/status` publishes `attest_lag_seconds`, `null` when there is no
  evidence of a projector.
- **DC-26's bound should be rejected rather than restated.** The report offers "state the unit or raise the
  bound; disputes is within the intent". At HEAD `disputesLambda` is 132 lines and `attestationsLambda`
  107, both over the written bound by raw span and both ~38 non-comment lines, i.e. the metric the rule
  uses decides the answer and the rule does not say which. A guideline that two of four validators violate
  on its plain reading, in a codebase whose comments outnumber its code, is not a guideline; delete it or
  bind it to non-comment lines with a number nothing currently exceeds.
- **One claim I could not confirm and would not repeat.** The brief states 70 distinct trace codes in
  `onchain-lib` at HEAD; grepping the `traceIfFalse`/`traceError` string literals finds **63**
  (`A0 A2–A7 D0 D1 D3–D9 Da K1 K2 M0 M1 Mc1–Mc4 Md1 Md3–Md8 Mf Mg Mh Mk Mm Mn Mp1 Mp4–Mp6 Mq N0 N1 O0–O6
  P0–P7 U1 U2 U3`). Codes appearing only in comments (`A1`, `D2`, `Md2`, `N2`, `U0`, `P8`/`P9`) are not
  emitted. Not a report-06 finding, but any count this report's siblings publish should be re-derived the
  same way.
