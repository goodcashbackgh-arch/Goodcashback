BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Treasury statement control corrective pack — hardening patch.
-- 1. Remove the attempted row lock on a joined interpretation view. The physical
--    dva_statement_lines row remains explicitly locked immediately afterwards.
-- 2. Keep eligibility aligned with the write RPC by blocking archived/cancelled orders.

DO $$
DECLARE
  v_allocator_definition text;
  v_ranking_definition text;
  v_allocator_patched text;
  v_ranking_patched text;
BEGIN
  IF to_regprocedure('public.staff_allocate_statement_line_to_supplier_invoice_incremental_v1(uuid,uuid,numeric,text)') IS NULL THEN
    RAISE EXCEPTION 'Sequential supplier allocator is missing.';
  END IF;
  IF to_regprocedure('public.internal_supplier_payment_next_invoice_candidates_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Supplier-payment next-invoice ranking function is missing.';
  END IF;

  SELECT pg_get_functiondef(
    'public.staff_allocate_statement_line_to_supplier_invoice_incremental_v1(uuid,uuid,numeric,text)'::regprocedure
  ) INTO v_allocator_definition;

  v_allocator_patched := regexp_replace(
    v_allocator_definition,
    E'\\n[[:space:]]*FOR UPDATE OF e;',
    ';',
    'i'
  );

  IF v_allocator_patched = v_allocator_definition THEN
    RAISE EXCEPTION 'Expected FOR UPDATE OF e clause was not found in sequential allocator definition.';
  END IF;
  IF position('PERFORM 1 FROM public.dva_statement_lines dsl' in v_allocator_patched) = 0
     OR position('FOR UPDATE;' in v_allocator_patched) = 0 THEN
    RAISE EXCEPTION 'Physical statement-line lock is missing after allocator hardening.';
  END IF;

  EXECUTE v_allocator_patched;

  SELECT pg_get_functiondef(
    'public.internal_supplier_payment_next_invoice_candidates_v1(uuid)'::regprocedure
  ) INTO v_ranking_definition;

  IF position('c.retailer_id AS candidate_retailer_id,' in v_ranking_definition) = 0
     OR position('WHEN cb.candidate_importer_id IS DISTINCT FROM cb.importer_id' in v_ranking_definition) = 0 THEN
    RAISE EXCEPTION 'Expected ranking-function anchors were not found.';
  END IF;

  v_ranking_patched := replace(
    v_ranking_definition,
    'c.retailer_id AS candidate_retailer_id,',
    E'c.retailer_id AS candidate_retailer_id,\n      o.status::text AS candidate_order_status,'
  );

  v_ranking_patched := replace(
    v_ranking_patched,
    'WHEN cb.candidate_importer_id IS DISTINCT FROM cb.importer_id THEN ''candidate_importer_mismatch''',
    E'WHEN cb.candidate_order_status IN (''archived'', ''cancelled'') THEN ''candidate_order_archived_or_cancelled''\n        WHEN cb.candidate_importer_id IS DISTINCT FROM cb.importer_id THEN ''candidate_importer_mismatch'''
  );

  IF v_ranking_patched = v_ranking_definition
     OR position('candidate_order_archived_or_cancelled' in v_ranking_patched) = 0
     OR position('candidate_order_status' in v_ranking_patched) = 0 THEN
    RAISE EXCEPTION 'Ranking-function archived/cancelled order guard was not installed.';
  END IF;

  EXECUTE v_ranking_patched;
END $$;

REVOKE ALL ON FUNCTION public.staff_allocate_statement_line_to_supplier_invoice_incremental_v1(uuid, uuid, numeric, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.staff_allocate_statement_line_to_supplier_invoice_incremental_v1(uuid, uuid, numeric, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.staff_allocate_statement_line_to_supplier_invoice_incremental_v1(uuid, uuid, numeric, text) TO authenticated;

REVOKE ALL ON FUNCTION public.internal_supplier_payment_next_invoice_candidates_v1(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_supplier_payment_next_invoice_candidates_v1(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.internal_supplier_payment_next_invoice_candidates_v1(uuid) TO authenticated;

COMMENT ON FUNCTION public.staff_allocate_statement_line_to_supplier_invoice_incremental_v1(uuid, uuid, numeric, text) IS
'Sequential supplier-payment allocator. Locks the physical statement row and target invoice/order, repeats funding/readiness and amount controls, permits invoice-by-invoice allocation only within one order/importer/retailer, and inherits the first allocation source mapping.';

COMMENT ON FUNCTION public.internal_supplier_payment_next_invoice_candidates_v1(uuid) IS
'Read-only supplier-payment candidate contract aligned to the sequential allocator, including archived/cancelled order exclusion, hard eligibility, explicit blockers and non-binding amount/date/retailer/reference ranking.';

NOTIFY pgrst, 'reload schema';
COMMIT;
