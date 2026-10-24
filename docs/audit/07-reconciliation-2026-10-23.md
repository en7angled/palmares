# Reconciliation of the audit — judged at `2bf5bde` (2026-10-23), **re-judged at `f72af4e` (2026-10-24)**

The six reports in this directory were written against `4eb9117` (2026-10-22) and first reconciled
against `2bf5bde` (2026-10-23). `main` then advanced **~50 commits**, so on **2026-10-24 every row
still marked OPEN, PARTIAL or new was re-checked a second time** against the code at `f72af4e` and,
wherever the claim was observable, against the running preprod services. The table and the prose
below are the second pass; the first pass's verdicts survive only where they are still true, and
where they are not, the row says so.

**Read this first: the second pass is the one that moved.** The 2026-10-23 pass closed 3 rows of 189
and concluded "the audit held". That conclusion was right about `2bf5bde` and is **wrong about
HEAD** — 61 rows are now closed and 47 are half-closed, because the ~50 commits were aimed squarely
at this list. A document that cries open about closed findings is a document nobody trusts for the
rows that are genuinely open, so the counts below are the point of the exercise.

**Method.** One pass per report, each confined to its own report and its own layer, none given the
others' conclusions. Code verdicts are taken from the file at HEAD, never from a commit message;
`file:line` cites are **re-derived**, because almost every line number in the first pass has moved and
a stale cite is itself a defect. Where a claim is observable over HTTP it was measured against the
live services (query-api `:8083`, interaction-api `:8082`, attest-sync `:8084`) and the command and
response are given. No build was run — the test-coverage rows are judged by reading `src/test/`, which
is how the census was built in the first place. Four verdicts needed the live db-sync and were taken
with a single read-only `SELECT` each.

**Status vocabulary.** **OPEN** — still true, with the current `path:line` *and* a clause naming what
was checked, so the next reader does not re-check it. **FIXED** — closed, with the commit and the code
that proves it. **PARTIAL** — one half closed, the other named. **MOOT** — the code it describes no
longer exists. **INVALID** — wrong when written. **WRONG** — the row's own claim is contradicted by a
measurement *now*, usually a count; these are flagged inline and listed per section, and they matter
most, because a stale row misleads about a date while a wrong row misleads about a fact.

| | Rows judged | OPEN | PARTIAL | FIXED | MOOT | INVALID | of which WRONG |
|---|---|---|---|---|---|---|---|
| 01 on-chain security | 23 | 7 | 4 | 11 | 1 | 0 | 2 |
| 02 off-chain and write API | 25 | 10 | 6 | 9 | 0 | 0 | 0 (2 sub-claims) |
| 03 chain-sync and projections | 26 | 14 | 7 | 4 | 1 | 0 | 1 |
| 04 governance read path | 36 | 12 | 5 | 15 | 0 | 4 | 2 |
| 05 tests, CI and delivery | 20 | 8 | 7 | 5 | 0 | 0 | 3 |
| 06 docs, spec and product gaps | 59 | 22 | 18 | 17 | 2 | 0 | 5 |
| **total** | **189** | **73** | **47** | **61** | **4** | **4** | **13** |

Rows exceed findings because several findings have sub-items with their own verdicts. For comparison,
the 2026-10-23 pass read **163 OPEN · 17 PARTIAL · 3 FIXED**. **164 of the 189 rows were stale** — the
recorded verdict, or every `file:line` in it, no longer held.

Beyond the table: of the 39 findings the first pass raised itself, the second pass closed 31
(`NEW-OC-1`…`5`, `NEW-OF-1`…`4`, `NEW-CS-1`…`5`, `NEW-GV-1`/`4`/`5`, `NEW-TD-1`…`4`, 19 of 23
`NEW-DC-*`), and verifying them turned up **a further 20 defects in no document at all**, two of
which are Medium and live: `NEW-GV-8` (every ratified action's tally reads its voting power one epoch
late — 25 rows over all 11 ratified preprod actions, measured) and a `/ready` that answers 503 for an
entire post-wipe re-sync, which the code's own comment says it refuses to do.

**The single most useful thing in this document is the shape of what is left.** Nothing Critical and
no High on the chain-sync or write paths is open. What remains is concentrated in delivery hygiene
(no `USER` in any Dockerfile, a `devonly` default password, images not digest-pinned), in documentation
that still describes deleted code, and in read-surface conveniences — plus the two new Medium defects
above, which are the only items here that misreport a number to a client.

---

## 1. [`01-onchain-security.md`](01-onchain-security.md)
Verified by reading the code at HEAD (`f72af4e`), not by trusting commit messages. **This section was
re-judged a second time on 2026-10-24**, after ~50 further commits: seven findings are now closed
outright (`OC-01` `OC-03` `OC-04` `OC-05` `OC-06` `OC-09`, beside the already-closed `OC-02`), three
are half-closed (`OC-08` `OC-11` `OC-12`), and five stand (`OC-07` `OC-10` `OC-13` `OC-14` `OC-15`).
Two sub-rows that the 2026-10-24 pass marked FIXED were wrong about code that never changed —
`OC-11d` and `OC-11f`.

| ID | Sev. | Status | Evidence |
|---|---|---|---|
| OC-01 | High | **FIXED 2026-10-24** `93e12ac` (ADR 0005) | `opAdmin :: Credential` (`Protocol/Types.hs:88`) and a second `opArbiter :: Credential` (`:148`); `O1` (`OracleValidator.hs:84`), `O5` (`:86`, `incomingProvedControl` at `:122-124`) and `D1` (`DisputesValidator.hs:158`, which reads `opArbiter`) all go through `Utils.checkCredentialControl` (`Utils.hs:350-358`). Rotation is expressible: `OracleSetAdmin Credential` (`Types.hs:176`) and `OracleSetArbiter Credential` (`:196`), indices 4 and 7 (`:200-210`). Tooling built: `rotate-admin`/`rotate-arbiter` with `--script` (`admin/Main.hs:562,573,100-107`). Live: `GET :8082/status` publishes `admin`/`arbiter` as `{hash, is_script}` |
| OC-02 | Medium | **FIXED** `26d53f7` | unchanged since the snapshot and re-verified: `attestationOracleToken :: AssetClass` (`Types.hs:595`), `traceIfFalse "A7" (not (opPaused oracle))` as the **first, unconditional** conjunct (`AttestationsValidator.hs:139`). Cost estimate was wrong — see note 1 |
| OC-03 | Medium | **FIXED 2026-10-24** `e6cf839` | the prescribed `user-token == 0` output check now sits beside all four `geq` sites: `Pa` beside `P5` (`ProfilesValidator.hs:178`), `Ms` beside `Mk` (`MintingPolicy.hs:361`), `A8` beside `A1` (`AttestationsValidator.hs:183`), `Md9` beside `Md5` (`MintingPolicy.hs:551`). Fresh codes, not the burnt `P8`/`P9` — the convention is recorded at `ProfilesValidator.hs:181-192`. Residue, which is rules 5/10 and not this finding: FOREIGN tokens may still ride a state output, `geq` permits it |
| OC-04 | Medium | **FIXED 2026-10-24** `4d1502b` + `2cc6fc1` (ADR 0006) | the role is on chain: `ClaimedCredential = ClaimedDRep \| ClaimedCCCold \| ClaimedCCHot` (`Types.hs:505-517`), carried by `attestationCredential :: Maybe ClaimedCredential` (`:578`), unwrapped for the proof by `claimedCredentialOf` (`:523-527`) so `Mc3` asks one question of all three. The renderer dispatches instead of guessing: `claimCredentialToText` → `renderCredentialRoleCip129 (roleOf claimed)` (`TxBuilding/Conversions.hs:134-142`). Stake credentials are documented as NOT claimable (`Types.hs:501-504`) |
| OC-05 | Medium | **FIXED 2026-10-24** `2cc6fc1` (ADR 0006) | per-kind CIP-67 labels (`CIP68.hs:261-279`): `Mg` is `isProfileId subject && isProfileId issuer` (`MintingPolicy.hs:326`), `Md4` is `isAttestationId target && isProfileId openedBy` (`:517`), and self-attestation is refused by the new `Mr` (`:341`), correctly scoped `isCredentialKind \|\| subject /= issuer` so it does not contradict `Mc1` (`:344`) — the scoping the audit's fix text got wrong. Lineage dropped by owner decision (`AttestationsValidator.hs:14-33`). `isUnbackedDatum` had to take the kind's predicate or `A4`/`D8` would have called all real state sweepable (`Utils.hs:457-473`). Live on preprod: attestation ids carry label `00001070`, profile ids `000643b0` (`GET :8083/attestations?limit=1`) |
| OC-06 | Medium | **FIXED 2026-10-24** `26d53f7` (1) + `fba6ed0` (2)(3)(4) | (1) admin-liveness: `ExpireDispute` (`DisputesValidator.hs:190-204`) needs no key and no oracle read, gated only by `D9` on `disputeStaleAfter` (`:203`, `Types.hs:706`), with `Da` (`:170`) stopping the arbiter asserting an expiry. (2)(3)(4) all three deposit-losing `depositTo` shapes are closed by one conjunct, `Mda` = `Utils.isKeyAddress depositTo` (`MintingPolicy.hs:545`, predicate at `Utils.hs:344-348`) — a `PubKeyCredential` payout cannot be a Plutus script, a protocol address, or the disputes address. Cost named rather than hidden (`MintingPolicy.hs:537-541`) |
| OC-07 | Low | **OPEN** | checked at HEAD and unchanged in substance: the absent/unparseable arms are still unconditional `True` (`ProfilesValidator.hs:88,90`; `AttestationsValidator.hs:92,94`; `DisputesValidator.hs:99,101`), and the prescribed "refuse to sweep a 222-labelled token" is not written anywhere — `isUnbackedDatum` returns `True` precisely when the datum's named token is not the own-kind REF name, and `Utils.hs:423-429` now states outright that a mis-sent user token under a hand-written datum is swept. The fix text's `P9` objection is answered by the repo itself: `ProfilesValidator.hs:181-192` records `P8`/`P9` as burnt and continues with a letter (`Pa`), so a fix here takes the next letter |
| OC-08 | Low | **PARTIAL** | datum half **FIXED** `4d1502b` (ADR 0006): `OnchainProfile` is `{profileId, profileKind, profileOracleToken :: AssetClass}` (`Types.hs:385-407`), written by `Mp5` from the policy's own parameter (`MintingPolicy.hs:385-390`) and read by `ProfilesValidator.hs:116`. Prose half **OPEN and now false rather than merely dead**: `Blueprint.hs:213-214` still says "Unparameterised — it reads the validator addresses it needs from the datum's protocolParams", and `:235-237` still describes the profile datum as "its id, its type, and the protocol parameters used to resolve sibling validator addresses" — a field that no longer exists. Both sentences are also in the **published** artifact (`docs/generated/palmares-blueprint.json`, Profiles Validator `description` and `datum.description`) |
| OC-09 | Low | **FIXED 2026-10-24** `5bbd3d7` (ADR 0007) | stance (a) taken, by decision, and the one condition that falsified it is gone: `needWipe` reads the schema version alone (`attest-sync/Main.hs:115-117`), where it was `storedVersion < current \|\| storedPolicy /= policyHexText`. The policy history is kept and logged (`:123-139`), stored comma-separated in the same column with no migration (`Storage.hs:502-519`, `parsePolicyHistory` at `:522-525`). No `protocolVersion` field, deliberately — `ProtocolParams` is unchanged at `Types.hs:24-33` and ADR 0007 argues the policy id in every `GYAssetClass` already is the fingerprint. **Deliberately not built, say so to the next reader:** indexing more than one policy at a time; `attest-sync` follows one Kupo pattern, so a dispute resolved on the OLD registry after a cutover is not indexed |
| OC-10 | Low | **OPEN, citations moved** | the on-chain claim still holds: nothing refuses a second profile claiming one credential, and `ProfileProjection.profileCredential` carries **no** unique constraint on purpose (`Storage.hs:180-189`), with `GET /profiles/by-credential` publishing `total` as the contested count and declining to pick a winner (`query-api/RestAPI.hs:1494-1498`). Premise changed as the earlier row said — the proof is now `Mc3` on a self-issued `CredentialClaim` (`MintingPolicy.hs:346`), not `Mp3`. What IS built of its read-layer fix, so nobody re-checks it: claims fold in chain order, latest-claim-wins per profile (`deriveProfileCredential`, `Storage.hs:759-776`), `by-credential` orders oldest-claim-first by slot, and every claim links to its minting transaction (`AttestationProjection.createdTxId`, `Storage.hs:202`; published as `tx_hash` — verified live on `GET :8083/attestations?limit=1`). Its recommended `RevokeClaim` remedy stays superseded (note 2) |
| OC-11 | Info | **PARTIAL** — of the 8 sub-items: 4 FIXED, 3 PARTIAL, 1 MOOT | per sub-item below. The previous count, "8 of 9 sub-items fixed", is wrong twice over: there are 8 sub-items, not 9, and two of the four it newly closed are not closed — see `OC-11d` and `OC-11f` |
| OC-11a `Protocol/Id.hs` zero callers | | **FIXED** `3654f57` | file deleted; `src/lib/onchain-lib/Palmares/Onchain/Protocol/` holds only `Lookup.hs` and `Types.hs` |
| OC-11b `unsafeGetProfile*`, `K3` | | **FIXED** `3654f57` | gone; `git grep '"K3"' -- src` → 0 hits |
| OC-11c dead `Utils`/`CIP68` helpers | | **FIXED 2026-10-24** `b65ae24` | all eight gone: `git grep -- src` finds no definition of `checkTxOutAtIndexWithDatumValueAndAddress`, `hasTxInAtAddressWithNFT`, `checkAndGetCurrentStateDatumAndValue`, `checkAndGetInlineDatum`, `hasCurrencySymbol`, `updateCIP68DatumImage`, `validateImageURI`, `isDisputeId` — only the named-and-gone comments (`Utils.hs:73-79,126-134,475-508`, `CIP68.hs:281-288`). `U2`/`U3` retired, not reassigned. Hash-neutral confirmed against a real pin: `ScriptSize.hs:38` asserts `expected == measured` on an exact five-row table (`:473-480`), unchanged. **Incomplete, not wrong:** `isProtocolRefToken` was left behind with zero callers — NEW-OC-8 |
| OC-11d `CLAUDE.md` `protocolParams` claim | | **PARTIAL** | the `isDisputeId`/`hasCurrencySymbol`/`checkAndGetCurrentStateDatumAndValue` bullets ARE corrected (`src/lib/onchain-lib/CLAUDE.md:55-61,98-99`). **WRONG:** the `protocolParams` claim this row is named for was never touched and is now false in a stronger way than when the audit found it — `CLAUDE.md:33` still says "**ProtocolParams**: Carried in datums for unparameterized validators" and `:34-39` still says "the only field any of them reads out of `protocolParams` is `oracleToken`", while ADR 0006 removed `ProtocolParams` from every datum: the field is `profileOracleToken :: AssetClass` and no datum has a `protocolParams` to read a field out of |
| OC-11e blueprint prose stale | | **PARTIAL** | the two real clauses are fixed in the SOURCE: the minting-policy description now names three hashes (`Blueprint.hs:131-132`, `bf3e1b6`+`b65ae24`), `opDisputeDeposit` and `opDisputeTimeoutMs` are both in the oracle datum description (`:412-416`), `MintProfile` and `claimedCredential` are in the mint redeemer (`:163,170`) and `ExpireDispute`/`VerdictExpired` in the disputes redeemer (`:332-340`). **Still OPEN:** the published artifact was never regenerated, so `docs/generated/palmares-blueprint.json` still ships the two-hash sentence this row says it fixed (NEW-OC-6), and the profile prose is newly false (OC-08) |
| OC-11f Haddock misattachment | | **PARTIAL** | `isUnbackedDatum`/`valueAtOutputIdx` order fixed `3654f57` (`Utils.hs:372-380` then `:396-470`), and `data OnchainProfileKind` now has its own block (`Types.hs:338-350`). **WRONG:** the other half of the row's own citation never changed. `Types.hs:296-307` is still a `-- \|` block for `OnchainProfileKind` sitting immediately before the `-- \|` block for `MintAction` (`:309`) and `data MintAction` (`:320`) — two doc-next blocks, one declaration, byte-equivalent to `2bf5bde:Types.hs:230`. And the defect class was REINTRODUCED after this row closed — NEW-OC-7 |
| OC-11g `checkDateInRange` future-dating | | **FIXED 2026-10-24** | `Utils.hs:237-244` states the rule permits future-dating by the same 14.4 h and why one symmetric rule is the only rule a validator can enforce |
| OC-11h stake credential claimable | | **MOOT** | the sentence went with `profileCredential`; `Types.hs:501-504` now states the opposite — stake credentials are not claimable and never were |
| OC-12 | Info | **PARTIAL** | genesis half **FIXED 2026-10-24**: `mintOracleNFTAndLockDatum` asserts `oracleParamsAreWellFormed initialOracleParams` and `fail`s before building (`TxBuilding/Transactions.hs:288-294`), with the literals it guards at `:269-286`. Second half **OPEN**: the oracle address still has no sweep — `OracleRedeemer` has the single arm `OracleUpdate Integer OracleAdminAction` (`OracleValidator.hs:48`), no `Cleanup`, so dust sent there is unspendable for ever (`O0`/`O3`), which still differs from the three state validators |
| OC-13 | Info | **OPEN** | checked at HEAD: `Mj` still constrains the whole minted value to one attestation NFT (`MintingPolicy.hs:349-351`) and `Mf` still spends the issuer's single user token (`:325`), so one attestation per transaction, chained on one UTxO. `NewAttestation` takes no list |
| OC-14 | Info | **OPEN** (narrowed) | checked at HEAD: nothing burns and no cap exists, so pending spam about a third party stands for the five ordinary kinds; `Mr` (`:341`) does not bound it, it only stops self-issuance. The two credential kinds cannot be aimed at a third party because `Mc1` forces `subject == issuer` (`:344`). No subject-side `Reject` exists — `AttestationsRedeemer` is `AcceptAttestation \| Cleanup` (`AttestationsValidator.hs:67-74`) |
| OC-15 | Info | **OPEN** | checked at HEAD: `mkUntypedLambda` still runs `fromBuiltinData` over the whole context — `parseData c "U0"` with `case fromBuiltinData mdata of Just d -> d; _ -> traceError message` (`Utils.hs:54-61`). `unsafeFromBuiltinData` is used only for the redeemers (`MintingPolicy.hs:179`, `ProfilesValidator.hs:81`, `AttestationsValidator.hs:83`, `DisputesValidator.hs:87`). Measurement still not taken; `ScriptSize` pins bytes, not ExUnits |

Checklist and hypotheses that moved — restated against HEAD, where ten of the fifteen findings are
now closed (seven) or half-closed (three): §3 rule 14 is FIXED outright (`ExpireDispute` plus `Mda`), rules 5 and
10 move from **Partial** to *narrowed* — the authority-token half is closed in all four places, a
foreign token may still ride a state output's `geq` — and §5 **(a)**, **(b)**, **(d)**, **(e)**,
**(j)**, **(m)** and **(n)** are all FIXED (the last by decision, ADR 0007); §5 **(c)**'s
recommendation is superseded (note 2). §5 **(o)**'s code census is **stale, and the "70" it was
corrected to was right only for `2bf5bde`**. The census is settled once here for the whole document,
because three of its sections quoted three different numbers and all three were defensible under
their own method — **`74` codes exist, `73` of them emitted through `traceIfFalse`/`traceError` and
one (`U0`) handed to a local `parseData`; a naive one-line `grep` sees `67`.** Derived and
cross-checked both ways, which differ by exactly `U0` and nothing else:

    # 73 — anchored on the emitting call, spanning newlines
    perl -0777 -ne 'while(/\b(traceIfFalse|traceError)\b\s*(?:--[^\n]*\n\s*)*"([^"]+)"/g){print "$2\n"}' \
      $(git ls-files 'src/lib/onchain-lib/**/*.hs') | sort -u | wc -l

    # 74 — every short code-shaped literal, each hit then located by hand
    grep -rhoE '"[A-Z][A-Za-z]?[0-9a-z]{0,2}"' src/lib/onchain-lib/ | tr -d '"' | sort -u | wc -l

Movement: 69 emitted at `2bf5bde` (70 with `U0` — the figure §5(o) was corrected to, and correct for
that commit), plus `A8 Md9 Mda Mr Ms Pa`, minus `U2 U3`. **The one-line `grep`'s `63` was wrong when
written, not merely stale**, and for a mechanical reason worth recording once: six codes put their
literal on a continuation line (`A1 D2 Mj Mp2 Md2 N2`), so any census that cannot span a newline
loses exactly those six, and `U0` makes seven — `63 + 6 + 1 = 70`, the number it declined to
confirm. §6 and §7 re-read and still true;
§7's "Two-sided admin handover" now covers the arbiter as well (`OracleValidator.hs:122-124`), and
admin liveness is no longer a protocol-ending dependency at all, because the credential is rotatable
to a multisig (ADR 0005).

### Notes

**1. OC-02's cost estimate was out by ~5×, in the direction that matters.** The report estimated
"~100 script bytes"; measured, `A7` cost **+494** (`AttestationsValidator` 7640 → 8134,
`ScriptSize.hs:241`), because `A7` brought this validator's *first* oracle read — the lookup
machinery, not just a conjunct. The recommendation was right and was taken; the number was not. The
datum estimate was closer: "~33 bytes" against a measured +29 for the field
(`ScriptSize.hs:301`, a later round). Both citations still resolve at HEAD; the validator itself is
now pinned at 8608 bytes (`ScriptSize.hs:476`), the `+494` and `+29` being historical deltas.

