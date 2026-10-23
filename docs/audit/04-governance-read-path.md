# Audit 04 — Governance read path (SQL views, metrics, query API, Koios reconciliation)

> **Reconciled 2026-10-23 against `main` @ `2bf5bde`.** Every finding below has been re-judged; the per-finding verdicts, with current `path:line`, are in [`07-reconciliation-2026-10-23.md`](07-reconciliation-2026-10-23.md). Line references in this file are as of `4eb9117` and several have moved.

Repo: `mariusgeorgescu/palmares`, branch `main`, HEAD `4eb9117` (2026-10-22). Static review only — no
toolchain, no database, no network. Every claim below is tied to a `path:line`; where correctness
depends on ledger or db-sync behaviour that cannot be checked offline it is marked
**VERIFY** with the exact thing to check.

Scope: `sql/*.sql`, `sql/indexes`, `sql/checks`, `resources/metrics/*.sql`, `resources/metric-formulas.json`,
`src/exe/query-api/**` (governance routes), the governance DTO/filter modules, `Palmares.Reconcile*`,
`src/exe/admin/Reconcile.hs`, `config/reconcile-*`, `.github/workflows/reconcile.yml`, `webapi-lib`
(Envelope/Errors/CSV/Utils), the governance unit tests and fixtures.

## 1. Executive summary

The read path is unusually well reasoned: parameters are always bound, sort keys are closed enums,
the 30 s ceiling is a real server-side `statement_timeout`, the CSV formula guard covers every text
cell, the feed is keyset-paged with a widening window, and the reconciliation has honest exit codes
and owned waivers. The published metric SQL is byte-identical to `docs/metrics.md` (verified
mechanically), uses one leading parameter CTE per file, has no `?` outside placeholders and no
`now()`.

The problems are mostly at the seams between components, and several are latent on preprod
because the data that would expose them does not exist there yet:

| ID | Sev | One line |
|---|---|---|
| GV-01 | High | Every boot does `DROP SCHEMA palmares CASCADE` + rebuilds the matview in one transaction: with >1 replica this is a read outage and a 10 s-lock-timeout crash loop on every rolling restart |
| GV-02 | High | The Koios nightly is broken by the `unknown` DRep status: the reconciler fetches `status=active&status=inactive`, so 90 DReps become unexplained *membership* divergences in R1/R2; the committed replay snapshot predates the change and masks it |
| GV-03 | High | "The exact SQL the server executes" is not what is served: five of six DRep metrics come from the `drep_metrics` matview, a second implementation; only `delegator_retention_rate_v1` runs the catalog bytes; the agreement check is manual, preprod-only and over one DRep |
| GV-04 | High | Least privilege: the documented self-host path runs the public API as the Postgres superuser; `PG_CONN_STR` silently defaults to a superuser DSN |
| GV-05 | Medium | No rate limit, no concurrency cap; `src/exe/CLAUDE.md` claims "rate-limited", Swagger documents 429, nothing emits it; pool of 10 with unbounded waits |
| GV-06 | Medium | `/votes` stage 4 and `vote_tally` join DReps by `drep_raw`, not by the unique `drep_hash_id`; preprod has duplicated raw hashes (key+script), so a page can fan out and the tally's scalar subquery can raise |
| GV-07 | Medium | Activity cursor is not unique for an enacted treasury action with two beneficiaries (arm 11 uses `gov_action_id` as `item_index`); unreachable on preprod, so no check sees it |

Full list in §3; ranked backlog in §7.

## 2. What is done well

