BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Regression contract:
-- docs/governing-pack/backend/SHIPPER_AP_AND_CUSTOMER_SHIPPING_RECHARGE_GATE_SEPARATION_ADDENDUM_v1.md
--
-- This regression is transaction-safe and performs no Sage API call.
-- It proves canonical queue preservation, the unapportioned shipper-AP population,
-- customer recharge protection, Mini-build 4 non-interference and duplicate controls.

DO $prerequisites$
BEGIN
  IF to_regprocedure('public.internal_ready_for_sage_queue_v2()') IS NULL
     OR to_regprocedure('public.internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1()') IS NULL THEN
    RAISE EXCEPTION 'Shipper AP gate-separation migration is not deployed';
  END IF;

  IF to_regprocedure('public.internal_customer_sales_release_sources_v1(uuid)') IS NULL
     OR to_regprocedure('public.internal_freeze_shipper_ap_sage_batch_v1(uuid[],text)') IS NULL THEN
    RAISE EXCEPTION 'Required customer-release or shipper-AP freeze function is missing';
  END IF;

  IF to_regprocedure('public.internal_materialize_customer_review_cycles_v1(uuid,uuid)') IS NULL
     OR to_regprocedure('public.shipper_tracking_review_state_v1(uuid,uuid)') IS NULL
     OR to_regprocedure('public.shipper_shipment_batch_candidates_v1()') IS NULL THEN
    RAISE EXCEPTION 'Mini-build 4 canonical review prerequisites are missing';
  END IF;
END
$prerequisites$;

CREATE TEMP TABLE regression_before_counts ON COMMIT DROP AS
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

DO $queue_preservation$
DECLARE
  v_preserved_count bigint;
  v_exact_preserved_count bigint;
  v_duplicate_count bigint;
BEGIN
  SELECT COUNT(*)
  INTO v_preserved_count
  FROM public.internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1();

  SELECT COUNT(*)
  INTO v_exact_preserved_count
  FROM public.internal_ready_for_sage_queue_v2() current_row
  JOIN public.internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1() preserved_row
    ON preserved_row.queue_row_id IS NOT DISTINCT FROM current_row.queue_row_id
   AND preserved_row.document_lane IS NOT DISTINCT FROM current_row.document_lane
   AND preserved_row.document_type IS NOT DISTINCT FROM current_row.document_type
   AND preserved_row.source_table IS NOT DISTINCT FROM current_row.source_table
   AND preserved_row.source_id IS NOT DISTINCT FROM current_row.source_id
   AND preserved_row.order_id IS NOT DISTINCT FROM current_row.order_id
   AND preserved_row.order_ref IS NOT DISTINCT FROM current_row.order_ref
   AND preserved_row.shipment_batch_id IS NOT DISTINCT FROM current_row.shipment_batch_id
   AND preserved_row.booking_ref IS NOT DISTINCT FROM current_row.booking_ref
   AND preserved_row.counterparty_name IS NOT DISTINCT FROM current_row.counterparty_name
   AND preserved_row.amount_gbp IS NOT DISTINCT FROM current_row.amount_gbp
   AND preserved_row.currency_code IS NOT DISTINCT FROM current_row.currency_code
   AND preserved_row.invoice_type IS NOT DISTINCT FROM current_row.invoice_type
   AND preserved_row.sage_status IS NOT DISTINCT FROM current_row.sage_status
   AND preserved_row.sage_invoice_id IS NOT DISTINCT FROM current_row.sage_invoice_id
   AND preserved_row.sage_posted_at IS NOT DISTINCT FROM current_row.sage_posted_at
   AND preserved_row.readiness_status IS NOT DISTINCT FROM current_row.readiness_status
   AND preserved_row.blocker IS NOT DISTINCT FROM current_row.blocker
   AND preserved_row.reference_text IS NOT DISTINCT FROM current_row.reference_text
   AND preserved_row.notes_text IS NOT DISTINCT FROM current_row.notes_text
   AND preserved_row.detail_href IS NOT DISTINCT FROM current_row.detail_href
   AND preserved_row.source_payload IS NOT DISTINCT FROM current_row.source_payload;

  IF v_exact_preserved_count <> v_preserved_count THEN
    RAISE EXCEPTION
      'FAIL: only % of % preserved canonical rows remain byte-for-byte equivalent',
      v_exact_preserved_count,
      v_preserved_count;
  END IF;

  SELECT COUNT(*)
  INTO v_duplicate_count
  FROM (
    SELECT q.document_lane, q.source_table, q.source_id
    FROM public.internal_ready_for_sage_queue_v2() q
    GROUP BY q.document_lane, q.source_table, q.source_id
    HAVING COUNT(*) > 1
  ) duplicates;

  IF v_duplicate_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: duplicate canonical lane/source identities found: %', v_duplicate_count;
  END IF;
