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
