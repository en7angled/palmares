# The `D-` and `F-` identifiers the code cites

Haddocks, SQL comments and test names in this repository carry two families of short identifiers.
Until this file existed neither family resolved to anything a reader could look up, which is the
second half of finding `DC-43`: a comment that says "(D-20)" is provenance only if the reader can
find out what D-20 decided.

Both tables below list **every identifier actually cited in this repository**, and nothing else. A
new citation must add its row here, or use no identifier at all. Most citation sites also state the
rule in words — the identifier is there to say *where the rule came from*, not to replace it.

## `D-n` — design decisions

Collision resolutions from the F1 design synthesis (2026-10-19 to 2026-10-21). Five parallel design
tracks produced contradictory proposals; each `D-n` is one contradiction and its resolution. They are
decisions about *this* codebase, which is why the code cites them where the decision is visible.

| id | The question | The decision |
|---|---|---|
| `D-1` | Governance projection tables: five, or none? | **None.** The governance layer is SQL views over db-sync plus a single materialized view (`palmares.drep_metrics`). A view cannot go stale and needs no projector service; only the attestation pipeline owns tables. |
| `D-2` | DRep eligibility: `drep_distr` membership or `drep_registration` intervals? | **Registration intervals.** `drep_distr` is the stake distribution, so using it would silently drop every DRep with zero delegated stake out of its own denominator. |
| `D-3` | The `rationale_rate` denominator: vote rows or distinct actions? | **Distinct actions.** One preprod (DRep, action) pair has **20** vote rows; counting rows would let a re-voter's rationale rate be computed over twenty copies of one decision. |
| `D-7` | `/ready` lag threshold: 120, 180 or 300 seconds? | **Red at 300 s**, with the UI's amber at 120 s as a separate, lower bar. |
| `D-9` | Publish `/metrics/formulas`, or leave the formulas in the service? | **Publish.** The catalog (`resources/metric-formulas.json` plus `resources/metrics/*.sql`) is extracted, embedded and served; `docs/metrics.md` is generated from it. |
| `D-10` | The anchor verdict: a SQL `CASE` or a Haskell classifier? | **The SQL `CASE`, in `palmares.anchor`.** It is one place, every consumer already joins that view, and a second classifier in another language would need a test between the two. |
| `D-15` | The DDL mechanism — four were proposed and two are mutually impossible. | **Two mechanisms, split by privilege and transactionality**: the schema bootstrap runs in one transaction as the owner at service boot; `REFRESH MATERIALIZED VIEW CONCURRENTLY` cannot run inside a transaction block and therefore lives in its own thread. |
| `D-17` | `age_days` nullability — `Maybe Int` or `Int`? | **`Maybe Int` in both DTOs**, null exactly when the credential never registered. |
| `D-18` | `/activity`'s page total. | **`pageTotal :: Maybe Int`**, `null` on `/activity`. A magic `-1` costs the same and lies. |
| `D-19` | The activity feed cannot produce five of its own event kinds from transactions. | **`palmares.activity` `UNION ALL`s the five epoch-boundary kinds** (ratified, enacted, expired, dropped, and the DRep-retirement boundary) with a corrected cursor. |
| `D-20` | The always-abstain / always-no-confidence pseudo-DReps in the DRep list and in the Koios parity rows. | **One view, `palmares.drep_epoch_power`, with `target_kind` and no filter.** `/dreps` and every rate filter take `target_kind = 'drep'`; the dashboard reads the pseudo-DReps deliberately. They have no `drep_registration` row and never enter `/dreps`. |
| `D-24` | CC votes are cast by hot keys, but a member is its cold credential. | **`palmares.vote` carries both** `voter_hot_hash` and `voter_cold_hash`, the cold one resolved by a `LATERAL` over `committee_registration`. |
| `D-25` | The (voter role, gov-action type) → threshold column mapping. | **A static table is a named deliverable with its own test**, consumed by `palmares.vote_tally`. It is ledger law, not a derivation, and the NULLs in it each have a different reason. |
| `D-27` | Which credential the vote-sequence window partitions by. | **`voter_id_hash`** — the COLD credential for the CC and the signing credential itself for DReps and SPOs. Partitioning by the hot key would count each hot-key rotation as a separate voter. |
| `D-31` | The activity cursor's wire format. | **Four columns, never a concatenated string.** `renderCursor` is the single definition; a `||` in SQL would be a second one, in another language, with no test between them. |

