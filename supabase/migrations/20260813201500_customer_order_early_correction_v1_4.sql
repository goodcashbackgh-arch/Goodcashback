BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $preflight$
DECLARE
  v_definition text;
  v_normalized text;
  v_security_definer boolean;
  v_config text[];
BEGIN
  IF to_regprocedure('public.customer_correct_unprocessed_order_v1(uuid,integer,numeric,text[])') IS NULL THEN
    RAISE EXCEPTION 'Function missing: public.customer_correct_unprocessed_order_v1(uuid,integer,numeric,text[])';
  END IF;

  IF to_regclass('public.order_funding_position_vw') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.order_funding_position_vw';
  END IF;

  SELECT
    pg_get_functiondef(p.oid),
    p.prosecdef,
    p.proconfig
  INTO
    v_definition,
    v_security_definer,
    v_config
  FROM pg_proc p
  WHERE p.oid = 'public.customer_correct_unprocessed_order_v1(uuid,integer,numeric,text[])'::regprocedure;

  v_normalized := lower(regexp_replace(v_definition, '\s+', ' ', 'g'));

  IF position('replacement screenshot row count postcondition failed.' IN v_normalized) = 0
     OR position('replacement screenshot display order postcondition failed.' IN v_normalized) = 0
     OR position('storage.objects' IN v_normalized) = 0
     OR position('> 3670016' IN v_normalized) = 0
     OR position('from public.order_funding_events x where x.order_id = p_order_id' IN v_normalized) = 0 THEN
    RAISE EXCEPTION 'Existing correction RPC is not the expected v1.3 authority; stop before applying v1.4.';
  END IF;

  IF NOT COALESCE(v_security_definer, false)
     OR NOT COALESCE(v_config, ARRAY[]::text[]) @> ARRAY['search_path=public, pg_temp']::text[] THEN
    RAISE EXCEPTION 'Existing correction RPC security boundary changed; stop before applying v1.4.';
  END IF;
END
$preflight$;

