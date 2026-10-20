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
  -- COALESCE inside the arithmetic, not around it. A FILTERed sum over no matching rows is NULL,
  -- not 0, so without this a UNANIMOUS action — every vote Yes, no No at all — computes
  -- yes + NULL = NULL and publishes ratio = NULL. That reads as "no votes were cast", which is the
  -- opposite of what happened. Measured: 49 of the 129 tallies carry power, and 33 of those 49
  -- were publishing a null ratio; after the fix none is null and 31 are a unanimous 1.0.
  --
  -- NULLIF stays, for the case it was written for: no power behind either side, where there really
  -- is no ratio to publish.
  COALESCE(sum(w.power) FILTER (WHERE w.vote = 'Yes'), 0)
    / NULLIF(
        COALESCE(sum(w.power) FILTER (WHERE w.vote = 'Yes'), 0)
          + COALESCE(sum(w.power) FILTER (WHERE w.vote = 'No'), 0),
        0
      ) AS ratio,
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
  tx.block_index AS proposed_tx_index,
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
  -- Final votes only: a re-voted action must not count twice. Counted as DISTINCT VOTERS rather
  -- than as palmares.vote rows with seq_last = 1, which is the same number by definition — one
  -- final vote per voter per action — but does not pay for that view's window functions over all
  -- 3.24 M rows. Measured: 5.7 s for one action through palmares.vote, 0.03 s this way.
  --
  -- The committee is counted by COLD credential, like everywhere else: preprod's 648,766 hot keys
  -- resolve to 43 cold ones, so counting hot keys would report a governance action as having been
  -- voted on by six hundred thousand committee members.
  (SELECT count(*) FROM (
     SELECT DISTINCT
       v.voter_role,
       CASE v.voter_role
         WHEN 'DRep' THEN 'd:' || v.drep_voter
         WHEN 'SPO' THEN 'p:' || v.pool_voter
         ELSE 'c:' || COALESCE(encode(cold.cold_raw, 'hex'), 'hot:' || v.committee_voter)
       END AS who
     FROM public.voting_procedure v
     LEFT JOIN palmares.cc_cold_interval cold
       ON cold.hot_key_id = v.committee_voter
      AND cold.from_tx <= v.tx_id
      AND (cold.to_tx IS NULL OR cold.to_tx > v.tx_id)
     WHERE v.gov_action_proposal_id = aw.gov_action_id
   ) voters) AS votes_cast,
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

