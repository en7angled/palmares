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
