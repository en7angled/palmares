# ADR 0009 — The votes feed and the window it cannot escape

Status: accepted 2026-10-24, owner's decision — the window-free row source is **not built**
Date: 2026-10-24

## The stance

`GET /votes` is slow on deep pages because of a **data property, not a query shape**: the page's own
primary keys cannot be pushed below a `WindowAgg`, so a page of 100 rows reads 1.5–3.2 M. A
window-free sibling of `palmares.vote` would fix it — MEASURED at 33.8× on the deepest page — and it
is **not built.**

**The reason is not the one this ADR was opened with.** It was opened expecting a trade: speed against
the exactness of three columns the read surface documents as exact at every instant. There is no
trade. §5 measures a variant that is exact *and* fast — 24–131 ms over the stale shape, inside the
run-to-run spread, with 32× still in hand at the deepest page — so the guarantee never had to be
sold. What is declined is the **latency**: every page a real user can reach is already fast, the
pages it would speed up exist because somebody stress-tested preprod, and a second derivation of
`is_final`, `is_first` and `revote_count` to serve test data is a maintenance cost with no user
behind it.

**And the slow case is only the unfiltered deep feed, which is what makes the whole finding small.**
`voter_id_hash` IS a partition column, so a filtered page is pushdown-safe at any depth — MEASURED,
`?voter_id=7cc19a2e…&limit=100&offset=10000` is **3.35 s** against **20.53 s** unfiltered at the same
depth. "This DRep's voting record" is the screen that exists, and it is fast. "Every vote ever cast,
page 9" is the screen that is slow, and nobody builds it.

One mitigation taken, one declined:

* **TAKEN — correct the `?is_final=true` claim wherever the docs overstate it.** It is a mitigation
  for the *first* pages only, not for the route; § "The claim that was overstated" says by how much.
  Routed separately, not implemented here.
* **DECLINED — lowering `/votes`' offset ceiling.** This was recorded as taken earlier in the same
  decision. The step-not-slope measurement retired it; (b) below has the three numbers that did.

**The trigger for revisiting is written out below with the query that checks it**, because the
decision rests on a property of today's corpus and that property can change.

**The trigger for revisiting is written out below with the query that checks it**, because the
decision rests on a property of today's corpus and that property can change.

## 1. The measurement, re-verified

`listVotes` (`src/exe/query-api/Query/Gov.hs:1587`) is four statements. Each was run on its own
through `psql` against preprod at epoch 321, warm, **median of three**, with the page's id and
partition-key lists bound exactly as the service binds them. No filters, `order_by=cast_at`,
`sort_order=desc` — the shape `docs/usecases/api-screen-map.md` §2.8 publishes.

| page | ① count | ② page ids | ③ partition keys | ④ the rows | Σ | `curl` end-to-end |
| --- | --- | --- | --- | --- | --- | --- |
| `limit=200&offset=0` | 375 ms | 2.6 ms | 2.0 ms | **519 ms** | 0.90 s | 0.77 s |
| `limit=100&offset=1000` | 375 ms | 8.4 ms | 362 ms | **10,670 ms** | 11.4 s | 10.24 s |
| `limit=200&offset=10000` | 375 ms | 28.4 ms | 350 ms | **17,393 ms** | 18.1 s | 20.53 s |

The sum and the HTTP number agree to within 15%, so the whole request is these four statements and
nothing else. ① is shape-independent here (no filter reaches a join) and ②+③ together are **under
5 ms at offset 0 and 378 ms at offset 10,000** — so the *offset* is not the cost. Stage ④ is 95.9%
of the deepest request.

**`EXPLAIN ANALYZE` cannot measure these statements and was not used for timing.** Its per-row
instrumentation over three `WindowAgg`s reported 36,476 ms for the offset-1000 statement that takes
13,183 ms unobserved (`Gov.hs:1551-1554`). Every number here is wall clock; every plan fact is from
`EXPLAIN` without `ANALYZE`.

The plan of the offset-10000 page shows the whole mechanism in three lines:

* `Filter: (gov_action_proposal_id = ANY ('{10,12,13,8,9}'::bigint[]))` on the `Seq Scan` of
  `voting_procedure` — pushed down, and it keeps **more** rows than the page needs, because those
  five actions *are* the corpus;
* the `voter_id_hash` filter applied after the `cc_cold_interval` hash join — still below the
  windows, but unable to reach an index, because the view *derives* the column as
  `COALESCE(cold_raw, hot_hash)`;
