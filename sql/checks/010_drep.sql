-- Checks for the DRep views, run against a CAUGHT-UP preprod db-sync (tip epoch >= 320).
--
-- What this file may assert, and what it may not:
--
--   * INVARIANTS of the views — no fan-out, a total status partition, exactly one sync_state row.
--     These must hold at every tip.
--   * IMMUTABLE HISTORY — the fixture DRep registered in epoch 173 at a specific second. The
--     chain cannot rewrite that.
--
-- It must NOT assert today's value of a live counter. The plan drafted
-- `count(*) FROM drep_hash = 802` and `registered = 294` from a measurement on 2026-10-19;
-- re-measured on 2026-10-20 they were 814 and 297, because db-sync inserts a drep_hash row for
-- every credential that appears in a delegation and registrations keep arriving. An assertion
-- like that fails for the one reason that is not a defect, and a check that cries wolf gets
-- commented out. Where a magnitude is worth recording it goes in a RAISE NOTICE, not an ASSERT.
DO $$
DECLARE
  n_total   bigint;
  n_real    bigint;
  n_reg     bigint;
  n_ret     bigint;
  n_never   bigint;
BEGIN
  -- ---- invariants -------------------------------------------------------------------------
  -- One row per real credential, and not one more. This is what caught db-sync 13.7's duplicate
  -- off_chain_vote_drep_data rows: three DReps appeared twice, 812 credentials -> 815 rows.
  SELECT count(*) INTO n_total FROM palmares.drep;
  SELECT count(*) INTO n_real FROM public.drep_hash WHERE raw IS NOT NULL;
  ASSERT n_total = n_real,
    format('palmares.drep must have one row per credential with raw NOT NULL: %s rows vs %s credentials', n_total, n_real);

  ASSERT (SELECT count(*) FROM palmares.drep WHERE drep_raw IS NULL) = 0,
    'the reserved drep_always_abstain / drep_always_no_confidence options are not DReps';

  -- The status partition is total: every row lands in exactly one bucket.
  SELECT count(*) INTO n_reg   FROM palmares.drep WHERE registration_status = 'registered';
  SELECT count(*) INTO n_ret   FROM palmares.drep WHERE registration_status = 'retired';
  SELECT count(*) INTO n_never FROM palmares.drep WHERE registration_status = 'never_registered';
  ASSERT n_reg + n_ret + n_never = n_total,
    'registration_status must be one of registered / retired / never_registered';

  -- A credential with no certificate must never read as registered: db-sync creates drep_hash
  -- rows for delegation targets, and reading those as DReps was the headline counting error.
  ASSERT (SELECT count(*) FROM palmares.drep d
          WHERE d.registration_status <> 'never_registered'
            AND NOT EXISTS (SELECT 1 FROM palmares.drep_cert c WHERE c.drep_hash_id = d.drep_hash_id)) = 0,
    'a DRep with no certificate must be never_registered';

  -- An open interval means registered, and a closed one must close at or after it opened.
  ASSERT (SELECT count(*) FROM palmares.drep_interval WHERE to_epoch IS NOT NULL AND to_epoch < from_epoch) = 0,
    'drep_interval must not close before it opens';

  ASSERT (SELECT count(DISTINCT cert_kind) FROM palmares.drep_cert) = 3,
    'drep_cert must carry all three kinds: register, update, retire';
  ASSERT (SELECT count(*) FROM palmares.drep_cert WHERE cert_kind NOT IN ('register', 'update', 'retire')) = 0,
    'cert_kind is closed over those three';

  -- sync_state is a singleton and guards the network.
  ASSERT (SELECT count(*) FROM palmares.sync_state) = 1, 'sync_state must be exactly one row';
  ASSERT (SELECT network_name FROM palmares.sync_state) = 'preprod',
    'these checks assume preprod; running them against another network is a configuration error';
  -- `ledger: enable` took: the DRep stake distribution is at most one epoch behind the tip.
  -- Without ledger state this column would be far behind or NULL, and every voting-power number
  -- would be missing rather than wrong.
  ASSERT (SELECT drep_distr_epoch >= epoch_no - 1 FROM palmares.sync_state),
    'drep_distr is more than one epoch behind the tip: is ledger state enabled?';

  -- ---- immutable history: the fixture DRep (Bitcows) --------------------------------------
  ASSERT (SELECT count(*) FROM palmares.drep_interval i
          JOIN public.drep_hash h ON h.id = i.drep_hash_id
          WHERE h.raw = decode('81378d3ea89b68f0fc09944b1f93f2feb851318f196f98ba4029d8a8', 'hex')) = 1,
    'the fixture DRep has exactly one registration interval';
  ASSERT (SELECT from_epoch FROM palmares.drep_interval i
          JOIN public.drep_hash h ON h.id = i.drep_hash_id
          WHERE h.raw = decode('81378d3ea89b68f0fc09944b1f93f2feb851318f196f98ba4029d8a8', 'hex')) = 173,
    'the fixture DRep registered in epoch 173';
  ASSERT (SELECT to_epoch IS NULL FROM palmares.drep_interval i
          JOIN public.drep_hash h ON h.id = i.drep_hash_id
          WHERE h.raw = decode('81378d3ea89b68f0fc09944b1f93f2feb851318f196f98ba4029d8a8', 'hex')),
    'the fixture DRep has never retired, so its interval is open';
  ASSERT (SELECT from_time FROM palmares.drep_interval i
          JOIN public.drep_hash h ON h.id = i.drep_hash_id
          WHERE h.raw = decode('81378d3ea89b68f0fc09944b1f93f2feb851318f196f98ba4029d8a8', 'hex'))
         = '2024-10-16 20:38:10'::timestamp,
    'the fixture DRep registered at a specific second, and that cannot change';
  -- The CIP-119 path end to end: certificate -> anchor -> off-chain data -> drep metadata.
  ASSERT (SELECT given_name FROM palmares.drep d
          JOIN public.drep_hash h ON h.id = d.drep_hash_id
          WHERE h.raw = decode('81378d3ea89b68f0fc09944b1f93f2feb851318f196f98ba4029d8a8', 'hex')) = 'Bitcows',
    'the CIP-119 display name must resolve through palmares.anchor';

  RAISE NOTICE 'drep views ok: % credentials (% registered, % retired, % never registered), % with CIP-119 metadata',
    n_total, n_reg, n_ret, n_never,
    (SELECT count(*) FROM palmares.drep WHERE given_name IS NOT NULL);

  -- The size of the `unknown` bucket: registered DReps for whom the ledger recorded no activity
  -- deadline, because drep_distr has never held a row for them. This is the whole justification for
  -- the API's third status, so the number is worth printing on every run — a NOTICE and not an
  -- ASSERT, per this file's own rule, because it is a live counter. 90 of 294 when the decision was
  -- taken (2026-10-21, epoch 320). If it ever reaches 0 the third status has become dead weight; if
  -- it grows, the status is carrying more weight than it did, which is the thing to know before
  -- mainnet.
  RAISE NOTICE '  of which % registered DReps have no ledger deadline (API status = unknown)',
    (SELECT count(*) FROM palmares.drep
     WHERE registration_status = 'registered' AND active_until_epoch IS NULL);
END $$;