-- ---------------------------------------------------------------------------------------------
-- palmares.activity — one governance feed, eleven arms, thirteen kinds, one total cursor.
--
-- The cursor is `(sort_slot, tx_index, arm, item_index)` and it MUST be unique over the whole
-- feed: it is what a client pages by, and a duplicate either skips an event or repeats one
-- forever.
--
-- MEASURED, and this is why the cursor has four components rather than the three the plan
-- specified. Against the real preprod corpus (3.9 M feed rows) the triple
-- (sort_slot, tx_index, item_index) had **108,141 duplicate groups**, from two distinct causes:
--
--   1. CROSS-ARM, 108,130 groups. `voting_procedure.index`, `gov_action_proposal.index` and
--      `cert_index` are three INDEPENDENT per-transaction counters, so a transaction carrying
--      both a vote and a certificate produces the same triple twice. The epoch-187
--      AuthCommitteeHotKey stress test did exactly that in bulk: 108,128 groups are
--      `committee_authorized` colliding with `vote_cast`, the worst with 31 rows.
--      Fixed by `arm`, a per-arm ordinal that is part of the cursor.
--
--   2. WITHIN THE VOTE ARM, 11 groups. `voting_procedure.index` is NOT a per-transaction
--      counter in this data: the 3,243,802 CC vote rows carry only 108,176 distinct
--      (tx_id, index) pairs, and the values 0, 1 and 2 each appear about 648,000 times. So it
--      cannot identify a vote within a transaction at all. The vote arm therefore uses
--      `voting_procedure.id`, which is unique by construction.
--
-- An arm ordinal alone would not have fixed (2), and a unique key alone would not have fixed (1).
-- `sql/checks/060_activity.sql` asserts the uniqueness, and that assertion is what found both.
--
-- Two kinds of arm:
--
-- SIX TX-BORNE ARMS have a real transaction, so the cursor is the chain's own order:
-- `sort_slot = block.slot_no`, `tx_index = tx.block_index`, and `item_index` identifies the item
-- within the transaction — `cert_index` where it is a genuine per-transaction counter, and the
-- row's own primary key for the vote arm, where it is not (see above).
--
-- FIVE EPOCH-BOUNDARY ARMS have no transaction at all: db-sync records ratification, enactment,
-- expiry and dropping only as `*_epoch` columns on the proposal. So those rows carry
-- `slot_no = NULL` and `tx_hash = NULL` — there is no chain point to report and inventing one
-- would be a lie — while `sort_slot` borrows the first block of the epoch so the feed still
-- sorts, and `tx_index = -1` puts them before every transaction in that epoch.
-- `item_index = gov_action_proposal.id` keeps the triple unique when two actions ratify in the
-- same epoch.
--
-- `treasury_withdrawal_enacted` is the one arm at `tx_index = -2`. It fires in the SAME epoch as
-- `gov_action_enacted` for the SAME proposal id, so at -1 it would collide with it on all three
-- cursor components. -2 still sorts before every transaction and restores totality. The API's
-- cursor parser must accept both values.
--
-- `actor_id` and `target_id` are text and their meaning depends on `event_type`: a credential in
-- hex, a stake address in bech32, or a governance action id. That is inherent to a union feed;
-- the reader dispatches on the kind.
CREATE VIEW palmares.activity AS

-- (1) DRep certificates: three kinds off one arm.
SELECT
  CASE c.cert_kind
    WHEN 'register' THEN 'drep_registered'
    WHEN 'retire' THEN 'drep_retired'
    ELSE 'drep_updated'
  END AS event_type,
  'governance' AS source,
  c.slot_no AS sort_slot,
  c.tx_index,
  1 AS arm,
  c.cert_index AS item_index,
  c.slot_no,
  c.epoch_no,
  c.cert_time AS block_time,
  encode(c.tx_hash, 'hex') AS tx_hash,
  encode(h.raw, 'hex') AS actor_id,
  NULL::text AS target_id
FROM palmares.drep_cert c
JOIN public.drep_hash h ON h.id = c.drep_hash_id

UNION ALL

-- (2) Votes. Every row, not just final ones: a re-vote is an event that happened.
--
-- NOT `FROM palmares.vote`. That view computes three window functions, and although PostgreSQL
-- drops their computation when nothing selects them, the view still cannot be pulled up — so NO
-- qual reaches these joins. A slot bound lands as a filter above a sequential scan of all
-- 3,244,711 voting_procedure rows on every page. MEASURED: a 50-row page of palmares.activity took
-- 253 SECONDS that way.
--
-- The credential is resolved by four LEFT JOINs and ONE COALESCE, not by four correlated
-- subqueries. That is the second measurement, and it is the one that matters at this scale: the
-- subquery form evaluates its scalar SELECTs once per row BEFORE the sort, so 3.24 M rows pay for
-- the 50 the LIMIT keeps — 39.8 s for an unwindowed newest-50 page, of which 36.1 s was this arm
-- and 34.5 s of that was the per-row credential lookups. Written as joins the same page is 8.4 s,
-- and under the API's 5-day window it is 0.6 s. The COALESCE chain needs no CASE on voter_role
-- because exactly one of drep_voter, pool_voter and committee_voter is non-null per row, and the
-- two forms were checked row for row: 0 disagreements over all 3,244,711 rows.
--
-- palmares.vote itself is unchanged and keeps its own hash join, which is the right shape for its
-- full-corpus consumers — that is the 87 s to 5.7 s win T-API-11 measured. The identity published
-- here is identical: COALESCE(cold, hot) is exactly palmares.vote.voter_id_hash (D-24), and the
-- cold credential still comes from palmares.cc_cold_interval, so the "registration in force at
-- this transaction" rule has one definition. sql/checks/060_activity.sql asserts this arm's count
-- equals palmares.vote's, row for row.
SELECT
  'vote_cast',
  'governance',
  b.slot_no,
  tx.block_index,
  2,
  -- NOT voting_procedure.index: it repeats massively in this data (see the header).
  v.id,
  b.slot_no,
  b.epoch_no,
  b.time,
  encode(tx.hash, 'hex'),
  encode(COALESCE(cold.cold_raw, dh.raw, ph.hash_raw, ch.raw), 'hex'),
  v.gov_action_proposal_id::text
