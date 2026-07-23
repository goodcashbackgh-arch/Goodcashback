BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Preserve the mixed sequential/atomic allocator as the guarded core, then
-- expose the established public RPC name through a stale-selection filter.
-- Example: A is already confirmed; the browser submits A+B+C; only B+C are
-- passed to the atomic core. No duplicate allocation is created.
DO $migration$
BEGIN
  IF to_regprocedure('public.staff_allocate_statement_line_to_supplier_invoice_bundle(uuid,jsonb,text)') IS NULL THEN
    RAISE EXCEPTION 'Mixed supplier bundle allocator is missing. Apply 20260723d first.';
  END IF;

  IF to_regprocedure('public.staff_allocate_statement_line_to_supplier_invoice_bundle_core_v1(uuid,jsonb,text)') IS NULL THEN
    ALTER FUNCTION public.staff_allocate_statement_line_to_supplier_invoice_bundle(uuid, jsonb, text)
      RENAME TO staff_allocate_statement_line_to_supplier_invoice_bundle_core_v1;
  END IF;
END
$migration$;

CREATE OR REPLACE FUNCTION public.staff_allocate_statement_line_to_supplier_invoice_bundle(
  p_dva_statement_line_id uuid,
  p_allocations jsonb,
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_filtered_allocations jsonb;
  v_requested_count integer := 0;
  v_filtered_count integer := 0;
  v_result jsonb;
BEGIN
  IF p_allocations IS NULL OR jsonb_typeof(p_allocations) <> 'array' THEN
    RAISE EXCEPTION 'p_allocations must be a JSON array';
  END IF;

  v_requested_count := jsonb_array_length(p_allocations);

  SELECT COALESCE(jsonb_agg(item ORDER BY ordinal_position), '[]'::jsonb)
    INTO v_filtered_allocations
  FROM (
    SELECT entry.item, entry.ordinal_position
    FROM jsonb_array_elements(p_allocations) WITH ORDINALITY AS entry(item, ordinal_position)
    WHERE NULLIF(entry.item->>'supplier_invoice_id', '') IS NOT NULL
      AND NOT EXISTS (
        SELECT 1
        FROM public.dva_statement_line_allocations existing
        WHERE existing.dva_statement_line_id = p_dva_statement_line_id
          AND existing.supplier_invoice_id = (entry.item->>'supplier_invoice_id')::uuid
          AND existing.allocation_type = 'supplier_invoice'
          AND existing.allocation_status <> 'reversed'
      )
  ) filtered;

  v_filtered_count := jsonb_array_length(v_filtered_allocations);

  IF v_filtered_count = 0 THEN
    RAISE EXCEPTION 'All selected supplier invoices are already allocated on this statement OUT.';
  END IF;

  v_result := public.staff_allocate_statement_line_to_supplier_invoice_bundle_core_v1(
    p_dva_statement_line_id,
    v_filtered_allocations,
    p_notes
  );

  RETURN v_result || jsonb_build_object(
    'submitted_invoice_count', v_requested_count,
    'new_invoice_count', v_filtered_count,
    'ignored_already_allocated_count', v_requested_count - v_filtered_count
  );
END;
$$;

COMMENT ON FUNCTION public.staff_allocate_statement_line_to_supplier_invoice_bundle(uuid, jsonb, text) IS
'Public mixed sequential/atomic supplier allocator. Filters stale already-confirmed invoice selections on the same OUT, then atomically allocates only newly selected invoices through the guarded core.';

REVOKE ALL ON FUNCTION public.staff_allocate_statement_line_to_supplier_invoice_bundle_core_v1(uuid, jsonb, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.staff_allocate_statement_line_to_supplier_invoice_bundle_core_v1(uuid, jsonb, text) FROM anon;
REVOKE ALL ON FUNCTION public.staff_allocate_statement_line_to_supplier_invoice_bundle_core_v1(uuid, jsonb, text) FROM authenticated;

REVOKE ALL ON FUNCTION public.staff_allocate_statement_line_to_supplier_invoice_bundle(uuid, jsonb, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.staff_allocate_statement_line_to_supplier_invoice_bundle(uuid, jsonb, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.staff_allocate_statement_line_to_supplier_invoice_bundle(uuid, jsonb, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
