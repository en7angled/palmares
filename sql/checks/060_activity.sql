-- Checks for palmares.activity against a caught-up preprod db-sync (tip epoch >= 320).
-- Prerequisite: sql/indexes/001_gov_indexes.sql. MEASURED at about 3.5 minutes: the feed is
-- ~3.9 M rows and the uniqueness assertion groups all of them. It is the slowest check in the
-- set by an order of magnitude, and it earns that by being the one that found the cursor defect.
--
-- The thirteen kinds are NOT asserted here. preprod has never recorded a committee resignation
-- (committee_de_registration is empty) and has never enacted a treasury withdrawal (the 11
-- enacted actions are 6 ParameterChange, 2 HardForkInitiation and 3 NewCommittee), so two kinds
-- are unreachable on live data and a DISTINCT = 13 gate would be unfalsifiable. That assertion
-- lives in src/test/UnitTests/Activity.hs over a seeded corpus; this file asserts the counts and
-- the cursor over the real one.
DO $$
DECLARE
  n_rows bigint;
  n_dups bigint;
BEGIN
  SELECT count(*) INTO n_rows FROM palmares.activity;

  -- THE assertion of this file. The cursor is what a client pages by, so a duplicate either skips
  -- an event or repeats one forever. Four components, because three were measured insufficient:
  -- 108,141 duplicate triples, from cross-arm collisions (independent per-tx counters, 108,130
  -- groups) and from voting_procedure.index not being a per-tx counter at all (11 groups).
  SELECT count(*) INTO n_dups FROM (
    SELECT 1 FROM palmares.activity
    GROUP BY sort_slot, tx_index, arm, item_index HAVING count(*) > 1
  ) x;
  ASSERT n_dups = 0, format('the activity cursor must be total: %s duplicate groups', n_dups);

  -- Lifecycle counts, cut at epoch 320 so they are history rather than a live tally.
  ASSERT (SELECT count(*) FROM palmares.activity
          WHERE event_type = 'gov_action_proposed' AND epoch_no < 320) = 131;
  ASSERT (SELECT count(*) FROM palmares.activity
          WHERE event_type = 'gov_action_ratified' AND epoch_no <= 320) = 11;
  ASSERT (SELECT count(*) FROM palmares.activity
          WHERE event_type = 'gov_action_enacted' AND epoch_no <= 320) = 11;
  ASSERT (SELECT count(*) FROM palmares.activity
          WHERE event_type = 'gov_action_expired' AND epoch_no <= 320) = 103;

  -- 6, NOT 108. `dropped_epoch` is not an independent outcome: db-sync sets it to
  -- expired_epoch + 1 on expiry, so 102 of the 108 rows carrying it are expired actions that
  -- already emit gov_action_expired, and emitting a drop for them would duplicate the expiry one
  -- epoch later. The schema doc's claim to the contrary is stale per its own maintainer (#1932),
  -- and CHANGELOG 13.6.0.1 stopped marking enacted proposals as dropped.
  ASSERT (SELECT count(*) FROM palmares.activity
          WHERE event_type = 'gov_action_dropped' AND epoch_no <= 320) = 6,
    'only the pruned-sibling case is a genuine drop';

  -- Every vote row is an event, including re-votes: a superseded vote still happened.
  ASSERT (SELECT count(*) FROM palmares.activity WHERE event_type = 'vote_cast')
         = (SELECT count(*) FROM palmares.vote);

  ASSERT (SELECT count(*) FROM palmares.activity WHERE source <> 'governance') = 0,
    'this feed is the governance source; attestations arrive as their own source';

  -- Epoch-boundary events have no transaction, so they must not pretend to have one: a slot or a
  -- tx hash there would be a chain point the API could publish and no explorer could resolve.
  ASSERT (SELECT count(*) FROM palmares.activity
          WHERE event_type IN ('gov_action_ratified', 'gov_action_enacted', 'gov_action_expired',
                               'gov_action_dropped', 'treasury_withdrawal_enacted')
            AND (tx_index NOT IN (-1, -2) OR slot_no IS NOT NULL OR tx_hash IS NOT NULL)) = 0;

  -- Conversely a tx-borne event must carry its chain point, or the feed cannot be joined back to
  -- the chain at all.
  ASSERT (SELECT count(*) FROM palmares.activity
          WHERE tx_index >= 0 AND (slot_no IS NULL OR tx_hash IS NULL)) = 0;

  -- `arm` is closed over the eleven arms, and every row has one.
  ASSERT (SELECT count(*) FROM palmares.activity WHERE arm IS NULL OR arm < 1 OR arm > 11) = 0;

  RAISE NOTICE 'activity ok: % rows, % duplicate cursors, % kinds present (% unreachable on preprod: committee_resigned, treasury_withdrawal_enacted)',
    n_rows, n_dups, (SELECT count(DISTINCT event_type) FROM palmares.activity), 2;
END $$;
