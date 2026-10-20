-- rationale_rate_v1 — of the votes this DRep cast, how many carried a published rationale.
--
-- Params: drep_hash_id, as_of_epoch.
--
-- FIVE grades, not four (D-3), and the fifth is the one that matters for fairness:
--   verified    the anchor was fetched and its hash matched
--   inline      a `data:` URI: the rationale IS the URL, so there is nothing to fetch and hash
--               verification is vacuous. preprod has real ones. Counting these as missing would
--               accuse an author who did publish a rationale.
--   unverified  a fetch was attempted and failed
--   pending     an anchor is attached and db-sync has not tried yet
--   absent      no anchor at all
-- THE DENOMINATOR EXCLUDES WHAT WE COULD NOT ASSESS. The rate is
--   (verified + inline) / (verified + inline + absent)
-- so `unverified` and `pending` are out of BOTH sides. Rationale, and it is measured, not
-- theoretical: across all 648 final DRep votes on preprod today there are ZERO `valid` anchors.
-- 23 are unreachable, and network-wide 140 of the 237 unreachable anchors are `ipfs://` URIs that
-- our db-sync's gateway list cannot fetch. Dividing by votes_cast would therefore publish
-- "essentially nobody on preprod writes rationales" when the truth is "our indexer cannot fetch
-- IPFS" — a statement about our infrastructure, printed as a judgement about 36 people.
--
-- An unreachable or not-yet-fetched anchor is evidence the author DID attach something and no
-- evidence about its contents. Counting it as a failure is the same error the `inline` and
-- `pending` grades exist to avoid; excluding it says "we cannot tell", which is true. When nothing
-- can be assessed the rate is NULL — "n/a", not 0%.
--
-- All five counters are published regardless, so a consumer who wants a different basis (an
-- attachment rate, say: (votes_cast - absent) / votes_cast) can compute it without us.
--
-- The five counters sum to votes_cast BY CONSTRUCTION, because `final` joins eligible_actions —
-- the same denominator participation_rate uses. Taking every action the DRep ever voted on instead
-- would let a vote on a still-open action into this sample while participation_rate excluded it,
-- and the two rates would stop being comparable.
WITH p AS (
  SELECT ?::bigint AS drep_hash_id, ?::int AS as_of_epoch
),
elig AS (
  SELECT e.gov_action_id
  FROM p, palmares.eligible_actions(p.drep_hash_id, p.as_of_epoch) e
),
final AS (
  SELECT v.gov_action_id, v.voting_anchor_id
  FROM palmares.vote v
  JOIN elig e ON e.gov_action_id = v.gov_action_id
  WHERE v.drep_voter_id = (SELECT drep_hash_id FROM p)
    AND v.seq_last = 1
),
graded AS (
  SELECT
    f.gov_action_id,
    CASE
      WHEN f.voting_anchor_id IS NULL THEN 'absent'
      WHEN a.verdict = 'inline' THEN 'inline'
      WHEN a.verdict = 'valid' THEN 'verified'
      WHEN a.verdict = 'not_fetched' THEN 'pending'
      ELSE 'unverified'
    END AS grade,
    a.cip100_valid
  FROM final f
  LEFT JOIN palmares.anchor a ON a.voting_anchor_id = f.voting_anchor_id
)
SELECT
  count(*) FILTER (WHERE grade = 'verified') AS rationale_verified,
  count(*) FILTER (WHERE grade = 'inline') AS rationale_inline,
  count(*) FILTER (WHERE grade = 'unverified') AS rationale_unverified,
  count(*) FILTER (WHERE grade = 'pending') AS rationale_pending,
  count(*) FILTER (WHERE grade = 'absent') AS rationale_absent,
  count(*) FILTER (WHERE cip100_valid IS TRUE) AS rationale_cip100_valid,
  CASE WHEN count(*) FILTER (WHERE grade IN ('verified', 'inline', 'absent')) = 0 THEN NULL
       ELSE count(*) FILTER (WHERE grade IN ('verified', 'inline'))::float8
            / count(*) FILTER (WHERE grade IN ('verified', 'inline', 'absent')) END AS rationale_rate
FROM graded;
