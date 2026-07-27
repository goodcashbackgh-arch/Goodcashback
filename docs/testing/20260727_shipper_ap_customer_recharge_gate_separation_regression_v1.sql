BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Governing contract:
-- docs/governing-pack/backend/SHIPPER_AP_AND_CUSTOMER_SHIPPING_RECHARGE_GATE_SEPARATION_ADDENDUM_v1.md
--
-- Rollback-safe regression. No Sage API call and no permanent mutation.

DO $prerequisites$
DECLARE
  v_auth_uid uuid;
BEGIN
  IF to_regprocedure('public.internal_ready_for_sage_queue_v2()') IS NULL
     OR to_regprocedure(
          'public.internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1()'
        ) IS NULL THEN
    RAISE EXCEPTION 'FAIL: gate-separation migration is not deployed';
  END IF;

  IF to_regprocedure('public.internal_customer_sales_release_sources_v1(uuid)') IS NULL
     OR to_regprocedure('public.internal_customer_invoice_release_create_drafts_v1(uuid[])') IS NULL
     OR to_regprocedure('public.internal_freeze_shipper_ap_sage_batch_v1(uuid[],text)') IS NULL
     OR to_regprocedure('public.internal_revalidate_sage_posting_snapshots_v1(uuid[])') IS NULL THEN
    RAISE EXCEPTION 'FAIL: required customer-sales or shipper-AP functions are missing';
  END IF;

  IF to_regprocedure('public.internal_materialize_customer_review_cycles_v1(uuid,uuid)') IS NULL
     OR to_regprocedure('public.shipper_tracking_review_state_v1(uuid,uuid)') IS NULL
     OR to_regprocedure('public.shipper_shipment_batch_candidates_v1()') IS NULL THEN
    RAISE EXCEPTION 'FAIL: Mini-build 4 prerequisites are missing';
  END IF;

  SELECT staff_row.auth_user_id
  INTO v_auth_uid
  FROM public.staff staff_row
  WHERE staff_row.active = true
    AND staff_row.auth_user_id IS NOT NULL
  ORDER BY
    CASE
      WHEN staff_row.role_type = 'admin' THEN 0
      WHEN staff_row.role_type = 'supervisor' THEN 1
      ELSE 2
    END,
    staff_row.id
  LIMIT 1;

  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'FAIL: no active staff auth identity available for queue regression';
  END IF;

  PERFORM set_config('request.jwt.claim.sub', v_auth_uid::text, true);
  PERFORM set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_auth_uid::text, 'role', 'authenticated')::text,
    true
  );
END
$prerequisites$;

CREATE TEMP TABLE protected_counts_before
ON COMMIT DROP
AS
SELECT
  (SELECT COUNT(*) FROM public.sales_invoices) AS sales_invoice_count,
  (SELECT COUNT(*) FROM public.customer_sales_release_lines) AS release_line_count,
  (SELECT COUNT(*) FROM public.shipping_cost_allocations) AS allocation_count,
  (SELECT COUNT(*) FROM public.shipping_cost_allocation_lines) AS allocation_line_count,
  (SELECT COUNT(*) FROM public.customer_order_review_links) AS review_link_count,
  (SELECT COUNT(*) FROM public.customer_review_cycle_memberships) AS review_membership_count,
  (SELECT COUNT(*) FROM public.customer_review_cycle_legacy_issues) AS review_issue_count,
  (SELECT COUNT(*) FROM public.shipper_shipment_batches) AS shipment_batch_count,
  (SELECT COUNT(*) FROM public.sage_posting_snapshots) AS snapshot_count;

DO $structure_and_scope$
DECLARE
  v_shape text;
  v_definition text;
  v_private_application_grants bigint;
