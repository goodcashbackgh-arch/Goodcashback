BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.customer_pre_shipment_hold_requests') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.customer_pre_shipment_hold_requests';
  END IF;
  IF to_regclass('public.order_tracking_line_allocations') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.order_tracking_line_allocations';
  END IF;
  IF to_regclass('public.supplier_invoice_lines') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoice_lines';
  END IF;
  IF to_regclass('public.supplier_invoices') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoices';
  END IF;
  IF to_regclass('public.disputes') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.disputes';
  END IF;
  IF to_regclass('public.dispute_lines') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.dispute_lines';
  END IF;
END $$;

--------------------------------------------------------------------------------
-- Resolve the precise existing supplier-invoice lines represented by an
-- approved item or package hold. Package scope uses only the existing
-- tracking-line allocation truth; it never infers every line in the order.
--------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.customer_hold_refund_target_lines_v1(
  p_hold_request_id uuid
)
RETURNS TABLE (
  supplier_invoice_line_id uuid,
  qty_impact numeric,
  amount_impact_gbp numeric,
  source_line_qty numeric
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH hold_row AS (
    SELECT h.*
    FROM public.customer_pre_shipment_hold_requests h
    WHERE h.id = p_hold_request_id
      AND h.status = 'supervisor_approved'
      AND h.requested_scope IN ('line', 'tracking')
  ), direct_line AS (
    SELECT
      sil.id AS supplier_invoice_line_id,
      COALESCE(sil.qty_confirmed, sil.qty, 0)::numeric AS qty_impact,
      COALESCE(sil.amount_confirmed, sil.amount_inc_vat_gbp, 0)::numeric AS amount_impact_gbp,
      COALESCE(sil.qty_confirmed, sil.qty, 0)::numeric AS source_line_qty
    FROM hold_row h
    JOIN public.supplier_invoice_lines sil
      ON h.requested_scope = 'line'
     AND sil.id = h.supplier_invoice_line_id
    JOIN public.supplier_invoices si
      ON si.id = sil.supplier_invoice_id
     AND si.order_id = h.order_id
    WHERE COALESCE(si.review_status, '') NOT IN (
      'rejected_resubmit_required',
      'duplicate_blocked',
      'superseded'
    )
  ), package_allocated AS (
    SELECT
      otla.supplier_invoice_line_id,
      SUM(COALESCE(otla.qty_allocated, 0))::numeric AS allocated_qty
    FROM hold_row h
    JOIN public.order_tracking_line_allocations otla
      ON h.requested_scope = 'tracking'
     AND otla.order_id = h.order_id
     AND otla.tracking_submission_id = h.tracking_submission_id
     AND COALESCE(otla.qty_allocated, 0) > 0
    GROUP BY otla.supplier_invoice_line_id
  ), package_line AS (
    SELECT
      sil.id AS supplier_invoice_line_id,
      pa.allocated_qty AS qty_impact,
      CASE
        WHEN COALESCE(sil.qty_confirmed, sil.qty, 0) > 0
          THEN ROUND(
            COALESCE(sil.amount_confirmed, sil.amount_inc_vat_gbp, 0)::numeric
            * pa.allocated_qty
            / COALESCE(sil.qty_confirmed, sil.qty, 0)::numeric,
            2
          )
        ELSE 0::numeric
      END AS amount_impact_gbp,
      COALESCE(sil.qty_confirmed, sil.qty, 0)::numeric AS source_line_qty
    FROM hold_row h
    JOIN package_allocated pa ON true
    JOIN public.supplier_invoice_lines sil
      ON sil.id = pa.supplier_invoice_line_id
    JOIN public.supplier_invoices si
      ON si.id = sil.supplier_invoice_id
     AND si.order_id = h.order_id
    WHERE h.requested_scope = 'tracking'
      AND COALESCE(si.review_status, '') NOT IN (
        'rejected_resubmit_required',
        'duplicate_blocked',
        'superseded'
      )
  )
  SELECT
    dl.supplier_invoice_line_id,
    dl.qty_impact,
    dl.amount_impact_gbp,
    dl.source_line_qty
  FROM direct_line dl

  UNION ALL

  SELECT
    pl.supplier_invoice_line_id,
    pl.qty_impact,
    pl.amount_impact_gbp,
    pl.source_line_qty
  FROM package_line pl;
$$;

REVOKE ALL ON FUNCTION public.customer_hold_refund_target_lines_v1(uuid) FROM PUBLIC;

--------------------------------------------------------------------------------
-- Approved line/package hold -> the same disputes/dispute_lines route already
-- used by importer reconciliation exceptions.
--------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.customer_hold_create_refund_exception_v2()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_target_line_ids uuid[];
  v_target_count integer := 0;
  v_linked_target_count integer := 0;
  v_existing_dispute_count integer := 0;
  v_ineligible_link_count integer := 0;
  v_dispute_id uuid;
  v_operator_id uuid;
  v_sop_version text;
  v_refund_approved_at timestamptz;
BEGIN
  IF NEW.status <> 'supervisor_approved'
     OR NEW.requested_scope NOT IN ('line', 'tracking')
  THEN
    RETURN NEW;
  END IF;

  v_refund_approved_at := COALESCE(NEW.reviewed_at, now());

  IF NEW.converted_dispute_id IS NOT NULL THEN
    UPDATE public.disputes d
    SET refund_approved_by_staff_id = COALESCE(d.refund_approved_by_staff_id, NEW.reviewed_by_staff_id),
        refund_approved_at = COALESCE(d.refund_approved_at, v_refund_approved_at)
    WHERE d.id = NEW.converted_dispute_id
      AND d.desired_outcome = 'refund';
    RETURN NEW;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(NEW.order_id::text));

  SELECT
    array_agg(t.supplier_invoice_line_id ORDER BY t.supplier_invoice_line_id),
    COUNT(*)::integer
  INTO v_target_line_ids, v_target_count
  FROM public.customer_hold_refund_target_lines_v1(NEW.id) t;

  -- A package approved before precise allocation truth remains an active
  -- set-aside. The existing narrowing path can convert it once truth exists.
  IF COALESCE(v_target_count, 0) = 0 THEN
    RETURN NEW;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.customer_hold_refund_target_lines_v1(NEW.id) t
    WHERE t.source_line_qty <= 0
       OR t.qty_impact <= 0
       OR t.qty_impact > t.source_line_qty
  ) THEN
    RAISE EXCEPTION 'Approved hold cannot be converted because its package quantity does not fit the source invoice line.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.customer_hold_refund_target_lines_v1(NEW.id) t
    WHERE ABS(t.qty_impact - ROUND(t.qty_impact)) > 0.000001
  ) THEN
    RAISE EXCEPTION 'Approved hold conversion requires whole-unit affected quantities. Correct or narrow the package allocation first.';
  END IF;

  WITH open_links AS (
    SELECT DISTINCT
      dl.supplier_invoice_line_id,
      d.id AS dispute_id,
      d.desired_outcome,
      d.status
    FROM public.dispute_lines dl
    JOIN public.disputes d
      ON d.id = dl.dispute_id
     AND d.resolved_at IS NULL
    WHERE dl.supplier_invoice_line_id = ANY(v_target_line_ids)
      AND dl.resolved_at IS NULL
  )
  SELECT
    COUNT(DISTINCT ol.supplier_invoice_line_id)::integer,
    COUNT(DISTINCT ol.dispute_id)::integer,
    COUNT(*) FILTER (
      WHERE ol.desired_outcome <> 'refund'
         OR ol.status <> 'raised'
    )::integer
  INTO
    v_linked_target_count,
    v_existing_dispute_count,
    v_ineligible_link_count
  FROM open_links ol;

  IF v_linked_target_count > 0 THEN
    IF v_linked_target_count = v_target_count
       AND v_existing_dispute_count = 1
       AND v_ineligible_link_count = 0
    THEN
      SELECT MIN(d.id)
      INTO v_dispute_id
      FROM public.dispute_lines dl
      JOIN public.disputes d
        ON d.id = dl.dispute_id
       AND d.resolved_at IS NULL
       AND d.desired_outcome = 'refund'
       AND d.status = 'raised'
      WHERE dl.supplier_invoice_line_id = ANY(v_target_line_ids)
        AND dl.resolved_at IS NULL;
    ELSE
      RAISE EXCEPTION 'Approved hold overlaps an existing open exception. Resolve or narrow the existing exception before approving this hold.';
    END IF;
  END IF;

  SELECT o.operator_id, o.sop_version
  INTO v_operator_id, v_sop_version
  FROM public.orders o
  WHERE o.id = NEW.order_id;

  IF v_operator_id IS NULL THEN
    RAISE EXCEPTION 'Order operator could not be resolved for customer hold exception conversion.';
  END IF;

  -- Match the existing reconciliation action: reuse the latest open raised
  -- refund dispute for the order where the target lines are not already rows.
  IF v_dispute_id IS NULL THEN
    SELECT d.id
    INTO v_dispute_id
    FROM public.disputes d
    WHERE d.order_id = NEW.order_id
      AND d.desired_outcome = 'refund'
      AND d.status = 'raised'
      AND d.resolved_at IS NULL
      AND NOT EXISTS (
        SELECT 1
        FROM public.dispute_lines dl
        WHERE dl.dispute_id = d.id
          AND dl.supplier_invoice_line_id = ANY(v_target_line_ids)
      )
    ORDER BY d.raised_at DESC NULLS LAST, d.id DESC
    LIMIT 1;
  END IF;

  IF v_dispute_id IS NULL THEN
    INSERT INTO public.disputes (
      order_id,
      raised_by_operator_id,
      issue_type,
      desired_outcome,
      liable_party,
      stage_detected,
      amount_impact_gbp,
      comments_initial,
      status,
      sop_version,
      refund_approved_by_staff_id,
      refund_approved_at
    ) VALUES (
      NEW.order_id,
      v_operator_id,
      'missing',
      'refund',
      'unknown',
      'at_reconciliation',
      0,
      'Created from approved customer ' || NEW.requested_scope || ' hold ' || NEW.id::text || '.',
      'raised',
      v_sop_version,
      NEW.reviewed_by_staff_id,
      v_refund_approved_at
    )
    RETURNING id INTO v_dispute_id;
  ELSE
    UPDATE public.disputes d
    SET refund_approved_by_staff_id = COALESCE(d.refund_approved_by_staff_id, NEW.reviewed_by_staff_id),
        refund_approved_at = COALESCE(d.refund_approved_at, v_refund_approved_at)
    WHERE d.id = v_dispute_id
      AND d.desired_outcome = 'refund';
  END IF;

  IF v_linked_target_count = 0 THEN
    INSERT INTO public.dispute_lines (
      dispute_id,
      supplier_invoice_line_id,
      qty_impact,
      amount_impact_gbp,
      line_status,
      intended_remedy,
      conversation_status
    )
    SELECT
      v_dispute_id,
      t.supplier_invoice_line_id,
      ROUND(t.qty_impact)::integer,
      ROUND(t.amount_impact_gbp, 2),
      'affected',
      'refund',
      'refund_pending_approval'
    FROM public.customer_hold_refund_target_lines_v1(NEW.id) t;
  END IF;

  UPDATE public.disputes d
  SET amount_impact_gbp = COALESCE((
    SELECT SUM(dl.amount_impact_gbp)
    FROM public.dispute_lines dl
    WHERE dl.dispute_id = d.id
      AND dl.resolved_at IS NULL
  ), 0)
  WHERE d.id = v_dispute_id;

  UPDATE public.customer_pre_shipment_hold_requests h
  SET converted_dispute_id = v_dispute_id,
      updated_at = now()
  WHERE h.id = NEW.id
    AND h.converted_dispute_id IS NULL;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.customer_hold_create_refund_exception_v2() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_customer_hold_create_refund_exception_for_line_v1
  ON public.customer_pre_shipment_hold_requests;

