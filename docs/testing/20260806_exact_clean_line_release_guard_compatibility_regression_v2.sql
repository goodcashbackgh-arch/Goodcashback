-- Read-only post-E2E regression for the exact-clean release-ledger guard.
-- No DDL, DML, draft creation or authenticated write calls.

WITH target_batch AS (
  SELECT id, booking_ref
  FROM public.shipper_shipment_batches
  WHERE id = '1d8ed4af-4d35-4b2d-9913-9bae1a20a717'::uuid
    AND booking_ref = 'J040826'
), effective AS (
  SELECT e.*
  FROM target_batch b
  CROSS JOIN LATERAL public.shipper_shipment_batch_effective_lines_v1(b.id) e
), tracking AS (
  SELECT DISTINCT tracking_submission_id FROM effective
), allocations AS (
  SELECT
    a.id,
    e.qty_in_shipment,
    e.adjusted_net_value_gbp,
    e.source_mode,
    public.internal_customer_sales_release_exact_clean_proof_v1(
      (SELECT id FROM target_batch),
      a.id
    ) AS exact_clean_proof
  FROM public.order_tracking_line_allocations a
  JOIN tracking t ON t.tracking_submission_id = a.tracking_submission_id
  LEFT JOIN effective e ON e.tracking_line_allocation_id = a.id
), guard AS (
  SELECT pg_get_functiondef(
    'public.customer_sales_release_guard_v1()'::regprocedure
  ) AS definition
), grouped_membership AS (
  SELECT
    COUNT(*)::integer AS line_count,
    ROUND(COALESCE(SUM(line.customer_charge_amount_gbp), 0), 2) AS amount_gbp
  FROM public.customer_sales_release_lines line
  WHERE line.sales_invoice_id = 'a557ca14-03e5-43c0-b436-f843e9412a28'::uuid
    AND line.release_status = 'active'
    AND line.source_shipment_batch_id = '1d8ed4af-4d35-4b2d-9913-9bae1a20a717'::uuid
    AND line.tracking_line_allocation_id = '9dd8c47c-9dd9-4191-910b-41095f15feee'::uuid
), checks AS (
  SELECT jsonb_build_object(
    'helper_exists', to_regprocedure(
      'public.internal_customer_sales_release_exact_clean_proof_v1(uuid,uuid)'
    ) IS NOT NULL,
    'helper_not_public', NOT has_function_privilege(
      'public',
      'public.internal_customer_sales_release_exact_clean_proof_v1(uuid,uuid)',
      'EXECUTE'
    ),
    'helper_not_anon', NOT has_function_privilege(
      'anon',
      'public.internal_customer_sales_release_exact_clean_proof_v1(uuid,uuid)',
      'EXECUTE'
    ),
    'helper_not_authenticated', NOT has_function_privilege(
      'authenticated',
      'public.internal_customer_sales_release_exact_clean_proof_v1(uuid,uuid)',
      'EXECUTE'
    ),
    'guard_uses_helper', EXISTS (
      SELECT 1 FROM guard
      WHERE definition ILIKE '%internal_customer_sales_release_exact_clean_proof_v1(%'
    ),
    'guard_preserves_package_exception', EXISTS (
      SELECT 1 FROM guard
      WHERE definition ILIKE '%Package is not currently received clean%'
    ),
    'guard_preserves_effective_membership', EXISTS (
      SELECT 1 FROM guard
      WHERE definition ILIKE '%shipper_shipment_batch_effective_lines_v1%'
    ),
    'guard_preserves_hold_check', EXISTS (
      SELECT 1 FROM guard
      WHERE definition ILIKE '%Active customer hold conflicts with release membership%'
    ),
    'guard_preserves_exception_check', EXISTS (
      SELECT 1 FROM guard
      WHERE definition ILIKE '%Unresolved exception conflicts with release membership%'
    ),
    'guard_preserves_terminal_refund_check', EXISTS (
      SELECT 1 FROM guard
      WHERE definition ILIKE '%Terminal refunded line cannot be attached to a customer sales release%'
    ),
    'guard_preserves_qty_limit', EXISTS (
      SELECT 1 FROM guard
      WHERE definition ILIKE '%Release quantity exceeds exact effective shipment membership%'
    ),
    'guard_preserves_goods_limit', EXISTS (
      SELECT 1 FROM guard
      WHERE definition ILIKE '%Release goods value exceeds exact effective shipment membership%'
    ),
    'trigger_binding_present', EXISTS (
      SELECT 1
      FROM pg_trigger trigger_row
      JOIN pg_class relation_row ON relation_row.oid = trigger_row.tgrelid
      JOIN pg_namespace namespace_row ON namespace_row.oid = relation_row.relnamespace
      JOIN pg_proc function_row ON function_row.oid = trigger_row.tgfoid
      WHERE namespace_row.nspname = 'public'
        AND relation_row.relname = 'customer_sales_release_lines'
        AND trigger_row.tgname = 'trg_customer_sales_release_guard_v1'
        AND function_row.proname = 'customer_sales_release_guard_v1'
        AND NOT trigger_row.tgisinternal
    ),
    'target_batch_found', EXISTS (SELECT 1 FROM target_batch),
    'effective_line_count_one', (SELECT COUNT(*) FROM effective) = 1,
    'proven_line_count_one', (
      SELECT COUNT(*) FROM allocations WHERE exact_clean_proof
    ) = 1,
    'diverted_line_count_four', (
      SELECT COUNT(*) FROM allocations WHERE NOT exact_clean_proof
    ) = 4,
    'proven_allocation_exact', EXISTS (
      SELECT 1 FROM allocations
      WHERE id = '9dd8c47c-9dd9-4191-910b-41095f15feee'::uuid
        AND exact_clean_proof
        AND source_mode = 'immutable_snapshot'
        AND qty_in_shipment = 1
        AND adjusted_net_value_gbp = 10
    ),
    'current_grouped_membership_exact', EXISTS (
      SELECT 1 FROM grouped_membership
      WHERE line_count = 1
        AND amount_gbp = 10.00
    )
  ) AS value
)
SELECT jsonb_build_object(
  'regression', 'exact_clean_line_release_guard_compatibility_v2',
  'status', CASE
    WHEN NOT EXISTS (
      SELECT 1
      FROM jsonb_each((SELECT value FROM checks)) item
      WHERE item.value <> 'true'::jsonb
    ) THEN 'passed'
    ELSE 'failed'
  END,
  'checks', (SELECT value FROM checks),
  'batch_id', (SELECT id FROM target_batch),
  'booking_ref', (SELECT booking_ref FROM target_batch),
  'protected_grouped_invoice', 'a557ca14-03e5-43c0-b436-f843e9412a28'
) AS result;