**2. OC-10/§5(c) recommended the thing we built and then deleted.** Hypothesis (c) proposes
"a `RevokeClaim` profile redeemer (`checkCredentialControl` again, writes `profileCredential =
Nothing`) so a holder can retire an old profile's claim". That is precisely decision D-E
(`800a39d`), and an independent audit of it found it **more dangerous than the problem**: it took the
same weak proof the claim took and its effect was irreversible, severing a credential from its whole
track record with no redeemer able to set it again. ADR 0003 (`6d0a76a`) removed it and replaced it
with an append-only `CredentialWithdrawal` attestation. The reviewer's instinct — give the holder a
remedy — was right; the shape they proposed was the one that had to be thrown away. Recorded in
`docs/adr/0003-credential-claim-as-attestation.md`. Still true at HEAD: `ProfilesRedeemer` is
`UpdateProfile \| Cleanup` with index 2 deliberately burnt (`ProfilesValidator.hs:52-68`), and the
remedy is `AttestationKind`'s `CredentialWithdrawal` at index 6 (`Types.hs:461,478`), exempted from
`Mf` precisely so the profile whose token an attacker holds is not the party asked
(`MintingPolicy.hs:312-325`).

### Findings I judge wrong

- **No `OC-` finding was factually wrong of the code at the snapshot.** Every one I checked was true
  there, and the two the reviewers marked as needing a decision were the two the owner then decided.
- **Two verdicts of the 2026-10-24 pass were wrong**, and they are wrong rather than stale: `OC-11d`
  and `OC-11f` were marked FIXED while the code each row cites was never touched —
  `onchain-lib/CLAUDE.md:33,34-39` still carries the `protocolParams` claim, and `Types.hs:296-307`
  still puts a second doc-next block before `data MintAction`. Both are flagged in their rows.
- The three *recommendations* that were unusable as written have all been taken, with the correction
  each needed: `OC-03` took fresh codes (`Pa`/`Ms`/`A8`/`Md9`, not the burnt `P8`/`P9`), `OC-05` took
  `subject /= issuer` scoped by `isCredentialKind` (`MintingPolicy.hs:341`), and `OC-07`'s `P9`
  objection is answered by the letter convention at `ProfilesValidator.hs:181-192`.
- `OC-01`'s overstated deposit clause is moot: the finding is closed, and both halves of it —
  key loss and key compromise — are answered by a rotatable `Credential` (ADR 0005).
- §5(o)'s census is stale in BOTH directions now: 65 described `4eb9117`, the "70" correction
  described `2bf5bde`, and HEAD is 73. The §2 per-script tables are likewise stale, not wrong.

### New findings

**NEW-OC-1 — `opDisputeTimeoutMs = 0` is well-formed and voids the dispute mechanism.** Medium.
**FIXED 2026-10-24.** The guard is now `&& opDisputeTimeoutMs params > 0` (`Protocol/Types.hs:276`),
with the argument for refusing zero written out beside it (`:261-275`) — including why it imposes no
FLOOR. Pinned three ways in `UnitTests/OracleRules.hs:100,102,104` (`0` and `-1` false, `1` true),
reachable only through `O6` on the result (`OracleValidator.hs:92`), and the genesis datum is now
asserted against the same function (`TxBuilding/Transactions.hs:288-294`, which also closes half of
`OC-12`). Live: `GET :8082/status` reports `dispute_timeout_ms: 2592000000`. The original text
follows, for the record.
`oracleParamsAreWellFormed` checked `opDisputeTimeoutMs params >= 0` (`Types.hs:210`), and the comment
directly above it (`:207-209`) says a timeout that puts `disputeStaleAfter` in the past "voids the
dispute mechanism with one keystroke". Zero does exactly that: `disputeStaleAfter = openedAt + 0`,
and `Md6` already forces `openedAt` into the validity range, so every dispute is stale the moment it
opens and anyone may close it as `VerdictExpired` in the next block — deposit returned, no decision
ever recorded. The guard admits precisely the value its own comment argues against. One admin action
(`OracleSetDisputeTimeout 0`) reaches it, and `O6` runs on updates, so this is live, not only a
genesis risk. Fix: `> 0`. **This is a defect in code added this session, not inherited.**

**NEW-OC-2 — the published blueprint's minting redeemer is missing an argument and a constructor.**
Low (contract hygiene, but the blueprint is what clients generate from). **FIXED** `bf3e1b6`
(+ `2cc6fc1`). `Blueprint.hs:163` now opens with `MintProfile seedTxOutRef kind metadata outputIdx`
and `:169-170` lists all ten `NewAttestation` arguments including `claimedCredential`, which matches
the constructor at `MintingPolicy.hs:122`. Verified against the snapshot too: at `2bf5bde` the
blueprint named neither, so the finding was true when written. The original text follows.
`Blueprint.hs:163` listed
`NewAttestation seedTxOutRef metadata otherMetadata subject issuer kind date claimedPeriod outputIdx`
— ADR 0003 inserted a `Maybe Credential` before `outputIdx`, so the published arity is wrong. The
same description documents `NewAttestation` and `OpenDispute` and **never mentions `MintProfile`**,
which was already true at the snapshot and which report 01 did not catch.

**NEW-OC-3 — the blueprint does not mention `ExpireDispute` or `VerdictExpired`.** Low. **FIXED**
`bf3e1b6`. `Blueprint.hs:332-343` now names `VerdictExpired`, states that a resolution may NOT assert
it (`Da`), and describes `ExpireDispute` in full — "ANYONE may close an undecided dispute … with no
signature and no oracle read … the protocol's only permissionless state transition". The original
text follows. `Blueprint.hs:310-313` described `ResolveDispute` and `Cleanup` only, and named `VerdictUpheld`/
`VerdictRejected`. The one path that closes a dispute without the admin — the answer to `OC-06`(1) —
is absent from the published contract, as is the third terminal verdict.

**NEW-OC-4 — the blueprint's oracle datum omits two of its six fields.** Low. **FIXED**
`bf3e1b6` (deposit) + `b65ae24` (timeout). `Blueprint.hs:412-416` now lists all seven: the ADMIN
CREDENTIAL, the pause flag, the minimum UTxO value, the dispute deposit for NEW disputes, the dispute
timeout in milliseconds, the optional fee configuration, and the ARBITER CREDENTIAL — and `:421-425`
records that the timeout may not be zero. Verified against the snapshot: at `2bf5bde` the description
listed four fields ("the admin public key hash, the pause flag, the minimum UTxO value, and an
optional fee configuration"), so BOTH omissions were real. **The published artifact is a separate
matter and still stale — see NEW-OC-6.**

**NEW-OC-5 — `Protocol/Lookup.hs:7` asserts a call that does not exist.** Info. **FIXED 2026-10-24**
`b65ae24`, and FIXED rather than MOOT: the helper was deleted AND the sentence was corrected in
place, which is the part that matters, because deleting the subject of a false sentence does not make
the sentence true. `Protocol/Lookup.hs:12-16` now names this finding and says what was wrong — "that
was false — audit `NEW-OC-5`. No validator ever called that function either … So the sentence named a
THIRD dead route as the live one" — and `:18-23` replaces it with the useful statement: each
validator is handed its own datum by `SpendingScript _ mdatum`, parses it inline, reads its own input
through `Utils.unsafeFindOwnInputByTxOutRef`, and gets the oracle through `readOracleParams`, the one
lookup in the module any validator reaches. `git grep checkAndGetCurrentStateDatumAndValue -- src`
now finds nothing but named-and-gone comments (`Utils.hs:132-134,478-491`); `U2`/`U3` are retired,
not unreachable.

---

## 2. [`02-offchain-and-write-api.md`](02-offchain-and-write-api.md)
Snapshot `4eb9117` → HEAD `2bf5bde` (14 commits). Verified by reading the worktree; Atlas 0.14.1
(tag `bf0d2d1`, the exact pin) was read from the hie-bios source cache, which closed four of the
report's five "could not verify" items. Nothing was built.

**Headline: nine of the twenty-five are closed, and the two Highs are among them.** The ~50 commits
since `2bf5bde` were aimed at this list: `OF-01` (`93e12ac`), `OF-02` (`ec18712`), `OF-03`/`OF-04`
(`fff93cd`), `OF-05` (`16b0fc4` plus `7ab6d6e`), `OF-08` (`439de49`), `OF-16` (`2cc6fc1`, ADR 0006),
`OF-17` (`ec18712`) and `OF-20` (`b65ae24`) are verified closed in code, and `OF-05`, `OF-16` and
`OF-20`'s refusals were measured against the running service. Four are PARTIAL with the closed half
named: `OF-07` (the `turboSubmit` half is MOOT, the relay stands), `OF-15` (the published prose is
fixed; one comment now states the opposite of the truth), `OF-18` (the `_ = 400` wildcard is gone,
the duplicated `applyAdminAction` is not), `OF-19` (`addRefScriptSkeleton` became live and the
licence was corrected; eight dead bindings and one stale module line remain), plus `OF-23` and
`OF-24` as Info. Twelve are genuinely open and all twelve were re-read at HEAD rather than carried
over. Of the new findings this report raised, `NEW-OF-1`, `NEW-OF-2`, `NEW-OF-3` and `NEW-OF-4` are
closed; `NEW-OF-5` and `NEW-OF-6` survive untouched. One sub-claim of `OF-20`'s own prose needed
correcting (the refusal codes), and `OF-19`'s version-mismatch bullet is not a defect.

| ID | Sev. | Status | Evidence |
|---|---|---|---|
| OF-01 | High | **FIXED 2026-10-24** `93e12ac` | The two-party flow exists: `rotate-admin --build-only` (`admin/Main.hs:305-310`), `sign-tx [--key-file]` (`:386-400`, `signTxWitness:1079-1092`), `submit-tx --tx --witness` (`SubmitTx` ctor `:77`, args `:122-127`, parser `:584-598`, dispatch `:755-765`). Primitives: `buildActionWithPK` (`Transactions.hs:157`) reusing `interactionToHexEncodedCBOR`, `submitSignedTxWithWitnesses` (`:172`). Flagless `rotate-admin` now refuses and names the three commands (`admin/Main.hs:876-879`). Residue, not the finding: `TestRuns.hs:1145`'s "signs with exactly one key" is now a true statement about the emulator helper `adminInteraction`, not about the CLI |
| OF-02 | High | **FIXED 2026-10-24** `ec18712` | The default is the address holding the opener's user NFT, returned by `spendUserNFTForProfileAt` so the two cannot disagree (`Operations.hs:832`, defaulted at `:848-849`). A named address is forced as an input or refused: script → `DepositAddressIsScript` through the protocol's own `isKeyAddress` (`:857`), not in `user_addresses` → `DepositAddressNotSpendable` (`:859`), no spendable UTxO there → same (`:863`). Published contract rewritten (`ServiceRequests.hs:255-266`) |
| OF-03 | Medium | **FIXED 2026-10-24** `fff93cd` | `resolveDisputeTX` reads the flag it already had in hand: `when (opPaused oracleParams) $ throwError (GYApplicationException ProtocolPaused)` (`Operations.hs:998-999`) → 503 (`Exceptions.hs:235`). The "obstacle" comment is replaced by the record that it was not real (`:954-962`). `expireDisputeTX` is deliberately ungated, with D-A's reason stated (`:963-968`) |
| OF-04 | Medium | **FIXED 2026-10-24** `fff93cd` | `getFeeSkeleton` short-circuits: `if feeAmount <= 0 then return mempty` (`Operations.hs:84-85`), `<= 0` and not `== 0` because `O6` permits zero and nothing bounds a negative. `Operations.hs:924`'s "always empty: feeFor MintActionDispute is 0 by design" is now TRUE, which is the sub-claim this row had as false |
| OF-05 | Medium | **FIXED 2026-10-24** `16b0fc4` + `7ab6d6e` | (a) `classifyWriteFailure :: SomeException -> ApiFailure` is pure and total (`Exceptions.hs:308-357`): `ScriptRefused` 400 with the trace codes in the message, `InsufficientFunds` 400, `TxTooExpensive`/`TxTooLarge` 400, `ProviderError` 502, `InternalError` 500, with `traceCodesInRender` (`:382`) shared with `Test.Helpers.failedWithTrace`. (b) `runWithTxErrorHandling` is `try @SomeException` (`InteractionAppMonad.hs:86-99`); `7ab6d6e` gave `checkDeployedScriptsAreReady` the same, recovering the typed case with `fromException` (`:143-155`). (c) `pollTxConfirmation` is `try @SomeException` (`:126`), so `GYAwaitTxException` is caught. Measured: `POST /issue-attestation {"kind":"credential_claim"}` → `400 {"code":"AttestationKindIsCredentialBinding"}`, not `InsufficientFunds` |
| OF-06 | Medium | OPEN | Checked at HEAD: `recipient` is still bound at `Interactions.hs:103` and read by nothing — a grep of `src` for `recipient` returns only that declaration, `TestRuns.hs` constructing `Interaction`, and `Skeletons.hs:81,85`, which is an unrelated local parameter of `txMustPayValueToAddress`. Still on **nine** request types (`ServiceRequests.hs:53,78,109,141,171,209,244,281,308`) and documented to clients in nine places (`:68,90,129,151,188,226,266,295,324`), the published document included |
| OF-07 | Medium | PARTIAL | The relay half is OPEN and unchanged: `/submit-tx` (`RestAPI.hs:87-92`, `handleSubmitTx:107-111`, `submitTxApp` → `Transactions.hs:85-86`) relays any Conway transaction for any Basic-auth holder, with no check that it touches a deployed script hash and no tx-id/principal logging. The `turboSubmit` half is MOOT: ADR 0004 / `075882b` dropped the Maestro block, `grep -rn turboSubmit src config` = 0 hits, and `config/config_atlas.example.json` is Blockfrost-only |
| OF-08 | Medium | **FIXED 2026-10-24** `439de49` | Both halves, and the second larger than the row asked. Limbo: `deployReferenceScript` calls `addRefScriptSkeleton` (`Transactions.hs:202`), which targets Atlas's always-fail `limboValidatorV2` (`Skeletons.hs:193-196`); min-ADA is now spent, not parked, and said so (`Transactions.hs:186-194`). Readiness: `deployedScriptsProblems` (`Operations.hs:175-203`) makes three things agree — compiled hash, configured hash, on-chain script hash — with no chain query in the config-mismatch branch; `deploy-reference-scripts` self-verifies and `fail`s BEFORE the config is written (`Transactions.hs:249-256`) |
| OF-09 | Medium | OPEN | Checked at HEAD: `signTxWitness` (`admin/Main.hs:1079-1092`) still reads a mnemonic and signs whatever hex arrives on stdin — no summary of inputs/outputs/mint/required signers, no `--yes`, no oracle-spend guard (`grep --yes src/exe/admin/Main.hs` = 0 hits). The only change since the snapshot is `--key-file` (`:386-400`). One narrowing worth recording: the command prints a witness set and no longer submits, so the scenario now also needs the operator to run `submit-tx` |
| OF-10 | Medium | OPEN (both) | (a) `getUTxOWithNFT` (`Lookups.hs:48-53`) still takes a client-supplied asset class with no policy or CIP-67 pre-check; the proposed `ensureProtocolRefToken` does not exist (grep over `src` = 0 hits) and `DatumParseError` is still a 500 (`Exceptions.hs:239`). (b) `getOpenDisputesForAttestation` (`Lookups.hs:279-285`) still reads every parseable datum at the Disputes address with no value authentication, so the parked-datum block on `open-dispute` stands. Mitigated, not closed: OF-20's selector now offers such a plant to the permissionless `cleanupDustTX`, so anyone can clear it; and the function's Haddock (`:265-277`) now calls itself a courtesy rather than a guarantee |
| OF-11 | Medium | OPEN | Checked at HEAD: `claimProofSkeleton` (`Operations.hs:311-326`) still takes `(spendable : _)` — the first match — adds it with the caller's witness and declares no mirroring output, so the whole value lands in the claimant's change. `filter (isNothing . utxoRefScript)` excludes reference-script UTxOs only, **not** datum-hash ones; there is still no `scriptHash`/`simpleScriptHash` comparison against the claimed credential. The caller is `credentialAttestationTX:617`; a `CredentialWithdrawal` still spends no profile token (`:622-627`), so the drain needs only the script's own witness |
| OF-12 | Medium | OPEN; one half now a documented decision | All `txMustSpendFromAddress` call sites still pass `GYTxInWitnessKey` — now **three**, not four (`Operations.hs:262,626,714`), ADR 0003 having removed one. The witness is a real parameter (`Skeletons.hs:141-143`) and `UnitTests/WritePath.hs:66-74` pins the choice at the type level, so it is exercised by a test and still by no production caller. `claimProfileTX` still pays the user token into change, and `Operations.hs:336-338` now argues that this is correct ("authority belongs in the claimant's wallet") rather than leaving it unexplained |
| OF-13 | Medium | OPEN; fix needs amending | Checked at HEAD and live: `interaction-api/Main.hs:81-82` is still bare `defaultSettings` with no `setServerName` — measured, `GET /ready` answers `Server: Warp/3.4.7`; `/ready` is still unauthenticated and uncached — measured, no credentials → 200. The per-request cost went UP rather than down: `deployedScriptsProblems` (`Operations.hs:184-203`) still makes five `utxoAtTxOutRef` calls and now also hashes each resolved script. `a9bfd71`'s `wai-extra` removal still stands, so the fix must still re-add it |
| OF-14 | Medium | OPEN | Two unguarded `B.writeFile Constants.defaultTxBuildingContextFile`, now `admin/Main.hs:702` and `:722`; `doesFileExist` is still used only by `new-operator-key` (`:993`), whose refusal pattern is still not applied. `439de49` added a self-verification before the write (`Transactions.hs:249-256`) — which means a *failed* deploy no longer overwrites, but a *successful* one still overwrites an existing config silently |
| OF-15 | Low | PARTIAL; the row's own location is closed | Closed: `webapi-lib/.../Utils.hs:149-155` now publishes "Cardano address as RAW CBOR HEX (114 hex characters), not bech32…" and the committed document carries it — measured, `interaction-swagger-api.json` `definitions.GYAddress.description` is that sentence. One residue, and it is the inverse of the original: `admin/Main.hs:1067-1068` still says "The generated Swagger's prose for `GYAddress` says 'Bech32-encoded Cardano address', which is wrong", a comment that is now itself false. Checked and **not** a residue: `Transfer/OrderBy.hs:157`'s "Bech32-encoded Cardano address" describes `WalletAddress`, a read-side type where bech32 is the right answer |
| OF-16 | Low | **FIXED 2026-10-24** `2cc6fc1` (ADR 0006) | `claimCredentialToText` renders the HRP from the claimed ROLE (`Conversions.hs:135-144`), and `parseClaimCredential` (`:115-123`) keeps the role and refuses CIP-105 and bare hex as `CredentialMalformed`. The role lives in the datum (`ClaimedDRep`/`ClaimedCCCold`/`ClaimedCCHot`), so the "needs a profile lookup" obstacle is gone. `f72af4e` also renamed the read-side refusal — measured live: `GET /profiles/by-credential/zzz` → `{"code":"invalid_credential","message":"Not a CIP-129 governance credential: expected drep1y..., cc_cold1... or cc_hot1..."}` |
| OF-17 | Low | **FIXED 2026-10-24** `ec18712` | "pointing it somewhere useless costs only the disputer" is gone — grep over `src` = 0 hits. `ServiceRequests.hs:255-266` now states the real default, both refusals by name, and that the subject bears the cost of an unresolvable dispute |
| OF-18 | Low | PARTIAL | The `_ = 400` half is **FIXED** (`b65ae24`): `txBuildingExceptionToHttpStatus` (`Exceptions.hs:226-263`) is exhaustive with no wildcard arm, and the twelve constructors that used to arrive through it are named in a block comment (`:240-250`); measured live, one of them answers by name (`AttestationKindIsCredentialBinding`, 400). Still open: `applyAdminAction` (`Operations.hs:1189-1197`) re-implements `applyOracleAdminAction` (`Protocol/Types.hs:215-223`) field by field — both are now 8 arms and they agree, held together only by the "Must stay in sync" comment at `:1187`. The row's `Envelope.hs:161-163` citation is still misattached and has moved to `:217-229` (NEW-OF-5) |
| OF-19 | Low | PARTIAL | Closed since the snapshot: `addRefScriptSkeleton` is no longer dead — `deployReferenceScript` calls it (`Transactions.hs:202`), by OF-08 — and `RestAPI.hs:283` now declares `Apache-2.0`. Still dead, each measured at exactly 2 references (signature + definition, zero call sites): `getOrganizationInformation` (`Lookups.hs:101-114`), `getProfileRefACsAtAddress` (`:284-300`), `txMustHaveUTxOsAsRefInputs` (`Skeletons.hs:132-133`), `txMustBurnCIP68UserAndRef` (`:188-190`), `extractNFTAssetClass` (`TxBuilding/Utils.hs:49-56`), `export*Validator` + `exportValidators` (`Validators.hs:185-204`) with `Constants.hs:11-24`, `optionalPosixTimeParser` (`admin/Main.hs:256-266`), and `ProtocolStatus`/`FeeConfigDTO`/`ScriptHashesDTO` (`Transfer/Types.hs:51-90`). Stale text: `Operations.hs:1` still lists the Belt System's "ranks, memberships" and still omits the credential bindings and the dispute expiry. Drop one sub-claim: `appVersion = "1.0.0"` (`Constants.hs:31`, measured live in `/status`) vs `info.version` 3.5.0 is declared independent by `CLAUDE.md`, so it is not a defect |
| OF-20 | ~~Low~~ **High** | **FIXED 2026-10-24** `b65ae24`, and the severity was wrong | Verified: `getDustUTxOs` (`Lookups.hs:183-215`) now takes the kind's CIP-67 label predicate, datum parser and id field and applies the arm's own `isUnbackedDatum` test, with the three call sites naming validator, redeemer and finder together (`Operations.hs:1227-1234`). **`Low` understated it, because this row and `F5` both recorded only the false-NEGATIVE half** ("the selector is narrower than the on-chain rule"). The false positive is the one that matters: `cleanupDustTX` builds ONE all-or-nothing transaction, so a single UTxO selected off chain and refused on chain bricks every sweep for ever, permissionlessly, for the price of one min-ADA output with a label-prefixed token name and a hand-written datum. A permanent DoS on a permissionless redeemer is not Low. A second door to the same brick is closed in the same change: a datum-**hash** plant is refused by the ledger before any validator runs, so `isSweepable` returns `False` for `GYOutDatumHash` (`Lookups.hs:205`) — the one deliberate deviation from the arm, documented as such — and the obvious "improvement" `pid == ourPolicy` is refused in writing (`:170-174`) because it would re-create the brick. `Operations.hs`' sweep remains unbounded (`cleanupDustTX:1223-1240` maps over every dust UTxO at all three addresses with no cap) |
| OF-21 | Low | OPEN (both) | (a) `queryOracleParams` (`Lookups.hs:125-131`) still reaches the oracle through `getUTxOWithTokenAtAddresses`, i.e. `utxosAtAddresses` over the whole address (`:67`). (b) The double read is now structural rather than textual, which makes it harder to see: `txMustSpendStateFromRefScriptWithRedeemer` calls `getUTxOWithNFT` itself (`Skeletons.hs:91-95`), so every builder that first reads the state datum re-reads the same UTxO — `updateProfileTX` (`Operations.hs:234`/`:259`), `acceptAttestationTX` (`:709`/`:737`), `resolveDisputeTX` (`:982`/`:1013`), `expireDisputeTX` (`:1061`/`:1081`). Four, as the reconciliation said. `updateOracleTX` is the only builder that reuses its read (`txMustSpendFromRefScriptWithKnownDatum`, `:1132`) |
| OF-22 | Low | OPEN (all four) | Checked at HEAD: `executeOnchainCommand` still does `readMnemonicFile mnemonicFilePath` unconditionally (`admin/Main.hs:1105-1106`) before dispatching, and `QueryOracle` is dispatched through it (`:767-771`), against `src/exe/CLAUDE.md:12` ("Read-only commands … no signing"); `unsafeAddressFromText` at `:678`; no `--yes` anywhere (grep = 0 hits), including on `rotate-admin` and `set-fees`; the Atlas config and the validators config are still echoed to stdout at `interaction-api/Main.hs:86-87` |
| OF-23 | Info | PARTIAL | Pragmas unchanged: `Actions.hs:1` and `Transfer/Types.hs:1` `-Wno-partial-fields`, `Validators.hs:1` `-Wno-incomplete-patterns`. Module Haddock largely closed — of the in-scope tree only `TxBuilding/Validators.hs` and `WebAPI/ServiceProbe.hs` still lack a module `-- \|`, down from 10. Metrics re-measured: `Operations.hs` 1268 lines / 483 comment lines (38 %, was 34 %), **9** lines over 120 chars (was 11); `admin/Main.hs` **19** (was 18) |
| OF-24 | Info | PARTIAL | The timing comparison is in place and the row never said otherwise: `Auth.hs:42` is `constEq username expectedUser && constEq password expectedPass`, so the per-field compare is constant-time and the `&&` between them still short-circuits — a wrong username skips the password compare. Unchanged: `CORS.hs:78` still exposes `hAuthorization` in `corsExposedHeaders`, and `interaction-api/Main.hs:69,81-82` still binds plain HTTP on `0.0.0.0` |
| OF-25 | Low | OPEN | Checked at HEAD: the oracle is still read by its current ref (`Operations.hs:52`), seeds at `:360,499,631,827`, the user NFT at `:262`; no 409 is served anywhere. One thing changed: the choice is now recorded rather than silent — `Exceptions.hs:277` states "this API publishes no 409 anywhere". `StateChanged` and `BadInputsUTxO` still appear in no document outside the audit set (grep over `src` + `docs` excluding `docs/audit/0*` = 0 hits) |

### Findings I judge wrong

- **OF-16's "fix no longer implementable" verdict is itself MOOT as of ADR 0006.** The verdict was
  right at `2bf5bde`: ADR 0003 had moved the credential to `OnchainAttestation.attestationCredential`,
  which carried no role, so a kind-aware rendering needed a profile lookup no site did. `2cc6fc1`
  removed the premise by putting the role IN the datum — `ClaimedDRep` / `ClaimedCCCold` /
  `ClaimedCCHot` (`Conversions.hs:115-123`) — so `claimCredentialToText` (`:135-144`) derives the
  HRP from the claimed role with nothing to look up. The finding's substance (role dropped,
  `cc_cold` echoes as `drep`) is closed with it; see OF-16.
- **OF-18's `Envelope.hs:161-163` citation points at the wrong function, and it still does.** The
  prose it invokes as its authority ("a `case` and not a lookup table with a fallthrough") is
  misattached Haddock, now at `Envelope.hs:217-221` — see NEW-OF-5, re-verified at HEAD. The
  argument against the old `_ = 400` was accepted and acted on (`b65ae24`, see OF-18); the citation
  was never the reason.
- **No finding in this file was wrong when written, and that holds after re-verification.** The two
  claims most likely to have been a mis-read both check out against the current tree: OF-19's
  `Transfer/Types.hs:52-90` range is exactly `ProtocolStatus`, `FeeConfigDTO` and `ScriptHashesDTO`
  (confirmed at `2bf5bde`), all three still at zero consumers, and `OrganizationProfileInformation`
  — which IS live, through `QueryResponses.hs:244` and `Query/Projected.hs:157,172,184,195` — sits
  above that range, so the row never claimed it. OF-04's and OF-05c's hedges resolved in the
  report's favour and both were then fixed. OF-08's hedge resolved against its worst case (Atlas
  will not eat the reference scripts by accident) and the finding was fixed anyway. One sub-claim
  should now be dropped rather than defended: OF-19 counts `appVersion = "1.0.0"` against
  `info.version` as stale text, but `CLAUDE.md` declares the API and app versions independent.

### New findings

- **NEW-OF-1 — Medium — FIXED 2026-10-24.** `/claim-profile` no longer advertises the `credential`
  and `witness` ADR 0003 deleted. `ServiceRequests.hs:67-70` now reads "It claims no credential:
  since ADR 0003 a binding is its own record, so bind the profile with POST /claim-credential
  afterwards", and the two no-op `describeField` calls are gone — the only `describeField
  "credential"` / `"witness"` sites left in `src` are `ServiceRequests.hs:186-187` and `:224-225`,
  on `ClaimCredentialRequest` and `WithdrawCredentialRequest`, where those properties do exist.
  `RestAPI.hs:133` repeats the correct version. The property list the committed document publishes
  is unchanged — `[description, image_uri, kind, name, recipient, user_addresses]` — which is now
  what the prose describes.
- **NEW-OF-2 — Medium — FIXED 2026-10-24.** The shared `AttestationType` description now enumerates
  all seven spellings and splits the claim that was false: `webapi-lib/.../Utils.hs:164-175` lists
  `credential_claim` and `credential_withdrawal` beside the first five and says "For the first five
  the kind is presentational … The last two the protocol does enforce — they must be self-issued and
  must name a credential that proved control of the minting transaction". Measured: the committed
  `interaction-swagger-api.json` `AttestationType.enum` has the same seven members. The row still
  lives in `addSharedSwaggerDescriptions`, so the correction reaches both documents.
- **NEW-OF-3 — Medium — FIXED by `bf3e1b6`, which landed after `2bf5bde` and before this report was
  committed; the row was true at its stated snapshot and stale on the page.** The guard is
  `issueAttestationTX`'s FIRST statement (`Operations.hs:450-455`), a pattern match rather than `==`
  because `AttestationKind` has no `Eq` instance by design, and it throws the new
  `AttestationKindIsCredentialBinding` → 400. Because `issueAttestationTX` is the shared root,
  `/issue-attestation` and `/build-tx`'s `IssueAttestationAction` arm are covered by the one line.
  Measured live: `POST /issue-attestation {"kind":"credential_claim",…}` → `400
  {"code":"AttestationKindIsCredentialBinding","message":"A credential binding is not issued here:
  use /claim-credential or /withdraw-credential, which take the credential and the witness that
  proves control of it"}`. Two residues, both cosmetic rather than the finding: `admin
  issue-attestation --kind` still advertises both spellings, because its help is derived from
  `[minBound .. maxBound]` (`admin/Main.hs:218-228`), and the attempt now fails as that same clean
  400; and `credentialAttestationTX`'s "anything else is a caller error" (`Operations.hs:592`) is
  still unenforced, though no route can reach it with a non-binding kind — `/claim-credential` and
  `/withdraw-credential` fix the kind themselves.
- **NEW-OF-4 — Low — FIXED 2026-10-24.** `ProfileClaimsNoCredential` is gone: a grep of `src`
  returns one hit, `Exceptions.hs:118`, and it is the historical note on the constructor that
  replaced it ("This constructor replaced `ProfileClaimsNoCredential`, which belonged to the D-E
  revocation …"). The burnt `P8` citation went with it, and the exhaustive status map OF-18 asked
  for (`Exceptions.hs:226-263`) therefore carries no arm for a constructor that should not exist.
- **NEW-OF-5 — Info — OPEN, re-verified at HEAD; the line numbers moved and nothing else did.** Two
  `-- |` blocks still sit back to back with one declaration after them — `Envelope.hs:217-221` ("The
  status each code is served with … a `case` and not a lookup table with a fallthrough") and
  `:222-229` ("Read an 'ErrorCode' back from its wire tag") — so the first attaches to
  `errorCodeFromText` (`:230`), which is literally `fromMaybe InvalidParameter (lookup …)`, while
  `errorCodeToHttpStatus` (`:238`) has no Haddock at all. Confirmed at committed HEAD too
  (`:202`/`:207`/`:215`/`:223`), so the four commits that touched this module since the snapshot —
  the `ErrorCode` additions for 405/406 and the in-flight `route_not_found` — all walked past it. It
  is still the line OF-18 cites as its authority.
- **NEW-OF-6 — Info — OPEN, all three counts still false, re-measured at HEAD.**
  `Core/Types.hs:138` still says `AttestationType` is the off-chain mirror of `AttestationKind`,
  "same five constructors in the same order" (there are seven — measured, the published `enum` has
  seven members); `Core/Types.hs:182` still says "a sixth attestation kind becomes parseable and
  documented"; `admin/Main.hs:217` still says "a sixth kind appears here by itself". All three were
  written when five was right, and the commits that fixed the *behaviour* around them (`bf3e1b6`'s
  guard, `b65ae24`'s shared description) left the counts alone. `Operations.hs:1`'s module line is
  the mirror image and is also unchanged — it still lists the Belt System's "ranks, memberships"
  (OF-19) and still omits the credential bindings and the dispute expiry.

---

## 3. [`03-chainsync-and-projections.md`](03-chainsync-and-projections.md)
Snapshot cited by the audit: `4eb9117`. Re-judged against `2bf5bde` on 2026-10-23, and AGAIN
against `f72af4e` on 2026-10-24 after ~50 commits landed.

**The 2026-10-23 "unchanged since the snapshot" list is void.** Every file it named has changed
except one: `2bf5bde..f72af4e` is +2110/-298 over this report's dependencies, including
`Storage.hs` (+384), `Query/Attest.hs` (+294), `Query/Gov.hs` (+282), `ChainSyncLogic.hs` (+223),
`ChainsyncAPI.hs` (+173), `Main.hs` (+164), `QueryResponses.hs` (+132), `Conversions.hs` (+118),
`compose.yaml` (+112), `smoke_attest_flow.sh` (+183), plus `Dockerfile.attest-sync`,
`.dockerignore`, `.env.example`, `README.md`, `palmares.cabal`, both `CLAUDE.md` files and
`attest-flow-smoke.md`. **Not one line cite in the original report resolves.** Every cite in the
table below is re-anchored to `f72af4e`.

The single exception, where the original cites still resolve: `src/lib/chainsync-lib/**`
(`KupoClient.hs`, `KupoAtlas.hs`) — zero diff since the snapshot, which is why CS-18.a/CS-18.b and
the `newManager`-per-call half of CS-05/CS-16 are the only rows whose evidence is byte-identical.

Nine commits name findings in this section: `8be51d9` + `9b959a4` (CS-01, both halves),
`211d8ee` (CS-02, CS-04), `ecf5228` (CS-03), `3894e75` + `99189f0` + `ccb6613` (CS-07),
`5ae17bf` (the authentication gate), `5bbd3d7` (ADR 0007). Three more carry the rest:
`bf3e1b6` (NEW-CS-1, NEW-CS-2), `b65ae24` (the projector block), `3f0dc00` (NEW-CS-3, schema v6).
Schema version is now **6**, not 4 — so every "v3→v4" sentence in the 2026-10-23 pass is two bumps
stale.

__Read ADR 0007 before any CS-06 / NEW-CS-7 work.__ A policy change no longer wipes; only a schema
bump does, and that is a deliberate decision with its reason recorded.

---

| ID | Sev. | Status | Evidence |
|---|---|---|---|
| CS-01 | Critical | **FIXED 2026-10-24** | Both halves. `8be51d9`: `representablePeriod` (`Conversions.hs:288-303`) clamps a period outside 1970-2970 to `Nothing` at the one boundary every datum crosses, applied at `:319`; six pure cases incl. both edges (`UnitTests/Conversions.hs:205-222`). `9b959a4`: `applyMatches` (`Storage.hs:463-500`) keeps the one-transaction fast path and falls back to one transaction per match on abort, dead-lettering each failure into `attest_dead_letter` (`Storage.hs:164-172,417-428`) and RETURNING instead of throwing, so the cursor advances; `ccb6613` added the two `projectAndStore` branches (`Storage.hs:602-614`) and made the count reach `last_error` (`ChainSyncLogic.hs:273,286-289`). Three Pg cases (`Projections.hs:617-660`). No value the chain lets a stranger choose reaches a column unguarded: `attestationDate` is held to the validity range by `Mq` (`MintingPolicy.hs:309`) and the range is held by the ledger's time-translation horizon; `disputeStaleAfter` is computed on chain (`MintingPolicy.hs:504`) — see NEW-FINDINGS 3 for its admin-only residue |
| CS-02 | High | **FIXED 2026-10-24** (`211d8ee`) | `verifyCursor`/`classifyCursor` (`ChainSyncLogic.hs:120-148`) ask `GET /v1/checkpoints/{slot}` whether the cursor's own block survived, BEFORE the slot comparison is trusted (`Main.hs:204-220`), and roll back to Kupo's ancestor — a precise target, margin only as fallback. `runKupoCheckpointBySlot` went from zero callers to exactly one (`grep -rn runKupoCheckpointBySlot src/ --include=*.hs` → `KupoClient.hs:282`, `ChainSyncLogic.hs:32,143`). An empty header reads as on-chain by definition (`:122`). A Kupo error is not a fork (`:145-147`). Six pure cases (`ChainSyncReplay.hs:213-222`) |
| CS-03 | High | **FIXED 2026-10-24** (`ecf5228`, `b65ae24`) | The `attest-sync` service exists (`compose.yaml:311-333`): its own `palmares_attest` schema, `PG_CONN_STR` as `palmares_owner` (`:315`), `deployed-validators` mount, `depends_on` Kupo + `palmares-roles` (`:333`). `palmares-roles` is a `restart: "no"` one-shot that applies the roles first (`:285-292`). `query-api` connects as `palmares_owner`, not `postgres` (`:360`). All five published ports bind `127.0.0.1` (`:101,224,268,329,367`). `PG_CONN_STR` is fail-closed through one shared `requirePgConnStr` that `die`s (`webapi-lib/Palmares/WebAPI/Utils.hs:39-40`), replacing two copies of a `user=postgres password=postgres` default. `Dockerfile.attest-sync` no longer bakes `KUPO_URL`/`PG_CONN_STR` (`:55-66`) |
| CS-04 | Medium | **FIXED 2026-10-24** (`211d8ee`) | `rollbackTo` step 2 (`Storage.hs:796-823`) clears a `spent_at` whose slot is above the rollback slot, written back to the raw row and not only to the replay, so a rollback below a spend no longer deletes the output the spend created and leaves the spent one unprojectable. Two Pg cases (`Projections.hs:508+`), the second asserting the column rather than `is_accepted`, which would have been vacuous; verified to fail with the un-spend removed |
| CS-05 | Medium | PARTIAL | Two halves closed. **Verdict**: `readyVerdict` (`ChainsyncAPI.hs:141-156`) no longer reads only `smChainSyncState` — it reads `smDbReady`, `smMigrationsComplete` (both measured per request by `probeDatabase`, `:96-105`, not boot literals) and the tick's age, and the 503 carries a `{code,message}` body (`:198-206`). **Kupo silence**: `getBlockchainTip`'s retry now reports `error` with the message before sleeping (`ChainSyncLogic.hs:222-231`) and so does the match-fetch retry (`:264-271`). Remaining: `Main.hs:184` is still a bare `forever` with no `try` and no supervisor, so any exception outside those two paths exits the process; both backoffs are a fixed 10 s (`ChainSyncLogic.hs:230,270`); a new `Manager` per call (`KupoClient.hs:218,265,285,309,333` — chainsync-lib unchanged) |
| CS-06 | Medium | OPEN | Code unchanged in substance and now at v6. Checked: `grep -rn "CONFIRM_WIPE\|confirmWipe" .` → 3 hits, all inside `docs/audit/**`; no guard exists. `Main.hs:118-121` still `putStrLn` then `wipeChainSyncTablesRaw`, which is `DROP TABLE IF EXISTS … CASCADE` over all eight tables (`Storage.hs:528-544`, now including `attest_sync_state` and `attest_dead_letter`). The DOWNGRADE case is still unhandled: the condition is `storedVersion < currentSchemaVersion` only (`Main.hs:115-117`), so an older-schema database under a newer binary wipes and a NEWER-schema database under an older binary meets `migrateAll` with extra columns. **The policy-change trigger is MOOT** — ADR 0007 / `5bbd3d7` removed `storedPolicy /= policyHexText` from `needWipe`; the column now holds a comma-separated history (`Storage.hs:502-524`, `Main.hs:123-139`). See NEW-CS-7 for the exposure |
| CS-07 | Medium | PARTIAL (one half won't-fix by decision) | **Wire half FIXED and verified live.** `3894e75` added the singleton `AttestSyncState` row (`Storage.hs:101-131`), written every tick and after every window (`ChainSyncLogic.hs:150-182`, `Main.hs:219,226,234,237,243,250`); `99189f0` fixed the read, which `getBy` had rendered as an unqualified `FROM "attest_sync_state"` so `/status.attestation` was `null` for ever against a healthy projector — it is now schema-qualified (`Storage.hs:398-411`). Live: `GET :8083/status` → `"attestation":{"slot":137178345,"kupo_tip_slot":137178345,"lag_seconds":47,"state":"following","last_sync_at":"2026-10-24T17:06:23.649665Z","is_ready":true,"policy_id":"648c6a73…","last_error":null,"source":"attest-sync/kupo"}` beside `"attest_lag_seconds":47`; `GET :8083/attestations?limit=2` carries `X-Attest-Slot: 137178392`, `X-Attest-Lag-Seconds: 3`, `X-Attest-State: following` (`Gov.hs:643-648`). **Green-during-first-sync**: now red on an errored tick and on a report that stopped arriving (`Gov.hs:378,382`) and `syncing` is published rather than inferred. **Absence**: deliberately still green, argued at `Gov.hs:352-354` (a governance-only deployment runs no projector) — won't-fix, not open; no `PALMARES_EXPECT_ATTEST` exists and none is wanted. **Docs half still OPEN in the script**: `docs/deployment/attest-flow-smoke.md:141-158` is rewritten and correct, but `scripts/smoke_attest_flow.sh:144` and `:157` still say "Neither /ready nor /status on either service reports attest-sync's lag at all" — contradicted by the same script at `:279-289`, which reads `attest_lag_seconds` and `die`s when it is null |
| CS-08 | Medium | OPEN | One clause added so this is not re-checked: the *silence* is gone — a Kupo outage now writes `state=error` with the client's message (`ChainSyncLogic.hs:222-231`) and turns query-api's `/ready` red (`Gov.hs:378`). The finding's own subject is untouched: no boot health or range check, `Main.hs:179` is still `putStrLn "Kupo: configured"`, `fetchingMatches` (`ChainSyncLogic.hs:241-290`) asks nothing about `--since`/`--match`/pruning/network, and `kupoHealth`/`kupoMetrics` (`KupoClient.hs:302,326`) still have zero callers outside their own module (`grep -rn "kupoHealth\|kupoMetrics" src/` → KupoClient.hs only) |
| CS-09 | Medium | OPEN | Checked at HEAD: `Main.hs:82-91` takes the policy from `DEPLOYED_VALIDATORS_CONFIG` and only *parses* it (a non-policy-id is a boot failure, which is new but is not the finding); `Ingestion.hs:97-115` still dispatches on this binary's compiled validator addresses. No recompute of the expected policy from the compiled hashes + oracle token, and the boot log (`Main.hs:177-182`) names the pattern, the DSN and the lag threshold but not one validator address |
| CS-10 | Medium | OPEN | `upsertByUnique` is still `getBy` then `insert`/`replace`, not atomic (`Storage.hs:355-364`), and it is now the writer for six tables rather than four (`:372,380,419,662,683,718`). No single-writer guard anywhere in attest-sync: `grep -rn "pg_advisory\|pg_try_advisory" src/` → one hit, `Query/Views.hs:132`, which is query-api's matview gate |
| CS-11 | Low | OPEN | `Main.hs:177` `matchPattern = policyHexText <> ".*"`; `putKupoMatch` stores every match unconditionally with the wallet's whole value map (`Storage.hs:623-636`); `rollbackTo` still `selectList [] []` over the entire raw log and replays all of it (`Storage.hs:810,830-831`). Slightly worse than described: `211d8ee` added a per-row `update` for every cleared `spent_at` in the same transaction (`:817`), and CS-02's fix makes rollbacks more frequent, which is the cost the finding predicted |
| CS-12 | Low | PARTIAL | Most of it closed. `BATCH_SIZE` is gone from the README table, `.env.example` and the Dockerfile, with the removal recorded (`README.md:196`); the defaults are now stated truthfully rather than contradicted — `README.md:181` says "default `10000000` in the binary, `100000` as the images and `compose.yaml` set it", and `Dockerfile.attest-sync:64-66` says why; the unit is stated (`Constants.hs:33`); `Query/Metrics.hs`, which never existed, is no longer named (`git show 2bf5bde:src/exe/CLAUDE.md:55` had it); the esqueleto claim is gone and attestation endpoints route to `Query/Attest.hs` (`CLAUDE.md:61`, `src/exe/CLAUDE.md:50-53`, which correctly calls `Query/Projected.hs` kept-on-disk and uncompiled). Two remain, one of them new: `Query/Common.hs:14-15` still says "the inherited profile/attestation handlers still call" `legacyNormalizeLimitOffset` — the only callers are `Query/Pages.hs:52,76,101`, which is commented out of `palmares.cabal:367`; and `CLAUDE.md:60` now routes a new governance endpoint to `Query/Aggregates.hs` and `Query/Pages.hs`, **both** commented out of `palmares.cabal:360,367` — the same defect, relocated |
| CS-13.1 | Low | OPEN | `AttestationRow` (`QueryResponses.hs:1887-1911`) still has no `open_disputes`/`contested`; `GET /attestations/{id}` is still the only place disputes are inlined (`QueryResponses.hs:2008-2009`, `Attest.hs:519`), so a list is still N+1. `/disputes` now takes `target` AND `resolved` (`RestAPI.hs:1649`, `Attest.hs:1807-1809`), which does not change the gap |
| CS-13.2 | Low | **MOOT** (`2cc6fc1`, OC-05) | The defect cannot occur. `Mg` now requires subject and issuer to be this protocol's PROFILE ids by CIP-67 label (`MintingPolicy.hs:326`), so an attestation whose subject is an attestation id is refused at the mint rather than left stuck at `accepted=false`. `AttestationsValidator.hs:14-28` now records the removal ("LINEAGE IS GONE, and the limit it used to carry with it") instead of instructing the read layer to show `False` as "pending". A `subject_kind` field would have no second value to take |
| CS-13.3 | Low | OPEN | `Protocol/Types.hs:556-557` still prescribes "`claimed_period` beside `issued_at`"; `QueryResponses.hs:1892` still publishes `attestationRowDate` → `date`. Live `/attestations` returns `"date":"2026-10-24T17:05:05Z"` and no `issued_at` |
| CS-13.4 | Low | OPEN | Cite moved: `RestAPI.hs:926` still says `profiles` and `attestations` "are always empty here and are filled over the attestation schema later", while `/profiles?q=` exists |
| CS-13.5 | Low | OPEN (cite moved twice) | Now `QueryResponses.hs:1853-1855`, and it is on `AttestProfileRow`, not on the attestation row: "A claim is not a proof: nothing on chain checks that the claimant controls the credential." Still false, and `Mp3` is still the wrong thing to go looking for — control is proven by `Mc3` (`MintingPolicy.hs:346`) through `checkCredentialControl` (`:302`) |
| CS-14 | Low | PARTIAL | The attestation half was already closed before the snapshot (`87807f1`, not by the drift): `attestation_projection` carries `created_tx_id`/`created_output_index` (`Storage.hs:202-203`) and the DTO publishes them (`QueryResponses.hs:1908-1911`) — live `/attestations` returns `tx_hash`, `slot`, `output_index`. Everything the row actually claims is still open: `ProfileProjection` (`Storage.hs:187-197`) and `DisputeProjection` (`Storage.hs:223-237`) carry no tx pointer; every projection is still upserted by NFT id so `created_at_slot` is the LATEST UTxO's (`Storage.hs:662,683,718`); `order_by=registered_at` still sorts on it (`Attest.hs:307`); no row carries block time and the DTO still publishes a raw slot with "a drifting slot-to-time conversion is worse than an honest slot number" (`QueryResponses.hs:1840-1849`) although `public.block(slot_no, time)` sits in the same database |
| CS-15 | Low | OPEN | `runMigrations` (`Storage.hs:306-315`) still adds exactly one index, `profile_projection_credential_idx`; `grep -rn "CREATE INDEX" src/lib/offchain-lib/Palmares/Storage.hs` → 1 hit, and nothing in `sql/**` touches `palmares_attest`. The read side still filters `attestation_projection.attestation_kind` (`Attest.hs:423`), `subject`/`issuer`/`accepted`/`date_from` (`:418-430`), sorts on `attestation_date` (`:391`) and `created_at_slot` (`:307`), and filters `dispute_projection.target_attestation_id` (`:1809`) — none of them indexed. The 2026-10-23 undercount note still stands (`UniqueKupoMatch` is `Storage.hs:149`) |
| CS-16 | Low | PARTIAL | Two halves closed by `c8ae1bf`/`b65ae24` (TD-01): `COPY ./config /app/config` is gone and the runtime carries no `config/` (`Dockerfile.attest-sync:50-53`), and `config/config_atlas.json` + `config/config_palmares_validators.json` are now excluded from the build context with the reason recorded (`.dockerignore:21-35`). Still open, all four: `Main.hs:76` creates the pool under `runStdoutLoggingT`, so persistent logs two statements per raw match each carrying the full `KupoMatch` JSON (query-api chose `runNoLoggingT` for its owner pool, `query-api/Main.hs:105-108`); `Main.hs:175` is still `void $ forkIO $ startProbeServer`, unlinked, so a bind failure is invisible; `Main.hs:78-79` still requires the whole Atlas core config to read `networkId` alone; `KupoClient.hs:218` still builds a `Manager` per call |
| CS-17 | Low | PARTIAL (one gap of five left) | Four of the five gaps closed. `palmares.cabal:483` now reads `hs-source-dirs: src/test, src/exe/query-api, src/exe/attest-sync`, so `ChainSyncLogic` is importable and `classifyCursor`/`evaluateChainSyncState` are pinned (`ChainSyncReplay.hs:9,213-222`); a `spent_at` fixture exists (`Projections.hs:352`) and CS-04 has two Pg cases (`:508+`); the hostile datum has six pure cases (`Conversions.hs:205-222`); `applyMatches` isolation has three (`Projections.hs:617-660`) and the replay-order derivation two (`:495,:502`). **Remaining: no boot-time wipe-decision test.** `needWipe` is still an inline `let` inside `main` (`Main.hs:115-117`), so nothing can reach it; `grep -rn needWipe src/test` → 0. (`parsePolicyHistory` and `readSchemaProbe` round-trips ARE tested, `AttestSchema.hs:115-144`, but not the decision.) The `readyVerdict` sub-gap remains INVALID — see below |
| CS-18.a | Info | OPEN | `KupoAtlas.hs:61` still matches `(Nothing, Just dh, Just "hash")`, so with `resolve_hashes` on a resolved hash datum arrives as `(Just d, Just dh, Just "hash")` and falls to `_ -> Right GYOutDatumNone` at `:64`. chainsync-lib has zero diff since the snapshot, so these are the original cites |
| CS-18.b | Info | OPEN | `KupoAtlas.hs:89` unchanged: `mapM (maybeToEither "Invalid spent input index") (spent_input_index <$> spent_at)` fails the whole conversion on a null `input_index`. One clause: the consequence is no longer only a `putStrLn` — the failed conversion is dead-lettered with its text (`Storage.hs:602-604`), so an operator can see the row that would have been `NoEvent` anyway |
| CS-18.c | Info | OPEN | `ChainCursor.lastTxId`/`lastOutputIndex` (`Storage.hs:96-97`) are still always `Nothing`: the only writer is `updateLocalTip` → `putCursor (ChainCursor True … Nothing Nothing)` (`ChainSyncLogic.hs:190`) |
| CS-18.d | Info | **WRONG** | The claim as written is impossible. `Core/Types.hs:41,43` are `type ProfileRefAC = GYAssetClass` and `type AttestationAC = GYAssetClass` — transparent aliases, so `disputeRowId :: Core.AttestationAC` and `disputeRowId :: GYAssetClass` are the SAME type and nothing is "typed as an attestation id"; OC-05's typed ids are CIP-67 labels on chain (`MintingPolicy.hs:326`), not a DTO-layer distinction. What survives is a naming nit, one line lower than cited: `QueryResponses.hs:1932-1933` names both a dispute's own id and its target `Core.AttestationAC`, so the field that is a dispute id reads as an attestation one. No `DisputeAC` alias exists (`grep -rn "DisputeAC" src/lib` → zero) |
| CS-18.e | Info | PARTIAL | `Main.hs:242,249` still store `KupoCheckpoint rollbackSlot ""` on the `Ahead` and `UpToDateButDifferentBlockHash` paths. The consequence named ("the next equal-slot comparison can never be `UpToDate`") no longer applies to the fork path, which is the one that matters: `Main.hs:218` stores Kupo's real ancestor when it has one, and `classifyCursor` treats an empty header as on-chain by definition rather than as a mismatch (`ChainSyncLogic.hs:122`). Both remaining paths roll back to `tip - margin`, i.e. below the tip, so the next tick is `Behind` and recovers forward |

---

### Findings I judge wrong

- **CS-17, sub-gap "no `readyVerdict` case with `readyAttestLagSeconds` (grep finds none under `src/test`)" — INVALID, wrong when written.** At the snapshot itself, `git show 4eb9117:src/test/UnitTests/GovDto.hs` lines 264-266 and 273-276 hold five `readyVerdict` cases carrying `(Just 42)`, `(Just 301)` and `Nothing` in the `readyAttestLagSeconds` position. The grep returned nothing because those tests build `ReadyInputs` **positionally**, never naming the field. The auditor grepped a record selector and concluded the behaviour was untested. (At HEAD the coverage is larger still: `GovDto.hs:290-312`.)
- **CS-13.5 — substance holds, citation stale twice over.** It argues the DTO comment contradicts `Mp3`. ADR 0003 (`6d0a76a`) deleted `Mp3` entirely. The comment is nonetheless still false, now because of `Mc3` (`MintingPolicy.hs:346`, via `checkCredentialControl` at `:302`), so it stays OPEN rather than MOOT — but any fix must not go looking for `Mp3`, and the comment is now at `QueryResponses.hs:1853-1855`, on `AttestProfileRow` rather than on the attestation row.
- **CS-15's "only the three `Unique*` ids and `profile_credential` are indexed" undercounts, and now by more.** `persistLowerCase` also emits `UniqueKupoMatch` (`Storage.hs:149`), whose leading column is what `rollbackTo`'s `deleteWhere` scans, plus `UniqueDeadLetter` (`:171`), `UniqueAttestSyncState` (`:130`) and the two older singleton uniques — six tables' worth, not four. The finding's substance (read-side filter/sort columns unindexed) is unaffected: `runMigrations` still creates exactly one index (`Storage.hs:312-315`).
- **README §9's instruction to re-judge CS-05 against `5978d28`'s "probe arithmetic" conflates two probes.** CS-05's green probe is attest-sync's own `/ready`, which `5978d28` did not touch; the commit changed query-api's `/ready`, which is CS-07's. *The closing sentence "CS-05 is unchanged in every part" was true on 2026-10-23 and is false at `f72af4e`:* `ccb6613` and `b65ae24` rewrote that probe — `readyVerdict` (`ChainsyncAPI.hs:141-156`) now weighs the database and the schema measured per request (`probeDatabase`, `:96-105`) plus the tick's age, and a Kupo outage reports `error` instead of freezing the numbers (`ChainSyncLogic.hs:222-231`). What is left of CS-05 is the bare `forever` (`Main.hs:184`), the fixed 10 s backoff and the per-call `Manager`.

### New findings — re-judged at `f72af4e`, 2026-10-24

- **NEW-CS-1 — High — FIXED 2026-10-24 (`bf3e1b6`).** The silent `updateWhere` no-op is gone. The
  column is no longer written incrementally: `deriveProfileCredential` (`Storage.hs:759-776`) FOLDS
  a profile's `CredentialClaim`/`CredentialWithdrawal` records in chain order
  (slot, output index, tx id), so whichever row is written second recomputes from everything
  already stored and neither depends on arriving first. `putProfileProjection` calls it (`:647`)
  and `putAttestationProjection` re-derives after a credential record (`:723-732`). The withdrawal
  rule is explicit — a withdrawal clears only the credential the profile published at that point in
  the fold (`:774-775`) — because `Mc3` asks only the named credential to consent, so the read layer
  has to ignore a withdrawal naming someone else's. The two replay-order cases the finding asked for
  exist: "a claim that replays before any profile row still binds (the re-sync order)"
  (`Projections.hs:495`) and the claim+withdrawal pair before the profile row (`:502`). The fixture
  gap is closed too (`Projections.hs:352` sets `spent_at`). Live: `/profiles?limit=2` returns
  `"credential":"drep1yfdqa29j3hhsf9lsj490j59t7cgf0k5la5q8nqgkqkahpwq5hl35n"` on a profile re-synced
  through the v6 wipe. Confirming the fold against the whole live table needs one SQL query — see
  NEEDS-SQL.
- **NEW-CS-2 — Medium — FIXED 2026-10-24 (`bf3e1b6`).** `AttestationRow` gained `credential`
  (`QueryResponses.hs:1902`), selected and mapped at `Attest.hs:610-611`; query Swagger 1.2.0 →
  1.3.0. Live: `GET /attestations?limit=2` returns the `credential_claim` row with
  `"credential":"drep1yfdqa29j3hhsf9lsj490j59t7cgf0k5la5q8nqgkqkahpwq5hl35n"`. The append-only
  claim/withdrawal log ADR 0003 made the source of truth is readable.
- **NEW-CS-3 — Low — FIXED 2026-10-24 (`3f0dc00`).** `disputeStaleAfter` is projected and
  published: `pdStaleAfter` (`Ingestion.hs:40-47,147`), the `staleAfter` column
  (`Storage.hs:230`, NOT NULL, which is why it needed the v6 bump at `:343-352`),
  `disputeRowStaleAfter` (`QueryResponses.hs:1944`), and asserted BY NAME as well as by column
  count (`AttestSchema.hs:251-258`). The field's own Haddock records why it cannot be re-derived:
  the datum's deadline is absolute, so `opened_at + the oracle's CURRENT timeout` is wrong for every
  dispute opened before a retiming. Live: `GET /disputes?limit=2` →
  `"opened_at":"2026-10-24T16:40:49Z","stale_after":"2026-11-23T16:40:49Z"`.
- **NEW-CS-4 — Low — FIXED.** `Storage.hs:180-186` now reads "DERIVED, not read off a datum — ADR
  0003 removed the datum field and made a binding its own record; `deriveProfileCredential` is the
  fold", and no longer contradicts `putProfileProjection`'s own Haddock.
- **NEW-CS-5 — Low — FIXED 2026-10-24 (`3894e75`).** `startFreshnessPoll`'s Haddock
  (`Gov.hs:538-545`) now says "The paragraph that stood here said absence was silent and named the
  follow-up … That is what landed", and describes the row it actually reads.
- **NEW-CS-6 — Info — PARTIAL, and the surviving half is worse.** The duplicated one-liner on
  `putProfileProjection` is gone — one `-- |` block at `Storage.hs:638-644`. `currentSchemaVersion`
  still carries TWO stacked `-- |` blocks (`:317-332` and `:333-336`) whose bullet list stops at
  `* v3:`, and v5 and v6 are now described in plain `--` comments at `:338-351` that sit BETWEEN the
  type signature (`:337`) and the definition (`:352`), where Haddock attaches them to nothing. Four
  versions of history in three places, two of them invisible in the rendered docs.
- **NEW-CS-7 — Medium — PARTIAL; half (a) stands, half (b) is now FALSE.**
  (a) still true, and still on the normal upgrade path: `needWipe` is `storedVersion <
  currentSchemaVersion` (`Main.hs:115-117`) with `currentSchemaVersion = 6` (`Storage.hs:352`), so
  the first boot at HEAD drops all EIGHT chain-sync tables after one `putStrLn`
  (`Storage.hs:528-544`) — `onchain_match_event` and `chain_cursor` among them — and with
  `KUPO_SINCE=<tip>` (`compose.yaml:192,217`; the committed default is `origin`) the dropped raw log
  cannot be rebuilt. The POLICY-change trigger this bullet also named is MOOT: ADR 0007 / `5bbd3d7`
  took it out of `needWipe`.
  (b) is contradicted by the code: `/ready` is **not** green and `attest_lag_seconds` is **not**
  `null` during the rebuild. The wipe drops `chain_cursor`, so `getLocalTip` answers slot 0
  (`ChainSyncLogic.hs:195-204`), the first tick writes `attest_sync_state` with `cursor_slot = 0`
  (`Main.hs:234`), `attestStatusOf` computes `max 0 (dbSyncSlot - 0)` ≈ 137 M (`Gov.hs:600`) and
  `readyVerdict`'s summed-lag guard (`Gov.hs:372`) returns 503 for the whole re-sync. Which is its
  own problem, in the opposite direction — see NEW-FINDINGS 1 in this pass.

### Verdict on the three directed items — re-judged at `f72af4e`, 2026-10-24

1. **CS-01 end to end at HEAD: CLOSED, both halves, and nothing new reaches a column unguarded.**
   The 2026-10-23 chain is broken in two places. The value: `representablePeriod`
   (`Conversions.hs:288-303`) clamps a period outside 1970-2970 to `Nothing` and KEEPS the
   attestation, at the one boundary every datum crosses — ingest, replay and any future reader —
   with six pure cases including both edges (`UnitTests/Conversions.hs:205-222`). The shape:
   `applyMatches` (`Storage.hs:463-500`) keeps the one-transaction fast path and, only on abort,
   falls back to one transaction per match, dead-lettering each refusal with its text
   (`attest_dead_letter`, `Storage.hs:164-172,417-428`) and RETURNING the count rather than
   throwing, so the cursor advances and the window lands. `projectAndStore`'s two drop branches
   dead-letter too (`:602-614`), the count reaches `last_error` (`ChainSyncLogic.hs:286-289`) and
   turns query-api's `/ready` red (`Gov.hs:378`), which is what keeps "isolated" from meaning
   "silently short of a record". `FETCH_BATCH_SIZE`'s aggravation is also gone in practice: the
   image and compose set 100 000 (`Dockerfile.attest-sync:66`, `compose.yaml:319`) and the README
   states both numbers (`:181`), though the binary default is still 10 M slots (`Main.hs:143`).
   I re-checked the two values schema 5 and 6 added. `disputeStaleAfter` is `openedAt +
   opDisputeTimeoutMs`, computed on chain (`MintingPolicy.hs:504`) off an `openedAt` that `Md6`
   forces into the opening transaction's range — not stranger-chosen; its admin-chosen residue is
   NEW-FINDINGS 3 below. `attestationDate` is held to the validity range by `Mq`
   (`MintingPolicy.hs:309`) and the range is held by the ledger's own time-translation horizon, so
   "no value left that the chain lets a STRANGER choose" holds as written.
2. **NEW-CS-1 is CLOSED (`bf3e1b6`), by the right fix and with the test that was missing.** The
   derivation is no longer order-dependent: it is a fold over the stored records
   (`Storage.hs:759-776`) rather than two incremental writes, so the `updateWhere` that matched no
   row cannot exist. Both arms call it (`:647`, `:723-732`). The two replay-order cases exist
   (`Projections.hs:495,502`) and so does the `spent_at` fixture whose absence hid the defect
   (`:352`). It was closed before the v5→v6 bump that would have shipped it, which was the risk.
3. **The schema bump and CS-06 have separated, and the pair I prescribed is now half wrong.**
   CS-06's code is still byte-identical in substance (`Main.hs:115-121`), so CS-06 stays OPEN and
   `ATTEST_SYNC_CONFIRM_WIPE` is still the guard it wants — `grep` finds the string only in these
   audit documents. What changed underneath it: ADR 0007 took the POLICY change out of `needWipe`
   (`5bbd3d7`), so only a schema bump wipes, and that is now a recorded decision with its reason
   (those tables would need an in-place `ALTER` Postgres rejects) rather than an accident. The
   version DOWNGRADE case is still unhandled. The second half of my prescription — "a red `/ready`
   on absence-when-expected" — should NOT ship: `3894e75` argued the other way with a better reason
   (a governance-only deployment runs no projector, `Gov.hs:352-354`) and covered the two states no
   lag can catch instead, an errored tick and a report that stopped arriving (`:378,:382`). The
   real remaining problem is the opposite of the one I named: the summed-lag guard already turns
   `/ready` red for the entire backfill, which the code's own comment says it does not. See
   NEW-FINDINGS 1.






---

## 4. [`04-governance-read-path.md`](04-governance-read-path.md)
Replacement for lines ~347-360.

> Audit snapshot `4eb9117`; the reconciliation judged `2bf5bde`. **Re-verified at `f72af4e`, 50
> commits later**, on 2026-10-24 against the live preprod stack (epoch 321, `drep_distr_epoch` 321,
> `/status` lag 28 s).
>
> **In-scope files that changed since the reconciliation (`2bf5bde..HEAD`):** `sql/010_gov_views.sql`,
> `sql/020_views.sql`, `sql/030_metrics.sql`, `sql/checks/{020_eligibility,050_actions_committee_treasury,
> 070_drep_metrics}.sql`, `resources/metrics/participation_rate_v1.sql`, `resources/metric-formulas.json`,
> `docs/metrics.md`, `docs/adr/0001-governance-data-substrate.md`, `compose.yaml`, `README.md`,
> `CLAUDE.md`, `src/exe/CLAUDE.md`, `config/reconcile-sample.preprod.json`,
> `query-api/{Main.hs,RestAPI.hs,QueryAppMonad.hs,Query/Gov.hs,Query/Views.hs,Query/Refresh.hs,
> Query/ServiceStatus.hs,Query/Common.hs,Query/Attest.hs}`, `admin/Reconcile.hs`,
> `offchain-lib/.../{Transfer/QueryResponses.hs,Transfer/Filters.hs,Transfer/Types.hs,Metrics/Catalog.hs,
> Metrics/Doc.hs}`, `webapi-lib/.../{Envelope.hs,Errors.hs,Utils.hs,CORS.hs}`,
> `docs/generated/swagger/query-swagger-api.json` (1.2.0 → **1.7.0**), all eleven
> `test/fixtures/snapshot/**` files (re-recorded by `0402a3c`), `.github/workflows/ci.yml`, and
> `scripts/{check_sql_checks.sh,check_swagger.sh,check_vocabulary.sh,check_packaging.sh,smoke_query_api.sh,
> smoke_views.sh}`.
>
> **In-scope files that did NOT change:** `sql/000_schema.sql`, `sql/040_grants.sql`,
> `sql/050_roles.sql`; `sql/checks/{010_drep,030_votes,040_power,060_activity}.sql`;
> `sql/indexes/001_gov_indexes.sql`; `resources/metrics/` except `participation_rate_v1.sql`;
> `query-api/{Query/Thresholds.hs,Query/Csv.hs,Query/Aggregates.hs,Query/Pages.hs,Query/Projected.hs}`;
> `offchain-lib/Palmares/Reconcile.hs`, `Transfer/OrderBy.hs`, `Admin/ApplySql.hs`;
> `config/reconcile-exceptions.yaml`; `.github/workflows/reconcile.yml`; `docs/adr/0003`.
> Every verdict below cites HEAD's line, verified, not inherited.
>
> **Counts.** 15 FIXED, 5 PARTIAL, 12 OPEN, 4 INVALID, 0 MOOT. Of the seven NEW-GV findings the
> reconciliation added, 3 are FIXED and 4 remain. One new defect found while verifying
> (`NEW-GV-8`, below) and one latency/documentation gap (`NEW-GV-9`).

---

| ID | Sev. | Status | Evidence |
|---|---|---|---|
| GV-01 | High | **FIXED 2026-10-24** (`38a0d7b`) | `sql/000_schema.sql:10` still carries `DROP SCHEMA IF EXISTS palmares CASCADE`, but it is no longer reached on an unchanged restart: `Query/Views.hs:133` gates the whole DDL behind `unchanged <- fingerprintMatches` (an `md5()` over the concatenated embeds, computed and compared server-side, `:87-95`, `:144-156`), and `:132` takes `pg_advisory_xact_lock(871237)` first so two replicas booting together serialise instead of racing. The fingerprint table is written AFTER the DDL (`:139-141`), so a half-finished bootstrap rebuilds next boot. `lock_timeout = '10s'` survives at `:125` and is now only paid on a real change. Pinned by object identity (`UnitTests.Views`: unchanged oid across a second boot = no rebuild) rather than by counting schemas |
| GV-02 | High | **FIXED 2026-10-24** (`a6ef22d` + `0402a3c`) | `admin/Reconcile.hs:325` is now `-- NO STATUS FILTER — GV-02`: the request omits `status` entirely, so our side is the API's own three-status default (`Gov.hs:1897`, `[DRepActive, DRepInactive, DRepUnknown]`), pinned by `UnitTests.QueryHardening`. The stale fixture half closed too: `test/fixtures/snapshot/palmares/dreps.json` now holds 294 rows as `inactive` 187 / `unknown` 90 / `active` 17, with exactly the 90 null `active_until_epoch` rows relabelled — the population that produced the 90 false `membership` divergences every night. `Palmares/Reconcile.hs:178-179` is unchanged and needs no change |
| GV-03 | High | **FIXED 2026-10-24** (`ec3a243`) | `sql/030_metrics.sql:79` is `count(DISTINCT e.gov_action_id) AS eligible_actions`, so the matview's denominator is the eligible SET and agrees with `resources/metrics/participation_rate_v1.sql:51` by construction. Measured before the fix: 23 of 809 DReps inflated, 171 excess rows, worst +90 actions and 0.3395 of rate. Agreement is now asserted rather than asserted-about: `sql/checks/070_drep_metrics.sql:114` runs `palmares.eligible_actions` as a `LATERAL` over EVERY DRep (736 ms, 821 rows at epoch 321) and `UnitTests.MetricAgreement` compares the SERVED `drepMetricsQuery` response against the catalog's own embedded bytes for every DRep in a seeded corpus. Live: `/dreps?order_by=votes_cast` serves `16/119 = 0.13445378151260504`, exact. Two implementations remain (`030_metrics.sql:32` says so, with the measurement for why) — that was never the finding |
| GV-04 | High | **FIXED 2026-10-24** (`ea90f48` + `ccaa2a1`) | `compose.yaml:359` now serves requests as `user=palmares_ro` with `PALMARES_PG_OWNER_CONN_STR` wired separately at `:360` — the split that was a comment and nothing else. `PG_CONN_STR` is fail-closed: `query-api/Main.hs:91` is `requirePgConnStr`, which is `requireEnv' "PG_CONN_STR"` (`webapi-lib/.../Utils.hs:39-41`) with no default — the `defaultConnStr = "… user=postgres password=postgres …"` the row cited is deleted. `Main.hs:104`'s `fromMaybe connStr` survives deliberately, documented at `:101-103`, as the single-role path; compose no longer takes it. `PALMARES_ADMIN_CONN_STR` is in README §11 (`README.md:189`, "required …, **fail-closed**"); it is still absent from `compose.yaml`, which runs no admin service — the SQL Jobs are a Kubernetes concern, not a defect of this row |
| GV-05 | Medium | **PARTIAL** | FIXED half: `src/exe/CLAUDE.md:85-86` now says the service is "**not** rate-limited either: `rate_limited` is declared in the error vocabulary and unreachable" (was "rate-limited"), and `QueryAppMonad.hs:14` names the BFF as the limiter, correctly. **Still OPEN:** the published Swagger description at `RestAPI.hs:2077` still reads "429 a rate limit" as a status this service serves, against `webapi-lib/.../Envelope.hs:131`'s own "`rate_limited` … unreachable in Plan A". The pool is now 10 for reads + 2 for the owner (`Main.hs:92`, `:108`) |
| GV-06 | Medium | **FIXED 2026-10-24** (`ea90f48`) | The fan-out is closed at the join: `Query/Gov.hs:1437` adds `AND d.registration_status <> 'never_registered'` to `voteFrom`'s `palmares.drep` join, with the measurement in the Haddock (`:1421-1427`) — `/votes` served 832 items for 831 votes, and `?voter_id=763ef756…` answered `"total": 1` beside two byte-identical items. Live now: `/votes?voter_id=763ef75661f0cd8c8fa159a79d79bfe8f9a76878bdaaff700598ee0e&limit=10` → `total 1, items 1`, 1.24 s. The `drep_distr`-on-both-rows half resolves in the code's favour: `/drep/763ef756…/power?limit=10` returns 10 rows with **zero duplicate epochs** (0.016 s), so the `p.drep_raw = v.voter_id_hash` power join at `:1434` does not double-count. Page/total asymmetry is now structural and intended — `listVotes` restricts stage 4 by `voting_procedure_id IN (…)` (`Gov.hs:1637-1645`), so the page is the count's own rows |
| GV-07 | Medium | OPEN | Unchanged and now **demonstrated reachable**. `sql/020_views.sql:881` still emits `t.gov_action_id` as arm 11's `item_index`, one row per `palmares.treasury_withdrawal` row (`:548-556` is one row per `(action, stake_address)`), against the uniqueness contract at `:603`. Checked live: `/treasury-withdrawals?limit=100` returns all 83 rows, of which **1 action (`191398f38ef05515ddca…`) holds 2 withdrawals** and **0 rows have a non-null `enacted_epoch`**. Arm 11 fires `WHERE t.enacted_epoch IS NOT NULL` (`:891`), so it emits nothing today — which is the only reason `sql/checks/060_activity.sql:25-27` (`n_dups = 0` over `(sort_slot, tx_index, arm, item_index)`) passes. The duplicate appears the epoch that action enacts. Fix is one column: `t.stake_address_id` |
| GV-08 | Medium | **INVALID** | Unchanged. `020_views.sql:605-611` (`b.epoch_no = g.ratified_epoch`) is still the arm, and it is still the most accurate placement available. See §Findings I judge wrong; the real defect is NEW-GV-6 |
| GV-09a | Medium | OPEN | Both halves survive verbatim. `Query/Gov.hs:2144` is `count(DISTINCT v.drep_voter)` over `public.voting_procedure` with no power gate, divided (`:2136`) by `e.with_power` = `count(*) FILTER (WHERE p.amount > 0)` (`:2137`), so a voter with zero recorded power still enters the numerator and a rate > 1.0 is reachable. `QueryResponses.hs:1390-1396` `EpochParticipationPoint` still carries no `formula_id`, against `RestAPI.hs`'s stated contract. The statement was rewritten for speed (1213 ms → 4.6 ms, `:2118-2124`), not for either half of this row |
| GV-09b | Medium | **FIXED 2026-10-24** (`ccaa2a1`) | `RestAPI.hs:1388` is now `dashboardTotalDreps = n DRepActive + n DRepInactive + n DRepUnknown`, with the regression recorded at `:1385`. Live: `/pages/dashboard` → `total_dreps 294`, matching `/dreps`'s three-status default of 294, and the breakdown is reconstructable (`active 17`, `inactive 187`, `retired 523`; 294−17−187 = 90 unknown), so the absent `unknown_dreps` field the row asked for is moot |
| GV-10 | Medium | **FIXED 2026-10-24** (`b65ae24`) | The correlated subselect is gone: `sql/020_views.sql:471` is `(SELECT count(*) FROM palmares.vote_partition p WHERE p.gov_action_id = aw.gov_action_id)` — a count over 931 pre-aggregated rows through `palmares_idx_vote_partition_action`, 6.0 ms for all 131 actions, verified against the number it replaced on all 131 with 0 disagreements (`:459-467`). `govActionProjection` still ends `g.votes_cast` (`Gov.hs:1158`). Measured live with `votes_cast` selected: `curl -w '%{time_total}' '/gov-actions?limit=5'` → **0.0145 s**, `total 131`. The price is named: a 300 s matview staleness window (`:469-470`). The 41.7 s comment survives at `Gov.hs:2064` where it belongs — the dashboard totals statement |
| GV-11 | Medium | OPEN | Unchanged. `sql/010_gov_views.sql:171` is still `WINDOW w AS (PARTITION BY drep_hash_id ORDER BY slot_no, cert_index)` and `:206`/`:215` still `ORDER BY drep_hash_id, slot_no DESC, cert_index DESC`, while `drep_cert` publishes `tx_index` at `:134` and `live_delegation` orders by it at `:731` (`b.slot_no DESC, tx.block_index DESC, dv.cert_index DESC`). Two certificates in two transactions of one block still tie. `delegatorFrom` picked the three-column order up (`Gov.hs:1058`); `drep_interval`/`drep_status` did not |
| GV-12 | Medium | **FIXED 2026-10-24** (`ea90f48`) | `sql/010_gov_views.sql:358` is `LEAST(g.expiration - 1, …)` and the `drep_votable` window at `:371` carries the same `- 1`, with the measurement in the comment (`:344-356`): of the 96 actions that ever received a vote, 19 reach exactly `expiration - 1` and none reaches `expiration`. Published effect: `actions_in_flight` 11 → 7, DReps with a wrong denominator 462 of 809 → 0. Live confirmation: `/gov-actions?limit=5` serves `expires_epoch 326` beside `last_votable_epoch 325`, and `/pages/dashboard.actions_in_flight = 7`. `020_views.sql:35` still gates on `<` and is now correct against a correct column. **NEW-GV-5's danger was handled, by a different route than prescribed — see NEW-GV-8 for the residual** |
| GV-13 | Medium | **INVALID** | Unchanged verdict; `010_gov_views.sql:47` still maps `is_valid IS NULL` to `invalid_schema`, which is right. The repo's comment is still wrong — see NEW-GV-7, which is also still open |
| GV-14 | Medium | OPEN | Unchanged in every part. `sql/010_gov_views.sql:495` is still `('ParameterChange', 'SPO', 'pvtpp_security_group')`, an unconditional row in a static `VALUES` list; `Query/Thresholds.hs:181` `spoParamChangeApplies` still has no production caller (`grep -rn spoParamChangeApplies src/` → 3 hits in `Query/Thresholds.hs` + 3 in `UnitTests/GovThresholds.hs`, zero elsewhere); there is no `threshold_applies` column anywhere in `sql/`. Live, on an enacted ParameterChange: the SPO tally row publishes `threshold_param "pvtpp_security_group", threshold 0.51`. The DRep arm did improve — it now publishes `greatest(dvt_p_p_network_group, dvt_p_p_economic_group)` — which is orthogonal to this row |
| GV-15 | Medium | OPEN | `Query/Gov.hs:701` is still `JOIN palmares.drep_metrics m ON m.drep_hash_id = d.drep_hash_id` — inner — inside `drepFrom`, now shared by the page AND the count (`:696-699`, F-17's fix), so a DRep absent from the matview vanishes from both consistently rather than from one. `drepSummaryByIdQuery` moved to a `WITH m AS (SELECT * FROM palmares.drep_metrics WHERE drep_hash_id = ?)` CTE (`:881`), which returns no row at all for an unrefreshed DRep rather than a row with null metrics. `Query/Refresh.hs:106` is `REFRESH MATERIALIZED VIEW CONCURRENTLY` (so no empty window) but still takes **no advisory lock**, so two replicas can refresh simultaneously. `/drep/{id}/updates` still reads `palmares.drep_cert` (`Gov.hs:1084`) and so still finds the DRep — the asymmetry the row named |
| GV-16 | Medium | OPEN (strengthened) | `Query/Gov.hs:1053-1058` (`delegatorFrom`) still takes `DISTINCT ON (addr_id)` over ALL of `palmares.vote_delegation`, and `dv.drep_hash_id = ?` is applied in `whereSql` (`:1046`) outside it — so an address whose latest certificate names a different DRep is unreachable at any `is_current`. `RestAPI.hs:427-429` still promises "`is_current=false` includes those, which is what makes the list a history rather than a snapshot". **The repo now contradicts itself about it:** `RestAPI.hs:974-978`, documenting the same shape on `/delegations`, states "a superseded certificate is not the latest one, so it is not a row here, and `is_current=false` means one thing only: the stake account was deregistered AFTER the delegation's certificate" — and then calls that "a deliberate difference from /drep/{id}/delegators, where is_current=false widens to the history instead", which `delegatorFrom` cannot do |
| GV-17 | Medium | OPEN | Unchanged. `sql/indexes/001_gov_indexes.sql:35` still creates `gov_idx_committee_reg_hot` with the "never finishes" note at `:30-34`; `Admin/ApplySql.hs:170` still has `declaredIndexes`, and `assertIndexesValid` (`:193-205`) checks for **INVALID** indexes (`NOT i.indisvalid`), not **missing** ones, and runs only from `admin apply-indexes` (`admin/Main.hs:945`). `grep -rn "missing_indexes\|missingIndexes" src/ sql/ scripts/` → 0 hits; nothing in `Query/ServiceStatus.hs` or `Main.hs` compares the declared set against `pg_indexes`, and the live `/status` publishes no such field |
| GV-18 | Low | OPEN — VERIFY SETTLED | Unchanged. `sql/020_views.sql:517-518` is still `EXISTS (SELECT 1 FROM public.committee_de_registration dr WHERE dr.cold_key_id = cm.committee_hash_id) THEN 'resigned'` with no tenure bound, and the comment at `:492-493` still states the unbounded rule. The correct predicate (resignation counts only within the credential's current membership tenure) is in §VERIFY and was not implemented |
| GV-19 | Low | **INVALID** | Unchanged. `020_views.sql:386`-equivalent join (`rr.spendable_epoch = ga.enacted_epoch`, now `sql/020_views.sql:560-562`) is exactly right; `paid_heuristic` is still a heuristic and `:543-547` says so |
| GV-20 | Low | **FIXED 2026-10-24** (`ea90f48`) | Both copies gained the registration-interval overlap test the row said neither had. Matview: `sql/030_metrics.sql:208-212` adds `EXISTS (SELECT 1 FROM palmares.drep_interval i WHERE i.drep_hash_id = d.drep_hash_id AND i.from_epoch <= o.last_votable_epoch AND (i.to_epoch IS NULL OR i.to_epoch >= o.proposed_epoch))`. Catalog: `resources/metrics/participation_rate_v1.sql:38-43`, the same test. Measured before: all 824 credentials reported 11 outstanding actions, including 523 retired and 7 never-registered — 64% of the table; a DRep that retired in epoch 163 was served `eligible_actions: 0` beside `open_actions_unvoted: 11` |
| GV-21 | Low | OPEN | Unchanged. `Query/Gov.hs:1182` still filters `g.expiration < ?` for `expires_before_epoch` while `:2089` uses `ga.last_votable_epoch >= …` for `actions_in_flight`, and `RestAPI.hs:1325` still documents the gap ("`actions_in_flight` is `last_votable_epoch >= epoch`, which is not `state = proposed`"). The gap is now 1 rather than the row's "12-vs-11": `expiration` is a documented protocol column (`QueryResponses.hs:523-527`) and `last_votable_epoch` is `expiration - 1`, so the filter means one epoch later than the in-flight test. Severity unchanged; the row's own cite of the number is stale |
| GV-22 (dead modules) | Low | OPEN | Unchanged. `palmares.cabal:360,365,367,368` still comment out `Query.{Aggregates,Metrics,Pages,Projected}`; the files are still on disk; `Query/Aggregates.hs:20,49` and `Query/Projected.hs:187` still reference `runWithQueryErrorHandling`, and `grep -rn runWithQueryErrorHandling src/` returns exactly those 3 hits — **it is still defined nowhere**, so neither file compiles |
| GV-22 (CLAUDE.md routing) | Low | **PARTIAL** | FIXED: `CLAUDE.md:58` now points at `offchain-lib/Palmares/Metrics/Catalog.hs`, and `src/exe/CLAUDE.md:51-52` now correctly calls `Query/{Projected,Pages,Aggregates}.hs` "inherited files kept on disk and commented out of `palmares.cabal`". **Still OPEN:** `CLAUDE.md:60` still routes new work to "aggregates in `Query/Aggregates.hs`, pages in `Query/Pages.hs`" — the two modules the same repo documents as uncompiled, one file away |
| GV-22 (one pool) | Low | **FIXED 2026-10-24** (`ccaa2a1`) | `src/exe/CLAUDE.md:43` now reads "There is a **second** pool outside the …", against `Main.hs:92` and `:108`, which open two |
| GV-22 (`Query.Metrics`) | Low | **FIXED 2026-10-24** (`ec3a243` + `ccaa2a1`) | All three cited sites corrected: `src/exe/CLAUDE.md`, `docs/metrics.md` and `Palmares/Metrics/Catalog.hs` no longer name the module (`grep -rn "Query\.Metrics" src/ docs/metrics.md` → 1 hit, `src/test/UnitTests/MetricCatalog.hs:100`, a test-only aside about a future module, not a routing pointer) |
| GV-22 (view count) | Low | **FIXED 2026-10-24** (`ccaa2a1`) | `docs/adr/0001-governance-data-substrate.md:12` and `:108` both read "nineteen", agreeing with `scripts/smoke_views.sh:37` |
| GV-22 (`docs/superpowers`) | Low | **FIXED 2026-10-24** | `grep -rn "docs/superpowers" --exclude-dir=.git .` outside `docs/audit/` → **0**. `resources/metric-formulas.json`'s six `spec` keys and `config/reconcile-sample.preprod.json:23` now point at live documents (`:23` → `docs/deployment/koios-parity-gate.md`) |
| GV-22 (trigram) | Low | OPEN | Unchanged. `Transfer/Filters.hs:136` still promises "through a trigram index" and `Query/Common.hs:148` still reasons from one ("below two characters a trigram index cannot help"); `grep -rn "pg_trgm\|gin_trgm\|gist_trgm" sql/ scripts/` → **0**. Live `/search?q=drep&limit=2` answers in 0.07 s on 22 hits, so nothing is broken — the promise is |
| GV-22 (README §11) | Low | **FIXED 2026-10-24** | `README.md:175` lists `PG_CONN_STR` as required and the code now agrees (`Main.hs:91` `requirePgConnStr`, no default) — so the README's statement was the correct one and the code was the defect; it was fixed in the README's direction. `PALMARES_PG_OWNER_CONN_STR` (`:176`), `PALMARES_NETWORK_NAME` (`:187`), `PALMARES_FRESHNESS_POLL_MS` (`:188`) and `PALMARES_ADMIN_CONN_STR` (`:189`) are all present. Flagged in §WRONG-ROWS for the blame, not the outcome |
| GV-22 (`invalid_drep_id`) | Low | OPEN | `RestAPI.hs:738-739` still documents that `voter_id` accepts "drep1y…, cc_cold1… , pool1… or 56 hex characters", and a bad one still answers with the DRep-shaped code. Measured live: `GET /votes?voter_id=notahash&limit=1` → `400 {"code":"invalid_drep_id","message":"Not a DRep identifier"}`. `/profiles/by-credential`'s neighbouring case WAS fixed with a new `invalid_credential` code (`RestAPI.hs:1937,2089-2092`), and `:2091-2092` deliberately preserves `invalid_drep_id`'s narrow meaning "on the governance routes" — which is exactly the route where it is wrong for two of the three accepted forms |
| GV-23 | Low | **PARTIAL** (`3894e75`, `99189f0`) | FIXED, item by item against the row's own list, verified on the live `/status` and in the generated Swagger (`StatusResponse`, 1.7.0): `attest_lag_seconds` (0) and a whole `attestation` block (`slot`, `kupo_tip_slot`, `lag_seconds`, `state: "following"`, `last_sync_at`, `is_ready`, `policy_id`, `last_error`, `source`); `drep_distr_epoch` (321) — now a top-level field, not on `SyncStatus` (`QueryResponses.hs:491-504` still has six fields, correctly); `amber_lag_seconds` (120), read out of `QueryAppMonad`'s `amberLag` at `ServiceStatus.hs:76`; `ready_max_lag_seconds` (300); `metrics_as_of_epoch` (321), the epoch `palmares.drep_metrics` was last refreshed for (`Gov.hs:468-477`). **Still OPEN, three items:** no `missing_indexes` anywhere (GV-17); no matview refresh **timestamp** (the `as_of_epoch` half closed, the "when" did not — `grep -rn "refreshed_at\|last_refresh" src/exe/query-api/ sql/` → 0); and `X-Data-Lag-Seconds` (`Gov.hs:630`) is **still absent from `docs/generated/swagger/query-swagger-api.json`** — in fact the document declares **no response headers at all** (`grep -o 'X-[A-Za-z-]*'` → 0 matches), so `X-Attest-Slot`, `X-Attest-Lag-Seconds` and `X-Attest-State` joined it undocumented. See NEW-GV-9 |
| GV-24 | Low | **PARTIAL** | FIXED: the `docs/superpowers/F1-PROGRESS.md` pointer is gone — `config/reconcile-sample.preprod.json:23` now says "Redraw with the commands in `docs/deployment/koios-parity-gate.md`". **Still OPEN:** `.github/workflows/reconcile.yml:25` `continue-on-error: true` (unchanged, but now with a stated rationale at `:3-7` and a release gate that reads the artifact instead — so this is a documented decision, not drift); `config/reconcile-sample.preprod.json:26` still pins `"recorded_at_epoch": 320` while preprod is at 321; `Palmares/Reconcile.hs:596` still hard-codes `Divergence "freshness" "epoch_skew"`; `sample_age_epochs` still appears nowhere under `src/` |
| GV-25 (checks not in CI) | Low | **FIXED 2026-10-24** (`b65ae24`) | Re-verified at HEAD: `.github/workflows/ci.yml:322-334` runs all seven files through `scripts/check_sql_checks.sh`, which rewrites each condition to `TRUE OR <condition>` so PostgreSQL analyses it in full before folding, self-tests that property every run (`:62-80,:100-115`), and proves every relation, column, function, cast and type in all 135 ASSERTs resolves — and nothing about any number. The against-preprod run stays the authority; `ea90f48` reports all seven green there |
| GV-25 (no check covers thresholds) | Low | **INVALID** | Unchanged: `sql/checks/030_votes.sql` and `040_power.sql` are both untouched since the reconciliation, so the three pins it cited still stand |
| GV-25 (other coverage gaps) | Low | **PARTIAL** (narrowed) | Two of the three named gaps closed. CSV: `scripts/smoke_query_api.sh` now exercises `Accept: text/csv` on seven routes (`:165,293,399,450,678,684,690`) plus two 406 refusals (`:696,729`). `drep_metrics` beyond one DRep: `sql/checks/070_drep_metrics.sql:114` asserts the denominator for EVERY DRep, and `UnitTests.MetricAgreement` covers all five metrics per DRep over a seeded corpus. **Still open:** `sql/checks/040_power.sql:84` is still the single tip-agreement row for one fixture DRep (`:78-88`), and `/search` has no smoke assertion at all (`grep -n search scripts/smoke_query_api.sh` → 0; it is live and answers, measured 0.07 s) |

---

### DC-01 / GV-03 — do the two implementations agree?

**They agree now, and the disagreement the reconciliation derived was real and is measured.**
`ec3a243` changed one word.

Agree exactly, unchanged since the reconciliation: `rationale_rate` and its five grades
(`030_metrics.sql:105-142` vs `rationale_rate_v1.sql:41-71` — both one row per eligible action via
`seq_last = 1`); `vote_latency_*` (`030:143-160` vs `vote_latency_median_hours_v1.sql:21-33` — both
`seq_first = 1`); `votes_cast` (both `count(DISTINCT gov_action_id)`). `eligible_actions()` carries
`GROUP BY gov_action_id, action_type` (`020_views.sql:38`), so neither side can duplicate the
denominator set.

**`eligible_actions` no longer differs.** `sql/030_metrics.sql:79` is now
`count(DISTINCT e.gov_action_id)`, computed over the same `LEFT JOIN dv` that fans out to one row per
vote; the `DISTINCT` is what collapses it back to the eligible set, which is what
`participation_rate_v1.sql:51` counts directly. The numerator at `:80` is unchanged
(`count(DISTINCT v.gov_action_id)`). So:


catalog   eligible_actions = E        participation_rate = V / E
matview   eligible_actions = E        participation_rate = V / E      -- identical by construction

The pre-fix drift was not hypothetical and was measured on preprod at epoch 321 over 809 DReps:
**23 DReps affected, 171 excess rows, worst single inflation +90 actions (65 → 155), worst rate error
0.3395.** For one credential the published formula gives `38/65 = 0.5846` and the matview served
`0.2452` out of its own column — thirty-four percentage points understated on a person's public
record. The matview's old comment applied `DISTINCT` to the numerator "so a re-voter cannot exceed
100%" and left `count(*)` in the denominator of the same aggregate: the bound was achieved by
inflating it. (`sql/checks/030_votes.sql:33-38` pins the cause: 69 re-voted (DRep, action) pairs,
the worst voted 20 times.)

`030_metrics.sql:200-212` and `participation_rate_v1.sql:38-43` also both gained the
registration-interval overlap test `palmares.eligible_actions` already applied, which is GV-20 —
so `open_actions_unvoted` is the fourth number on which the two copies agree, and both are now
right rather than both wrong.

**The reconciliation's recommended fix (a) — run the 070 agreement over all DReps — shipped and
passes.** `sql/checks/070_drep_metrics.sql:100-115` is a `LATERAL` over every row of
`palmares.drep_metrics` asserting `m.eligible_actions = count(*) FROM palmares.eligible_actions(…)`,
measured at 736 ms over 812 rows and run against real preprod with the fix: passes, 821 rows at
epoch 321. The full per-metric agreement could not widen the same way — every other metric
references `palmares.vote`, and a per-DRep `LATERAL` re-pays a 3.2 M-row `voting_procedure` pass 812
times, measured in minutes — so CI covers the rest through `UnitTests.MetricAgreement`, which
compares the **served** `drepMetricsQuery` response (not the matview, so it also covers
`votes_by_type`, computed in Haskell and a third copy) against the catalog's embedded bytes run by
`formula_id`, for every DRep in a four-block nine-row seeded corpus. Verified to catch the bug:
restoring `count(*)` fails with "drep 1: eligible_actions expected 4 but got 5".

Live, 2026-10-24: `/dreps?limit=5&order_by=votes_cast&order=desc` serves five DReps whose
`participation_rate` equals `votes_cast / eligible_actions` to the last digit (`16/119 =
0.13445378151260504`), and `/drep/drep1y2qn0rf…`'s per-type `eligible_actions` sum to **119**
against `metrics.eligible_actions` **119** — the self-contradiction NEW-GV-1 named is gone.

Two implementations remain, deliberately. `030_metrics.sql:32` and its header record why
generating the matview from the catalog was rejected (a per-DRep statement pays the
`voting_procedure` pass each time, where the batched shape pays it once in 3.1 s; generating it
needs a transform smarter than textual inclusion, i.e. a second generator to maintain). That was
never the finding — the finding was that nothing asserted their agreement, and now something does.

### VERIFY items settled

| Question | Answer | Source | What it means for the finding |
|---|---|---|---|
| `GV-12` — is db-sync's `expiration` = `gasExpiresAfter + 1`? | **Yes, literally.** db-sync: `DB.govActionProposalExpiration = (\epochNum -> unEpochNo epochNum + 1) <$> govExpiresAt`, where `govExpiresAt = Ledger.addEpochInterval e ei` with `ei = ppGovActionLifetime` — the same two inputs and the same formula the ledger uses for `gasExpiresAfter` (`mkGovActionState`: `gasExpiresAfter = addEpochInterval curEpoch expiryInterval`, no `+1`). The schema comment does not disclose the `+1`. | [db-sync `Insert/GovAction.hs#L99`](https://github.com/IntersectMBO/cardano-db-sync/blob/13.7.2.1/cardano-db-sync/src/Cardano/DbSync/Era/Universal/Insert/GovAction.hs#L99), [`Ledger/Types.hs#L202-205`](https://github.com/IntersectMBO/cardano-db-sync/blob/master/cardano-db-sync/src/Cardano/DbSync/Ledger/Types.hs#L202-L205), [ledger `Rules/Gov.hs`](https://github.com/IntersectMBO/cardano-ledger/blob/master/eras/conway/impl/src/Cardano/Ledger/Conway/Rules/Gov.hs) | **GV-12 confirmed, and FIXED 2026-10-24 (`ea90f48`).** `sql/010_gov_views.sql:358` is now `LEAST(g.expiration - 1, …)`, and the `drep_votable` window at `:371` carries the same `- 1`. The three pinned counts in `sql/checks/020_eligibility.sql` moved by one (119/12/115 → 120/11/116, fixture DRep 114 → 115), and `sql/checks/050_actions_committee_treasury.sql`'s three pins of the same drifting shape were replaced with lifecycle invariants. **The blanket fix NEW-GV-5 warned against was avoided — but by a uniform `last_votable_epoch + 1` for the power epoch rather than by two columns, which is right for two of the three terminal arms and one too high for the third: NEW-GV-8.** |
| `GV-12` — is a vote legal in the epoch *equal* to `gasExpiresAfter`? | **Yes.** `checkVotesAreNotForExpiredActions curEpoch votes = checkDisallowedVotes votes VotingOnExpiredGovAction $ \GovActionState{gasExpiresAfter} _ -> curEpoch <= gasExpiresAfter`; the lambda is the *allowed* predicate and the failure collects its negation. | [ledger `Rules/Gov.hs` L356-362, L646-650](https://github.com/IntersectMBO/cardano-ledger/blob/master/eras/conway/impl/src/Cardano/Ledger/Conway/Rules/Gov.hs) | The rule quoted in the view header (`010_gov_views.sql:311-313`) is correct; only the column it is applied to is off by one. Independently corroborated by the repo's own data: "no vote was ever observed later than `expired_epoch - 1`" (`010:325`). |
| `GV-08` — db-sync's `ratified_epoch` boundary | **Settled: `ratified_epoch` = the epoch just STARTED, written verbatim.** db-sync force-completes, at the first block of epoch N, the pulser the ledger freshly seeded at that same boundary (`finishDRepPulser`, then `updateRatified syncEnv epochNo`, `DB.updateGovActionRatified gaId (unEpochNo epochNo)` — no adjustment; `epochNo = sdEpochNo details`). That pulser's `dpProposals` was frozen at the boundary, so it holds votes **through the end of epoch N-1**. The ledger applies the *previous* boundary's pulser, so an action stamped `ratified_epoch = N` **stays a live, votable proposal all through epoch N** — GOV has no "already ratified" gate — and is only removed at the boundary into N+1, which db-sync records as `enacted_epoch = N+1`. | [db-sync `Insert/GovAction.hs#L427-430`](https://github.com/IntersectMBO/cardano-db-sync/blob/13.7.2.1/cardano-db-sync/src/Cardano/DbSync/Era/Universal/Insert/GovAction.hs), [`Universal/Block.hs#L74,L136-137`](https://github.com/IntersectMBO/cardano-db-sync/blob/master/cardano-db-sync/src/Cardano/DbSync/Era/Universal/Block.hs), [ledger `Rules/Epoch.hs#L296-320,L376`](https://github.com/IntersectMBO/cardano-ledger/blob/master/eras/conway/impl/src/Cardano/Ledger/Conway/Rules/Epoch.hs), [`Rules/Gov.hs#L604-608`](https://github.com/IntersectMBO/cardano-ledger/blob/master/eras/conway/impl/src/Cardano/Ledger/Conway/Rules/Gov.hs) | **GV-08 is INVALID** and the real defect is elsewhere: those epoch-N votes are legal, recorded, and *provably non-counting* — which `palmares.vote_tally` does not know (**NEW-GV-6**). `ratified_epoch = N` also means "in force from N+1", not N. |
| Which `drep_distr` epoch a ratification weighs | **The same label db-sync writes for that boundary.** `RatifyEnv.reCurrentEpoch = dpCurrentEpoch`, frozen at pulser creation, and db-sync's `insertDrepDistr epochNo drepSnapshot` writes `drepDistrEpochNo = unEpochNo e` for the *same* `e` it passes to `updateRatified` — one pulser, one call, two columns. | [ledger `Governance/DRepPulser.hs#L393-421`](https://github.com/IntersectMBO/cardano-ledger/blob/master/eras/conway/impl/src/Cardano/Ledger/Conway/Governance/DRepPulser.hs), [db-sync `Universal/Epoch.hs#L75-78`](https://github.com/IntersectMBO/cardano-db-sync/blob/13.7.2.1/cardano-db-sync/src/Cardano/DbSync/Era/Universal/Epoch.hs) | **Good news for `vote_tally`.** `last_votable_epoch` happens to equal the right `drep_distr` epoch in all three terminal shapes (ratified → `ratified_epoch`; expired → `expiration = expired_epoch`; open → `expiration`, the boundary of the last attempt). `020_views.sql`'s `vote_tally` no longer reads `last_votable_epoch` for power: `sql/020_views.sql:303` now computes `power_epoch = LEAST(f.last_votable_epoch + 1, sync_state.drep_distr_epoch)` and publishes it as the tally's `epoch` (`:330`). The clamp is a real fix (an in-flight action's bound is in the future, so `COALESCE(…, 0)` was publishing `yes_power: 0` for a live action with 40 DRep votes) and the `+ 1` is right for the expiration and open arms. It is one too high for the **ratified** arm, where `last_votable_epoch = ratified_epoch` and this VERIFY established that the weighing distribution is `drep_distr.epoch_no = ratified_epoch` itself. Measured live — see NEW-GV-8. `Gov.hs:1434` (`voteFrom`) still reads `drep_epoch_power` at `w.last_votable_epoch`, unclamped and un-incremented, so the per-vote power and the tally power are now computed at two different epochs. |
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
- **GV-03 — right in substance, wrong in tense, and now CLOSED.** It said a drift "would" change
  every served number while the gates stay green; the drift was already there, and `ec3a243`
  measured it (23 DReps, 171 excess rows, 0.3395 worst rate error) and removed it with
  `count(DISTINCT e.gov_action_id)`. Fix (a) shipped too and passes on the current corpus
  (`sql/checks/070_drep_metrics.sql:114`, 821 rows at epoch 321). §DC-01 is rewritten.
- **GV-10 — mechanism real, predicted 503 not established.** The 41.7 s at `Gov.hs:1895` was measured
  on the dashboard's totals statement, and the same comment records that naming the needed columns
  drops it to 213 ms because PostgreSQL prunes the view's targetlist. The only live evidence about the
  *list* page — `scripts/smoke_query_api.sh:272-274`, asserting `/gov-actions?limit=200` returns all
  131 rows with `g.votes_cast` selected (`Gov.hs:1151`) — points the other way. The correlated count
  at `020_views.sql:282-296` is real and worth removing; "would answer 503" is unproven and the
  finding's own `EXPLAIN ANALYZE` caveat should be the headline, not a footnote. **Removed
  2026-10-24** (`b65ae24`): `sql/020_views.sql:471` counts over the `palmares.vote_partition`
  pre-aggregation instead, 6.0 ms for all 131 actions and verified against the number it replaced
  with 0 disagreements. Measured live with `g.votes_cast` selected: `/gov-actions?limit=5` answers
  in 0.0145 s.
- **GV-23 — the `/status` field list is stale, and four more of its items closed on 2026-10-24.**
  `3894e75` published `drep_distr_epoch`, `amber_lag_seconds`, `ready_max_lag_seconds` and
  `metrics_as_of_epoch`, plus a whole `attestation` block; all six verified on the live `/status`
  and in `StatusResponse` at Swagger 1.7.0. Three items survive: `missing_indexes`, a matview
  refresh timestamp, and `X-Data-Lag-Seconds` in the generated Swagger — which that document still
  cannot carry, because it declares no response headers at all (NEW-GV-9). Still PARTIAL.

### New findings

- **NEW-GV-1 — High — FIXED 2026-10-24 (`ec3a243`). The served `eligible_actions`/`participation_rate`
  fanned out on re-votes, and one `/drep/{id}` response contradicted itself.** Closed by
  `count(DISTINCT e.gov_action_id)` at `sql/030_metrics.sql:79`. Both halves verified live:
  `participation_rate` equals the served `votes_cast / eligible_actions` exactly, and for
  `drep1y2qn0rf…` the per-type `eligible_actions` sum to 119 against `metrics.eligible_actions` 119.
  The `smoke_query_api.sh` one-DRep assertion is backed up by `sql/checks/070_drep_metrics.sql:114`
  (every DRep) and `UnitTests.MetricAgreement` (every metric, every DRep, seeded corpus). Original
  text follows for the record: `sql/030_metrics.sql:68-80` takes `count(*)` across a
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
- **NEW-GV-5 — Medium — HEEDED 2026-10-24 (`ea90f48`), by a different mechanism, with one residual
  (NEW-GV-8). GV-12's recommended fix would have broken the tally's power epoch, and did not.** The
  two quantities were separated, but not into two `action_window` columns: `last_votable_epoch`
  became the eligibility bound (`expiration - 1`) and `vote_tally` grew its own
  `power_epoch = LEAST(last_votable_epoch + 1, sync_state.drep_distr_epoch)`
  (`sql/020_views.sql:303`), published as the tally's `epoch` (`:330`). The coupling this finding
  predicted was observed on the way: correcting the bound alone took zero-power tallies from 4 to
  32, and separating the two took them to 0. The clamp additionally fixed a defect this finding did
  not name — an in-flight action's bound is in the future, so a live ParameterChange with 40 DRep
  votes published `yes_power: 0` and `ratio: null`. `sql/checks/040_power.sql` still does not pin
  the two apart. Original text follows for the record:
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
- **NEW-GV-7 — Low — OPEN; reworded, not corrected. `cip100_valid`'s published contract mis-states
  db-sync.** At HEAD `sql/010_gov_views.sql:13` says "or the check was inconclusive: db-sync writes
  is_valid NULL for that, and preprod has such a row" and `:55` still offers `cip100_valid` so a
  consumer can tell "checked and failed (FALSE)" from "check was inconclusive (NULL)". "Inconclusive"
  is still the wrong reading: db-sync's NULL means the fetched body is not valid JSON at all.
  Original text follows:
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
- **NEW-GV-4 — Low — FIXED 2026-10-24 (`bf3e1b6`). `attestation_credential` was written and never
  served.** `AttestationRow` now carries `attestationRowCredential :: Maybe Text`
  (`QueryResponses.hs:1902`, documented at `:1894-1901` as the history that `profile.credential` is
  the current state of) and `toAttestationRow` reads it at `Query/Attest.hs:627`. Original text
  follows for the record: ADR 0003 (`6d0a76a`)
  added the column (`Palmares/Storage.hs:149`) and writes it (`:469`), and
  `docs/generated/swagger/query-swagger-api.json` (1.2.0) now publishes `credential_claim` and
  `credential_withdrawal` as `AttestationType` values. But `AttestationRow`
  (`QueryResponses.hs:1818-1834`) has no credential field and `toAttestationRow`
  (`Query/Attest.hs:384-405`) never reads it, so `/attestations?kind=credential_claim` returns rows
  whose defining payload is absent: a client sees *that* a credential was claimed or withdrawn, never
  *which*, and cannot reconstruct a profile's credential history even though
  `AttestProfileRow.credential` (`QueryResponses.hs:1800`) publishes the current value. The write path
  and the Swagger vocabulary moved; the read projection did not.

- **NEW-GV-8 — Medium — `vote_tally`'s `power_epoch` is one epoch too late for every RATIFIED
  action.** `sql/020_views.sql:303` computes `power_epoch = LEAST(last_votable_epoch + 1,
  sync_state.drep_distr_epoch)` uniformly. `last_votable_epoch` is
  `LEAST(expiration - 1, COALESCE(ratified_epoch, …), COALESCE(expired_epoch, …),
  COALESCE(dropped_epoch - 1, …))` (`010_gov_views.sql:357-362`), so the `+ 1` recovers the right
  epoch only when the `expiration - 1` arm won: for an **expired** action it gives `expiration`,
  which §VERIFY settled as correct, and for an **open** one it gives the boundary of the last
  attempt, also correct. For a **ratified** action the `ratified_epoch` arm wins, so `power_epoch =
  ratified_epoch + 1` — while §VERIFY settled, from db-sync's source, that the weighing distribution
  is `drep_distr.epoch_no = ratified_epoch` itself (`insertDrepDistr epochNo` and `updateRatified
  … epochNo`, one pulser, one call, two columns). Measured live: `/gov-action/e641ec80…#0` has
  `ratified_epoch 304`, `last_votable_epoch 304`, and all three tally rows publish `"epoch": 305`.
  11 of 131 preprod actions are `enacted` and all of them are in this shape. The clamp cannot mask
  it — `drep_distr_epoch` is 321 and these actions ratified at 295-304 — so a ratified action's
  published `yes_power`/`no_power`/`ratio` are weighed at a snapshot the ledger did not use. Also
  inconsistent with the per-vote surface: `Query/Gov.hs:1434` (`voteFrom`) reads `drep_epoch_power`
  at `w.last_votable_epoch`, neither incremented nor clamped, so `/votes` and `/gov-action/{id}`
  now weigh the same vote at two different epochs. Fix: make the `+ 1` arm-specific — `expiration`
  for the expiration/open arms, `ratified_epoch` for the ratified arm, `dropped_epoch` for dropped —
  which is NEW-GV-5's "two columns" done once in `action_window`, and pin them apart in
  `sql/checks/040_power.sql` as NEW-GV-5 asked.
- **NEW-GV-9 — Low — the generated Swagger declares no response headers, so four published headers
  are invisible to a generated client.** `docs/generated/swagger/query-swagger-api.json` (1.7.0)
  contains zero `X-` strings: `grep -o 'X-[A-Za-z-]*'` returns nothing. query-api serves four —
  `X-Data-Lag-Seconds` (`Query/Gov.hs:630`) and the three `X-Attest-*` added by `3894e75` — and
  `ccaa2a1` had to add all three to `Access-Control-Expose-Headers` (`webapi-lib/.../CORS.hs`)
  precisely so a browser could read them. `check_swagger.sh:230` asserts the `AttestationStatus`
  body properties and nothing about headers. This is GV-23's last item generalised: the document is
  the frontend's codegen input, so a header that is not in it is a header no generated client knows
  to look for.

Swagger is coherent at **1.7.0**: `AttestationType` carries all seven kinds and `DisputeVerdict` all
three, and `scripts/check_swagger.sh:41-42,191-192` asserts both as sets. `DisputeRow.verdict` is
`$ref: DisputeVerdict` with `x-nullable: true`, so `VerdictExpired` needed no read-path change.
All 15 paged routes now `$ref` 13 distinct per-element page schemas (`Page_DRepSummary`,
`Page_VoteRecord`, …) rather than one `Page` whose element type was whichever registered last
(`ccaa2a1`).
`profile_credential` becoming derived leaves `Query/Attest.hs`'s filters valid as written.
**The metric files are NO LONGER untouched:** `resources/metrics/participation_rate_v1.sql`
(GV-20's overlap test), `resources/metric-formulas.json` (the six `spec` keys, GV-22) and
`docs/metrics.md` (GV-22's `Query.Metrics`, and `ec3a243`'s correction of the "no second
derivation" claim) all changed. The other five `resources/metrics/*.sql` are untouched, so §5's
"reviewed and not an issue" items about those five still hold; anything §5 said about
`participation_rate_v1.sql` or `docs/metrics.md` needs re-reading.

### Drift checks that came back clean

Swagger is coherent at **1.7.0**: `AttestationType` carries all seven kinds and `DisputeVerdict` all
three, and `scripts/check_swagger.sh:41-42,191-192` asserts both as sets. `DisputeRow.verdict` is
`$ref: DisputeVerdict` with `x-nullable: true`, so `VerdictExpired` needed no read-path change.
All 15 paged routes now `$ref` 13 distinct per-element page schemas (`Page_DRepSummary`,
`Page_VoteRecord`, …) rather than one `Page` whose element type was whichever registered last
(`ccaa2a1`).
`profile_credential` becoming derived leaves `Query/Attest.hs`'s filters valid as written.
**The metric files are NO LONGER untouched:** `resources/metrics/participation_rate_v1.sql`
(GV-20's overlap test), `resources/metric-formulas.json` (the six `spec` keys, GV-22) and
`docs/metrics.md` (GV-22's `Query.Metrics`, and `ec3a243`'s correction of the "no second
derivation" claim) all changed. The other five `resources/metrics/*.sql` are untouched, so §5's
"reviewed and not an issue" items about those five still hold; anything §5 said about
`participation_rate_v1.sql` or `docs/metrics.md` needs re-reading.


---

## 5. [`05-tests-ci-and-delivery.md`](05-tests-ci-and-delivery.md)
Re-reconciled 2026-10-24 against `f72af4e`, **49 commits after `2bf5bde`** and 63 after the audit's
own snapshot `4eb9117`. `cabal test` was not run (no build permitted; `b65ae24` claims 772 green,
`3f0dc00` 778, `f72af4e` 779 — taken as given and not verified). Everything else was verified by
reading the file at HEAD or by running the script.

**The decisive drift fact is now the opposite of what the previous reconciliation recorded, and the
old paragraph must be deleted outright.** `git diff --name-only 2bf5bde..HEAD` outside `src/` and
`docs/` touches **47 paths**, and they are almost exactly the delivery-side files the previous
paragraph declared untouched: `.dockerignore`, `.env.example`, `.github/workflows/ci.yml`,
`.gitignore`, `CLAUDE.md`, `Dockerfile.admin`, `Dockerfile.attest-sync`,
`Dockerfile.interaction-api`, `Dockerfile.query-api`, `README.md`, `compose.yaml`,
`palmares.cabal`, three `config/*`, `resources/*`, eight `scripts/*` (including
`check_vocabulary.sh`, `check_swagger.sh`, `check_packaging.sh`, `check_sql_checks.sh` and all four
`smoke_*.sh`), six `sql/*`, and eleven `test/fixtures/snapshot/*`. The claim that these are
unchanged "in substance **and in line numbers**" is false for every one of them, and **every line
cite in the old table below had to be re-derived**.

What genuinely did **not** change since the snapshot, so a cite into one of these still resolves:
`Dockerfile.base`, `Dockerfile.runtime-base`, `.github/workflows/images.yml`,
`.github/workflows/reconcile.yml`, `.envrc`, `.justfile`, `scripts/check_gitleaks_allowlist.sh`,
`scripts/check_determinism.sh`, `deploy/**`. Note that this list is narrower than the user's brief
assumed: `Dockerfile.base` and `Dockerfile.runtime-base` are **not** among the changed Dockerfiles,
so `TD-05` and the runtime half of `TD-11` cite lines that still resolve exactly.

| ID | Sev. | Status | Evidence |
|---|---|---|---|
| TD-01 | High | **PARTIAL — the secret half FIXED 2026-10-24 (`c8ae1bf`), context bloat OPEN** | FIXED: `.dockerignore:34-35` now exclude `config/config_atlas.json` **and** `config/config_palmares_validators.json`, under a 14-line comment naming `TD-01` (`:21-33`); all four service runtimes dropped `COPY config` (`Dockerfile.{interaction-api,query-api,attest-sync}:51-53`, `Dockerfile.admin:51-55` copies only the two `config/reconcile-*` files). `docs/adr/0002-write-path-provider.md:30-31`'s "excluded by both `.gitignore` and `.dockerignore`" is now **true** (`.gitignore:44` + `.dockerignore:34`) — the row's second half is closed, not merely stale. Still OPEN: `.cabal/` (**3.7 GB on disk**), `out/` (5.5 MB), `experiments/`, `.vscode/` are still in the build context — `grep -qxF` against `.dockerignore` returns no match for any of the four. `COPY config ./config` survives in all four *builder* stages at `:22`, which is now harmless only because the context no longer carries the two files. |
| TD-02 | High | **FIXED 2026-10-24** (`ecf5228`) | `compose.yaml` now declares **eight** services, not six: `cardano-node:37`, `postgres:74`, `cardano-db-sync:111`, `kupo:179`, `interaction-api:243`, `palmares-roles:285`, **`attest-sync:311`**, `query-api:342`. `interaction-api` requires both credentials with no default — `:261` `BASIC_USER: "${BASIC_USER:?set BASIC_USER — interaction-api is fail-closed and will not boot without it}"`, `:262` the same for `BASIC_PASS` — so compose names the missing variable instead of letting `Auth.hs:62`'s `die` kill the container. `query-api` stays `profiles: [app]` (`:343`) and `attest-sync` is `profiles: [write]` (`:312`), so the `write` profile now both boots and projects what it submits. |
| TD-03 | High | **FIXED 2026-10-24** (`3acdb39`) | The one cache is now two, and the `dist-newstyle` half is keyed on `palmares.cabal`. `ci.yml:147-150`: `path: dist-newstyle`, `key: …-dist-${{ hashFiles('cabal.project.freeze','cabal.project','palmares.cabal','sql/**','resources/**','test/fixtures/*.sql') }}` and **no `restore-keys`** — so a `ghc-options` edit changes the key and a near miss restores nothing rather than a stale build tree. `restore-keys` survives only on the `cabal-store` cache (`:125-129`), where an additive store is the right behaviour. The embed inputs are in the key for the reason `:131-137` records, and `scripts/check_packaging.sh` now pins the count: run at HEAD, exit **0**, "15 embedFile inputs in the cache key, the sdist and the Views case". |
| TD-04 | Medium | **FIXED 2026-10-24** (`a1b3fab`), and **WRONG: the row's "21 of 70" is wrong at HEAD in both numbers** | `a1b3fab` added exactly the six the row named, as pure `(True, False)` pairs in one group, `MutationGuards.hs:1442-1500` ("Mp6, Mg, O6, P2, P5, N0: the codes with no pair (TD-04)"): `Mp6` `:1446`, `Mg` `:1455`, `O6` `:1465`, `P2` `:1473`, `P5` `:1482`, `N0` `:1491`. `K3` is gone with `Protocol/Id.hs` and the test group's own Haddock says so (`:1433-1435`). The real census at HEAD is **13 uncovered of 74** — not 21 of 70 — and **all thirteen are structural `traceError` fall-through arms**, so the behavioural untested set is **empty**. See §Trace-code coverage for the derivation. Repo rule still at `src/test/CLAUDE.md:36-37`. |
| TD-05 | Medium | OPEN — checked: both base Dockerfiles are byte-identical to the snapshot (`git diff --name-only 4eb9117..HEAD` lists neither), so every cite still resolves | `Dockerfile.base:4` `benz0li/ghc-musl:9.6.6` and `Dockerfile.runtime-base:5` `alpine:3.20` by tag; `apk add` without versions at `base:8,:12,:40`; libsodium 1.0.19 tarball unchecksummed (`base:50`, `runtime-base:24`); secp256k1 `--branch 'v0.3.2'` (`base:57`, `runtime-base:34`); blst `ARG BLST_REF=v0.3.15` + `git checkout` (`base:66,:70`, `runtime-base:42,:47`). CI is still `haskell-actions/setup@v2` + apt + source blst (`ci.yml:104`, `:73-81`). No job runs `cabal test` inside the builder. |
| TD-06 | Medium | OPEN (re-run at HEAD) — and the exclusion is now **wider** than when the audit wrote it | `bash scripts/check_vocabulary.sh` → exit **0**, last line `vocabulary OK`, ten `ok` lines. The `DORMANT` list (`scripts/check_vocabulary.sh:32`) now excludes **8** paths, up from 8 with a different membership (`Query/Pages.hs` added). The comment at `:24-27` claims the five test modules are "comment-prefixed out of the test-suite's `other-modules`" — still **false**: all five are live in `palmares.cabal` (`Test.Fixtures:488`, `TestRuns:500`, `UnitTests.Attestation:512`, `UnitTests.Cleanup:514`, `UnitTests.Oracle:538`), so all five compile. The hidden live hit is still there: `src/test/TestRuns.hs:16` contains "the promotion-acceptance attack", which matches the banned `[Pp]romotion`. The three `Query/*` exclusions remain legitimate (`palmares.cabal:360,:367,:368` comment them out) and still hide real hits — `Query/Projected.hs` 12, `Query/Aggregates.hs` 1 (`:38` "either practitioners or organizations"), `Query/Pages.hs` 0. Candidate arithmetic re-derived: **155 → 147**, not 150 → 142. |
| TD-07 | Medium | OPEN — checked: `reconcile.yml` is unchanged since the snapshot, so all three cites resolve exactly | `.github/workflows/reconcile.yml:25` `continue-on-error: true` (now under a comment, `:23-24`, that argues for it); `:58` `ghcr.io/mariusgeorgescu/palmares-admin:latest`; `grep -nE 'gh issue\|notif\|slack'` over the file returns nothing. The artifact upload (`:62-66`) is still the only consumer, and the release gate that reads it is prose in `docs/deployment/koios-parity-gate.md`, not a job. |
| TD-08 | Medium | PARTIAL — substance OPEN, and **WRONG: the counts are wrong twice over, in the audit AND in the previous reconciliation** | Substance stands: `compose.yaml:181` `cardanosolutions/kupo:v2.12.0` by tag; `:245,:289,:313,:344` four palmares images by `${TAG:-latest}`; the header still claims at `:23-24` "every image is pinned by its multi-arch INDEX digest" and at `:2` "arm64 and amd64 both work" while `images.yml:74,:116` publish `linux/arm64` only; node and Postgres still have no caps — `deploy:`/`limits:` appears once, `:150-155`, for db-sync alone. The counts: the audit said "five of seven" and "four palmares images"; the previous reconciliation corrected that to "three of six" and "two palmares images". **Both are wrong at HEAD.** Eight services, eight images; digest-pinned **three** (`:39` node, `:76` postgres, `:113` db-sync), not pinned **five** (`:181` Kupo + four palmares). So the header is false for **five of eight**, and **four** palmares images appear in compose, which is the audit's original number reached for a different reason. |
| TD-09 | Medium | PARTIAL — ports FIXED 2026-10-24 (`ecf5228`), the default superuser password OPEN | FIXED: every published port now binds loopback — `compose.yaml:101` `["127.0.0.1:${POSTGRES_PORT:-5432}:5432"]`, `:224` Kupo, `:268` interaction-api, `:329` attest-sync (new), `:367` query-api. OPEN: `POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-devonly}` survives at `compose.yaml:80` and `:127`, and `:292` interpolates the same default into `palmares-roles`' `PG_CONN_STR`. A guessable default on a loopback-only port is a smaller hole, not a closed one. Related and genuinely closed beyond the row: `Dockerfile.attest-sync` no longer bakes `PG_CONN_STR="…password=postgres…"` (`:55-62` records the removal). |
| TD-10 | Medium | PARTIAL — gitleaks/blst/`permissions` OPEN, and the `docker/*` citation still wrong | `ci.yml:385-387` gitleaks 8.30.1 fetched by `curl -fsSL … \| tar -xz` with no checksum; `:76` `git clone --depth 1 --branch v0.3.15`; `grep -n 'uses:' .github/workflows/ci.yml` returns **six** lines — `:29,:294,:367` `actions/checkout@v4`, `:104` `haskell-actions/setup@v2`, `:125,:147` `actions/cache@v4` — all by major tag; `grep -n 'permissions:' .github/workflows/*.yml` matches only `images.yml:44` and `:88`, so `ci.yml` still has no `permissions:` block. The `docker/*@v3/v6` half of the citation remains **INVALID**: the only `docker/*` actions in the repo are `images.yml:55,:56,:70,:97,:98,:112`. |
| TD-11 | Medium | PARTIAL — the baked DSN FIXED 2026-10-24, `USER` and the layer hygiene OPEN | FIXED: `Dockerfile.attest-sync:55-66` deleted both baked defaults and keeps only `ENV FETCH_BATCH_SIZE=100000`, with the reason recorded ("A fail-closed check whose value is supplied by the image is not fail-closed"); `grep -n PG_CONN_STR Dockerfile.*` now matches only a comment. OPEN: `grep -nE '^\s*USER' Dockerfile.*` returns **nothing** — six Dockerfiles, no `USER`, and no `adduser`/`addgroup` either; `ecf5228`'s "stops running as superuser" is about the **Postgres** role (`query-api` → `palmares_owner`), not the container user. `Dockerfile.runtime-base:22,:32,:44` still add three virtual package sets and `:57` deletes them in a fourth `RUN`; `grep -rn 'executable-stripping'` over `Dockerfile.*` and `palmares.cabal` is empty. |
| TD-12 | Medium | OPEN — checked: `images.yml` is unchanged since the snapshot | `.github/workflows/images.yml:2-5` — `push: tags: ["v*.*.*"]` + `workflow_dispatch:` only, no `pull_request`. `:7-12` now argues the case (a full static musl build of the Cardano tree, over an hour for the base alone, four services on top, every main-triggered run cancelled by the next commit), which makes it a recorded decision rather than an oversight — but the finding's consequence, that no pull request ever builds an image, is unchanged. |
| TD-13 | Low | **FIXED 2026-10-24** — and the row's count is stale: it is **39 call sites, not 35** | The premise is gone twice over. (1) The name is per CALL, not per process: `src/test/Test/Pg.hs:53` `scratchCounter = unsafePerformIO (newIORef 0)`, `:95` `n <- atomicModifyIORef' scratchCounter (\k -> (k + 1, k))`, `:96` `dbName = "palmares_test_" <> T.pack (show pid) <> "_" <> T.pack (show n)`, under a Haddock at `:48` saying exactly why. (2) The concurrency is now exercised rather than avoided: `ci.yml:175-178` runs `cabal test all --test-show-details=direct --test-options='-j4'` as a second step on the already-built binary, and `:166-174` records the measurement that justified it (84 failures of 706 under `-j4` with the old per-process name, none serially). The three executables still carry `-threaded` and the test suite still does not (`palmares.cabal:353,:410,:447`), which is now irrelevant because `-j4` is passed explicitly. Current call-site count, `withScratchDb` outside its own definition and import lines: **39** — `AttestSchema.hs` 14, `Views.hs` 6, `Activity.hs` 5, `Refresh.hs` 4, `Projections.hs` 4, `MetricAgreement.hs` 2, `Anchor.hs`/`AttestRead.hs`/`MetricCatalog.hs`/`ThresholdMap.hs` 1 each. |
| TD-14 | Low | **FIXED 2026-10-24** (correction retained) | Verified again at HEAD. `README.md:125` exports `PALMARES_TEST_PG_CONN_STR`; `:192-194` name all three variables, `:193` documents the optional fixture DSN and `:194` the gate; `.env.example:49-61` carries the test-suite block with the fixture DSN and the gate left deliberately EMPTY, each with the reason. The gate itself is `src/test/UnitTests/MetricFixture.hs:246-255` — `lookupEnv "PALMARES_REQUIRE_FIXTURE_GATE"`, non-empty turns the skip into an `assertFailure` naming the variable — and `ci.yml:191-204` asserts the property on a `TASTY_PATTERN`-filtered run instead of setting it on a run that cannot satisfy it (`:155-158` explains why not on the main run). `Test/Pg.hs` still `die`s, which is correct and not the finding. **The "8 to 10" claim in this row is wrong** — `grep -c 'withFixture "' src/test/UnitTests/MetricFixture.hs` is **8** at HEAD, unchanged, and all eight route through the one gated helper. |
| TD-15 | Low | PARTIAL — README and `palmares.cabal:81-82` FIXED, nine strings still stale | **FIXED:** `README.md:80` now reads "the measurement rigs behind the ADRs, kept while an ADR still cites one" (the "deleted once their numbers land in an ADR" promise is gone); `:172-173` scope `BASIC_USER`/`BASIC_PASS` to `interaction-api` alone and mark them "required, **fail-closed**", matching the one reader, `webapi-lib/Palmares/WebAPI/Auth.hs:56-57`; `:181` gives `FETCH_BATCH_SIZE` as "default `10000000` in the binary, `100000` as the images and `compose.yaml` set it", which is what `src/exe/attest-sync/Main.hs:142`, `Dockerfile.attest-sync:66` and `compose.yaml:319` actually do; `:196` records `BATCH_SIZE`'s removal from table, `.env.example` and Dockerfile; `palmares.cabal:79-84` deleted the quoted size and says so ("which is why no number is quoted here any more"). **Still stale verbatim:** `palmares.cabal:19-21` ("The SQL and metric-catalog globs below are deliberately commented out" — they are LIVE at `:29-32`), `:40-41` (leftover commented duplicates of `:29-30`), `:99-101` ("Every `exposed-modules` / `other-modules` list in this file is present but comment-prefixed" — 46 live module lines in the test-suite stanza alone), `:359,:365` (`Metrics.Catalog` / `Query.Metrics` commented out — neither file exists under `src/exe/query-api/`, while `Palmares.Metrics.Catalog` is live at `:230`); `ci.yml:238-239` orphaned pasted instructions (**cite moved from `:150-151`**); `scripts/smoke_attest_flow.sh:34` "this repo ships no signer" against `admin sign-tx` (`src/exe/admin/Main.hs:388`); `src/test/Test/Helpers.hs:37` and `src/test/UnitTests/Oracle.hs:23` still call `preserve-logging` a cabal *flag* "on by default" while `palmares.cabal:94-95` says it is deliberately not a flag; commented-out `remove-trace` pragmas at `Validators/AttestationsValidator.hs:6` and `Validators/ProfilesValidator.hs:8`; `extraction-keep.txt` still present. The two items the row called "worse" are both closed — see `NEW-TD-3` and `NEW-TD-4` in §New findings. |
| TD-16 | Low | OPEN (re-run at HEAD) | `env PATH=/usr/bin:/bin bash scripts/check_gitleaks_allowlist.sh` → `  skip gitleaks not found (pass its path as $1, or install it)`, exit **0**; identical under the full `PATH`, since no `gitleaks` is installed on this machine either. The skip is `scripts/check_gitleaks_allowlist.sh:40-44`. File unchanged since the snapshot. The skip is harmless in CI, where `ci.yml:400` passes `/tmp/gitleaks` from the step above, and unconditional everywhere else — including the pre-push hook the header at `ci.yml:371-372` says runs the same code. |
| TD-17 | Low | OPEN — checked: `.envrc` and `.justfile` are unchanged since the snapshot | `.envrc:26` `PATH_add $(nix build --print-out-paths nixpkgs#xz.dev)/lib/pkgconfig`, `:41-42` two `nix eval --raw nixpkgs#xz.dev` — the unpinned flake registry is still consulted on every directory load; `:38` unconditional `just link-hls`; `.justfile:11` `cabal run . -- {{ OPTS }} 2>&1 \|\| true` (ambiguous across four executables, exit code swallowed). |
| TD-18 | Low | OPEN — checked: `deploy/**` is unchanged since the snapshot | `deploy/node-config/SOURCES.sha256:3` "Fetched 2026-10-19. Verify with:  shasum -a 256 -c SOURCES.sha256"; `grep -rn SOURCES.sha256 .github/ scripts/ deploy/` finds only that line itself — no job and no script verifies it. `experiments/dbsync-preprod/run.sh:10` still verifies only its own copy. |
| TD-19 | Low | PARTIAL — the one-way wipe OPEN, the policy-change wipe deliberately removed, one runbook of three now exists | OPEN: `src/exe/attest-sync/Main.hs:115-117` `needWipe = case mProbe of Nothing -> False; Just (storedVersion, _) -> storedVersion < currentSchemaVersion` — a `storedVersion > currentSchemaVersion` (an older binary against a newer database) still falls through to `runAttest pool runMigrations` at `:121` against a newer table shape. `currentSchemaVersion` is now **6** (`src/lib/offchain-lib/Palmares/Storage.hs:352`), up from 4, so the wipe path has fired twice more since the snapshot. Changed, and deliberately: the `storedPolicy /= policyHexText` arm is gone — `:101-110` records it as ADR 0007 stance (a), "a redeploy is a new registry and the old records remain readable" — so the row's paraphrase of the predicate is out of date. Runbooks: `docs/deployment/` holds `attest-flow-smoke.md` and `koios-parity-gate.md`; `preprod-dbsync-sync.md`, still named at `scripts/check_determinism.sh:25-26`, is still **MISSING**, and there is still no deploy/rollback or key-rotation runbook. |
| TD-20 | Info | OPEN — re-judged against two more steps; the finding is unchanged | `ci.yml:305-320` still applies `test/fixtures/dbsync-skeleton.sql` plus `sql/000_schema.sql`, `010_gov_views.sql`, `020_views.sql`, `030_metrics.sql` and runs `scripts/check_determinism.sh` over it. The skeleton has **zero `INSERT` statements in 479 lines**, so every table is empty and a plan-order nondeterminism still cannot manifest. Two steps were added since the snapshot and neither changes that: `:333-337` runs `scripts/check_sql_checks.sh` (135 line-initial `ASSERT`s across the seven `sql/checks/*.sql`, each rewritten to `ASSERT TRUE OR …` at `check_sql_checks.sh:67` so it parses and resolves without rows), and `:349-362` creates a second empty `cexplorer`, applies the same skeleton plus `sql/050_roles.sql`, then `CREATE TABLE palmares_attest.chain_cursor (slot_no bigint)` and reads `count(*)` as `palmares_ro`. Zero rows throughout. `check_determinism.sh:21-26` documents this itself and still names the runbook that does not exist. |

**Counts (2026-10-24), 20 rows:** FIXED **5** (`TD-02`, `TD-03`, `TD-04`, `TD-13`, and `TD-14`
re-confirmed from the earlier pass) · PARTIAL **7** (`TD-01`, `TD-08`, `TD-09`, `TD-10`, `TD-11`,
`TD-15`, `TD-19`) · OPEN **8** (`TD-05`, `TD-06`, `TD-07`, `TD-12`, `TD-16`, `TD-17`, `TD-18`,
`TD-20`) · MOOT 0 · INVALID 0. **WRONG 3** — `TD-04`, `TD-08` and `TD-14` each carry a count their
own text got wrong; `TD-13`'s count was merely stale. `TD-10`'s `docker/*` sub-item stays INVALID.
The `K3` and `Mp3` rows of §1a are MOOT, and `U2`/`U3` join them (both codes deleted, `NEW-TD-1`).

*(The previous pass's line — "OPEN 17 · PARTIAL 2 · FIXED 0" — is superseded, not amended: zero
FIXED became five, and every row needed a re-derived `file:line`.)*

### Trace-code coverage at HEAD

**How this list was derived, and why the two numbers already in this document are both wrong.**
A narrow one-line census —
`grep -rnoE '(traceIfFalse|traceError) *"[^"]*"' src/lib/onchain-lib/ | sed 's/.*"\(.*\)"/\1/' | sort -u`
— finds **67** codes at HEAD. It is the method §6 used, where it reported **63**; that number was
true at `4eb9117` and is now stale. But the method is also **structurally wrong**: it misses every
code whose string literal sits on a *continuation* line below its `traceIfFalse`, and it misses
`U0`, which is handed to a local `parseData`. The complete census is
`grep -rnoE '"[A-Z][A-Za-z]?[0-9a-z]{0,2}"' src/lib/onchain-lib/ | sed 's/.*:"\(.*\)"/\1/' | sort -u`,
cross-checked by locating each hit, which finds **74**. The seven the narrow grep drops are `A1`
(`AttestationsValidator.hs:163-164`), `D2` (`DisputesValidator.hs:236-237`), `Md2`
(`MintingPolicy.hs:509-510`), `Mj` (`:349-350`), `Mp2` (`:393-394`), `N2`
(`OracleNFTPolicy.hs:39-40`) and `U0` (`Utils.hs:57`). So **neither 63 nor 70 is right: the number
is 74**, and §6's bullet should say so rather than quoting a grep that undercounts by seven.
Movement since the previous table of 70: six codes added (`A8`, `Md9`, `Mda`, `Mr`, `Ms`, `Pa`), two
deleted (`U2`, `U3` — see `NEW-TD-1`). 70 + 6 − 2 = 74.

Legend for the last column: **L** = pure `ScriptContext` `(True, False)` pair against the lambda;
**E** = emulator `mustFailWith (failedWithTrace "X")`; **no** = no validator-level case (a
helper-only test is named but does not count). Code locations are under
`src/lib/onchain-lib/Palmares/Onchain/`; tests under `src/test/`. Test cites are against HEAD as
committed — five test modules were dirty in the working tree during this pass, so
`UnitTests/Oracle.hs` lines are one lower than the working copy shows.

| Code | Rule (one phrase) | Test that pins it | Validator-level? |
|---|---|---|---|
| A0 | accept arm: datum absent or unparseable (`Validators/AttestationsValidator.hs:98,100`) | — | no (structural, `traceError`) |
| A1 | re-lock the attestation accepted at the same address (`:164`) | `UnitTests/MutationGuards.hs:216` | yes (L) |
| A2 | spending purpose only (`:187`) | — | no (structural, `traceError`) |
| A3 | not already accepted (`:151`) | `UnitTests/Attestation.hs:168` | yes (E) |
| A4 | cleanup refuses a backed attestation datum (`:96`) | `UnitTests/Cleanup.hs:186` | yes (E) |
| A5 | subject's user NFT spent (`:174`) | `UnitTests/MutationGuards.hs:229` | yes (L) |
| A6 | own input holds the attestation NFT its datum names (`:186`) | `UnitTests/MutationGuards.hs:236` | yes (L) |
| A7 | a paused protocol refuses an acceptance (`:139`) | `UnitTests/MutationGuards.hs:255` **and** `UnitTests/Pause.hs:186` | yes (L + E) |
| A8 | **new** — subject's user token must not be locked with the state (`:183`) | `UnitTests/MutationGuards.hs:1391` | yes (L) |
| D0 | resolve/expire arms: datum absent or unparseable (`Validators/DisputesValidator.hs:108,110,191,193`) | — | no (structural, `traceError`) |
| D1 | the arbiter proves control of the resolution (`:158`) | `UnitTests/Dispute.hs:294` (E), `UnitTests/DisputeRules.hs:439-446` (L) | yes (E + L) |
| D2 | dispute returns closed, value less deposit, NFT-backed (`:237`) | `UnitTests/DisputeRules.hs:455,468,473,486,490` | yes (L) |
| D3 | a verdict is written once (`:151,:202`) | `UnitTests/Dispute.hs:311` (E), `UnitTests/DisputeRules.hs:627` (L) | yes (E + L) |
| D4 | the deposit returns to the address the opener named (`:273`) | `UnitTests/DisputeRules.hs:517,525,528,642`; `UnitTests/MutationGuards.hs:1038` | yes (L) |
| D5 | spending purpose only (`:205`) | — | no (structural, `traceError`) |
| D6 | exactly one dispute input per transaction (`:274`) | `UnitTests/Dispute.hs:454` (E), `UnitTests/MutationGuards.hs:1017,1036` (L); helper in `UnitTests/Satisfaction.hs` | yes (E + L) |
| D7 | a paused protocol refuses a resolution (`:145`) | `UnitTests/Pause.hs:107` (E), `UnitTests/DisputeRules.hs:653` (L) | yes (E + L) |
| D8 | cleanup refuses a backed dispute datum (`:106`) | `UnitTests/Cleanup.hs:195,245` | yes (E) |
| D9 | an expiry needs the stale-after instant to have passed (`:203`) | `UnitTests/DisputeRules.hs:616,618,623` | yes (L) |
| Da | a resolution must name a finding, not `VerdictExpired` (`:170`) | `UnitTests/DisputeRules.hs:427` | yes (L) |
| K1 | the oracle reference input is present, inline and decodes (`Protocol/Lookup.hs:54,55,56`) | `UnitTests/MutationGuards.hs:982` | yes (L, observes the exception only — the code string is not assertable) |
| K2 | the configured fee is paid to the fee address (`Protocol/Lookup.hs:107`) | `UnitTests/MutationGuards.hs:1220,1228`; helper in `UnitTests/Fees.hs` | yes (L) |
| M0 | mint gate: protocol not paused (`Validators/MintingPolicy.hs:198`) | `UnitTests/MutationGuards.hs:163` | yes (L) |
| M1 | minting purpose only (`:209`) | — | no (structural, `traceError`; `MutationGuards.hs:969` only notes it in prose) |
| Mc1 | a credential record is self-issued (`:344`) | `UnitTests/MutationGuards.hs:349` | yes (L) |
| Mc2 | a credential record must name a credential (`:345`) | `UnitTests/MutationGuards.hs:354` | yes (L) |
| Mc3 | the named credential controls this transaction (`:346`) | `UnitTests/MutationGuards.hs:358` (L) and `UnitTests/Profile.hs:187,238,267` (E); helper in `UnitTests/Claim.hs` | yes (L + E) |
| Mc4 | only a credential record may name a credential (`:347`) | `UnitTests/MutationGuards.hs:364` | yes (L) |
| Md1 | dispute mint spends the seed its redeemer names (`:508`) | `UnitTests/MutationGuards.hs:750` | yes (L) |
| Md2 | mint exactly the dispute ref NFT, burn nothing (`:510`) | `UnitTests/DisputeRules.hs:755,763,769` | yes (L) |
| Md3 | the opener's user NFT is spent (`:512`) | `UnitTests/DisputeRules.hs:779,787,798` | yes (L) |
| Md4 | target is an attestation id, opener a profile id, both this protocol's (`:517`) | `UnitTests/Dispute.hs:428` (E); helper in `UnitTests/MintInputs.hs` | yes (E) |
| Md5 | lock the dispute and deposit at the disputes address (`:546`) | `UnitTests/MetadataLimits.hs:189` | yes (L — staking-half variant only; a wrong script hash is not exercised) |
| Md6 | `openedAt` inside the validity interval (`:552`) | `UnitTests/DisputeRules.hs:810,812,819`; helper in `UnitTests/OracleRules.hs` | yes (L) |
| Md7 | dispute metadata byte limits (`:553`) | `UnitTests/MetadataLimits.hs:152` | yes (L) |
| Md8 | the deposit address is one the opening tx spends from (`:518`) | `UnitTests/Dispute.hs:374` | yes (E) |
| Md9 | **new** — opener's user token must not be locked with the dispute (`:551`) | `UnitTests/MutationGuards.hs:1401` | yes (L) |
| Mda | **new** — the deposit address must be a key address, not a script (`:545`) | `UnitTests/MutationGuards.hs:1413` **and** `:1420` (this protocol's own disputes address) | yes (L) |
| Mf | issuer's user NFT spent (exempt on `CredentialWithdrawal`) (`:325`) | `UnitTests/Attestation.hs:386` | yes (E) |
| Mg | subject and issuer are this protocol's PROFILE ids (`:326`) | `UnitTests/MutationGuards.hs:1455` (L) **and** `UnitTests/Attestation.hs:311` (E) | yes (L + E) — **closed by `a1b3fab`** |
| Mh | attestation mint spends the seed its redeemer names (`:348`) | `UnitTests/MutationGuards.hs:745` | yes (L) |
| Mj | mint exactly the attestation NFT, burn nothing (`:350`) | `UnitTests/DisputeRules.hs:900,907,912,917` | yes (L) |
| Mk | lock the attestation at the attestations address (`:352`) | `UnitTests/MetadataLimits.hs:185` | yes (L — staking-half variant only) |
| Mm | attestation metadata byte limits (`:310`) | `UnitTests/MetadataLimits.hs:134` | yes (L) |
| Mn | `otherMetadata` bounded, keys unique and unreserved (`:311`) | `UnitTests/Attestation.hs:349` (E); helper in `UnitTests/MintInputs.hs` | yes (E) |
| Mp1 | profile mint spends the seed its redeemer names (`:392`) | `UnitTests/MutationGuards.hs:740` | yes (L) |
| Mp2 | mint exactly the profile ref + user NFT, burn nothing (`:394`) | `UnitTests/Profile.hs:289,316` | yes (E) |
| Mp4 | profile metadata byte limits (`:401`) | `UnitTests/MetadataLimits.hs:139,141,143,148` | yes (L) |
| Mp5 | lock the profile at the profiles address (`:402`) | `UnitTests/MetadataLimits.hs:187` | yes (L — staking-half variant only) |
| Mp6 | the user token must not be locked with the mint's state output (`:424`) | `UnitTests/MutationGuards.hs:1446` | yes (L) — **closed by `a1b3fab`** |
| Mq | attestation date inside the validity interval (`:309`) | `UnitTests/Attestation.hs:363` (E); helper in `UnitTests/OracleRules.hs` | yes (E) |
| Mr | **new** — an attestation may not be self-issued, unless it is a credential record (`:341`) | `UnitTests/Attestation.hs:332` | yes (E) |
| Ms | **new** — issuer's user token must not be locked with the state (`:361`) | `UnitTests/MutationGuards.hs:1375` | yes (L) |
| N0 | the oracle-NFT mint spends its seed (`Validators/OracleNFTPolicy.hs:38`) | `UnitTests/MutationGuards.hs:1491` | yes (L) — **closed by `a1b3fab`** |
| N1 | minting purpose only (`:42`) | — | no (structural, `traceError`) |
| N2 | mint exactly the oracle NFT, burn nothing (`:40`) | `UnitTests/Oracle.hs:369,373` | yes (E) |
| O0 | oracle datum parses (`Validators/OracleValidator.hs:74`) | — | no (structural, `traceError`) |
| O1 | the current admin proves control (`:84`) | `UnitTests/Oracle.hs:253,322,331` | yes (E) |
| O2 | the oracle returns at the named index with the computed datum (`:85`) | `UnitTests/DisputeRules.hs:972,979,987,991,995` | yes (L) |
| O3 | spending purpose only (`:94`) | — | no (structural, `traceError`) |
| O4 | oracle redeemer parses (`:77`) | — | no (structural, `traceError`) |
| O5 | a handover is also proved by the incoming admin (`:86`) | `UnitTests/Oracle.hs:350` | yes (E) |
| O6 | the resulting params are well-formed, no negative lovelace (`:92`) | `UnitTests/MutationGuards.hs:1465` (L) **and** a 6-case pure predicate suite, `UnitTests/OracleRules.hs:91-113` | yes (L + predicate) — **closed by `a1b3fab`, which also closes `NEW-TD-2`** |
| P0 | update arm: datum absent or unparseable (`Validators/ProfilesValidator.hs:98,100`) | — | no (structural, `traceError`) |
| P1 | spending purpose only (`:136`) | — | no (structural, `traceError`) |
| P2 | own value holds the profile's ref NFT (`:158`) | `UnitTests/MutationGuards.hs:1473` | yes (L) — **closed by `a1b3fab`** |
| P3 | the profile's user NFT is spent (`:159`) | `UnitTests/MutationGuards.hs:322` | yes (L) |
| P4 | update metadata byte limits (`:160`) | `UnitTests/MetadataLimits.hs:159,161,236` | yes (L) |
| P5 | re-lock the updated profile at its own address and value (`:161`) | `UnitTests/MutationGuards.hs:1482` | yes (L) — **closed by `a1b3fab`** |
| P6 | a paused protocol refuses a profile update (`:134`) | `UnitTests/Pause.hs:97` | yes (E) |
| P7 | cleanup refuses a backed profile datum (`:96`) | `UnitTests/Cleanup.hs:177` | yes (E) |
| Pa | **new** — the user token must not be locked with the update's state output (`:178`) | `UnitTests/MutationGuards.hs:1370` | yes (L) |
| U0 | the script context parses (`Utils.hs:57`, via a local `parseData`, not `traceIfFalse`) | — | no (structural) |
| U1 | own input found by its `TxOutRef` (`Utils.hs:394`) | — | no (structural, `traceError`) |

**Uncovered: 13 of 74** — `A0 A2 D0 D5 M1 N1 O0 O3 O4 P0 P1 U0 U1`. **All thirteen are structural**,
and that is now verifiable rather than asserted: twelve are `traceError` fall-through arms whose
message is literally "No datum" / "Invalid datum" / "Invalid purpose" / "Invalid script info" /
"Invalid script purpose" / "Invalid oracle datum" / "Invalid oracle redeemer" / "Cannot find own
input by TxOutRef", and the thirteenth, `U0`, is `parseData`'s own failure label at `Utils.hs:57`.
Deleting any of them would not compile or would break every positive test, so a mutation pair is not
expressible. **The behaviourally untested set is empty.** `a1b3fab` closed exactly the six the
previous reconciliation named — `Mp6`, `Mg`, `O6`, `P2`, `P5`, `N0`, in one group at
`UnitTests/MutationGuards.hs:1442-1500`, each as a `(True, False)` pair with the attack it defends
written out — and retired `K3` as a code the protocol can no longer emit. Of the six codes added
since the previous table, **all six** (`A8`, `Md9`, `Mda`, `Mr`, `Ms`, `Pa`) landed with a
validator-level test, five of them in the `oc03Tests` group at `:1366-1422` and `Mr` as an emulator
case at `UnitTests/Attestation.hs:332`. `K3`, `Mp3`, `U2` and `U3` are deleted codes and their rows
are gone. Suite scale for reference: 705 `testCase`, 70 `mkTestFor`, 8 fixture-gated, 122 Haskell
files under `src/`.

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
- **`TD-04`'s fix list names `K3`** — INVALID, and now closed by the code itself. `3654f57` deleted
  `Protocol/Id.hs` together with `unsafeGetProtocolParamsFromProfileRefInput` and the `K3` code;
  `grep -rn '"K3"' src/lib/onchain-lib` is empty. `a1b3fab` reached the same conclusion in the
  source — `UnitTests/MutationGuards.hs:1433-1435`: "the seventh, `K3`, no longer exists … A test
  for a code the protocol cannot emit would be a test of the test." The §1a `K3` row goes with it,
  and so do the `Mp3` row (`6d0a76a`) and the `U2`/`U3` rows (`b65ae24`). All four are MOOT, not
  open work.
- **`TD-04`'s own count is WRONG at HEAD, in both figures.** The row says "21 of 70". A complete
  census finds **13 of 74**, all thirteen structural — see §Trace-code coverage for the grep and why
  the narrow `traceIfFalse` census undercounts by seven. The six codes the row lists as the ones
  that matter behaviourally were all closed by `a1b3fab` on 2026-10-24, so the behavioural untested
  set is empty and the row should read FIXED.
- **§6's "63 codes" is wrong too, and for a reason worth fixing rather than restating.** §6's last
  bullet reports that grepping the `traceIfFalse`/`traceError` string literals finds 63. At HEAD
  that grep finds 67, and the true count is 74: the one-line form misses `A1`, `D2`, `Md2`, `Mj`,
  `Mp2` and `N2`, whose literals sit on a continuation line below their `traceIfFalse`, and `U0`,
  which is handed to a local `parseData`. §5's old "70" and §6's "63" disagreed because one of them
  located every code and the other grepped one line at a time; the method, not the arithmetic, is
  the defect.
- **§1a header counts are stale, not wrong** — "63 codes; 19 E, 25 L, 22 U" was true at `4eb9117`;
  at HEAD it is **74 codes and 13 uncovered**. Likewise §0's "537 `testCase`s, 60 CLB emulator
  cases, 8 fixture-gated cases" is now **705** `testCase`s, **70** `mkTestFor` cases and **8**
  fixture-gated cases — the fixture figure is 8, not the 10 both the audit and the previous
  reconciliation gave it, as `grep -c 'withFixture "'
  src/test/UnitTests/MetricFixture.hs` confirms. §1d's "`ScriptSize.hs:237-241` … MintingPolicy
  12276" is now `ScriptSize.hs:462` and **12953**; §8's "0 of 121 Haskell files" is 0 of **122**.
  Recording these so nobody treats the drift as a finding.
- **`U0`'s citation** — §1a places it at `Utils.hs:63`; at HEAD it is `Utils.hs:57`
  (`mkUntypedLambda f c = check $ f (parseData c "U0")`), and it is handed to a local `parseData`,
  not to `traceIfFalse`. The audit's "U" verdict is right, and `U0` is now one of SEVEN codes a
  one-line `traceIfFalse` census drops, not the only one — see the derivation in §Trace-code
  coverage.
- **Three of the four rows I could not falsify on 2026-10-23 were fixed on 2026-10-24.** `TD-01`'s
  asymmetry (`.gitignore:44` excluded `config/config_atlas.json`, `.dockerignore` did not) is closed
  by `c8ae1bf` at `.dockerignore:34-35`, which also makes ADR 0002's claim true. `TD-02`'s
  `Auth.hs:62` `die` is now unreachable from compose, which requires both credentials with `:?`
  (`compose.yaml:261-262`), and `attest-sync` exists (`:311`). `TD-13`'s premise is gone twice:
  `Test/Pg.hs:95-96` names the scratch database per CALL, and `ci.yml:175-178` runs the suite at
  `-j4` to prove it. Only `TD-06` survives falsification: `bash scripts/check_vocabulary.sh` still
  exits 0 while `src/test/TestRuns.hs:16` carries a live banned hit, hidden by a `DORMANT` entry
  whose stated justification — that the module is comment-prefixed out of `other-modules` — is
  contradicted by `palmares.cabal:500`.
- **One check I ran that found no finding**, recorded so it is not re-run: `A7` makes the oracle
  reference input mandatory on every `AcceptAttestation` (via `attestationOracleToken` →
  `readOracleParams` → `K1`). `acceptAttestationTX`
  (`src/lib/offchain-lib/Palmares/TxBuilding/Operations.hs:614-618`) does call
  `getOracleAndValiditySkeleton` and includes `oracleRefSkeleton` in the `mconcat`, so the
  production accept path is wired for D-C. No regression.

### New findings

- **NEW-TD-1 — `U2` and `U3` are trace codes in unreachable code. FIXED 2026-10-24 by deletion,
  which is what this finding asked for.** `grep -rn 'checkAndGetCurrentStateDatumAndValue\|checkAndGetInlineDatum' src/`
  now returns only prose: `Utils.hs:478` records the removal ("`checkAndGetCurrentStateDatumAndValue`
  (which held `U2`) and `checkAndGetInlineDatum` (which held …)"), `Utils.hs:132` and
  `src/lib/onchain-lib/CLAUDE.md:98-99` the same, and `Protocol/Lookup.hs:12` replaces the false
  Haddock with the audit reference `NEW-OC-5`. No code emits `U2` or `U3`, the two rows are MOOT,
  and both are off every validator's size budget. The original finding follows, for the record.
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
- **NEW-TD-2 — `O6`'s predicate has no test at any level, not just no validator-level one. FIXED
  2026-10-24 by `a1b3fab`, and at both levels.** `oracleParamsAreWellFormed` (now
  `Protocol/Types.hs:257-258`) has a six-case pure suite at `UnitTests/OracleRules.hs:91-113`
  covering `opDisputeTimeoutMs` 0/-1/1, a negative `opMinUTxOValue`, a negative `opDisputeDeposit`
  and the zero-is-fine boundary — and the writing of it found a real defect, recorded at
  `ScriptSize.hs:375`: the predicate had admitted `opDisputeTimeoutMs = 0`, the exact value the
  comment beside it ruled out. `O6` also now has a validator pair at
  `UnitTests/MutationGuards.hs:1465`, and the rule is enforced off-chain before deployment at
  `TxBuilding/Transactions.hs:288-293`, the one path the on-chain check never sees. The original
  finding follows, for the record.
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
  off-chain Haddock that describes the write path. FIXED 2026-10-24: the misstatements are gone and
  what remains is deliberate history.** The count is now 16, and that is not a regression: every one
  reads as past tense about a deleted rule — `Validators/MintingPolicy.hs:396` "`Mp3` IS GONE, and
  its index is not reused", `UnitTests/MutationGuards.hs:357` "`Mc3`, the rule that was `Mp3`",
  `UnitTests/Claim.hs:67` "moving the call site from `Mp3` to `Mc3`". The specific defect this
  finding named is closed: `grep -n Mp3 src/lib/offchain-lib/Palmares/TxBuilding/Operations.hs` is
  **empty** (the sentence "a required signer and `Mp3` finds it in `txInfoSignatories`" is gone), and
  `TxBuilding/Utils.hs:81` and `DomainTypes/Core/Actions.hs:271` now describe `Mp3` as the thing ADR
  0003 replaced rather than as a live rule. The original finding follows, for the record.
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
  stale script size and is now three size moves stale itself. FIXED 2026-10-24, with exactly the
  cheap fix: the number is deleted and the pointer kept.** `palmares.cabal:80-84` now reads "The
  pair above is a dated measurement and is not re-run on every change; `UnitTests.ScriptSize` is the
  authority on the current size, **which is why no number is quoted here any more**: the two previous
  attempts to keep one in sync both went stale within days". `grep -n '12296' palmares.cabal` is
  empty. One residual, small: `:79` still says "~75% occupancy", and `ScriptSize.hs:462` now pins
  MintingPolicy at **12953** of 16384, i.e. 79 %. The original finding follows, for the record.

---

## 6. [`06-docs-spec-and-product-gaps.md`](06-docs-spec-and-product-gaps.md)
Snapshot cited by the report: `4eb9117`. Code read at: `2bf5bde`. **Re-verified at `f72af4e`
(2026-10-24), 50 commits later.**

The paragraph this replaces listed fifteen files as having **zero** changes since the snapshot. At
HEAD that is false for thirteen of them, so almost every line number in section 6 had moved:
`README.md` (+88/-…), `.env.example` (38), `compose.yaml` (112), `docs/adr/0001` (10),
`docs/adr/0002` (4), `docs/deployment/attest-flow-smoke.md` (57),
`docs/deployment/koios-parity-gate.md` (32), `src/lib/onchain-lib/Palmares/Onchain/Blueprint.hs`
(96), `src/lib/webapi-lib/Palmares/WebAPI/{Utils,CORS,Envelope}.hs` (124/8/51), `src/exe/CLAUDE.md`
(28), `src/test/CLAUDE.md` (9), `src/lib/offchain-lib/CLAUDE.md` (7),
`scripts/smoke_interaction_api.sh` (45), `scripts/smoke_query_api.sh` (46) — `git diff --stat
2bf5bde..HEAD`.

Only **two** of the fifteen are genuinely untouched: `NOTICE` and
`src/lib/webapi-lib/Palmares/WebAPI/Auth.hs` (`git log --oneline 2bf5bde..HEAD -- NOTICE
src/lib/webapi-lib/Palmares/WebAPI/Auth.hs` is empty). Those two rows (`DC-42`, and the `Auth.hs`
half of `DC-03`/`DC-40`) keep their line numbers; every other citation below is re-derived.

New since the snapshot and load-bearing for this section: `docs/spec/{README,protocol,metrics,decisions}.md`
(`74d7241`), `docs/generated/palmares-blueprint.json` (`be8afa0`), `docs/adr/0004`–`0008`,
`docs/usecases/` (`8d96c40`), a committed `config/config_palmares_validators.json` and a preprod
deployment verified on chain (`61e280b`).

| ID | Sev. | Status | Evidence |
|---|---|---|---|
| DC-01 | High | **FIXED 2026-10-24** (`ec3a243`) | `docs/metrics.md:12-20` now names `palmares.drep_metrics` as a second implementation and `UnitTests.MetricAgreement` + `sql/checks/070_drep_metrics.sql` as its gate; `grep -rn 'Query.Metrics' docs/metrics.md` = 0, and the only surviving mentions are in `docs/audit/` and `docs/architecture/system-overview.md:318-319` quoting the old text as a finding |
| DC-02 | High | OPEN | Checked all four limbs at HEAD: `README.md:34-36` still "needs one key of your own … you supply your own token … (CIP-30 / CIP-95)"; every write route behind `BasicAuth` (`interaction-api/RestAPI.hs:346,356`); compose still ships `socketPath`+`kupoUrl` (`compose.yaml:251`); no CIP-30 client in the repo. §2 is now also contradicted by its own file: `README.md:209-213` says "**If you run a node yourself, you need no key at all**" |
| DC-03 | High | **FIXED 2026-10-24** | `README.md:172-173` rows read "required, **fail-closed** \| interaction-api" — `admin` removed; `.env.example:4-5` says "The admin CLI reads neither"; `grep -rn BASIC_ src/exe/admin` = 0, sole reader still `Auth.hs:56-57` |
| DC-04 | High | **FIXED 2026-10-24** (`ecf5228`) | the DSN defaults are gone: `requirePgConnStr` `die`s (`webapi-lib/Palmares/WebAPI/Utils.hs:39-41` → `:56`), called at `query-api/Main.hs:91` and `attest-sync/Main.hs:73`. `requireEnv` generalises it and `KUPO_URL` is fail-closed too (`attest-sync/Main.hs:72`) |
| DC-05 | High | **FIXED 2026-10-24** | `README.md:177-178` both rows now read "interaction-api, attest-sync, admin"; the `die` sites moved to `attest-sync/Main.hs:78,81` |
| DC-06 | Medium | **FIXED 2026-10-24** | `BATCH_SIZE` deleted from README, `.env.example` and `Dockerfile.attest-sync`, with the removal recorded at `README.md:196-197`; `FETCH_BATCH_SIZE` row `:181` now states both numbers and matches `attest-sync/Main.hs:143` (`10_000_000`); CORS row `:174` is "optional … denies all cross-origin … query-api, interaction-api, attest-sync" |
| DC-07 | Medium | **FIXED 2026-10-24**, one nit | §11 is now 24 rows (`README.md:170-194`) and covers every name the census below finds, including the two that are new. Nit: `:185` attributes `PALMARES_READY_MAX_LAG_SECONDS` to query-api only; `admin/Reconcile.hs:93` reads it as the parity gate's ceiling |
| DC-08 | Medium | **FIXED 2026-10-24** | `README.md:120-127` adds the `docker run postgres:17-alpine` + `export PALMARES_TEST_PG_CONN_STR` step with the 127.0.0.1 note; `src/test/CLAUDE.md:50-53` now reads "**not** no database at all: 85 cases connect to one" |
| DC-09 | Medium | PARTIAL | committed half closed: `docs/generated/palmares-blueprint.json` exists (`be8afa0`, 968 lines) so `Constants.hs:26-27` resolves. Gate half open: `grep -n 'write-blueprint' .github/workflows/ci.yml` = 0, while the Swagger equivalent is at `ci.yml:256-258` |
| DC-10 | Medium | PARTIAL | compose now defines `attest-sync` (`compose.yaml:311`) and `palmares-roles` (`:285`), and `README.md:146-148` names attest-sync in the `write` profile. Still open: the §5 diagram `README.md:52-57` names neither `attest-sync` nor `interaction-api`, and §8 `:93` still says "node + db-sync + Postgres + the API" |
| DC-11 | Medium | OPEN | `deploy/` still holds `dbsync/db-sync-config.yaml` + 8 `node-config/*` and nothing else (`find deploy -type f`); `README.md:162-163` still "the Kubernetes ConfigMap is generated from it, never forked" with no manifest, no generator and no external repository named (`:79` repeats the claim) |
| DC-12 | Low | PARTIAL | §6 table (`README.md:65-80`) gained `scripts/ · config/ · deploy/`, `docs/spec/`, `docs/audit/`, `docs/architecture/`, and the experiments row `:80` is corrected to "kept while an ADR still cites one". Still: `test/`, `sql/checks`, `sql/indexes`, `licenses/` absent; `:69` still "unit, property and emulator tests" while `PropertyTests.hs:23-29` still says "the plan asked for @hedgehog@. Neither arrived" (now with a justification); `mkPrivnetTestFor`/`withPrivnet` appear only at `src/test/CLAUDE.md:16` (`grep -rn` over `src/` = 1 hit) |
| DC-13 | Medium | PARTIAL | fixed: root `CLAUDE.md:58` points at `offchain-lib/Palmares/Metrics/Catalog.hs`; `src/exe/CLAUDE.md:50-53` labels `Projected.hs`/`Pages.hs`/`Aggregates.hs` "inherited files kept on disk and commented out of `palmares.cabal`; they are not compiled"; `Query/Metrics.hs` is gone from `src/exe/CLAUDE.md`. Still open: root `CLAUDE.md:60` routes "aggregates in `Query/Aggregates.hs`, pages in `Query/Pages.hs`" — both commented out at `palmares.cabal:360,367` |
| DC-14 | Low | **FIXED 2026-10-24** | `src/lib/offchain-lib/CLAUDE.md:78-79` now reads "ID derivation (`CIP68.hs`; `Id.hs` was deleted and is not where a new one goes)" |
| DC-15 | Low | OPEN | checked both servers: Swagger is written only under `--write-swagger-only` (`query-api/Main.hs:77`, `interaction-api/Main.hs:54`) and CI diffs the file (`ci.yml:256-258`). Root `CLAUDE.md:84` still "Auto-generated on API startup"; `src/exe/CLAUDE.md:20` still "Startup: Write Swagger JSON → …" and `:91` "Written to `docs/generated/swagger/` on startup" |
| DC-16 | Low | OPEN | `CLAUDE.md:52` "New validator" row still omits `Onchain/Blueprint.hs`, `src/exe/admin/Main.hs` (`deploy-reference-scripts`), the now-committed `config/config_palmares_validators.json`, the `KUPO_MATCH` note (`compose.yaml:194,203`) and `Storage.hs`/`Ingestion.hs` |
| DC-17 | High | PARTIAL | second-pool half closed — `src/exe/CLAUDE.md:43-46` now describes the owner pool, `PALMARES_PG_OWNER_CONN_STR` and the fallback. `:42` still says "`QueryAppContext` = auth + `ProviderCtx` + the request `ConnectionPool`"; the real context is six fields with no auth and no provider (`query-api/QueryAppMonad.hs:24-42`, stated at `:6-15`), second pool at `query-api/Main.hs:104-108` |
| DC-18 | High | **FIXED 2026-10-24** | `src/exe/CLAUDE.md:85-88` now reads "It is **not** rate-limited either: `rate_limited` is declared in the error vocabulary and unreachable (`WebAPI/Envelope.hs`), and the limit the spec asks for (`docs/spec/protocol.md` §4.2) belongs to a BFF that does not exist yet" |
| DC-19 | Medium | **FIXED 2026-10-24** | `src/exe/CLAUDE.md:50-51` now "**Attestations** (`Query/Attest.hs`): `rawSql` with `??` over `palmares_attest`, schema-qualified and never aliased"; no esqueleto claim remains |
| DC-20 | Medium | OPEN | `src/exe/CLAUDE.md:56-58` still "Idempotent — every statement is `CREATE OR REPLACE` / `CREATE … IF NOT EXISTS`". Re-measured over `sql/*.sql`: `sql/000_schema.sql:10-11` is `DROP SCHEMA IF EXISTS palmares CASCADE; CREATE SCHEMA palmares;`, **19** `CREATE VIEW`, **2** `CREATE MATERIALIZED VIEW` (`030_metrics.sql:42`, `020_views.sql:221`), **2** `CREATE FUNCTION` (`020_views.sql:24,139`), **0** `CREATE OR REPLACE` |
| DC-21 | Medium | OPEN | `src/exe/CLAUDE.md:65-66` still names two of the verdict's inputs; `readyVerdict` has five guards at `query-api/Query/Gov.hs:357-375` (db reachable, lag, `drep_distr` epoch ≥ tip−1, network name, and the **summed** projector lag) |
| DC-22 | Low | PARTIAL | `runActionWithPK` half fixed at `src/exe/CLAUDE.md:11`. Still: `mkPalmaresApp` at `:25` with 0 refs (real is `mkWebApp`, `interaction-api/RestAPI.hs:421`, `query-api/RestAPI.hs:2314`); `:23-24` describes three arms where `FullAPI` has five (`interaction-api/RestAPI.hs:362-367`); `src/lib/offchain-lib/CLAUDE.md:36` still says `runPalmaresActionWithPK` (0 refs; `Transactions.hs:130`); the probe still answers 200 for `Behind False` (`attest-sync/ChainsyncAPI.hs:148`) |
| DC-23 | Medium | OPEN | `src/lib/onchain-lib/CLAUDE.md:33` still "Only MintingPolicy is parameterized" and `:107` repeats it; `OracleNFTPolicy.hs:57` is `TxOutRef -> CompiledCode …` and `MintingPolicy.hs:568` is `ProtocolParams -> …`, so two scripts take a parameter. The other four `*Compile` signatures take none |
| DC-24 | Medium | OPEN | `src/lib/onchain-lib/CLAUDE.md:94-95` still "any date carried in a datum is validated against the transaction's validity interval — never trusted as supplied"; `attestationPeriod` is deliberately unvalidated and self-reported (`Protocol/Types.hs:538` "__self-reported__", field at `:558`) |
| DC-25 | Low | **FIXED 2026-10-24** | `src/lib/onchain-lib/CLAUDE.md:96-103` rewritten: "exactly three live readers — `readOracleParams`, `feeFor` and `checkFee`. The `unsafeGet*` profile helpers it used to export were deleted with `Protocol/Id.hs`" |
| DC-26 | Low | OPEN (worse again) | `src/lib/onchain-lib/CLAUDE.md:9` still "Keep lambdas under ~80 lines". Re-measured at HEAD: `disputesLambda` **137** lines / 37 non-comment (`DisputesValidator.hs:85-221`), `attestationsLambda` **115** / 39 (`AttestationsValidator.hs:81-195`), `profilesLambda` 65/26, `oracleLambda` 64/25, `mintingPolicyLambda` 40/33. Both numbers grew since `2bf5bde` (132→137, 107→115) |
| DC-27 | Low | PARTIAL (narrowed) | `src/lib/offchain-lib/CLAUDE.md:26-27` still names `utxoDatum'`/`utxosDatums`; `grep -rn "utxoDatum'\|utxosDatums" src --include='*.hs'` = **0**. The `:92` architecture-docs half stays closed (four docs + 26 diagrams in `docs/architecture/`) |
| DC-28 | Medium | PARTIAL, and the remainder moved | "fourteen" is fixed: `docs/adr/0001:12` now "nineteen read-only views, one materialized view, two SQL functions". **The matview count is now the wrong one**: there are two (`sql/030_metrics.sql:42` `drep_metrics`, `sql/020_views.sql:221` `vote_partition`), both refreshed by `query-api/Query/Refresh.hs:105`. Same stale "one" at `adr/0001:61,108`, `README.md:54` and root `CLAUDE.md:23-24` |
| DC-29 | High | PARTIAL | status half fixed: `docs/adr/0002:3-5` is "**superseded 2026-10-23 by ADR 0004**", and ADR 0004 carries the current decision. `:11` ("token is supplied from the environment") and `:30` ("A provider token is the only secret in the deployment") are unchanged, now framed by `:5` as "Kept as dated evidence"; the secret inventory the finding asked for exists nowhere |
| DC-30 | Low | PARTIAL | the attest-sync citation is gone — `grep -n 'ADR 000' src/exe/attest-sync/Main.hs` returns only ADR 0007 at `:101`. `sql/050_roles.sql:3` still says "ADR 0001 chose to co-locat[e] …" and ADR 0001 still has no roles paragraph (`grep -in 'role\|palmares_owner\|second database' docs/adr/0001-*.md` = 0) |
| DC-31 | Low | OPEN (status half still INVALID) | `docs/adr/0001:39` still "see the design notes in the originating repository" for T1–T7 and `:47` still "once T-SUBSTRATE-3/4 land"; neither resolves in this repository. The "accepted while PVC is open" half was already false at `4eb9117` and remains disclosed at `:3-4` |
| DC-32 | Medium | **FIXED 2026-10-24** | the paragraph is rewritten: `docs/deployment/attest-flow-smoke.md:142-158` describes `/status.attestation` (slot, Kupo tip, lag, `state`, `last_sync_at`, `is_ready`, policy, last error), the three `X-Attest-*` headers, what `/ready` is red on and why not on `syncing`. Verified live: `curl -s localhost:8083/status` returns `"attest_lag_seconds":81` and an `attestation` object |
| DC-33 | Medium | PARTIAL | the published contract is fixed — `webapi-lib/Palmares/WebAPI/Utils.hs:155` is now "Cardano address as RAW CBOR HEX (114 hex characters), **not bech32**", and both generated documents carry it (`GYAddress.description`, read off the JSON). **`docs/deployment/attest-flow-smoke.md:93-97` still apologises for the bech32 text**, so an internal doc now documents a fixed defect as live |
| DC-34 | Low | PARTIAL | "F1 check N" now resolves: `docs/spec/protocol.md:395-520` numbers F1's checks (1–12), and seven scripts/workflows cite them. `operation.prv` is still documented only as "admin key" (`CLAUDE.md:15`); `grep -n 'new-operator-key\|mnemonic' README.md` = **0**, so the 24-word mnemonic (`admin/Main.hs:370-376`) and the fund-then-`operator-address` sequence are still undocumented in the README |
| DC-35 | High | **FIXED 2026-10-24** | `src/exe/interaction-api/RestAPI.hs:283` is `& info . license ?~ "Apache-2.0"` (with `:280` recording the GPL inheritance); both committed documents report `info.license.name = "Apache-2.0"`, and `scripts/check_swagger.sh:306-317` now runs an `icheck` block over the write document |
| DC-36 | Low | PARTIAL | the "not shared" half is fixed — `addSharedSwaggerDescriptions` is called from both (`query-api/RestAPI.hs:2001`, `interaction-api/RestAPI.hs:319`), and the query document now carries the `GYAssetClass` text. Still four silent no-ops: `GYTime`, `GYPubKeyHash`, `DRepId`, `GovActionId` (`webapi-lib/Utils.hs:156-161`) match **no** definition in either document (checked by loading both JSONs and by `curl`ing the live `/swagger-api.json`) |
| DC-37 | Low | OPEN (restated) | four numbers, all four re-read; the two API versions moved again. See the version census below |
| DC-38 | Low | OPEN | `DomainTypes/Core/Types.hs:48` still "(@person_drep@, @organization@, …)" while both documents publish `person_d_rep`. The bonus error also survives: `:66-67` still claims "@ProfileType@ is absent from both generated Swagger documents today" — it is present in both, with the six-value enum (`curl localhost:8083/swagger-api.json` → `['person_d_rep','organization','committee','community','vendor','auditor']`) |
| DC-39 | Low | OPEN | `palmares.cabal:19-21` still says the SQL and metric-catalog globs are "deliberately commented out" (they are live at `:26-38`); `:40-41` is still the stale commented duplicate; `:99-101` still says every module list "is present but comment-prefixed" while only five lines are (`:359,360,365,367,368`) |
| DC-40 | High | PARTIAL | the boot-blocking halves are closed: `compose.yaml:261-262` sets `BASIC_USER`/`BASIC_PASS` with `:?` and a named reason, `attest-sync` exists at `:311`, `palmares-roles` at `:285`, every port binds `127.0.0.1`. Still wrong: `compose.yaml:241-242`'s "`operation.prv` is bind-mounted read-only" — the `interaction-api` service's volumes are `node-ipc:/ipc:ro` and `./config:/app/config:ro` only (`:264-268`) |
| DC-41 | Low | **FIXED 2026-10-24** | `.env.example:4-5` ("The admin CLI reads neither"), `:8-10` (CORS optional, three services, "NOT a boot failure"), `:23-25` (`FETCH_BATCH_SIZE=100000` explained against the binary's `10000000`); `BATCH_SIZE` is gone; `READY_MAX_LAG_SLOTS` added at `:27-34` |
| DC-42 | Low | OPEN | `NOTICE:11-12` unchanged — `NOTICE` is one of only two files in the preamble's list with no commit since `2bf5bde`; the only in-repo hit for "license report" is still `NOTICE` itself |
| DC-43 | High | **FIXED 2026-10-24** (`74d7241`) | `docs/spec/{README,protocol,metrics,decisions}.md` exist; `protocol.md`'s numbering is frozen as the citation key (`docs/spec/README.md`, rule 3) and carries §2, §3, §4.1, §4.3, §6; all eight `spec` fields in `resources/metric-formulas.json` point at `docs/spec/metrics.md#<formula_id>` and the anchors exist (`docs/spec/metrics.md:18,54,81,101,134,154,167,189`); `grep -c 'docs/superpowers' docs/metrics.md resources/metric-formulas.json` = **0/0** |
| PG-01 | — | OPEN | re-checked: no `web/`, `frontend/` or `explorer/` directory; `README.md:7,32,56` still promise an explorer with no link. New since the snapshot and not a frontend: `docs/usecases/` (`8d96c40`), four documents described as "the frontend's input" |
| PG-02 | — | **FIXED 2026-10-24** (`ecf5228`, `61e280b`) | `compose.yaml` now defines `attest-sync:311` and `palmares-roles:285`, the `write` profile supplies `BASIC_*` (`:261-262`), and the flow has been run on a deployment: `config/config_palmares_validators.json` is committed and its `mintingPolicyHashAndRef` policy id `648c6a73…` equals the live `/status`'s `"policy_id"` |
| PG-03 | — | PARTIAL | four blockers closed: ADR 0002 is superseded not proposed (`adr/0002:3`), the blueprint is committed, the validators config is committed with frozen hashes, and the deployment is verified on chain (`61e280b`). Still: `platforms: linux/arm64` only (`.github/workflows/images.yml:74,116`) against an x86_64 mainnet host, PVC unsized (`adr/0001:66,95`), no cluster manifests in the repo (DC-11) |
| PG-04 | — | PARTIAL | DRep-id printer closed: `operator-address` prints bech32, raw hex **and** the CIP-129 DRep id (`admin/Main.hs:378-386`). 23 commands now (`new-operator-key operator-address sign-tx deploy-reference-scripts write-blueprint write-metrics-doc reconcile-koios apply-indexes apply-roles pause-protocol unpause-protocol set-fees set-min-utxo-value set-dispute-deposit set-dispute-timeout rotate-admin rotate-arbiter submit-tx query-oracle update-profile issue-attestation accept-attestation cleanup-dust`). Still absent: `claim-profile`, `claim-credential`, `withdraw-credential`, `open-dispute`, `resolve-dispute`, `expire-dispute`, and any `palmares_attest` read |
| PG-05 | — | **FIXED 2026-10-24** (`075882b`, ADR 0004) | `README.md:203-214` documents the three provider shapes, that mixing two lets the first that parses win, the no-key `{socketPath, kupoUrl}` path as measured, the `--match '*'` requirement and the macOS socket limit; ADR 0004 carries the measurement |
| PG-06 | — | OPEN | `grep -rn 'CIP-95'` over the repo outside `docs/` = **1 hit**, `README.md:36`. The only signer is still `admin sign-tx`; a credentialled profile now needs **two** signed transactions (`/claim-profile` then `/claim-credential`, `scripts/smoke_attest_flow.sh:297,330`) |
| PG-07 | — | OPEN (wording) | `.github/workflows/reconcile.yml:15` is still `cron: "0 3 * * *"` and `:25` still `continue-on-error: true`, over the pinned sample; `README.md:17` still says only "Koios is used as an independent cross-check, never as a source". `a6ef22d` fixed the 90 false divergences, not the claim's wording |
| PG-08 | — | PARTIAL | the `/status` half is now fully closed (`3894e75`, `99189f0`): `attest_lag_seconds` **and** an `attestation` block **and** three `X-Attest-*` headers, asserted at `scripts/check_swagger.sh:194,212,215` and observed live. Still: no Prometheus endpoint on any of our services (`grep -rn 'prometheus' src/exe/*/RestAPI.hs` = 0; only Kupo's, `compose.yaml:226-228`) and no alerting |
| PG-09 | — | OPEN (wording) | re-derived from the committed query document's `produces`: CSV on seven governance routes (`/dreps`, `/votes`, `/gov-actions`, `/delegations`, `/spos`, `/treasury-withdrawals`, `/drep/{drep-id}/delegators`); none for attestations, by design |
| PG-10 | — | MOOT | unchanged; its own "What exists" column concludes "Not a gap". It should not carry a PG id — the honest count of this block is 15 |
| PG-11 | — | OPEN (restated) | six profile kinds and **seven** attestation kinds in both documents (verified by loading both JSONs); `person_d_rep` is still the published spelling and still undecided — `DomainTypes/Core/Types.hs:48` says the opposite |
| PG-12 | — | PARTIAL | `docs/generated/palmares-blueprint.json` is committed (`be8afa0`); no CI step regenerates or diffs it (`grep -n write-blueprint .github/workflows/ci.yml` = 0) |
| PG-13 | — | OPEN | no rate limiting in `src`, `compose.yaml` or `.github` (`grep -rni 'rate.limit'` returns prose only: `Envelope.hs:131`, `QueryAppMonad.hs:14`, `query-api/RestAPI.hs:9`, `src/exe/CLAUDE.md:85`). The gap is now *documented* (DC-18) rather than closed |
| PG-14 | — | **MOOT** (`2cc6fc1`, ADR 0006 / `OC-05`) | there is no lineage attestation to mislabel: `Mg` requires the subject to be a **profile** id by CIP-67 label, so an attestation about an attestation is refused at the mint (`MintingPolicy.hs:239-245`, reasoned at `AttestationsValidator.hs:14-28`). `subject_kind` is unnecessary — every subject is a profile |
| PG-15 | — | OPEN | read off the committed query document: `AttestationRow.properties` = `accepted block_hash claimed_period credential date description id image_uri issuer kind name other_metadata output_index slot subject tx_hash` — no `dispute_count`/`contested`; `AttestProfileRow` has no `claimant_count`. New since the snapshot: `/disputes` and `/disputes/{dispute-id}` list routes, so the data is reachable by a second request |
| PG-16 | — | OPEN (holds) | no Koios read in the serving path, no composite-score field in any DTO |

Read-layer obligations re-graded at HEAD: **RL-1 PASS**, **RL-2 PASS**, **RL-3 PARTIAL**,
**RL-4 MOOT** (was FAIL), **RL-5 PASS**, **RL-6 PARTIAL**.

**RL-4 is no longer an obligation.** A lineage attestation cannot be minted: `Mg` types the subject
by CIP-67 label and refuses anything but a profile id (`MintingPolicy.hs:239-245`), and
`AttestationsValidator.hs:14-28` records the reasoning — "a feature whose only reachable outcome is
a stuck record is not a feature" (ADR 0006, `OC-05`). The read layer therefore has nothing to
mislabel as pending, and `PG-14` goes with it.

**The ADR 0003 wrinkle is closed.** `attestation_credential` is now published:
`AttestationRow.credential` is in both the committed query document and the live one, and the row
description names it. A `credential_claim` attestation is no longer served as a row whose content is
invisible.

Still open: `AttestationRow` carries no dispute marker — no `dispute_count`, `contested` or
`open_disputes` — so a list row beside an **upheld** dispute looks like any other (RL-3); disputes
are still inlined on the detail route only, though `/disputes` and `/disputes/{dispute-id}` now make
them reachable by a second request. `AttestProfileRow` still has no `claimant_count` and no claim
status, so a verification screen that starts from a profile cannot see a contested credential
(RL-6); the only signal remains `total > 1` on `/profiles/by-credential/{credential}`.
### Environment-variable census at HEAD

The set of names the code reads **has** drifted: two were added, and `BATCH_SIZE` was deleted from
the three places that set it and the zero that read it. At HEAD the code reads **22 runtime names
and 3 test names**. `README.md` §11 was rewritten in the same window and now has 24 rows; six of the
seven wrong or incomplete rows the snapshot found are corrected. Corrected table:

| Variable | Read by (file:line at HEAD) | Code default | Fail-closed? | README §11 verdict |
|---|---|---|---|---|
| `BASIC_USER`, `BASIC_PASS` | `webapi-lib/.../Auth.hs:56-57` ← `interaction-api/Main.hs` | none | yes (`die` at `Auth.hs:62`) | ✓ `:172-173` — "interaction-api" only, admin dropped |
| `CORS_ALLOWED_ORIGINS` | `webapi-lib/.../CORS.hs:39` ← query-api, interaction-api, `attest-sync/Main.hs:65` | `[]` | no, by design (silent deny-all) | ✓ `:174` — "optional; unset or empty denies all cross-origin … and not a boot failure" |
| `PG_CONN_STR` | `webapi-lib/.../Utils.hs:41` via `requirePgConnStr` ← `query-api/Main.hs:91`, `attest-sync/Main.hs:73` | **none** | **yes** (`die` at `Utils.hs:56`) | ✓ `:175` — "required" is now true |
| `PALMARES_PG_OWNER_CONN_STR` | `query-api/Main.hs:104` | falls back to `PG_CONN_STR` | n/a | ✓ `:176` |
| `ATLAS_CORE_CONFIG` | `interaction-api/Main.hs:59`, `attest-sync/Main.hs:78`, `admin/Main.hs:1058,1110` | `config/config_atlas.json` | yes, all three | ✓ `:177` — attest-sync named |
| `DEPLOYED_VALIDATORS_CONFIG` | `interaction-api/Main.hs:60`, `attest-sync/Main.hs:81`, `admin/Main.hs:1099` | `config/config_palmares_validators.json` | yes for the two services | ✓ `:178` — attest-sync named |
| `PORT` | `webapi-lib/.../Utils.hs:60` ← `8082`/`8083`/`8084` (`interaction-api/Main.hs:70`, `query-api/Main.hs:130`, `attest-sync/Main.hs:64`) | per service | no | ✓ `:179` |
| `KUPO_URL` | `attest-sync/Main.hs:72` via `requireEnv` | **none** | **yes** (`Utils.hs:56`) | ✓ `:180` — "required, **fail-closed** — no default" |
| `BATCH_SIZE` | **nowhere** (`grep '"BATCH_SIZE"' src` = 0) | — | — | ✓ **deleted**, and the deletion is recorded at `:196-197` |
| `FETCH_BATCH_SIZE` | `attest-sync/Main.hs:142-143` | `10_000_000` | no | ✓ `:181` — states both the binary's and the images' number |
| `ROLLBACK_MARGIN` | `attest-sync/Main.hs:146-147` ← `Constants.hs:34-35` | 2160 | no | ✓ `:182` |
| `READY_MAX_LAG_SLOTS` | **new** — `attest-sync/ChainSyncLogic.hs:80` | 1200 | no (unparseable falls back) | ✓ `:183` |
| `PALMARES_VIEW_REFRESH_SECONDS` | `query-api/Query/Refresh.hs:115` | 300 | no | ✓ `:184` |
| `PALMARES_READY_MAX_LAG_SECONDS` | `query-api/Query/Gov.hs:403`; also `admin/Reconcile.hs:93` | 300 | no | **incomplete** — `:185` says query-api; the admin use is still undocumented |
| `PALMARES_AMBER_LAG_SECONDS` | `query-api/Query/Gov.hs:407` | 120 | no | ✓ `:186` |
| `PALMARES_FRESHNESS_POLL_MS` | `query-api/Query/Gov.hs:411` | 5000 | no | ✓ `:188` |
| `PALMARES_NETWORK_NAME` | `query-api/Query/Gov.hs:419` | `preprod` — drives `/ready`'s network check (`Gov.hs:362`) | no | ✓ `:187` |
| `PALMARES_ADMIN_CONN_STR` | `admin/Main.hs:1135` | none | yes | ✓ `:189` |
| `PALMARES_OWNER_PASSWORD`, `PALMARES_RO_PASSWORD` | `admin/Main.hs:950-951` | none | yes | ✓ `:190` |
| `PALMARES_API`, `KOIOS_API`, `KOIOS_API_TOKEN` | `admin/Reconcile.hs:91-92,415` | `""` / preprod Koios / none | `reconcile_koios.sh` requires `PALMARES_API` | ✓ `:191` |
| `PALMARES_TEST_PG_CONN_STR` | `src/test/Test/Pg.hs:58` | none | test `die`s | ✓ `:192`, and §10 `:120-127` |
| `PALMARES_FIXTURE_PG_CONN_STR` | `src/test/UnitTests/MetricFixture.hs:241` | none | fixture skips | ✓ `:193` |
| `PALMARES_REQUIRE_FIXTURE_GATE` | **new** — `src/test/UnitTests/MetricFixture.hs:246` | none | turns a skip into a failure | ✓ `:194` |
| `MAESTRO_API_KEY` | nowhere | — | — | ✓ correctly excluded, and `:199-207` now says why (Atlas reads the provider out of the core config; Maestro withdrew its API) |

Net: 24 README rows, **1 incomplete**, **0 wrong**, **0 names absent**, **0 names documented that
nothing reads**. The snapshot's figure was 14 rows with 6 wrong or incomplete, 11 absent and 1
phantom. `DC-03`, `DC-05`, `DC-06`, `DC-07` and `DC-41` close on this table; `DC-04` closes on the
code column.

### Version census at HEAD

| Thing | Value | Source |
|---|---|---|
| query-api Swagger `info.version` | **1.7.0** | `src/exe/query-api/RestAPI.hs:1966`; same in `docs/generated/swagger/query-swagger-api.json`; same served live (`curl localhost:8083/swagger-api.json`) |
| interaction-api Swagger `info.version` | **3.5.0** | `src/exe/interaction-api/RestAPI.hs:272`; same in `docs/generated/swagger/interaction-swagger-api.json`; same served live (`curl -u … localhost:8082/swagger-api.json`) |
| `appVersion` reported by every probe | **1.0.0** | `src/lib/offchain-lib/Palmares/Constants.hs:30-31`; observed: `curl -u … localhost:8082/status` → `"version":"1.0.0"` |
| cabal package version | **0.1.0** | `palmares.cabal:3` |

**Verdict: still inconsistent, and the gap has widened by another five minor versions.** The two API
numbers moved again (`1.2.0`→`1.7.0` across `ccaa2a1`, `5ae17bf`, `b65ae24`, `7ab6d6e`, `3f0dc00`;
`3.1.0`→`3.5.0` across `ecf5228`, `fff93cd`, `ec18712`, `b65ae24`, `7ab6d6e`) while `appVersion` and
the cabal version did not. The collision the report pointed at is live and now observable from one
request: the same process serves `info.version: 1.7.0` on `/swagger-api.json` and
`"version":"1.0.0"` on `/status`. `DC-37` stands. Two things *do* now hold that did not: both
documents agree with their source, and `scripts/check_swagger.sh:35` pins the query document's
number so a bump arrives as a reviewed diff — but **nothing pins the write document's version**
(`check_swagger.sh`'s `icheck` block checks license and title only), which is why
`scripts/smoke_interaction_api.sh:72` can still assert `3.3.0` with no gate going red (NEW-DC-3).

### Stale documentation ADR 0003 created

Mostly closed. `be8afa0` regenerated the CIP-57 blueprint from a rewritten `Blueprint.hs` (96 lines
changed, against the byte-identical diff the snapshot found), `3f0dc00`/`f72af4e` and `b65ae24`
rewrote both smoke scripts, `b65ae24` rewrote the shared Swagger descriptions, and the architecture
set was reconciled in place. Nineteen of the twenty-three rows are closed; the three that remain are
all in documents a human reads rather than a client parses, and one of them (`NEW-DC-3`) fails a
deployment check.

| ID | Sev. | Status | Location at HEAD | Verdict |
|---|---|---|---|---|
| NEW-DC-1 | High | **FIXED** | `scripts/smoke_attest_flow.sh:293-335` | step 2 is split: `/claim-profile` posts `{kind,name,description,image_uri,user_addresses}` with no credential and no witness (`:297,305`, with `:302-304` naming ADR 0003), then `/claim-credential` posts the credential and `witness:{"tag":"key"}` as its own signed transaction (`:330-335`) |
| NEW-DC-2 | High | **FIXED** | `scripts/smoke_attest_flow.sh:324,341-342,413-415` | `:324` now asserts `.credential == null` right after the mint; the `credential != null` and `credential_is_script` assertions moved behind a `wait_for` on the claim's projection (`:341-342`); `/profiles/by-credential/` is asserted at `:413-415` |
| NEW-DC-3 | High | **OPEN, and worse** | `scripts/smoke_interaction_api.sh:72` | still `assert /swagger-api.json '.info.version' '"3.3.0"'`. The number was bumped from `3.0.0`, but the served document is **`3.5.0`** — confirmed against the live service. F1 check 12's smoke half fails on a correct deployment, and no CI gate pins this document's version |
| NEW-DC-4 | High | **FIXED** | `scripts/smoke_interaction_api.sh:73-76` | `'[.paths\|keys[]]\|length' '15'` (the document has 15) and the loop at `:74-76` now covers `/expire-dispute`, `/claim-credential` and `/withdraw-credential`, asserting the set with `has("$p")` |
| NEW-DC-5 | High | **FIXED** | `src/exe/interaction-api/ServiceRequests.hs` → the generated document | `ClaimProfileRequest.description` is now "Mint a profile. It claims no credential: since ADR 0003 a binding is its own record, so bind the profile with POST /claim-credential afterwards"; its `properties` are `kind name description image_uri user_addresses recipient`, with no `describeField "credential"` left to no-op |
| NEW-DC-6 | High | **FIXED** | `Blueprint.hs:281-282` | "its kind (one of MilestoneDelivered, AuditPassed, Affiliation, RoleHeld, Endorsement, **CredentialClaim, CredentialWithdrawal**)" |
| NEW-DC-7 | High | **FIXED** | `Blueprint.hs:285-289` | the "no validator branches on the kind" sentence is gone: "The kind is mostly presentational … with ONE exception the protocol does enforce: the two credential kinds must name a credential and must be self-issued, and the other five must name none" |
| NEW-DC-8 | Medium | **FIXED** | `Blueprint.hs:169-170` | "NewAttestation seedTxOutRef metadata otherMetadata subject issuer kind date claimedPeriod **claimedCredential** outputIdx", with `:183-186` explaining when it is present |
| NEW-DC-9 | Medium | **FIXED** | `Blueprint.hs:280-285` | the datum list now carries "an optional CREDENTIAL, **the oracle token that authenticates the pause gate on acceptance**" |
| NEW-DC-10 | Medium | **FIXED** | `Blueprint.hs:336-340` | "ExpireDispute outputIdx — after the dispute's own staleAfter deadline, **ANYONE** may close an undecided dispute as VerdictExpired, with no signature and no oracle read … the protocol's only permissionless state transition" |
| NEW-DC-11 | Medium | **PARTIAL** | `Blueprint.hs:320` | the admin/arbiter half is fixed (`:315-316` "The oracle's ARBITER credential writes the verdict", `:332-336` "A resolution may NOT name VerdictExpired: that constructor is the clock's"). **"on EITHER verdict" survives at `:320`** while `Verdict` has three constructors (`Protocol/Types.hs:618-646`) |
| NEW-DC-12 | Medium | **FIXED** | `Blueprint.hs:356-360` | "the **STALE-AFTER instant past which anyone may expire it**", with the reason it is recorded per dispute rather than read from the oracle |
| NEW-DC-13 | Medium | **FIXED** | `Blueprint.hs:412-418` | all **seven** `OracleParams` fields are now listed — admin credential, pause flag, min UTxO, dispute deposit, dispute timeout, fee config, arbiter credential — matching `Protocol/Types.hs:88,90,92,94,106,127,148` |
| NEW-DC-14 | Medium | **FIXED** | `Blueprint.hs:380-387` | the repricing list names the dispute timeout and "Retiming is opDisputeTimeoutMs, the sixth field"; re-keying is "OracleSetAdmin for the admin and OracleSetArbiter for the arbiter" (both exist, `Protocol/Types.hs:176,196`) |
| NEW-DC-15 | Medium | **FIXED** | `Blueprint.hs:264-268` | "The transaction must reference the oracle UTxO named by the attestation's own oracleToken, because acceptance is refused while the protocol is paused" |
| NEW-DC-16 | Medium | **FIXED** | `webapi-lib/.../Utils.hs:165` → both documents | `AttestationType.description` lists all seven kinds and distinguishes them: "For the first five the kind is presentational … The last two the protocol does enforce — they must be self-issued and must name a credential that proved control of the minting transaction" |
| NEW-DC-17 | Medium | **OPEN** | `docs/deployment/attest-flow-smoke.md:16-24` | the table is still five rows and `:24` still "So the script goes over HTTP for all six, uniformly". The flow now has a sixth step (`/claim-credential`, which the script performs at `:330`) and the API has three more CLI-less routes (`/claim-credential`, `/withdraw-credential`, `/expire-dispute`) |
| NEW-DC-18 | Medium | **OPEN** | `docs/deployment/attest-flow-smoke.md:99-103` | still "Claiming a key credential puts `mustBeSignedBy <that key hash>` into the transaction (`TxBuilding/Operations.hs`, `claimProofSkeleton`)" with no route named. True of `claimProofSkeleton` (`Operations.hs:310`, called for the claim at `:618`) but the requirement now belongs to `/claim-credential`, not the profile mint |
| NEW-DC-19 | Medium | **FIXED** | `src/lib/offchain-lib/Palmares/Storage.hs:180` | "profileCredential is the CIP-129 rendering of the credential **the profile currently publishes**" — the "the datum claims" clause is gone and no longer contradicts `:334-335` |
| NEW-DC-20 | Low | **FIXED** | `src/lib/offchain-lib/Palmares/TxBuilding/Operations.hs` | `grep -n Mp3` over the file = **0**; the rule is cited as `Mc3` where it is named |
| NEW-DC-21 | Low | **FIXED** | `src/lib/offchain-lib/Palmares/TxBuilding/Utils.hs:81` | retargeted as history: "ADR 0003 was the same attack against a profile's own credential field and @Mp3@" |
| NEW-DC-22 | Low | **FIXED** | `scripts/check_swagger.sh:185-192` | the heading is "The attestation kinds, as wire spellings"; "five" is gone, `grep -n 'five attestation' scripts/check_swagger.sh` = 0, and the assertion is the seven-element **set** |
| NEW-DC-23 | Low | **FIXED** | `docs/architecture/{onchain-protocol,onchain-flows,system-overview}.md` + `README.md` | the set was reconciled (`a1c0a6e`, `04add06`): `onchain-protocol.md:292` "**A profile datum carries no credential** — ADR 0003 removed `profileCredential`", `:441` lists the three-field datum, `:561,580,873-875` record `Mp3` as retired and not reused, `onchain-flows.md:221,594,706` likewise; `docs/architecture/README.md:3,9` stamps the whole set as reconciled against `2bf5bde` |

### Items I judge wrong

- **DC-31, the status half — INVALID when written.** The report says ADR 0001 is "`Status: accepted` while
  the PVC verdict is 'open' (`:65`)". At the snapshot the status line already read "accepted; … (PVC sizing
  and the memory fork still open — see the fork below)" (`git show 4eb9117:docs/adr/0001-governance-data-substrate.md`,
  lines 3-4). The disclosure the finding asks for was already there. Its other half — T1–T7 and
  T-SUBSTRATE-3/4 naming nothing in the repo — is correct and stays open.
- **PG-10 is not a finding.** Its own "What exists" column concludes "Not a gap unless the explorer
  promises it". Carrying a PG id for a non-gap inflates the count of 16; the honest count is 15.
  Re-checked 2026-10-24: unchanged, and `PG-14` has since joined it as MOOT for a different reason —
  lineage attestations are refused at the mint (ADR 0006), so the honest count is now 14.
- **The audit `README.md` §9 mapping was wrong about DC-14 and DC-25, and both are now closed for
  real.** §9 listed both as "resolved" by `3654f57`; the commit deleted the *code* and fixed only the
  *root* `CLAUDE.md`, leaving two library files naming deleted symbols. Both were corrected on
  2026-10-24: `src/lib/offchain-lib/CLAUDE.md:78-79` now reads "(`CIP68.hs`; `Id.hs` was deleted and
  is not where a new one goes)" and `src/lib/onchain-lib/CLAUDE.md:96-103` names the three live
  readers and says the `unsafeGet*` helpers "were deleted with `Protocol/Id.hs`". DC-14 and DC-25 are
  FIXED; the §9 mapping was still wrong when written, which is why it is recorded here.
- **§9 is right that DC-34's `operator-address` row drifted, and the drift is bigger than "two forms →
  three".** Appendix B's row also says "config only (network id, `:780-799`)"; at HEAD the DRep id is
  printed **before** the config is loaded and before the `die` (`admin/Main.hs:837-840`, reasoned at
  `:826-831`), so the command now produces useful output with no Atlas config at all. The appendix's
  provider column is wrong, not just its note.
- **DC-32's fix text was stale, and the finding is now closed.** The report's proposed replacement —
  "`/status` does not yet expose the projector's lag" — was already false when §9 was written
  (`9a8d79b`), so applying it verbatim would have re-introduced a false sentence. The document was
  instead rewritten correctly: `docs/deployment/attest-flow-smoke.md:142-158` names both halves, the
  three `X-Attest-*` headers and what `/ready` is red on. Verified live 2026-10-24: `/status` carries
  `attest_lag_seconds` and an `attestation` block. DC-32 is FIXED; the lesson — a fix text ages faster
  than the finding it closes — is why it stays on this list.
- **DC-26's bound should be rejected rather than restated, and the numbers have moved again.** The
  report offers "state the unit or raise the bound; disputes is within the intent". Re-measured at
  `f72af4e`: `disputesLambda` is **137** lines / 37 non-comment (`DisputesValidator.hs:85-221`) and
  `attestationsLambda` **115** / 39 (`AttestationsValidator.hs:81-195`) — both grew while the bound at
  `src/lib/onchain-lib/CLAUDE.md:9` did not move. The metric the rule uses decides the answer and the
  rule does not say which. A guideline that two of four validators violate on its plain reading, in a
  codebase whose comments outnumber its code, is not a guideline; delete it or bind it to non-comment
  lines with a number nothing currently exceeds.
- **One claim I could not confirm, and the grep was the thing at fault.** The brief stated 70 distinct
  trace codes in `onchain-lib`; a one-line grep of the `traceIfFalse`/`traceError` string literals
  finds **63**, and the 7-code gap is entirely mechanical: six codes have their literal on a
  CONTINUATION line (`A1` `D2` `Mj` `Mp2` `Md2` `N2` — e.g. `AttestationsValidator.hs:163-164`), which
  no line-oriented grep can see, and `U0` is traced through a local `parseData` rather than
  `traceIfFalse` at all. 63 + 6 + 1 = 70, so the brief was right for `2bf5bde` and this bullet was
  wrong. A census that spans the newline is the only kind that answers the question:
  `perl -0777 -ne 'while(/\b(traceIfFalse|traceError)\b\s*(?:--[^\n]*\n\s*)*"([^"]+)"/g){print "$2\n"}'`
  over `git ls-files 'src/lib/onchain-lib/**/*.hs'` gives 69 at `2bf5bde` and **73** at HEAD, which
  with `U0` is the **74** §1's trailing paragraph settles for the whole document. Two corrections to
  this bullet's own earlier wording, because it contradicted itself: the parenthesised code list it
  used to carry was the `2bf5bde` list (it still named `U2`/`U3`, both since deleted), and its closing
  sentence called `A1 D2 Md2 N2 U0` "comment-only" one line after arguing they are emitted — they are
  emitted; only `P8`/`P9` are genuinely not, being deliberately burnt by ADR 0003. Not a report-06
  finding, but any count this report's siblings publish should be re-derived the same way.
