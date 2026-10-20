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

-- ---------------------------------------------------------------------------------------------
-- palmares.drep_epoch_delegators — delegator count per DRep per epoch.
--
-- Built from delegation INTERVALS rather than from a per-epoch snapshot table, because db-sync
-- has no such table for vote delegation: `drep_distr` carries the stake, not the head count.
-- An interval runs from the certificate's epoch until either the next certificate for that
-- address or the credential's de-registration, whichever comes first.
--
-- ponytail: a view, not a materialized view. It cross-joins intervals with an epoch series, so it
-- is O(addresses x epochs) at read time. Promote it to a matview only if /drep/{id} or
-- /drep/{id}/power measures over 500 ms p95 on preprod — not before, because a matview adds a
-- refresh thread and a staleness window to maintain.
CREATE VIEW palmares.drep_epoch_delegators AS
WITH seq AS (
  SELECT
    dv.addr_id,
    dv.drep_hash_id,
    b.epoch_no AS from_epoch,
    LEAD(b.epoch_no) OVER w AS next_epoch
  FROM public.delegation_vote dv
  JOIN public.tx ON tx.id = dv.tx_id
  JOIN public.block b ON b.id = tx.block_id
  WINDOW w AS (PARTITION BY dv.addr_id ORDER BY b.slot_no, tx.block_index, dv.cert_index)
),
intervals AS (
  SELECT
    s.addr_id,
    s.drep_hash_id,
    s.from_epoch,
    -- 2147483647 stands in for "no end", which keeps the comparison inside word31type's domain.
    LEAST(
      COALESCE(s.next_epoch, 2147483647),
      COALESCE((SELECT min(sd.epoch_no) FROM public.stake_deregistration sd
                WHERE sd.addr_id = s.addr_id AND sd.epoch_no >= s.from_epoch), 2147483647)
    ) AS to_epoch
  FROM seq s
),
epochs AS (
  SELECT generate_series(
           (SELECT min(epoch_no) FROM public.drep_distr),
           (SELECT epoch_no FROM palmares.sync_state)
         ) AS epoch_no
)
SELECT
  i.drep_hash_id,
  e.epoch_no,
  count(*) AS delegator_count
FROM intervals i
JOIN epochs e ON i.from_epoch <= e.epoch_no AND i.to_epoch > e.epoch_no
GROUP BY i.drep_hash_id, e.epoch_no;

