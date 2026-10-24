-- Checks for palmares.gov_action, palmares.committee_member and palmares.treasury_withdrawal,
-- against a caught-up preprod db-sync (tip epoch >= 320).
-- Prerequisite: sql/indexes/001_gov_indexes.sql.
--
-- The first assertion in each group is a NO-FAN-OUT invariant, and that is not ceremony: writing
-- these views, two separate join mistakes inflated row counts here (131 actions -> 135, and
-- 3 committee members -> 1,563). Both were invisible in every other assertion and both corrupted
-- downstream sums.
DO $$
DECLARE
  n_actions bigint;
BEGIN
  -- ---- gov_action --------------------------------------------------------------------------
  SELECT count(*) INTO n_actions FROM palmares.gov_action;
  ASSERT n_actions = (SELECT count(*) FROM public.gov_action_proposal),
    format('one row per proposal: %s rows for %s proposals', n_actions,
           (SELECT count(*) FROM public.gov_action_proposal));
  ASSERT (SELECT count(*) FROM (SELECT gov_action_id FROM palmares.gov_action
                                GROUP BY 1 HAVING count(*) > 1) q) = 0,
    'gov_action_id must be unique';

  -- Lifecycle, cut at epoch 320 so the counts are history rather than a live tally.
  ASSERT (SELECT count(*) FROM palmares.gov_action WHERE proposed_epoch < 320) = 131;
  ASSERT (SELECT count(*) FROM palmares.gov_action
          WHERE proposed_epoch < 320 AND state = 'enacted') = 11;
  ASSERT (SELECT count(*) FROM palmares.gov_action
          WHERE proposed_epoch < 320 AND ratified_epoch IS NOT NULL) = 11;
  -- __THESE TWO ARE NOT PINNED, AND THE REASON IS THE CUT ABOVE.__ `proposed_epoch < 320` freezes
  -- which actions are counted; it does not freeze a lifecycle column that the chain writes at
  -- SETTLEMENT, which happens later. An action proposed in epoch 319 expires after 320, so both
  -- counts climb with the chain: `expired_epoch` was pinned at 103 and measured 107, `dropped_epoch`
  -- at 108 and measured 109. The assertion fails on a correct view, which is the shape of pin that
  -- gets a gate switched off rather than fixed.
  --
  -- What IS invariant is the relation between them, and that is asserted below. The magnitudes are
  -- reported so a reader still sees them move.
  RAISE NOTICE 'lifecycle (proposed before 320, counts move with the chain): % expired, % dropped',
    (SELECT count(*) FROM palmares.gov_action WHERE proposed_epoch < 320 AND expired_epoch IS NOT NULL),
    (SELECT count(*) FROM palmares.gov_action WHERE proposed_epoch < 320 AND dropped_epoch IS NOT NULL);
  ASSERT (SELECT count(*) FROM palmares.gov_action
          WHERE proposed_epoch < 320 AND dropped_epoch IS NOT NULL
            AND expired_epoch IS NULL AND ratified_epoch IS NULL) = 6, 'dropped-only';
  -- No action is 'ratified' without being 'enacted' on preprod: all 11 ratified were enacted.
  ASSERT (SELECT count(*) FROM palmares.gov_action
          WHERE proposed_epoch < 320 AND state = 'ratified') = 0;

  -- `state` and `last_votable_epoch` answer different questions, and the INVARIANT is what is
  -- asserted — not the magnitudes, which move with the chain for the reason given above (the
  -- 'proposed' count was pinned at 11 and measured 7, because four of those actions have since
  -- expired).
  --
  -- The relation: every action is either enacted, expired, dropped-only, or still 'proposed'.
  ASSERT (SELECT count(*) FROM palmares.gov_action WHERE proposed_epoch < 320 AND state = 'proposed')
       = (SELECT count(*) FROM palmares.gov_action WHERE proposed_epoch < 320)
       - (SELECT count(*) FROM palmares.gov_action WHERE proposed_epoch < 320 AND state = 'enacted')
       - (SELECT count(*) FROM palmares.gov_action WHERE proposed_epoch < 320 AND expired_epoch IS NOT NULL)
       - (SELECT count(*) FROM palmares.gov_action WHERE proposed_epoch < 320 AND dropped_epoch IS NOT NULL
            AND expired_epoch IS NULL AND ratified_epoch IS NULL),
    'the four lifecycle outcomes must partition the proposals';
  -- And `state` is not votability: an action whose `expired_epoch` is the current epoch reads as
  -- `expired` while `last_votable_epoch` has already closed its window the epoch before. Since
  -- `last_votable_epoch = expiration - 1`, no action can now be both 'expired' by state and still
  -- votable — which is itself the invariant worth asserting, and it replaces the count.
  ASSERT (SELECT count(*) FROM palmares.gov_action
          WHERE expired_epoch IS NOT NULL AND last_votable_epoch >= expired_epoch) = 0,
    'an expired action cannot still be votable in or after the epoch it expired';
  RAISE NOTICE 'still votable now: %',
    (SELECT count(*) FROM palmares.gov_action WHERE last_votable_epoch >= (SELECT epoch_no FROM palmares.sync_state));

  -- votes_cast counts FINAL votes, so it must equal the seq_last filter exactly. A mismatch means
  -- either the re-vote numbering or this subquery drifted.
  ASSERT (SELECT count(*) FROM palmares.gov_action g
          WHERE g.votes_cast <> (SELECT count(*) FROM palmares.vote v
                                 WHERE v.gov_action_id = g.gov_action_id AND v.seq_last = 1)) = 0;

  -- ---- committee ---------------------------------------------------------------------------
  -- preprod's committee: 3 members, 2-of-3 quorum, all script credentials, all expiring at 372.
  ASSERT (SELECT count(*) FROM palmares.committee_member WHERE is_enacted) = 3,
    'exactly three enacted members (a fan-out here read 1,563)';
  ASSERT (SELECT count(DISTINCT cold_hash) FROM palmares.committee_member WHERE is_enacted) = 3,
    'and three DISTINCT cold credentials';
  ASSERT (SELECT count(*) FROM palmares.committee_member
          WHERE is_enacted AND NOT cold_has_script) = 0, 'all script credentials';
  ASSERT (SELECT count(*) FROM palmares.committee_member
          WHERE is_enacted AND expiration_epoch <> 372) = 0;
  ASSERT (SELECT count(DISTINCT quorum_numerator || '/' || quorum_denominator)
          FROM palmares.committee_member WHERE is_enacted) = 1;
  ASSERT (SELECT DISTINCT quorum_numerator || '/' || quorum_denominator
          FROM palmares.committee_member WHERE is_enacted) = '2/3';
  -- Each enacted member has a hot key registered; without one it could not have voted at all.
  ASSERT (SELECT count(*) FROM palmares.committee_member
          WHERE is_enacted AND hot_hash IS NULL) = 0;

  -- This is what makes palmares.vote's hot-to-cold resolution checkable end to end: every CC vote
  -- resolves to a cold credential that is a real committee member. It is also the assertion that
  -- would have caught the near-miss of joining a hot key id against committee_hash_id.
  ASSERT (SELECT count(*) FROM palmares.vote v
          WHERE v.voter_role = 'ConstitutionalCommittee'
            AND NOT EXISTS (SELECT 1 FROM palmares.committee_member m
                            WHERE m.cold_hash = v.voter_cold_hash)) = 0,
    'every CC voter resolves to a committee member';

  -- ---- treasury ----------------------------------------------------------------------------
  ASSERT (SELECT count(*) FROM palmares.treasury_withdrawal)
         = (SELECT count(*) FROM public.treasury_withdrawal),
    'one row per withdrawal: the reward_rest LEFT JOIN must not fan out';

  -- The per-action total must agree with gov_action.withdrawal_total, which is summed
  -- independently over public.treasury_withdrawal. This is the assertion that caught the
  -- off_chain_vote_gov_action_data duplicate rows: the fan-out double-counted 6 actions' totals.
  ASSERT (SELECT count(*) FROM palmares.gov_action g
          WHERE g.action_type = 'TreasuryWithdrawals'
            AND coalesce(g.withdrawal_total, 0)
                <> (SELECT coalesce(sum(amount), 0) FROM palmares.treasury_withdrawal t
                    WHERE t.gov_action_id = g.gov_action_id)) = 0,
    'withdrawal_total agrees with the per-action sum';

  RAISE NOTICE 'actions/committee/treasury ok: % actions (% enacted, % expired, % dropped-only, % proposed), 3 committee members at 2/3, % withdrawals',
    n_actions,
    (SELECT count(*) FROM palmares.gov_action WHERE state = 'enacted'),
    (SELECT count(*) FROM palmares.gov_action WHERE state = 'expired'),
    (SELECT count(*) FROM palmares.gov_action WHERE state = 'dropped'),
    (SELECT count(*) FROM palmares.gov_action WHERE state = 'proposed'),
    (SELECT count(*) FROM palmares.treasury_withdrawal);
END $$;
