-- age_days_v1 — how long this DRep has been registered, summed over its intervals.
--
-- Params: drep_hash_id, as_of_epoch.
--
-- Summed over intervals, because retire-then-re-register is legal: the age is the time actually
-- spent registered, not the span from the first certificate.
--
-- The retirement lookup is bounded by `slot_no > i.from_slot`, NOT by `epoch_no >= i.from_epoch`.
-- The epoch form picks up a retirement that happened EARLIER IN THE SAME EPOCH than the
-- registration opening the interval — register, retire, re-register inside one five-day epoch is
-- legal and cheap — which yields a negative term that GREATEST(0, ...) then silently hides.
WITH p AS (
  SELECT ?::bigint AS drep_hash_id, ?::int AS as_of_epoch
),
cursor_time AS (
  SELECT max(b.time) AS t
  FROM public.block b
  WHERE b.epoch_no <= (SELECT as_of_epoch FROM p)
)
SELECT
  GREATEST(0, SUM(EXTRACT(EPOCH FROM (
    LEAST(COALESCE(r.retire_time, c.t), c.t) - i.from_time
  )))) / 86400 AS age_days
FROM palmares.drep_interval i
CROSS JOIN cursor_time c
LEFT JOIN LATERAL (
  SELECT b2.time AS retire_time
  FROM public.drep_registration r2
  JOIN public.tx t2 ON t2.id = r2.tx_id
  JOIN public.block b2 ON b2.id = t2.block_id
  WHERE r2.drep_hash_id = i.drep_hash_id
    AND r2.deposit < 0
    AND b2.slot_no > i.from_slot
  ORDER BY b2.slot_no
  LIMIT 1
) r ON TRUE
WHERE i.drep_hash_id = (SELECT drep_hash_id FROM p);
