BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $auth_context$
DECLARE
  v_auth_user_id uuid;
BEGIN
  SELECT staff_row.auth_user_id
  INTO v_auth_user_id
  FROM public.staff staff_row
  WHERE staff_row.active = true
    AND staff_row.auth_user_id IS NOT NULL
  ORDER BY staff_row.created_at, staff_row.id
  LIMIT 1;

  IF v_auth_user_id IS NULL THEN
    RAISE EXCEPTION 'FAIL: no active staff auth context available for regression';
  END IF;

  PERFORM set_config('request.jwt.claim.sub', v_auth_user_id::text, true);
END;
$auth_context$;

DO $proof$
DECLARE
  v_bad integer;
  v_definition text;
  v_compact text;
BEGIN
  SELECT COUNT(*)
  INTO v_bad
  FROM public.internal_customer_invoice_release_queue_v1() queue_row
  WHERE queue_row.readiness_status = 'ready_to_create_draft'
    AND (
      queue_row.ready_line_count <= 0
      OR ROUND(COALESCE(queue_row.proposed_amount_gbp, 0), 2) <= 0
      OR queue_row.queue_action <> 'ready_for_bulk_draft_creation'
    );

  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'FAIL: queue contains non-positive or zero-line actionable rows (%)', v_bad;
  END IF;

  SELECT COUNT(*)
  INTO v_bad
  FROM public.internal_customer_invoice_release_queue_v1() queue_row
  WHERE queue_row.readiness_status = 'ready_to_create_draft'
    AND NOT EXISTS (
      SELECT 1
      FROM public.internal_customer_sales_release_sources_v1(queue_row.shipment_batch_id) source_row
      WHERE source_row.blocker IS NULL
        AND ROUND(COALESCE(source_row.customer_charge_amount_gbp, 0), 2) > 0
    );

  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'FAIL: queue re-admits batches without a genuine positive source delta (%)', v_bad;
  END IF;

  SELECT COUNT(*)
  INTO v_bad
  FROM public.internal_customer_invoice_release_queue_v1() queue_row
  WHERE queue_row.posted_invoice_count > 0
    AND queue_row.created_draft_count = 0
    AND NOT EXISTS (
      SELECT 1
      FROM public.internal_customer_sales_release_sources_v1(queue_row.shipment_batch_id) source_row
      WHERE source_row.blocker IS NULL
        AND ROUND(COALESCE(source_row.customer_charge_amount_gbp, 0), 2) > 0
    )
    AND queue_row.readiness_status IS DISTINCT FROM 'posted_exists';

  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'FAIL: fully released posted batches do not remain posted_exists (%)', v_bad;
  END IF;

  SELECT COUNT(*)
  INTO v_bad
  FROM (
    SELECT DISTINCT shipping_control.shipment_batch_id
    FROM public.internal_shipping_control_v1() shipping_control
    WHERE shipping_control.shipment_batch_id IS NOT NULL
      AND COALESCE(shipping_control.allocation_status_summary, '') = 'contents_allocated'
      AND COALESCE(shipping_control.receipt_status_summary, '') = 'received_clean'
  ) AS batch_row
  CROSS JOIN LATERAL public.internal_shipping_customer_invoice_readiness_preview_v1(
    batch_row.shipment_batch_id
  ) AS preview_row
  WHERE preview_row.blocker IS NOT NULL
    AND (
      ROUND(COALESCE(preview_row.qty_allocated, 0), 3) <> 0
      OR ROUND(COALESCE(preview_row.goods_amount_gbp, 0), 2) <> 0
      OR ROUND(COALESCE(preview_row.shipping_amount_gbp, 0), 2) <> 0
      OR ROUND(COALESCE(preview_row.total_line_amount_gbp, 0), 2) <> 0
    );

  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'FAIL: blocked preview rows still carry actionable historical values (%)', v_bad;
  END IF;

  SELECT pg_get_functiondef(
           'public.internal_customer_invoice_release_create_drafts_v1(uuid[])'::regprocedure
         )
  INTO v_definition;

  v_compact := regexp_replace(lower(v_definition), '[[:space:]]+', '', 'g');

  IF strpos(v_compact, 'internal_customer_sales_release_sources_v1') = 0
     OR strpos(v_compact, 'blockerisnull') = 0
     OR strpos(v_compact, 'v_amount') = 0
     OR strpos(v_compact, '<=0') = 0
     OR strpos(v_compact, 'customer_sales_release_lines') = 0
  THEN
    RAISE EXCEPTION 'FAIL: existing draft creator fail-closed/durable-ledger controls changed';
  END IF;

  SELECT pg_get_functiondef(
           'public.internal_customer_sales_release_sources_v1(uuid)'::regprocedure
         )
  INTO v_definition;

  v_compact := regexp_replace(lower(v_definition), '[[:space:]]+', '', 'g');

  IF strpos(v_compact, 'used_goodsas') = 0
     OR strpos(v_compact, 'used_shippingas') = 0
     OR strpos(v_compact, 'source_fully_released') = 0
     OR strpos(v_compact, 'supplementary') = 0
  THEN
    RAISE EXCEPTION 'FAIL: protected multi-invoice delta resolver changed or regressed';
  END IF;
END;
$proof$;

ROLLBACK;

SELECT 'PASS: only genuine positive customer-release deltas are actionable; fully released posted batches remain posted, draft protection and repeated supplementary routing remain intact' AS regression_result;
