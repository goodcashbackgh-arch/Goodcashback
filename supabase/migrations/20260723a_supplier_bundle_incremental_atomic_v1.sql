BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Patch the existing atomic bundle RPC in place. Preserve its authentication,
-- role, readiness, invoice, source-provenance, insert, audit and JSON contracts.
-- Only remove the obsolete full-physical-OUT equality requirement, replace the
-- unsupported UUID aggregate, and report whether a governed residual remains.
DO $migration$
DECLARE
  v_bundle_definition text;
  v_bundle_patched text;
BEGIN
  IF to_regprocedure('public.staff_allocate_statement_line_to_supplier_invoice_bundle(uuid,jsonb,text)') IS NULL THEN
    RAISE EXCEPTION 'Atomic supplier bundle allocator is missing.';
  END IF;

  SELECT pg_get_functiondef(
    'public.staff_allocate_statement_line_to_supplier_invoice_bundle(uuid,jsonb,text)'::regprocedure
  ) INTO v_bundle_definition;

  IF position('ABS(v_requested_total - v_statement_total) > 0.01' in v_bundle_definition) = 0
     OR position('MIN(si.order_id),' in v_bundle_definition) = 0
     OR position('''balanced_yn'', true' in v_bundle_definition) = 0 THEN
    RAISE EXCEPTION 'Expected atomic supplier bundle definition anchors were not found.';
  END IF;

  v_bundle_patched := replace(
    v_bundle_definition,
    'ABS(v_requested_total - v_statement_total) > 0.01',
    'v_requested_total > v_statement_total + 0.005'
  );

  v_bundle_patched := replace(
    v_bundle_patched,
    'One physical supplier-payment OUT must be allocated once for its full amount. Statement GBP %, bundle GBP %',
    'Supplier-payment bundle would over-allocate the physical OUT. Statement GBP %, bundle GBP %'
  );

  v_bundle_patched := replace(
    v_bundle_patched,
    'MIN(si.order_id),',
    '(ARRAY_AGG(si.order_id ORDER BY si.order_id))[1],'
  );

  v_bundle_patched := replace(
    v_bundle_patched,
    '''balanced_yn'', true',
    '''balanced_yn'', ABS(v_statement_total - v_requested_total) < 0.01'
  );

  IF v_bundle_patched = v_bundle_definition
     OR position('v_requested_total > v_statement_total + 0.005' in v_bundle_patched) = 0
     OR position('(ARRAY_AGG(si.order_id ORDER BY si.order_id))[1]' in v_bundle_patched) = 0
     OR position('''balanced_yn'', ABS(v_statement_total - v_requested_total) < 0.01' in v_bundle_patched) = 0
     OR position('ABS(v_requested_total - v_statement_total) > 0.01' in v_bundle_patched) > 0
     OR position('MIN(si.order_id),' in v_bundle_patched) > 0 THEN
    RAISE EXCEPTION 'Atomic supplier bundle correction was not installed completely.';
  END IF;

  EXECUTE v_bundle_patched;
END
$migration$;

COMMENT ON FUNCTION public.staff_allocate_statement_line_to_supplier_invoice_bundle(uuid, jsonb, text) IS
'Atomic multi-invoice supplier-payment bundle. Existing authentication, readiness, mapping, audit and all-or-nothing controls are preserved; selected supplier amounts may leave a governed statement residual for the existing FX/card/fee path.';

REVOKE ALL ON FUNCTION public.staff_allocate_statement_line_to_supplier_invoice_bundle(uuid, jsonb, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.staff_allocate_statement_line_to_supplier_invoice_bundle(uuid, jsonb, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.staff_allocate_statement_line_to_supplier_invoice_bundle(uuid, jsonb, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