- **Injection surface is closed by construction.** Filters bind every value (`Query/Gov.hs:611-672`,
  `1310-1377`, `2052-2101`, `2789-2856`); sort columns come only from `*OrderBy -> SortSpec` total
  functions over closed enums (`Query/Common.hs:94-118`, `Transfer/OrderBy.hs:162-171`);
  LIMIT/OFFSET are bound after clamping (`Query/Common.hs:83-88`); LIKE patterns escape `\`, `%`, `_`
  in the right order (`WebAPI/Utils.hs:33-37`, pinned by `UnitTests/QueryHardening.hs:102-107`).
  The two interpolations that exist are a compile-time constant (`Gov.hs:876-887`) and an expression
  built from a closed column table (`Gov.hs:1264-1277`, `Query/Thresholds.hs:193-209`).
- **The read ceiling is real.** `SET LOCAL statement_timeout = 30000` inside the per-request
  `RepeatableRead` transaction (`Gov.hs:246-273`): a timed-out statement is cancelled by the server,
  so an abandoned client cannot leave a backend grinding.
- **The decode boundary names the field.** One `row_to_json` column per statement, decoded by the
  DTO's own `FromJSON` (`Gov.hs:22-26`, `275-289`), so a renamed view column fails loudly.
- **Placeholder-count tests** over every filter shape (`UnitTests/QueryHardening.hs:159-194`,
  `287-298`, `401-418`) turn postgresql-simple's run-time count mismatch into a unit-test failure.
- **CSV trust boundary.** `safeCell` on every text cell including tab/CR leads (`WebAPI/CSV.hs:52-55`,
  `Query/Csv.hs` throughout), enums via `jsonTag`, numbers unguarded on purpose.
- **Committee identity is the cold key** everywhere (`sql/010_gov_views.sql:497-530`), which is the
  single decision that keeps 3.24 M stress-test rows from becoming 648 k "members".
- **Keyset feed with a widening window** and a validated, inverse-tested cursor
  (`Gov.hs:2462-2476`, `2511-2512`, `UnitTests/QueryHardening.hs:224-310`).
- **Metric files are disciplined**: one leading `p` CTE, `?` count equals `params` (2/3/2/2/2/2),
  none in comments, no `now()`, `docs/metrics.md` byte-identical to the six files, regenerated and
  diffed in CI (`.github/workflows/ci.yml:124-128`), plus a determinism gate (`ci.yml:193-232`).
- **Reconciliation is honest**: `koios`/`palmares`, never `expected`/`actual`; exit 2 is transport
  only; R10 runs first; waivers need reason/opened/owner and a wildcard must name a field
  (`Palmares/Reconcile.hs:232-250`, `474-483`).
- `admin apply-indexes` detects INVALID indexes left by an interrupted `CONCURRENTLY` build
  (`Palmares/Admin/ApplySql.hs:177-205`) — a failure mode most teams never notice.

## 3. Findings

### GV-01 — High — Boot DDL drops and rebuilds the schema on every start; unsafe with more than one replica

**Location.** `sql/000_schema.sql:10`; `src/exe/query-api/Query/Views.hs:81-92`;
`src/exe/query-api/Main.hs:100-107`; `sql/030_metrics.sql:40-246`.

**What the code does.** Every `query-api` process, at boot, runs `DROP SCHEMA IF EXISTS palmares
CASCADE; CREATE SCHEMA palmares;` and then all view DDL plus `CREATE MATERIALIZED VIEW … WITH DATA`
in **one transaction** under `SET LOCAL lock_timeout = '10s'` (`Views.hs:83-84`), and `die`s on
failure (`Views.hs:91`).

**Why it is a problem.** `DROP SCHEMA … CASCADE` takes `AccessExclusiveLock` on every view and the
matview and holds them until commit. Scenario: two replicas, rolling restart. Replica B boots while
replica A serves traffic. B's `DROP` waits for A's in-flight reads; new readers on A queue behind
B's pending lock (the module comment documents a 20-minute stall of exactly this shape,
`Views.hs:70-74`). If a read on A exceeds 10 s, B dies and the supervisor restarts it — a crash loop
during which every boot attempt re-stalls A. If B wins the lock, A's readers block for the whole
transaction, which includes the matview build (3.1 s on preprod per `030_metrics.sql:21`; mainnet
has an order of magnitude more votes and DReps). Two replicas booting together serialise on the
same lock and the second rebuilds the schema the first just built. `UnitTests/Views.hs:24-30` pins
idempotence, not concurrency.

**Evidence.** `sql/000_schema.sql:10` `DROP SCHEMA IF EXISTS palmares CASCADE;`;
`Views.hs:76-80` "Ten seconds, then the statement fails, the transaction rolls back, and
`applyPalmaresSchema` dies".

**Recommended fix (M).**
1. Make the bootstrap conditional: store a hash of the embedded SQL set as `COMMENT ON SCHEMA
   palmares IS '<sha256>'`; at boot, if the comment matches, skip DDL entirely.
2. Serialise boots with `SELECT pg_advisory_xact_lock(<const>)` as the first statement.
3. Build into `palmares_next` and swap with two `ALTER SCHEMA … RENAME` statements (milliseconds of
   exclusive lock instead of the whole build), or at minimum create the matview `WITH NO DATA` and
   run the first `REFRESH` outside the DDL transaction before the listener starts.
4. Keep `000_schema.sql` as the "force rebuild" path behind an explicit flag.

### GV-02 — High — Koios nightly parity is broken by the `unknown` status; the replay fixture hides it

**Location.** `src/exe/admin/Reconcile.hs:325`; `src/exe/query-api/Query/Gov.hs:619-620`,
`1694-1698`, `1710-1713`; `test/fixtures/snapshot/palmares/dreps.json`;
`config/reconcile-exceptions.yaml:88-99`; `src/lib/offchain-lib/Palmares/Reconcile.hs:176-179`,
`274-277`; `docs/deployment/koios-parity-gate.md:101-103`.

**What the code does.** The live reconciler fetches our side with
`/dreps?status=active&status=inactive` (`admin/Reconcile.hs:325`). Since the owner decision of
2026-10-21, `drepStatusExpr` yields `unknown` for every registered DRep with no `drep_distr` row
(`Gov.hs:1696-1697`), and an explicit status list is honoured verbatim (`Gov.hs:1710-1713`), so
those 90 DReps are **absent** from the fetched page. R1 and R2 are keyed by DRep id; a key present on
Koios's side only is a `membership` divergence (`Reconcile.hs:178`). The R2 waivers are `key: "*"`
with `field: active_until_epoch` / `field: status` (`reconcile-exceptions.yaml:88-99`); `covers`
requires the field to match (`Reconcile.hs:274-277`), so `membership` is not waived.

**Evidence that the committed snapshot predates the change.** `dreps.json` holds 294 rows whose
statuses are only `inactive` (277) and `active` (17), with 90 rows having `active_until_epoch: null`
— exactly the population that now reads `unknown`. The replay test (`UnitTests/Reconcile.hs:821-833`)
asserts 0 unexplained divergences over this stale pair, so CI stays green. `koios-parity-gate.md:101`
claims "All 90 now report `unknown` while Koios still reports its own computed answer, so more keys
diverge — 90 rather than 21", which can only have been observed with a fetch that *includes*
`unknown`; the shipped code does not.

**Expected effect.** The next live run reports ~90 unexplained R1 and ~90 unexplained R2 divergences
and exits 1; because the workflow is `continue-on-error: true` (`reconcile.yml:25`) nothing turns
red. **VERIFY** by running `admin reconcile-koios` against the live API.

**Recommended fix (S).** Fetch `/dreps` with no status parameter (the default set now includes
`unknown`, `Gov.hs:1712`) or add `&status=unknown`; re-record the pair with `--dump-snapshots
test/fixtures/snapshot`; add a replay assertion that every value `drepStatusExpr` can produce for a
registered DRep appears in `dreps.json`, so the next vocabulary change fails the gate instead of
hiding behind it.

### GV-03 — High — The served metric numbers are not produced by the published SQL

**Location.** `sql/030_metrics.sql:28-32`; `src/exe/query-api/Query/Gov.hs:778-833` and `879-895`;
`README.md:21-23`; `src/exe/query-api/RestAPI.hs:237-243`; `docs/metrics.md:10-12`;
`src/lib/offchain-lib/Palmares/Metrics/Catalog.hs:10-13`; `sql/checks/070_drep_metrics.sql:89-95`.

**What the code does.** `drepMetricsQuery` reads `participation_rate`, the five rationale grades,
latency and `age_days` from `palmares.drep_metrics` (`Gov.hs:782`, `807-812`), i.e. from the matview,
which its own header calls "a second implementation of the same arithmetic"
(`030_metrics.sql:30`). Only `delegator_retention_rate_v1.sql` is executed as embedded bytes
(`Gov.hs:881-891`). The `votes_by_type` block is a third copy (`Gov.hs:793-806`) of
`votes_by_type_v1.sql`.

**Why it is a problem.** `/metrics/formulas` promises "the exact SQL statement the server executes,
inlined" (`RestAPI.hs:241-243`), README §1 promises "the exact SQL that computes it", and
`docs/metrics.md:11` / `Catalog.hs:11` say "`Query.Metrics` looks each statement up by `formula_id`
and runs it" — there is no `Query.Metrics` module (`palmares.cabal:364` is commented out). The only
guard that the two implementations agree is `070_drep_metrics.sql:96-170`, which runs manually
(`scripts/verify_views.sh`), against preprod only, for one DRep, and skips `age_days` equality.
A drift in the matview (e.g. a window partition change, see `030_metrics.sql:22-26`) would change
every served number while the published formula, the doc gate and CI all stay green.

**Recommended fix (M).** Pick one source of truth. Cheapest honest option: generate the matview body
from the catalog files at build time (the `p` CTE shape makes each file a `LATERAL`-able block), or
register the matview itself as the `sql_object` for the five metrics and publish its DDL. Until then:
(a) run the 070 agreement over *all* DReps (`EXCEPT`-style set comparison) and add it to the CI
determinism job over a seeded corpus; (b) rewrite the three prose claims to say "the formula the
matview implements; agreement asserted by check 070".

### GV-04 — High — The public read service runs as the database superuser in the documented deployment

**Location.** `compose.yaml:263-267`; `src/exe/query-api/Main.hs:31-32`, `87`, `100`;
`README.md:146`; `src/exe/admin/Main.hs:861-868`; `sql/050_roles.sql:1-18`.

**What the code does.** `compose.yaml:267` gives query-api `PG_CONN_STR: "host=postgres
user=postgres …"` — the cluster superuser that owns db-sync's tables. `Main.hs:87` falls back to
`defaultConnStr` (`user=postgres password=postgres`) when `PG_CONN_STR` is unset, although
README §11 lists it as required. `PALMARES_PG_OWNER_CONN_STR` defaults to the same DSN
(`Main.hs:100`). The two-role model (`050_roles.sql`) is applied only by `admin apply-roles` via
`PALMARES_ADMIN_CONN_STR`, which no manifest in this repository sets; the Kubernetes Jobs the SQL
comments refer to live elsewhere.

