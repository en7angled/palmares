-- palmares views over db-sync's public schema; objects appended by later tasks.

-- ---------------------------------------------------------------------------------------------
-- palmares.eligible_actions(drep_hash_id, as_of_epoch) — the actions a DRep COULD have voted on.
--
-- A function rather than a view, and a function rather than a CTE copy-pasted into each metric:
-- this set is the denominator of participation_rate, of rationale_rate and of several more, and
-- the surest way to make those numbers disagree is to re-derive the set per metric.
--
-- Eligibility is three conditions and deliberately NOT a fourth:
--   1. the DRep's registration overlaps the action's window (drep_interval, which is why
--      retire-then-re-register keeps the earlier votes countable);
--   2. the action was DRep-votable at all (the Conway bootstrap test, computed once in
--      action_window);
--   3. the action is SETTLED as of `as_of_epoch` — a still-open action is not yet a missed vote.
-- The fourth, membership in `drep_distr`, is explicitly excluded (D-2): drep_distr is the stake
-- distribution, and a registered DRep with zero delegated stake is still eligible to vote. Using
-- it would silently drop every small DRep out of its own denominator.
--
-- GROUP BY both columns because a DRep may hold several intervals and an action may overlap more
-- than one of them; without it, a re-registered DRep's denominator would double-count.
--
-- STABLE, not IMMUTABLE: it reads tables. LANGUAGE sql so the planner can inline it.
CREATE FUNCTION palmares.eligible_actions(drep_hash_id bigint, as_of_epoch int)
RETURNS TABLE (gov_action_id bigint, action_type public.govactiontype)
LANGUAGE sql
STABLE
AS $$
  SELECT a.gov_action_id, a.action_type
  FROM palmares.action_window a
  JOIN palmares.drep_interval i
    ON i.drep_hash_id = eligible_actions.drep_hash_id
   AND i.from_epoch <= a.last_votable_epoch
   AND (i.to_epoch IS NULL OR i.to_epoch >= a.proposed_epoch)
  WHERE a.last_votable_epoch < eligible_actions.as_of_epoch
    AND a.drep_votable
  GROUP BY a.gov_action_id, a.action_type;
$$;