DROP TRIGGER IF EXISTS trg_customer_hold_create_refund_exception_v2
  ON public.customer_pre_shipment_hold_requests;

CREATE TRIGGER trg_customer_hold_create_refund_exception_v2
AFTER INSERT OR UPDATE OF
  status,
  requested_scope,
  supplier_invoice_line_id,
  tracking_submission_id,
  reviewed_by_staff_id,
  reviewed_at
ON public.customer_pre_shipment_hold_requests
FOR EACH ROW
EXECUTE FUNCTION public.customer_hold_create_refund_exception_v2();

--------------------------------------------------------------------------------
-- Backfill only still-active approved item/package holds with precise targets.
-- One ambiguous historical row must not abort the universal workflow patch;
-- it remains unconverted and is reported as a migration notice for review.
--------------------------------------------------------------------------------

DO $$
DECLARE
  v_hold record;
BEGIN
  FOR v_hold IN
    SELECT h.id
    FROM public.customer_pre_shipment_hold_requests h
    WHERE h.status = 'supervisor_approved'
      AND h.requested_scope IN ('line', 'tracking')
      AND h.converted_dispute_id IS NULL
      AND EXISTS (
        SELECT 1
        FROM public.customer_hold_refund_target_lines_v1(h.id)
      )
    ORDER BY h.created_at, h.id
  LOOP
    BEGIN
      UPDATE public.customer_pre_shipment_hold_requests h
      SET status = h.status,
          updated_at = now()
      WHERE h.id = v_hold.id;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'Approved customer hold % was not backfilled: %', v_hold.id, SQLERRM;
    END;
  END LOOP;
END $$;

NOTIFY pgrst, 'reload schema';

COMMIT;
