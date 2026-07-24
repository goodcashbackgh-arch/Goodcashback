BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Permanent lane restoration: every current and future supplier invoice and
-- approved supplier credit note is resolved live through the existing helpers.
-- No order/document ids are hard-coded and no accounting data is changed.

DO $block$
DECLARE
  v_current_definition text;
  v_backup_definition text;
  v_current_body text;
  v_queue_shape text;
  v_goods_shape text;
  v_credit_shape text;
BEGIN
  IF to_regprocedure('public.internal_ready_for_sage_queue_v2()') IS NULL
     OR to_regprocedure('public.internal_supplier_goods_ap_ready_rows_v1()') IS NULL
     OR to_regprocedure('public.internal_supplier_credit_note_ready_rows_v1()') IS NULL THEN
    RAISE EXCEPTION 'Required Sage queue/helper function missing';
  END IF;

  SELECT pg_get_function_result('public.internal_ready_for_sage_queue_v2()'::regprocedure),
         pg_get_function_result('public.internal_supplier_goods_ap_ready_rows_v1()'::regprocedure),
         pg_get_function_result('public.internal_supplier_credit_note_ready_rows_v1()'::regprocedure)
    INTO v_queue_shape, v_goods_shape, v_credit_shape;

  IF v_queue_shape IS DISTINCT FROM v_goods_shape
     OR v_queue_shape IS DISTINCT FROM v_credit_shape THEN
    RAISE EXCEPTION 'Sage queue/helper return shapes differ; refusing unsafe composition';
  END IF;

  SELECT pg_get_functiondef('public.internal_ready_for_sage_queue_v2()'::regprocedure)
    INTO v_current_definition;
  v_current_body := lower(v_current_definition);

  IF position('internal_ready_for_sage_queue_v2_pre_supplier_lane_restore_v1' IN v_current_body) > 0
     AND position('internal_supplier_goods_ap_ready_rows_v1' IN v_current_body) > 0
     AND position('internal_supplier_credit_note_ready_rows_v1' IN v_current_body) > 0 THEN
    RETURN;
  END IF;

  IF to_regprocedure('public.internal_ready_for_sage_queue_v2_pre_supplier_lane_restore_v1()') IS NOT NULL THEN
    RAISE EXCEPTION 'Private queue baseline already exists but canonical wrapper is incomplete';
  END IF;

  v_backup_definition := regexp_replace(
    v_current_definition,
    'FUNCTION[[:space:]]+public\.internal_ready_for_sage_queue_v2\(\)',
    'FUNCTION public.internal_ready_for_sage_queue_v2_pre_supplier_lane_restore_v1()',
    'i'
  );

  IF v_backup_definition = v_current_definition THEN
    RAISE EXCEPTION 'Could not preserve current Sage queue definition safely';
  END IF;

  EXECUTE v_backup_definition;
END
$block$;

REVOKE ALL ON FUNCTION public.internal_ready_for_sage_queue_v2_pre_supplier_lane_restore_v1() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_ready_for_sage_queue_v2_pre_supplier_lane_restore_v1() FROM anon;
REVOKE ALL ON FUNCTION public.internal_ready_for_sage_queue_v2_pre_supplier_lane_restore_v1() FROM authenticated;

CREATE OR REPLACE FUNCTION public.internal_ready_for_sage_queue_v2()
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
  WITH existing_queue AS (
    SELECT q.queue_row_id, q.document_lane, q.document_type, q.source_table,
           q.source_id, q.order_id, q.order_ref, q.shipment_batch_id,
           q.booking_ref, q.counterparty_name, q.amount_gbp, q.currency_code,
           q.invoice_type, q.sage_status, q.sage_invoice_id, q.sage_posted_at,
           q.readiness_status, q.blocker, q.reference_text, q.notes_text,
           q.detail_href, q.source_payload
    FROM public.internal_ready_for_sage_queue_v2_pre_supplier_lane_restore_v1() q
  ), supplier_goods AS (
    SELECT g.queue_row_id, g.document_lane, g.document_type, g.source_table,
           g.source_id, g.order_id, g.order_ref, g.shipment_batch_id,
           g.booking_ref, g.counterparty_name, g.amount_gbp, g.currency_code,
           g.invoice_type, g.sage_status, g.sage_invoice_id, g.sage_posted_at,
           g.readiness_status, g.blocker, g.reference_text, g.notes_text,
           g.detail_href, g.source_payload
    FROM public.internal_supplier_goods_ap_ready_rows_v1() g
    WHERE NOT EXISTS (
      SELECT 1 FROM existing_queue e
      WHERE e.document_lane IS NOT DISTINCT FROM g.document_lane
        AND e.source_table IS NOT DISTINCT FROM g.source_table
        AND e.source_id IS NOT DISTINCT FROM g.source_id
    )
  ), supplier_credit AS (
    SELECT c.queue_row_id, c.document_lane, c.document_type, c.source_table,
           c.source_id, c.order_id, c.order_ref, c.shipment_batch_id,
           c.booking_ref, c.counterparty_name, c.amount_gbp, c.currency_code,
           c.invoice_type, c.sage_status, c.sage_invoice_id, c.sage_posted_at,
           c.readiness_status, c.blocker, c.reference_text, c.notes_text,
           c.detail_href, c.source_payload
    FROM public.internal_supplier_credit_note_ready_rows_v1() c
    WHERE NOT EXISTS (
      SELECT 1 FROM existing_queue e
      WHERE e.document_lane IS NOT DISTINCT FROM c.document_lane
        AND e.source_table IS NOT DISTINCT FROM c.source_table
        AND e.source_id IS NOT DISTINCT FROM c.source_id
    )
      AND NOT EXISTS (
        SELECT 1 FROM supplier_goods g
        WHERE g.document_lane IS NOT DISTINCT FROM c.document_lane
          AND g.source_table IS NOT DISTINCT FROM c.source_table
          AND g.source_id IS NOT DISTINCT FROM c.source_id
      )
  )
  SELECT * FROM existing_queue
  UNION ALL
  SELECT * FROM supplier_goods
  UNION ALL
  SELECT * FROM supplier_credit;
$func$;

REVOKE ALL ON FUNCTION public.internal_ready_for_sage_queue_v2() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_ready_for_sage_queue_v2() TO authenticated;

COMMENT ON FUNCTION public.internal_ready_for_sage_queue_v2_pre_supplier_lane_restore_v1() IS
'Private preserved implementation of the canonical Sage queue before supplier-lane restoration.';

COMMENT ON FUNCTION public.internal_ready_for_sage_queue_v2() IS
'Canonical dynamic Sage-ready queue. Every read composes the preserved queue with all current and future supplier goods AP and approved supplier credit-note rows from the existing helpers, deduplicated by lane/table/source id.';

NOTIFY pgrst, 'reload schema';

COMMIT;