**Why it is a problem.** A single SQL-level mistake in a public, unauthenticated, un-rate-limited
service (GV-05) is then a superuser mistake on db-sync's database; `000_schema.sql`'s `CASCADE` is
executed with rights to drop anything. The compose path is the one README §10 tells contributors
and self-hosters to run.

**Recommended fix (M).** In `compose.yaml`, add a one-shot `admin apply-roles` service and point
query-api at `palmares_ro` / `palmares_owner`; make `PG_CONN_STR` fail-closed (`die` when unset, as
`BASIC_USER` does); on the read pool execute `SET default_transaction_read_only = on` in
`runGovRead` as belt-and-braces; document `PALMARES_PG_OWNER_CONN_STR`, `PALMARES_ADMIN_CONN_STR`,
`PALMARES_NETWORK_NAME`, `PALMARES_FRESHNESS_POLL_MS` in README §11.

### GV-05 — Medium — No rate limiting or concurrency cap, contrary to the docs

**Location.** `src/exe/query-api/QueryAppMonad.hs:14-15`; `src/exe/CLAUDE.md:76-77`;
`src/lib/webapi-lib/Palmares/WebAPI/Envelope.hs:113-116`, `139-140`; `src/exe/query-api/RestAPI.hs:7-10`,
`1774`; `src/exe/query-api/Main.hs:88`.

**What the code does.** Nothing in the process limits request rate or in-flight work.
`RateLimited` exists as an error code that "is unreachable" (`Envelope.hs:113-116`); Swagger tells
clients "429 a rate limit" (`RestAPI.hs:1774`); `src/exe/CLAUDE.md:77` says the surface is
"rate-limited". The read pool holds 10 connections (`Main.hs:88`) and resource-pool waits without
timeout.

**Why it is a problem.** Ten concurrent `/votes?voter_role=constitutional_committee` (1.7 s best
case, 30 s worst), `/activity` last-rung pages (4.6 s) or `/gov-actions?limit=200` (GV-10) occupy the
pool; every other request, including the freshness poller (`Gov.hs:508`), queues. `/ready` keeps
answering from the cache, so the load balancer keeps routing to a stalled instance.

**Recommended fix (M).** Either state the dependency explicitly (which BFF, what limits) and remove
the "rate-limited" claim, or add an in-process guard: a bounded semaphore around `runRead` that
answers `503 db_unavailable` (or `429 rate_limited`) immediately when saturated, a per-client token
bucket middleware keyed on `X-Forwarded-For`, and `setTimeout`/`setMaxTotalHeaderLength` on Warp.

### GV-06 — Medium — DRep joins by `drep_raw` instead of `drep_hash_id` can fan out

**Location.** `src/exe/query-api/Query/Gov.hs:1299-1307` (stage 4 `voteFrom`), `1452-1456`,
`2770-2774` (stage 2 joins by id); `sql/020_views.sql:143-148`;
`src/lib/offchain-lib/Palmares/DomainTypes/Core/Types.hs:325-333`; `Gov.hs:721-727`.

**What the code does.** Stage 4 of `/votes` joins `palmares.drep d ON d.drep_raw = v.voter_id_hash`
and `drep_epoch_power p ON p.drep_raw = v.voter_id_hash AND p.epoch_no = …` (`Gov.hs:1304-1307`),
while stage 2 joins power by `p.drep_hash_id = v.drep_voter` (`Gov.hs:2772-2774`). `vote_tally`
weighs a DRep vote with a scalar subquery `SELECT p.amount … WHERE p.drep_raw = f.voter_hot_hash`
(`020_views.sql:144-148`).

**Why it is a problem.** The codebase itself documents that on preprod two raw hashes exist twice in
`drep_hash`, once as key and once as script (`Types.hs:327-331`). `palmares.drep` has one row per
`drep_hash` row, so the stage-4 join returns two rows for each vote of such a DRep — the page carries
duplicates and exceeds `limit`, while `total` (stage 1) does not. If both rows ever carry a
`drep_distr` row for the same epoch, the tally's scalar subquery errors ("more than one row returned
by a subquery used as an expression") and the whole `vote_tally` view fails for that action.
**VERIFY** on preprod whether the phantom credential of either pair has `drep_distr` rows.

**Recommended fix (S).** `LEFT JOIN palmares.drep d ON d.drep_hash_id = v.drep_voter_id` and
`LEFT JOIN palmares.drep_epoch_power p ON p.drep_hash_id = v.drep_voter_id AND p.epoch_no =
w.last_votable_epoch` in `voteFrom`; in `vote_tally`, carry `v.drep_voter_id` into `final_votes` and
join power by it (and replace the scalar subquery with a `LEFT JOIN` so a fan-out would show up as a
count mismatch in check 040 rather than an error).

### GV-07 — Medium — The activity cursor is not total for multi-beneficiary treasury enactments

**Location.** `sql/020_views.sql:698-717`; `sql/checks/060_activity.sql:6-11`;
`src/test/UnitTests/Activity.hs:139-140`.

**What the code does.** Arm 11 emits one `treasury_withdrawal_enacted` row per
`palmares.treasury_withdrawal` row (one per beneficiary) with `item_index = t.gov_action_id`
(`020_views.sql:705`), so two beneficiaries of one enacted action share
`(first_slot, -2, 11, gov_action_id)`.

**Why it is a problem.** The cursor "MUST be unique over the whole feed" (`020_views.sql:390-393`);
a duplicate makes a client skip or repeat rows. Preprod has 83 withdrawals across 82 actions and
none enacted, so check 060 and the seeded unit test (one withdrawal) cannot see it; mainnet enacts
multi-beneficiary withdrawals routinely.

