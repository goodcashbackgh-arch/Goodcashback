BEGIN;

-- One-off cleanup after accidental out-of-sequence VAT pack generation.
-- June/July 2026 were generated while earlier VAT periods were still unfiled/unlocked.
-- This preserves audit history but removes those packs from the active VAT sequence.

WITH target_runs AS (
  SELECT id
  FROM public.vat_return_runs
  WHERE status IN ('draft', 'calculated', 'admin_review_required', 'blocked')
    AND period_start_date IN (DATE '2026-06-01', DATE '2026-07-01')
), updated_runs AS (
  UPDATE public.vat_return_runs r
  SET status = 'superseded',
      superseded_at = now(),
      superseded_reason = 'Out-of-sequence draft generated before earlier VAT return was filed',
      updated_at = now()
  FROM target_runs t
  WHERE r.id = t.id
  RETURNING r.id
), updated_lines AS (
  UPDATE public.vat_return_run_lines l
  SET status = 'superseded'
  FROM updated_runs r
  WHERE l.vat_return_run_id = r.id
    AND l.status = 'active'
  RETURNING l.id
)
UPDATE public.vat_return_blockers b
SET status = 'waived',
    resolved_at = now(),
    resolution_notes = concat_ws(E'\n', b.resolution_notes, 'Waived because out-of-sequence VAT return pack was superseded.')
FROM updated_runs r
WHERE b.vat_return_run_id = r.id
  AND b.status = 'open';

NOTIFY pgrst, 'reload schema';

COMMIT;
