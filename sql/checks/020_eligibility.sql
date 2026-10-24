-- Checks for palmares.action_window and palmares.eligible_actions, against a caught-up preprod
-- db-sync (tip epoch >= 320).
--
-- Every count here is cut at `proposed_epoch < 320`, and that cut is what makes the figures
-- reproducible rather than a snapshot. Two facts make it sound:
--
--   * the set of actions proposed before epoch 320 can never grow;
--   * `last_votable_epoch < 320` cannot change for a member of that set. It is
--     LEAST(expiration, ratified, expired, dropped-1), and ratification/expiry/dropping can only
--     happen inside the window, i.e. at an epoch >= the one the action was still open in. So an
--     action settled before 320 stays settled, and one open at 320 can never become
--     settled-before-320.
--
-- Without the cut these would be assertions about a live counter: `count(*) = 131` breaks the
-- moment proposal 132 arrives, which is not a defect.
DO $$
DECLARE
  d bigint;
  n_elig bigint;
BEGIN
  -- ---- the window, as of epoch 320 ---------------------------------------------------------
  ASSERT (SELECT count(*) FROM palmares.action_window WHERE proposed_epoch < 320) = 131,
    'all proposals up to epoch 320';
  -- 120/11, from 119/12: `last_votable_epoch` was `expiration` and is now `expiration - 1`, which
  -- moved one action whose window had been published as open into the settled set. The 320 cut is
  -- safe for these two — an action settled by 320 cannot become open again — so they stay pinned.
  ASSERT (SELECT count(*) FROM palmares.action_window
          WHERE proposed_epoch < 320 AND last_votable_epoch < 320) = 120,
    'settled by epoch 320';
  ASSERT (SELECT count(*) FROM palmares.action_window
          WHERE proposed_epoch < 320 AND last_votable_epoch >= 320) = 11,
    'still open at epoch 320';
  -- The four excluded are the bootstrap-era 3 ParameterChange + 1 HardForkInitiation: during
  -- bootstrap a DRep could only vote on InfoAction.
  ASSERT (SELECT count(*) FROM palmares.action_window
          WHERE proposed_epoch < 320 AND last_votable_epoch < 320 AND drep_votable) = 116,
    'settled and DRep-votable';

  -- The window length is network configuration, not an action property: govActionLifetime is 6 on
  -- preprod and the ledger sets expiration = proposed + lifetime + 1, so the delta is 7 on every
  -- row. A single row with another delta means either a lifetime change or a bug in the join.
  ASSERT (SELECT count(*) FROM palmares.action_window WHERE expiration - proposed_epoch <> 7) = 0,
    'expiration is proposed_epoch + 7 on preprod (govActionLifetime 6, plus one)';

  -- `last_votable_epoch` can never fall outside the window.
  ASSERT (SELECT count(*) FROM palmares.action_window
          WHERE last_votable_epoch < proposed_epoch OR last_votable_epoch > expiration) = 0,
    'last_votable_epoch must lie within [proposed_epoch, expiration]';

  -- ---- the bootstrap window: epochs 163..180, closed history -------------------------------
  ASSERT (SELECT count(*) FROM palmares.action_window WHERE proposed_epoch BETWEEN 163 AND 180) = 6,
    'six proposals in the bootstrap window';
  ASSERT (SELECT count(*) FROM palmares.action_window
          WHERE proposed_epoch BETWEEN 163 AND 180 AND action_type = 'ParameterChange') = 3;
  ASSERT (SELECT count(*) FROM palmares.action_window
          WHERE proposed_epoch BETWEEN 163 AND 180 AND action_type = 'InfoAction') = 2;
  ASSERT (SELECT count(*) FROM palmares.action_window
          WHERE proposed_epoch BETWEEN 163 AND 180 AND action_type = 'HardForkInitiation') = 1;
  -- Only those three types could even be PROPOSED during bootstrap; anything else in the window
  -- would mean the epoch boundaries are wrong.
  ASSERT (SELECT count(*) FROM palmares.action_window
          WHERE proposed_epoch BETWEEN 163 AND 180
            AND action_type NOT IN ('ParameterChange', 'InfoAction', 'HardForkInitiation')) = 0,
    'bootstrap permitted only those three proposal types';

  -- ---- eligible_actions, the fixture DRep (registered epoch 173, never retired) ------------
  SELECT id INTO d FROM public.drep_hash
    WHERE raw = decode('81378d3ea89b68f0fc09944b1f93f2feb851318f196f98ba4029d8a8', 'hex');
  ASSERT d IS NOT NULL, 'the fixture DRep must exist';

  -- 115 = the 116 settled-and-votable actions minus the one whose window closed before epoch 173,
  -- i.e. before this DRep existed. That single row is the whole point of joining drep_interval.
  SELECT count(*) INTO n_elig FROM palmares.eligible_actions(d, 320);
  ASSERT n_elig = 115, format('fixture DRep eligible_actions: %s', n_elig);
  -- 80, from 79: the one action the `expiration - 1` correction moved into the settled set is a
  -- TreasuryWithdrawals, which is also why `n_elig` above went 114 -> 115. The seven per-type
  -- counts sum to `n_elig`, and that is asserted below rather than left to the reader.
  ASSERT (SELECT count(*) FROM palmares.eligible_actions(d, 320) WHERE action_type = 'TreasuryWithdrawals') = 80;
  ASSERT (SELECT count(*) FROM palmares.eligible_actions(d, 320) WHERE action_type = 'InfoAction') = 13;
  ASSERT (SELECT count(*) FROM palmares.eligible_actions(d, 320) WHERE action_type = 'ParameterChange') = 11;
  ASSERT (SELECT count(*) FROM palmares.eligible_actions(d, 320) WHERE action_type = 'NewCommittee') = 7;
  ASSERT (SELECT count(*) FROM palmares.eligible_actions(d, 320) WHERE action_type = 'HardForkInitiation') = 2;
  ASSERT (SELECT count(*) FROM palmares.eligible_actions(d, 320) WHERE action_type = 'NoConfidence') = 1;
  ASSERT (SELECT count(*) FROM palmares.eligible_actions(d, 320) WHERE action_type = 'NewConstitution') = 1;
  -- The seven above are the whole set: a type added to the ledger, or a row landing under a type
  -- nobody pinned, shows up here instead of silently not being counted.
  ASSERT (SELECT count(*) FROM palmares.eligible_actions(d, 320)
          WHERE action_type NOT IN ('TreasuryWithdrawals', 'InfoAction', 'ParameterChange',
                                    'NewCommittee', 'HardForkInitiation', 'NoConfidence',
                                    'NewConstitution')) = 0,
    'every eligible action falls under one of the seven pinned types';

  -- The empty case, asserted so the function can never pass vacuously: as of its own registration
  -- epoch this DRep has nothing settled behind it. A participation rate over an empty denominator
  -- is 'n/a', never 0%.
  ASSERT (SELECT count(*) FROM palmares.eligible_actions(d, 173)) = 0,
    'an empty eligibility set as of the registration epoch';

  -- An eligible action is always settled and always DRep-votable; this is the function's contract
  -- stated independently of the counts above.
  ASSERT (SELECT count(*) FROM palmares.eligible_actions(d, 320) e
          JOIN palmares.action_window a ON a.gov_action_id = e.gov_action_id
          WHERE NOT a.drep_votable OR a.last_votable_epoch >= 320) = 0,
    'eligible_actions must yield only settled, DRep-votable actions';

  RAISE NOTICE 'action_window ok: % proposals total (% of them proposed before epoch 320), % SPO-votable; fixture DRep eligible for %',
    (SELECT count(*) FROM palmares.action_window),
    (SELECT count(*) FROM palmares.action_window WHERE proposed_epoch < 320),
    (SELECT count(*) FROM palmares.action_window WHERE spo_votable),
    n_elig;
END $$;