**Recommended fix (S).** Publish `tw.id AS withdrawal_id` from `palmares.treasury_withdrawal` and
use it as arm 11's `item_index`; seed two beneficiaries for one enacted action in
`UnitTests/Activity.hs` so the uniqueness test covers it.

### GV-08 — Medium — `gov_action_ratified` is placed one epoch too early in the feed

**Location.** `sql/020_views.sql:593-612`; `sql/010_gov_views.sql:316-320`.

**What the code does.** The ratification event's `sort_slot`/`block_time` are the first block of
`ratified_epoch`. The repo's own measurement says the last votes on 3 of 9 ratified actions landed
*in* `ratified_epoch` (`010_gov_views.sql:318-320`), i.e. db-sync's `ratified_epoch` is the epoch
whose votes were counted at its closing boundary.

**Why it is a problem.** The feed shows "ratified" before the votes that ratified it, and before
`gov_action_enacted` only because enactment is placed at `enacted_epoch = ratified_epoch + 1`.
A reader scrolling an action's timeline sees an outcome preceding its cause.
**VERIFY** db-sync's assignment of `ratified_epoch` (`Cardano.DbSync.Era.Universal.Epoch`,
`GovActionsAtEpochBoundary`) and the ledger's `RATIFY`→`ENACT` boundary; if ratification is
decided at the boundary into `ratified_epoch + 1`, place the event there.

**Recommended fix (S).** `WHERE b.epoch_no = g.ratified_epoch + 1` in arm 7 (with
`epoch_no = g.ratified_epoch + 1` published), or publish the event at the last block of
`ratified_epoch` and document the convention.

### GV-09 — Medium — Two dashboard numbers break the "every number carries a formula id" contract

**Location.** `src/exe/query-api/Query/Gov.hs:1944-1969`; `src/exe/query-api/RestAPI.hs:1340-1348`,
`1294-1296`, `1816-1819`, `1063-1066`.

**What the code does.** (a) `participation_by_epoch[].participation_rate` = distinct DRep voters in
the epoch ÷ DReps with power in the epoch (`Gov.hs:1950-1951`), with no formula id, while
`SPOSummary.participation_rate` is deliberately `null` because "a rate with no resolvable formula
would break that contract" (`RestAPI.hs:1063-1066`). The numerator counts voters without power, so
the rate can exceed 1.0. (b) `total_dreps = active + inactive` (`RestAPI.hs:1345`) excludes
`unknown`, while the Swagger text says it is "the universe /dreps lists by default"
(`RestAPI.hs:1294-1296`) and the default `/dreps` population now includes `unknown`
(`Gov.hs:1712`; `scripts/smoke_query_api.sh:117` asserts 294). The dashboard also publishes no
`unknown_dreps` count.

**Recommended fix (S).** Add `epoch_participation_rate_v1` to `resources/metric-formulas.json`
(`sql_object` or a statement) and echo its id in `EpochParticipationPoint`, or null the rate and
publish only the two counts; make `total_dreps` the sum of the three registered statuses and add
`unknown_dreps`.

### GV-10 — Medium — `/gov-actions` pages pay a per-row correlated vote count that can exceed the ceiling

**Location.** `sql/020_views.sql:274-296`; `src/exe/query-api/Query/Gov.hs:1121-1135`, `1037`,
`1877-1882`; `src/exe/query-api/Query/Common.hs:46-52`.

**What the code does.** `gov_action.votes_cast` is `SELECT count(*) FROM (SELECT DISTINCT … FROM
public.voting_procedure v LEFT JOIN palmares.cc_cold_interval … WHERE v.gov_action_proposal_id = …)`
per row. `govActionProjection` selects it on every list page, `order_by=votes_cast` sorts by it, and
the JSON ceiling is 200 rows (CSV 10 000). The dashboard comment measured "selecting it for all 131
actions costs 41.7 s" (`Gov.hs:1878-1880`) — above the 30 s `statement_timeout`.

**Why it is a problem.** `GET /gov-actions?limit=200`, the CSV export and `?order_by=votes_cast`
would answer `503 db_unavailable`; on mainnet (hundreds of actions, no stress-test concentration)
the cost profile differs but the shape is O(rows × votes). `scripts/smoke_query_api.sh:272` asserts
`limit=200` returns 131 items, so either the 41.7 s predates the committee indexes or the smoke
only passes warm. **VERIFY** with `EXPLAIN ANALYZE` on preprod.

**Recommended fix (M).** Replace the correlated count with one pre-aggregated relation
(`palmares.gov_action_voters AS SELECT gov_action_proposal_id, count(DISTINCT …) … GROUP BY 1`)
joined once per page, or move `votes_cast` into a small matview refreshed with `drep_metrics`.

### GV-11 — Medium — "Latest certificate" ordering omits the transaction index

**Location.** `sql/010_gov_views.sql:171`, `206`, `215` versus `716`.

**What the code does.** `drep_interval`'s window and `drep`'s `latest_cert`/`latest_anchor` order by
`(slot_no, cert_index)` only, although `drep_cert` already carries `tx_index` (`010:134`).
`live_delegation` orders by `(slot_no, tx.block_index, cert_index)` (`010:716`).

**Why it is a problem.** Two transactions in one block each carrying a certificate for the same DRep
(register in tx 0 cert 1, retire in tx 1 cert 0) are ordered by `cert_index`, inverting the status
and producing an interval that closes before it opens — exactly the "register, retire, re-register
inside one epoch" shape the age metric guards against (`resources/metrics/age_days_v1.sql:8-11`).

**Recommended fix (S).** Add `tx_index` between `slot_no` and `cert_index` in all three orderings;
`sql/checks/010_drep.sql:50-51` already asserts no inverted interval and would catch the regression.

### GV-12 — Medium — `last_votable_epoch` is one epoch permissive, shifting "settled" and "in flight"

**Location.** `sql/010_gov_views.sql:324-325`, `344-349`; `sql/020_views.sql:35`;
`src/exe/query-api/Query/Gov.hs:1903-1905`; `sql/checks/020_eligibility.sql:36-40`;
`sql/checks/030_votes.sql:92-94`.

**What the code does.** `last_votable_epoch = LEAST(expiration, ratified, expired, dropped - 1)`.
The repo measured `expired_epoch = expiration` in 103/103 cases, `expiration = proposed + lifetime + 1`,
and "no vote was ever observed later than `expired_epoch - 1`" (`010:324-325`), then kept
`expiration` as the bound as "permissive but never wrong".

**Why it is a problem.** It is wrong for the *denominator*: `eligible_actions` treats an action as
settled only when `last_votable_epoch < as_of_epoch` (`020:35`), so an action that left the proposal
set entering epoch E is excluded from every participation denominator computed as of E and is
counted in `actions_in_flight` (`Gov.hs:1903-1905`) and `open_actions_unvoted` for one extra epoch.
The ledger rule quoted in the view header is `currentEpoch <= gasExpiresAfter`
(`010:311-313`); if db-sync's `expiration` is `gasExpiresAfter + 1` the correct bound is
`expiration - 1`. **VERIFY** in `cardano-db-sync` `insertGovActionProposal` (how `expiration` is
derived from `gasExpiresAfter`) and in `Conway/Rules/Gov.hs` `checkVotesAreNotForExpiredActions`.

