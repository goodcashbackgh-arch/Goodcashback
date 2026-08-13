BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
DECLARE
  v_required text;
BEGIN
  FOREACH v_required IN ARRAY ARRAY[
    'public.orders',
    'public.operators',
    'public.operator_importers',
    'public.order_screenshots',
    'public.order_funding_events',
    'public.order_tracking_submissions',
    'public.supplier_invoices',
    'public.dva_reconciliation',
    'public.dva_statement_line_allocations',
    'public.order_evidence_queries',
    'public.order_value_adjustments',
    'public.customer_order_review_links',
    'public.customer_pre_shipment_hold_requests',
    'public.shipper_shipment_batch_packages',
    'public.shipper_package_receipts',
    'public.sales_invoices',
    'public.shipping_quote_orders',
    'storage.objects'
  ] LOOP
    IF to_regclass(v_required) IS NULL THEN
      RAISE EXCEPTION 'Prerequisite missing: %', v_required;
    END IF;
  END LOOP;

  IF to_regprocedure('public.customer_correct_unprocessed_order_v1(uuid,integer,numeric,text[])') IS NOT NULL THEN
    RAISE EXCEPTION 'Function already exists: public.customer_correct_unprocessed_order_v1(uuid,integer,numeric,text[])';
  END IF;
END $$;