FROM public.voting_procedure v
JOIN public.tx ON tx.id = v.tx_id
JOIN public.block b ON b.id = tx.block_id
LEFT JOIN palmares.cc_cold_interval cold
  ON cold.hot_key_id = v.committee_voter
 AND cold.from_tx <= v.tx_id
 AND (cold.to_tx IS NULL OR cold.to_tx > v.tx_id)
LEFT JOIN public.drep_hash dh ON dh.id = v.drep_voter
LEFT JOIN public.pool_hash ph ON ph.id = v.pool_voter
LEFT JOIN public.committee_hash ch ON ch.id = v.committee_voter

UNION ALL

-- (3) Proposals.
SELECT
  'gov_action_proposed',
  'governance',
  ga.proposed_slot,
  ga.proposed_tx_index,
  3,
  ga.index,
  ga.proposed_slot,
  ga.proposed_epoch,
  ga.proposed_at,
  encode(ga.tx_hash, 'hex'),
  ga.return_address,
  ga.gov_action_id::text
FROM palmares.gov_action ga

UNION ALL

-- (4) Vote delegation.
SELECT
  'delegation_changed',
  'governance',
  vd.slot_no,
  vd.tx_index,
  4,
  vd.cert_index,
  vd.slot_no,
  vd.epoch_no,
  vd.delegated_at,
  encode(vd.tx_hash, 'hex'),
  vd.stake_address,
  CASE WHEN vd.target_kind = 'drep' THEN encode(h.raw, 'hex') ELSE vd.target_kind END
FROM palmares.vote_delegation vd
JOIN public.drep_hash h ON h.id = vd.drep_hash_id

UNION ALL

-- (5) Committee hot-key authorisation.
SELECT
  'committee_authorized',
  'governance',
  b.slot_no,
  tx.block_index,
  5,
  cr.cert_index,
  b.slot_no,
  b.epoch_no,
  b.time,
  encode(tx.hash, 'hex'),
  encode(cold.raw, 'hex'),
  encode(hot.raw, 'hex')
FROM public.committee_registration cr
JOIN public.tx ON tx.id = cr.tx_id
JOIN public.block b ON b.id = tx.block_id
JOIN public.committee_hash cold ON cold.id = cr.cold_key_id
JOIN public.committee_hash hot ON hot.id = cr.hot_key_id

UNION ALL

-- (6) Committee resignation.
SELECT
  'committee_resigned',
  'governance',
  b.slot_no,
  tx.block_index,
  6,
  dr.cert_index,
  b.slot_no,
  b.epoch_no,
  b.time,
  encode(tx.hash, 'hex'),
  encode(cold.raw, 'hex'),
  NULL::text
FROM public.committee_de_registration dr
JOIN public.tx ON tx.id = dr.tx_id
JOIN public.block b ON b.id = tx.block_id
JOIN public.committee_hash cold ON cold.id = dr.cold_key_id

UNION ALL

-- (7) Ratification.
SELECT
  'gov_action_ratified',
  'governance',
  eb.first_slot,
  -1,
  7,
  g.gov_action_id,
  NULL::bigint,
  g.ratified_epoch,
  eb.first_time,
  NULL::text,
  NULL::text,
  g.gov_action_id::text