* `Filter: (v.voting_procedure_id = ANY ('{3234524,…}'))` on the `Subquery Scan` **above all three
  `WindowAgg` nodes.** The page's own 200 primary keys are tested only after the windows have been
  computed over 3.2 M rows. `qual_is_pushdown_safe` admits a qualifier below a `WindowAgg` only when
  it references the `PARTITION BY` columns, and the primary key is not one of them.

And the proof that page size is irrelevant: **stage ④ for a page of ONE deep row is 2,194 ms** —
one row, one partition, 21,625 siblings read.

## 2. The distribution that causes it

931 partitions over 3,244,723 vote rows — min 1, **median 1**, mean 3,485.2, max 21,626:

| rows in the partition | partitions | vote rows | share of corpus |
| --- | --- | --- | --- |
| 1 | 697 | 697 | 0.02% |
| 2–10 | 83 | 254 | 0.01% |
| 11–1,000 | 1 | 20 | 0.00% |
| **> 10,000** | **150** | **3,243,752** | **99.97%** |

Those 150 partitions are five governance actions — the epoch-187 `AuthCommitteeHotKey` stress test:

| `gov_action_id` | partitions | vote rows | share | largest partition |
| --- | --- | --- | --- | --- |
| 8 | 33 | 648,755 | 19.99% | 21,625 |
| 9 | 32 | 648,754 | 19.99% | 21,625 |
| 10 | 32 | 648,754 | 19.99% | 21,625 |
| 12 | 30 | 648,752 | 19.99% | 21,626 |
| 13 | 30 | 648,750 | 19.99% | 21,625 |
| **top five** | **157** | **3,243,765** | **99.97%** | |
| 98 *(the sixth)* | 115 | 119 | 0.00% | 3 |

A cliff of four orders of magnitude at rank six. **Excluding those five actions the entire corpus is
958 votes in 774 partitions over 98 actions, and the largest partition is 20 rows** — a size at which
every window in this file is free and none of this exists.

That asymmetry is the decision. `revote_count` for one row is
`COUNT(*) OVER (PARTITION BY voter_role, voter_id_hash, gov_action_id)`, so its cost is the partition
size and nothing else. At 20 rows it is free; at 21,625 it is the defect. The corpus that makes it a
defect is one stress test that will not be re-run, and a vote costs a transaction fee per cast while
the ledger keeps only the last — so 21,625 re-votes by one credential on one action is not a shape
real governance produces.

**The cliff is visible in the feed itself and it is not a function of depth.** `/votes` is ordered
`v.id DESC`, and exactly **901 votes are newer than the newest stress-test vote**
(id 3,243,822). Measured end-to-end, that boundary is the whole latency curve:

| `limit=200&offset=` | 0 | 100 | 200 | 400 | 600 | **800** | 1000 | 10000 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| end-to-end | 0.77 s | 1.12 s | 1.09 s | 1.11 s | 1.10 s | **12.15 s** | 10.24 s | 20.53 s |

Flat at ~1.1 s until the page crosses row 901, then a step of 11 s. The route is not "slow when
paged deeply"; it is fast for the whole real corpus and slow the moment a page touches the artifact.

## 3. The trigger

Revisit this decision **when a corpus the registry actually serves shows partitions in the
thousands** — that is, when re-voting at scale is a property of real governance rather than of five
actions. Checkable, and the obvious phrasing does *not* work: the 99th percentile of partition size
on preprod today is **21,625**, because 150 of 931 partitions are stress-test partitions, so a plain
p99 trigger fires already and says nothing.

The form that is checkable excludes the five heaviest actions *by rule* and asks whether the problem
is broader than a handful of them:

```sql
-- Trigger for ADR 0009. Run against the deployment in question.
WITH heaviest AS (
  SELECT gov_action_id FROM palmares.vote_partition
  GROUP BY gov_action_id ORDER BY sum(vote_rows) DESC LIMIT 5
)
SELECT
  (SELECT count(*) FROM (SELECT gov_action_id FROM palmares.vote_partition
                         GROUP BY gov_action_id HAVING max(vote_rows) > 1000) q)
    AS actions_with_heavy_partitions,
  percentile_disc(0.99) WITHIN GROUP (ORDER BY p.vote_rows) AS p99_rest,
  max(p.vote_rows)                                          AS largest_rest
FROM palmares.vote_partition p
WHERE p.gov_action_id NOT IN (SELECT gov_action_id FROM heaviest);
```

