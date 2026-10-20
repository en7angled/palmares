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