END
$queue_preservation$;

DO $working_apportioned_flow$
DECLARE
  v_proof_id uuid := 'ea5d4deb-ae18-48b3-b6e7-97f64434f266'::uuid;
  v_old jsonb;
  v_new jsonb;
  v_row_count integer;
BEGIN
  IF EXISTS (SELECT 1 FROM public.shipping_documents WHERE id = v_proof_id) THEN
    SELECT to_jsonb(q)
    INTO v_old
    FROM public.internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1() q
    WHERE q.document_lane = 'shipper_ap'
      AND q.source_table = 'shipping_documents'
      AND q.source_id = v_proof_id;

    SELECT COUNT(*), MAX(to_jsonb(q))
    INTO v_row_count, v_new
    FROM public.internal_ready_for_sage_queue_v2() q
    WHERE q.document_lane = 'shipper_ap'
      AND q.source_table = 'shipping_documents'
      AND q.source_id = v_proof_id;

    IF v_old IS NULL THEN
      RAISE EXCEPTION 'FAIL: known approved-apportionment proof row is absent from preserved queue';
    END IF;

    IF v_row_count <> 1 OR v_new IS DISTINCT FROM v_old THEN
      RAISE EXCEPTION 'FAIL: known approved-apportionment shipper AP row changed or duplicated';
    END IF;

    IF (v_new->>'amount_gbp')::numeric IS DISTINCT FROM 20.49::numeric THEN
      RAISE EXCEPTION 'FAIL: known shipper AP amount changed from £20.49';
    END IF;
  END IF;
END
$working_apportioned_flow$;

DO $unapportioned_population$
DECLARE
  v_missing_count bigint;
  v_invalid_count bigint;
  v_duplicate_count bigint;
BEGIN
  -- Every accepted/current positive shipper invoice without approved apportionment,
  -- and without an existing queue/snapshot/batch lock, must now appear once.
  SELECT COUNT(*)
  INTO v_missing_count
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
      FROM public.internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1() q
      WHERE q.document_lane = 'shipper_ap'
        AND q.source_table = 'shipping_documents'
        AND q.source_id = sd.id
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
        AND q.source_payload #>> '{customer_recharge_apportionment_status}' = 'not_approved_not_required_for_shipper_ap'
    ) <> 1;

  IF v_missing_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: qualifying unapportioned shipper AP documents missing or incorrect: %', v_missing_count;
  END IF;

  SELECT COUNT(*)
  INTO v_invalid_count
  FROM public.internal_ready_for_sage_queue_v2() q
  JOIN public.shipping_documents sd ON sd.id = q.source_id
  WHERE q.document_lane = 'shipper_ap'
    AND q.source_table = 'shipping_documents'
    AND q.source_payload #>> '{customer_recharge_apportionment_status}' = 'not_approved_not_required_for_shipper_ap'
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

  IF v_invalid_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: invalid additive shipper AP rows found: %', v_invalid_count;
  END IF;

  SELECT COUNT(*)
  INTO v_duplicate_count
  FROM (
    SELECT q.source_id
    FROM public.internal_ready_for_sage_queue_v2() q
    WHERE q.document_lane = 'shipper_ap'
      AND q.source_table = 'shipping_documents'
    GROUP BY q.source_id
    HAVING COUNT(*) > 1
  ) duplicate_shipper_ap;

  IF v_duplicate_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: duplicate shipper AP queue rows found: %', v_duplicate_count;
  END IF;
END
$unapportioned_population$;

DO $customer_recharge_protection$
DECLARE
  v_release_definition text;
  v_draft_definition text;
  v_freeze_definition text;
