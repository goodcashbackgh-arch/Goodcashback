-- Read-only post-install regression for the exact-clean release-ledger guard.
-- No DDL, DML, draft creation or staff-authenticated RPC calls.

WITH target_batch AS (
  SELECT id, booking_ref
  FROM public.shipper_shipment_batches
  WHERE booking_ref = 'J040826'
  ORDER BY created_at DESC, id DESC
  LIMIT 1
), effective AS (
  SELECT e.*
  FROM target_batch b
  CROSS JOIN LATERAL public.shipper_shipment_batch_effective_lines_v1(b.id) e
), tracking AS (
  SELECT DISTINCT tracking_submission_id FROM effective
), allocations AS (
  SELECT
    a.id,
    a.order_id,
    a.tracking_submission_id,
    a.supplier_invoice_line_id,
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
    to_regprocedure('public.customer_sales_release_guard_v1()')
  ) AS definition
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
    'draft_creator_unchanged', md5(pg_get_functiondef(
      to_regprocedure('public.internal_customer_invoice_release_create_drafts_v1(uuid[])')
    )) = '2e75a619e3cc3cc2fc364d3cb5a85cc3',
    'readiness_preview_unchanged', md5(pg_get_functiondef(
      to_regprocedure('public.internal_shipping_customer_invoice_readiness_preview_v1(uuid)')
    )) = '25be89183956fe7f756472b0075b4f58',
    'remaining_preview_unchanged', md5(pg_get_functiondef(
      to_regprocedure('public.internal_shipping_customer_invoice_remaining_preview_v1(uuid)')
    )) = '0d6c54c50d5594a72b2af79700655020',
    'financial_guard_unchanged', md5(pg_get_functiondef(
      to_regprocedure('public.customer_sales_release_financial_guard_v1()')
    )) = 'c492d47d33c6419d14d4cb26799fbfb9',
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
    )
  ) AS value
)
SELECT jsonb_build_object(
  'regression', 'exact_clean_line_release_guard_compatibility_v1',
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
  'proven_allocation_id', (
    SELECT id FROM allocations WHERE exact_clean_proof LIMIT 1
  ),
  'proven_qty', (
    SELECT qty_in_shipment FROM allocations WHERE exact_clean_proof LIMIT 1
  ),
  'proven_goods_gbp', (
    SELECT adjusted_net_value_gbp FROM allocations WHERE exact_clean_proof LIMIT 1
  ),
  'diverted_allocation_count', (
    SELECT COUNT(*) FROM allocations WHERE NOT exact_clean_proof
  ),
  'note', 'Authenticated draft creation and duplicate suppression remain the final post-install acceptance.'
) AS result;
