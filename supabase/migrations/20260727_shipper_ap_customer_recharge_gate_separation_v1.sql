BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Governing contract:
-- docs/governing-pack/backend/SHIPPER_AP_AND_CUSTOMER_SHIPPING_RECHARGE_GATE_SEPARATION_ADDENDUM_v1.md
--
-- Surgical correction only:
-- - preserve every current canonical Sage-ready row unchanged;
-- - add only accepted/current shipper invoice rows omitted solely because customer
--   shipping apportionment is not yet approved;
-- - do not alter customer release, allocation, Mini-build 4, freeze payload,
--   Accounting Command Centre actions, permissions or Sage posting behaviour.

DO $guard$
DECLARE
  v_shape text;
  v_expected_shape text :=
    'TABLE(queue_row_id text, document_lane text, document_type text, source_table text, source_id uuid, order_id uuid, order_ref text, shipment_batch_id uuid, booking_ref text, counterparty_name text, amount_gbp numeric, currency_code text, invoice_type text, sage_status text, sage_invoice_id text, sage_posted_at timestamp with time zone, readiness_status text, blocker text, reference_text text, notes_text text, detail_href text, source_payload jsonb)';
BEGIN
  IF to_regclass('public.shipping_documents') IS NULL
     OR to_regclass('public.shipper_shipment_batches') IS NULL
     OR to_regclass('public.shippers') IS NULL
     OR to_regclass('public.shipping_cost_allocations') IS NULL
     OR to_regclass('public.sage_posting_snapshots') IS NULL
     OR to_regclass('public.sage_posting_batch_rows') IS NULL
     OR to_regclass('public.sage_posting_batches') IS NULL THEN
    RAISE EXCEPTION 'Shipper AP gate-separation prerequisites are missing';
  END IF;

  IF to_regprocedure('public.internal_freeze_shipper_ap_sage_batch_v1(uuid[],text)') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.internal_freeze_shipper_ap_sage_batch_v1(uuid[],text)';
  END IF;

  IF to_regprocedure('public.internal_customer_sales_release_sources_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.internal_customer_sales_release_sources_v1(uuid)';
  END IF;

  IF to_regprocedure('public.internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1()') IS NULL THEN
    IF to_regprocedure('public.internal_ready_for_sage_queue_v2()') IS NULL THEN
      RAISE EXCEPTION 'Prerequisite missing: public.internal_ready_for_sage_queue_v2()';
    END IF;

    SELECT pg_get_function_result('public.internal_ready_for_sage_queue_v2()'::regprocedure)
    INTO v_shape;

    IF regexp_replace(v_shape, '\s+', ' ', 'g') IS DISTINCT FROM v_expected_shape THEN
      RAISE EXCEPTION
        'Canonical Sage queue return shape drifted; refusing unsafe wrapper. Actual: %',
        v_shape;
    END IF;

    ALTER FUNCTION public.internal_ready_for_sage_queue_v2()
      RENAME TO internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1;
  END IF;

  SELECT pg_get_function_result(
    'public.internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1()'::regprocedure
  ) INTO v_shape;

  IF regexp_replace(v_shape, '\s+', ' ', 'g') IS DISTINCT FROM v_expected_shape THEN
    RAISE EXCEPTION
      'Preserved canonical Sage queue return shape drifted; refusing unsafe wrapper. Actual: %',
      v_shape;
  END IF;
END
$guard$;

-- Keep the exact previous implementation private. Application and downstream callers
-- continue to use only the canonical public function recreated below.
REVOKE ALL ON FUNCTION
  public.internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1()
FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.internal_ready_for_sage_queue_v2()
RETURNS TABLE (
  queue_row_id text,
  document_lane text,
  document_type text,
  source_table text,
  source_id uuid,
  order_id uuid,
  order_ref text,
  shipment_batch_id uuid,
  booking_ref text,
  counterparty_name text,
  amount_gbp numeric,
  currency_code text,
  invoice_type text,
  sage_status text,
  sage_invoice_id text,
  sage_posted_at timestamptz,
  readiness_status text,
  blocker text,
  reference_text text,
  notes_text text,
  detail_href text,
  source_payload jsonb
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $func$
  WITH preserved_queue AS (
    SELECT
      q.queue_row_id,
      q.document_lane,
      q.document_type,
      q.source_table,
      q.source_id,
      q.order_id,
      q.order_ref,
      q.shipment_batch_id,
      q.booking_ref,
      q.counterparty_name,
      q.amount_gbp,
      q.currency_code,
      q.invoice_type,
      q.sage_status,
      q.sage_invoice_id,
      q.sage_posted_at,
      q.readiness_status,
      q.blocker,
      q.reference_text,
      q.notes_text,
      q.detail_href,
      q.source_payload
    FROM public.internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1() q
  ), accepted_shipper_documents AS (
    SELECT
      sd.id AS shipping_document_id,
      sd.shipment_batch_id,
      batch.booking_ref::text AS booking_ref,
      shipper.name::text AS shipper_name,
      sd.document_ref::text AS document_ref,
      sd.document_date,
      sd.total_amount::numeric AS total_amount,
      COALESCE(NULLIF(sd.currency_code::text, ''), 'GBP')::text AS currency_code,
      order_refs.order_ref
    FROM public.shipping_documents sd
    JOIN public.shipper_shipment_batches batch
      ON batch.id = sd.shipment_batch_id
     AND batch.shipper_id = sd.shipper_id
    JOIN public.shippers shipper
      ON shipper.id = sd.shipper_id
    LEFT JOIN LATERAL (
      SELECT string_agg(DISTINCT o.order_ref::text, ', ' ORDER BY o.order_ref::text)::text AS order_ref
      FROM public.shipper_shipment_batch_packages package
      JOIN public.order_tracking_submissions tracking
        ON tracking.id = package.tracking_submission_id
      JOIN public.orders o
        ON o.id = tracking.order_id
      WHERE package.shipment_batch_id = sd.shipment_batch_id
        AND package.active = true
    ) order_refs ON true
    WHERE sd.active = true
      AND sd.superseded_at IS NULL
      AND sd.replaced_by_document_id IS NULL
      AND sd.document_kind = 'shipper_invoice'
      AND sd.review_status = 'accepted_current'
      AND COALESCE(sd.total_amount, 0) > 0
      -- This additive lane is deliberately only for documents that do not yet have
      -- approved customer/order apportionment. Existing apportioned rows are returned
      -- unchanged by preserved_queue and always win.
      AND NOT EXISTS (
        SELECT 1
        FROM public.shipping_cost_allocations allocation
        WHERE allocation.shipping_document_id = sd.id
          AND allocation.active = true
          AND allocation.allocation_status = 'approved'
      )
      AND NOT EXISTS (
        SELECT 1
        FROM preserved_queue existing
        WHERE existing.document_lane = 'shipper_ap'
          AND existing.source_table = 'shipping_documents'
          AND existing.source_id = sd.id
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
  ), additive_shipper_ap AS (
    SELECT
      ('shipping_ap_intent:' || source.shipping_document_id::text)::text AS queue_row_id,
      'shipper_ap'::text AS document_lane,
      'shipper_ap_purchase_invoice_intent'::text AS document_type,
      'shipping_documents'::text AS source_table,
      source.shipping_document_id AS source_id,
      NULL::uuid AS order_id,
      source.order_ref,
      source.shipment_batch_id,
      source.booking_ref,
      source.shipper_name AS counterparty_name,
      source.total_amount AS amount_gbp,
      source.currency_code,
      'purchase_invoice'::text AS invoice_type,
      'not_drafted'::text AS sage_status,
      NULL::text AS sage_invoice_id,
      NULL::timestamptz AS sage_posted_at,
      'ready_for_ap_purchase_invoice_draft'::text AS readiness_status,
      NULL::text AS blocker,
      COALESCE(NULLIF(source.document_ref, ''), NULLIF(source.booking_ref, ''), source.shipping_document_id::text)::text AS reference_text,
      ('Booking ' || COALESCE(source.booking_ref, ''))::text AS notes_text,
      ('/internal/shipping-control/readiness/' || source.shipment_batch_id::text)::text AS detail_href,
      jsonb_build_object(
        'document_ref', source.document_ref,
        'document_date', source.document_date,
        'shipping_document_date', source.document_date,
        'booking_ref', source.booking_ref,
        'shipper_name', source.shipper_name,
        'document_total', source.total_amount,
        'currency', source.currency_code,
        'route', 'shipper_ap_purchase_invoice_intent',
        'status', 'source_ready_not_posted_to_sage',
        'customer_recharge_apportionment_status', 'not_approved_not_required_for_shipper_ap'
      ) AS source_payload
    FROM accepted_shipper_documents source
  )
  SELECT
    q.queue_row_id, q.document_lane, q.document_type, q.source_table, q.source_id,
    q.order_id, q.order_ref, q.shipment_batch_id, q.booking_ref, q.counterparty_name,
    q.amount_gbp, q.currency_code, q.invoice_type, q.sage_status, q.sage_invoice_id,
    q.sage_posted_at, q.readiness_status, q.blocker, q.reference_text, q.notes_text,
    q.detail_href, q.source_payload
  FROM preserved_queue q
  UNION ALL
  SELECT
    a.queue_row_id, a.document_lane, a.document_type, a.source_table, a.source_id,
    a.order_id, a.order_ref, a.shipment_batch_id, a.booking_ref, a.counterparty_name,
    a.amount_gbp, a.currency_code, a.invoice_type, a.sage_status, a.sage_invoice_id,
    a.sage_posted_at, a.readiness_status, a.blocker, a.reference_text, a.notes_text,
    a.detail_href, a.source_payload
  FROM additive_shipper_ap a;
$func$;

REVOKE ALL ON FUNCTION public.internal_ready_for_sage_queue_v2() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.internal_ready_for_sage_queue_v2() TO authenticated;
GRANT EXECUTE ON FUNCTION public.internal_ready_for_sage_queue_v2() TO service_role;

COMMENT ON FUNCTION
  public.internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1()
IS
  'Private exact canonical Sage-ready queue immediately before shipper AP/customer recharge gate separation. Not callable by application roles.';

COMMENT ON FUNCTION public.internal_ready_for_sage_queue_v2()
IS
  'Canonical Sage-ready queue. Preserves every preceding row unchanged and additively exposes accepted current shipper invoices for shipper AP before customer shipping apportionment. Customer shipping recharge remains governed by approved allocation and the existing customer-sales release route.';

DO $verify$
DECLARE
  v_preserved_count bigint;
  v_current_preserved_count bigint;
  v_duplicate_count bigint;
  v_invalid_additive_count bigint;
BEGIN
  SELECT COUNT(*) INTO v_preserved_count
  FROM public.internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1();

  SELECT COUNT(*) INTO v_current_preserved_count
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

  IF v_current_preserved_count <> v_preserved_count THEN
    RAISE EXCEPTION
      'Canonical queue preservation failed: expected % exact rows, found %',
      v_preserved_count,
      v_current_preserved_count;
  END IF;

  SELECT COUNT(*) INTO v_duplicate_count
  FROM (
    SELECT document_lane, source_table, source_id
    FROM public.internal_ready_for_sage_queue_v2()
    GROUP BY document_lane, source_table, source_id
    HAVING COUNT(*) > 1
  ) duplicate_row;

  IF v_duplicate_count <> 0 THEN
    RAISE EXCEPTION 'Canonical queue contains duplicate lane/source identities after gate separation';
  END IF;

  SELECT COUNT(*) INTO v_invalid_additive_count
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
      OR EXISTS (
        SELECT 1
        FROM public.shipping_cost_allocations allocation
        WHERE allocation.shipping_document_id = sd.id
          AND allocation.active = true
          AND allocation.allocation_status = 'approved'
      )
    );

  IF v_invalid_additive_count <> 0 THEN
    RAISE EXCEPTION 'Invalid additive shipper AP rows detected: %', v_invalid_additive_count;
  END IF;
END
$verify$;

NOTIFY pgrst, 'reload schema';

COMMIT;
