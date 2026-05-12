BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.customer_order_review_links') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.customer_order_review_links';
  END IF;
  IF to_regclass('public.customer_pre_shipment_hold_requests') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.customer_pre_shipment_hold_requests';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'customer_pre_shipment_hold_requests'
      AND column_name = 'narrowed_from_hold_request_id'
  ) THEN
    RAISE EXCEPTION 'Prerequisite missing: customer_pre_shipment_hold_requests.narrowed_from_hold_request_id';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.customer_pre_shipment_hold_review_v1(p_secure_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_link_id uuid;
  v_order_id uuid;
  v_result jsonb;
BEGIN
  SELECT l.id, l.order_id
    INTO v_link_id, v_order_id
  FROM public.customer_order_review_links l
  WHERE l.secure_token = p_secure_token
    AND l.is_active = true
    AND (l.expires_at IS NULL OR l.expires_at > now())
  LIMIT 1;

  IF v_order_id IS NULL THEN
    RAISE EXCEPTION 'Customer review link is invalid or expired.';
  END IF;

  UPDATE public.customer_order_review_links
  SET last_used_at = now()
  WHERE id = v_link_id;

  SELECT jsonb_build_object(
    'order', jsonb_build_object(
      'id', o.id,
      'order_ref', o.order_ref,
      'retailer_name', r.name,
      'status', o.status,
      'order_type', o.order_type,
      'total_qty_declared', o.total_qty_declared
    ),
    'tracking', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', ots.id,
        'courier_name', c.name,
        'tracking_ref', ots.tracking_ref,
        'tracking_date', ots.tracking_date,
        'is_final_delivery_yn', ots.is_final_delivery_yn
      ) ORDER BY ots.submitted_at DESC NULLS LAST)
      FROM public.order_tracking_submissions ots
      LEFT JOIN public.couriers c ON c.id = ots.courier_id
      WHERE ots.order_id = o.id
        AND ots.superseded_at IS NULL
    ), '[]'::jsonb),
    'lines', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', sil.id,
        'supplier_invoice_id', sil.supplier_invoice_id,
        'invoice_ref', si.invoice_ref,
        'description', sil.description,
        'size', sil.size,
        'retailer_sku', sil.retailer_sku,
        'qty', sil.qty,
        'amount_inc_vat_gbp', sil.amount_inc_vat_gbp,
        'eligible_for_invoice_yn', sil.eligible_for_invoice_yn
      ) ORDER BY si.uploaded_at DESC NULLS LAST, sil.created_at NULLS LAST)
      FROM public.supplier_invoice_lines sil
      JOIN public.supplier_invoices si ON si.id = sil.supplier_invoice_id
      WHERE si.order_id = o.id
        AND COALESCE(si.review_status, '') NOT IN ('rejected_resubmit_required','duplicate_blocked','superseded')
    ), '[]'::jsonb),
    'holds', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', h.id,
        'requested_scope', h.requested_scope,
        'tracking_submission_id', h.tracking_submission_id,
        'supplier_invoice_line_id', h.supplier_invoice_line_id,
        'narrowed_from_hold_request_id', h.narrowed_from_hold_request_id,
        'status', h.status,
        'reason', h.reason,
        'created_at', h.created_at,
        'supervisor_review_note', h.supervisor_review_note
      ) ORDER BY h.created_at DESC)
      FROM public.customer_pre_shipment_hold_requests h
      WHERE h.order_id = o.id
        AND h.review_link_id = v_link_id
    ), '[]'::jsonb)
  ) INTO v_result
  FROM public.orders o
  LEFT JOIN public.retailers r ON r.id = o.retailer_id
  WHERE o.id = v_order_id;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.customer_pre_shipment_hold_review_v1(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.customer_pre_shipment_hold_review_v1(text) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
