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

-- ---------------------------------------------------------------------------------------------
-- palmares.gov_action — one row per governance action, with its published lifecycle state.
--
-- `state` is the published `gov_action_state_v1` chain, in this exact order:
--   enacted_epoch  -> 'enacted'
--   expired_epoch  -> 'expired'
--   dropped_epoch  -> 'dropped'
--   ratified_epoch -> 'ratified'
--   otherwise         'proposed'
-- The order matters because the columns are not mutually exclusive: an enacted action carries
-- ratified_epoch too, and 108 of preprod's 131 actions carry dropped_epoch. Reordering the arms
-- renames a third of the corpus.
--
-- `state` and `last_votable_epoch` answer DIFFERENT questions and may disagree. One preprod
-- action carries `expired_epoch = 320` while its window is still open at epoch 320, so it is
-- 'expired' by state and votable by window. A UI that derives "can I still vote" from `state`
-- will be wrong on exactly that row; `palmares.action_window` is the authority for votability.
--
-- `withdrawal_total` sums `public.treasury_withdrawal` and NOT `palmares.treasury_withdrawal`:
-- the latter reads this view, and PostgreSQL rejects the cycle.
CREATE VIEW palmares.gov_action AS
WITH action_meta AS (
  -- ponytail: db-sync 13.7.1.0/13.7.2.1 write DUPLICATE off-chain metadata child rows (release
  -- notes "Known issues"; PR #2137 fixes it). The design's list named off_chain_vote_author,
  -- _reference and _external_update; MEASURED, the bug also hits off_chain_vote_gov_action_data
  -- (2 duplicated off_chain_vote_data_id values on preprod) and off_chain_vote_drep_data. Here it
  -- fanned 131 actions out to 135 rows, which then double-counted treasury withdrawals through
  -- palmares.treasury_withdrawal. DISTINCT ON by lowest id picks the first-inserted. Drop this CTE
  -- and join directly after upgrading past 13.7.2.1.
  SELECT DISTINCT ON (off_chain_vote_data_id)
    off_chain_vote_data_id, title, abstract
  FROM public.off_chain_vote_gov_action_data
  ORDER BY off_chain_vote_data_id, id
)
SELECT
  aw.gov_action_id,
  tx.hash AS tx_hash,
  g.index,
  aw.action_type,
  gd.title,
  gd.abstract,
  aw.proposed_epoch,
  aw.proposed_slot,
  aw.proposed_at,
  aw.expiration,
  aw.last_votable_epoch,
  CASE
    WHEN g.enacted_epoch IS NOT NULL THEN 'enacted'
    WHEN g.expired_epoch IS NOT NULL THEN 'expired'
    WHEN g.dropped_epoch IS NOT NULL THEN 'dropped'
    WHEN g.ratified_epoch IS NOT NULL THEN 'ratified'
    ELSE 'proposed'
  END AS state,
  g.ratified_epoch,
  g.enacted_epoch,
  g.expired_epoch,
  g.dropped_epoch,
  g.deposit,
  sa.view AS return_address,
  g.prev_gov_action_proposal,
  (SELECT sum(tw.amount) FROM public.treasury_withdrawal tw
   WHERE tw.gov_action_proposal_id = g.id) AS withdrawal_total,
  -- Final votes only: a re-voted action must not count twice.
  (SELECT count(*) FROM palmares.vote v
   WHERE v.gov_action_id = aw.gov_action_id AND v.seq_last = 1) AS votes_cast,
  g.voting_anchor_id
FROM palmares.action_window aw
JOIN public.gov_action_proposal g ON g.id = aw.gov_action_id
JOIN public.tx ON tx.id = g.tx_id
JOIN public.stake_address sa ON sa.id = g.return_address
LEFT JOIN palmares.anchor a ON a.voting_anchor_id = g.voting_anchor_id
LEFT JOIN action_meta gd ON gd.off_chain_vote_data_id = a.off_chain_vote_data_id;

-- ---------------------------------------------------------------------------------------------
-- palmares.committee_member — the constitutional committee, cold and hot credentials resolved.
--
-- ponytail: this view subsumes spec §6's `committee_vote_auth`. Authorising a CC vote is
-- "the cold credential is an enacted member and has a hot key registered", which is these
-- columns; a second view would be the same join under another name.
--
-- `is_enacted` marks the committee in force at the tip. db-sync's `epoch_state` points at the
-- committee per epoch, and issue #2155 can leave DUPLICATE epoch_state rows on 13.7.1.0 — so the
-- committee is taken from the max-id row of the latest epoch rather than from "the" row.
--
-- `status` is 'resigned' once the cold credential appears in committee_de_registration, and
-- 'active' otherwise. A resigned member keeps its row: its past votes are still history.
CREATE VIEW palmares.committee_member AS
WITH current_committee AS (
  -- EXACTLY ONE ROW: the committee in force at the latest epoch that records one.
  --
  -- `epoch_state` has a row per epoch, and many epochs point at the same committee, so selecting
  -- one row per EPOCH and then joining on committee_id multiplies every member by the number of
  -- epochs that used its committee. Measured: that fanned 3 enacted members out to 1,563.
  --
  -- The max-id tie-break matters on its own: issue #2155 can leave duplicate epoch_state rows on
  -- 13.7.1.0, so "the row for the latest epoch" is not unique either.
  SELECT es.committee_id, es.epoch_no
  FROM public.epoch_state es
  WHERE es.committee_id IS NOT NULL
  ORDER BY es.epoch_no DESC, es.id DESC
  LIMIT 1
)
SELECT
  cm.committee_hash_id,
  ch.raw AS cold_hash,
  ch.has_script AS cold_has_script,
  hot.raw AS hot_hash,
  hot.has_script AS hot_has_script,
  CASE
    WHEN EXISTS (SELECT 1 FROM public.committee_de_registration dr
                 WHERE dr.cold_key_id = cm.committee_hash_id) THEN 'resigned'
    ELSE 'active'
  END AS status,
  cm.expiration_epoch,
  cm.committee_id,
  (cc.committee_id IS NOT NULL) AS is_enacted,
  c.quorum_numerator,
  c.quorum_denominator
FROM public.committee_member cm
JOIN public.committee_hash ch ON ch.id = cm.committee_hash_id
JOIN public.committee c ON c.id = cm.committee_id
LEFT JOIN current_committee cc ON cc.committee_id = cm.committee_id
-- The hot credential in force now: the newest registration for this cold key.
LEFT JOIN LATERAL (
  SELECT h.raw, h.has_script
  FROM public.committee_registration cr
  JOIN public.committee_hash h ON h.id = cr.hot_key_id
  WHERE cr.cold_key_id = cm.committee_hash_id
  ORDER BY cr.tx_id DESC, cr.cert_index DESC
  LIMIT 1
) hot ON true;

-- ---------------------------------------------------------------------------------------------
-- palmares.treasury_withdrawal — the withdrawals an action requests, and whether one was paid.
--
-- `paid_heuristic` is named for what it is. `reward_rest` records treasury payouts per
-- (stake address, epoch) with NO governance-action key, so matching a payout to a withdrawal is
-- inference: when one address receives two withdrawals in the same epoch the match is ambiguous
-- and this column will claim both were paid. It is a display hint, never an accounting fact, and
-- nothing downstream may sum it.
CREATE VIEW palmares.treasury_withdrawal AS
SELECT
  tw.gov_action_proposal_id AS gov_action_id,
  tw.stake_address_id,
  sa.view AS stake_address,
  tw.amount,
  ga.enacted_epoch,
  (rr.addr_id IS NOT NULL) AS paid_heuristic
FROM public.treasury_withdrawal tw
JOIN public.stake_address sa ON sa.id = tw.stake_address_id
JOIN palmares.gov_action ga ON ga.gov_action_id = tw.gov_action_proposal_id
LEFT JOIN public.reward_rest rr
  ON rr.addr_id = tw.stake_address_id
 AND rr.type = 'treasury'
 AND rr.spendable_epoch = ga.enacted_epoch;
