-- palmares views over db-sync's public schema; objects appended by later tasks.
--
-- ---------------------------------------------------------------------------------------------
-- palmares.drep_metrics — one of the TWO materialized views in this schema.
--
-- Everything else in `palmares` is a plain view, because a view cannot go stale and needs no
-- refresh thread to maintain. This one is materialized because it costs a full pass over
-- public.voting_procedure (3.2M rows on preprod) per read, and it is the object the DRep list and
-- the DRep detail page both hit. The other is `palmares.vote_partition` in 020_views.sql, which
-- pre-aggregates palmares.vote's window partitions; its header has the measurement that justifies
-- it. Both are refreshed by the same thread, on the same tick, into the same staleness window:
-- Query/Refresh.hs.
--
-- WHY THE SHAPE IS "ONE CTE PER METRIC, JOINED AT THE END", and not "a LATERAL per DRep":
-- palmares.vote computes three window functions partitioned by (voter_role, voter_id_hash,
-- gov_action_id). A WHERE on voter_role cannot be pushed below a window function, so every
-- reference to palmares.vote costs the whole 3.2M-row pass. Calling it inside a LATERAL would
-- pay that cost once per DRep — 812 times on preprod. The `dv` CTE below pays it ONCE.
-- palmares.eligible_actions, by contrast, reads 131 action_window rows and that DRep's intervals,
-- so it IS called per DRep: that keeps the eligibility rule in exactly one place (D-15) at a cost
-- that does not show up in the measurement.
--
-- MEASURED: the whole statement plus its four indexes builds in 3.1 s over preprod's 3.2 M
-- voting_procedure rows, because `voter_role` appears in the PARTITION BY of all three of
-- palmares.vote's window functions and PostgreSQL will push a qual below a WindowAgg exactly in
-- that case (qual_is_pushdown_safe). So `dv` never materializes the 3.2 M-row pass at all -- it
-- scans the ~1,400 DRep votes. That is a property of the view's partitioning, not luck: a window
-- partitioned by anything that does not include voter_role would silently turn this into minutes.
--
-- EVERY NUMBER HERE MUST AGREE WITH resources/metrics/*.sql. Those files are the published
-- formulas — docs/metrics.md is generated from them and the epoch-319 fixture pins their output.
-- This view is a second implementation of the same arithmetic, batched over all DReps, so
-- sql/checks/070_drep_metrics.sql exists to assert the two agree. When a formula changes, change
-- the catalog statement first, then this view, then re-run that check.
--
-- Counters COALESCE to 0 and rates stay NULL. A DRep with nothing it could have voted on has no
-- participation rate; publishing 0% there would be a different and false statement (3.8).
--
-- An empty public.block yields ZERO rows here rather than 812 rows of nulls: with no tip there is
-- no as_of_epoch, and every metric in the view is "as of" that epoch. That is also what makes the
-- CI skeleton test meaningful — the matview is created and populated, it just has nothing to say.
CREATE MATERIALIZED VIEW palmares.drep_metrics AS
WITH s AS (
  SELECT epoch_no, tip_time, drep_distr_epoch FROM palmares.sync_state
),
dv AS (
  -- The single pass over palmares.vote. DRep rows only; the sequence numbers come from the view
  -- so there is no second notion of "which vote is final" anywhere in the codebase.
  SELECT
    v.drep_voter_id,
    v.gov_action_id,
    v.voting_anchor_id,
    v.cast_at,
    v.vote_epoch,
    v.vote_slot,
    v.tx_index,
    v.vote_index,
    v.seq_first,
    v.seq_last
  FROM palmares.vote v
  WHERE v.voter_role = 'DRep'
),
elig AS (
  -- The denominator, per DRep: palmares.eligible_actions, never a re-derivation of it.
  SELECT d.drep_hash_id, e.gov_action_id
  FROM palmares.drep d
  CROSS JOIN s
  CROSS JOIN LATERAL palmares.eligible_actions(d.drep_hash_id, s.epoch_no) e
),
part AS (
  SELECT
    e.drep_hash_id,
    -- DISTINCT on BOTH aggregates, and the denominator is the one that was wrong (GV-03/DC-01).
    -- The LEFT JOIN below fans out to one row per VOTE, so for an action with n re-votes this
    -- group holds max(1, n) rows: `count(*)` published E + X, where X is the excess re-vote rows
    -- (preprod: X >= 69, worst single action voted 20 times). participation_rate was therefore
    -- understated and eligible_actions overstated for every DRep that ever changed a vote —
    -- the rate was held under 100% by inflating its denominator rather than by deduplicating it.
    count(DISTINCT e.gov_action_id) AS eligible_actions,
    count(DISTINCT v.gov_action_id) AS votes_cast
  FROM elig e
  LEFT JOIN dv v
    ON v.drep_voter_id = e.drep_hash_id
   AND v.gov_action_id = e.gov_action_id
  GROUP BY e.drep_hash_id
),
graded AS (
  -- The five rationale grades of rationale_rate_v1, on the final vote of each eligible action.
  SELECT
    e.drep_hash_id,
    CASE
      WHEN v.voting_anchor_id IS NULL THEN 'absent'
      WHEN a.verdict = 'inline' THEN 'inline'
      WHEN a.verdict = 'valid' THEN 'verified'
      WHEN a.verdict = 'not_fetched' THEN 'pending'
      ELSE 'unverified'
    END AS grade,
    a.cip100_valid
  FROM elig e
  JOIN dv v
    ON v.drep_voter_id = e.drep_hash_id
   AND v.gov_action_id = e.gov_action_id
   AND v.seq_last = 1
  LEFT JOIN palmares.anchor a ON a.voting_anchor_id = v.voting_anchor_id
),
rat AS (
  SELECT
    g.drep_hash_id,
    count(*) FILTER (WHERE grade = 'verified') AS rationale_verified,
    count(*) FILTER (WHERE grade = 'inline') AS rationale_inline,
    count(*) FILTER (WHERE grade = 'unverified') AS rationale_unverified,
    count(*) FILTER (WHERE grade = 'pending') AS rationale_pending,
    count(*) FILTER (WHERE grade = 'absent') AS rationale_absent,
    count(*) FILTER (WHERE cip100_valid IS TRUE) AS rationale_cip100_valid,
    -- The denominator excludes what could not be assessed: unverified and pending are out of
    -- BOTH sides. See resources/metrics/rationale_rate_v1.sql for the measurement that decided
    -- this — on preprod, dividing by votes_cast would publish our indexer's inability to fetch
    -- ipfs:// as 36 authors' negligence.
    CASE WHEN count(*) FILTER (WHERE grade IN ('verified', 'inline', 'absent')) = 0 THEN NULL
         ELSE count(*) FILTER (WHERE grade IN ('verified', 'inline'))::float8
              / count(*) FILTER (WHERE grade IN ('verified', 'inline', 'absent')) END AS rationale_rate
  FROM graded g
  GROUP BY g.drep_hash_id
),
lat AS (
  -- percentile_cont, not percentile_disc: the median of an even-sized sample is interpolated.
  -- The sample is seq_first = 1, the FIRST vote on each eligible action.
  SELECT
    e.drep_hash_id,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (v.cast_at - w.proposed_at)) / 3600.0)
      AS vote_latency_median_hours,
    percentile_cont(0.9) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (v.cast_at - w.proposed_at)) / 3600.0)
      AS vote_latency_p90_hours,
    count(*) AS vote_latency_sample
  FROM elig e
  JOIN dv v
    ON v.drep_voter_id = e.drep_hash_id
   AND v.gov_action_id = e.gov_action_id
   AND v.seq_first = 1
  JOIN palmares.action_window w ON w.gov_action_id = e.gov_action_id
  GROUP BY e.drep_hash_id
),
age AS (
  -- age_days_v1's interval sum, against the tip rather than against an arbitrary epoch cursor:
  -- sync_state.tip_time IS max(block.time) for epoch_no <= the tip epoch, so this is the same
  -- cursor the catalog statement uses with as_of_epoch = the tip epoch.
  SELECT
    i.drep_hash_id,
    GREATEST(0, SUM(EXTRACT(EPOCH FROM (
      LEAST(COALESCE(r.retire_time, s.tip_time), s.tip_time) - i.from_time
    )))) / 86400 AS age_days
  FROM palmares.drep_interval i
  CROSS JOIN s
  LEFT JOIN LATERAL (
    -- Bounded by slot, not epoch: register-retire-re-register inside one epoch is legal and the
    -- epoch form would pick up the earlier retirement and contribute a negative term.
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
  GROUP BY i.drep_hash_id
),
power AS (
  -- One epoch for everybody: the latest epoch for which the ledger produced a distribution. A
  -- per-DRep "latest row" would compare a DRep measured at epoch 320 against one whose last row
  -- is from epoch 180, and call the second one's stale stake its current voting power.
  SELECT p.drep_hash_id, p.amount
  FROM palmares.drep_epoch_power p
  CROSS JOIN s
  WHERE p.target_kind = 'drep'
    AND p.epoch_no = s.drep_distr_epoch
),
deleg AS (
  SELECT l.drep_hash_id, count(*) AS delegator_count
  FROM palmares.live_delegation l
  GROUP BY l.drep_hash_id
),
open_actions AS (
  -- The window bounds travel with the id, because `open_unvoted` below needs them for the same
  -- registration-interval overlap test `palmares.eligible_actions` applies.
  SELECT a.gov_action_id, a.proposed_epoch, a.last_votable_epoch
  FROM palmares.action_window a
  CROSS JOIN s
  WHERE a.last_votable_epoch >= s.epoch_no
    AND a.drep_votable
),
open_unvoted AS (
  -- Reported separately from participation, and deliberately NOT subtracted from it: a still-open
  -- action is not a missed vote, it is a vote not yet due.
  --
  -- __The registration interval is required here, exactly as `palmares.eligible_actions` requires
  -- it.__ Without it this counted every open action for every credential in `palmares.drep`, so all
  -- 824 reported 11 outstanding actions — including 523 retired and 7 never-registered ones, 64% of
  -- the table, that cannot legally vote on any of them. A DRep that retired in epoch 163 was served
  -- `eligible_actions: 0` beside `open_actions_unvoted: 11`, which reads as a DRep ignoring its
  -- duties 158 epochs after it left. The same omission is in the published formula, so the two
  -- agreed with each other and both were wrong.
  SELECT d.drep_hash_id, count(*) AS open_actions_unvoted
  FROM palmares.drep d
  CROSS JOIN open_actions o
  WHERE EXISTS (
      SELECT 1 FROM palmares.drep_interval i
      WHERE i.drep_hash_id = d.drep_hash_id
        AND i.from_epoch <= o.last_votable_epoch
        AND (i.to_epoch IS NULL OR i.to_epoch >= o.proposed_epoch)
    )
    AND NOT EXISTS (
      SELECT 1 FROM dv v
      WHERE v.drep_voter_id = d.drep_hash_id
        AND v.gov_action_id = o.gov_action_id
    )
  GROUP BY d.drep_hash_id
),
last_vote AS (
  -- Ungated by eligibility on purpose: "when did this DRep last vote" should count a vote on a
  -- still-open action, which the eligible set excludes.
  SELECT DISTINCT ON (v.drep_voter_id)
    v.drep_voter_id, v.cast_at, v.vote_epoch
  FROM dv v
  ORDER BY v.drep_voter_id, v.vote_slot DESC, v.tx_index DESC, v.vote_index DESC
)
SELECT
  d.drep_hash_id,
  d.drep_raw,
  d.has_script,
  COALESCE(part.eligible_actions, 0) AS eligible_actions,
  COALESCE(part.votes_cast, 0) AS votes_cast,
  CASE WHEN COALESCE(part.eligible_actions, 0) = 0 THEN NULL
       ELSE part.votes_cast::float8 / part.eligible_actions END AS participation_rate,
  COALESCE(rat.rationale_verified, 0) AS rationale_verified,
  COALESCE(rat.rationale_inline, 0) AS rationale_inline,
  COALESCE(rat.rationale_unverified, 0) AS rationale_unverified,
  COALESCE(rat.rationale_pending, 0) AS rationale_pending,
  COALESCE(rat.rationale_absent, 0) AS rationale_absent,
  COALESCE(rat.rationale_cip100_valid, 0) AS rationale_cip100_valid,
  rat.rationale_rate,
  lat.vote_latency_median_hours,
  lat.vote_latency_p90_hours,
  COALESCE(lat.vote_latency_sample, 0) AS vote_latency_sample,
  age.age_days,
  -- Zero, not null: a registered DRep absent from drep_distr has no delegated stake, which the
  -- ledger states by leaving it out. 101 of preprod's 294 registered DReps are in that position.
  COALESCE(power.amount, 0) AS voting_power,
  s.drep_distr_epoch AS voting_power_epoch,
  COALESCE(deleg.delegator_count, 0) AS delegator_count,
  COALESCE(open_unvoted.open_actions_unvoted, 0) AS open_actions_unvoted,
  d.is_active,
  d.active_until_epoch,
  last_vote.cast_at AS last_vote_at,
  last_vote.vote_epoch AS last_vote_epoch,
  s.epoch_no AS as_of_epoch
FROM palmares.drep d
CROSS JOIN s
LEFT JOIN part ON part.drep_hash_id = d.drep_hash_id
LEFT JOIN rat ON rat.drep_hash_id = d.drep_hash_id
LEFT JOIN lat ON lat.drep_hash_id = d.drep_hash_id
LEFT JOIN age ON age.drep_hash_id = d.drep_hash_id
LEFT JOIN power ON power.drep_hash_id = d.drep_hash_id
LEFT JOIN deleg ON deleg.drep_hash_id = d.drep_hash_id
LEFT JOIN open_unvoted ON open_unvoted.drep_hash_id = d.drep_hash_id
LEFT JOIN last_vote ON last_vote.drep_voter_id = d.drep_hash_id
WITH DATA;

-- UNIQUE, and on the key the matview is keyed by: REFRESH MATERIALIZED VIEW CONCURRENTLY refuses
-- to run without a unique index, and CONCURRENTLY is what keeps reads served during a refresh.
CREATE UNIQUE INDEX palmares_idx_drep_metrics_pk ON palmares.drep_metrics (drep_hash_id);

-- The three orderings the DRep list offers. NULLS LAST on the rate so "n/a" sorts after 0%
-- rather than above 100%.
CREATE INDEX palmares_idx_drep_metrics_part ON palmares.drep_metrics (participation_rate DESC NULLS LAST);
CREATE INDEX palmares_idx_drep_metrics_power ON palmares.drep_metrics (voting_power DESC);
CREATE INDEX palmares_idx_drep_metrics_raw ON palmares.drep_metrics (drep_raw);
