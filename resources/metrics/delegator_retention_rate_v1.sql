-- delegator_retention_rate_v1 — how many of this DRep's delegators from w epochs ago are still
-- delegating to it.
--
-- Params: drep_hash_id, as_of_epoch, retention_window_epochs.
--
-- The window is a PARAMETER, bound from the catalog's `retention_window_epochs` (10), and never a
-- literal. Two literals in two places is exactly the drift this directory exists to prevent.
--
-- A delegation interval ends at the next certificate for that address OR at the credential's
-- de-registration, whichever comes first: a closed stake account is not a delegator, even though
-- delegation_vote keeps the row forever.
WITH p AS (
  SELECT ?::bigint AS drep_hash_id, ?::int AS as_of_epoch, ?::int AS retention_window_epochs
),
seq AS (
  SELECT
    dv.addr_id,
    dv.drep_hash_id,
    b.epoch_no AS from_epoch,
    LEAD(b.epoch_no) OVER w AS next_epoch
  FROM public.delegation_vote dv
  JOIN public.tx ON tx.id = dv.tx_id
  JOIN public.block b ON b.id = tx.block_id
  WINDOW w AS (PARTITION BY dv.addr_id ORDER BY b.slot_no, tx.block_index, dv.cert_index)
),
live AS (
  SELECT
    s.addr_id,
    s.drep_hash_id,
    s.from_epoch,
    -- 2147483647 stands in for "no end", keeping the comparison inside word31type's domain.
    LEAST(
      COALESCE(s.next_epoch, 2147483647),
      COALESCE((SELECT min(sd.epoch_no) FROM public.stake_deregistration sd
                WHERE sd.addr_id = s.addr_id AND sd.epoch_no >= s.from_epoch), 2147483647)
    ) AS to_epoch
  FROM seq s
),
at_epoch AS (
  -- UNION, not UNION ALL. With retention_window_epochs = 0 the two epochs coincide, and UNION ALL
  -- would join every delegator twice: measured, the counters came back doubled (24 for 12
  -- delegators). UNION collapses the degenerate case so "previous" equals "now", which is the
  -- right answer for a zero window and is what makes the parameter testable at all.
  SELECT e.e, l.addr_id
  FROM (
    SELECT (SELECT as_of_epoch FROM p) AS e
    UNION
    SELECT (SELECT as_of_epoch - retention_window_epochs FROM p)
  ) e
  JOIN live l
    ON l.drep_hash_id = (SELECT drep_hash_id FROM p)
   AND l.from_epoch <= e.e
   AND l.to_epoch > e.e
)
SELECT
  count(*) FILTER (WHERE e = (SELECT as_of_epoch FROM p)) AS delegator_count,
  count(*) FILTER (WHERE e = (SELECT as_of_epoch - retention_window_epochs FROM p)) AS delegator_count_prev,
  (SELECT count(*) FROM (
     SELECT addr_id FROM at_epoch WHERE e = (SELECT as_of_epoch FROM p)
     INTERSECT
     SELECT addr_id FROM at_epoch WHERE e = (SELECT as_of_epoch - retention_window_epochs FROM p)) x
  ) AS delegators_retained,
  (SELECT count(*) FROM (
     SELECT addr_id FROM at_epoch WHERE e = (SELECT as_of_epoch FROM p)
     EXCEPT
     SELECT addr_id FROM at_epoch WHERE e = (SELECT as_of_epoch - retention_window_epochs FROM p)) x
  ) AS delegators_joined,
  (SELECT count(*) FROM (
     SELECT addr_id FROM at_epoch WHERE e = (SELECT as_of_epoch - retention_window_epochs FROM p)
     EXCEPT
     SELECT addr_id FROM at_epoch WHERE e = (SELECT as_of_epoch FROM p)) x
  ) AS delegators_left,
  CASE WHEN count(*) FILTER (WHERE e = (SELECT as_of_epoch - retention_window_epochs FROM p)) = 0 THEN NULL
       ELSE (SELECT count(*) FROM (
               SELECT addr_id FROM at_epoch WHERE e = (SELECT as_of_epoch FROM p)
               INTERSECT
               SELECT addr_id FROM at_epoch WHERE e = (SELECT as_of_epoch - retention_window_epochs FROM p)) x
            )::float8
            / count(*) FILTER (WHERE e = (SELECT as_of_epoch - retention_window_epochs FROM p))
  END AS delegator_retention_rate
FROM at_epoch;
