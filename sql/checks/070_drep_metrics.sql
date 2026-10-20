-- Checks for palmares.drep_metrics against a caught-up preprod db-sync (tip epoch >= 320).
-- Prerequisite: sql/indexes/001_gov_indexes.sql, and the matview must have been built by
-- sql/030_metrics.sql. MEASURED at about 4 seconds, the matview build included.
--
-- WHAT THIS FILE DOES NOT ASSERT: magnitudes. Every number in the matview is "as of the tip
-- epoch", so a frozen eligible_actions = 114 would be wrong the moment the next epoch closes.
-- The earlier check files could cut their counts at `epoch < 320` and be immutable; this one
-- cannot, because the matview has no epoch parameter to cut on — it has one row per DRep, at the
-- tip. So the assertions here are the INVARIANTS, which hold at every epoch, plus one agreement
-- test against the published catalog SQL, which is what would actually catch a formula drift.
-- The live magnitudes go out through RAISE NOTICE, where they inform without pinning.
--
-- The magnitude pins live in test/fixtures/preprod-epoch-320-metrics.json, against a CLOSED
-- epoch, which is where a pin can be stable.
DO $$
DECLARE
  n_rows bigint;
  n_dreps bigint;
  d bigint;
  m_part record;
  c_part record;
  m_age numeric;
  c_age numeric;
