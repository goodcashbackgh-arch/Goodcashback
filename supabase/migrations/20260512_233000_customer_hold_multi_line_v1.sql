BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.customer_pre_shipment_hold_requests') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.customer_pre_shipment_hold_requests';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.customer_narrow_pre_shipment_hold_lines_v1(
  p_secure_token text,
  p_existing_hold_request_id uuid,
  p_supplier_invoice_line_ids uuid[],
  p_reason text DEFAULT NULL
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_link_id uuid;
  v_order_id uuid;
  v_existing public.customer_pre_shipment_hold_requests%ROWTYPE;
  v_reason text;
  v_selected_count int := 0;
  v_inserted_count int := 0;
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

  SELECT count(*)::int
    INTO v_selected_count
  FROM (SELECT DISTINCT unnest(COALESCE(p_supplier_invoice_line_ids, ARRAY[]::uuid[])) AS id) selected
  WHERE selected.id IS NOT NULL;

  IF COALESCE(v_selected_count, 0) = 0 THEN
    RAISE EXCEPTION 'Select at least one invoice line to hold.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM (SELECT DISTINCT unnest(COALESCE(p_supplier_invoice_line_ids, ARRAY[]::uuid[])) AS id) selected
    LEFT JOIN public.supplier_invoice_lines sil ON sil.id = selected.id
    LEFT JOIN public.supplier_invoices si ON si.id = sil.supplier_invoice_id
    WHERE selected.id IS NULL
       OR sil.id IS NULL
       OR si.order_id IS DISTINCT FROM v_order_id
       OR COALESCE(si.review_status, '') IN ('rejected_resubmit_required','duplicate_blocked','superseded')
  ) THEN
    RAISE EXCEPTION 'One or more selected invoice lines do not belong to this active order invoice.';
  END IF;

  v_reason := COALESCE(NULLIF(btrim(COALESCE(p_reason, '')), ''), v_existing.reason);

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
  )
  SELECT
    v_order_id,
    v_link_id,
    v_existing.tracking_submission_id,
    selected.id,
    'line',
    v_reason,
    v_existing.customer_contact_label,
    v_existing.status,
    CASE WHEN v_existing.status = 'supervisor_approved' THEN 'Auto-narrowed from approved ' || v_existing.requested_scope || '-level customer hold.' ELSE NULL END,
    v_existing.reviewed_by_staff_id,
    CASE WHEN v_existing.status = 'supervisor_approved' THEN now() ELSE NULL END,
    v_existing.id
  FROM (SELECT DISTINCT unnest(COALESCE(p_supplier_invoice_line_ids, ARRAY[]::uuid[])) AS id) selected
  WHERE selected.id IS NOT NULL;

  GET DIAGNOSTICS v_inserted_count = ROW_COUNT;

  UPDATE public.customer_pre_shipment_hold_requests h
  SET status = 'superseded',
      superseded_by_hold_request_id = NULL,
      resolved_at = now(),
      updated_at = now(),
      supervisor_review_note = concat_ws(' ', NULLIF(h.supervisor_review_note, ''), 'Superseded by narrower line-level customer hold(s).')
  WHERE h.id = v_existing.id;

  RETURN v_inserted_count;
END;
$$;

CREATE OR REPLACE FUNCTION public.customer_submit_pre_shipment_line_holds_v1(
  p_secure_token text,
  p_supplier_invoice_line_ids uuid[],
  p_reason text,
  p_customer_contact_label text DEFAULT NULL
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_link_id uuid;
  v_order_id uuid;
  v_reason text;
  v_selected_count int := 0;
  v_inserted_count int := 0;
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

  v_reason := NULLIF(btrim(COALESCE(p_reason, '')), '');
  IF v_reason IS NULL THEN
    RAISE EXCEPTION 'Please give a reason for the hold.';
  END IF;

  SELECT count(*)::int
    INTO v_selected_count
  FROM (SELECT DISTINCT unnest(COALESCE(p_supplier_invoice_line_ids, ARRAY[]::uuid[])) AS id) selected
  WHERE selected.id IS NOT NULL;

  IF COALESCE(v_selected_count, 0) = 0 THEN
    RAISE EXCEPTION 'Select at least one invoice line to hold.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM (SELECT DISTINCT unnest(COALESCE(p_supplier_invoice_line_ids, ARRAY[]::uuid[])) AS id) selected
    LEFT JOIN public.supplier_invoice_lines sil ON sil.id = selected.id
    LEFT JOIN public.supplier_invoices si ON si.id = sil.supplier_invoice_id
    WHERE selected.id IS NULL
       OR sil.id IS NULL
       OR si.order_id IS DISTINCT FROM v_order_id
       OR COALESCE(si.review_status, '') IN ('rejected_resubmit_required','duplicate_blocked','superseded')
  ) THEN
    RAISE EXCEPTION 'One or more selected invoice lines do not belong to this active order invoice.';
  END IF;

  INSERT INTO public.customer_pre_shipment_hold_requests (
    order_id,
    review_link_id,
    supplier_invoice_line_id,
    requested_scope,
    reason,
    customer_contact_label,
    status
  )
  SELECT
    v_order_id,
    v_link_id,
    selected.id,
    'line',
    v_reason,
    NULLIF(btrim(COALESCE(p_customer_contact_label, '')), ''),
    'requested'
  FROM (SELECT DISTINCT unnest(COALESCE(p_supplier_invoice_line_ids, ARRAY[]::uuid[])) AS id) selected
  WHERE selected.id IS NOT NULL;

  GET DIAGNOSTICS v_inserted_count = ROW_COUNT;
  RETURN v_inserted_count;
END;
$$;

REVOKE ALL ON FUNCTION public.customer_narrow_pre_shipment_hold_lines_v1(text,uuid,uuid[],text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.customer_submit_pre_shipment_line_holds_v1(text,uuid[],text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.customer_narrow_pre_shipment_hold_lines_v1(text,uuid,uuid[],text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.customer_submit_pre_shipment_line_holds_v1(text,uuid[],text,text) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
