BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Governing contract:
-- docs/governing-pack/backend/SHIPPER_AP_AND_CUSTOMER_SHIPPING_RECHARGE_GATE_SEPARATION_ADDENDUM_v1.md
--
-- Read-only transactional proof. No Sage API call. No permanent mutation.

DO $prerequisites$
BEGIN
  IF to_regprocedure('public.internal_ready_for_sage_queue_v2()') IS NULL
     OR to_regprocedure('public.internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1()') IS NULL THEN
    RAISE EXCEPTION 'Gate-separation migration is not deployed';
  END IF;

  IF to_regprocedure('public.internal_customer_sales_release_sources_v1(uuid)') IS NULL
     OR to_regprocedure('public.internal_customer_invoice_release_create_drafts_v1(uuid[])') IS NULL
     OR to_regprocedure('public.internal_freeze_shipper_ap_sage_batch_v1(uuid[],text)') IS NULL THEN
    RAISE EXCEPTION 'Required customer-sales or shipper-AP functions are missing';
  END IF;

  IF to_regprocedure('public.internal_materialize_customer_review_cycles_v1(uuid,uuid)') IS NULL
     OR to_regprocedure('public.shipper_tracking_review_state_v1(uuid,uuid)') IS NULL
     OR to_regprocedure('public.shipper_shipment_batch_candidates_v1()') IS NULL THEN
    RAISE EXCEPTION 'Mini-build 4 prerequisites are missing';
  END IF;
END
$prerequisites$;

CREATE TEMP TABLE protected_counts_before ON COMMIT DROP AS
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

DO $preserved_queue$
DECLARE
  v_preserved bigint;
  v_exact bigint;
  v_duplicates bigint;
BEGIN
  SELECT COUNT(*) INTO v_preserved
  FROM public.internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1();

  SELECT COUNT(*) INTO v_exact
  FROM public.internal_ready_for_sage_queue_v2() current_row
  JOIN public.internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1() preserved_row
    ON to_jsonb(current_row) = to_jsonb(preserved_row);

  IF v_exact <> v_preserved THEN
    RAISE EXCEPTION
      'FAIL: preserved queue changed. Expected % exact rows, found %',
      v_preserved,
      v_exact;
  END IF;

  SELECT COUNT(*) INTO v_duplicates
  FROM (
    SELECT document_lane, source_table, source_id
    FROM public.internal_ready_for_sage_queue_v2()
    GROUP BY document_lane, source_table, source_id
    HAVING COUNT(*) > 1
  ) duplicate_rows;

  IF v_duplicates <> 0 THEN
    RAISE EXCEPTION 'FAIL: duplicate canonical lane/source rows found: %', v_duplicates;
  END IF;
END
$preserved_queue$;

DO $known_working_apportioned_row$
DECLARE
  v_proof_id uuid := 'ea5d4deb-ae18-48b3-b6e7-97f64434f266'::uuid;
  v_old jsonb;
  v_new jsonb;
  v_count integer;
BEGIN
  IF EXISTS (SELECT 1 FROM public.shipping_documents WHERE id = v_proof_id) THEN
    SELECT to_jsonb(q)
    INTO v_old
    FROM public.internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1() q
    WHERE q.document_lane = 'shipper_ap'
      AND q.source_table = 'shipping_documents'
      AND q.source_id = v_proof_id;

    SELECT COUNT(*)
    INTO v_count
    FROM public.internal_ready_for_sage_queue_v2() q
    WHERE q.document_lane = 'shipper_ap'
      AND q.source_table = 'shipping_documents'
      AND q.source_id = v_proof_id;

    SELECT to_jsonb(q)
    INTO v_new
    FROM public.internal_ready_for_sage_queue_v2() q
    WHERE q.document_lane = 'shipper_ap'
      AND q.source_table = 'shipping_documents'
      AND q.source_id = v_proof_id
    LIMIT 1;

    IF v_old IS NULL THEN
      RAISE EXCEPTION 'FAIL: known approved-apportionment row missing from preserved queue';
    END IF;

    IF v_count <> 1 OR v_new IS DISTINCT FROM v_old THEN
      RAISE EXCEPTION 'FAIL: known approved-apportionment row changed or duplicated';
    END IF;

    IF (v_new->>'amount_gbp')::numeric IS DISTINCT FROM 20.49::numeric THEN
      RAISE EXCEPTION 'FAIL: known shipper AP amount changed from £20.49';
    END IF;
  END IF;
