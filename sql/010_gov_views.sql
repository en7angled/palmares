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