CREATE FUNCTION public.customer_correct_unprocessed_order_v1(
  p_order_id uuid,
  p_total_qty_declared integer,
  p_order_total_gbp_declared numeric,
  p_replacement_screenshot_urls text[] DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_operator record;
  v_order record;
  v_new_amount numeric(12,2);
  v_new_quote_total_ghs numeric;
  v_amount_changed boolean := false;
  v_qty_changed boolean := false;
  v_original_screenshot_count integer := 0;
  v_screenshots_replaced boolean := false;
  v_storage_public_prefix text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user.';
  END IF;

  SELECT
    op.id AS operator_id,
    oi.importer_id
  INTO v_operator
  FROM public.operators op
  JOIN public.operator_importers oi
    ON oi.operator_id = op.id
   AND oi.revoked_at IS NULL
  WHERE op.auth_user_id = auth.uid()
    AND op.active = true
  ORDER BY oi.id DESC
  LIMIT 1;

  IF v_operator.operator_id IS NULL OR v_operator.importer_id IS NULL THEN
    RAISE EXCEPTION 'Active customer/operator assignment not found.';
  END IF;

  IF p_order_id IS NULL THEN
    RAISE EXCEPTION 'Order is required.';
  END IF;

  IF p_total_qty_declared IS NULL OR p_total_qty_declared <= 0 THEN
    RAISE EXCEPTION 'Total quantity declared must be a positive integer.';
  END IF;

  IF p_order_total_gbp_declared IS NULL OR p_order_total_gbp_declared <= 0 THEN
    RAISE EXCEPTION 'Order total GBP declared must be greater than 0.';
  END IF;

  v_new_amount := ROUND(p_order_total_gbp_declared::numeric, 2);

  IF p_replacement_screenshot_urls IS NOT NULL AND EXISTS (
    SELECT 1
    FROM unnest(p_replacement_screenshot_urls) AS replacement_url
    WHERE replacement_url IS NULL OR length(btrim(replacement_url)) = 0
  ) THEN
    RAISE EXCEPTION 'Replacement screenshot URLs must not be blank.';
  END IF;

  SELECT
    o.id,
    o.importer_id,
    o.operator_id,
    o.order_type,
    o.status,
    o.total_qty_declared,
    o.order_total_gbp_declared,
    o.quote_total_ghs,
    o.content_locked_at,
    o.tracking_locked_at,
    o.funded_at,
    o.completed_at,
    o.accounting_release_ready_at,
    o.vat_release_approved_at,
    o.vat_return_period
  INTO v_order
  FROM public.orders o
  WHERE o.id = p_order_id
  FOR UPDATE;

  IF v_order.id IS NULL THEN
    RAISE EXCEPTION 'Order not found.';
  END IF;

  IF v_order.importer_id IS DISTINCT FROM v_operator.importer_id
     OR v_order.operator_id IS DISTINCT FROM v_operator.operator_id THEN
    RAISE EXCEPTION 'Order does not belong to the active customer/operator assignment.';
  END IF;

  IF p_replacement_screenshot_urls IS NOT NULL AND EXISTS (
    SELECT 1
    FROM unnest(p_replacement_screenshot_urls) AS replacement_url
    CROSS JOIN LATERAL (
      SELECT CASE
        WHEN position('/storage/v1/object/public/order-screenshots/' IN replacement_url) > 0
          THEN split_part(replacement_url, '/storage/v1/object/public/order-screenshots/', 2)
        ELSE replacement_url
      END AS object_name
    ) parsed
    WHERE parsed.object_name NOT LIKE v_operator.importer_id::text || '/' || p_order_id::text || '/correction-%'
       OR NOT EXISTS (
         SELECT 1
         FROM storage.objects so
         WHERE so.bucket_id = 'order-screenshots'
           AND so.name = parsed.object_name
       )
  ) THEN
    RAISE EXCEPTION 'Replacement screenshot URL is not a verified correction object for this order.';
  END IF;

  IF v_order.order_type IS DISTINCT FROM 'original'
     OR v_order.status IS DISTINCT FROM 'pending_dva_funding'
     OR v_order.content_locked_at IS NOT NULL
     OR v_order.tracking_locked_at IS NOT NULL
     OR v_order.funded_at IS NOT NULL
     OR v_order.completed_at IS NOT NULL
     OR v_order.accounting_release_ready_at IS NOT NULL
     OR v_order.vat_release_approved_at IS NOT NULL
     OR v_order.vat_return_period IS NOT NULL THEN
    RAISE EXCEPTION 'Order correction blocked: processing has started.';
  END IF;

  IF EXISTS (SELECT 1 FROM public.order_funding_events x WHERE x.order_id = p_order_id)
     OR EXISTS (SELECT 1 FROM public.order_tracking_submissions x WHERE x.order_id = p_order_id)
     OR EXISTS (SELECT 1 FROM public.supplier_invoices x WHERE x.order_id = p_order_id)
     OR EXISTS (SELECT 1 FROM public.dva_reconciliation x WHERE x.order_id = p_order_id)
     OR EXISTS (SELECT 1 FROM public.dva_statement_line_allocations x WHERE x.order_id = p_order_id)
     OR EXISTS (SELECT 1 FROM public.order_evidence_queries x WHERE x.order_id = p_order_id)
     OR EXISTS (SELECT 1 FROM public.order_value_adjustments x WHERE x.order_id = p_order_id)
     OR EXISTS (SELECT 1 FROM public.customer_order_review_links x WHERE x.order_id = p_order_id)
     OR EXISTS (SELECT 1 FROM public.customer_pre_shipment_hold_requests x WHERE x.order_id = p_order_id)
     OR EXISTS (SELECT 1 FROM public.shipper_shipment_batch_packages x WHERE x.order_id = p_order_id)
     OR EXISTS (SELECT 1 FROM public.shipper_package_receipts x WHERE x.order_id = p_order_id)
     OR EXISTS (SELECT 1 FROM public.sales_invoices x WHERE x.order_id = p_order_id)
     OR EXISTS (SELECT 1 FROM public.shipping_quote_orders x WHERE x.order_id = p_order_id)
     OR EXISTS (SELECT 1 FROM public.orders child WHERE child.parent_order_id = p_order_id) THEN
    RAISE EXCEPTION 'Order correction blocked: processing has started.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.order_screenshots os
    WHERE os.order_id = p_order_id
      AND os.note IS DISTINCT FROM 'Original order screenshot'
  ) THEN
    RAISE EXCEPTION 'Order correction blocked: downstream evidence already exists.';
  END IF;

  v_qty_changed := v_order.total_qty_declared IS DISTINCT FROM p_total_qty_declared;
  v_amount_changed := ROUND(v_order.order_total_gbp_declared::numeric, 2) IS DISTINCT FROM v_new_amount;

  IF NOT v_qty_changed AND NOT v_amount_changed AND p_replacement_screenshot_urls IS NULL THEN
    RETURN jsonb_build_object(
      'ok', true,
      'order_id', p_order_id,
      'changed', false,
      'screenshots_replaced', false
    );
  END IF;

  IF v_amount_changed THEN
    IF v_order.order_total_gbp_declared IS NULL
       OR v_order.order_total_gbp_declared <= 0
       OR v_order.quote_total_ghs IS NULL
       OR v_order.quote_total_ghs <= 0 THEN
      RAISE EXCEPTION 'Order correction blocked: stored quote baseline is unavailable.';
    END IF;

    v_new_quote_total_ghs := ROUND(
      (
        v_order.quote_total_ghs::numeric
        / v_order.order_total_gbp_declared::numeric
      ) * v_new_amount,
      2
    );
  ELSE
    v_new_quote_total_ghs := v_order.quote_total_ghs;
  END IF;

  IF v_qty_changed OR v_amount_changed THEN
    UPDATE public.orders
    SET
      total_qty_declared = p_total_qty_declared,
      order_total_gbp_declared = v_new_amount,
      quote_total_ghs = v_new_quote_total_ghs,
      updated_at = now()
    WHERE id = p_order_id;
  END IF;

  IF p_replacement_screenshot_urls IS NOT NULL THEN
    PERFORM 1
    FROM public.order_screenshots os
    WHERE os.order_id = p_order_id
      AND os.note = 'Original order screenshot'
    ORDER BY os.display_order, os.id
    FOR UPDATE;

    SELECT COUNT(*)::integer
    INTO v_original_screenshot_count
    FROM public.order_screenshots os
    WHERE os.order_id = p_order_id
      AND os.note = 'Original order screenshot';

    IF v_original_screenshot_count < 1 THEN
      RAISE EXCEPTION 'Replacement screenshots require at least one original screenshot.';
    END IF;

    IF cardinality(p_replacement_screenshot_urls) IS DISTINCT FROM v_original_screenshot_count THEN
      RAISE EXCEPTION 'Replacement screenshot count must match the existing original screenshot count (%).', v_original_screenshot_count;
    END IF;

    SELECT MIN(parsed.public_prefix)
    INTO v_storage_public_prefix
    FROM public.order_screenshots os
    CROSS JOIN LATERAL (
      SELECT CASE
        WHEN position('/storage/v1/object/public/order-screenshots/' IN os.screenshot_url) > 0
          THEN split_part(os.screenshot_url, '/storage/v1/object/public/order-screenshots/', 1)
               || '/storage/v1/object/public/order-screenshots/'
        ELSE NULL
      END AS public_prefix
    ) parsed
    WHERE os.order_id = p_order_id
      AND os.note = 'Original order screenshot'
    HAVING COUNT(*) > 0
       AND COUNT(parsed.public_prefix) = COUNT(*)
       AND COUNT(DISTINCT parsed.public_prefix) = 1;

    IF v_storage_public_prefix IS NULL THEN
      RAISE EXCEPTION 'Replacement screenshot URL baseline is unavailable or inconsistent.';
    END IF;

    WITH current_rows AS (
      SELECT
        os.id,
        row_number() OVER (ORDER BY os.display_order, os.id) AS position
      FROM public.order_screenshots os
      WHERE os.order_id = p_order_id
        AND os.note = 'Original order screenshot'
    ), replacements AS (
      SELECT
        v_storage_public_prefix || parsed.object_name AS canonical_url,
        replacement.ordinality::bigint AS position
      FROM unnest(p_replacement_screenshot_urls) WITH ORDINALITY AS replacement(url, ordinality)
      CROSS JOIN LATERAL (
        SELECT CASE
          WHEN position('/storage/v1/object/public/order-screenshots/' IN replacement.url) > 0
            THEN split_part(replacement.url, '/storage/v1/object/public/order-screenshots/', 2)
          ELSE replacement.url
        END AS object_name
      ) parsed
    )
    UPDATE public.order_screenshots os
    SET
      screenshot_url = replacements.canonical_url,
      uploaded_by_operator_id = v_operator.operator_id
    FROM current_rows
    JOIN replacements USING (position)
    WHERE os.id = current_rows.id;

    v_screenshots_replaced := true;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'order_id', p_order_id,
    'changed', true,
    'old_total_qty_declared', v_order.total_qty_declared,
    'new_total_qty_declared', p_total_qty_declared,
    'old_order_total_gbp_declared', v_order.order_total_gbp_declared,
    'new_order_total_gbp_declared', v_new_amount,
    'old_quote_total_ghs', v_order.quote_total_ghs,
    'new_quote_total_ghs', v_new_quote_total_ghs,
    'screenshots_replaced', v_screenshots_replaced
  );
END;
$$;

REVOKE ALL ON FUNCTION public.customer_correct_unprocessed_order_v1(uuid, integer, numeric, text[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.customer_correct_unprocessed_order_v1(uuid, integer, numeric, text[]) FROM anon;
GRANT EXECUTE ON FUNCTION public.customer_correct_unprocessed_order_v1(uuid, integer, numeric, text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.customer_correct_unprocessed_order_v1(uuid, integer, numeric, text[]) TO service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
