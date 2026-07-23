BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Single-invoice supplier allocation must resolve funding provenance for the
-- amount actually being allocated, not the full physical statement OUT.
-- This preserves the remaining statement balance for later supplier legs or
-- the existing FX/card/fee residual path.
DO $migration$
DECLARE
  v_allocator regprocedure := to_regprocedure(
    'public.staff_allocate_statement_line_to_supplier_invoice_incremental_v(uuid,uuid,numeric,text)'
  );
  v_definition text;
  v_patched text;
BEGIN
  IF v_allocator IS NULL THEN
    RAISE EXCEPTION 'Incremental supplier allocator is missing.';
  END IF;

  SELECT pg_get_functiondef(v_allocator)
    INTO v_definition;

  IF v_definition ~ 'internal_supplier_payment_bundle_source_v1\([[:space:]]*v_order[.]id[[:space:]]*,[[:space:]]*v_amount[[:space:]]*\)' THEN
    v_patched := v_definition;
  ELSE
    v_patched := regexp_replace(
      v_definition,
      'internal_supplier_payment_bundle_source_v1\([[:space:]]*v_order[.]id[[:space:]]*,[[:space:]]*v_statement_total[[:space:]]*\)',
      'internal_supplier_payment_bundle_source_v1(v_order.id, v_amount)',
      'i'
    );
  END IF;

  IF v_patched !~ 'internal_supplier_payment_bundle_source_v1\([[:space:]]*v_order[.]id[[:space:]]*,[[:space:]]*v_amount[[:space:]]*\)' THEN
    RAISE EXCEPTION 'Incremental supplier source-resolution amount correction could not be installed.';
  END IF;

  v_patched := regexp_replace(
    v_patched,
    'Supplier-payment source mapping could not be resolved for order % and physical OUT %',
    'Supplier-payment source mapping could not be resolved for order % and allocation amount %',
    'i'
  );

  IF v_patched <> v_definition THEN
    EXECUTE v_patched;
  END IF;
END
$migration$;

REVOKE ALL ON FUNCTION public.staff_allocate_statement_line_to_supplier_invoice_incremental_v(uuid, uuid, numeric, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.staff_allocate_statement_line_to_supplier_invoice_incremental_v(uuid, uuid, numeric, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.staff_allocate_statement_line_to_supplier_invoice_incremental_v(uuid, uuid, numeric, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
