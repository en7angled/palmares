-- Checks for palmares.vote, palmares.thresholds and palmares.threshold_map, against a caught-up
-- preprod db-sync (tip epoch >= 320).
--
-- PREREQUISITE: sql/indexes/001_gov_indexes.sql must have been applied. The CC assertions below
-- resolve a cold credential per vote row, and without gov_idx_committee_reg_hot that lookup
-- seq-scans 648,766 registrations once per row — measured: it does not finish. With the index the
-- whole file runs in about a minute, and each CC count takes ~10 s over 3.2 M rows. Slow is
-- expected here; hung is not.
--
-- Counts are cut at `vote_epoch < 320` for the same reason as 020_eligibility.sql: votes keep
-- arriving, so `count(*) = 816` is an assertion about a live counter. The plan's 816 / 511 / 65
-- were a mid-epoch-320 snapshot; cut at the epoch boundary the stable values are 809 / 504 / 64.
DO $$
DECLARE
  cc_rows bigint;
  cc_final bigint;
  cc_cold bigint;
  cc_hot bigint;
BEGIN
  -- ---- DRep votes ---------------------------------------------------------------------------
  ASSERT (SELECT count(*) FROM palmares.vote
          WHERE voter_role = 'DRep' AND vote_epoch < 320) = 809, 'DRep vote rows before epoch 320';
  ASSERT (SELECT count(DISTINCT voter_hot_hash) FROM palmares.vote
          WHERE voter_role = 'DRep' AND vote_epoch < 320) = 504, 'distinct DRep voters before epoch 320';
  ASSERT (SELECT count(*) FROM palmares.vote
          WHERE voter_role = 'DRep' AND vote_epoch < 320 AND voting_anchor_id IS NOT NULL) = 64,
    'DRep votes carrying a rationale anchor';

  -- Re-voting is real and the view must keep every row: 69 (voter, action) pairs were voted more
  -- than once and the worst was voted 20 times. A tally that forgot `seq_last = 1` would count
  -- all 20.
  ASSERT (SELECT count(*) FROM (
            SELECT 1 FROM palmares.vote
            WHERE voter_role = 'DRep' AND vote_epoch < 320
            GROUP BY voter_hot_hash, gov_action_id HAVING count(*) > 1) x) = 69,
    're-voted (DRep, action) pairs';
  ASSERT (SELECT max(vote_rows) FROM palmares.vote
          WHERE voter_role = 'DRep' AND vote_epoch < 320) = 20, 'worst re-voted pair';

  -- ---- SPO votes ----------------------------------------------------------------------------
  ASSERT (SELECT count(*) FROM palmares.vote
          WHERE voter_role = 'SPO' AND vote_epoch < 320) = 90, 'SPO vote rows';
  ASSERT (SELECT count(DISTINCT voter_hot_hash) FROM palmares.vote
          WHERE voter_role = 'SPO' AND vote_epoch < 320) = 45, 'distinct SPO voters';
  -- No SPO has ever attached a rationale on preprod. Asserted so that a future non-zero is
  -- noticed rather than averaged away.
  ASSERT (SELECT count(*) FROM palmares.vote
          WHERE voter_role = 'SPO' AND vote_epoch < 320 AND voting_anchor_id IS NOT NULL) = 0,
    'no SPO rationale anchors on preprod';
  -- An SPO is always a key hash: db-sync's pool_hash has no has_script column to record otherwise.
  ASSERT (SELECT count(*) FROM palmares.vote WHERE voter_role = 'SPO' AND has_script) = 0,
    'stake pools are never script credentials';

  -- ---- the sequence numbering, which every tally depends on --------------------------------
  -- Exactly one seq_last = 1 and one seq_first = 1 per (voter identity, action). If this fails,
  -- every participation and tally number downstream is wrong.
  ASSERT (SELECT count(*) FROM (
            SELECT 1 FROM palmares.vote
            GROUP BY voter_role, voter_id_hash, gov_action_id
            HAVING count(*) FILTER (WHERE seq_last = 1) <> 1
                OR count(*) FILTER (WHERE seq_first = 1) <> 1) x) = 0,
    'exactly one first and one last vote per (voter identity, action)';

  -- ---- D-24 / D-27: the constitutional committee -------------------------------------------
  -- Every CC vote must resolve to a cold credential. A NULL here means a hot key voted without a
  -- registration in force, which would silently drop the vote out of every per-member view.
  ASSERT (SELECT count(*) FROM palmares.vote
          WHERE voter_role = 'ConstitutionalCommittee' AND voter_cold_hash IS NULL) = 0,
    'every CC vote resolves to a cold credential';

  SELECT count(*) INTO cc_rows FROM palmares.vote
    WHERE voter_role = 'ConstitutionalCommittee' AND vote_epoch < 320;
  SELECT count(*) INTO cc_final FROM palmares.vote
    WHERE voter_role = 'ConstitutionalCommittee' AND vote_epoch < 320 AND seq_last = 1;
  SELECT count(DISTINCT voter_cold_hash) INTO cc_cold FROM palmares.vote
    WHERE voter_role = 'ConstitutionalCommittee' AND vote_epoch < 320;
  SELECT count(DISTINCT voter_hot_hash) INTO cc_hot FROM palmares.vote
    WHERE voter_role = 'ConstitutionalCommittee' AND vote_epoch < 320;

  -- This trio is the whole reason voter_id_hash exists. An AuthCommitteeHotKey stress test in
  -- epoch 187 left preprod with 648,766 CC hot keys mapping to 43 cold keys. Partitioning the
  -- re-vote windows by the hot key would report 3,243,798 "final" CC votes; the truth is 193.
  -- A factor of about 16,800 — not a rounding error, and invisible unless asserted.
  ASSERT cc_rows = 3243802, format('CC vote rows: %s', cc_rows);
  ASSERT cc_final = 193, format('CC final votes by cold key: %s', cc_final);
  ASSERT cc_cold = 43, format('distinct CC cold keys: %s', cc_cold);
  ASSERT cc_hot = 648766, format('distinct CC hot keys: %s', cc_hot);
  ASSERT cc_hot > cc_cold * 1000,
    'the hot-key explosion is what makes the cold-key partition load-bearing';

  -- ---- thresholds and the static map -------------------------------------------------------
  -- gov_action_lifetime is 6, NOT 7. The ledger sets expiration = proposed_epoch + lifetime + 1,
  -- and the observed delta is 7 on all 131 preprod actions — which is why last_votable_epoch
  -- must read gov_action_proposal.expiration and never do arithmetic over this parameter.
  ASSERT (SELECT gov_action_lifetime FROM palmares.thresholds WHERE epoch_no = 320) = 6,
    'govActionLifetime is 6 on preprod';
  -- The epoch_param row for a closed epoch is immutable, so this pin is safe.
  ASSERT (SELECT count(*) FROM palmares.thresholds WHERE epoch_no = 320) = 1;

  ASSERT (SELECT count(*) FROM palmares.threshold_map) = 21, 'seven action types x three roles';
  -- The spelling that a pvt_ prefix scan misses.
  ASSERT (SELECT threshold_param FROM palmares.threshold_map
          WHERE action_type = 'ParameterChange' AND voter_role = 'SPO') = 'pvtpp_security_group';
  -- Every non-NULL threshold_param must name a real column of palmares.thresholds, or the API
  -- would echo a name a client cannot look up.
  ASSERT (SELECT count(*) FROM palmares.threshold_map m
          WHERE m.threshold_param IS NOT NULL
            AND NOT EXISTS (
              SELECT 1 FROM information_schema.columns c
              WHERE c.table_schema = 'palmares' AND c.table_name = 'thresholds'
                AND c.column_name = m.threshold_param)) = 0,
    'every threshold_param names a column of palmares.thresholds';

  RAISE NOTICE 'vote views ok: % CC rows -> % final by % cold keys (over % hot keys); DRep % rows, SPO % rows',
    cc_rows, cc_final, cc_cold, cc_hot,
    (SELECT count(*) FROM palmares.vote WHERE voter_role = 'DRep'),
    (SELECT count(*) FROM palmares.vote WHERE voter_role = 'SPO');
END $$;