BEGIN
  SELECT pg_get_function_result('public.internal_ready_for_sage_queue_v2()'::regprocedure)
  INTO v_shape;

  IF v_shape IS DISTINCT FROM pg_get_function_result(
       'public.internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1()'::regprocedure
     ) THEN
    RAISE EXCEPTION 'FAIL: canonical and preserved queue return shapes differ';
  END IF;

  SELECT lower(
    pg_get_functiondef('public.internal_ready_for_sage_queue_v2()'::regprocedure)
  )
  INTO v_definition;

  IF position(
       'internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1'
       IN v_definition
     ) = 0
     OR position('review_status = ''accepted_current''' IN v_definition) = 0
     OR position('document_kind = ''shipper_invoice''' IN v_definition) = 0
     OR position('shipping_cost_allocations' IN v_definition) = 0
     OR position('allocation_status = ''approved''' IN v_definition) = 0
     OR position('shipping_document.extracted_total_amount' IN v_definition) = 0
     OR position('shipping_document.total_amount' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: governed shipper-AP queue composition is incomplete';
  END IF;

  IF position('customer_recharge_apportionment_status' IN v_definition) > 0
     OR position('''shipping_document_date''' IN v_definition) > 0
     OR position('customer_order_review_links' IN v_definition) > 0
     OR position('customer_review_cycle_memberships' IN v_definition) > 0
     OR position('internal_materialize_customer_review_cycles_v1' IN v_definition) > 0
     OR position('shipper_tracking_review_state_v1' IN v_definition) > 0
     OR position('shipper_shipment_batch_candidates_v1' IN v_definition) > 0
     OR position('shipper_create_shipment_batch_v1' IN v_definition) > 0 THEN
    RAISE EXCEPTION 'FAIL: queue correction exceeded the governed boundary';
  END IF;

  SELECT COUNT(*)
  INTO v_private_application_grants
  FROM pg_proc procedure_row
  JOIN pg_namespace namespace_row
    ON namespace_row.oid = procedure_row.pronamespace
  CROSS JOIN LATERAL aclexplode(
    COALESCE(procedure_row.proacl, acldefault('f', procedure_row.proowner))
  ) privilege_row
  LEFT JOIN pg_roles grantee_role
    ON grantee_role.oid = privilege_row.grantee
  WHERE namespace_row.nspname = 'public'
    AND procedure_row.proname =
      'internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1'
    AND procedure_row.pronargs = 0
    AND privilege_row.privilege_type = 'EXECUTE'
    AND (
      privilege_row.grantee = 0
      OR grantee_role.rolname IN ('anon', 'authenticated', 'service_role')
    );

  IF v_private_application_grants <> 0 THEN
    RAISE EXCEPTION 'FAIL: private preserved queue is callable by an application role';
  END IF;
END
$structure_and_scope$;

DO $preserved_queue$
DECLARE
  v_missing bigint;
  v_duplicates bigint;
BEGIN
  SELECT COUNT(*)
  INTO v_missing
  FROM (
    SELECT *
    FROM public.internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1()

    EXCEPT ALL

    SELECT *
    FROM public.internal_ready_for_sage_queue_v2()
  ) missing_rows;

  IF v_missing <> 0 THEN
    RAISE EXCEPTION 'FAIL: canonical queue lost % preserved row(s)', v_missing;
  END IF;

  SELECT COUNT(*)
  INTO v_duplicates
  FROM (
    SELECT document_lane, source_table, source_id
    FROM public.internal_ready_for_sage_queue_v2()
    GROUP BY document_lane, source_table, source_id
    HAVING COUNT(*) > 1
  ) duplicate_rows;

  IF v_duplicates <> 0 THEN
    RAISE EXCEPTION 'FAIL: duplicate canonical lane/source identities found: %', v_duplicates;
  END IF;
END
$preserved_queue$;

DO $working_apportioned_flow$
DECLARE
  v_source_id uuid;
  v_before jsonb;
  v_after jsonb;
  v_count integer;
BEGIN
  SELECT preserved.source_id
  INTO v_source_id
  FROM public.internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1() preserved
  WHERE preserved.document_lane = 'shipper_ap'
    AND preserved.source_table = 'shipping_documents'
    AND EXISTS (
      SELECT 1
      FROM public.shipping_cost_allocations allocation
      WHERE allocation.shipping_document_id = preserved.source_id
        AND allocation.active = true
        AND allocation.allocation_status = 'approved'
    )
  ORDER BY preserved.source_id
  LIMIT 1;

  IF v_source_id IS NOT NULL THEN
    SELECT to_jsonb(preserved)
    INTO v_before
    FROM public.internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1() preserved
    WHERE preserved.document_lane = 'shipper_ap'
      AND preserved.source_table = 'shipping_documents'
      AND preserved.source_id = v_source_id;

    SELECT COUNT(*), MAX(to_jsonb(current_row))
    INTO v_count, v_after
    FROM public.internal_ready_for_sage_queue_v2() current_row
    WHERE current_row.document_lane = 'shipper_ap'
      AND current_row.source_table = 'shipping_documents'
      AND current_row.source_id = v_source_id;

    IF v_count <> 1 OR v_after IS DISTINCT FROM v_before THEN
      RAISE EXCEPTION 'FAIL: existing approved-apportionment shipper-AP row changed or duplicated';
    END IF;
  END IF;
END
$working_apportioned_flow$;

DO $unapportioned_population$
DECLARE
  v_missing bigint;
  v_invalid bigint;
  v_unexpected_payload bigint;
BEGIN
  SELECT COUNT(*)
  INTO v_missing
  FROM public.shipping_documents shipping_document
  JOIN public.shipper_shipment_batches shipment_batch
    ON shipment_batch.id = shipping_document.shipment_batch_id
   AND shipment_batch.shipper_id = shipping_document.shipper_id
  WHERE shipping_document.active = true
    AND shipping_document.superseded_at IS NULL
    AND shipping_document.replaced_by_document_id IS NULL
    AND shipping_document.document_kind = 'shipper_invoice'
    AND shipping_document.review_status = 'accepted_current'
    AND COALESCE(
      shipping_document.extracted_total_amount,
      shipping_document.total_amount,
      0
    ) > 0
    AND NOT EXISTS (
      SELECT 1
      FROM public.shipping_cost_allocations allocation
      WHERE allocation.shipping_document_id = shipping_document.id
        AND allocation.active = true
        AND allocation.allocation_status = 'approved'
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1() old_row
      WHERE old_row.document_lane = 'shipper_ap'
        AND old_row.source_table = 'shipping_documents'
        AND old_row.source_id = shipping_document.id
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.sage_posting_snapshots snapshot
      WHERE snapshot.source_table = 'shipping_documents'
        AND snapshot.source_id = shipping_document.id
        AND snapshot.document_lane = 'shipper_ap'
        AND snapshot.active = true
        AND snapshot.approval_status = 'approved_frozen'
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.sage_posting_batch_rows batch_row
      JOIN public.sage_posting_batches posting_batch
        ON posting_batch.id = batch_row.batch_id
      WHERE batch_row.source_table = 'shipping_documents'
        AND batch_row.source_id = shipping_document.id
        AND batch_row.document_lane = 'shipper_ap'
        AND batch_row.posting_status NOT IN ('excluded', 'cancelled')
        AND COALESCE(posting_batch.status, '') <> 'cancelled'
        AND COALESCE(posting_batch.batch_status, '') <> 'superseded'
    )
    AND (
      SELECT COUNT(*)
      FROM public.internal_ready_for_sage_queue_v2() queue_row
      WHERE queue_row.document_lane = 'shipper_ap'
        AND queue_row.source_table = 'shipping_documents'
        AND queue_row.source_id = shipping_document.id
        AND queue_row.readiness_status = 'ready_for_ap_purchase_invoice_draft'
        AND queue_row.blocker IS NULL
        AND queue_row.amount_gbp IS NOT DISTINCT FROM COALESCE(
          shipping_document.extracted_total_amount,
          shipping_document.total_amount
        )
        AND queue_row.currency_code IS NOT DISTINCT FROM COALESCE(
          NULLIF(shipping_document.extracted_currency_code::text, ''),
          NULLIF(shipping_document.currency_code::text, ''),
          'GBP'
        )
    ) <> 1;

  IF v_missing <> 0 THEN
    RAISE EXCEPTION 'FAIL: qualifying unapportioned shipper invoices missing or incorrect: %', v_missing;
  END IF;

  SELECT COUNT(*)
  INTO v_invalid
  FROM public.internal_ready_for_sage_queue_v2() queue_row
  JOIN public.shipping_documents shipping_document
    ON shipping_document.id = queue_row.source_id
  WHERE queue_row.document_lane = 'shipper_ap'
    AND queue_row.source_table = 'shipping_documents'
    AND NOT EXISTS (
      SELECT 1
      FROM public.internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1() old_row
      WHERE old_row.document_lane = queue_row.document_lane
        AND old_row.source_table = queue_row.source_table
        AND old_row.source_id = queue_row.source_id
    )
    AND (
      shipping_document.active IS DISTINCT FROM true
      OR shipping_document.superseded_at IS NOT NULL
      OR shipping_document.replaced_by_document_id IS NOT NULL
      OR shipping_document.document_kind IS DISTINCT FROM 'shipper_invoice'
      OR shipping_document.review_status IS DISTINCT FROM 'accepted_current'
      OR COALESCE(
        shipping_document.extracted_total_amount,
        shipping_document.total_amount,
        0
      ) <= 0
      OR queue_row.amount_gbp IS DISTINCT FROM COALESCE(
        shipping_document.extracted_total_amount,
        shipping_document.total_amount
      )
      OR queue_row.readiness_status IS DISTINCT FROM 'ready_for_ap_purchase_invoice_draft'
      OR queue_row.blocker IS NOT NULL
      OR EXISTS (
        SELECT 1
        FROM public.shipping_cost_allocations allocation
        WHERE allocation.shipping_document_id = shipping_document.id
          AND allocation.active = true
          AND allocation.allocation_status = 'approved'
      )
    );

  IF v_invalid <> 0 THEN
    RAISE EXCEPTION 'FAIL: invalid additive shipper-AP rows found: %', v_invalid;
  END IF;

  SELECT COUNT(*)
  INTO v_unexpected_payload
  FROM public.internal_ready_for_sage_queue_v2() queue_row
  WHERE queue_row.document_lane = 'shipper_ap'
    AND queue_row.source_table = 'shipping_documents'
    AND NOT EXISTS (
      SELECT 1
      FROM public.internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1() old_row
      WHERE old_row.document_lane = queue_row.document_lane
        AND old_row.source_table = queue_row.source_table
        AND old_row.source_id = queue_row.source_id
    )
    AND (
      queue_row.source_payload ? 'customer_recharge_apportionment_status'
      OR queue_row.source_payload ? 'shipping_document_date'
      OR queue_row.source_payload - ARRAY[
        'document_ref',
        'document_date',
        'booking_ref',
        'shipper_name',
        'document_total',
        'currency',
        'route',
        'status'
      ]::text[] <> '{}'::jsonb
    );

  IF v_unexpected_payload <> 0 THEN
    RAISE EXCEPTION 'FAIL: additive shipper-AP source payload changed the established shape';
  END IF;
END
$unapportioned_population$;

DO $customer_and_mini4_boundaries$
DECLARE
  v_release_definition text;
  v_draft_definition text;
  v_freeze_definition text;
BEGIN
  SELECT lower(
    pg_get_functiondef('public.internal_customer_sales_release_sources_v1(uuid)'::regprocedure)
  )
  INTO v_release_definition;

  SELECT lower(
    pg_get_functiondef('public.internal_customer_invoice_release_create_drafts_v1(uuid[])'::regprocedure)
  )
  INTO v_draft_definition;

  SELECT lower(
    pg_get_functiondef('public.internal_freeze_shipper_ap_sage_batch_v1(uuid[],text)'::regprocedure)
  )
  INTO v_freeze_definition;

  IF position('shipping_cost_allocations' IN v_release_definition) = 0
     OR position('shipping_cost_allocation_lines' IN v_release_definition) = 0
     OR position('approved' IN v_release_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: customer shipping release no longer requires approved apportionment';
  END IF;

  IF position('internal_customer_sales_release_sources_v1' IN v_draft_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: customer draft route no longer consumes canonical release sources';
  END IF;

  IF position('shipping_cost_allocation_lines' IN v_freeze_definition) > 0
     OR position('''unit_price_gbp'', lr.amount_gbp' IN v_freeze_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: shipper-AP freeze no longer uses the full queue/document amount independently';
  END IF;
END
$customer_and_mini4_boundaries$;

DO $protected_counts$
DECLARE
  v_before jsonb;
  v_after jsonb;
BEGIN
  SELECT to_jsonb(before_row)
  INTO v_before
  FROM protected_counts_before before_row;

  SELECT to_jsonb(after_row)
  INTO v_after
  FROM (
    SELECT
      (SELECT COUNT(*) FROM public.sales_invoices) AS sales_invoice_count,
      (SELECT COUNT(*) FROM public.customer_sales_release_lines) AS release_line_count,
      (SELECT COUNT(*) FROM public.shipping_cost_allocations) AS allocation_count,
      (SELECT COUNT(*) FROM public.shipping_cost_allocation_lines) AS allocation_line_count,
      (SELECT COUNT(*) FROM public.customer_order_review_links) AS review_link_count,
      (SELECT COUNT(*) FROM public.customer_review_cycle_memberships) AS review_membership_count,
      (SELECT COUNT(*) FROM public.customer_review_cycle_legacy_issues) AS review_issue_count,
      (SELECT COUNT(*) FROM public.shipper_shipment_batches) AS shipment_batch_count,
      (SELECT COUNT(*) FROM public.sage_posting_snapshots) AS snapshot_count
  ) after_row;

  IF v_after IS DISTINCT FROM v_before THEN
    RAISE EXCEPTION 'FAIL: regression changed protected table counts';
  END IF;
END
$protected_counts$;

SELECT jsonb_build_object(
  'regression_result', 'PASS',
  'details',
    'Canonical queue rows remain exact; qualifying accepted unapportioned shipper invoices are exposed once at the canonical full document amount; established source-payload vocabulary is retained; customer shipping remains behind approved apportionment; Mini-build 4 and protected tables remain unchanged.',
  'qualifying_unapportioned_live_count', (
    SELECT COUNT(*)
    FROM public.internal_ready_for_sage_queue_v2() queue_row
    WHERE queue_row.document_lane = 'shipper_ap'
      AND queue_row.source_table = 'shipping_documents'
      AND NOT EXISTS (
        SELECT 1
        FROM public.internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1() old_row
        WHERE old_row.document_lane = queue_row.document_lane
          AND old_row.source_table = queue_row.source_table
          AND old_row.source_id = queue_row.source_id
      )
  )
) AS regression_result;

ROLLBACK;