END
$known_working_apportioned_row$;

DO $unapportioned_population$
DECLARE
  v_missing bigint;
  v_invalid bigint;
BEGIN
  SELECT COUNT(*) INTO v_missing
  FROM public.shipping_documents sd
  JOIN public.shipper_shipment_batches shipment_batch
    ON shipment_batch.id = sd.shipment_batch_id
   AND shipment_batch.shipper_id = sd.shipper_id
  WHERE sd.active = true
    AND sd.superseded_at IS NULL
    AND sd.replaced_by_document_id IS NULL
    AND sd.document_kind = 'shipper_invoice'
    AND sd.review_status = 'accepted_current'
    AND COALESCE(sd.total_amount, 0) > 0
    AND NOT EXISTS (
      SELECT 1
      FROM public.shipping_cost_allocations allocation
      WHERE allocation.shipping_document_id = sd.id
        AND allocation.active = true
        AND allocation.allocation_status = 'approved'
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1() old_q
      WHERE old_q.document_lane = 'shipper_ap'
        AND old_q.source_table = 'shipping_documents'
        AND old_q.source_id = sd.id
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.sage_posting_snapshots snapshot
      WHERE snapshot.source_table = 'shipping_documents'
        AND snapshot.source_id = sd.id
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
        AND batch_row.source_id = sd.id
        AND batch_row.document_lane = 'shipper_ap'
        AND batch_row.posting_status NOT IN ('excluded', 'cancelled')
        AND COALESCE(posting_batch.status, '') <> 'cancelled'
        AND COALESCE(posting_batch.batch_status, '') <> 'superseded'
    )
    AND (
      SELECT COUNT(*)
      FROM public.internal_ready_for_sage_queue_v2() q
      WHERE q.document_lane = 'shipper_ap'
        AND q.source_table = 'shipping_documents'
        AND q.source_id = sd.id
        AND q.readiness_status LIKE 'ready%'
        AND q.amount_gbp IS NOT DISTINCT FROM sd.total_amount
        AND q.source_payload #>> '{customer_recharge_apportionment_status}' =
          'not_approved_not_required_for_shipper_ap'
    ) <> 1;

  IF v_missing <> 0 THEN
    RAISE EXCEPTION 'FAIL: qualifying unapportioned shipper invoices missing or incorrect: %', v_missing;
  END IF;

  SELECT COUNT(*) INTO v_invalid
  FROM public.internal_ready_for_sage_queue_v2() q
  JOIN public.shipping_documents sd ON sd.id = q.source_id
  WHERE q.document_lane = 'shipper_ap'
    AND q.source_table = 'shipping_documents'
    AND q.source_payload #>> '{customer_recharge_apportionment_status}' =
      'not_approved_not_required_for_shipper_ap'
    AND (
      sd.active IS DISTINCT FROM true
      OR sd.superseded_at IS NOT NULL
      OR sd.replaced_by_document_id IS NOT NULL
      OR sd.document_kind IS DISTINCT FROM 'shipper_invoice'
      OR sd.review_status IS DISTINCT FROM 'accepted_current'
      OR COALESCE(sd.total_amount, 0) <= 0
      OR q.amount_gbp IS DISTINCT FROM sd.total_amount
      OR q.readiness_status NOT LIKE 'ready%'
      OR EXISTS (
        SELECT 1
        FROM public.shipping_cost_allocations allocation
        WHERE allocation.shipping_document_id = sd.id
          AND allocation.active = true
          AND allocation.allocation_status = 'approved'
      )
    );

  IF v_invalid <> 0 THEN
    RAISE EXCEPTION 'FAIL: invalid additive shipper AP rows found: %', v_invalid;
  END IF;