**Reading on preprod, 2026-10-24: `actions_with_heavy_partitions = 5`, `p99_rest = 4`,
`largest_rest = 20`.** The decision stands while that holds. It is revisited when either

* `actions_with_heavy_partitions > 5` — the heavy partitions are no longer confined to five actions;
* or `p99_rest` exceeds a few hundred rows — ordinary actions carry partitions big enough for the
  window to cost real time.

Both are far from firing, and both are one query away from being checked rather than re-argued.

## 4. What was costed and declined: the window-free row source

A sibling view — not a replacement — whose three sequence columns come from
`palmares.vote_partition` by join, so the page's restriction becomes a primary-key lookup:

```sql
CREATE VIEW palmares.vote_as_of_refresh AS           -- NOT CREATED; the name carries the cost
SELECT
  v.*,                                               -- palmares.vote's `identified` CTE, exposed as
                                                     -- its own view: the identity CASEs and the
                                                     -- cc_cold_interval join unchanged, the three
                                                     -- WindowAggs gone
  (vp.last_voting_procedure_id  = v.voting_procedure_id) AS is_final,
  (vp.first_voting_procedure_id = v.voting_procedure_id) AS is_first,
  vp.vote_rows                                           AS revote_count
FROM palmares.vote_resolved v
LEFT JOIN palmares.vote_partition vp
  ON  vp.voter_role    = v.voter_role
  AND vp.voter_id_hash = v.voter_id_hash
  AND vp.gov_action_id = v.gov_action_id;
```

Measured by running the equivalent statement by hand — same projection, same five standing joins,
restricted by `v.id IN (<the page's ids>)` and nothing else:

| page | stage ④ now | window-free | speed-up | projected Σ |
| --- | --- | --- | --- | --- |
| `limit=200&offset=0` | 519 ms | **157 ms** | 3.3× | 0.54 s |
| `limit=100&offset=1000` | 10,670 ms | **551 ms** | **19.4×** | 1.30 s |
| `limit=200&offset=10000` | 17,393 ms | **515 ms** | **33.8×** | 1.27 s |
| one deep row | 2,194 ms | **424 ms** | 5.2× | — |

`EXPLAIN` confirms the mechanism: `Index Scan using voting_procedure_pkey,
Index Cond: (id = ANY ('{…}'))`, estimated total cost **153,036 against 150,920,551** — a 986× drop
— and **zero `WindowAgg` nodes over `palmares.vote`**. The one window left is `cc_cold_interval`'s
`LEAD` over 648,767 committee registrations, `Materialize`d for a merge join; alone it is 88–187 ms,
which is most of the ~0.5 s floor the deep pages land on.

**It is the same answer, verified not assumed.** Both shapes were computed for the same 500 rows
across the three pages and compared on all three columns: **0 disagreements on `is_final`, 0 on
`is_first`, 0 on `revote_count`, 0 unmatched rows.** By construction, too —
`palmares.vote_partition` reads its sequence numbers *from* `palmares.vote`
(`sql/020_views.sql:209-213`).

### The cost that looked decisive, and was not

The matview is refreshed on a tick (`Query/Refresh.hs`), `PALMARES_VIEW_REFRESH_SECONDS` = **300** in
`README.md`, `compose.yaml` and `.env.example` alike. Re-measured: the matview's defining `SELECT`
over all 3,244,723 rows is **7.88 s** (7.79 / 9.47 / 7.88), consistent with the 8.9 s
`Query/Refresh.hs:93` records; `REFRESH … CONCURRENTLY` adds diff-and-apply, so ~9 s is the honest
figure. **Worst-case staleness ≈ 300 s + 9 s ≈ 5 min 9 s.**

Which rows, exactly:

1. **A first vote by a voter on an action.** No matview row, the `LEFT JOIN` yields NULL, and
   `VoteRecord` types these fields `Bool`, `Bool`, `Int` — not `Maybe`
   (`QueryResponses.hs:1266-1268`). So the row is a **500 through the response decoder** unless
   coalesced, and coalescing publishes `is_final=false, is_first=false, revote_count=0` for a vote
   that is in truth the first and only one. The price is not staleness; it is a choice between a 500
   and a plausible lie.
2. **A re-vote in an existing partition.** `last_voting_procedure_id` still names the previous vote,
   so **two** published rows are wrong — the new vote reads `is_final=false` and its predecessor
   reads `is_final=true` — and `revote_count` is one short for *every* row of that partition.

