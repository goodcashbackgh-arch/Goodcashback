BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

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
    'tracking', '[]'::jsonb,
    'lines', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', sil.id,
        'description', sil.description,
        'size', sil.size,
        'retailer_sku', sil.retailer_sku,
        'qty', sil.qty,
        'amount_inc_vat_gbp', sil.amount_inc_vat_gbp,
        'tracking_submission_id', rl.tracking_submission_id,
        'eligible_for_invoice_yn', sil.eligible_for_invoice_yn
      ) ORDER BY sil.created_at NULLS LAST)
      FROM public.customer_review_ready_line_ids_v1(o.id) rl
      JOIN public.supplier_invoice_lines sil ON sil.id = rl.supplier_invoice_line_id
    ), '[]'::jsonb),
    'holds', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', h.id,
        'requested_scope', h.requested_scope,
        'tracking_submission_id', h.tracking_submission_id,
        'supplier_invoice_line_id', h.supplier_invoice_line_id,
        'narrowed_from_hold_request_id', h.narrowed_from_hold_request_id,
        'converted_dispute_id', h.converted_dispute_id,
        'status', h.status,
        'reason', h.reason,
        'created_at', h.created_at,
        'supervisor_review_note', h.supervisor_review_note
      ) ORDER BY h.created_at DESC)
      FROM public.customer_pre_shipment_hold_requests h
      WHERE h.order_id = o.id
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