**Recommended fix (S).** If confirmed, use `g.expiration - 1` in both `last_votable_epoch` and the
`drep_votable` window; update the pinned counts in `sql/checks/020_eligibility.sql` and the fixture.

### GV-13 — Medium — `is_valid IS NULL` is published as `invalid_schema` and blocks content

**Location.** `sql/010_gov_views.sql:11-13`, `44-52`; `src/exe/query-api/Query/Gov.hs:1009`,
`1259`; `src/test/UnitTests/Anchor.hs:34-37`.

**What the code does.** A fetched, hash-matched anchor whose `off_chain_vote_data.is_valid` is NULL
("the check was inconclusive", `010:12-13`) gets `verdict = 'invalid_schema'` (`010:47`).
`anchorContentQuery`/`govActionAnchorQuery` publish CIP-119/CIP-108 content only for
`verdict = 'valid'`.

**Why it is a problem.** The registry accuses the author of an invalid schema where db-sync said
"not checked", and withholds a document whose on-chain hash *did* match. This is the same false
accusation the `inline`/`pending` grades exist to avoid. **VERIFY** in db-sync which anchor
types/versions leave `is_valid` NULL (the schema says it is set only by the CIP-100/108/119
validator; `anchortype` has six values, `dbsync-skeleton.sql:17`).

**Recommended fix (S).** Add a verdict `hash_verified` (fetched, hash ok, schema not assessed) or
treat `d.id IS NOT NULL AND d.is_valid IS NULL` as `valid` for content publication while keeping
`cip100_valid` nullable; update `UnitTests/Anchor.hs` and the `AnchorStatus` enum.

### GV-14 — Medium — SPO threshold on ParameterChange is reported even when SPOs do not vote on it

**Location.** `sql/010_gov_views.sql:480`; `sql/020_views.sql:186-199`;
`src/exe/query-api/RestAPI.hs:691-700`; `src/exe/query-api/Query/Thresholds.hs:16-19`, `179-181`.

**What the code does.** `threshold_map` maps `(ParameterChange, SPO)` to `pvtpp_security_group`
unconditionally, so every SPO tally on a ParameterChange carries that threshold. The ledger applies
it only when the update touches the security group (`Thresholds.hs:157-161`), which
`action_window.spo_votable` already computes (`010:370-387`). `fillParamChangeThreshold` has the
touched columns in hand but only fills the DRep arm; `spoParamChangeApplies` is used by tests only.

**Why it is a problem.** A tally with `threshold = 0.51, threshold_param = pvtpp_security_group`
for a non-security ParameterChange invites a client to compare against a bar the ledger never set.
Two related gaps are documented but not surfaced per tally: the `_no_confidence` committee variants
(`Thresholds.hs:16-19`) and the bootstrap-phase (PV 9) rules under which DRep thresholds did not
apply to historical actions. **VERIFY** against `votingStakePoolThreshold` /
`votingDRepThreshold` in `Cardano.Ledger.Conway.Rules.Ratify` for the bootstrap and no-confidence
cases.

**Recommended fix (S).** In `fillParamChangeThreshold`: when `voteTallyRole t == SPO` and
`not (spoParamChangeApplies touched)`, set `voteTallyThreshold = Nothing, voteTallyThresholdParam =
Nothing`; add a `threshold_applies` boolean (false for bootstrap-era DRep tallies and for CC rows).

### GV-15 — Medium — Matview staleness is per-replica and leaks into 404s

**Location.** `src/exe/query-api/Query/Refresh.hs:136-145`; `src/exe/query-api/Main.hs:107`;
`sql/030_metrics.sql:9-10`; `src/exe/query-api/Query/Gov.hs:599-603`, `760-768`.

**What the code does.** Every replica runs its own refresh loop ("one refresh thread" is true per
process). `drepFrom` INNER-joins `palmares.drep_metrics` (`Gov.hs:602`), and `drepSummaryByIdQuery`
reuses it, so a DRep registered after the last refresh is absent from `/dreps` and answers
`404 drep_not_found` on `/drep/{id}` for up to `PALMARES_VIEW_REFRESH_SECONDS` plus the refresh
duration, while `/drep/{id}/updates` (reads `drep_cert`) finds it.

**Recommended fix (S/M).** `LEFT JOIN palmares.drep_metrics` with `COALESCE`d counters (the matview
already zero-fills), take `pg_try_advisory_lock` in `step` so only one replica refreshes, and expose
the matview's `as_of_epoch` and last-refresh time in `/status` (GV-24).

### GV-16 — Medium — `/drep/{id}/delegators?is_current=false` is not the history the docs promise

**Location.** `src/exe/query-api/Query/Gov.hs:924-927`, `931-941`; `src/exe/query-api/RestAPI.hs:406-412`.

**What the code does.** `delegatorFrom` takes `DISTINCT ON (addr_id) … ORDER BY addr_id, slot_no
DESC` over all `vote_delegation` rows, then filters `dv.drep_hash_id = ?`. An address whose latest
certificate names another DRep never appears. `is_current=false` only widens to addresses whose
latest certificate still names this DRep but whose stake account was later deregistered.

**Why it is a problem.** The route description says `is_current` "is false for a delegation since
superseded or whose stake account closed; `is_current=false` includes those, which is what makes the
list a history rather than a snapshot" (`RestAPI.hs:409-412`). Superseded delegations are never
returned.

**Recommended fix (S).** For `is_current=false`, select from `palmares.vote_delegation` restricted to
this DRep and compute `is_current` per row as "latest certificate for the address AND no later
deregistration"; or correct the description to "closed accounts only".

### GV-17 — Medium — The out-of-band indexes are load-bearing and nothing verifies they exist

**Location.** `sql/indexes/001_gov_indexes.sql:4-18`, `27-35`;
`src/lib/offchain-lib/Palmares/Admin/ApplySql.hs:152-205`; `sql/checks/030_votes.sql:4-8`.

**What the code does.** The 23 indexes on db-sync's tables are applied only by `admin apply-indexes`
(a Job outside this repo). Without `gov_idx_committee_reg_hot` "the CC half of `palmares.vote` simply
never finishes" (`001_gov_indexes.sql:30-32`). A db-sync re-sync from genesis (the documented
remedy in ADR 0001) recreates `public` and loses them; `query-api` boots fine and every committee
query becomes a 30 s `503 db_unavailable`.

**Recommended fix (S).** At boot and in `/status`, compare `declaredIndexes` against
`pg_indexes`/`pg_index.indisvalid` and publish `missing_indexes` (warn, do not die); add the re-sync
runbook step "re-run `admin apply-indexes`".

