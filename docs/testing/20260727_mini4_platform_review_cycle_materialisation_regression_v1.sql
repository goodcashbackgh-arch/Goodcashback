-- Read-only production regression for the Mini 4 platform materialisation repair.

WITH materialiser AS (
  SELECT pg_get_functiondef(
    'public.internal_materialize_customer_review_cycles_v1(uuid,uuid)'::regprocedure
  ) AS definition
),
trigger_state AS (
  SELECT
    bool_and(t.tgenabled <> 'D') AS all_enabled,
    count(*)::integer AS trigger_count
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND t.tgname IN (
      'trg_customer_review_receipt_materialize_v1',
      'trg_customer_review_allocation_materialize_v1',
      'trg_customer_review_supplier_line_materialize_v1',
      'trg_customer_review_supplier_invoice_materialize_v1'
    )
    AND NOT t.tgisinternal
),
open_candidate_orders AS (
  SELECT DISTINCT tracking_row.order_id
  FROM public.order_tracking_submissions tracking_row
  JOIN LATERAL (
    SELECT receipt.receipt_status, receipt.recorded_at
    FROM public.shipper_package_receipts receipt
    WHERE receipt.tracking_submission_id = tracking_row.id
    ORDER BY receipt.created_at DESC, receipt.id DESC
    LIMIT 1
  ) latest_receipt ON true
  WHERE tracking_row.superseded_at IS NULL
    AND latest_receipt.receipt_status = 'received_clean'
    AND latest_receipt.recorded_at <= now()
    AND latest_receipt.recorded_at + interval '24 hours' > now()
    AND EXISTS (
      SELECT 1
      FROM public.customer_review_cycle_candidates_v1(tracking_row.order_id)
    )
),
missing_cycles AS (
  SELECT order_id
  FROM open_candidate_orders candidate_order
  WHERE NOT EXISTS (
    SELECT 1
    FROM public.customer_order_review_links link_row
    WHERE link_row.order_id = candidate_order.order_id
      AND link_row.is_active = true
      AND link_row.expires_at IS NOT NULL
      AND link_row.expires_at > now()
  )
),
empty_cycles AS (
  SELECT link_row.id
  FROM public.customer_order_review_links link_row
  WHERE link_row.is_active = true
    AND link_row.expires_at IS NOT NULL
    AND link_row.expires_at > now()
    AND NOT EXISTS (
      SELECT 1
      FROM public.customer_review_cycle_memberships membership
      WHERE membership.review_link_id = link_row.id
        AND membership.membership_status = 'active'
    )
),
duplicate_cycle_fingerprints AS (
  SELECT membership.review_link_id, membership.membership_fingerprint
  FROM public.customer_review_cycle_memberships membership
  GROUP BY membership.review_link_id, membership.membership_fingerprint
  HAVING count(*) > 1
)
SELECT
  CASE
    WHEN position(
      'md5(v_link_id::text || ''|'' || candidate.source_fingerprint)'
      IN materialiser.definition
    ) = 0 THEN 'FAIL: cycle-scoped fingerprint missing'
    WHEN materialiser.definition ~ E'(^|\\n)[[:space:]]*candidate\\.source_fingerprint,'
      THEN 'FAIL: raw candidate fingerprint write remains'
    WHEN trigger_state.trigger_count <> 4 OR NOT trigger_state.all_enabled
      THEN 'FAIL: required receipt/allocation/eligibility triggers missing or disabled'
    WHEN EXISTS (SELECT 1 FROM missing_cycles)
      THEN 'FAIL: open valid-candidate orders remain without review cycles'
    WHEN EXISTS (SELECT 1 FROM empty_cycles)
      THEN 'FAIL: open timed review cycles exist without active membership'
    WHEN EXISTS (SELECT 1 FROM duplicate_cycle_fingerprints)
      THEN 'FAIL: duplicate membership fingerprint exists inside one review cycle'
    ELSE 'PASS'
  END AS regression_result,
  jsonb_build_object(
    'required_trigger_count', trigger_state.trigger_count,
    'all_required_triggers_enabled', trigger_state.all_enabled,
    'open_candidate_order_count', (SELECT count(*) FROM open_candidate_orders),
    'missing_cycle_count', (SELECT count(*) FROM missing_cycles),
    'empty_open_cycle_count', (SELECT count(*) FROM empty_cycles),
    'duplicate_cycle_fingerprint_count', (SELECT count(*) FROM duplicate_cycle_fingerprints)
  ) AS details
FROM materialiser
CROSS JOIN trigger_state;
