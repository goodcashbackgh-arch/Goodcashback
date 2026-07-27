BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Surgical correction of the deployed Mini 4 materialiser.
-- The source fingerprint is candidate-scoped; membership identity must also
-- include the immutable review-link/cycle id so a later valid cycle does not
-- collide silently with an earlier cycle.
DO $patch$
DECLARE
  v_proc regprocedure :=
    'public.internal_materialize_customer_review_cycles_v1(uuid,uuid)'::regprocedure;
  v_definition text;
  v_patched text;
  v_raw_count integer;
BEGIN
  SELECT pg_get_functiondef(v_proc)
    INTO v_definition;

  SELECT count(*)::integer
    INTO v_raw_count
  FROM regexp_matches(
    v_definition,
    E'(^|\\n)[[:space:]]*candidate\\.source_fingerprint,',
    'g'
  );

  IF v_raw_count = 0 THEN
    IF position(
      'md5(v_link_id::text || ''|'' || candidate.source_fingerprint)'
      IN v_definition
    ) > 0 THEN
      -- Already repaired: keep the migration idempotent.
      RETURN;
    END IF;

    RAISE EXCEPTION
      'Mini 4 materialiser does not contain the proven raw-fingerprint defect; no replacement applied.';
  END IF;

  IF v_raw_count <> 2 THEN
    RAISE EXCEPTION
      'Expected exactly two raw candidate fingerprint writes, found %; no replacement applied.',
      v_raw_count;
  END IF;

  v_patched := regexp_replace(
    v_definition,
    E'(^|\\n)([[:space:]]*)candidate\\.source_fingerprint,',
    E'\\1\\2md5(v_link_id::text || ''|'' || candidate.source_fingerprint),',
    'g'
  );

  IF v_patched = v_definition
     OR position(
       'md5(v_link_id::text || ''|'' || candidate.source_fingerprint)'
       IN v_patched
     ) = 0 THEN
    RAISE EXCEPTION 'Mini 4 materialiser patch did not produce the required cycle-scoped fingerprint.';
  END IF;

  EXECUTE v_patched;
END
$patch$;

REVOKE ALL ON FUNCTION
  public.internal_materialize_customer_review_cycles_v1(uuid, uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION
  public.internal_materialize_customer_review_cycles_v1(uuid, uuid)
TO service_role;

-- Re-run the same idempotent materialiser whenever facts that can make an
-- already-received package reviewable are created or changed after receipt.
CREATE OR REPLACE FUNCTION public.customer_review_candidate_change_materialize_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order_id uuid;
BEGIN
  IF TG_TABLE_NAME = 'order_tracking_line_allocations' THEN
    v_order_id := COALESCE(NEW.order_id, OLD.order_id);

  ELSIF TG_TABLE_NAME = 'supplier_invoice_lines' THEN
    FOR v_order_id IN
      SELECT DISTINCT allocation.order_id
      FROM public.order_tracking_line_allocations allocation
      WHERE allocation.supplier_invoice_line_id = COALESCE(NEW.id, OLD.id)
    LOOP
      PERFORM public.internal_materialize_customer_review_cycles_v1(v_order_id, NULL);
    END LOOP;
    RETURN COALESCE(NEW, OLD);

  ELSIF TG_TABLE_NAME = 'supplier_invoices' THEN
    v_order_id := COALESCE(NEW.order_id, OLD.order_id);
  END IF;

  IF v_order_id IS NOT NULL THEN
    PERFORM public.internal_materialize_customer_review_cycles_v1(v_order_id, NULL);
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

REVOKE ALL ON FUNCTION public.customer_review_candidate_change_materialize_v1()
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.customer_review_candidate_change_materialize_v1()
TO service_role;

DROP TRIGGER IF EXISTS trg_customer_review_allocation_materialize_v1
  ON public.order_tracking_line_allocations;
CREATE TRIGGER trg_customer_review_allocation_materialize_v1
AFTER INSERT OR UPDATE OF
  order_id,
  tracking_submission_id,
  supplier_invoice_line_id,
  qty_allocated,
  base_value_gbp,
  retailer_delivery_share_gbp,
  discount_share_gbp
ON public.order_tracking_line_allocations
FOR EACH ROW
WHEN (
  NEW.supplier_invoice_line_id IS NOT NULL
  AND COALESCE(NEW.qty_allocated, 0) > 0
)
EXECUTE FUNCTION public.customer_review_candidate_change_materialize_v1();

DROP TRIGGER IF EXISTS trg_customer_review_supplier_line_materialize_v1
  ON public.supplier_invoice_lines;
CREATE TRIGGER trg_customer_review_supplier_line_materialize_v1
AFTER UPDATE OF eligible_for_invoice_yn
ON public.supplier_invoice_lines
FOR EACH ROW
WHEN (
  NEW.eligible_for_invoice_yn IS DISTINCT FROM OLD.eligible_for_invoice_yn
)
EXECUTE FUNCTION public.customer_review_candidate_change_materialize_v1();

DROP TRIGGER IF EXISTS trg_customer_review_supplier_invoice_materialize_v1
  ON public.supplier_invoices;
CREATE TRIGGER trg_customer_review_supplier_invoice_materialize_v1
AFTER UPDATE OF review_status
ON public.supplier_invoices
FOR EACH ROW
WHEN (
  NEW.review_status IS DISTINCT FROM OLD.review_status
)
EXECUTE FUNCTION public.customer_review_candidate_change_materialize_v1();

-- Recover every currently-open platform order that has valid review candidates.
-- Expired receipts are deliberately excluded; no historical cycle is rebuilt.
DO $recover$
DECLARE
  v_order_id uuid;
BEGIN
  FOR v_order_id IN
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
  LOOP
    PERFORM public.internal_materialize_customer_review_cycles_v1(v_order_id, NULL);
  END LOOP;
END
$recover$;

-- Platform invariants: no open valid-candidate order may remain without a timed
-- cycle, and every open timed cycle must have active immutable membership.
DO $verify$
DECLARE
  v_missing_cycle_count integer;
  v_empty_cycle_count integer;
BEGIN
  SELECT count(*)::integer
    INTO v_missing_cycle_count
  FROM (
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
      AND NOT EXISTS (
        SELECT 1
        FROM public.customer_order_review_links link_row
        WHERE link_row.order_id = tracking_row.order_id
          AND link_row.is_active = true
          AND link_row.expires_at IS NOT NULL
          AND link_row.expires_at > now()
      )
  ) missing_cycle;

  SELECT count(*)::integer
    INTO v_empty_cycle_count
  FROM public.customer_order_review_links link_row
  WHERE link_row.is_active = true
    AND link_row.expires_at IS NOT NULL
    AND link_row.expires_at > now()
    AND NOT EXISTS (
      SELECT 1
      FROM public.customer_review_cycle_memberships membership
      WHERE membership.review_link_id = link_row.id
        AND membership.membership_status = 'active'
    );

  IF v_missing_cycle_count <> 0 OR v_empty_cycle_count <> 0 THEN
    RAISE EXCEPTION
      'Mini 4 platform verification failed: missing cycles %, empty open cycles %.',
      v_missing_cycle_count,
      v_empty_cycle_count;
  END IF;
END
$verify$;

COMMIT;