### GV-18 — Low — Committee `status = resigned` is forever

**Location.** `sql/020_views.sql:340-344`; `src/exe/query-api/Query/Gov.hs:2211`, `2233-2236`.

A cold credential with any `committee_de_registration` row reads `resigned` even in a later
committee that re-elected it (the status is also duplicated in `getCommittee`, a second definition
the comment itself warns about, `Gov.hs:2168-2170`). **VERIFY** that `UpdateCommittee` may re-add a
previously resigned cold credential (ledger `Conway.Governance` `updateCommittee`); if so compare the
latest de-registration against the current committee's establishment (`committee.gov_action_proposal_id`
→ enactment epoch). Effort S.

### GV-19 — Low — `paid_heuristic` epoch match is unverified against db-sync's reward timing

**Location.** `sql/020_views.sql:380-386`; `test/fixtures/dbsync-skeleton.sql:392-402`.

The heuristic matches `reward_rest.type = 'treasury' AND spendable_epoch = enacted_epoch`. db-sync
defines `earned_epoch = spendable_epoch - 1` for `reward_rest` (`skeleton:397-401`), so a payout
earned at the enactment boundary may be recorded with `spendable_epoch = enacted_epoch + 1`. No
preprod row can validate this (zero enacted withdrawals, `RestAPI.hs:1115-1116`). **VERIFY** in
`Cardano.DbSync.Era.Universal.Insert.Epoch` how treasury withdrawals populate `reward_rest`; seed a
unit-test row either way. Effort S.

### GV-20 — Low — `open_actions_unvoted` is computed for retired and never-registered credentials

**Location.** `sql/030_metrics.sql:185-196`; `resources/metrics/participation_rate_v1.sql:29-38`.

Neither implementation gates the open set on a current registration interval, so
`/dreps?status=retired` shows retired DReps with "13 open actions unvoted" — actions they cannot vote
on. Fix (both copies, GV-03): join `drep_interval` with `to_epoch IS NULL` or `>= as_of_epoch`.
Effort S.

### GV-21 — Low — Dashboard "closing soon" and "in flight" use different clocks

**Location.** `src/exe/query-api/RestAPI.hs:1330-1338`; `src/exe/query-api/Query/Gov.hs:1903-1905`.

`closing_soon` filters `state = proposed AND expiration < epoch + 6`; `actions_in_flight` is
`last_votable_epoch >= epoch`. The repo's own example (`RestAPI.hs:1300-1302`, 12 vs 11) shows the
two populations differ. Add an `ExpiresBeforeEpoch`-style filter on `last_votable_epoch` and use it
here. Effort S.

### GV-22 — Low — Stale docs, dead code and unreachable claims

- `src/exe/query-api/Query/{Projected,Pages,Aggregates}.hs` are on disk but commented out of the
  build (`palmares.cabal:357-367`); `Aggregates.hs:20` imports `runWithQueryErrorHandling`, which
  `QueryAppMonad.hs` no longer defines, so they would not compile. `CLAUDE.md:56-59` still routes
  new work to `query-api/Metrics/Catalog.hs` (lives in `offchain-lib`), `Query/Aggregates.hs`,
  `Query/Pages.hs` and `Query/Projected.hs` (attestation reads are in `Query/Attest.hs`).
  Delete the three files or move them under `experiments/`.
- `src/exe/CLAUDE.md:42-43` "one PostgreSQL ConnectionPool … There is no second pool" vs
  `Main.hs:96-104` (two pools); `src/exe/CLAUDE.md:55`, `docs/metrics.md:11`,
  `Palmares/Metrics/Catalog.hs:11` name a `Query.Metrics` module that does not exist.
- `docs/adr/0001-governance-data-substrate.md:12` says "fourteen read-only views"; the same ADR
  (`:60`, `:107`) and `scripts/smoke_views.sh:43` say nineteen; `sql/` defines 19 views, 1
  function, 1 matview.
- All eight `spec` links in `resources/metric-formulas.json` (`:28`, `:58`, …) and the sample
  redraw procedure (`config/reconcile-sample.preprod.json:23`) point at `docs/superpowers/…`, which
  is not in the repository (17 references).
- "through a trigram index" (`Transfer/Filters.hs:136`, `Query/Common.hs:130`): no `pg_trgm` index
  exists anywhere; `lower(given_name) LIKE '%x%'` is a sequential scan (harmless at 800 rows).
- README §11 omits `PALMARES_PG_OWNER_CONN_STR`, `PALMARES_ADMIN_CONN_STR`, `PALMARES_NETWORK_NAME`,
  `PALMARES_FRESHNESS_POLL_MS`; `PG_CONN_STR` is listed as required but defaults (`Main.hs:87`).
- `/votes?voter_id=<malformed>` answers `invalid_drep_id` ("Not a DRep identifier") for pool and
  committee ids (`RestAPI.hs:774`).
Effort S.

### GV-23 — Low — `/status` under-reports what an operator needs

**Location.** `src/exe/query-api/Query/ServiceStatus.hs:58-78`; `src/exe/query-api/Query/Gov.hs:487-492`,
`539-549`; `src/exe/query-api/QueryAppMonad.hs:47`.

`/ready` encodes five conditions but `/status` publishes only lag, epoch, slot and `is_ready`:
not `drep_distr_epoch` (the "ledger enabled" signal), not the amber band (`amberLag` is parsed and
stored, never read), not the matview's `as_of_epoch`/last refresh, not the attestation projector lag
(`Gov.hs:487-492` calls this "a known half"), not missing indexes (GV-17). The `X-Data-Lag-Seconds`
header is a 5 s cache (`Gov.hs:372-374`), fine, but undocumented in Swagger. Add these as nullable
fields (minor Swagger bump). Effort S.

### GV-24 — Low — The nightly can rot silently

**Location.** `config/reconcile-sample.preprod.json:23`, `:26`; `.github/workflows/reconcile.yml:25`;
`src/lib/offchain-lib/Palmares/Reconcile.hs:595-597`; `src/exe/admin/Reconcile.hs:386-394`.

The sample is pinned at epoch 320 and only grows by a manual redraw whose procedure lives in a
missing document; new DReps and actions never enter R6/R7/R9. The workflow is `continue-on-error`,
so exit 1/2/3 never turns anything red; a Koios field rename exits 2 every night with a green badge.
The R10 abort divergence is always labelled `epoch_skew` even when the cause was lag
(`Reconcile.hs:596`). Add a `sample_age_epochs` field to the report with a warning threshold, open
a GitHub issue (or Slack post) on exit ≠ 0, and label the lag abort as `lag_seconds`. Effort S.

### GV-25 — Low — Test coverage gaps on the SQL