## `F-n` — inherited findings

Findings from the **Belt System** audit of 2026-07-04 (`FableReview-0407`). This repository was
extracted from that codebase, so it inherited both the code and the findings; each `F-n` below was
fixed here, and the citation marks the line that implements the fix or the test that pins it.

| id | The finding (Belt System, 2026-07-04) | How it stands here |
|---|---|---|
| `F-02` | Slot columns persisted as text, so SQL comparisons were lexicographic — `"99999999" > "100000000"`. | Slots are `Integer`; `rollbackTo` compares numerically. Pinned by `UnitTests.ChainSyncReplay` and `UnitTests.StorageRoundtrip`. |
| `F-05` | The raw-match unique key lost rows: one match per block. | The key is `(slot, header, txId, outputIndex)`, so same-block matches are all retained. |
| `F-06` | `toGYAssetClass` called `error`, so an externally triggerable crash loop. | It returns `Either`; a dotless policy id (empty asset name) parses, garbage is a `Left`. |
| `F-07` | A rollback lost projections permanently — destructive upserts with no replay. | `rollbackTo` wipes the projection tables and replays the surviving raw log in chain order, ordered by `(slot, txIndex, outputIndex)`. |
| `F-08` | `UpToDateButDifferentBlockHash` did not roll back, and `Ahead` did not look for the common ancestor. | A rollback margin of ≥ 1 guarantees the rollback slot is strictly below any orphan. The ancestor half is finding `CS-02`, closed separately: `verifyCursor` asks Kupo for the newest surviving point. |
| `F-09` | `fromBuiltinByteStringUtf8` corrupted non-ASCII text and could throw. | The encode/decode round trip preserves non-ASCII; pinned by `UnitTests.Conversions`. |
| `F-17` | The live backend applied limit/offset BEFORE the post-filters, so pages were wrong. | A page and its total come from one evaluation of one predicate: the count and the page share the `FROM` clause. The rule is cited wherever a paginated endpoint is defined. |
| `F-22` | Other on-chain hardening, grouped (extra tokens in a one-shot mint, and similar). | `N2` refuses an oracle NFT mint carrying an extra token; the rest landed as the `F-21`/`F-22`/`F-25` defensive checks. |
| `F-26` | Datum parse errors were reported as "not found". | A genuine parse failure is a distinct error from a missing UTxO. |
| `F-30` | The `/ready` probe returned 400 and duplicated the error handler. | An unknown status filter does not collapse to 400; pinned by `UnitTests.ApiHardening`. |
| `F-33` | Test holes that matter, enumerated per validator and operation. | The sub-items are cited individually (e.g. `F-33.7`, the Storage round-trip test that would have caught `F-02` and `F-05`). |

## `T-…` — implementation task ids

A third family appears in test Haddocks, SQL comments and the smoke scripts: `T-ATTEST-6`,
`T-API-11`, `T-METRIC §4`, `T-DATA §1.3`, `T-SUBSTRATE-3`. These are **task ids from the F1
implementation plans**, one prefix per design track — `T-DATA` (the db-sync layer), `T-API` (the query
API), `T-METRIC` (the formulas), `T-ATTEST` (the on-chain protocol), `T-EXTRACT` (the library
extraction), `T-INFRA`, `T-SUBSTRATE`, `T-PARITY`.

**They are deliberately not resolved here, and they are not requirements.** A plan is a build
schedule; the requirement each task implements is in [`protocol.md`](protocol.md) §9, and *which*
task a line landed in is provenance that `git log` carries better than a comment. The citations that
remain are the ones where the sentence is about what that task did — a measurement taken then ("the
87 s to 5.7 s win `T-API-11` measured"), or a behaviour that changed with it ("until `T-ATTEST-6` the
builder hardcoded a key witness"). **New code does not add them**: a comment that needs to say where
a rule came from cites `protocol.md`, an ADR, or an audit finding.

## `OF-`, `OC-`, `CS-`, `GV-`, `TD-`, `DC-`

These are findings of the **2026-10-22 audit of this repository**, not of the Belt System. They live
in `docs/audit/`, where §3 of the README carries the status of each one. A citation like `OF-08` or
`CS-04` resolves there.