BEGIN
  SELECT count(*) INTO n_rows FROM palmares.drep_metrics;
  SELECT count(*) INTO n_dreps FROM public.drep_hash WHERE raw IS NOT NULL;

  -- The no-fan-out invariant every check file in this directory opens with. One row per real DRep
  -- credential: more means a join fanned out, fewer means a LEFT JOIN was written as an inner one
  -- and silently dropped the DReps with nothing to report — which is most of them.
  ASSERT n_rows = n_dreps,
    format('drep_metrics must be one row per DRep credential: %s rows for %s credentials', n_rows, n_dreps);

  -- The reserved ledger options are not DReps and must not have rows here, however the
  -- unfiltered palmares.drep_epoch_power carries them.
  ASSERT (SELECT count(*) FROM palmares.drep_metrics WHERE drep_raw IS NULL) = 0;

  -- D-3: the five grades partition the final votes, so they sum to votes_cast for EVERY row. This
  -- is the assertion that catches a rationale grade silently falling outside the CASE.
  ASSERT (SELECT count(*) FROM palmares.drep_metrics
          WHERE rationale_verified + rationale_inline + rationale_unverified
              + rationale_pending  + rationale_absent <> votes_cast) = 0,
    'the five rationale grades must sum to votes_cast';

  -- 3.8, in both directions. A rate of 0 where the answer is "n/a" is a false statement about a
  -- person, and a NULL where the answer is a real 0% hides a genuine non-voter.
  ASSERT (SELECT count(*) FROM palmares.drep_metrics
          WHERE (eligible_actions = 0) <> (participation_rate IS NULL)) = 0,
    'participation_rate must be NULL exactly when eligible_actions = 0';
  ASSERT (SELECT count(*) FROM palmares.drep_metrics
          WHERE (rationale_verified + rationale_inline + rationale_absent = 0)
            <> (rationale_rate IS NULL)) = 0,
    'rationale_rate must be NULL exactly when nothing could be assessed';
  ASSERT (SELECT count(*) FROM palmares.drep_metrics
          WHERE (vote_latency_sample = 0) <> (vote_latency_median_hours IS NULL)) = 0,
    'vote latency must be NULL exactly when the sample is empty';
  -- age_days is NULL exactly for the credentials that never registered: those exist in drep_hash
  -- only because something delegated to them, so they have no interval to sum. 7 on preprod.
  ASSERT (SELECT count(*) FROM palmares.drep_metrics m
          JOIN palmares.drep d2 USING (drep_hash_id)
          WHERE (m.age_days IS NULL) <> (d2.registration_status = 'never_registered')) = 0,
    'age_days must be NULL exactly for never-registered credentials';

  -- votes_cast comes from count(DISTINCT gov_action_id) for this reason: a DRep may vote several
  -- times on one action, and counting rows would publish a participation rate above 100%.
  ASSERT (SELECT count(*) FROM palmares.drep_metrics WHERE votes_cast > eligible_actions) = 0,
    'votes_cast cannot exceed eligible_actions';
  ASSERT (SELECT count(*) FROM palmares.drep_metrics
          WHERE participation_rate < 0 OR participation_rate > 1
             OR rationale_rate < 0 OR rationale_rate > 1) = 0;

  -- Every row is measured at ONE epoch, and the voting power at ONE distribution epoch. Without
  -- this, a DRep whose last drep_distr row is from epoch 180 would be listed beside one measured
  -- at 320 and its stale stake called its current voting power.
  ASSERT (SELECT count(DISTINCT as_of_epoch) FROM palmares.drep_metrics) = 1,
    'the whole matview must share one as_of_epoch';
  ASSERT (SELECT count(DISTINCT voting_power_epoch) FROM palmares.drep_metrics) = 1,
    'the whole matview must share one voting_power_epoch';

  -- CONCURRENTLY needs the unique index; assert it rather than discovering it at runtime.
  ASSERT (SELECT count(*) FROM pg_indexes
          WHERE schemaname = 'palmares' AND indexname = 'palmares_idx_drep_metrics_pk') = 1;
  ASSERT (SELECT count(*) FROM pg_indexes
          WHERE schemaname = 'palmares'
            AND indexname IN ('palmares_idx_drep_metrics_part',
                              'palmares_idx_drep_metrics_power',
                              'palmares_idx_drep_metrics_raw')) = 3;

  -- -------------------------------------------------------------------------------------------
  -- AGREEMENT WITH THE PUBLISHED FORMULAS. The matview is a second implementation of the same
  -- arithmetic, batched over all DReps; resources/metrics/*.sql is the one docs/metrics.md is
  -- generated from. If they diverge, the documented formula is not the served number.
  --
  -- The parameters are inlined here because psql cannot bind a `?`. That is the point of the
  -- file: an independent re-derivation, not a shared helper.
  SELECT id INTO d FROM public.drep_hash
    WHERE raw = decode('81378d3ea89b68f0fc09944b1f93f2feb851318f196f98ba4029d8a8','hex');
  ASSERT d IS NOT NULL, 'the pinned DRep is missing: is this database preprod?';

  SELECT eligible_actions, votes_cast, participation_rate, open_actions_unvoted,
         rationale_verified, rationale_inline, rationale_unverified, rationale_pending,
         rationale_absent, rationale_rate, vote_latency_median_hours, vote_latency_p90_hours,
         vote_latency_sample, as_of_epoch
    INTO m_part
    FROM palmares.drep_metrics WHERE drep_hash_id = d;

  WITH elig AS (
    SELECT e.gov_action_id FROM palmares.eligible_actions(d, m_part.as_of_epoch) e
  ),
  voted AS (
    SELECT DISTINCT v.gov_action_id FROM palmares.vote v
    JOIN elig e ON e.gov_action_id = v.gov_action_id WHERE v.drep_voter_id = d
  ),
  final AS (
    SELECT v.gov_action_id, v.voting_anchor_id FROM palmares.vote v
    JOIN elig e ON e.gov_action_id = v.gov_action_id
    WHERE v.drep_voter_id = d AND v.seq_last = 1
  ),
  graded AS (
    SELECT CASE
             WHEN f.voting_anchor_id IS NULL THEN 'absent'
             WHEN a.verdict = 'inline' THEN 'inline'
             WHEN a.verdict = 'valid' THEN 'verified'
             WHEN a.verdict = 'not_fetched' THEN 'pending'
             ELSE 'unverified'
           END AS grade
    FROM final f LEFT JOIN palmares.anchor a ON a.voting_anchor_id = f.voting_anchor_id
  ),
  lat AS (
    SELECT EXTRACT(EPOCH FROM (v.cast_at - w.proposed_at)) / 3600.0 AS h
    FROM palmares.vote v
    JOIN elig e ON e.gov_action_id = v.gov_action_id
    JOIN palmares.action_window w ON w.gov_action_id = v.gov_action_id
    WHERE v.drep_voter_id = d AND v.seq_first = 1
  )
  SELECT
    (SELECT count(*) FROM elig) AS eligible_actions,
    (SELECT count(*) FROM voted) AS votes_cast,
    (SELECT count(*) FROM voted)::float8 / NULLIF((SELECT count(*) FROM elig), 0) AS participation_rate,
    (SELECT count(*) FROM palmares.action_window a
      WHERE a.last_votable_epoch >= m_part.as_of_epoch AND a.drep_votable
        AND NOT EXISTS (SELECT 1 FROM palmares.vote v
                         WHERE v.drep_voter_id = d AND v.gov_action_id = a.gov_action_id)) AS open_actions_unvoted,
    (SELECT count(*) FROM graded WHERE grade = 'verified') AS rationale_verified,
    (SELECT count(*) FROM graded WHERE grade = 'inline') AS rationale_inline,
    (SELECT count(*) FROM graded WHERE grade = 'unverified') AS rationale_unverified,
    (SELECT count(*) FROM graded WHERE grade = 'pending') AS rationale_pending,
    (SELECT count(*) FROM graded WHERE grade = 'absent') AS rationale_absent,
    (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY h) FROM lat) AS vote_latency_median_hours,
    (SELECT percentile_cont(0.9) WITHIN GROUP (ORDER BY h) FROM lat) AS vote_latency_p90_hours,
    (SELECT count(*) FROM lat) AS vote_latency_sample
    INTO c_part;

  ASSERT m_part.eligible_actions = c_part.eligible_actions,
    format('eligible_actions: matview %s, formula %s', m_part.eligible_actions, c_part.eligible_actions);
  ASSERT m_part.votes_cast = c_part.votes_cast,
    format('votes_cast: matview %s, formula %s', m_part.votes_cast, c_part.votes_cast);
  ASSERT m_part.participation_rate = c_part.participation_rate;
  ASSERT m_part.open_actions_unvoted = c_part.open_actions_unvoted,
    format('open_actions_unvoted: matview %s, formula %s', m_part.open_actions_unvoted, c_part.open_actions_unvoted);
  ASSERT m_part.rationale_verified = c_part.rationale_verified
     AND m_part.rationale_inline = c_part.rationale_inline
     AND m_part.rationale_unverified = c_part.rationale_unverified
     AND m_part.rationale_pending = c_part.rationale_pending
     AND m_part.rationale_absent = c_part.rationale_absent,
    'the rationale grades must match the formula';
  ASSERT m_part.vote_latency_median_hours = c_part.vote_latency_median_hours
     AND m_part.vote_latency_p90_hours = c_part.vote_latency_p90_hours
     AND m_part.vote_latency_sample = c_part.vote_latency_sample,
    'the latency percentiles must match the formula';

  -- age_days is the one metric that cannot be asserted equal, and the reason is the matview's
  -- whole purpose: the formula reads max(block.time) LIVE, the matview froze it at its last
  -- refresh, and the chain moved in between. The invariant is therefore directional — a snapshot
  -- of the past can only be younger — with a bound far wider than any refresh interval but far
  -- narrower than a formula error, which would be off by epochs or by a whole interval.
  SELECT age_days INTO m_age FROM palmares.drep_metrics WHERE drep_hash_id = d;
  SELECT GREATEST(0, SUM(EXTRACT(EPOCH FROM (
           LEAST(COALESCE(r.retire_time, c.t), c.t) - i.from_time)))) / 86400
    INTO c_age
    FROM palmares.drep_interval i
    CROSS JOIN (SELECT max(b.time) AS t FROM public.block b
                 WHERE b.epoch_no <= m_part.as_of_epoch) c
    LEFT JOIN LATERAL (
      SELECT b2.time AS retire_time FROM public.drep_registration r2
      JOIN public.tx t2 ON t2.id = r2.tx_id
      JOIN public.block b2 ON b2.id = t2.block_id
      WHERE r2.drep_hash_id = i.drep_hash_id AND r2.deposit < 0 AND b2.slot_no > i.from_slot
      ORDER BY b2.slot_no LIMIT 1
    ) r ON TRUE
    WHERE i.drep_hash_id = d;
  ASSERT m_age <= c_age AND c_age - m_age < 1.0,
    format('age_days must trail the live formula by less than a day: matview %s, formula %s', m_age, c_age);

  RAISE NOTICE 'drep_metrics ok: % rows at epoch %, % with an eligible action, % that have voted, % active; pinned DRep %/% actions (%)',
    n_rows, m_part.as_of_epoch,
    (SELECT count(*) FROM palmares.drep_metrics WHERE eligible_actions > 0),
    (SELECT count(*) FROM palmares.drep_metrics WHERE votes_cast > 0),
    (SELECT count(*) FROM palmares.drep_metrics WHERE is_active),
    m_part.votes_cast, m_part.eligible_actions, round(m_part.participation_rate::numeric, 6);
END $$;

-- Outside the DO block, and outside any transaction: PreventInTransactionBlock rejects
-- CONCURRENTLY "from a function or multi-command string", which a DO body is. This is the same
-- call Query/Refresh.hs makes, so running it here is the check that a deployed refresh will work.
REFRESH MATERIALIZED VIEW CONCURRENTLY palmares.drep_metrics;
