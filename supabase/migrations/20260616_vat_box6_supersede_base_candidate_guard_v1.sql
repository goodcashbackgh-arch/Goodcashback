-- =============================================================================
-- 20260616_vat_box6_supersede_base_candidate_guard_v1.sql
-- Goodcashback — VAT Box 6 timing de-duplication guard
--
-- Purpose:
--   Prevent a current-period Sage sales invoice from being counted twice when the
--   VAT timing engine inserts both:
--     - sage_sales_invoice_natural_current; and
--     - box6_anti_duplicate_decrease
--   for an invoice that already has an active sales_invoice_box6_candidate row
--   from the platform source snapshot refresh.
--
-- Why this is intentionally narrow:
--   The existing partial-prepayment function and source refresh are preserved.
--   This guard only supersedes the base candidate for the same sales invoice when
--   the timing engine has created the replacement natural-current line.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.vat_return_run_lines') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.vat_return_run_lines';
  END IF;

  IF to_regclass('public.vat_return_runs') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.vat_return_runs';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.trg_vat_box6_supersede_base_candidate_on_timing_natural_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.line_kind IS DISTINCT FROM 'sage_sales_invoice_natural_current'
     OR NEW.source_table IS DISTINCT FROM 'sales_invoices'
     OR NEW.source_id IS NULL
     OR NEW.box_number IS DISTINCT FROM 6
     OR NEW.status IS DISTINCT FROM 'active' THEN
    RETURN NEW;
  END IF;

  -- Do not mutate a locked/submitted/mismatched VAT run. Those require the
  -- correction/reopen flow by design.
  IF NOT EXISTS (
    SELECT 1
    FROM public.vat_return_runs r
    WHERE r.id = NEW.vat_return_run_id
      AND r.locked_at IS NULL
      AND r.status NOT IN (
        'sage_return_submitted',
        'matched_to_sage_locked',
        'mismatch_needs_admin_review',
        'superseded'
      )
  ) THEN
    RETURN NEW;
  END IF;

  UPDATE public.vat_return_run_lines l
  SET
    status = 'superseded',
    adjustment_reason = concat_ws(
      E'\n',
      NULLIF(l.adjustment_reason, ''),
      'superseded_by_sage_sales_invoice_natural_current_box6_dedup_guard_v1'
    )
  WHERE l.vat_return_run_id = NEW.vat_return_run_id
    AND l.status = 'active'
    AND l.source_table = 'sales_invoices'
    AND l.source_id = NEW.source_id
    AND l.box_number = 6
    AND l.line_kind = 'sales_invoice_box6_candidate';

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_vat_box6_supersede_base_candidate_on_timing_natural_v1
ON public.vat_return_run_lines;

CREATE TRIGGER trg_vat_box6_supersede_base_candidate_on_timing_natural_v1
BEFORE INSERT ON public.vat_return_run_lines
FOR EACH ROW
EXECUTE FUNCTION public.trg_vat_box6_supersede_base_candidate_on_timing_natural_v1();

-- One-time cleanup for any currently editable VAT run that already has both the
-- base sales invoice candidate and the replacement natural-current timing line
-- active for the same sales invoice.
WITH affected AS (
  UPDATE public.vat_return_run_lines c
  SET
    status = 'superseded',
    adjustment_reason = concat_ws(
      E'\n',
      NULLIF(c.adjustment_reason, ''),
      'superseded_by_existing_sage_sales_invoice_natural_current_box6_dedup_guard_v1'
    )
  FROM public.vat_return_runs r
  WHERE c.vat_return_run_id = r.id
    AND r.locked_at IS NULL
    AND r.status NOT IN (
      'sage_return_submitted',
      'matched_to_sage_locked',
      'mismatch_needs_admin_review',
      'superseded'
    )
    AND c.status = 'active'
    AND c.source_table = 'sales_invoices'
    AND c.box_number = 6
    AND c.line_kind = 'sales_invoice_box6_candidate'
    AND EXISTS (
      SELECT 1
      FROM public.vat_return_run_lines n
      WHERE n.vat_return_run_id = c.vat_return_run_id
        AND n.status = 'active'
        AND n.source_table = 'sales_invoices'
        AND n.source_id IS NOT DISTINCT FROM c.source_id
        AND n.box_number = 6
        AND n.line_kind = 'sage_sales_invoice_natural_current'
    )
  RETURNING c.vat_return_run_id
), recalculated AS (
  SELECT
    l.vat_return_run_id,
    round(COALESCE(SUM(
      CASE
        WHEN l.direction IN ('natural','increase') THEN l.amount_gbp
        WHEN l.direction = 'decrease' THEN -l.amount_gbp
        ELSE 0
      END
    ), 0)::numeric, 2) AS expected_box6_gbp
  FROM public.vat_return_run_lines l
  WHERE l.vat_return_run_id IN (SELECT DISTINCT vat_return_run_id FROM affected)
    AND l.status = 'active'
    AND l.box_number = 6
  GROUP BY l.vat_return_run_id
)
UPDATE public.vat_return_runs r
SET
  expected_box6_gbp = recalculated.expected_box6_gbp,
  source_counts_json = COALESCE(r.source_counts_json, '{}'::jsonb) || jsonb_build_object(
    'box6_base_candidate_dedup_guard_v1',
    jsonb_build_object(
      'applied_at', now(),
      'rule', 'active sales_invoice_box6_candidate is superseded where active sage_sales_invoice_natural_current exists for the same sales invoice'
    )
  ),
  updated_at = now()
FROM recalculated
WHERE r.id = recalculated.vat_return_run_id
  AND r.locked_at IS NULL
  AND r.status NOT IN (
    'sage_return_submitted',
    'matched_to_sage_locked',
    'mismatch_needs_admin_review',
    'superseded'
  );

COMMENT ON FUNCTION public.trg_vat_box6_supersede_base_candidate_on_timing_natural_v1() IS
'VAT Box 6 timing guard: when a sage_sales_invoice_natural_current line is inserted for a sales invoice, supersede the active sales_invoice_box6_candidate for the same VAT run/source invoice so the natural invoice value is not counted twice.';

NOTIFY pgrst, 'reload schema';

COMMIT;
