BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Keep the existing atomic bundle RPC and its signature, but compose it from
-- the installed incremental allocator so a supplier bundle may consume only
-- the selected invoice balances. Any failure still rolls back every leg.
DO $$
BEGIN
  IF to_regprocedure('public.staff_allocate_statement_line_to_supplier_invoice_bundle(uuid,jsonb,text)') IS NULL THEN
    RAISE EXCEPTION 'Atomic supplier bundle allocator is missing.';
  END IF;
  IF to_regprocedure('public.staff_allocate_statement_line_to_supplier_invoice_incremental_v(uuid,uuid,numeric,text)') IS NULL THEN
    RAISE EXCEPTION 'Incremental supplier allocator is missing.';
  END IF;
END $$;

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
  v_input record;
  v_result jsonb;
  v_input_count integer := 0;
  v_inserted_ids uuid[] := ARRAY[]::uuid[];
  v_requested_total numeric(12,2) := 0;
  v_order_id uuid;
  v_order_ref text;
  v_importer_id uuid;
  v_retailer_id uuid;
  v_statement_total numeric(12,2) := 0;
  v_source_mapping text;
  v_source_wallet text;
  v_source_reason text;
  v_balanced_yn boolean := false;
BEGIN
  IF p_allocations IS NULL
     OR jsonb_typeof(p_allocations) <> 'array'
     OR jsonb_array_length(p_allocations) = 0 THEN
    RAISE EXCEPTION 'p_allocations must be a non-empty JSON array';
  END IF;

  CREATE TEMP TABLE pg_temp.supplier_payment_bundle_incremental_input (
    sequence_no bigint PRIMARY KEY,
    supplier_invoice_id uuid NOT NULL UNIQUE,
    allocated_gbp_amount numeric(12,2) NOT NULL
  ) ON COMMIT DROP;

  BEGIN
    INSERT INTO pg_temp.supplier_payment_bundle_incremental_input (
      sequence_no,
      supplier_invoice_id,
      allocated_gbp_amount
    )
    SELECT
      item.ordinality,
      NULLIF(item.value ->> 'supplier_invoice_id', '')::uuid,
      ROUND(COALESCE(NULLIF(item.value ->> 'allocated_gbp_amount', '')::numeric, 0), 2)
    FROM jsonb_array_elements(p_allocations) WITH ORDINALITY AS item(value, ordinality);
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'Each supplier invoice may appear only once in the allocation bundle.';
  END;

  SELECT COUNT(*)::integer
    INTO v_input_count
  FROM pg_temp.supplier_payment_bundle_incremental_input;

  IF v_input_count <> jsonb_array_length(p_allocations) THEN
    RAISE EXCEPTION 'Supplier-payment bundle contains an invalid invoice entry.';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM pg_temp.supplier_payment_bundle_incremental_input i
    WHERE i.allocated_gbp_amount <= 0
  ) THEN
    RAISE EXCEPTION 'Every supplier invoice allocation amount must be greater than zero.';
  END IF;

  FOR v_input IN
    SELECT i.supplier_invoice_id, i.allocated_gbp_amount
    FROM pg_temp.supplier_payment_bundle_incremental_input i
    ORDER BY i.sequence_no
  LOOP
    v_result := public.staff_allocate_statement_line_to_supplier_invoice_incremental_v(
      p_dva_statement_line_id,
      v_input.supplier_invoice_id,
      v_input.allocated_gbp_amount,
      concat_ws(E'\n', NULLIF(p_notes, ''), 'Atomic multi-invoice supplier-payment bundle')
    );

    IF COALESCE((v_result ->> 'ok')::boolean, false) IS DISTINCT FROM true
       OR NULLIF(v_result ->> 'allocation_id', '') IS NULL THEN
      RAISE EXCEPTION 'Incremental supplier allocation returned an invalid result for invoice %.',
        v_input.supplier_invoice_id;
    END IF;

    IF v_order_id IS NULL THEN
      v_order_id := (v_result ->> 'order_id')::uuid;
      v_order_ref := v_result ->> 'order_ref';
      v_importer_id := (v_result ->> 'importer_id')::uuid;
      v_retailer_id := (v_result ->> 'retailer_id')::uuid;
      v_statement_total := ROUND(COALESCE((v_result ->> 'statement_gbp_amount')::numeric, 0), 2);
    ELSIF v_order_id IS DISTINCT FROM (v_result ->> 'order_id')::uuid
       OR v_importer_id IS DISTINCT FROM (v_result ->> 'importer_id')::uuid
       OR v_retailer_id IS DISTINCT FROM (v_result ->> 'retailer_id')::uuid THEN
      RAISE EXCEPTION 'All supplier allocations in one atomic bundle must resolve to one order, importer and retailer.';
    END IF;

    v_inserted_ids := array_append(v_inserted_ids, (v_result ->> 'allocation_id')::uuid);
    v_requested_total := ROUND(v_requested_total + (v_result ->> 'allocated_gbp_amount')::numeric, 2);
    v_source_mapping := v_result ->> 'source_bank_account_mapping_code';
    v_source_wallet := v_result ->> 'source_wallet_code';
    v_source_reason := v_result ->> 'source_resolution_reason';
    v_balanced_yn := COALESCE((v_result ->> 'statement_balanced_yn')::boolean, false);
  END LOOP;

  IF COALESCE(array_length(v_inserted_ids, 1), 0) <> v_input_count THEN
    RAISE EXCEPTION 'Supplier-payment bundle insert count mismatch. Expected %, inserted %',
      v_input_count,
      COALESCE(array_length(v_inserted_ids, 1), 0);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'dva_statement_line_id', p_dva_statement_line_id,
    'order_id', v_order_id,
    'order_ref', v_order_ref,
    'importer_id', v_importer_id,
    'retailer_id', v_retailer_id,
    'statement_gbp_amount', v_statement_total,
    'allocated_gbp_amount', v_requested_total,
    'allocation_count', v_input_count,
    'allocation_ids', to_jsonb(v_inserted_ids),
    'source_bank_account_mapping_code', v_source_mapping,
    'source_wallet_code', v_source_wallet,
    'source_resolution_reason', v_source_reason,
    'balanced_yn', v_balanced_yn
  );
END;
$$;

COMMENT ON FUNCTION public.staff_allocate_statement_line_to_supplier_invoice_bundle(uuid, jsonb, text) IS
'Atomic multi-invoice supplier-payment bundle using the installed incremental allocator for each selected invoice. All legs commit or roll back together; selected supplier amounts may leave a governed statement residual for the existing FX/card/fee path.';

REVOKE ALL ON FUNCTION public.staff_allocate_statement_line_to_supplier_invoice_bundle(uuid, jsonb, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.staff_allocate_statement_line_to_supplier_invoice_bundle(uuid, jsonb, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.staff_allocate_statement_line_to_supplier_invoice_bundle(uuid, jsonb, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
