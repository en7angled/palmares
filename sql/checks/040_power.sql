-- Checks for the delegation, voting-power and tally views (D-20), against a caught-up preprod
-- db-sync (tip epoch >= 320). Prerequisite: sql/indexes/001_gov_indexes.sql.
--
-- Epoch 319 is used for the power figures rather than the tip, because a closed epoch's
-- drep_distr rows are immutable while the tip epoch's are still being written.
DO $$
DECLARE
  d bigint;
  live_n bigint;
  epoch_n bigint;
BEGIN
  -- ---- drep_epoch_power is UNFILTERED, and that is the point ------------------------------
  ASSERT (SELECT count(*) FROM palmares.drep_epoch_power WHERE epoch_no = 319) = 195,
    '193 real DReps plus the two reserved options';
  ASSERT (SELECT count(*) FROM palmares.drep_epoch_power
          WHERE epoch_no = 319 AND target_kind = 'drep') = 193;
  ASSERT (SELECT amount FROM palmares.drep_epoch_power
          WHERE epoch_no = 319 AND target_kind = 'always_abstain') = 431863790957959;
  ASSERT (SELECT amount FROM palmares.drep_epoch_power
          WHERE epoch_no = 319 AND target_kind = 'always_no_confidence') = 325390800383;
  -- The reason the view has no WHERE clause: always-abstain alone is ~46% of total voting power,
  -- so any denominator built from a filtered view understates it by nearly half and every
  -- "share of total power" number comes out inflated.
  ASSERT (SELECT sum(amount) FROM palmares.drep_epoch_power WHERE epoch_no = 319) = 937803900128796,
    'total voting power at epoch 319, pseudo-DReps included';
  ASSERT (SELECT amount FROM palmares.drep_epoch_power
          WHERE epoch_no = 319 AND target_kind = 'always_abstain') * 2
         > (SELECT sum(amount) FROM palmares.drep_epoch_power WHERE epoch_no = 319) * 0.9,
    'always_abstain is of the same order as the entire rest of the distribution';

  -- Absence means ZERO power, not unknown power: 101 of the 294 registered DReps have no
  -- drep_distr row at epoch 319. A reader that INNER JOINs this view loses them silently.
  ASSERT (SELECT count(*) FROM palmares.drep dr
          WHERE dr.registration_status = 'registered'
            AND NOT EXISTS (SELECT 1 FROM palmares.drep_epoch_power p
                            WHERE p.drep_hash_id = dr.drep_hash_id AND p.epoch_no = 319)) = 101,
    'registered DReps with no power row at epoch 319';

  -- ---- the fixture DRep's power series -----------------------------------------------------
  SELECT id INTO d FROM public.drep_hash
    WHERE raw = decode('81378d3ea89b68f0fc09944b1f93f2feb851318f196f98ba4029d8a8', 'hex');

  -- 141, not 147: the series is NOT unbroken. Epochs 203..208 have no row at all, which is
  -- exactly the "absence means zero" case above, observed on the very DRep the rest of these
  -- checks use. The plan asserted 147 unbroken rows for 174..320; that was arithmetic
  -- (320 - 174 + 1), not a measurement.
  ASSERT (SELECT count(*) FROM palmares.drep_epoch_power
          WHERE drep_hash_id = d AND epoch_no <= 320) = 141,
    'the fixture DRep has 141 power rows up to epoch 320, with a gap';
  ASSERT (SELECT min(epoch_no) FROM palmares.drep_epoch_power WHERE drep_hash_id = d) = 174,
    'the first power row is the epoch AFTER registration (173), not the registration epoch';
  ASSERT (SELECT count(*) FROM generate_series(203, 208) e
          WHERE NOT EXISTS (SELECT 1 FROM palmares.drep_epoch_power p
                            WHERE p.drep_hash_id = d AND p.epoch_no = e)) = 6,
    'epochs 203..208 are the measured gap';
  ASSERT (SELECT amount FROM palmares.drep_epoch_power
          WHERE drep_hash_id = d AND epoch_no = 320) = 3923709956713;
  ASSERT (SELECT active_until FROM palmares.drep_epoch_power
          WHERE drep_hash_id = d AND epoch_no = 320) = 333;

  -- ---- delegation ---------------------------------------------------------------------------
  -- The de-registration rule, as an invariant rather than a count: a stake credential closed
  -- AFTER its delegation certificate must not appear in live_delegation, even though
  -- delegation_vote keeps the row forever. Without it a DRep keeps counting closed accounts.
  --
  -- Compared by certificate, not by epoch. The epoch form of this assertion passed while the view
  -- was wrong, because the view made the same mistake: closing an account and reopening it in one
  -- epoch cancelled the delegation made moments later. Koios parity found it, 55 delegations deep.
  ASSERT (SELECT count(*) FROM palmares.live_delegation l
          JOIN public.delegation_vote dv ON dv.addr_id = l.addr_id
          WHERE EXISTS (SELECT 1 FROM public.stake_deregistration sd
                        WHERE sd.addr_id = l.addr_id
                          AND (sd.tx_id, sd.cert_index) > (dv.tx_id, dv.cert_index))
            AND NOT EXISTS (SELECT 1 FROM public.delegation_vote dv2
                            WHERE dv2.addr_id = l.addr_id
                              AND (dv2.tx_id, dv2.cert_index) > (dv.tx_id, dv.cert_index))) = 0,
    'no credential closed after its latest delegation may remain in live_delegation';

  -- The two delegator views must agree at the tip; they are built from different shapes (latest
  -- certificate vs. interval overlap) and disagreeing means one of them is wrong.
  SELECT count(*) INTO live_n FROM palmares.live_delegation WHERE drep_hash_id = d;
  SELECT delegator_count INTO epoch_n FROM palmares.drep_epoch_delegators
    WHERE drep_hash_id = d AND epoch_no = (SELECT epoch_no FROM palmares.sync_state);
  ASSERT live_n = epoch_n,
    format('live_delegation (%s) and drep_epoch_delegators at the tip (%s) must agree', live_n, epoch_n);
  -- No equality pin on the count itself: delegations come and go. It was 13 on 2026-10-19 and 12
  -- today, and neither is a defect.
  ASSERT live_n > 0, 'the fixture DRep must still have delegators for the agreement check to mean anything';

  ASSERT (SELECT count(DISTINCT target_kind) FROM palmares.vote_delegation) = 3,
    'delegations target a DRep or one of the two reserved options';

  -- ---- the tally ---------------------------------------------------------------------------
  -- Every final vote lands in exactly one counter; if this drifts, the tally is dropping or
  -- double-counting votes.
  ASSERT (SELECT sum(yes_count + no_count + abstain_count) FROM palmares.vote_tally
          WHERE voter_role = 'DRep')
         = (SELECT count(*) FROM palmares.vote WHERE voter_role = 'DRep' AND seq_last = 1),
    'the DRep counters sum to the number of final DRep votes';

  -- The basis is published, not implied: a ratio over cast votes is NOT the ledger's
  -- ratification arithmetic (which compares against total active voting power), so the column
  -- exists to stop a client reading it as such.
  ASSERT (SELECT count(DISTINCT basis) FROM palmares.vote_tally) = 1;
  ASSERT (SELECT min(basis) FROM palmares.vote_tally) = 'cast_votes_only';

  -- Every non-null threshold_param must name a real column of palmares.thresholds. This is what
  -- catches a 'pvt_pp_security_group' misspelling without depending on which actions happened to
  -- get SPO votes.
  ASSERT (SELECT count(*) FROM palmares.vote_tally t
          WHERE t.threshold_param IS NOT NULL
            AND NOT EXISTS (SELECT 1 FROM information_schema.columns c
                            WHERE c.table_schema = 'palmares' AND c.table_name = 'thresholds'
                              AND c.column_name = t.threshold_param)) = 0;

  -- The CC holds no stake, so its power columns are 0 by construction rather than by accident.
  ASSERT (SELECT count(*) FROM palmares.vote_tally
          WHERE voter_role = 'ConstitutionalCommittee'
            AND (yes_power <> 0 OR no_power <> 0 OR abstain_power <> 0)) = 0,
    'committee rows carry counts, not power';

  -- SPO power comes from pool_stat.voting_power, which this sync proved is populated. If it ever
  -- comes back all-zero, the tally has silently lost the join.
  ASSERT (SELECT count(*) FROM palmares.vote_tally
          WHERE voter_role = 'SPO' AND (yes_power > 0 OR no_power > 0 OR abstain_power > 0)) > 0,
    'SPO rows must carry real voting power from pool_stat';

  RAISE NOTICE 'power and tally ok: % power rows at epoch 319 (% real DReps), fixture DRep % delegators; tally rows: % DRep, % SPO, % CC',
    (SELECT count(*) FROM palmares.drep_epoch_power WHERE epoch_no = 319),
    (SELECT count(*) FROM palmares.drep_epoch_power WHERE epoch_no = 319 AND target_kind = 'drep'),
    live_n,
    (SELECT count(*) FROM palmares.vote_tally WHERE voter_role = 'DRep'),
    (SELECT count(*) FROM palmares.vote_tally WHERE voter_role = 'SPO'),
    (SELECT count(*) FROM palmares.vote_tally WHERE voter_role = 'ConstitutionalCommittee');
END $$;
