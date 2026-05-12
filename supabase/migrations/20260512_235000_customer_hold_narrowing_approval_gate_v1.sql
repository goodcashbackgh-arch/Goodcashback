BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
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

  IF EXISTS (
    SELECT 1
    FROM public.customer_pre_shipment_hold_requests h
    WHERE h.narrowed_from_hold_request_id = v_existing.id
      AND h.status IN ('requested','supervisor_approved')
  ) THEN
    RAISE EXCEPTION 'A narrowed hold selection already exists for this hold. Ask the supervisor to approve/reject it before changing again.';
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
    'requested',
    'Customer narrowed from approved ' || v_existing.requested_scope || '-level customer hold. Supervisor approval required before shipper set-aside changes.',
    NULL,
    NULL,
    v_existing.id
  FROM (SELECT DISTINCT unnest(COALESCE(p_supplier_invoice_line_ids, ARRAY[]::uuid[])) AS id) selected
  WHERE selected.id IS NOT NULL;

  GET DIAGNOSTICS v_inserted_count = ROW_COUNT;

  UPDATE public.customer_pre_shipment_hold_requests h
  SET supervisor_review_note = concat_ws(' ', NULLIF(h.supervisor_review_note, ''), 'Customer submitted narrower line selection; awaiting supervisor approval before this broad hold is superseded.'),
      updated_at = now()
  WHERE h.id = v_existing.id;

  RETURN v_inserted_count;
END;
$$;

CREATE OR REPLACE FUNCTION public.internal_review_customer_pre_shipment_hold_v1(
  p_hold_request_id uuid,
  p_decision text,
  p_review_note text DEFAULT NULL
)
RETURNS TABLE (
  hold_request_id uuid,
  status text,
  message text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff_id uuid;
  v_new_status text;
  v_hold public.customer_pre_shipment_hold_requests%ROWTYPE;
  v_approved_count int := 0;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: customer hold review requires auth.uid()';
  END IF;

  SELECT s.id INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND COALESCE(s.active, true) = true
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Active staff account required for customer hold review.';
  END IF;

  SELECT * INTO v_hold
  FROM public.customer_pre_shipment_hold_requests h
  WHERE h.id = p_hold_request_id
  LIMIT 1;

  IF v_hold.id IS NULL THEN
    RAISE EXCEPTION 'Customer hold request not found: %', p_hold_request_id;
  END IF;

  v_new_status := CASE p_decision
    WHEN 'approve' THEN 'supervisor_approved'
    WHEN 'reject' THEN 'rejected'
    WHEN 'resolve' THEN 'resolved'
    WHEN 'supersede' THEN 'superseded'
    ELSE NULL
  END;

  IF v_new_status IS NULL THEN
    RAISE EXCEPTION 'Invalid hold review decision: %', p_decision;
  END IF;

  IF p_decision = 'approve' AND v_hold.narrowed_from_hold_request_id IS NOT NULL THEN
    UPDATE public.customer_pre_shipment_hold_requests h
    SET status = 'supervisor_approved',
        supervisor_review_note = COALESCE(NULLIF(btrim(COALESCE(p_review_note, '')), ''), h.supervisor_review_note, 'Narrowed line selection approved by supervisor.'),
        reviewed_by_staff_id = v_staff_id,
        reviewed_at = now(),
        updated_at = now()
    WHERE h.narrowed_from_hold_request_id = v_hold.narrowed_from_hold_request_id
      AND h.order_id = v_hold.order_id
      AND h.status = 'requested';

    GET DIAGNOSTICS v_approved_count = ROW_COUNT;

    UPDATE public.customer_pre_shipment_hold_requests parent
    SET status = 'superseded',
        superseded_by_hold_request_id = p_hold_request_id,
        resolved_at = now(),
        reviewed_by_staff_id = v_staff_id,
        reviewed_at = now(),
        updated_at = now(),
        supervisor_review_note = concat_ws(' ', NULLIF(parent.supervisor_review_note, ''), 'Superseded after supervisor approved narrower line-level customer hold selection.')
    WHERE parent.id = v_hold.narrowed_from_hold_request_id
      AND parent.status IN ('requested','supervisor_approved');

    RETURN QUERY
    SELECT p_hold_request_id, 'supervisor_approved'::text, ('Approved narrowed line selection: ' || v_approved_count::text || ' line hold(s). Parent hold superseded.')::text;
    RETURN;
  END IF;

  UPDATE public.customer_pre_shipment_hold_requests h
  SET status = v_new_status,
      supervisor_review_note = NULLIF(btrim(COALESCE(p_review_note, '')), ''),
      reviewed_by_staff_id = v_staff_id,
      reviewed_at = now(),
      resolved_at = CASE WHEN v_new_status IN ('rejected','resolved','superseded') THEN now() ELSE h.resolved_at END,
      updated_at = now()
  WHERE h.id = p_hold_request_id;

  IF p_decision = 'reject' AND v_hold.narrowed_from_hold_request_id IS NOT NULL THEN
    UPDATE public.customer_pre_shipment_hold_requests parent
    SET supervisor_review_note = concat_ws(' ', NULLIF(parent.supervisor_review_note, ''), 'Narrowed line selection rejected; original broad hold remains active.'),
        updated_at = now()
    WHERE parent.id = v_hold.narrowed_from_hold_request_id
      AND parent.status IN ('requested','supervisor_approved');
  END IF;

  RETURN QUERY
  SELECT p_hold_request_id, v_new_status, ('Customer hold marked ' || v_new_status)::text;
END;
$$;

REVOKE ALL ON FUNCTION public.customer_narrow_pre_shipment_hold_lines_v1(text,uuid,uuid[],text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_review_customer_pre_shipment_hold_v1(uuid,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.customer_narrow_pre_shipment_hold_lines_v1(text,uuid,uuid[],text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.internal_review_customer_pre_shipment_hold_v1(uuid,text,text) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