CREATE OR REPLACE FUNCTION public.customer_correct_unprocessed_order_v1(
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
  v_funding record;
  v_funding_after record;
  v_new_amount numeric(12,2);
  v_new_quote_total_ghs numeric;
  v_proposed_funding_gap numeric(12,2);
  v_amount_changed boolean := false;
  v_qty_changed boolean := false;
  v_original_screenshot_count integer := 0;
  v_original_screenshot_ids uuid[];
  v_replacement_count integer := 0;
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

  IF p_replacement_screenshot_urls IS NOT NULL THEN
    v_replacement_count := cardinality(p_replacement_screenshot_urls);
    IF v_replacement_count < 1 THEN
      RAISE EXCEPTION 'Replacement screenshot set must contain at least one image.';
    END IF;
    IF EXISTS (
      SELECT 1 FROM unnest(p_replacement_screenshot_urls) AS replacement_url
      WHERE replacement_url IS NULL OR length(btrim(replacement_url)) = 0
    ) THEN
      RAISE EXCEPTION 'Replacement screenshot URLs must not be blank.';
    END IF;
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

  IF p_replacement_screenshot_urls IS NOT NULL THEN
    IF EXISTS (
      WITH requested AS (
        SELECT replacement.ordinality, parsed.object_name
        FROM unnest(p_replacement_screenshot_urls) WITH ORDINALITY AS replacement(url, ordinality)
        CROSS JOIN LATERAL (
          SELECT CASE
            WHEN position('/storage/v1/object/public/order-screenshots/' IN replacement.url) > 0
              THEN split_part(replacement.url, '/storage/v1/object/public/order-screenshots/', 2)
            ELSE replacement.url
          END AS object_name
        ) parsed
      )
      SELECT 1
      FROM requested r
      LEFT JOIN storage.objects so
        ON so.bucket_id = 'order-screenshots'
       AND so.name = r.object_name
      WHERE r.object_name NOT LIKE v_operator.importer_id::text || '/' || p_order_id::text || '/correction-%'
         OR so.id IS NULL
         OR so.metadata IS NULL
         OR COALESCE(so.metadata->>'mimetype', '') NOT LIKE 'image/%'
         OR COALESCE(so.metadata->>'size', '') !~ '^[0-9]+$'
    ) THEN
      RAISE EXCEPTION 'Replacement screenshot is not a verified stored image for this order.';
    END IF;

    IF (
      SELECT COALESCE(SUM((so.metadata->>'size')::bigint), 0)
      FROM unnest(p_replacement_screenshot_urls) AS replacement(url)
      CROSS JOIN LATERAL (
        SELECT CASE
          WHEN position('/storage/v1/object/public/order-screenshots/' IN replacement.url) > 0
            THEN split_part(replacement.url, '/storage/v1/object/public/order-screenshots/', 2)
          ELSE replacement.url
        END AS object_name
      ) parsed
      JOIN storage.objects so
        ON so.bucket_id = 'order-screenshots'
       AND so.name = parsed.object_name
    ) > 3670016 THEN
      RAISE EXCEPTION 'Replacement screenshots exceed the 3.5 MB stored-object limit.';
    END IF;
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

  IF EXISTS (
       SELECT 1
       FROM public.order_funding_events x
       WHERE x.order_id = p_order_id
         AND x.event_type IS DISTINCT FROM 'credit_applied'
     )
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

  SELECT
    f.order_id,
    COALESCE(f.applied_credit_gbp, 0)::numeric AS applied_credit_gbp,
    COALESCE(f.confirmed_dva_funding_gbp, 0)::numeric AS confirmed_dva_funding_gbp,
    COALESCE(f.funded_total_gbp, 0)::numeric AS funded_total_gbp,
    COALESCE(f.markup_applied_gbp, 0)::numeric AS markup_applied_gbp,
    COALESCE(f.gap_remaining_gbp, 0)::numeric AS gap_remaining_gbp,
    COALESCE(f.threshold_met_yn, false) AS threshold_met_yn
  INTO v_funding
  FROM public.order_funding_position_vw f
  WHERE f.order_id = p_order_id;

  IF v_funding.order_id IS NULL THEN
    RAISE EXCEPTION 'Order correction blocked: funding position is unavailable.';
  END IF;

  IF v_funding.confirmed_dva_funding_gbp > 0.01
     OR v_funding.funded_total_gbp > v_funding.applied_credit_gbp + 0.01
     OR v_funding.threshold_met_yn
     OR v_funding.gap_remaining_gbp <= 0.01 THEN
    RAISE EXCEPTION 'Order correction blocked: processing has started.';
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
    v_proposed_funding_gap := ROUND(
      GREATEST(
        v_new_amount
          + v_funding.markup_applied_gbp
          - v_funding.funded_total_gbp,
        0
      )::numeric,
      2
    );

    IF v_proposed_funding_gap <= 0.01 THEN
      RAISE EXCEPTION 'Order correction blocked: corrected value would require funding-state recomputation.';
    END IF;

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

    SELECT
      f.order_id,
      COALESCE(f.applied_credit_gbp, 0)::numeric AS applied_credit_gbp,
      COALESCE(f.funded_total_gbp, 0)::numeric AS funded_total_gbp,
      COALESCE(f.gap_remaining_gbp, 0)::numeric AS gap_remaining_gbp,
      COALESCE(f.threshold_met_yn, false) AS threshold_met_yn
    INTO v_funding_after
    FROM public.order_funding_position_vw f
    WHERE f.order_id = p_order_id;

    IF v_funding_after.order_id IS NULL
       OR ROUND(v_funding_after.applied_credit_gbp, 2) IS DISTINCT FROM ROUND(v_funding.applied_credit_gbp, 2)
       OR ROUND(v_funding_after.funded_total_gbp, 2) IS DISTINCT FROM ROUND(v_funding.funded_total_gbp, 2)
       OR v_funding_after.threshold_met_yn
       OR v_funding_after.gap_remaining_gbp <= 0.01
       OR (
         v_amount_changed
         AND ROUND(v_funding_after.gap_remaining_gbp, 2) IS DISTINCT FROM v_proposed_funding_gap
       ) THEN
      RAISE EXCEPTION 'Order correction funding postcondition failed.';
    END IF;
  END IF;

  IF p_replacement_screenshot_urls IS NOT NULL THEN
    PERFORM 1
    FROM public.order_screenshots os
    WHERE os.order_id = p_order_id
      AND os.note = 'Original order screenshot'
    ORDER BY os.display_order, os.id
    FOR UPDATE;

    SELECT array_agg(os.id ORDER BY os.display_order, os.id), COUNT(*)::integer
    INTO v_original_screenshot_ids, v_original_screenshot_count
    FROM public.order_screenshots os
    WHERE os.order_id = p_order_id
      AND os.note = 'Original order screenshot';

    IF v_original_screenshot_count < 1 THEN
      RAISE EXCEPTION 'Replacement screenshots require at least one original screenshot.';
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

    WITH replacements AS (
      SELECT
        v_storage_public_prefix || parsed.object_name AS canonical_url,
        replacement.ordinality::integer AS position
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
    SET screenshot_url = replacements.canonical_url,
        uploaded_by_operator_id = v_operator.operator_id,
        display_order = replacements.position
    FROM replacements
    WHERE replacements.position <= v_original_screenshot_count
      AND os.id = v_original_screenshot_ids[replacements.position];

    WITH replacements AS (
      SELECT
        v_storage_public_prefix || parsed.object_name AS canonical_url,
        replacement.ordinality::integer AS position
      FROM unnest(p_replacement_screenshot_urls) WITH ORDINALITY AS replacement(url, ordinality)
      CROSS JOIN LATERAL (
        SELECT CASE
          WHEN position('/storage/v1/object/public/order-screenshots/' IN replacement.url) > 0
            THEN split_part(replacement.url, '/storage/v1/object/public/order-screenshots/', 2)
          ELSE replacement.url
        END AS object_name
      ) parsed
      WHERE replacement.ordinality > v_original_screenshot_count
    )
    INSERT INTO public.order_screenshots
      (order_id, screenshot_url, uploaded_by_operator_id, display_order, note)
    SELECT p_order_id, canonical_url, v_operator.operator_id, position, 'Original order screenshot'
    FROM replacements
    ORDER BY position;

    DELETE FROM public.order_screenshots os
    WHERE os.id = ANY(v_original_screenshot_ids)
      AND array_position(v_original_screenshot_ids, os.id) > v_replacement_count
      AND os.order_id = p_order_id
      AND os.note = 'Original order screenshot';

    IF (
      SELECT COUNT(*)::integer
      FROM public.order_screenshots os
      WHERE os.order_id = p_order_id
        AND os.note = 'Original order screenshot'
    ) IS DISTINCT FROM v_replacement_count THEN
      RAISE EXCEPTION 'Replacement screenshot row count postcondition failed.';
    END IF;

    IF EXISTS (
      SELECT 1
      FROM (
        SELECT
          os.display_order,
          row_number() OVER (ORDER BY os.display_order, os.id)::integer AS expected_display_order
        FROM public.order_screenshots os
        WHERE os.order_id = p_order_id
          AND os.note = 'Original order screenshot'
      ) final_screenshots
      WHERE final_screenshots.display_order IS DISTINCT FROM final_screenshots.expected_display_order
    ) THEN
      RAISE EXCEPTION 'Replacement screenshot display order postcondition failed.';
    END IF;

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