How often, measured: the matview is exactly current right now (max covered id = max vote id =
3,244,723), the newest 1,000 votes span **667.7 days** (~1.5 votes/day outside the stress test), and
across the whole chain **votes occur in 535 of 457,263 possible 300-second windows — 0.12%** — with a
worst window of **38** votes and a p99 of **5** (excluding the stress test; including it, the worst
300 s window held 13,950).

So the staleness is small. It is also unnecessary, which is the next section.

## 5. The alternative that makes the trade disappear: correct only the uncovered tail

The costing above treats the matview as all-or-nothing — its flags for every row, and therefore
staleness for every row. It need not be. The rows the matview does not cover are *precisely the rows
newer than the last refresh*, and for those the truth is **derivable, not unknown**: a vote not yet in
the matview is newer than everything in its partition, so `is_final` is true unless a later uncovered
row exists in the same partition; `is_first` is true iff the partition has no matview row at all; and
`revote_count` is the matview's count plus the uncovered rows of that partition. A covered row whose
partition contains an uncovered row is un-marked by an anti-join against the same tiny set.

So: the matview for the body, a window over **only the tail**, exact, with no NULL reaching a `Bool`
and no coalesced lie. The watermark is `SELECT max(last_voting_procedure_id) FROM
palmares.vote_partition` — **0.8 ms** over 931 rows.

**MEASURED, and it is as cheap as it looks.** The tail's whole added cost — resolve the uncovered
rows, aggregate them per partition, join the matview — at simulated watermarks:

| uncovered tail | cost | what it corresponds to |
| --- | --- | --- |
| 0 rows | **1.5 ms** | 99.88% of 300 s windows on this chain |
| 38 rows | **1.7 ms** | the worst 300 s window of real governance traffic, ever |
| 1,000 rows | 368 ms | — |
| 14,000 rows | 980 ms | the worst 300 s window in chain history, mid-stress-test |

And the complete page, with the tail correction wired in, against the stale shape it replaces:

| page | current | stale window-free | **exact, tail-corrected** |
| --- | --- | --- | --- |
| `limit=200&offset=0` | 519 ms | 157 ms | **288 ms** |
| `limit=100&offset=1000` | 10,670 ms | 551 ms | **599 ms** |
| `limit=200&offset=10000` | 17,393 ms | 515 ms | **539 ms** |

**So there is no trade, and this measurement changed the reason for the stance.** Exactness costs
between 24 ms and 131 ms on top of the stale shape — inside the run-to-run spread — and still leaves
a 32× improvement at the deepest page. The decision was *first* taken on the grounds that a published
guarantee should not be weakened to serve an artifact of test data. That reason is now void: nothing
has to be weakened. The reason as it stands is narrower and must not be read as the old one:

* the pages the hybrid would speed up exist **because somebody stress-tested preprod**;
* **every page of the real corpus is already fast** — 901 of 958 rows sit above the cliff, and a
  filtered page is fast at any depth;
* so a second derivation of `is_final`, `is_first` and `revote_count`, alongside the one in
  `palmares.vote` that `palmares.vote_partition` itself derives from, is a **maintenance cost with no
  user behind it.**

If the trigger in §3 fires, this is what to build, and it is pre-costed — §5, not §4.

Two warnings for whoever builds it:

* **The watermark must be a BOUND VALUE, not a scalar subquery.** Written as
  `WHERE v.id > (SELECT max(…) FROM palmares.vote_partition)` the same three pages measured
  **1,399 / 1,858 / 1,933 ms** — 2.4–3.6× worse — because an InitPlan's value is unknown while the
  plan is chosen and the tail scan loses its primary-key path. This is exactly the hazard
  `activityWhere` records for the activity feed's tip (`Gov.hs:2774-2779`): one extra round trip of
  ~0.8 ms buys the same plan on every page.
* **Only the covered branch is verified.** The 0-disagreement check above exercises the matview join;
  the tail branch is derived and untested, because producing an uncovered row requires a write.
  Verifying it means recomputing the matview as of a watermark and comparing against the window over
  the full corpus — one statement, and it belongs in `sql/checks/`.

## 6. The other alternatives

### (a) Keyset/cursor pagination over the fact table — ruled out

