-- palmares views over db-sync's public schema; objects appended by later tasks.

-- ---------------------------------------------------------------------------------------------
-- palmares.anchor — one row per voting anchor, with ONE verdict column.
--
-- Every anchor db-sync knows about appears here exactly once, and `verdict` is total: there is no
-- input for which it is NULL. That totality is what F1 check 7 ("every anchor has a verdict")
-- asserts, and it is why the last arm is a default rather than another pattern.
--
-- The verdict strings are the API's vocabulary, so they are fixed here and nowhere else:
--   valid           the anchor was fetched, the hash matched, and the body passed the CIP-100 check
--   invalid_schema  fetched and the hash matched, but the body did not pass (or the check was
--                   inconclusive: db-sync writes is_valid NULL for that, and preprod has such a row)
--   hash_mismatch   fetched, but the body did not hash to data_hash
--   oversized       the body exceeded db-sync's cap
--   unreachable     the fetch failed for any other reason (DNS, TLS, HTTP status, bad URL)
--   inline          a `data:` URI: the content IS the URL, so there is nothing to fetch and
--                   hash verification is vacuous
--   not_fetched     the anchor is known and nothing has been attempted yet. db-sync queues
--                   fetches and flushes them periodically, so during the first hours of a sync
--                   most anchors are here. Collapsing this into `unreachable` would be a false
--                   accusation against the author of a brand-new proposal.
--
-- Two details are easy to get wrong and are deliberate:
--
-- 1. `inline` is tested FIRST. A `data:` anchor also carries a URL-parse row in
--    off_chain_vote_fetch_error (db-sync's parseOffChainUrl requires http(s)), so any later
--    position would report it as `unreachable`.
-- 2. The failure patterns match db-sync's PROSE, not its constructor names. The persisted text is
--    `show err` over OffChainFetchError, which renders human-readable sentences; matching
--    '%HashMismatch%' or '%DataTooLong%' would never fire and every failure would read
--    `unreachable`. Verified against the live preprod rows:
--      'Hash mismatch when fetching metadata from <url>. Expected "…" but got "…".'
--      'Error Offchain Voting Anchor: Size error, fetching metadata from <url> exceeded 512 bytes.'
--      'Error Offchain Voting Anchor: URL parse error for <url>'
--    The "512 bytes" in the size message is an upstream copy-paste bug (the real vote cap is 3 MB),
--    so the number is never parsed — only the sentence is matched.
CREATE VIEW palmares.anchor AS
SELECT
  va.id AS voting_anchor_id,
  va.url,
  va.data_hash,
  va.type AS anchor_type,
  CASE
    WHEN va.url LIKE 'data:%' THEN 'inline'
    WHEN d.id IS NOT NULL AND d.is_valid IS TRUE THEN 'valid'
    WHEN d.id IS NOT NULL THEN 'invalid_schema'
    WHEN e.fetch_error LIKE 'Hash mismatch%' THEN 'hash_mismatch'
    WHEN e.fetch_error LIKE '%Size error, fetching metadata from%' THEN 'oversized'
    WHEN e.id IS NOT NULL THEN 'unreachable'
    ELSE 'not_fetched'
  END AS verdict,
  -- The CIP-100 schema check on its own, kept separate from the verdict: `valid` already implies
  -- TRUE, but a consumer that wants to tell "checked and failed" (FALSE) from "check was
  -- inconclusive" (NULL) cannot recover that from the verdict alone.
  d.is_valid AS cip100_valid,
  -- The off-chain row's own id, so the CIP-119 (DRep) and CIP-108 (gov action) child tables can
  -- be reached through this view instead of every consumer re-joining off_chain_vote_data by
  -- voting_anchor_id. Additive: it changes no verdict.
  d.id AS off_chain_vote_data_id,
  d.language,
  d.comment,
  d.warning,
  d.json,
  e.fetch_error,
  e.fetch_time,
  e.retry_count
FROM public.voting_anchor va
LEFT JOIN public.off_chain_vote_data d ON d.voting_anchor_id = va.id
-- The newest attempt wins: retry_count counts up, so ORDER BY it descending picks the last
-- failure rather than an arbitrary one. LATERAL + LIMIT 1 keeps this view one-row-per-anchor
-- even though a single anchor accumulates many error rows.
LEFT JOIN LATERAL (
  SELECT x.id, x.fetch_error, x.fetch_time, x.retry_count
  FROM public.off_chain_vote_fetch_error x
  WHERE x.voting_anchor_id = va.id
  ORDER BY x.retry_count DESC
  LIMIT 1
) e ON true;

-- ---------------------------------------------------------------------------------------------
-- palmares.sync_state — exactly one row: where db-sync has got to, and which network it is.
--
-- `ORDER BY b.id DESC LIMIT 1` is db-sync's own idiom for finding the tip (doc/manual-rollbacks.md),
-- and block.id is the primary key. The tempting `max(time)` form seq-scans, and the stage-4
-- indexes that would help only exist once db-sync is within 30 minutes of tip — i.e. exactly not
-- during the sync when a freshness probe matters most.
--
-- `block.time` is `timestamp` WITHOUT time zone while `now()` is `timestamptz`, so subtracting
-- them directly resolves through the session's TimeZone and is wrong by that offset on any
-- non-UTC session. `now() AT TIME ZONE 'UTC'` pins it.
--
-- `network_name` is here so a caller can refuse to serve mainnet answers from a preprod database
-- (and the other way round) instead of silently mixing them.
CREATE VIEW palmares.sync_state AS
SELECT
  b.block_no,
  b.slot_no,
  b.epoch_no,
  b.hash AS tip_hash,
  b.time AS tip_time,
  EXTRACT(EPOCH FROM (now() AT TIME ZONE 'UTC' - b.time))::bigint AS lag_seconds,
  -- The latest epoch for which the ledger produced a DRep stake distribution. This lags the tip
  -- by at most one epoch when `ledger: enable` took; if it is far behind, db-sync is running
  -- without ledger state and every voting-power number would be missing rather than wrong.
  (SELECT max(epoch_no) FROM public.drep_distr) AS drep_distr_epoch,
  (SELECT max(stage_two) FROM public.schema_version) AS dbsync_schema_stage_two,
  (SELECT network_name FROM public.meta LIMIT 1) AS network_name
FROM public.block b
ORDER BY b.id DESC
LIMIT 1;

-- ---------------------------------------------------------------------------------------------
-- palmares.drep_cert — the DRep certificate log, one row per certificate.
--
-- db-sync encodes the kind in the deposit column and nowhere else (schema.md, drep_registration):
-- a positive deposit is a registration, a negative one a retirement, and NULL is a metadata
-- update. `cert_index` is carried because two certificates can land in the same slot, and slot
-- alone cannot order them — which matters to every "the latest certificate wins" rule.
CREATE VIEW palmares.drep_cert AS
SELECT
  r.drep_hash_id,
  CASE
    WHEN r.deposit > 0 THEN 'register'
    WHEN r.deposit < 0 THEN 'retire'
    ELSE 'update'
  END AS cert_kind,
  tx.hash AS tx_hash,
  b.slot_no,
  b.epoch_no,
  b.time AS cert_time,
  -- Part of the total order palmares.activity's cursor needs: cert_index orders certificates
  -- WITHIN a transaction, tx_index orders transactions within a block.
  tx.block_index AS tx_index,
  r.cert_index,
  r.deposit,
  r.voting_anchor_id
FROM public.drep_registration r
JOIN public.tx ON tx.id = r.tx_id
JOIN public.block b ON b.id = tx.block_id;

-- ---------------------------------------------------------------------------------------------
-- palmares.drep_interval — one row per registration interval, so "was this DRep registered at
-- time T" is a range test rather than a guess from the latest certificate.
--
-- A DRep may retire and register again; eligibility is the union of the intervals, and age sums
-- them. `from_slot` is carried for the same reason `drep_cert.cert_index` is: epoch alone cannot
-- order intra-epoch events, and the retirement lookup is bounded by slot.
--
-- Metadata updates are filtered out: they neither open nor close an interval.
CREATE VIEW palmares.drep_interval AS
WITH ev AS (
  SELECT
    r.drep_hash_id,
    b.epoch_no,
    b.slot_no,
    b.time,
    r.cert_index,
    CASE WHEN r.deposit > 0 THEN 'register' WHEN r.deposit < 0 THEN 'retire' END AS kind
  FROM public.drep_registration r
  JOIN public.tx ON tx.id = r.tx_id
  JOIN public.block b ON b.id = tx.block_id
  WHERE r.deposit IS NOT NULL
),
seq AS (
  SELECT
    ev.*,
    LEAD(epoch_no) OVER w AS next_epoch,
    LEAD(kind) OVER w AS next_kind
  FROM ev
  WINDOW w AS (PARTITION BY drep_hash_id ORDER BY slot_no, cert_index)
)
SELECT
  drep_hash_id,
  epoch_no AS from_epoch,
  slot_no AS from_slot,
  time AS from_time,
  CASE WHEN next_kind = 'retire' THEN next_epoch END AS to_epoch
FROM seq
WHERE kind = 'register';

-- ---------------------------------------------------------------------------------------------
-- palmares.drep — one row per real DRep credential.
--
-- Two rules here are the ones that make the DRep counts correct, and both contradict the obvious
-- reading of db-sync's schema:
--
-- 1. A `drep_hash` row does NOT mean "a DRep". db-sync inserts one for any credential that merely
--    appears in a delegation ("the existance of an entry doesn't mean the DRep is registered",
--    schema.md), so `registration_status` is derived from the latest certificate and never from
--    the presence of this row. A credential with no certificate at all is `never_registered`.
-- 2. `drep_hash.raw IS NULL` is not a DRep either: those are the two reserved ledger options,
--    `drep_always_abstain` and `drep_always_no_confidence`. They are voting choices, not actors,
--    and they are excluded here so no per-DRep metric counts them.
--
-- `drep_hash.view` is deliberately NOT exposed: it is the CIP-105 rendering, which uses the same
-- HRP for key and script credentials and therefore cannot be compared against Koios, GovTool or a
-- wallet. The pair (drep_raw, has_script) goes out instead, and Palmares.DomainTypes.Core.Ids
-- does the CIP-129 encoding.
CREATE VIEW palmares.drep AS
WITH latest_cert AS (
  -- The certificate that decides the current status: last by (slot, cert_index).
  SELECT DISTINCT ON (drep_hash_id)
    drep_hash_id, cert_kind, slot_no, cert_time
  FROM palmares.drep_cert
  ORDER BY drep_hash_id, slot_no DESC, cert_index DESC
),
latest_anchor AS (
  -- CIP-119 metadata comes from the most recent certificate that carried an anchor: a metadata
  -- update supersedes the registration's anchor, and a retirement usually carries none.
  SELECT DISTINCT ON (drep_hash_id)
    drep_hash_id, voting_anchor_id
  FROM palmares.drep_cert
  WHERE voting_anchor_id IS NOT NULL
  ORDER BY drep_hash_id, slot_no DESC, cert_index DESC
),
cert_span AS (
  SELECT
    drep_hash_id,
    min(slot_no) AS first_cert_slot,
    min(cert_time) AS first_cert_time,
    max(slot_no) AS last_cert_slot,
    max(cert_time) AS last_cert_time
  FROM palmares.drep_cert
  GROUP BY drep_hash_id
),
latest_distr AS (
  -- One stake-distribution row per DRep per epoch; the newest epoch carries the live active_until.
  SELECT DISTINCT ON (hash_id)
    hash_id, active_until
  FROM public.drep_distr
  ORDER BY hash_id, epoch_no DESC
),
drep_meta AS (
  -- ponytail: db-sync 13.7.1.0/13.7.2.1 write DUPLICATE off-chain metadata child rows (release
  -- notes, "Known issues"; fixed by PR #2137 in the unreleased line). Measured here: 3 DReps on
  -- preprod had two off_chain_vote_drep_data rows for one off_chain_vote_data_id, which fanned
  -- palmares.drep out to 815 rows for 812 credentials. DISTINCT ON by lowest id picks the
  -- first-inserted deterministically. Drop this CTE and join directly after upgrading past
  -- 13.7.2.1 -- and re-run sql/checks/010_drep.sql, which is what caught it.
  SELECT DISTINCT ON (off_chain_vote_data_id)
    off_chain_vote_data_id, given_name, image_url
  FROM public.off_chain_vote_drep_data
  ORDER BY off_chain_vote_data_id, id
)
SELECT
  h.id AS drep_hash_id,
  h.raw AS drep_raw,
  h.has_script,
  CASE
    WHEN lc.cert_kind IS NULL THEN 'never_registered'
    WHEN lc.cert_kind = 'retire' THEN 'retired'
    ELSE 'registered'
  END AS registration_status,
  -- Registered is not the same as active: the ledger drops a DRep's voting power when it has not
  -- voted for drep_activity epochs, and active_until is where the ledger records that deadline.
  -- COALESCE keeps this two-valued. `active_until IS NULL` already yields false, but on a
  -- database with no blocks yet the sync_state subquery is NULL and the comparison would be too;
  -- a boolean flag that can be NULL invites a three-valued bug in the API layer.
  COALESCE(ld.active_until >= (SELECT epoch_no FROM palmares.sync_state), false) AS is_active,
  ld.active_until AS active_until_epoch,
  la.voting_anchor_id,
  cs.first_cert_slot,
  cs.first_cert_time,
  cs.last_cert_slot,
  cs.last_cert_time,
  dd.given_name,
  dd.image_url,
  a.language
FROM public.drep_hash h
LEFT JOIN latest_cert lc ON lc.drep_hash_id = h.id
LEFT JOIN latest_anchor la ON la.drep_hash_id = h.id
LEFT JOIN cert_span cs ON cs.drep_hash_id = h.id
LEFT JOIN latest_distr ld ON ld.hash_id = h.id
LEFT JOIN palmares.anchor a ON a.voting_anchor_id = la.voting_anchor_id
LEFT JOIN drep_meta dd ON dd.off_chain_vote_data_id = a.off_chain_vote_data_id
WHERE h.raw IS NOT NULL;

-- ---------------------------------------------------------------------------------------------
-- palmares.action_window — the authoritative voting window of every governance action.
--
-- Everything downstream that says "was this actor allowed to vote on this action" reads this view
-- and nothing else. The ledger rule is: a vote is valid while `currentEpoch <= gasExpiresAfter`
-- AND the action is still in the proposals set
-- (cardano-ledger Conway/Rules/Gov.hs, checkVotesAreNotForExpiredActions).
--
-- `last_votable_epoch` treats the four lifecycle columns asymmetrically, and that asymmetry is
-- empirical, not aesthetic. Measured over all 131 preprod proposals (Koios proposal_list,
-- 2026-10-19):
--   * `ratified_epoch` is NOT decremented: on 3 of the 9 voted ratified actions the last DRep
--     vote landed in the SAME epoch as ratified_epoch (228/228, 251/251, 293/293).
--   * `dropped_epoch` IS decremented: on all 4 voted dropped-only actions the last vote landed at
--     dropped_epoch - 1 (251/252, 294/296, 304/305, 312/313). Those 6 dropped-only rows are
--     actions invalidated because a competing action was enacted; the action left the proposals
--     set at the boundary.
--   * `expired_epoch = expiration` in 103/103 cases, and no vote was ever observed later than
--     expired_epoch - 1, so using `expiration` is permissive but never wrong.
-- Note this contradicts the schema doc's claim that "a proposal is dropped when it's expired or
-- enacted": enacted actions carry enacted_epoch = ratified_epoch + 1 with dropped_epoch AND
-- expired_epoch both NULL.
--
-- `drep_votable` is the Conway bootstrap test, and it is a test over the WHOLE WINDOW rather than
-- over the proposing block. During bootstrap a DRep could only vote on InfoAction, so an action
-- proposed under protocol major 9 but still votable after the fork IS DRep-votable. Using
-- `proposed_proto_major` instead would silently shrink every participation denominator;
-- that column is kept for display and audit only.
CREATE VIEW palmares.action_window AS
SELECT
  g.id AS gov_action_id,
  g.type AS action_type,
  b.epoch_no AS proposed_epoch,
  b.slot_no AS proposed_slot,
  b.time AS proposed_at,
  b.proto_major AS proposed_proto_major,
  g.expiration,
  LEAST(
    g.expiration,
    COALESCE(g.ratified_epoch, g.expiration),
    COALESCE(g.expired_epoch, g.expiration),
    COALESCE(g.dropped_epoch - 1, g.expiration)
  ) AS last_votable_epoch,
  (
    g.type = 'InfoAction'
    OR EXISTS (
      SELECT 1
      FROM public.epoch_param ep
      WHERE ep.epoch_no BETWEEN b.epoch_no AND LEAST(
              g.expiration,
              COALESCE(g.ratified_epoch, g.expiration),
              COALESCE(g.expired_epoch, g.expiration),
              COALESCE(g.dropped_epoch - 1, g.expiration))
        AND ep.protocol_major <> 9
    )
  ) AS drep_votable,
  -- SPO eligibility. An SPO never votes on a treasury withdrawal or a new constitution, votes on
  -- everything else, and votes on a ParameterChange only when the update touches the ledger's
  -- SecurityGroup. The eleven columns below are every `THKD ('PPGroups _ 'SecurityGroup)` field of
  -- Conway/PParams.hs mapped to param_proposal: a NULL means the proposal does not touch it.
  CASE g.type
    WHEN 'TreasuryWithdrawals' THEN FALSE
    WHEN 'NewConstitution' THEN FALSE
    WHEN 'ParameterChange' THEN EXISTS (
      SELECT 1
      FROM public.param_proposal p
      WHERE p.id = g.param_proposal
        AND (
          p.min_fee_a IS NOT NULL
          OR p.min_fee_b IS NOT NULL
          OR p.max_block_size IS NOT NULL
          OR p.max_tx_size IS NOT NULL
          OR p.max_bh_size IS NOT NULL
          OR p.coins_per_utxo_size IS NOT NULL
          OR p.max_block_ex_mem IS NOT NULL
          OR p.max_block_ex_steps IS NOT NULL
          OR p.max_val_size IS NOT NULL
          OR p.gov_action_deposit IS NOT NULL
          OR p.min_fee_ref_script_cost_per_byte IS NOT NULL
        )
    )
    ELSE TRUE
  END AS spo_votable,
  g.param_proposal
FROM public.gov_action_proposal g
JOIN public.tx ON tx.id = g.tx_id
JOIN public.block b ON b.id = tx.block_id;

-- ---------------------------------------------------------------------------------------------
-- palmares.thresholds — the governance parameters of each epoch, and only those.
--
-- `epoch_param` has ~70 columns; this view lists the governance ones EXPLICITLY rather than
-- scanning for a prefix, because `pvtpp_security_group` does not share the `pvt_` prefix of its
-- four siblings. A prefix filter in application code silently drops the one threshold that
-- decides whether an SPO vote on a ParameterChange counts at all.
CREATE VIEW palmares.thresholds AS
SELECT
  ep.epoch_no,
  -- DRep thresholds
  ep.dvt_motion_no_confidence,
  ep.dvt_committee_normal,
  ep.dvt_committee_no_confidence,
  ep.dvt_update_to_constitution,
  ep.dvt_hard_fork_initiation,
  ep.dvt_p_p_network_group,
  ep.dvt_p_p_economic_group,
  ep.dvt_p_p_technical_group,
  ep.dvt_p_p_gov_group,
  ep.dvt_treasury_withdrawal,
  -- SPO thresholds
  ep.pvt_motion_no_confidence,
  ep.pvt_committee_normal,
  ep.pvt_committee_no_confidence,
  ep.pvt_hard_fork_initiation,
  ep.pvtpp_security_group,
  -- committee and action parameters
  ep.committee_min_size,
  ep.committee_max_term_length,
  -- NOTE: gov_action_lifetime is the LIFETIME, not the window. The ledger sets
  -- `gov_action_proposal.expiration = proposed_epoch + lifetime + 1`, so on preprod this column
  -- reads 6 while the observed delta is 7 on all 131 actions. Anything that needs the last
  -- votable epoch must read `palmares.action_window`, never arithmetic over this number.
  ep.gov_action_lifetime,
  ep.gov_action_deposit,
  ep.drep_deposit,
  ep.drep_activity
FROM public.epoch_param ep;

-- ---------------------------------------------------------------------------------------------
-- palmares.threshold_map — which threshold parameter decides a given (action type, voter role).
--
-- A static table, not a derivation: the mapping is ledger law (Conway ratification rules), it
-- changes only with a hard fork, and the API echoes `threshold_param` so a client can look the
-- number up in `palmares.thresholds` itself.
--
-- The NULLs are the informative part, and each is a different reason:
--   * ConstitutionalCommittee always NULL — the CC ratifies by a quorum of its members
--     (committee_min_size / the per-member threshold), not by a stake fraction.
--   * InfoAction, every role — an InfoAction is never ratifiable, so no threshold applies and a
--     participation metric must not treat a missing vote on one as a failure to reach quorum.
--   * NewCommittee / NoConfidence for the CC — the committee does not vote on its own
--     replacement or on a motion of no confidence in itself.
--   * NewConstitution and TreasuryWithdrawals for the SPO — SPOs do not vote on either.
--   * ParameterChange for the DRep — the threshold is the MAX over the parameter groups the
--     proposal actually touches (network / economic / technical / gov), so it is not a single
--     column and cannot be put in this table.
--
-- `pvtpp_security_group` is spelled exactly as db-sync spells it; `pvt_pp_security_group` does
-- not exist.
--
-- NewCommittee maps to the `_normal` thresholds throughout F1: the `_no_confidence` variants apply
-- only while the committee is in a state of no confidence, which preprod has never been in.
CREATE VIEW palmares.threshold_map AS
SELECT *
FROM (
  VALUES
    ('HardForkInitiation'::public.govactiontype, 'ConstitutionalCommittee'::public.voterrole, NULL::text),
    ('HardForkInitiation', 'DRep', 'dvt_hard_fork_initiation'),
    ('HardForkInitiation', 'SPO', 'pvt_hard_fork_initiation'),
    ('InfoAction', 'ConstitutionalCommittee', NULL),
    ('InfoAction', 'DRep', NULL),
    ('InfoAction', 'SPO', NULL),
    ('NewCommittee', 'ConstitutionalCommittee', NULL),
    ('NewCommittee', 'DRep', 'dvt_committee_normal'),
    ('NewCommittee', 'SPO', 'pvt_committee_normal'),
    ('NewConstitution', 'ConstitutionalCommittee', NULL),
    ('NewConstitution', 'DRep', 'dvt_update_to_constitution'),
    ('NewConstitution', 'SPO', NULL),
    ('NoConfidence', 'ConstitutionalCommittee', NULL),
    ('NoConfidence', 'DRep', 'dvt_motion_no_confidence'),
    ('NoConfidence', 'SPO', 'pvt_motion_no_confidence'),
    ('ParameterChange', 'ConstitutionalCommittee', NULL),
    ('ParameterChange', 'DRep', NULL),
    ('ParameterChange', 'SPO', 'pvtpp_security_group'),
    ('TreasuryWithdrawals', 'ConstitutionalCommittee', NULL),
    ('TreasuryWithdrawals', 'DRep', 'dvt_treasury_withdrawal'),
    ('TreasuryWithdrawals', 'SPO', NULL)
) AS t(action_type, voter_role, threshold_param);

-- ---------------------------------------------------------------------------------------------
-- palmares.vote — every vote row, with the voter resolved and the re-vote sequence numbered.
--
-- One row per vote CERTIFICATE, not per voter: an actor may vote repeatedly on the same action and
-- the ledger keeps only the last (Gov.hs: isVoteReplaced / GovRemovedVotes replacedVotes), while
-- db-sync keeps every row. So this view keeps every row too and marks them:
--   seq_last  = 1  the vote that counts
--   seq_first = 1  the first vote, which is what a latency metric measures
--   vote_rows      how many times this actor voted on this action
-- A tally therefore filters `seq_last = 1`, and an audit trail reads the rest.
--
-- D-27, and this is the one that matters most in this file: the window is partitioned by
-- `voter_id_hash`, which is the COLD credential for the constitutional committee and the signing
-- credential itself for DReps and SPOs. A committee member's votes split across hot-key
-- rotations, so partitioning by the hot key counts each rotation as a separate voter. On preprod
-- that is not a rounding error: an AuthCommitteeHotKey stress test in epoch 187 left 648,766 hot
-- keys mapping to 43 cold keys, so a hot-key partition reports 3,243,798 "final" CC votes where
-- the truth is 193 — a factor of about 16,800.
-- ---------------------------------------------------------------------------------------------
-- palmares.cc_cold_interval — which cold credential a committee HOT key belonged to, and when.
--
-- One row per registration, carrying the transaction range it was in force for. Its own view
-- because two things need it — palmares.vote, to identify who cast a committee vote, and
-- palmares.gov_action, to count distinct voters on an action — and a second copy of a
-- "registration in force at time T" rule is a second chance to get it wrong.
--
-- An INTERVAL rather than a per-row lookup, and that is a performance decision with a measured
-- reason. Expressed as "the latest registration with tx_id <= the vote's", PostgreSQL executes
-- one index lookup PER VOTE ROW. preprod has 3.24 M committee vote rows, from an
-- AuthCommitteeHotKey stress test in epoch 187 that registered 648,766 hot keys, concentrated so
-- that five governance actions each carry ~648,755 of them: selecting votes_cast for all 131
-- actions took 87 SECONDS. As an interval join the 648,767 registrations hash once and every vote
-- row is a hash probe plus a range test, which brought the same query to 5.7 s and left every
-- number identical (193 final committee votes by 43 cold keys, before and after).
CREATE VIEW palmares.cc_cold_interval AS
SELECT
  cr.hot_key_id,
  cr.tx_id AS from_tx,
  cr.cert_index AS from_cert,
  LEAD(cr.tx_id) OVER w AS to_tx,
  ch.raw AS cold_raw,
  ch.has_script AS cold_has_script
FROM public.committee_registration cr
JOIN public.committee_hash ch ON ch.id = cr.cold_key_id
WINDOW w AS (PARTITION BY cr.hot_key_id ORDER BY cr.tx_id, cr.cert_index);

-- ---------------------------------------------------------------------------------------------
CREATE VIEW palmares.vote AS
WITH resolved AS (
  SELECT
    -- The row's own key. palmares.activity's cursor needs it because voting_procedure.index is
    -- not a per-transaction counter in this data: 3,243,802 CC rows carry only 108,176 distinct
    -- (tx_id, index) pairs.
    v.id AS voting_procedure_id,
    -- The DRep's own row id, NULL for the other two roles. Carried so the metric SQL can bind one
    -- parameter (`drep_hash_id`) instead of also carrying the raw credential for the match.
    v.drep_voter AS drep_voter_id,
    v.gov_action_proposal_id AS gov_action_id,
    v.voter_role,
    -- The credential that signed the vote.
    CASE v.voter_role
      WHEN 'DRep' THEN (SELECT dh.raw FROM public.drep_hash dh WHERE dh.id = v.drep_voter)
      WHEN 'SPO' THEN (SELECT ph.hash_raw FROM public.pool_hash ph WHERE ph.id = v.pool_voter)
      ELSE (SELECT ch.raw FROM public.committee_hash ch WHERE ch.id = v.committee_voter)
    END AS voter_hot_hash,
    -- NULL except for the CC, where it is the cold credential resolved AS OF THIS VOTE'S tx: a
    -- member's hot key may have been rotated since, and the registration in force at the time is
    -- the one that identifies them.
    cold.cold_raw AS voter_cold_hash,
    -- The COLD credential's script flag, which is NOT the hot key's. Carried because the
    -- published CIP-129 cc_cold1… id is built from the cold hash, and the header byte that says
    -- key-or-script has to come from the same credential as the hash. Measured: every preprod
    -- committee cold credential is a SCRIPT, while `has_script` below reports the HOT key —
    -- pairing those two published a cc_cold1z… id that decodes to a different credential.
    cold.cold_has_script AS voter_cold_has_script,
    CASE v.voter_role
      WHEN 'DRep' THEN (SELECT dh.has_script FROM public.drep_hash dh WHERE dh.id = v.drep_voter)
      -- A stake pool is always a key hash; db-sync's pool_hash has no has_script column because
      -- there is nothing to record.
      WHEN 'SPO' THEN FALSE
      ELSE (SELECT ch.has_script FROM public.committee_hash ch WHERE ch.id = v.committee_voter)
    END AS has_script,
    v.vote,
    v.voting_anchor_id,
    b.epoch_no AS vote_epoch,
    b.slot_no AS vote_slot,
    b.time AS cast_at,
    tx.hash AS vote_tx_hash,
    tx.block_index AS tx_index,
    v.index AS vote_index
  FROM public.voting_procedure v
  JOIN public.tx ON tx.id = v.tx_id
  JOIN public.block b ON b.id = tx.block_id
  -- The cold credential in force at this vote's transaction. See palmares.cc_cold_interval for
  -- why this is an interval join rather than a per-row lookup.
  LEFT JOIN palmares.cc_cold_interval cold
    ON cold.hot_key_id = v.committee_voter
   AND cold.from_tx <= v.tx_id
   AND (cold.to_tx IS NULL OR cold.to_tx > v.tx_id)
),
identified AS (
  SELECT
    r.*,
    COALESCE(r.voter_cold_hash, r.voter_hot_hash) AS voter_id_hash
  FROM resolved r
)
SELECT
  i.voting_procedure_id,
  i.drep_voter_id,
  i.gov_action_id,
  i.voter_role,
  i.voter_id_hash,
  i.voter_hot_hash,
  i.voter_cold_hash,
  i.voter_cold_has_script,
  i.has_script,
  i.vote,
  i.voting_anchor_id,
  i.vote_epoch,
  i.vote_slot,
  i.cast_at,
  i.vote_tx_hash,
  i.tx_index,
  i.vote_index,
  ROW_NUMBER() OVER w AS seq_first,
  ROW_NUMBER() OVER (
    PARTITION BY i.voter_role, i.voter_id_hash, i.gov_action_id
    ORDER BY i.vote_slot DESC, i.tx_index DESC, i.vote_index DESC
  ) AS seq_last,
  COUNT(*) OVER (PARTITION BY i.voter_role, i.voter_id_hash, i.gov_action_id) AS vote_rows
FROM identified i
WINDOW w AS (
  PARTITION BY i.voter_role, i.voter_id_hash, i.gov_action_id
  ORDER BY i.vote_slot, i.tx_index, i.vote_index
);

-- ---------------------------------------------------------------------------------------------
-- palmares.drep_epoch_power — the DRep stake distribution, per epoch, UNFILTERED.
--
-- D-20: no WHERE clause. The two reserved ledger options, `drep_always_abstain` and
-- `drep_always_no_confidence`, get rows here exactly like real DReps, distinguished only by
-- `target_kind`. Consumers filter.
--
-- Filtering them out at the source is the mistake this view is shaped to prevent: on preprod at
-- epoch 319 the always-abstain option alone holds 431,863,790,957,959 lovelace, about 46% of the
-- 937,803,900,128,796 total. Any denominator built from a filtered view understates total voting
-- power by nearly half, and the dashboard's "share of total power" numbers would all be inflated.
--
-- A DRep with no row in an epoch has ZERO power that epoch, not unknown power: the ledger simply
-- did not include it in the distribution. 101 of the 294 registered DReps are in that position at
-- epoch 319. Readers must LEFT JOIN and coalesce, not INNER JOIN.
CREATE VIEW palmares.drep_epoch_power AS
SELECT
  dd.hash_id AS drep_hash_id,
  dh.raw AS drep_raw,
  dh.has_script,
  CASE
    WHEN dh.raw IS NOT NULL THEN 'drep'
    WHEN dh.view = 'drep_always_abstain' THEN 'always_abstain'
    ELSE 'always_no_confidence'
  END AS target_kind,
  dd.epoch_no,
  dd.amount,
  dd.active_until
FROM public.drep_distr dd
JOIN public.drep_hash dh ON dh.id = dd.hash_id;

-- ---------------------------------------------------------------------------------------------
-- palmares.vote_delegation — every vote-delegation certificate, with the target classified.
--
-- One row per certificate, so the history is auditable; `palmares.live_delegation` reduces it to
-- what is in force now.
CREATE VIEW palmares.vote_delegation AS
SELECT
  dv.addr_id,
  sa.view AS stake_address,
  dv.drep_hash_id,
  CASE
    WHEN dh.raw IS NOT NULL THEN 'drep'
    WHEN dh.view = 'drep_always_abstain' THEN 'always_abstain'
    ELSE 'always_no_confidence'
  END AS target_kind,
  tx.hash AS tx_hash,
  b.slot_no,
  b.epoch_no,
  b.time AS delegated_at,
  tx.block_index AS tx_index,
  dv.cert_index
FROM public.delegation_vote dv
JOIN public.tx ON tx.id = dv.tx_id
JOIN public.block b ON b.id = tx.block_id
JOIN public.stake_address sa ON sa.id = dv.addr_id
JOIN public.drep_hash dh ON dh.id = dv.drep_hash_id;

-- ---------------------------------------------------------------------------------------------
-- palmares.live_delegation — the delegation in force right now, per stake address.
--
-- Two rules, and the second is the one that is easy to miss: a later delegation certificate
-- supersedes an earlier one (so only the last per address counts), AND de-registering the stake
-- credential ends the delegation even though `delegation_vote` keeps the row forever. Without the
-- de-registration rule a DRep keeps counting delegators who have closed their accounts.
CREATE VIEW palmares.live_delegation AS
WITH latest AS (
  SELECT DISTINCT ON (dv.addr_id)
    dv.addr_id,
    dv.drep_hash_id,
    b.epoch_no AS from_epoch,
    b.slot_no AS from_slot
  FROM public.delegation_vote dv
  JOIN public.tx ON tx.id = dv.tx_id
  JOIN public.block b ON b.id = tx.block_id
  ORDER BY dv.addr_id, b.slot_no DESC, tx.block_index DESC, dv.cert_index DESC
)
SELECT l.addr_id, l.drep_hash_id, l.from_epoch, l.from_slot
FROM latest l
WHERE NOT EXISTS (
  SELECT 1
  FROM public.stake_deregistration sd
  WHERE sd.addr_id = l.addr_id
    AND sd.epoch_no >= l.from_epoch
);
