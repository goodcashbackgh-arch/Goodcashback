BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Restore supplier goods AP and supplier credit-note lanes to the shared Sage-ready queue.
-- This is deliberately compositional:
--   1. preserve the exact live internal_ready_for_sage_queue_v2() implementation as a private baseline copy;
--   2. keep the public function OID/name and return shape unchanged;
--   3. append the two already-built helper lanes;
--   4. suppress only exact duplicate lane/source rows.
-- No source, freeze, posting, VAT, banking, customer-sales, shipper-AP, Mini-build 1-3,
-- or planned Mini-build 4 logic is replaced.

DO $block$
DECLARE
  v_current_definition text;
  v_backup_definition text;
  v_current_body text;
BEGIN
  IF to_regprocedure('public.internal_ready_for_sage_queue_v2()') IS NULL THEN
    RAISE EXCEPTION 'Missing public.internal_ready_for_sage_queue_v2()';
  END IF;

  IF to_regprocedure('public.internal_supplier_goods_ap_ready_rows_v1()') IS NULL THEN
    RAISE EXCEPTION 'Missing public.internal_supplier_goods_ap_ready_rows_v1()';
  END IF;

  IF to_regprocedure('public.internal_supplier_credit_note_ready_rows_v1()') IS NULL THEN
    RAISE EXCEPTION 'Missing public.internal_supplier_credit_note_ready_rows_v1()';
  END IF;

  SELECT pg_get_functiondef('public.internal_ready_for_sage_queue_v2()'::regprocedure)
  INTO v_current_definition;

  v_current_body := lower(v_current_definition);

  -- Idempotent rerun: once the wrapper already references the preserved baseline and both
  -- helper lanes, do not copy the wrapper over the baseline or alter anything further.
  IF position('internal_ready_for_sage_queue_v2_pre_supplier_lane_restore_v1' IN v_current_body) > 0
     AND position('internal_supplier_goods_ap_ready_rows_v1' IN v_current_body) > 0
     AND position('internal_supplier_credit_note_ready_rows_v1' IN v_current_body) > 0
  THEN
    RETURN;
  END IF;

  -- Preserve the exact currently deployed queue behaviour before composing extra lanes.
  -- CREATE OR REPLACE below keeps internal_ready_for_sage_queue_v2() itself stable for all
  -- existing callers; the copied function is private implementation detail only.
  v_backup_definition := replace(
    v_current_definition,
    'FUNCTION public.internal_ready_for_sage_queue_v2()',
    'FUNCTION public.internal_ready_for_sage_queue_v2_pre_supplier_lane_restore_v1()'
  );

  IF v_backup_definition = v_current_definition THEN
    RAISE EXCEPTION 'Could not preserve current internal_ready_for_sage_queue_v2() definition safely';
  END IF;

  EXECUTE v_backup_definition;
END
$block$;

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
    SELECT *
    FROM public.internal_ready_for_sage_queue_v2_pre_supplier_lane_restore_v1()
  ), supplier_goods AS (
    SELECT g.*
    FROM public.internal_supplier_goods_ap_ready_rows_v1() g
    WHERE NOT EXISTS (
      SELECT 1
      FROM existing_queue e
      WHERE e.document_lane IS NOT DISTINCT FROM g.document_lane
        AND e.source_table IS NOT DISTINCT FROM g.source_table
        AND e.source_id IS NOT DISTINCT FROM g.source_id
    )
  ), supplier_credit AS (
    SELECT c.*
    FROM public.internal_supplier_credit_note_ready_rows_v1() c
    WHERE NOT EXISTS (
      SELECT 1
      FROM existing_queue e
      WHERE e.document_lane IS NOT DISTINCT FROM c.document_lane
        AND e.source_table IS NOT DISTINCT FROM c.source_table
        AND e.source_id IS NOT DISTINCT FROM c.source_id
    )
      AND NOT EXISTS (
        SELECT 1
        FROM supplier_goods g
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

REVOKE ALL ON FUNCTION public.internal_ready_for_sage_queue_v2_pre_supplier_lane_restore_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_ready_for_sage_queue_v2_pre_supplier_lane_restore_v1() TO authenticated;

REVOKE ALL ON FUNCTION public.internal_ready_for_sage_queue_v2() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_ready_for_sage_queue_v2() TO authenticated;

COMMENT ON FUNCTION public.internal_ready_for_sage_queue_v2_pre_supplier_lane_restore_v1() IS
'Exact preserved pre-restoration implementation of internal_ready_for_sage_queue_v2(), retained so the public queue can compose existing behaviour with already-built supplier goods and supplier credit lanes without rebuilding or rolling back other lanes.';

COMMENT ON FUNCTION public.internal_ready_for_sage_queue_v2() IS
'Canonical shared Sage-ready queue: preserves the exact prior queue and additively composes existing supplier goods AP and supplier credit-note helpers, deduplicated by document lane, source table and source id.';

NOTIFY pgrst, 'reload schema';

COMMIT;