BEGIN
  SELECT pg_get_functiondef('public.internal_customer_sales_release_sources_v1(uuid)'::regprocedure)
  INTO v_release_definition;

  SELECT pg_get_functiondef('public.internal_customer_invoice_release_create_drafts_v1(uuid[])'::regprocedure)
  INTO v_draft_definition;

  SELECT pg_get_functiondef('public.internal_freeze_shipper_ap_sage_batch_v1(uuid[],text)'::regprocedure)
  INTO v_freeze_definition;

  IF position('shipping_cost_allocations' IN COALESCE(v_release_definition, '')) = 0
     OR position('shipping_cost_allocation_lines' IN COALESCE(v_release_definition, '')) = 0
     OR position('approved' IN COALESCE(v_release_definition, '')) = 0 THEN
    RAISE EXCEPTION 'FAIL: customer shipping release no longer demonstrably depends on approved allocation';
  END IF;

  IF position('internal_customer_sales_release_sources_v1' IN COALESCE(v_draft_definition, '')) = 0 THEN
    RAISE EXCEPTION 'FAIL: customer draft route no longer consumes the canonical release-source resolver';
  END IF;

  IF position('shipping_cost_allocation_lines' IN COALESCE(v_freeze_definition, '')) > 0
     OR position('''unit_price_gbp'', lr.amount_gbp' IN COALESCE(v_freeze_definition, '')) = 0 THEN
    RAISE EXCEPTION 'FAIL: shipper AP freeze payload no longer uses the full queue/document amount independently of allocations';
  END IF;
END
$customer_recharge_protection$;

DO $mini4_boundary$
DECLARE
  v_queue_definition text;
BEGIN
  SELECT pg_get_functiondef('public.internal_ready_for_sage_queue_v2()'::regprocedure)
  INTO v_queue_definition;

  IF position('customer_order_review_links' IN v_queue_definition) > 0
     OR position('customer_review_cycle_memberships' IN v_queue_definition) > 0
     OR position('internal_materialize_customer_review_cycles_v1' IN v_queue_definition) > 0
     OR position('shipper_tracking_review_state_v1' IN v_queue_definition) > 0
     OR position('shipper_shipment_batch_candidates_v1' IN v_queue_definition) > 0
     OR position('shipper_create_shipment_batch_v1' IN v_queue_definition) > 0 THEN
    RAISE EXCEPTION 'FAIL: shipper AP queue correction crossed into Mini-build 4 or shipment gating';
  END IF;
END
$mini4_boundary$;

DO $no_mutation$
DECLARE
  before_row regression_before_counts%ROWTYPE;
  after_row regression_before_counts%ROWTYPE;
BEGIN
  SELECT * INTO before_row FROM regression_before_counts;

  SELECT
    (SELECT COUNT(*) FROM public.sales_invoices),
    (SELECT COUNT(*) FROM public.customer_sales_release_lines),
    (SELECT COUNT(*) FROM public.shipping_cost_allocations),
    (SELECT COUNT(*) FROM public.shipping_cost_allocation_lines),
    (SELECT COUNT(*) FROM public.customer_order_review_links),
    (SELECT COUNT(*) FROM public.customer_review_cycle_memberships),
    (SELECT COUNT(*) FROM public.customer_review_cycle_legacy_issues),
    (SELECT COUNT(*) FROM public.shipper_shipment_batches),
    (SELECT COUNT(*) FROM public.sage_posting_snapshots)
  INTO after_row;

  IF after_row IS DISTINCT FROM before_row THEN
    RAISE EXCEPTION 'FAIL: read-only regression unexpectedly changed protected row counts';
  END IF;
END
$no_mutation$;

SELECT jsonb_build_object(
  'regression_result', 'PASS',
  'details',
    'Canonical queue rows are preserved exactly; accepted current unapportioned shipper invoices are exposed once at their full document amount; customer shipping recharge still requires approved allocation; Mini-build 4, shipment, protected financial tables and Sage posting state are unchanged.',
  'qualifying_unapportioned_live_count', (
    SELECT COUNT(*)
    FROM public.internal_ready_for_sage_queue_v2() q
    WHERE q.document_lane = 'shipper_ap'
      AND q.source_table = 'shipping_documents'
      AND q.source_payload #>> '{customer_recharge_apportionment_status}' = 'not_approved_not_required_for_shipper_ap'
  )
) AS regression_result;

ROLLBACK;
