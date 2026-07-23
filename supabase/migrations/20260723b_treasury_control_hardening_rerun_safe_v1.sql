BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Rerun-safe correction for the treasury hardening migration.
-- The historical migration depended on exact pg_get_functiondef() formatting
-- and raised when the allocator had already been hardened or was formatted
-- differently. This migration accepts either state, removes only the invalid
-- view lock when present, preserves the physical row lock, applies the
-- archived/cancelled ranking guard once, and refreshes PostgREST.
DO $migration$
DECLARE
  v_allocator regprocedure := to_regprocedure(
    'public.staff_allocate_statement_line_to_supplier_invoice_incremental_v(uuid,uuid,numeric,text)'
  );
  v_ranking regprocedure := to_regprocedure(
    'public.internal_supplier_payment_next_invoice_candidates_v1(uuid)'
  );
  v_allocator_definition text;
  v_allocator_patched text;
  v_ranking_definition text;
  v_ranking_patched text;
BEGIN
  IF v_allocator IS NULL THEN
    RAISE EXCEPTION 'Incremental supplier allocator is missing. Apply 20260722b_statement_interpretation_and_sequential_supplier_allocation_v1.sql first.';
  END IF;

  SELECT pg_get_functiondef(v_allocator)
    INTO v_allocator_definition;

  -- PostgreSQL may preserve or normalise whitespace/case. Remove the invalid
  -- lock without relying on a particular newline or indentation. If it is
  -- already absent, this is intentionally a no-op.
  v_allocator_patched := regexp_replace(
    v_allocator_definition,
    'FOR[[:space:]]+UPDATE[[:space:]]+OF[[:space:]]+e[[:space:]]*;',
    '',
    'gi'
  );

  IF v_allocator_patched ~* 'FOR[[:space:]]+UPDATE[[:space:]]+OF[[:space:]]+e' THEN
    RAISE EXCEPTION 'Invalid view lock remains in the incremental supplier allocator.';
  END IF;

  IF v_allocator_patched !~* 'PERFORM[[:space:]]+1[[:space:]]+FROM[[:space:]]+public[.]dva_statement_lines[[:space:]]+dsl[[:space:]]+WHERE[[:space:]]+dsl[.]id[[:space:]]*=[[:space:]]*p_dva_statement_line_id[[:space:]]+FOR[[:space:]]+UPDATE[[:space:]]*;' THEN
    RAISE EXCEPTION 'Physical statement-line lock is missing from the incremental supplier allocator.';
  END IF;

  IF v_allocator_patched <> v_allocator_definition THEN
    EXECUTE v_allocator_patched;
  END IF;

  IF v_ranking IS NULL THEN
    RAISE EXCEPTION 'Supplier-payment next-invoice ranking function is missing. Apply 20260722c_supplier_payment_next_invoice_eligibility_and_ranking_v1.sql first.';
  END IF;

  SELECT pg_get_functiondef(v_ranking)
    INTO v_ranking_definition;

  v_ranking_patched := v_ranking_definition;

  IF position('candidate_order_status' in v_ranking_patched) = 0 THEN
    v_ranking_patched := regexp_replace(
      v_ranking_patched,
      '(c[.]retailer_id[[:space:]]+AS[[:space:]]+candidate_retailer_id[[:space:]]*,)',
      E'\\1\n      o.status::text AS candidate_order_status,',
      'i'
    );
  END IF;

  IF position('candidate_order_archived_or_cancelled' in v_ranking_patched) = 0 THEN
    v_ranking_patched := regexp_replace(
      v_ranking_patched,
      '(WHEN[[:space:]]+cb[.]candidate_importer_id[[:space:]]+IS[[:space:]]+DISTINCT[[:space:]]+FROM[[:space:]]+cb[.]importer_id[[:space:]]+THEN[[:space:]]+''candidate_importer_mismatch'')',
      E'WHEN cb.candidate_order_status IN (''archived'', ''cancelled'') THEN ''candidate_order_archived_or_cancelled''\n        \\1',
      'i'
    );
  END IF;

  IF position('candidate_order_status' in v_ranking_patched) = 0
     OR position('candidate_order_archived_or_cancelled' in v_ranking_patched) = 0 THEN
    RAISE EXCEPTION 'Archived/cancelled supplier-candidate guard could not be installed safely.';
  END IF;

  IF v_ranking_patched <> v_ranking_definition THEN
    EXECUTE v_ranking_patched;
  END IF;
END
$migration$;

REVOKE ALL ON FUNCTION public.staff_allocate_statement_line_to_supplier_invoice_incremental_v(uuid, uuid, numeric, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.staff_allocate_statement_line_to_supplier_invoice_incremental_v(uuid, uuid, numeric, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.staff_allocate_statement_line_to_supplier_invoice_incremental_v(uuid, uuid, numeric, text) TO authenticated;

REVOKE ALL ON FUNCTION public.internal_supplier_payment_next_invoice_candidates_v1(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_supplier_payment_next_invoice_candidates_v1(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.internal_supplier_payment_next_invoice_candidates_v1(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
