BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regprocedure('public.assert_current_operator_can_reconcile_order(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.assert_current_operator_can_reconcile_order(uuid)';
  END IF;

  IF to_regclass('public.supplier_invoice_lines') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoice_lines';
  END IF;

  IF to_regclass('public.supplier_invoices') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoices';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.operator_bulk_mark_supplier_invoice_lines_progressed(
  p_order_id uuid,
  p_line_ids uuid[]
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_requested_count integer := 0;
  v_valid_count integer := 0;
  v_updated_count integer := 0;
BEGIN
  IF p_order_id IS NULL THEN
    RAISE EXCEPTION 'Order is required';
  END IF;

  IF p_line_ids IS NULL OR cardinality(p_line_ids) = 0 THEN
    RAISE EXCEPTION 'Select at least one invoice line to progress';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM unnest(p_line_ids) AS requested(line_id)
    WHERE requested.line_id IS NULL
  ) THEN
    RAISE EXCEPTION 'Selected invoice lines cannot contain a blank line id';
  END IF;

  PERFORM public.assert_current_operator_can_reconcile_order(p_order_id);

  SELECT COUNT(*)::integer
    INTO v_requested_count
  FROM (
    SELECT DISTINCT requested.line_id
    FROM unnest(p_line_ids) AS requested(line_id)
  ) selected;

  SELECT COUNT(*)::integer
    INTO v_valid_count
  FROM (
    SELECT DISTINCT requested.line_id
    FROM unnest(p_line_ids) AS requested(line_id)
  ) selected
  JOIN public.supplier_invoice_lines sil
    ON sil.id = selected.line_id
  JOIN public.supplier_invoices si
    ON si.id = sil.supplier_invoice_id
   AND si.order_id = p_order_id;

  IF v_valid_count <> v_requested_count THEN
    RAISE EXCEPTION 'One or more selected supplier invoice lines do not belong to this order';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM (
      SELECT DISTINCT requested.line_id
      FROM unnest(p_line_ids) AS requested(line_id)
    ) selected
    JOIN public.supplier_invoice_lines sil
      ON sil.id = selected.line_id
    JOIN public.supplier_invoices si
      ON si.id = sil.supplier_invoice_id
     AND si.order_id = p_order_id
    WHERE sil.qty IS NULL
       OR sil.qty < 0
       OR sil.amount_inc_vat_gbp IS NULL
       OR sil.amount_inc_vat_gbp < 0
  ) THEN
    RAISE EXCEPTION 'Selected lines require non-negative quantity and amount before progression';
  END IF;

  WITH selected AS (
    SELECT DISTINCT requested.line_id
    FROM unnest(p_line_ids) AS requested(line_id)
  )
  UPDATE public.supplier_invoice_lines sil
  SET qty_confirmed = sil.qty,
      amount_confirmed = sil.amount_inc_vat_gbp,
      eligible_for_invoice_yn = 'Y',
      updated_at = now()
  FROM selected,
       public.supplier_invoices si
  WHERE sil.id = selected.line_id
    AND si.id = sil.supplier_invoice_id
    AND si.order_id = p_order_id;

  GET DIAGNOSTICS v_updated_count = ROW_COUNT;

  IF v_updated_count <> v_requested_count THEN
    RAISE EXCEPTION 'Bulk progression did not update every selected supplier invoice line';
  END IF;

  RETURN v_updated_count;
END;
$$;

COMMENT ON FUNCTION public.operator_bulk_mark_supplier_invoice_lines_progressed(uuid, uuid[]) IS
'Atomically validates and progresses the selected operator-owned supplier invoice lines in one set-based UPDATE. It does not loop through the single-line RPC and introduces no direct order-status, exception, funding, shipping, accounting, VAT, Sage, or evidence-query side effects.';

REVOKE ALL ON FUNCTION public.operator_bulk_mark_supplier_invoice_lines_progressed(uuid, uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.operator_bulk_mark_supplier_invoice_lines_progressed(uuid, uuid[]) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
