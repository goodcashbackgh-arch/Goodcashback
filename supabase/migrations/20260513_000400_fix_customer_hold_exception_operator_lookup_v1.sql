BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.customer_pre_shipment_hold_requests') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.customer_pre_shipment_hold_requests';
  END IF;
  IF to_regclass('public.disputes') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.disputes';
  END IF;
  IF to_regclass('public.dispute_lines') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.dispute_lines';
  END IF;
  IF to_regclass('public.supplier_invoice_lines') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoice_lines';
  END IF;
  IF to_regclass('public.supplier_invoices') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoices';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.customer_hold_create_refund_exception_for_line_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order_id uuid;
  v_sop_version text;
  v_operator_id uuid;
  v_dispute_id uuid;
  v_existing_dispute_id uuid;
  v_line_qty numeric;
  v_line_amount numeric;
  v_inserted boolean := false;
BEGIN
  IF NEW.requested_scope <> 'line'
     OR NEW.supplier_invoice_line_id IS NULL
     OR NEW.status <> 'supervisor_approved'
  THEN
    RETURN NEW;
  END IF;

  IF NEW.converted_dispute_id IS NOT NULL THEN
    RETURN NEW;
  END IF;

  SELECT
    si.order_id,
    o.sop_version,
    sil.qty::numeric,
    sil.amount_inc_vat_gbp::numeric
  INTO
    v_order_id,
    v_sop_version,
    v_line_qty,
    v_line_amount
  FROM public.supplier_invoice_lines sil
  JOIN public.supplier_invoices si ON si.id = sil.supplier_invoice_id
  JOIN public.orders o ON o.id = si.order_id
  WHERE sil.id = NEW.supplier_invoice_line_id
    AND si.order_id = NEW.order_id
    AND COALESCE(si.review_status, '') NOT IN ('rejected_resubmit_required','duplicate_blocked','superseded')
    AND COALESCE(lower(btrim(sil.eligible_for_invoice_yn::text)), 'n') NOT IN ('y','yes','true','1')
  LIMIT 1;

  IF v_order_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT dl.dispute_id
  INTO v_existing_dispute_id
  FROM public.dispute_lines dl
  JOIN public.disputes d ON d.id = dl.dispute_id
  WHERE dl.supplier_invoice_line_id = NEW.supplier_invoice_line_id
    AND dl.resolved_at IS NULL
    AND d.resolved_at IS NULL
  ORDER BY d.raised_at DESC NULLS LAST
  LIMIT 1;

  IF v_existing_dispute_id IS NOT NULL THEN
    NEW.converted_dispute_id := v_existing_dispute_id;
    RETURN NEW;
  END IF;

  SELECT oi.operator_id
  INTO v_operator_id
  FROM public.orders o
  JOIN public.operator_importers oi ON oi.importer_id = o.importer_id
  JOIN public.operators op ON op.id = oi.operator_id
  WHERE o.id = NEW.order_id
    AND oi.revoked_at IS NULL
    AND COALESCE(op.active, true) = true
  ORDER BY op.created_at DESC NULLS LAST, oi.id DESC
  LIMIT 1;

  SELECT d.id
  INTO v_dispute_id
  FROM public.disputes d
  WHERE d.order_id = NEW.order_id
    AND d.desired_outcome = 'refund'
    AND d.status = 'raised'
    AND d.resolved_at IS NULL
  ORDER BY d.raised_at DESC NULLS LAST
  LIMIT 1;

  IF v_dispute_id IS NULL THEN
    INSERT INTO public.disputes (
      order_id,
      raised_by_operator_id,
      issue_type,
      desired_outcome,
      liable_party,
      stage_detected,
      amount_impact_gbp,
      status,
      sop_version
    ) VALUES (
      NEW.order_id,
      v_operator_id,
      'missing',
      'refund',
      'unknown',
      'at_reconciliation',
      0,
      'raised',
      v_sop_version
    )
    RETURNING id INTO v_dispute_id;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.dispute_lines dl
    WHERE dl.dispute_id = v_dispute_id
      AND dl.supplier_invoice_line_id = NEW.supplier_invoice_line_id
      AND dl.resolved_at IS NULL
  ) THEN
    INSERT INTO public.dispute_lines (
      dispute_id,
      supplier_invoice_line_id,
      qty_impact,
      amount_impact_gbp,
      line_status,
      intended_remedy,
      conversation_status
    ) VALUES (
      v_dispute_id,
      NEW.supplier_invoice_line_id,
      COALESCE(v_line_qty, 0),
      COALESCE(v_line_amount, 0),
      'affected',
      'refund',
      'refund_pending_approval'
    );
    v_inserted := true;
  END IF;

  IF v_inserted THEN
    UPDATE public.disputes d
    SET amount_impact_gbp = COALESCE(d.amount_impact_gbp, 0) + COALESCE(v_line_amount, 0)
    WHERE d.id = v_dispute_id;
  END IF;

  NEW.converted_dispute_id := v_dispute_id;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_customer_hold_create_refund_exception_for_line_v1
  ON public.customer_pre_shipment_hold_requests;

CREATE TRIGGER trg_customer_hold_create_refund_exception_for_line_v1
BEFORE INSERT OR UPDATE OF status, supplier_invoice_line_id, converted_dispute_id
ON public.customer_pre_shipment_hold_requests
FOR EACH ROW
EXECUTE FUNCTION public.customer_hold_create_refund_exception_for_line_v1();

UPDATE public.customer_pre_shipment_hold_requests h
SET status = h.status
WHERE h.requested_scope = 'line'
  AND h.supplier_invoice_line_id IS NOT NULL
  AND h.status = 'supervisor_approved'
  AND h.converted_dispute_id IS NULL;

NOTIFY pgrst, 'reload schema';

COMMIT;