END
$unapportioned_population$;

DO $customer_and_mini4_boundaries$
DECLARE
  v_release text;
  v_draft text;
  v_freeze text;
  v_queue text;
BEGIN
  SELECT pg_get_functiondef('public.internal_customer_sales_release_sources_v1(uuid)'::regprocedure)
  INTO v_release;

  SELECT pg_get_functiondef('public.internal_customer_invoice_release_create_drafts_v1(uuid[])'::regprocedure)
  INTO v_draft;

  SELECT pg_get_functiondef('public.internal_freeze_shipper_ap_sage_batch_v1(uuid[],text)'::regprocedure)
  INTO v_freeze;

  SELECT pg_get_functiondef('public.internal_ready_for_sage_queue_v2()'::regprocedure)
  INTO v_queue;

  IF position('shipping_cost_allocations' IN COALESCE(v_release, '')) = 0
     OR position('shipping_cost_allocation_lines' IN COALESCE(v_release, '')) = 0
     OR position('approved' IN COALESCE(v_release, '')) = 0 THEN
    RAISE EXCEPTION 'FAIL: customer shipping release no longer requires approved allocation';
  END IF;

  IF position('internal_customer_sales_release_sources_v1' IN COALESCE(v_draft, '')) = 0 THEN
    RAISE EXCEPTION 'FAIL: customer draft route no longer consumes canonical release sources';
  END IF;

  IF position('shipping_cost_allocation_lines' IN COALESCE(v_freeze, '')) > 0
     OR position('''unit_price_gbp'', lr.amount_gbp' IN COALESCE(v_freeze, '')) = 0 THEN
    RAISE EXCEPTION 'FAIL: shipper AP freeze payload no longer uses the full document amount independently';
  END IF;

  IF position('customer_order_review_links' IN v_queue) > 0
     OR position('customer_review_cycle_memberships' IN v_queue) > 0
     OR position('internal_materialize_customer_review_cycles_v1' IN v_queue) > 0
     OR position('shipper_tracking_review_state_v1' IN v_queue) > 0
     OR position('shipper_shipment_batch_candidates_v1' IN v_queue) > 0
     OR position('shipper_create_shipment_batch_v1' IN v_queue) > 0 THEN
    RAISE EXCEPTION 'FAIL: queue patch crossed into Mini-build 4 or shipment gating';
  END IF;
END
$customer_and_mini4_boundaries$;

DO $protected_counts$
DECLARE
  v_before jsonb;
  v_after jsonb;
BEGIN
  SELECT to_jsonb(t) INTO v_before FROM protected_counts_before t;

  SELECT to_jsonb(current_counts)
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
  ) current_counts;

  IF v_after IS DISTINCT FROM v_before THEN
    RAISE EXCEPTION 'FAIL: regression changed protected table counts';
  END IF;
END
$protected_counts$;

SELECT jsonb_build_object(
  'regression_result', 'PASS',
  'details',
    'Existing queue rows remain exact; accepted current unapportioned shipper invoices are exposed once at the full document amount; customer shipping still requires approved apportionment; Mini-build 4 and protected tables remain unchanged.',
  'qualifying_unapportioned_live_count', (
    SELECT COUNT(*)
    FROM public.internal_ready_for_sage_queue_v2() q
    WHERE q.document_lane = 'shipper_ap'
      AND q.source_table = 'shipping_documents'
      AND q.source_payload #>> '{customer_recharge_apportionment_status}' =
        'not_approved_not_required_for_shipper_ap'
  )
) AS regression_result;

ROLLBACK;
