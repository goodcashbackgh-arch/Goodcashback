-- Read-only live DB preflight for the exact-clean mixed-package sales patch.
-- No DDL, DML, draft creation, or staff-authenticated RPC calls.

WITH wanted_functions(name) AS (
  VALUES
    ('internal_tracking_allocation_fulfilment_position_v1'),
    ('internal_tracking_allocation_fulfilment_routing_position_v2'),
    ('shipper_shipment_batch_effective_lines_v1'),
    ('shipper_create_shipment_batch_v2'),
    ('internal_customer_sales_release_sources_v1'),
    ('customer_sales_release_guard_v1'),
    ('customer_sales_release_financial_guard_v1'),
    ('internal_shipping_customer_invoice_readiness_preview_v1'),
    ('internal_customer_invoice_release_queue_v1'),
    ('internal_customer_invoice_release_create_drafts_v1'),
    ('internal_resolved_customer_sales_sage_payload_v1'),
    ('internal_customer_sales_sage_payload_pre_ledger_v1'),
    ('approve_vat_release'),
    ('mark_order_accounting_release_ready'),
    ('recompute_order_status')
), fn AS (
  SELECT
    w.name,
    p.oid,
    CASE WHEN p.oid IS NULL THEN NULL ELSE format('%I.%I(%s)', n.nspname, p.proname, pg_get_function_identity_arguments(p.oid)) END AS signature,
    CASE WHEN p.oid IS NULL THEN NULL ELSE pg_get_function_result(p.oid) END AS result_signature,
    CASE WHEN p.oid IS NULL THEN NULL ELSE pg_get_userbyid(p.proowner) END AS owner_name,
    p.prosecdef AS security_definer,
    p.provolatile,
    p.proacl::text AS acl,
    CASE WHEN p.oid IS NULL THEN NULL ELSE md5(pg_get_functiondef(p.oid)) END AS definition_md5,
    CASE WHEN p.oid IS NULL THEN NULL ELSE pg_get_functiondef(p.oid) END AS definition
  FROM wanted_functions w
  LEFT JOIN pg_namespace n ON n.nspname = 'public'
  LEFT JOIN pg_proc p ON p.pronamespace = n.oid AND p.proname = w.name
), target_batch AS (
  SELECT id, booking_ref, status
  FROM public.shipper_shipment_batches
  WHERE booking_ref = 'J040826'
  ORDER BY created_at DESC, id DESC
  LIMIT 1
), effective AS (
  SELECT e.*
  FROM target_batch b
  CROSS JOIN LATERAL public.shipper_shipment_batch_effective_lines_v1(b.id) e
), target_tracking AS (
  SELECT DISTINCT tracking_submission_id FROM effective
), latest_receipt AS (
  SELECT DISTINCT ON (r.tracking_submission_id)
    r.id,
    r.tracking_submission_id,
    r.receipt_status::text AS receipt_status,
    r.receipt_model_version,
    r.receipt_state::text AS receipt_state,
    r.finalised_at,
    r.recorded_at,
    r.created_at
  FROM public.shipper_package_receipts r
  JOIN target_tracking t ON t.tracking_submission_id = r.tracking_submission_id
  WHERE r.receipt_model_version = 1
     OR (r.receipt_model_version = 2 AND r.receipt_state = 'finalised' AND r.finalised_at IS NOT NULL)
  ORDER BY r.tracking_submission_id,
           COALESCE(r.finalised_at, r.recorded_at, r.created_at) DESC,
           r.created_at DESC,
           r.id DESC
), dispositions AS (
  SELECT
    d.tracking_line_allocation_id,
    COALESCE(SUM(d.quantity) FILTER (WHERE d.disposition_type = 'clean'), 0)::numeric AS clean_qty,
    COALESCE(SUM(d.quantity) FILTER (WHERE d.disposition_type <> 'clean'), 0)::numeric AS exception_qty
  FROM public.shipper_package_receipt_line_dispositions d
  JOIN latest_receipt r ON r.id = d.receipt_id
  GROUP BY d.tracking_line_allocation_id
), released AS (
  SELECT
    tracking_line_allocation_id,
    COALESCE(SUM(released_qty), 0)::numeric AS released_qty,
    COALESCE(SUM(goods_amount_gbp), 0)::numeric AS released_goods,
    COALESCE(SUM(shipping_amount_gbp), 0)::numeric AS released_shipping,
    COUNT(*)::integer AS active_memberships
  FROM public.customer_sales_release_lines
  WHERE release_status = 'active'
  GROUP BY tracking_line_allocation_id
), matrix AS (
  SELECT
    a.id AS tracking_line_allocation_id,
    a.order_id,
    a.tracking_submission_id,
    a.supplier_invoice_line_id,
    a.qty_allocated,
    a.adjusted_net_value_gbp AS allocation_goods_value_gbp,
    e.qty_in_shipment,
    e.adjusted_net_value_gbp AS shipment_goods_value_gbp,
    e.source_mode::text AS source_mode,
    (e.tracking_line_allocation_id IS NOT NULL) AS admitted_to_effective_shipment,
    r.id AS receipt_id,
    r.receipt_status,
    r.receipt_model_version,
    r.receipt_state,
    p.source_receipt_model,
    p.physical_clean_qty,
    p.physical_exception_qty,
    p.reviewed_qty,
    p.active_hold_qty,
    p.shipped_qty,
    p.customer_released_qty,
    p.position_valid_yn,
    p.position_blocker,
    COALESCE(d.clean_qty, 0)::numeric AS disposition_clean_qty,
    COALESCE(d.exception_qty, 0)::numeric AS disposition_exception_qty,
    COALESCE(x.released_qty, 0)::numeric AS ledger_released_qty,
    COALESCE(x.released_goods, 0)::numeric AS ledger_released_goods,
    COALESCE(x.released_shipping, 0)::numeric AS ledger_released_shipping,
    COALESCE(x.active_memberships, 0)::integer AS active_release_memberships,
    EXISTS (
      SELECT 1
      FROM public.sales_invoices s
      WHERE s.order_id = a.order_id
        AND s.invoice_type IN ('main', 'supplementary')
        AND s.sage_status = 'draft'
    ) AS has_active_sales_draft,
    CASE
      WHEN e.tracking_line_allocation_id IS NULL THEN false
      WHEN e.source_mode::text <> 'immutable_snapshot' THEN false
      WHEN COALESCE(e.qty_in_shipment, 0) <= 0 THEN false
      WHEN p.source_receipt_model IS DISTINCT FROM 'v2_exact' THEN false
      WHEN p.position_valid_yn IS DISTINCT FROM true THEN false
      WHEN p.physical_clean_qty + 0.0005 < p.shipped_qty THEN false
      WHEN p.shipped_qty + 0.0005 < e.qty_in_shipment THEN false
      ELSE true
    END AS proposed_exact_clean_proof
  FROM public.order_tracking_line_allocations a
  JOIN target_tracking t ON t.tracking_submission_id = a.tracking_submission_id
  LEFT JOIN effective e ON e.tracking_line_allocation_id = a.id
  LEFT JOIN latest_receipt r ON r.tracking_submission_id = a.tracking_submission_id
  LEFT JOIN dispositions d ON d.tracking_line_allocation_id = a.id
  LEFT JOIN released x ON x.tracking_line_allocation_id = a.id
  LEFT JOIN LATERAL public.internal_tracking_allocation_fulfilment_position_v1(
    a.order_id,
    a.tracking_submission_id,
    a.id
  ) p ON p.tracking_line_allocation_id = a.id
), consumers AS (
  SELECT
    p.proname AS consumer_name,
    format('%I.%I(%s)', n.nspname, p.proname, pg_get_function_identity_arguments(p.oid)) AS consumer_signature,
    md5(pg_get_functiondef(p.oid)) AS definition_md5,
    CASE
      WHEN pg_get_functiondef(p.oid) ILIKE '%internal_customer_sales_release_sources_v1%' THEN 'internal_customer_sales_release_sources_v1'
      ELSE 'internal_customer_invoice_release_queue_v1'
    END AS references_object
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.prokind = 'f'
    AND (
      (p.proname <> 'internal_customer_sales_release_sources_v1' AND pg_get_functiondef(p.oid) ILIKE '%internal_customer_sales_release_sources_v1%')
      OR
      (p.proname <> 'internal_customer_invoice_release_queue_v1' AND pg_get_functiondef(p.oid) ILIKE '%internal_customer_invoice_release_queue_v1%')
    )
)
SELECT jsonb_build_object(
  'probe', 'customer_sales_exact_clean_patch_db_preflight_v1',
  'database', current_database(),
  'current_user', current_user,
  'helper_name_free', to_regprocedure('public.internal_customer_sales_release_exact_clean_proof_v1(uuid,uuid)') IS NULL,
  'function_contracts', COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'name', name,
      'exists', oid IS NOT NULL,
      'signature', signature,
      'result_signature', result_signature,
      'owner', owner_name,
      'security_definer', security_definer,
      'volatility', provolatile,
      'acl', acl,
      'definition_md5', definition_md5
    ) ORDER BY name, signature)
    FROM fn
  ), '[]'::jsonb),
  'live_consumers', COALESCE((
    SELECT jsonb_agg(to_jsonb(c) ORDER BY references_object, consumer_signature)
    FROM consumers c
  ), '[]'::jsonb),
  'source_contract_checks', jsonb_build_object(
    'resolver_uses_effective_lines', EXISTS (
      SELECT 1 FROM fn WHERE name = 'internal_customer_sales_release_sources_v1' AND definition ILIKE '%shipper_shipment_batch_effective_lines_v1%'
    ),
    'resolver_has_package_blocker', EXISTS (
      SELECT 1 FROM fn WHERE name = 'internal_customer_sales_release_sources_v1' AND definition ILIKE '%package_not_received_clean%'
    ),
    'queue_has_received_clean_gate', EXISTS (
      SELECT 1 FROM fn WHERE name = 'internal_customer_invoice_release_queue_v1' AND definition ILIKE '%receipt_status_summary%' AND definition ILIKE '%received_clean%'
    ),
    'queue_uses_readiness_preview', EXISTS (
      SELECT 1 FROM fn WHERE name = 'internal_customer_invoice_release_queue_v1' AND definition ILIKE '%internal_shipping_customer_invoice_readiness_preview_v1%'
    )
  ),
  'target_batch', (SELECT to_jsonb(b) FROM target_batch b),
  'target_counts', jsonb_build_object(
    'effective_line_count', (SELECT COUNT(*) FROM effective),
    'allocation_count', (SELECT COUNT(*) FROM matrix),
    'proven_exact_clean_count', (SELECT COUNT(*) FROM matrix WHERE proposed_exact_clean_proof),
    'unreleased_proven_count', (SELECT COUNT(*) FROM matrix WHERE proposed_exact_clean_proof AND ledger_released_qty = 0 AND NOT has_active_sales_draft)
  ),
  'target_allocation_matrix', COALESCE((
    SELECT jsonb_agg(to_jsonb(m) ORDER BY tracking_line_allocation_id)
    FROM matrix m
  ), '[]'::jsonb),
  'critical_definitions', jsonb_build_object(
    'resolver', (SELECT definition FROM fn WHERE name = 'internal_customer_sales_release_sources_v1' ORDER BY oid LIMIT 1),
    'queue', (SELECT definition FROM fn WHERE name = 'internal_customer_invoice_release_queue_v1' ORDER BY oid LIMIT 1)
  )
) AS result;