-- ---------------------------------------------------------------------------------------------
-- palmares.vote_tally — one row per (action, voter role), over FINAL votes only.
--
-- `basis = 'cast_votes_only'` is a column rather than a comment because the alternative basis is
-- a different number entirely: the ledger compares yes-power against the total ACTIVE voting
-- power, so a "ratio" computed over cast votes is not the ratification arithmetic and must never
-- be presented as if it were. Publishing the basis makes the choice legible to a client instead
-- of implicit in our SQL.
--
-- `ratio` excludes abstentions from the denominator (`yes / (yes + no)`), which matches how
-- abstain is treated in ratification: it removes stake from the question rather than voting no.
-- NULLIF keeps it NULL rather than a division error when nobody voted yes or no.
--
-- Power per role:
--   DRep  `drep_epoch_power` at the action's last votable epoch, real DReps only — the two
--         pseudo-DRep options are not voters, they are standing instructions.
--   SPO   `pool_stat.voting_power` at the same epoch. MEASURED: the table is populated under
--         `preset: only_governance` + `shelley: enable: true` (99,872 rows, voting_power non-null
--         from epoch 163 with only 1-2 pools per epoch missing), which answers the plan's open
--         question. A missing row means the ledger recorded no voting power for that pool that
--         epoch, which is 0 for tally purposes.
--   CC    0. The committee ratifies by member quorum; it holds no stake, so 0 is the honest
--         number here rather than NULL.
CREATE VIEW palmares.vote_tally AS
WITH final_votes AS (
  SELECT
    v.gov_action_id,
    v.voter_role,
    v.voter_id_hash,
    v.voter_hot_hash,
    v.vote,
    a.last_votable_epoch,
    a.action_type
  FROM palmares.vote v
  JOIN palmares.action_window a ON a.gov_action_id = v.gov_action_id
  WHERE v.seq_last = 1
),
weighted AS (
  SELECT
    f.*,
    CASE f.voter_role
      WHEN 'DRep' THEN COALESCE((
        SELECT p.amount FROM palmares.drep_epoch_power p
        WHERE p.target_kind = 'drep'
          AND p.drep_raw = f.voter_hot_hash
          AND p.epoch_no = f.last_votable_epoch), 0)
      WHEN 'SPO' THEN COALESCE((
        SELECT ps.voting_power FROM public.pool_stat ps
        JOIN public.pool_hash ph ON ph.id = ps.pool_hash_id
        WHERE ph.hash_raw = f.voter_hot_hash
          AND ps.epoch_no = f.last_votable_epoch), 0)
      ELSE 0
    END AS power
  FROM final_votes f
)
SELECT
  w.gov_action_id,
  w.voter_role,
  w.last_votable_epoch AS epoch,
  sum(w.power) FILTER (WHERE w.vote = 'Yes') AS yes_power,
  sum(w.power) FILTER (WHERE w.vote = 'No') AS no_power,
  sum(w.power) FILTER (WHERE w.vote = 'Abstain') AS abstain_power,
  count(*) FILTER (WHERE w.vote = 'Yes') AS yes_count,
  count(*) FILTER (WHERE w.vote = 'No') AS no_count,
  count(*) FILTER (WHERE w.vote = 'Abstain') AS abstain_count,
  sum(w.power) FILTER (WHERE w.vote = 'Yes')
    / NULLIF(sum(w.power) FILTER (WHERE w.vote = 'Yes') + sum(w.power) FILTER (WHERE w.vote = 'No'), 0) AS ratio,
  -- The threshold in force at the epoch the action's window closed, looked up through the static
  -- map so the parameter name travels with the number. NULL where no threshold applies, which
  -- includes ParameterChange/DRep: that one is a maximum over the parameter groups the proposal
  -- touches, so it needs a second mapping nobody has asked for yet.
  CASE m.threshold_param
    WHEN 'dvt_motion_no_confidence' THEN th.dvt_motion_no_confidence
    WHEN 'dvt_committee_normal' THEN th.dvt_committee_normal
    WHEN 'dvt_committee_no_confidence' THEN th.dvt_committee_no_confidence
    WHEN 'dvt_update_to_constitution' THEN th.dvt_update_to_constitution
    WHEN 'dvt_hard_fork_initiation' THEN th.dvt_hard_fork_initiation
    WHEN 'dvt_treasury_withdrawal' THEN th.dvt_treasury_withdrawal
    WHEN 'pvt_motion_no_confidence' THEN th.pvt_motion_no_confidence
    WHEN 'pvt_committee_normal' THEN th.pvt_committee_normal
    WHEN 'pvt_committee_no_confidence' THEN th.pvt_committee_no_confidence
    WHEN 'pvt_hard_fork_initiation' THEN th.pvt_hard_fork_initiation
    WHEN 'pvtpp_security_group' THEN th.pvtpp_security_group
  END AS threshold,
  m.threshold_param,
  'cast_votes_only'::text AS basis
FROM weighted w
LEFT JOIN palmares.threshold_map m
  ON m.action_type = w.action_type AND m.voter_role = w.voter_role
LEFT JOIN palmares.thresholds th ON th.epoch_no = w.last_votable_epoch
GROUP BY w.gov_action_id, w.voter_role, w.last_votable_epoch, m.threshold_param,
         th.dvt_motion_no_confidence, th.dvt_committee_normal, th.dvt_committee_no_confidence,
         th.dvt_update_to_constitution, th.dvt_hard_fork_initiation, th.dvt_treasury_withdrawal,
         th.pvt_motion_no_confidence, th.pvt_committee_normal, th.pvt_committee_no_confidence,
         th.pvt_hard_fork_initiation, th.pvtpp_security_group;