FROM palmares.gov_action g
JOIN LATERAL (
  SELECT b.slot_no AS first_slot, b.time AS first_time
  FROM public.block b WHERE b.epoch_no = g.ratified_epoch ORDER BY b.slot_no LIMIT 1
) eb ON true
WHERE g.ratified_epoch IS NOT NULL

UNION ALL

-- (8) Enactment.
SELECT
  'gov_action_enacted',
  'governance',
  eb.first_slot,
  -1,
  8,
  g.gov_action_id,
  NULL::bigint,
  g.enacted_epoch,
  eb.first_time,
  NULL::text,
  NULL::text,
  g.gov_action_id::text
FROM palmares.gov_action g
JOIN LATERAL (
  SELECT b.slot_no AS first_slot, b.time AS first_time
  FROM public.block b WHERE b.epoch_no = g.enacted_epoch ORDER BY b.slot_no LIMIT 1
) eb ON true
WHERE g.enacted_epoch IS NOT NULL

UNION ALL

-- (9) Expiry.
SELECT
  'gov_action_expired',
  'governance',
  eb.first_slot,
  -1,
  9,
  g.gov_action_id,
  NULL::bigint,
  g.expired_epoch,
  eb.first_time,
  NULL::text,
  NULL::text,
  g.gov_action_id::text
FROM palmares.gov_action g
JOIN LATERAL (
  SELECT b.slot_no AS first_slot, b.time AS first_time
  FROM public.block b WHERE b.epoch_no = g.expired_epoch ORDER BY b.slot_no LIMIT 1
) eb ON true
WHERE g.expired_epoch IS NOT NULL

UNION ALL

-- (10) Dropping — and ONLY the genuine case.
--
-- `dropped_epoch` is not an independent outcome. db-sync's schema doc says a proposal is dropped
-- when it expires or is enacted, but that line is stale per its own maintainer (issue #1932):
-- CHANGELOG 13.6.0.1 stopped marking enacted proposals as dropped, and on EXPIRY db-sync sets
-- dropped_epoch = expired_epoch + 1. So 102 of the 108 preprod rows carrying dropped_epoch are
-- expired actions that already emit gov_action_expired, and emitting a drop for them would
-- duplicate the expiry one epoch later.
--
-- The 6 rows that remain are the real thing: actions invalidated because a competing action was
-- enacted — no expiry, no enactment, no ratification, just removed from the proposals set.
SELECT
  'gov_action_dropped',
  'governance',
  eb.first_slot,
  -1,
  10,
  g.gov_action_id,
  NULL::bigint,
  g.dropped_epoch,
  eb.first_time,
  NULL::text,
  NULL::text,
  g.gov_action_id::text
FROM palmares.gov_action g
JOIN LATERAL (
  SELECT b.slot_no AS first_slot, b.time AS first_time
  FROM public.block b WHERE b.epoch_no = g.dropped_epoch ORDER BY b.slot_no LIMIT 1
) eb ON true
WHERE g.dropped_epoch IS NOT NULL
  AND g.ratified_epoch IS NULL
  AND g.enacted_epoch IS NULL
  AND g.expired_epoch IS NULL

UNION ALL

-- (11) Treasury payout, at tx_index = -2 so it cannot collide with its own action's enactment.
SELECT
  'treasury_withdrawal_enacted',
  'governance',
  eb.first_slot,
  -2,
  11,
  t.gov_action_id,
  NULL::bigint,
  t.enacted_epoch,
  eb.first_time,
  NULL::text,
  NULL::text,
  t.stake_address
FROM palmares.treasury_withdrawal t
JOIN LATERAL (
  SELECT b.slot_no AS first_slot, b.time AS first_time
  FROM public.block b WHERE b.epoch_no = t.enacted_epoch ORDER BY b.slot_no LIMIT 1
) eb ON true
WHERE t.enacted_epoch IS NOT NULL;