`/activity` already does this (`Gov.hs:2696-2883`): a four-column cursor
`(sort_slot, tx_index, arm, item_index)`, a `ROW` comparison for the keyset, and scalar `sort_slot`
bounds beside it *because the row comparison is opaque to the planner*. It cannot help here, for
three independent reasons:

* **A keyset on `/votes` would be on `(vote_slot, voting_procedure_id)`, and neither is in the
  `PARTITION BY`** — which is `(voter_role, voter_id_hash, gov_action_id)`; slot and id are in the
  `ORDER BY`. `qual_is_pushdown_safe` keeps a keyset predicate above the `WindowAgg` exactly as it
  keeps the primary key there. A cursor changes which rows stage ② picks; stage ④ is untouched.
* **The cost is not in the offset.** Stage ② at offset 10,000 is 28 ms of an 18 s request, and a page
  of one deep row is still 2.2 s. There is no 28 ms worth a second pagination protocol.
* **`palmares.activity` carries no window-derived column at all** — its vote arm publishes no
  `is_final` and no `revote_count`. A keyset must be a total order over columns comparable at the
  base level; these three exist only after the window. The cursor machinery cannot carry them because
  nothing in it ever has.

It would also cost the total: `/activity` publishes `total: null` by design (F-17 — a count from a
different pass is a total that disagrees), while `/votes` publishes `total: 3244723`.

### (b) A lower offset ceiling on `/votes` — DECLINED, reversing an earlier decision in this ADR

`hardOffsetCeiling = 10000` (`Query/Common.hs:92`) refuses past row 10,000 with a 400 rather than a
clamp, and `docs/usecases/governance-read-surface.md` §2.2 already tells the UI to cap itself. Offset
paging therefore addresses 10,200 of 3,244,723 rows — **0.31% of this corpus**. Lowering the ceiling
was recorded as taken, on the reading that it costs no documented screen anything. **Three measured
numbers retired it:**

1. **901 / 958.** 901 votes are newer than the newest stress-test vote, and the real corpus is 958
   votes in 774 partitions. So **the entire corpus a real user would ever page through is already in
   the fast region**, and the cliff is not depth — it is the stress test. A ceiling cannot protect
   anything that needs protecting.
2. **1.10 s → 12.15 s between offset 600 and offset 800** (`limit=200`). The curve is a step, not a
   slope, so the only ceiling that makes the route uniformly fast today is **600** — which **refuses
   page 13 of a 50-row scroll**, permanently, on the one route three screens read. That trades a
   permanent refusal for a temporary slowness, on a screen that is legitimate.
3. **66 days.** The cliff *sinks* as real votes accumulate above it. At ~1.5 votes/day the artifact
   passes below row 1,000 in about 66 days, after which the route is uniformly ~1.1 s with nobody
   touching anything. A ceiling of 1,000 would only cap the worst case at ~12 s in the meantime, and
   would then be a tuned constant with no remaining purpose and nobody to remove it.

**The one caveat that makes this a judgement rather than a shrug:** a 12 s page is uncomfortably
close to the 30 s read timeout, and cold it has already crossed it once — **31.7 s and a 503** on the
first deep request. That figure is recorded from before this ADR and was not re-measured here: every
number in this document is warm, because a cold read cannot be reproduced on demand against a live
service, and the cold case is therefore the one risk here that is bounded by inference rather than by
measurement. If it 503s again, the answer is `hardOffsetCeiling = 600` on this route
and the cost is known in advance: page 13 of a 50-row scroll becomes a 400. That is a one-line change
with its trade already measured, which is the point of writing it down rather than taking it now.

### (c) Do nothing, on the grounds that preprod is not mainnet

**This is the stance.** With (b) declined, the only thing taken is a documentation correction, so
what ships is nothing: §2 is the argument, §3 is the trigger, and §5 is what to build if it fires.

### (d) A generated column on the fact table — not available

`palmares` has no write access to db-sync's tables; `sql/050_roles.sql` exists to assert exactly that
separation. A trigger or stored column on `public.voting_procedure` would also be destroyed by the
next db-sync migration's `CASCADE`, the hazard `Query/Refresh.hs:137-141` already handles for the
matviews.

## The claim that was overstated: `?is_final=true`

`?is_final=true` reads a 931-row pre-aggregation, turning the count from 7,058 ms into 2.4 ms and
65,000 pages into 19 (`Gov.hs:3032-3053`). It has been described — in this repository's own notes,
more than once — as *the answer for almost every client*. **It is the answer for the first pages
only.** It fixes stages ①–③ and leaves stage ④ exactly as it was: still read through
`palmares.vote`, still restricted by partition keys, still window-complete. MEASURED end-to-end on
the live service:

| request | latency | partition rows stage ④ must read |
| --- | --- | --- |
| `?is_final=true&limit=100&offset=0` | 0.53 s | 101 |
| `?is_final=true&limit=100&offset=100` | 0.52 s | 120 |
| `?is_final=true&limit=100&offset=800` | **9.57 s** | **1,621,907** |

The 931 final votes sort `v.id DESC`, so the stress test's 150 partitions land on the *last* pages.
**By how much the claim was overstated: page 9 of 10 of the mitigated list is an 18× slower request
than page 1 — nine clicks from page 1, not 65,000** — and it reads 16,000× more rows to return the
same 100. The window-free shape serves that page's stage ④ in 1,195 ms, an 8× improvement, which is
the one place where declining §4 costs a user something real.

The correction is routed separately. What belongs here is that the overstatement was measured, and
where: any text saying `?is_final=true` makes this route fast needs to say *the first pages of* it.

## What is deliberately not built

* **The window-free row source.** Per the stance. It is costed in §4 so that the next reader does not
  have to re-measure it, and the tail variant in §5 is the shape to build if the trigger fires —
  not §4's, because §5 is exact and measured to cost the same.
* **A lower offset ceiling.** Per (b): 600 refuses page 13 of a 50-row scroll to fix a region of the
  feed that will sink below row 1,000 on its own in ~66 days, and 1,000 caps the worst case at ~12 s
  without removing it. Both are tuned constants with nobody to remove them. Held in reserve against
  one condition only — a cold 503 — with the value and its cost already decided.
* **Keyset pagination on `/votes`.** Per (a); it cannot carry these columns at all.
* **Excluding the stress-test actions from the read surface.** Tempting, and wrong: they are real
  governance actions with real votes, and a read layer that hides rows to look fast is a read layer
  that disagrees with the chain.

## What changed while this was decided

Two positions were taken and then reversed on measurements made after them. They are recorded as
reversals rather than smoothed away, because the reasons that replaced them are narrower than the
reasons they replaced, and a reader who inherits only the conclusion would defend it with the wrong
argument.

| taken | reversed to | the measurement that did it |
| --- | --- | --- |
| Lower `/votes`' offset ceiling | **Do not lower it** | the latency curve is a **step** at row 901, not a slope — 901 of 958 real votes are above it, 600 would refuse page 13 of a 50-row scroll permanently, and the artifact sinks below row 1,000 on its own in ~66 days |
| The hybrid is declined because a published guarantee should not be weakened for test data | **Declined on latency alone — nothing is weakened** | exactness costs **24–131 ms**, inside the run-to-run spread, with 32× still in hand (§5) |

The second matters more than the first. "We kept the guarantee" is a defensible reason that happens
to be false here; the true reason is that there is no user behind the pages the fix would speed up.

## Consequences

* **`/votes` keeps three exact columns and one slow region, unbounded.** `is_final`, `is_first` and
  `revote_count` remain correct at every instant, which is what the read surface says. Pages that
  touch the epoch-187 artifact remain ~10–20 s warm, with **no ceiling added** to cap them, and that
  is accepted — the region is test data and it sinks out of reach of offset paging on its own.
* **One condition is held in reserve with its answer pre-decided.** A cold 503 on this route — 31.7 s
  against a 30 s read timeout, recorded once before this ADR and the only figure here that is not
  warm — triggers `hardOffsetCeiling = 600` on `/votes`, costing page 13 of a 50-row scroll. Nothing
  else triggers it.
* **The `is_final` claim has to be corrected in the docs, not just here.** It is the one
  user-visible defect this ADR does not fix: nine clicks deep on a nineteen-page list is a request a
  client makes.
* **The decision is checkable, not just argued.** §3's query and its three readings are the whole
  test. A future reader who disagrees should run it before re-opening the argument, and if it has
  moved, §5 is the costed answer and it is exact.
* **Two lines are worth more than the design they belong to.** Whoever builds §5 must bind the
  watermark rather than read it as a scalar subquery (2.4–3.6× measured), and must write the
  `sql/checks/` statement that verifies the tail branch, which is the half of §5 nothing has tested.
* **Preprod's corpus remains the only evidence.** Every number here comes from a chain holding one
  stress test that is 99.97% of its own vote table. That is also precisely why the stance is what it
  is.