- `sql/checks/*.sql` run only by hand (`scripts/verify_views.sh`); none is in CI. The CI
  determinism job applies the schema to the empty skeleton, which proves parse/shape only
  (`ci.yml:186-189`).
- No check covers `palmares.thresholds` values, `search`, `drep_epoch_delegators` beyond one
  tip-agreement row (`040_power.sql:81-85`), the CSV route, or `drep_metrics` for more than one DRep.
- `UnitTests/MetricFixture.hs` is skipped without `PALMARES_FIXTURE_PG_CONN_STR` (`:241-248`),
  so the epoch-319 magnitude pins never run in CI.
- The epoch-pinning rule (`src/test/CLAUDE.md:49-50`) is respected in 020/030/050/060
  (`proposed_epoch < 320`, `vote_epoch < 320`), but `030_votes.sql:67-69` and `:57-62` scan the
  whole corpus (invariants, acceptable) and `070` cannot pin at all by design.
Effort M (a seeded "mini-preprod" corpus for CI would pay for most of this).

## 4. Views: what each computes, and the doubtful rules

| View / object | Computes | Doubtful rule → finding |
|---|---|---|
| `anchor` (`010:38-79`) | one verdict per voting anchor; newest fetch error wins | NULL `is_valid` → `invalid_schema` (GV-13) |
| `sync_state` (`010:95-111`) | tip by `block.id DESC`, `lag_seconds` via `now() AT TIME ZONE 'UTC'`, `drep_distr_epoch`, network | — |
| `drep_cert`, `drep_interval` (`010:120-180`) | certificate log; registration intervals closed by the next retire | ordering omits `tx_index` (GV-11) |
| `drep` (`010:200-305`) | registration status from the latest cert; `is_active = active_until >= tip epoch`, NULL deadline → false; API maps to `unknown` first | status is as of the last `drep_distr` row: a DRep that voted this epoch stays `inactive` until the next distribution; the ledger's dormant-epoch accounting is (correctly) not re-derived |
| `action_window` (`010:335-393`) | `last_votable_epoch = LEAST(expiration, ratified, expired, dropped-1)`; `drep_votable` = InfoAction or any non-PV9 epoch in the window; `spo_votable` via the 11 security-group columns | one-epoch permissiveness (GV-12); bootstrap test over the whole window is coarse (an action proposed at PV9 is "DRep-votable" even for the epochs before the fork) — **VERIFY** `checkBootstrapVotes` / `DisallowedVotesDuringBootstrap` in `Conway/Rules/Gov.hs` for which (voter, action) pairs are rejected at PV9 |
| `thresholds`, `threshold_map` (`010:402-484`) | per-epoch governance params; static (type, role) → column | `_normal` only; no bootstrap variant; SPO ParameterChange unconditional (GV-14). The DRep/SPO/CC mapping otherwise matches CIP-1694 (`votingDRepThreshold`/`votingStakePoolThreshold`): InfoAction never ratifiable, SPO silent on constitution/treasury, CC quorum-based |
| `cc_cold_interval`, `vote` (`010:520-620`) | hot→cold interval join; `seq_first/seq_last/vote_rows` partitioned by `(role, cold-or-own hash, action)` | — (D-24/D-27 are sound) |
| `drep_epoch_power` (`010:637-651`) | unfiltered `drep_distr` with `target_kind` | — |
| `vote_delegation`, `live_delegation` (`010:658-725`) | certificate log; latest cert per address not followed by a deregistration certificate | — (the cert-vs-epoch fix is correct) |
| `eligible_actions()` (`020:24-38`) | settled, DRep-votable actions overlapping a registration interval | inherits GV-12 |
| `drep_epoch_delegators` (`020:52-101`) | interval × epoch series | O(addresses × epochs) at read time; fine on preprod, **VERIFY** mainnet (`/drep/{id}/power` LEFT JOINs it, `Gov.hs:852-853`) |
| `vote_tally` (`020:126-209`) | final votes weighted by `drep_distr`/`pool_stat` at `last_votable_epoch`; `yes/(yes+no)`; CC power 0 | power epoch choice: **VERIFY** which `drep_distr.epoch_no` the ledger's `RatifyEnv` uses at the boundary closing `last_votable_epoch` (both sides of the Koios check read the same table, so a shared off-by-one would not be caught); join by raw hash (GV-06) |
| `gov_action` (`020:231-303`) | lifecycle `state` chain, `votes_cast` as distinct voters by cold key, `withdrawal_total` | per-row correlated count (GV-10) |
| `committee_member` (`020:318-362`) | members of every committee; `is_enacted` from the latest `epoch_state` | `resigned` forever (GV-18) |
| `treasury_withdrawal` (`020:372-386`) | beneficiaries; `paid_heuristic` | epoch match (GV-19) |
| `activity` (`020:438-717`) | eleven arms, four-part cursor | arm 11 collision (GV-07); ratified placement (GV-08) |
| `drep_metrics` (`030:40-246`) | batched re-implementation of the six formulas at the tip | second implementation (GV-03); ungated open set (GV-20) |

## 5. Reviewed and not an issue

- **Injection/hardening** (hypothesis 1): confirmed safe — see §2. `delegatorStatsQuery` strips the
  trailing semicolon and binds three parameters in catalog order (`Gov.hs:884-894`); the facet
  statement is parameter-count-tested (`QueryHardening.hs:177-194`).
- **Timeout semantics**: server-side `SET LOCAL statement_timeout` (`Gov.hs:254-255`); a client
  disconnect cannot leave an unbounded backend. The `/activity` ladder's four statements share the
  one transaction and `max_parallel_workers_per_gather = 0` (`Gov.hs:2641`).
- **Pagination**: clamp to `[1, max]`, offset ≥ 0, hard ceiling 10 000 rejected with `offset_too_large`
  (`Common.hs:74-88`); CSV ceiling 10 000 rows materialised in memory — a few MB, acceptable.
- **CSV**: every `Text` cell in every `ToNamedRecord` goes through `safeCell`; `jsonTag` enums and
  numbers are closed sets; `-` and `@` are guarded; the content type carries `charset=utf-8`.
- **`REFRESH … CONCURRENTLY`**: unique index `palmares_idx_drep_metrics_pk` (`030:250`), asserted by
  `UnitTests/Refresh.hs:47-53` and `070:81-82`; the refresh runs via `runSqlPoolNoTransaction`
  (`Refresh.hs:88-94`); readers see the previous rows during a refresh; the tick is cheap.
- **Metric files** (hypothesis 3): one leading CTE, `?` only as placeholders (counts 2/3/2/2/2/2),
  no `now()`, no `ORDER BY`-dependent output except inside `percentile_cont` and `DISTINCT ON`
  (deterministic), `docs/metrics.md` matches the six files verbatim. NULL-vs-zero semantics are
  consistent between the files, the matview and check 070 (`:47-56`). `delegator_retention_rate_v1`'s
  `UNION` (not `UNION ALL`) handles the zero-window case correctly.
