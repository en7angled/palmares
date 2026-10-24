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
  -- The registration interval is required here, the same overlap test `elig` above applies through
  -- palmares.eligible_actions. Without it every credential in the table reported every open action
  -- as outstanding — including the 523 retired ones, which cannot legally vote on any of them, and
  -- which were therefore served `eligible_actions: 0` beside `open_actions_unvoted: 11`.
  SELECT a.gov_action_id
  FROM palmares.action_window a
  WHERE a.last_votable_epoch >= (SELECT as_of_epoch FROM p)
    AND a.drep_votable
    AND EXISTS (
      SELECT 1 FROM palmares.drep_interval i
      WHERE i.drep_hash_id = (SELECT drep_hash_id FROM p)
        AND i.from_epoch <= a.last_votable_epoch
        AND (i.to_epoch IS NULL OR i.to_epoch >= a.proposed_epoch)
    )
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
