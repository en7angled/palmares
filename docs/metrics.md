<!-- GENERATED FILE — do not edit.

     Produced by `admin write-metrics-doc` from resources/metric-formulas.json and
     resources/metrics/*.sql. CI runs the generator and fails on any diff, so editing this
     file by hand is reverted by the next build; edit the catalog instead.
-->

# Published metrics

Every number this API serves is defined here, and the SQL below is the SQL that produces it:
`Query.Metrics` looks each statement up by `formula_id` and runs it, so there is no second
copy of the arithmetic that could disagree with this page.

A `null` is not a zero. Where a formula has a `null when` condition, that condition means
"no data", and a UI must render it as such rather than as 0%.

## Participation rate

| | |
|---|---|
| formula id | `participation_rate_v1` |
| response field | `participation_rate` |
| version | 1 |
| source | `resources/metrics/participation_rate_v1.sql` |

**Expression.** |actions_voted| / |actions_eligible|

**Denominator.** distinct governance actions whose voting window closed before as_of_epoch, of a type the role may vote on in the action's protocol-version phase, overlapping a registered interval of the actor

**Null when.** eligible_actions = 0

**Inputs.** `gov_action_proposal`, `voting_procedure`, `drep_registration`, `epoch_param.protocol_major`

**Edge cases.**

- Conway bootstrap phase: a DRep could only vote on InfoAction, and the test is over the whole voting window rather than the proposing block
- re-votes collapsed to distinct actions; verdict = last vote, latency = first vote
- still-open actions excluded from the denominator and reported as open_actions_unvoted
- votes voided by DRep retirement still count as cast
- a registered DRep with zero delegated stake is still eligible: drep_distr membership is not part of the denominator

Parameters, in placeholder order: `drep_hash_id`, `as_of_epoch`

```sql
-- participation_rate_v1 — of the actions this DRep could have voted on, how many did it vote on.
--
-- Parameters are bound ONCE in the leading CTE, in the order resources/metric-formulas.json's
-- `params` array names them: drep_hash_id, as_of_epoch. Every statement in this directory follows
-- that shape, so a positional placeholder never has to be repeated and the names stay visible in
-- the SQL.
--
-- A question mark may not appear ANYWHERE else in these files, comments included:
-- postgresql-simple counts placeholders lexically over the whole statement, so a question mark in
-- prose is read as a parameter and the query fails with "N single chars, but M parameters".
-- UnitTests.MetricCatalog asserts the count per file so that lands as a clear failure.
--
-- The denominator is palmares.eligible_actions, not a re-derivation: registration overlap, the
-- Conway bootstrap test and "settled by as_of_epoch" all live in that one function (D-15).
-- `open_actions_unvoted` is reported separately because a still-open action is not a missed vote.
WITH p AS (
  SELECT ?::bigint AS drep_hash_id, ?::int AS as_of_epoch
),
elig AS (
  SELECT e.gov_action_id, e.action_type
  FROM p, palmares.eligible_actions(p.drep_hash_id, p.as_of_epoch) e
),
voted AS (
  SELECT DISTINCT v.gov_action_id
  FROM palmares.vote v
  JOIN elig e ON e.gov_action_id = v.gov_action_id
  WHERE v.drep_voter_id = (SELECT drep_hash_id FROM p)
),
open_unvoted AS (
  SELECT a.gov_action_id
  FROM palmares.action_window a
  WHERE a.last_votable_epoch >= (SELECT as_of_epoch FROM p)
    AND a.drep_votable
    AND NOT EXISTS (
      SELECT 1 FROM palmares.vote v
      WHERE v.drep_voter_id = (SELECT drep_hash_id FROM p)
        AND v.gov_action_id = a.gov_action_id
    )
)
SELECT
  (SELECT count(*) FROM elig) AS eligible_actions,
  (SELECT count(*) FROM voted) AS votes_cast,
  -- NULL, not 0: a DRep with nothing it could have voted on has no participation rate. "n/a" and
  -- "0%" are different statements about a person.
  CASE WHEN (SELECT count(*) FROM elig) = 0 THEN NULL
       ELSE (SELECT count(*) FROM voted)::float8 / (SELECT count(*) FROM elig) END AS participation_rate,
  (SELECT count(*) FROM open_unvoted) AS open_actions_unvoted;
```

Spec: docs/superpowers/design/f1-metric-formulas.md#51-participation_rate-eligible_actions-votes_cast-open_actions_unvoted

## Rationale rate

| | |
|---|---|
| formula id | `rationale_rate_v1` |
| response field | `rationale_rate` |
| version | 1 |
| source | `resources/metrics/rationale_rate_v1.sql` |

**Expression.** (rationale_verified + rationale_inline) / (rationale_verified + rationale_inline + rationale_absent)

**Denominator.** the final votes on actions in the eligible set whose rationale we could actually assess: verified, inline, or demonstrably absent. Unverified and pending votes are excluded from both sides.

**Null when.** rationale_verified + rationale_inline + rationale_absent = 0, i.e. none of this actor's rationales could be assessed

**Inputs.** `voting_procedure.voting_anchor_id`, `voting_anchor`, `off_chain_vote_data`, `off_chain_vote_fetch_error`

**Edge cases.**

- five grades, not four: verified | inline | unverified | pending | absent
- inline is a data: URI, where the rationale IS the URL and hash verification is vacuous; counting it as missing would accuse an author who did publish one
- pending means db-sync has not attempted the fetch yet, which is not the author's failure
- unverified and pending are excluded from the DENOMINATOR, not counted as failures: measured on preprod, zero anchors on DRep votes are valid and 140 of the 237 unreachable ones are ipfs:// URIs our gateway list cannot fetch, so dividing by votes_cast would report our infrastructure's failure as 36 authors' negligence
- all five counters are published, so a consumer wanting another basis — an attachment rate, say — can compute it
- the five counters sum to votes_cast by construction, because the sample is the eligible set

Parameters, in placeholder order: `drep_hash_id`, `as_of_epoch`

```sql
-- rationale_rate_v1 — of the votes this DRep cast, how many carried a published rationale.
--
-- Params: drep_hash_id, as_of_epoch.
--
-- FIVE grades, not four (D-3), and the fifth is the one that matters for fairness:
--   verified    the anchor was fetched and its hash matched
--   inline      a `data:` URI: the rationale IS the URL, so there is nothing to fetch and hash
--               verification is vacuous. preprod has real ones. Counting these as missing would
--               accuse an author who did publish a rationale.
--   unverified  a fetch was attempted and failed
--   pending     an anchor is attached and db-sync has not tried yet
--   absent      no anchor at all
-- THE DENOMINATOR EXCLUDES WHAT WE COULD NOT ASSESS. The rate is
--   (verified + inline) / (verified + inline + absent)
-- so `unverified` and `pending` are out of BOTH sides. Rationale, and it is measured, not
-- theoretical: across all 648 final DRep votes on preprod today there are ZERO `valid` anchors.
-- 23 are unreachable, and network-wide 140 of the 237 unreachable anchors are `ipfs://` URIs that
-- our db-sync's gateway list cannot fetch. Dividing by votes_cast would therefore publish
-- "essentially nobody on preprod writes rationales" when the truth is "our indexer cannot fetch
-- IPFS" — a statement about our infrastructure, printed as a judgement about 36 people.
--
-- An unreachable or not-yet-fetched anchor is evidence the author DID attach something and no
-- evidence about its contents. Counting it as a failure is the same error the `inline` and
-- `pending` grades exist to avoid; excluding it says "we cannot tell", which is true. When nothing
-- can be assessed the rate is NULL — "n/a", not 0%.
--
-- All five counters are published regardless, so a consumer who wants a different basis (an
-- attachment rate, say: (votes_cast - absent) / votes_cast) can compute it without us.
--
-- The five counters sum to votes_cast BY CONSTRUCTION, because `final` joins eligible_actions —
-- the same denominator participation_rate uses. Taking every action the DRep ever voted on instead
-- would let a vote on a still-open action into this sample while participation_rate excluded it,
-- and the two rates would stop being comparable.
WITH p AS (
  SELECT ?::bigint AS drep_hash_id, ?::int AS as_of_epoch
),
elig AS (
  SELECT e.gov_action_id
  FROM p, palmares.eligible_actions(p.drep_hash_id, p.as_of_epoch) e
),
final AS (
  SELECT v.gov_action_id, v.voting_anchor_id
  FROM palmares.vote v
  JOIN elig e ON e.gov_action_id = v.gov_action_id
  WHERE v.drep_voter_id = (SELECT drep_hash_id FROM p)
    AND v.seq_last = 1
),
graded AS (
  SELECT
    f.gov_action_id,
    CASE
      WHEN f.voting_anchor_id IS NULL THEN 'absent'
      WHEN a.verdict = 'inline' THEN 'inline'
      WHEN a.verdict = 'valid' THEN 'verified'
      WHEN a.verdict = 'not_fetched' THEN 'pending'
      ELSE 'unverified'
    END AS grade,
    a.cip100_valid
  FROM final f
  LEFT JOIN palmares.anchor a ON a.voting_anchor_id = f.voting_anchor_id
)
SELECT
  count(*) FILTER (WHERE grade = 'verified') AS rationale_verified,
  count(*) FILTER (WHERE grade = 'inline') AS rationale_inline,
  count(*) FILTER (WHERE grade = 'unverified') AS rationale_unverified,
  count(*) FILTER (WHERE grade = 'pending') AS rationale_pending,
  count(*) FILTER (WHERE grade = 'absent') AS rationale_absent,
  count(*) FILTER (WHERE cip100_valid IS TRUE) AS rationale_cip100_valid,
  CASE WHEN count(*) FILTER (WHERE grade IN ('verified', 'inline', 'absent')) = 0 THEN NULL
       ELSE count(*) FILTER (WHERE grade IN ('verified', 'inline'))::float8
            / count(*) FILTER (WHERE grade IN ('verified', 'inline', 'absent')) END AS rationale_rate
FROM graded;
```

Spec: docs/superpowers/design/f1-metric-formulas.md#52-rationale_rate-and-its-four-counters

## Registered age

| | |
|---|---|
| formula id | `age_days_v1` |
| response field | `age_days` |
| version | 1 |
| source | `resources/metrics/age_days_v1.sql` |

**Expression.** sum over registration intervals of (min(interval end, cursor) - interval start) / 86400

**Null when.** the actor has no registration interval

**Inputs.** `drep_registration`, `block.time`

**Edge cases.**

- summed over intervals, because retire-then-re-register is legal and the age is time actually spent registered
- the retirement lookup is bounded by slot, not epoch: register-retire-re-register inside one epoch would otherwise contribute a negative term
- the cursor is the last block of as_of_epoch, so the number is reproducible for a past epoch

Parameters, in placeholder order: `drep_hash_id`, `as_of_epoch`

```sql
-- age_days_v1 — how long this DRep has been registered, summed over its intervals.
--
-- Params: drep_hash_id, as_of_epoch.
--
-- Summed over intervals, because retire-then-re-register is legal: the age is the time actually
-- spent registered, not the span from the first certificate.
--
-- The retirement lookup is bounded by `slot_no > i.from_slot`, NOT by `epoch_no >= i.from_epoch`.
-- The epoch form picks up a retirement that happened EARLIER IN THE SAME EPOCH than the
-- registration opening the interval — register, retire, re-register inside one five-day epoch is
-- legal and cheap — which yields a negative term that GREATEST(0, ...) then silently hides.
WITH p AS (
  SELECT ?::bigint AS drep_hash_id, ?::int AS as_of_epoch
),
cursor_time AS (
  SELECT max(b.time) AS t
  FROM public.block b
  WHERE b.epoch_no <= (SELECT as_of_epoch FROM p)
)
SELECT
  GREATEST(0, SUM(EXTRACT(EPOCH FROM (
    LEAST(COALESCE(r.retire_time, c.t), c.t) - i.from_time
  )))) / 86400 AS age_days
FROM palmares.drep_interval i
CROSS JOIN cursor_time c
LEFT JOIN LATERAL (
  SELECT b2.time AS retire_time
  FROM public.drep_registration r2
  JOIN public.tx t2 ON t2.id = r2.tx_id
  JOIN public.block b2 ON b2.id = t2.block_id
  WHERE r2.drep_hash_id = i.drep_hash_id
    AND r2.deposit < 0
    AND b2.slot_no > i.from_slot
  ORDER BY b2.slot_no
  LIMIT 1
) r ON TRUE
WHERE i.drep_hash_id = (SELECT drep_hash_id FROM p);
```

Spec: docs/superpowers/design/f1-metric-formulas.md#53-age_days

## Delegator retention rate

| | |
|---|---|
| formula id | `delegator_retention_rate_v1` |
| response field | `delegator_retention_rate` |
| version | 1 |
| source | `resources/metrics/delegator_retention_rate_v1.sql` |

**Expression.** delegators_retained / delegator_count_prev

**Denominator.** the delegators this actor had retention_window_epochs epochs before as_of_epoch

**Null when.** delegator_count_prev = 0

**Inputs.** `delegation_vote`, `stake_deregistration`, `block.epoch_no`

**Edge cases.**

- the window is a parameter bound from this catalog, never a literal in the SQL
- a delegation ends at the next certificate for that address or at the credential's de-registration, whichever comes first
- a closed stake account is not a delegator, even though delegation_vote keeps the row

Parameters, in placeholder order: `drep_hash_id`, `as_of_epoch`, `retention_window_epochs`

```sql
-- delegator_retention_rate_v1 — how many of this DRep's delegators from w epochs ago are still
-- delegating to it.
--
-- Params: drep_hash_id, as_of_epoch, retention_window_epochs.
--
-- The window is a PARAMETER, bound from the catalog's `retention_window_epochs` (10), and never a
-- literal. Two literals in two places is exactly the drift this directory exists to prevent.
--
-- A delegation interval ends at the next certificate for that address OR at the credential's
-- de-registration, whichever comes first: a closed stake account is not a delegator, even though
-- delegation_vote keeps the row forever.
WITH p AS (
  SELECT ?::bigint AS drep_hash_id, ?::int AS as_of_epoch, ?::int AS retention_window_epochs
),
seq AS (
  SELECT
    dv.addr_id,
    dv.drep_hash_id,
    b.epoch_no AS from_epoch,
    -- The certificate's own position, so the de-registration below is compared against THIS
    -- CERTIFICATE rather than against its epoch.
    dv.tx_id AS from_tx,
    dv.cert_index AS from_cert,
    LEAD(b.epoch_no) OVER w AS next_epoch
  FROM public.delegation_vote dv
  JOIN public.tx ON tx.id = dv.tx_id
  JOIN public.block b ON b.id = tx.block_id
  WINDOW w AS (PARTITION BY dv.addr_id ORDER BY b.slot_no, tx.block_index, dv.cert_index)
),
live AS (
  SELECT
    s.addr_id,
    s.drep_hash_id,
    s.from_epoch,
    -- 2147483647 stands in for "no end", keeping the comparison inside word31type's domain.
    -- The de-registration is matched by CERTIFICATE and only its epoch taken as the end, exactly
    -- as palmares.drep_epoch_delegators does: comparing epochs let an account's own closure end
    -- the interval it had just started.
    LEAST(
      COALESCE(s.next_epoch, 2147483647),
      COALESCE((SELECT min(sd.epoch_no) FROM public.stake_deregistration sd
                WHERE sd.addr_id = s.addr_id
                  AND (sd.tx_id, sd.cert_index) > (s.from_tx, s.from_cert)), 2147483647)
    ) AS to_epoch
  FROM seq s
),
at_epoch AS (
  -- UNION, not UNION ALL. With retention_window_epochs = 0 the two epochs coincide, and UNION ALL
  -- would join every delegator twice: measured, the counters came back doubled (24 for 12
  -- delegators). UNION collapses the degenerate case so "previous" equals "now", which is the
  -- right answer for a zero window and is what makes the parameter testable at all.
  SELECT e.e, l.addr_id
  FROM (
    SELECT (SELECT as_of_epoch FROM p) AS e
    UNION
    SELECT (SELECT as_of_epoch - retention_window_epochs FROM p)
  ) e
  JOIN live l
    ON l.drep_hash_id = (SELECT drep_hash_id FROM p)
   AND l.from_epoch <= e.e
   AND l.to_epoch > e.e
)
SELECT
  count(*) FILTER (WHERE e = (SELECT as_of_epoch FROM p)) AS delegator_count,
  count(*) FILTER (WHERE e = (SELECT as_of_epoch - retention_window_epochs FROM p)) AS delegator_count_prev,
  (SELECT count(*) FROM (
     SELECT addr_id FROM at_epoch WHERE e = (SELECT as_of_epoch FROM p)
     INTERSECT
     SELECT addr_id FROM at_epoch WHERE e = (SELECT as_of_epoch - retention_window_epochs FROM p)) x
  ) AS delegators_retained,
  (SELECT count(*) FROM (
     SELECT addr_id FROM at_epoch WHERE e = (SELECT as_of_epoch FROM p)
     EXCEPT
     SELECT addr_id FROM at_epoch WHERE e = (SELECT as_of_epoch - retention_window_epochs FROM p)) x
  ) AS delegators_joined,
  (SELECT count(*) FROM (
     SELECT addr_id FROM at_epoch WHERE e = (SELECT as_of_epoch - retention_window_epochs FROM p)
     EXCEPT
     SELECT addr_id FROM at_epoch WHERE e = (SELECT as_of_epoch FROM p)) x
  ) AS delegators_left,
  CASE WHEN count(*) FILTER (WHERE e = (SELECT as_of_epoch - retention_window_epochs FROM p)) = 0 THEN NULL
       ELSE (SELECT count(*) FROM (
               SELECT addr_id FROM at_epoch WHERE e = (SELECT as_of_epoch FROM p)
               INTERSECT
               SELECT addr_id FROM at_epoch WHERE e = (SELECT as_of_epoch - retention_window_epochs FROM p)) x
            )::float8
            / count(*) FILTER (WHERE e = (SELECT as_of_epoch - retention_window_epochs FROM p))
  END AS delegator_retention_rate
FROM at_epoch;
```

Spec: docs/superpowers/design/f1-metric-formulas.md#54-delegator_count-delegator_retention_rate-delegators_joinedleft

## Vote latency

| | |
|---|---|
| formula id | `vote_latency_median_hours_v1` |
| response field | `vote_latency_median_hours` |
| version | 1 |
| source | `resources/metrics/vote_latency_median_hours_v1.sql` |

**Expression.** median over eligible voted actions of (first vote time - proposal time) in hours

**Null when.** vote_latency_sample = 0

**Inputs.** `voting_procedure`, `gov_action_proposal`, `block.time`

**Edge cases.**

- the sample is the FIRST vote on each action, while a verdict uses the last
- percentile_cont over an empty set is NULL, and vote_latency_sample is published so a reader can tell no-data from zero-hours
- drawn from the eligible set, so the sample is comparable with participation_rate's denominator

Parameters, in placeholder order: `drep_hash_id`, `as_of_epoch`

```sql
-- vote_latency_median_hours_v1 — how long after a proposal this DRep first votes on it.
--
-- Params: drep_hash_id, as_of_epoch.
--
-- The sample is `seq_first = 1`, the FIRST vote: latency measures how quickly the DRep engaged,
-- while a verdict uses the last vote. Both come off palmares.vote's sequence numbering, so there
-- is no second notion of "which vote" anywhere.
--
-- Drawn from the eligible set, like every other per-DRep metric, so the sample is comparable with
-- participation_rate's denominator.
--
-- percentile_cont over an empty set is NULL, so the "n/a" case needs no special casing — but
-- `vote_latency_sample` is published alongside so a reader can tell "no data" from "zero hours".
WITH p AS (
  SELECT ?::bigint AS drep_hash_id, ?::int AS as_of_epoch
),
elig AS (
  SELECT e.gov_action_id
  FROM p, palmares.eligible_actions(p.drep_hash_id, p.as_of_epoch) e
),
f AS (
  SELECT EXTRACT(EPOCH FROM (v.cast_at - a.proposed_at)) / 3600.0 AS h
  FROM palmares.vote v
  JOIN elig e ON e.gov_action_id = v.gov_action_id
  JOIN palmares.action_window a ON a.gov_action_id = v.gov_action_id
  WHERE v.drep_voter_id = (SELECT drep_hash_id FROM p)
    AND v.seq_first = 1
)
SELECT
  percentile_cont(0.5) WITHIN GROUP (ORDER BY h) AS vote_latency_median_hours,
  percentile_cont(0.9) WITHIN GROUP (ORDER BY h) AS vote_latency_p90_hours,
  count(*) AS vote_latency_sample
FROM f;
```

Spec: docs/superpowers/design/f1-metric-formulas.md#55-vote_latency_median_hours-vote_latency_p90_hours

## Votes by action type

| | |
|---|---|
| formula id | `votes_by_type_v1` |
| response field | `votes_by_type` |
| version | 1 |
| source | `resources/metrics/votes_by_type_v1.sql` |

**Expression.** per action type: votes_cast / eligible_actions

**Denominator.** the eligible set, partitioned by action type

**Null when.** eligible_actions = 0 for that type

**Inputs.** `gov_action_proposal.type`, `voting_procedure`

**Edge cases.**

- all seven action types always appear, even at zero: a missing row reads as no-data while a zero row reads as nothing-to-vote-on
- a new governance action type must be added to the VALUES list in the SQL

Parameters, in placeholder order: `drep_hash_id`, `as_of_epoch`

```sql
-- votes_by_type_v1 — participation broken down by governance action type.
--
-- Params: drep_hash_id, as_of_epoch.
--
-- The VALUES list is what guarantees all seven rows appear even when a DRep was eligible for none
-- of a type: a missing row reads as "no data" in a UI, while a zero row reads as "nothing to vote
-- on", and those are different facts. Any new action type must be added here.
WITH p AS (
  SELECT ?::bigint AS drep_hash_id, ?::int AS as_of_epoch
),
elig AS (
  SELECT e.gov_action_id, e.action_type
  FROM p, palmares.eligible_actions(p.drep_hash_id, p.as_of_epoch) e
),
final AS (
  SELECT v.gov_action_id, v.vote
  FROM palmares.vote v
  WHERE v.drep_voter_id = (SELECT drep_hash_id FROM p)
    AND v.seq_last = 1
)
SELECT
  -- ::text, because action_type is a PostgreSQL enum and a client wants a string. Without the
  -- cast persistent hands back a PersistLiteral that no decoder accepts.
  t.action_type::text AS action_type,
  count(e.gov_action_id) AS eligible_actions,
  count(f.gov_action_id) AS votes_cast,
  count(*) FILTER (WHERE f.vote = 'Yes') AS yes,
  count(*) FILTER (WHERE f.vote = 'No') AS no,
  count(*) FILTER (WHERE f.vote = 'Abstain') AS abstain,
  CASE WHEN count(e.gov_action_id) = 0 THEN NULL
       ELSE count(f.gov_action_id)::float8 / count(e.gov_action_id) END AS participation_rate
FROM (VALUES
  ('ParameterChange'::public.govactiontype),
  ('HardForkInitiation'),
  ('TreasuryWithdrawals'),
  ('NoConfidence'),
  ('NewCommittee'),
  ('NewConstitution'),
  ('InfoAction')
) t(action_type)
LEFT JOIN elig e ON e.action_type = t.action_type
LEFT JOIN final f ON f.gov_action_id = e.gov_action_id
GROUP BY t.action_type;
```

Spec: docs/superpowers/design/f1-metric-formulas.md#56-votes_by_type

## Governance action state

| | |
|---|---|
| formula id | `gov_action_state_v1` |
| response field | `state` |
| version | 1 |
| source | the view `palmares.gov_action` |

**Expression.** enacted_epoch -> enacted; else expired_epoch -> expired; else dropped_epoch -> dropped; else ratified_epoch -> ratified; else proposed

**Inputs.** `gov_action_proposal.ratified_epoch`, `gov_action_proposal.enacted_epoch`, `gov_action_proposal.expired_epoch`, `gov_action_proposal.dropped_epoch`

**Edge cases.**

- the arms are ordered because the columns are not mutually exclusive: an enacted action carries ratified_epoch too, and most expired actions carry dropped_epoch
- state and votability can disagree: an action with expired_epoch = the current epoch is 'expired' while its window is still open, so action_window is the authority for whether a vote is still possible
- dropped_epoch is not an independent outcome; on expiry db-sync sets it to expired_epoch + 1

Spec: docs/superpowers/design/f1-dbsync-data-layer.md

## Vote tally

| | |
|---|---|
| formula id | `tally_cast_votes_v1` |
| response field | `ratio` |
| version | 1 |
| source | the view `palmares.vote_tally` |

**Expression.** yes_power / (yes_power + no_power)

**Denominator.** the power behind the final yes and no votes actually cast; abstentions are excluded

**Null when.** yes_power + no_power = 0

**Inputs.** `voting_procedure`, `drep_distr`, `pool_stat.voting_power`, `epoch_param`

**Edge cases.**

- basis = 'cast_votes_only' is published as a column: this is NOT the ledger's ratification arithmetic, which compares against total active voting power
- abstain removes stake from the question rather than voting no, which is why it is out of the denominator
- committee rows carry counts and zero power: the committee ratifies by member quorum and holds no stake
- ParameterChange has no single DRep threshold: it is a maximum over the parameter groups the proposal touches

Spec: docs/superpowers/design/f1-metric-formulas.md#33-spo-on-parameterchange-the-securitygroup-test

