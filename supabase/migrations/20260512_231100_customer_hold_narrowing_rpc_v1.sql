BEGIN;

CREATE OR REPLACE FUNCTION public.customer_narrow_pre_shipment_hold_request_v1(
  p_secure_token text,
  p_existing_hold_request_id uuid,
  p_requested_scope text,
  p_tracking_submission_id uuid DEFAULT NULL,
  p_supplier_invoice_line_id uuid DEFAULT NULL,
  p_reason text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_link_id uuid;
  v_order_id uuid;
  v_existing public.customer_pre_shipment_hold_requests%ROWTYPE;
  v_new_hold_id uuid;
  v_reason text;
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

  SELECT * INTO v_existing
  FROM public.customer_pre_shipment_hold_requests h
  WHERE h.id = p_existing_hold_request_id
    AND h.order_id = v_order_id
    AND h.review_link_id = v_link_id
  LIMIT 1;

  IF v_existing.id IS NULL THEN
    RAISE EXCEPTION 'Existing hold request not found for this customer review link.';
  END IF;

  IF v_existing.status NOT IN ('requested','supervisor_approved') THEN
    RAISE EXCEPTION 'Only active holds can be narrowed.';
  END IF;

  IF v_existing.requested_scope = 'line' THEN
    RAISE EXCEPTION 'Line-level hold is already the narrowest scope.';
  END IF;

  IF p_requested_scope NOT IN ('tracking','line') THEN
    RAISE EXCEPTION 'Hold can only be narrowed to tracking or line scope.';
  END IF;

  IF v_existing.requested_scope = 'tracking' AND p_requested_scope <> 'line' THEN
    RAISE EXCEPTION 'Tracking-level hold can only be narrowed to line scope.';
  END IF;

  v_reason := COALESCE(NULLIF(btrim(COALESCE(p_reason, '')), ''), v_existing.reason);

  IF p_requested_scope = 'tracking' THEN
    IF p_tracking_submission_id IS NULL OR p_supplier_invoice_line_id IS NOT NULL THEN
      RAISE EXCEPTION 'Tracking-level narrowing requires tracking id only.';
    END IF;
    IF NOT EXISTS (
      SELECT 1
      FROM public.order_tracking_submissions ots
      WHERE ots.id = p_tracking_submission_id
        AND ots.order_id = v_order_id
        AND ots.superseded_at IS NULL
    ) THEN
      RAISE EXCEPTION 'Tracking/package does not belong to this order.';
    END IF;
  END IF;

  IF p_requested_scope = 'line' THEN
    IF p_supplier_invoice_line_id IS NULL THEN
      RAISE EXCEPTION 'Line-level narrowing requires invoice line id.';
    END IF;
    IF NOT EXISTS (
      SELECT 1
      FROM public.supplier_invoice_lines sil
      JOIN public.supplier_invoices si ON si.id = sil.supplier_invoice_id
      WHERE sil.id = p_supplier_invoice_line_id
        AND si.order_id = v_order_id
        AND COALESCE(si.review_status, '') NOT IN ('rejected_resubmit_required','duplicate_blocked','superseded')
    ) THEN
      RAISE EXCEPTION 'Invoice line does not belong to this order.';
    END IF;
  END IF;

  INSERT INTO public.customer_pre_shipment_hold_requests (
    order_id,
    review_link_id,
    tracking_submission_id,
    supplier_invoice_line_id,
    requested_scope,
    reason,
    customer_contact_label,
    status,
    supervisor_review_note,
    reviewed_by_staff_id,
    reviewed_at,
    narrowed_from_hold_request_id
  ) VALUES (
    v_order_id,
    v_link_id,
    p_tracking_submission_id,
    p_supplier_invoice_line_id,
    p_requested_scope,
    v_reason,
    v_existing.customer_contact_label,
    v_existing.status,
    CASE WHEN v_existing.status = 'supervisor_approved' THEN 'Auto-narrowed from approved ' || v_existing.requested_scope || '-level customer hold.' ELSE NULL END,
    v_existing.reviewed_by_staff_id,
    CASE WHEN v_existing.status = 'supervisor_approved' THEN now() ELSE NULL END,
    v_existing.id
  )
  RETURNING id INTO v_new_hold_id;

  UPDATE public.customer_pre_shipment_hold_requests h
  SET status = 'superseded',
      superseded_by_hold_request_id = v_new_hold_id,
      resolved_at = now(),
      updated_at = now(),
      supervisor_review_note = concat_ws(' ', NULLIF(h.supervisor_review_note, ''), 'Superseded by narrower customer hold.')
  WHERE h.id = v_existing.id;

  RETURN v_new_hold_id;
END;
$$;

REVOKE ALL ON FUNCTION public.customer_narrow_pre_shipment_hold_request_v1(text,uuid,text,uuid,uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.customer_narrow_pre_shipment_hold_request_v1(text,uuid,text,uuid,uuid,text) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
