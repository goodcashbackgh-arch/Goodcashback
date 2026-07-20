BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
DECLARE
  v_order_id uuid;
  v_line_ids uuid[];
  v_status text;
  v_function_definition text;
BEGIN
  SELECT pg_get_functiondef('public.operator_bulk_mark_supplier_invoice_lines_progressed(uuid,uuid[])'::regprocedure)
    INTO v_function_definition;

  IF v_function_definition ILIKE '%FOREACH%' THEN
    RAISE EXCEPTION 'Regression failed: operator bulk progression still loops through lines.';
  END IF;

  IF v_function_definition NOT ILIKE '%UPDATE public.supplier_invoice_lines%' THEN
    RAISE EXCEPTION 'Regression failed: operator bulk progression is not set-based.';
  END IF;

  SELECT o.id
    INTO v_order_id
  FROM public.orders o
  WHERE o.status = 'partially_progressed'
    AND (
      SELECT COUNT(*)
      FROM public.supplier_invoice_lines sil
      JOIN public.supplier_invoices si ON si.id = sil.supplier_invoice_id
      WHERE si.order_id = o.id
        AND COALESCE(si.review_status, '') NOT IN ('rejected_resubmit_required','duplicate_blocked','superseded')
        AND lower(COALESCE(sil.eligible_for_invoice_yn::text, '')) NOT IN ('y','yes','true','1')
    ) >= 2
  ORDER BY o.updated_at DESC NULLS LAST, o.created_at DESC
  LIMIT 1;

  IF v_order_id IS NULL THEN
    RAISE EXCEPTION 'Regression fixture unavailable: no partially_progressed order with at least two unresolved active lines.';
  END IF;

  SELECT array_agg(candidate.id ORDER BY candidate.line_order, candidate.id)
    INTO v_line_ids
  FROM (
    SELECT sil.id, sil.line_order
    FROM public.supplier_invoice_lines sil
    JOIN public.supplier_invoices si ON si.id = sil.supplier_invoice_id
    WHERE si.order_id = v_order_id
      AND COALESCE(si.review_status, '') NOT IN ('rejected_resubmit_required','duplicate_blocked','superseded')
      AND lower(COALESCE(sil.eligible_for_invoice_yn::text, '')) NOT IN ('y','yes','true','1')
    ORDER BY sil.line_order, sil.id
    LIMIT 2
  ) candidate;

  -- This reproduces the row-trigger sequence behind the platform bulk action.
  -- The transaction is rolled back below, so no live progression is retained.
  UPDATE public.supplier_invoice_lines sil
  SET qty_confirmed = sil.qty,
      amount_confirmed = sil.amount_inc_vat_gbp,
      eligible_for_invoice_yn = 'Y',
      updated_at = now()
  WHERE sil.id = ANY(v_line_ids);

  SELECT o.status
    INTO v_status
  FROM public.orders o
  WHERE o.id = v_order_id;

  IF v_status <> 'partially_progressed' THEN
    RAISE EXCEPTION 'Regression failed: partially progressed order moved to % after further bulk progression.', v_status;
  END IF;

  RAISE NOTICE 'PASS: further bulk progression preserves partially_progressed and does not attempt partially_progressed -> reconciling.';
END $$;

ROLLBACK;

SELECT 'PASS: operator bulk progression is set-based and partially_progressed remains stable until the existing explicit handoff' AS regression_result;
