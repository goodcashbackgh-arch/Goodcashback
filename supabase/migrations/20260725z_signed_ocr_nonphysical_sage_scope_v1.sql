BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Scope hardening for the signed non-physical supplier AP bridge.
-- Invoices without an active coded non-physical line must continue to receive the
-- exact preserved helper output. Only affected supplier invoices use the additive
-- signed-line enrichment created by the preceding migration.

DO $guard$
BEGIN
  IF to_regprocedure('public.internal_supplier_goods_ap_ready_rows_v1()') IS NULL THEN
    RAISE EXCEPTION 'Signed supplier AP helper is missing.';
  END IF;
  IF to_regprocedure('public.internal_supplier_goods_ap_ready_rows_pre_signed_nonphysical_v1()') IS NULL THEN
    RAISE EXCEPTION 'Preserved supplier AP helper is missing.';
  END IF;
  IF to_regclass('public.supplier_invoice_line_accounting_coding_vw') IS NULL
     OR to_regclass('public.supplier_invoice_line_resolutions') IS NULL THEN
    RAISE EXCEPTION 'Signed supplier AP scope prerequisite is missing.';
  END IF;
END
$guard$;

DO $rename$
BEGIN
  IF to_regprocedure('public.internal_supplier_goods_ap_ready_rows_signed_nonphysical_all_v1()') IS NULL THEN
    ALTER FUNCTION public.internal_supplier_goods_ap_ready_rows_v1()
      RENAME TO internal_supplier_goods_ap_ready_rows_signed_nonphysical_all_v1;
  END IF;
END
$rename$;

REVOKE ALL ON FUNCTION public.internal_supplier_goods_ap_ready_rows_signed_nonphysical_all_v1() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_supplier_goods_ap_ready_rows_signed_nonphysical_all_v1() FROM anon;
REVOKE ALL ON FUNCTION public.internal_supplier_goods_ap_ready_rows_signed_nonphysical_all_v1() FROM authenticated;
REVOKE ALL ON FUNCTION public.internal_supplier_goods_ap_ready_rows_signed_nonphysical_all_v1() FROM service_role;

CREATE OR REPLACE FUNCTION public.internal_supplier_goods_ap_ready_rows_v1()
RETURNS TABLE (
  queue_row_id text,
  document_lane text,
  document_type text,
  source_table text,
  source_id uuid,
  order_id uuid,
  order_ref text,
  shipment_batch_id uuid,
  booking_ref text,
  counterparty_name text,
  amount_gbp numeric,
  currency_code text,
  invoice_type text,
  sage_status text,
  sage_invoice_id text,
  sage_posted_at timestamptz,
  readiness_status text,
  blocker text,
  reference_text text,
  notes_text text,
  detail_href text,
  source_payload jsonb
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $func$
  WITH affected AS (
    SELECT DISTINCT v.supplier_invoice_id
    FROM public.supplier_invoice_line_accounting_coding_vw v
    JOIN public.supplier_invoice_line_resolutions r
      ON r.supplier_invoice_line_id = v.supplier_invoice_line_id
     AND r.supplier_invoice_id = v.supplier_invoice_id
     AND r.resolution_type = 'non_physical_financial'
     AND r.active = true
    WHERE COALESCE(v.coded_yn, false) = true
  ), preserved AS (
    SELECT p.*
    FROM public.internal_supplier_goods_ap_ready_rows_pre_signed_nonphysical_v1() p
    WHERE NOT EXISTS (
      SELECT 1 FROM affected a WHERE a.supplier_invoice_id = p.source_id
    )
  ), enriched AS (
    SELECT e.*
    FROM public.internal_supplier_goods_ap_ready_rows_signed_nonphysical_all_v1() e
    WHERE EXISTS (
      SELECT 1 FROM affected a WHERE a.supplier_invoice_id = e.source_id
    )
  )
  SELECT
    p.queue_row_id, p.document_lane, p.document_type, p.source_table, p.source_id,
    p.order_id, p.order_ref, p.shipment_batch_id, p.booking_ref, p.counterparty_name,
    p.amount_gbp, p.currency_code, p.invoice_type, p.sage_status, p.sage_invoice_id,
    p.sage_posted_at, p.readiness_status, p.blocker, p.reference_text, p.notes_text,
    p.detail_href, p.source_payload
  FROM preserved p
  UNION ALL
  SELECT
    e.queue_row_id, e.document_lane, e.document_type, e.source_table, e.source_id,
    e.order_id, e.order_ref, e.shipment_batch_id, e.booking_ref, e.counterparty_name,
    e.amount_gbp, e.currency_code, e.invoice_type, e.sage_status, e.sage_invoice_id,
    e.sage_posted_at, e.readiness_status, e.blocker, e.reference_text, e.notes_text,
    e.detail_href, e.source_payload
  FROM enriched e;
$func$;

REVOKE ALL ON FUNCTION public.internal_supplier_goods_ap_ready_rows_v1() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_supplier_goods_ap_ready_rows_v1() FROM anon;
GRANT EXECUTE ON FUNCTION public.internal_supplier_goods_ap_ready_rows_v1() TO authenticated;
GRANT EXECUTE ON FUNCTION public.internal_supplier_goods_ap_ready_rows_v1() TO service_role;

COMMENT ON FUNCTION public.internal_supplier_goods_ap_ready_rows_v1() IS
'Canonical supplier goods AP helper. Returns the exact preserved implementation for unaffected invoices and the additive signed non-physical enrichment only for invoices with active coded non-physical rows.';

NOTIFY pgrst, 'reload schema';

COMMIT;