- **No composite scores**: nothing in the API combines metrics; `SPOSummary.participation_rate` is
  nulled rather than invented.
- **Grants/roles**: `040_grants.sql` is guarded on the role existing and placed last
  (`Views.hs:43-47`); `050_roles.sql` refuses to run as the wrong owner (`:33-44`), revokes `CREATE
  ON public`, uses default privileges for future db-sync tables; passwords travel as bound
  `set_config` values (`ApplySql.hs:218-244`).
- **`?` in the boot DDL**: `rawExecute … []` would break on a `?` in a comment; none exists in
  `sql/*.sql` (checked), and `UnitTests/Views.hs` applies the files through the same path in CI.
- **Swagger spellings** (hypothesis 8): `DRepStatus` includes `unknown`, `GovActionType` is
  snake_case, `VoterRole` is `drep/spo/constitutional_committee`, `AnchorStatus` has seven values —
  all match the parsers (generated `query-swagger-api.json`, `definitions`); CIP-129, CIP-105 and
  hex are accepted on input and CIP-129 is echoed (`Core/Types.hs:357-366`, `UnitTests/GovDto.hs:156-176`).
- **Koios mapping**: `koiosDRepStatus` is deliberately not widened to `unknown` (`Koios.hs:426-431`)
  — right, the gap is the fetch (GV-02), not the mapping.
- **`/search`**: ids matched by equality after checksum decode, never by prefix; every arm gated by a
  bound boolean; LIKE escaped (`Gov.hs:1554-1674`).
- **Freshness headers**: added by middleware inside CORS so they are exposed (`RestAPI.hs:1868-1876`);
  ISO-8601 block time.
- **Voter filter on `/votes`**: resolves cold ids to hot keys via `committee_registration` without
  the interval join (`Gov.hs:2816-2837`) — correct and measured.

## 6. Open questions for the owner

1. **Deployment topology.** How many `query-api` replicas run, and how are rolling restarts done?
   GV-01's severity is "High" only if more than one process ever boots against a serving database.
   Are the index/roles Jobs and the `palmares_ro` wiring in another repository?
2. **Is the nightly green today?** The last run that produced the "90 rather than 21" sentence in
   `koios-parity-gate.md` cannot have used the fetch at `admin/Reconcile.hs:325`. Which is newer?
3. **Which is the formula of record** — the catalog file or the matview (GV-03)? The answer decides
   whether the doc gate protects anything.
4. **`expiration` semantics** (GV-12): is `gov_action_proposal.expiration = gasExpiresAfter + 1`?
   The three pinned counts in `020_eligibility.sql` move by one if the bound changes.
5. **Tally power epoch**: at the boundary closing epoch E, does the ledger weigh votes with
   `drep_distr` labelled E or E+1 in db-sync? A shared off-by-one with Koios would pass R3/R4.
6. **Should `unknown` count in `total_dreps`** on the dashboard (GV-09b)? Today `/dreps` and the
   dashboard disagree by 90.
7. **Mainnet sizing**: expected boot time of the matview build, `drep_epoch_delegators` cost with
   ~10⁶ delegations × 500 epochs, and `/gov-actions` with `votes_cast` for ~400 actions.
8. **Which BFF** provides rate limiting, and does it also cap concurrency per upstream?

## 7. Improvement backlog (ranked)

| # | ID | Severity | Effort | Action |
|---|---|---|---|---|
| 1 | GV-02 | High | S | Fetch `/dreps` without the status filter in the reconciler, re-record the snapshot pair, assert status coverage in the replay test |
| 2 | GV-01 | High | M | Hash-gated bootstrap + advisory lock + schema swap (or `WITH NO DATA` and refresh after boot) |
| 3 | GV-04 | High | M | Compose runs `apply-roles`; query-api as `palmares_ro`/`palmares_owner`; `PG_CONN_STR` fail-closed; `default_transaction_read_only` on the read pool |
| 4 | GV-03 | High | M | One source for the six formulas (generate the matview from the catalog or publish the matview as the formula); run the 070 agreement over all DReps in CI |
| 5 | GV-06 | Medium | S | Join `palmares.drep`/`drep_epoch_power` by `drep_hash_id` in `voteFrom` and `vote_tally` |
| 6 | GV-07 | Medium | S | Use `treasury_withdrawal.id` as arm 11's `item_index`; seed a two-beneficiary enactment |
| 7 | GV-12 | Medium | S | Confirm `expiration` semantics; use `expiration - 1` as the votable bound; update pins |
| 8 | GV-10 | Medium | M | Pre-aggregate `votes_cast` once per page (or matview column); `EXPLAIN` the 200-row page |
| 9 | GV-05 | Medium | M | Bounded semaphore around `runRead` + per-client token bucket, or remove the "rate-limited" claim and document the BFF |
| 10 | GV-11 | Medium | S | Add `tx_index` to the three latest-certificate orderings |
| 11 | GV-14 | Medium | S | Null the SPO threshold when no security parameter is touched; add `threshold_applies` |
| 12 | GV-09 | Medium | S | Catalog entry for the per-epoch participation rate (or null it); `total_dreps` includes `unknown`, add `unknown_dreps` |
| 13 | GV-13 | Medium | S | `hash_verified` verdict for `is_valid IS NULL`; publish hash-matched content |
| 14 | GV-15 | Medium | S/M | LEFT JOIN the matview; advisory-locked single refresher; expose `as_of_epoch` |
| 15 | GV-08 | Medium | S | Place `gov_action_ratified` at the boundary into `ratified_epoch + 1` (after VERIFY) |
| 16 | GV-16 | Medium | S | Make `is_current=false` return superseded delegations, or fix the description |
| 17 | GV-17 | Medium | S | Check `declaredIndexes` at boot/`/status`; re-sync runbook |
| 18 | GV-20 | Low | S | Gate `open_actions_unvoted` on a current registration interval (both copies) |
| 19 | GV-21 | Low | S | Filter "closing soon" on `last_votable_epoch` |
| 20 | GV-18 | Low | S | Compare the latest resignation against the current committee's establishment |
| 21 | GV-19 | Low | S | Verify `reward_rest.spendable_epoch` for treasury payouts; seed a test |
| 22 | GV-23 | Low | S | `/status`: `drep_distr_epoch`, amber band, matview `as_of_epoch`, attest lag, missing indexes |
| 23 | GV-24 | Low | S | Sample-age warning, notification on exit ≠ 0, correct the R10 abort label |
| 24 | GV-22 | Low | S | Delete the three dead query modules; fix CLAUDE.md/ADR/README/metrics.md references; drop the `docs/superpowers` links or vendor the specs |
| 25 | GV-25 | Low | M | Seeded mini-corpus so `sql/checks` semantics and the 070 agreement run in CI |
