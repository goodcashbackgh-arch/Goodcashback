-- Exact Shipment-Batch Draft Status Correction v1
-- Read-only live database preflight.
--
-- Governing authority:
-- docs/governing-pack/architecture/
-- EXACT_SHIPMENT_BATCH_DRAFT_STATUS_CORRECTION_ADDENDUM_v1.md
-- docs/addenda/
-- CUSTOMER_RELEASE_QUEUE_EXACT_SHIPMENT_BATCH_DRAFT_STATUS_AMENDMENT_v1.md
--
-- Purpose:
--   * obtain the exact current installed queue fingerprint after the already
--     installed exact-clean batch-admission correction;
--   * freeze the queue signature, return contract, security attributes and ACL;
--   * prove the two old order-level count expressions occur exactly once;
--   * prove the exact shipment-batch count expressions are not already present;
--   * freeze protected Mini Build 1-3 definitions;
--   * reconfirm that the existing £10 draft contains J040826 only.
--
-- This script performs no DDL or DML.

WITH objects AS (
  SELECT
    to_regprocedure(
      'public.internal_customer_invoice_release_queue_v1()'
    ) AS queue_oid,
    to_regprocedure(
      'public.internal_customer_sales_release_sources_v1(uuid)'
    ) AS resolver_oid,
    to_regprocedure(
      'public.internal_customer_invoice_release_create_drafts_v1(uuid[])'
    ) AS creator_oid,
    to_regprocedure(
      'public.internal_shipping_customer_invoice_readiness_preview_v1(uuid)'
    ) AS readiness_oid,
    to_regprocedure(
      'public.internal_shipping_customer_invoice_remaining_preview_v1(uuid)'
    ) AS remaining_oid,
    to_regprocedure(
      'public.customer_sales_release_guard_v1()'
    ) AS release_guard_oid,
    to_regprocedure(
      'public.customer_sales_release_financial_guard_v1()'
    ) AS financial_guard_oid,
    to_regprocedure(
      'public.shipper_shipment_batch_effective_lines_v1(uuid)'
    ) AS effective_lines_oid,
    to_regprocedure(
      'public.internal_customer_sales_release_exact_clean_proof_v1(uuid,uuid)'
    ) AS exact_clean_helper_oid,
    to_regclass('public.customer_sales_release_lines') AS release_lines_table,
    to_regclass('public.sales_invoices') AS sales_invoices_table
), queue_definition AS (
  SELECT
    o.*,
    pg_get_functiondef(o.queue_oid) AS definition,
    regexp_replace(
      lower(pg_get_functiondef(o.queue_oid)),
      '[[:space:]]+',
      '',
      'g'
    ) AS compact_definition
  FROM objects o
  WHERE o.queue_oid IS NOT NULL
), queue_contract AS (
  SELECT
    p.oid,
    n.nspname AS schema_name,
    p.proname AS function_name,
    pg_get_function_identity_arguments(p.oid) AS identity_arguments,
    pg_get_function_arguments(p.oid) AS arguments,
    pg_get_function_result(p.oid) AS function_result,
    l.lanname AS language_name,
    p.prosecdef AS security_definer,
    p.proconfig AS function_config,
    r.rolname AS owner_name,
    p.proacl::text AS acl_text,
    NOT has_function_privilege(
      'public',
      p.oid,
      'EXECUTE'
    ) AS public_execute_revoked,
    has_function_privilege(
      'authenticated',
      p.oid,
      'EXECUTE'
    ) AS authenticated_execute_granted
  FROM queue_definition q
  JOIN pg_proc p ON p.oid = q.queue_oid
  JOIN pg_namespace n ON n.oid = p.pronamespace
  JOIN pg_language l ON l.oid = p.prolang
  JOIN pg_roles r ON r.oid = p.proowner
), needles AS (
  SELECT
    'count(distinctinvoice.id)filter(whereinvoice.sage_status=''draft'')::integerasdraft_count'
      AS old_draft_needle,
    'count(distinctinvoice.id)filter(whereinvoice.sage_status=''posted'')::integerasposted_count'
      AS old_posted_needle,
    'release_line.source_shipment_batch_id=preview.shipment_batch_id'
      AS exact_batch_needle,
    'release_line.release_status=''active'''
      AS active_membership_needle
), definition_checks AS (
  SELECT
    q.*,
    n.*,
    (
      length(q.compact_definition)
      - length(replace(q.compact_definition, n.old_draft_needle, ''))
    ) / NULLIF(length(n.old_draft_needle), 0) AS old_draft_count_occurrences,
    (
      length(q.compact_definition)
      - length(replace(q.compact_definition, n.old_posted_needle, ''))
    ) / NULLIF(length(n.old_posted_needle), 0) AS old_posted_count_occurrences,
    (
      length(q.compact_definition)
      - length(replace(q.compact_definition, n.exact_batch_needle, ''))
    ) / NULLIF(length(n.exact_batch_needle), 0) AS exact_batch_predicate_occurrences,
    (
      length(q.compact_definition)
      - length(replace(q.compact_definition, n.active_membership_needle, ''))
    ) / NULLIF(length(n.active_membership_needle), 0) AS active_membership_predicate_occurrences,
    strpos(
      q.compact_definition,
      'internal_customer_sales_release_exact_clean_proof_v1'
    ) > 0 AS exact_clean_batch_admission_present,
    strpos(
      q.compact_definition,
      'internal_shipping_customer_invoice_readiness_preview_v1'
    ) > 0 AS readiness_preview_call_present,
    strpos(q.compact_definition, 'ready_to_create_draft') > 0
      AS ready_status_present,
    strpos(q.compact_definition, 'draft_exists') > 0
      AS draft_status_present,
    strpos(q.compact_definition, 'posted_exists') > 0
      AS posted_status_present,
    strpos(q.compact_definition, 'review_existing_draft') > 0
      AS draft_action_present,
    strpos(q.compact_definition, 'review_posted_invoice') > 0
      AS posted_action_present,
    strpos(q.compact_definition, 'resolve_blockers') > 0
      AS blocker_action_present
  FROM queue_definition q
  CROSS JOIN needles n
), target_batches AS (
  SELECT id, booking_ref
  FROM public.shipper_shipment_batches
  WHERE booking_ref IN ('J040826', 'J040826v1')
), target_parent AS (
  SELECT DISTINCT
    CASE
      WHEN o.order_type = 'replacement_child'
       AND o.parent_order_id IS NOT NULL
        THEN o.parent_order_id
      ELSE o.id
    END AS commercial_parent_order_id
  FROM target_batches b
  CROSS JOIN LATERAL
    public.shipper_shipment_batch_effective_lines_v1(b.id) e
  JOIN public.orders o ON o.id = e.order_id
), target_draft AS (
  SELECT si.*
  FROM public.sales_invoices si
  JOIN target_parent p ON p.commercial_parent_order_id = si.order_id
  WHERE si.id = 'a3c939e4-0abb-4047-b828-cdc137130fd4'::uuid
), target_memberships AS (
  SELECT
    line.id AS release_line_id,
    line.sales_invoice_id,
    line.source_shipment_batch_id,
    batch.booking_ref,
    line.tracking_line_allocation_id,
    line.released_qty,
    line.goods_amount_gbp,
    line.shipping_amount_gbp,
    line.customer_charge_amount_gbp,
    line.release_status,
    line.membership_fingerprint
  FROM public.customer_sales_release_lines line
  JOIN target_draft draft ON draft.id = line.sales_invoice_id
  LEFT JOIN public.shipper_shipment_batches batch
    ON batch.id = line.source_shipment_batch_id
), target_payload_batches AS (
  SELECT DISTINCT payload_batch.value::uuid AS source_shipment_batch_id
  FROM target_draft draft
  CROSS JOIN LATERAL jsonb_array_elements_text(
    COALESCE(
      draft.line_items_json #> '{draft_control,shipment_batch_ids}',
      '[]'::jsonb
    )
  ) payload_batch
), protected_fingerprints AS (
  SELECT jsonb_build_object(
    'resolver', CASE
      WHEN o.resolver_oid IS NULL THEN NULL
      ELSE md5(pg_get_functiondef(o.resolver_oid))
    END,
    'draft_creator', CASE
      WHEN o.creator_oid IS NULL THEN NULL
      ELSE md5(pg_get_functiondef(o.creator_oid))
    END,
    'readiness_preview', CASE
      WHEN o.readiness_oid IS NULL THEN NULL
      ELSE md5(pg_get_functiondef(o.readiness_oid))
    END,
    'remaining_preview', CASE
      WHEN o.remaining_oid IS NULL THEN NULL
      ELSE md5(pg_get_functiondef(o.remaining_oid))
    END,
    'release_guard', CASE
      WHEN o.release_guard_oid IS NULL THEN NULL
      ELSE md5(pg_get_functiondef(o.release_guard_oid))
    END,
    'financial_guard', CASE
      WHEN o.financial_guard_oid IS NULL THEN NULL
      ELSE md5(pg_get_functiondef(o.financial_guard_oid))
    END,
    'effective_shipment_lines', CASE
      WHEN o.effective_lines_oid IS NULL THEN NULL
      ELSE md5(pg_get_functiondef(o.effective_lines_oid))
    END,
    'exact_clean_helper', CASE
      WHEN o.exact_clean_helper_oid IS NULL THEN NULL
      ELSE md5(pg_get_functiondef(o.exact_clean_helper_oid))
    END
  ) AS fingerprints
  FROM objects o
)
SELECT jsonb_build_object(
  'preflight', 'exact_shipment_batch_draft_status_db_preflight_v1',
  'status', CASE
    WHEN o.queue_oid IS NULL
      OR o.release_lines_table IS NULL
      OR o.sales_invoices_table IS NULL
      OR dc.old_draft_count_occurrences <> 1
      OR dc.old_posted_count_occurrences <> 1
      OR dc.exact_batch_predicate_occurrences <> 0
      OR NOT dc.exact_clean_batch_admission_present
      OR NOT dc.readiness_preview_call_present
      OR NOT dc.ready_status_present
      OR NOT dc.draft_status_present
      OR NOT dc.posted_status_present
      OR NOT dc.draft_action_present
      OR NOT dc.posted_action_present
      OR NOT dc.blocker_action_present
      OR NOT qc.security_definer
      OR qc.language_name <> 'plpgsql'
      OR NOT qc.public_execute_revoked
      OR NOT qc.authenticated_execute_granted
    THEN 'failed'
    ELSE 'passed'
  END,
  'objects', jsonb_build_object(
    'queue_exists', o.queue_oid IS NOT NULL,
    'release_ledger_exists', o.release_lines_table IS NOT NULL,
    'sales_invoices_exists', o.sales_invoices_table IS NOT NULL,
    'exact_clean_helper_exists', o.exact_clean_helper_oid IS NOT NULL
  ),
  'queue', jsonb_build_object(
    'current_md5', md5(dc.definition),
    'schema_name', qc.schema_name,
    'function_name', qc.function_name,
    'identity_arguments', qc.identity_arguments,
    'arguments', qc.arguments,
    'function_result', qc.function_result,
    'language_name', qc.language_name,
    'security_definer', qc.security_definer,
    'function_config', qc.function_config,
    'owner_name', qc.owner_name,
    'acl_text', qc.acl_text,
    'public_execute_revoked', qc.public_execute_revoked,
    'authenticated_execute_granted', qc.authenticated_execute_granted,
    'old_draft_count_occurrences', dc.old_draft_count_occurrences,
    'old_posted_count_occurrences', dc.old_posted_count_occurrences,
    'exact_batch_predicate_occurrences',
      dc.exact_batch_predicate_occurrences,
    'active_membership_predicate_occurrences',
      dc.active_membership_predicate_occurrences,
    'exact_clean_batch_admission_present',
      dc.exact_clean_batch_admission_present,
    'readiness_preview_call_present', dc.readiness_preview_call_present,
    'status_vocabulary_present',
      dc.ready_status_present
      AND dc.draft_status_present
      AND dc.posted_status_present,
    'queue_actions_present',
      dc.draft_action_present
      AND dc.posted_action_present
      AND dc.blocker_action_present
  ),
  'protected_fingerprints', pf.fingerprints,
  'target_draft', (
    SELECT jsonb_build_object(
      'found', draft.id IS NOT NULL,
      'sales_invoice_id', draft.id,
      'order_id', draft.order_id,
      'invoice_type', draft.invoice_type,
      'amount_gbp', draft.amount_gbp,
      'sage_status', draft.sage_status,
      'created_at', draft.created_at,
      'payload_shipment_batches', COALESCE((
        SELECT jsonb_agg(
          jsonb_build_object(
            'shipment_batch_id', payload.source_shipment_batch_id,
            'booking_ref', batch.booking_ref
          )
          ORDER BY batch.booking_ref
        )
        FROM target_payload_batches payload
        LEFT JOIN public.shipper_shipment_batches batch
          ON batch.id = payload.source_shipment_batch_id
      ), '[]'::jsonb)
    )
    FROM target_draft draft
  ),
  'target_memberships', jsonb_build_object(
    'active_count', (
      SELECT count(*)
      FROM target_memberships
      WHERE release_status = 'active'
    ),
    'active_bookings', COALESCE((
      SELECT jsonb_agg(DISTINCT booking_ref ORDER BY booking_ref)
      FROM target_memberships
      WHERE release_status = 'active'
    ), '[]'::jsonb),
    'rows', COALESCE((
      SELECT jsonb_agg(to_jsonb(membership) ORDER BY booking_ref, release_line_id)
      FROM target_memberships membership
    ), '[]'::jsonb),
    'j040826_included', EXISTS (
      SELECT 1
      FROM target_memberships
      WHERE release_status = 'active'
        AND booking_ref = 'J040826'
    ),
    'j040826v1_included', EXISTS (
      SELECT 1
      FROM target_memberships
      WHERE release_status = 'active'
        AND booking_ref = 'J040826v1'
    )
  ),
  'note',
    'Use queue.current_md5 and the returned queue contract as the exact governed starting baseline for the follow-up migration. No migration should be written from the historical pre-install fingerprint.'
) AS result
FROM objects o
JOIN definition_checks dc ON true
JOIN queue_contract qc ON true
CROSS JOIN protected_fingerprints pf;
