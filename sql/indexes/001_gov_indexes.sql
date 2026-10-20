-- Indexes on db-sync's OWN tables, for the access patterns the palmares views have and db-sync
-- does not.
--
-- These are deliberately NOT part of palmaresSqlFiles / applyPalmaresSchema:
--
--   * they live in `public`, which `000_schema.sql` must never touch — dropping an index on a
--     db-sync table is one thing, but the schema reset runs on every query-api start;
--   * CREATE INDEX on a multi-million-row table takes minutes and holds locks, which is not
--     something an API process should do while coming up;
--   * CONCURRENTLY cannot run inside a transaction block, and the schema bootstrap is one
--     transaction by design.
--
-- So this file is applied once by the substrate block's index Job, and re-applying it is free
-- (IF NOT EXISTS). `scripts/verify_views.sh` assumes it has been applied: without the committee
-- index below, the CC assertions in sql/checks/030_votes.sql do not finish.
--
-- Every index here was either verified absent from db-sync's own schema/ migrations at tag
-- 13.7.2.1, or measured necessary against the real preprod database.

-- The vote fan-out: every tally, every per-actor history, every action's vote list.
CREATE INDEX CONCURRENTLY IF NOT EXISTS gov_idx_voting_procedure_gap ON public.voting_procedure (gov_action_proposal_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS gov_idx_voting_procedure_drep ON public.voting_procedure (drep_voter) WHERE drep_voter IS NOT NULL;
CREATE INDEX CONCURRENTLY IF NOT EXISTS gov_idx_voting_procedure_pool ON public.voting_procedure (pool_voter) WHERE pool_voter IS NOT NULL;
CREATE INDEX CONCURRENTLY IF NOT EXISTS gov_idx_voting_procedure_cc ON public.voting_procedure (committee_voter) WHERE committee_voter IS NOT NULL;
CREATE INDEX CONCURRENTLY IF NOT EXISTS gov_idx_voting_procedure_tx ON public.voting_procedure (tx_id);

-- palmares.vote resolves a CC vote's COLD credential by looking up the hot-key registration in
-- force at the vote's transaction: `WHERE hot_key_id = ? AND tx_id <= ? ORDER BY tx_id DESC`.
--
-- MEASURED, and this one is not in the design's list: without it the lookup seq-scans
-- committee_registration once per CC vote row. Preprod has 648,766 hot-key registrations and
-- 3,243,802 CC vote rows, so the CC half of palmares.vote simply never finishes. The design
-- listed only `(cold_key_id)`, which serves the opposite direction (a member's hot keys), not
-- this one.
CREATE INDEX CONCURRENTLY IF NOT EXISTS gov_idx_committee_reg_hot ON public.committee_registration (hot_key_id, tx_id DESC);

-- DRep identity, certificates and delegation.
CREATE INDEX CONCURRENTLY IF NOT EXISTS gov_idx_drep_registration_drep ON public.drep_registration (drep_hash_id, tx_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS gov_idx_delegation_vote_drep ON public.delegation_vote (drep_hash_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS gov_idx_delegation_vote_addr ON public.delegation_vote (addr_id, tx_id);

-- Governance actions and their anchors.
CREATE INDEX CONCURRENTLY IF NOT EXISTS gov_idx_gov_action_proposal_tx ON public.gov_action_proposal (tx_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS gov_idx_gov_action_prev ON public.gov_action_proposal (prev_gov_action_proposal) WHERE prev_gov_action_proposal IS NOT NULL;
CREATE INDEX CONCURRENTLY IF NOT EXISTS gov_idx_ocvd_anchor ON public.off_chain_vote_data (voting_anchor_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS gov_idx_ocvfe_anchor ON public.off_chain_vote_fetch_error (voting_anchor_id, retry_count DESC);

-- Committee membership and treasury.
CREATE INDEX CONCURRENTLY IF NOT EXISTS gov_idx_committee_reg_cold ON public.committee_registration (cold_key_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS gov_idx_committee_dereg_cold ON public.committee_de_registration (cold_key_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS gov_idx_treasury_withdrawal_gap ON public.treasury_withdrawal (gov_action_proposal_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS gov_idx_stake_dereg_addr ON public.stake_deregistration (addr_id, tx_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS gov_idx_reward_rest_type ON public.reward_rest (type, spendable_epoch);

-- These two ARE in db-sync's own migrations (4-0009 and 3-0004); IF NOT EXISTS makes re-stating
-- them free, and stating them keeps the list readable as "what the views need".
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_drep_distr_hash_id_epoch_no ON public.drep_distr (hash_id, epoch_no);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_committee_member_committee_id ON public.committee_member (committee_id);
