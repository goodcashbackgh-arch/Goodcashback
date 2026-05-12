BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.orders') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.orders';
  END IF;
  IF to_regclass('public.order_tracking_submissions') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.order_tracking_submissions';
  END IF;
  IF to_regclass('public.supplier_invoice_lines') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoice_lines';
  END IF;
  IF to_regclass('public.supplier_invoices') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoices';
  END IF;
  IF to_regclass('public.staff') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.staff';
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.customer_order_review_links (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  secure_token text NOT NULL UNIQUE DEFAULT (
    replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '')
  ),
  is_active boolean NOT NULL DEFAULT true,
  expires_at timestamptz,
  created_by_staff_id uuid REFERENCES public.staff(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  last_used_at timestamptz
);

CREATE INDEX IF NOT EXISTS idx_customer_order_review_links_order
  ON public.customer_order_review_links(order_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_customer_order_review_links_active_token
  ON public.customer_order_review_links(secure_token)
  WHERE is_active = true;

CREATE TABLE IF NOT EXISTS public.customer_pre_shipment_hold_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  review_link_id uuid REFERENCES public.customer_order_review_links(id) ON DELETE SET NULL,
  tracking_submission_id uuid REFERENCES public.order_tracking_submissions(id) ON DELETE SET NULL,
  supplier_invoice_line_id uuid REFERENCES public.supplier_invoice_lines(id) ON DELETE SET NULL,
  requested_scope varchar NOT NULL CHECK (requested_scope IN ('order','tracking','line')),
  reason text NOT NULL,
  customer_contact_label text,
  status varchar NOT NULL DEFAULT 'requested' CHECK (status IN (
    'requested',
    'supervisor_approved',
    'rejected',
    'converted_to_exception',
    'resolved',
    'superseded'
  )),
  supervisor_review_note text,
  reviewed_by_staff_id uuid REFERENCES public.staff(id),
  reviewed_at timestamptz,
  converted_dispute_id uuid REFERENCES public.disputes(id) ON DELETE SET NULL,
  resolved_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT customer_hold_scope_shape CHECK (
    (requested_scope = 'order' AND tracking_submission_id IS NULL AND supplier_invoice_line_id IS NULL)
    OR (requested_scope = 'tracking' AND tracking_submission_id IS NOT NULL AND supplier_invoice_line_id IS NULL)
    OR (requested_scope = 'line' AND supplier_invoice_line_id IS NOT NULL)
  )
);

CREATE INDEX IF NOT EXISTS idx_customer_hold_order_status
  ON public.customer_pre_shipment_hold_requests(order_id, status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_customer_hold_tracking_status
  ON public.customer_pre_shipment_hold_requests(tracking_submission_id, status)
  WHERE tracking_submission_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_customer_hold_line_status
  ON public.customer_pre_shipment_hold_requests(supplier_invoice_line_id, status)
  WHERE supplier_invoice_line_id IS NOT NULL;

ALTER TABLE public.customer_order_review_links ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customer_pre_shipment_hold_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS customer_order_review_links_staff_all ON public.customer_order_review_links;
CREATE POLICY customer_order_review_links_staff_all
ON public.customer_order_review_links
FOR ALL
TO authenticated
USING (public.is_active_staff())
WITH CHECK (public.is_active_staff());

DROP POLICY IF EXISTS customer_pre_shipment_hold_requests_staff_all ON public.customer_pre_shipment_hold_requests;
CREATE POLICY customer_pre_shipment_hold_requests_staff_all
ON public.customer_pre_shipment_hold_requests
FOR ALL
TO authenticated
USING (public.is_active_staff())
WITH CHECK (public.is_active_staff());

DROP POLICY IF EXISTS customer_pre_shipment_hold_requests_operator_select ON public.customer_pre_shipment_hold_requests;
CREATE POLICY customer_pre_shipment_hold_requests_operator_select
ON public.customer_pre_shipment_hold_requests
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.orders o
    JOIN public.operator_importers oi ON oi.importer_id = o.importer_id
    JOIN public.operators op ON op.id = oi.operator_id
    WHERE o.id = customer_pre_shipment_hold_requests.order_id
      AND oi.revoked_at IS NULL
      AND op.auth_user_id = auth.uid()
      AND COALESCE(op.active, true) = true
  )
);

CREATE OR REPLACE FUNCTION public.internal_create_customer_order_review_link_v1(p_order_id uuid)
RETURNS TABLE (
  order_id uuid,
  secure_token text,
  customer_review_path text,
  customer_review_url text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff_id uuid;
  v_token text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: customer order review link requires auth.uid()';
  END IF;

  SELECT s.id INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND COALESCE(s.active, true) = true
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Active staff account required to create customer review link.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.orders o WHERE o.id = p_order_id) THEN
    RAISE EXCEPTION 'Order not found: %', p_order_id;
  END IF;

  SELECT l.secure_token INTO v_token
  FROM public.customer_order_review_links l
  WHERE l.order_id = p_order_id
    AND l.is_active = true
    AND (l.expires_at IS NULL OR l.expires_at > now())
  ORDER BY l.created_at DESC
  LIMIT 1;

  IF v_token IS NULL THEN
    INSERT INTO public.customer_order_review_links (order_id, created_by_staff_id)
    VALUES (p_order_id, v_staff_id)
    RETURNING secure_token INTO v_token;
  END IF;

  RETURN QUERY
  SELECT
    p_order_id,
    v_token,
    ('/customer/orders/' || v_token || '/review')::text,
    ('/customer/orders/' || v_token || '/review')::text;
END;
$$;

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

CREATE OR REPLACE FUNCTION public.customer_submit_pre_shipment_hold_request_v1(
  p_secure_token text,
  p_requested_scope text,
  p_tracking_submission_id uuid DEFAULT NULL,
  p_supplier_invoice_line_id uuid DEFAULT NULL,
  p_reason text DEFAULT NULL,
  p_customer_contact_label text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_link_id uuid;
  v_order_id uuid;
  v_hold_id uuid;
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

  IF p_requested_scope NOT IN ('order','tracking','line') THEN
    RAISE EXCEPTION 'Invalid hold scope: %', p_requested_scope;
  END IF;

  IF NULLIF(btrim(COALESCE(p_reason, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Hold reason is required.';
  END IF;

  IF p_requested_scope = 'order' AND (p_tracking_submission_id IS NOT NULL OR p_supplier_invoice_line_id IS NOT NULL) THEN
    RAISE EXCEPTION 'Order-level hold cannot include tracking or line id.';
  END IF;

  IF p_requested_scope = 'tracking' THEN
    IF p_tracking_submission_id IS NULL OR p_supplier_invoice_line_id IS NOT NULL THEN
      RAISE EXCEPTION 'Tracking-level hold requires tracking id only.';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.order_tracking_submissions ots
      WHERE ots.id = p_tracking_submission_id
        AND ots.order_id = v_order_id
        AND ots.superseded_at IS NULL
    ) THEN
      RAISE EXCEPTION 'Tracking/package does not belong to this order.';
    END IF;
  END IF;

  IF p_requested_scope = 'line' THEN
    IF p_supplier_invoice_line_id IS NULL THEN
      RAISE EXCEPTION 'Line-level hold requires invoice line id.';
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
    IF p_tracking_submission_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.order_tracking_submissions ots
      WHERE ots.id = p_tracking_submission_id
        AND ots.order_id = v_order_id
        AND ots.superseded_at IS NULL
    ) THEN
      RAISE EXCEPTION 'Tracking/package does not belong to this order.';
    END IF;
  END IF;

  INSERT INTO public.customer_pre_shipment_hold_requests (
    order_id,
    review_link_id,
    tracking_submission_id,
    supplier_invoice_line_id,
    requested_scope,
    reason,
    customer_contact_label
  ) VALUES (
    v_order_id,
    v_link_id,
    p_tracking_submission_id,
    p_supplier_invoice_line_id,
    p_requested_scope,
    btrim(p_reason),
    NULLIF(btrim(COALESCE(p_customer_contact_label, '')), '')
  )
  RETURNING id INTO v_hold_id;

  RETURN v_hold_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.internal_customer_pre_shipment_holds_v1(p_include_closed boolean DEFAULT false)
RETURNS TABLE (
  hold_request_id uuid,
  order_id uuid,
  order_ref text,
  importer_name text,
  retailer_name text,
  requested_scope text,
  tracking_submission_id uuid,
  tracking_ref text,
  supplier_invoice_line_id uuid,
  line_description text,
  line_qty numeric,
  line_amount_inc_vat_gbp numeric,
  reason text,
  customer_contact_label text,
  status text,
  supervisor_review_note text,
  created_at timestamptz,
  reviewed_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: customer hold queue requires auth.uid()';
  END IF;
  IF NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff account required for customer hold queue.';
  END IF;

  RETURN QUERY
  SELECT
    h.id,
    h.order_id,
    o.order_ref::text,
    COALESCE(NULLIF(i.trading_name, ''), i.company_name)::text,
    r.name::text,
    h.requested_scope::text,
    h.tracking_submission_id,
    ots.tracking_ref::text,
    h.supplier_invoice_line_id,
    sil.description::text,
    sil.qty::numeric,
    sil.amount_inc_vat_gbp::numeric,
    h.reason,
    h.customer_contact_label,
    h.status::text,
    h.supervisor_review_note,
    h.created_at,
    h.reviewed_at
  FROM public.customer_pre_shipment_hold_requests h
  JOIN public.orders o ON o.id = h.order_id
  LEFT JOIN public.importers i ON i.id = o.importer_id
  LEFT JOIN public.retailers r ON r.id = o.retailer_id
  LEFT JOIN public.order_tracking_submissions ots ON ots.id = h.tracking_submission_id
  LEFT JOIN public.supplier_invoice_lines sil ON sil.id = h.supplier_invoice_line_id
  WHERE p_include_closed = true
     OR h.status IN ('requested','supervisor_approved')
  ORDER BY h.created_at DESC;
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

  UPDATE public.customer_pre_shipment_hold_requests h
  SET status = v_new_status,
      supervisor_review_note = NULLIF(btrim(COALESCE(p_review_note, '')), ''),
      reviewed_by_staff_id = v_staff_id,
      reviewed_at = now(),
      resolved_at = CASE WHEN v_new_status IN ('rejected','resolved','superseded') THEN now() ELSE h.resolved_at END,
      updated_at = now()
  WHERE h.id = p_hold_request_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Customer hold request not found: %', p_hold_request_id;
  END IF;

  RETURN QUERY
  SELECT p_hold_request_id, v_new_status, ('Customer hold marked ' || v_new_status)::text;
END;
$$;

CREATE OR REPLACE FUNCTION public.shipper_customer_hold_set_aside_v1()
RETURNS TABLE (
  order_id uuid,
  order_ref text,
  tracking_submission_id uuid,
  tracking_ref text,
  supplier_invoice_line_id uuid,
  hold_scope text,
  hold_status text,
  set_aside_instruction text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_shipper_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: shipper hold visibility requires auth.uid()';
  END IF;

  SELECT su.shipper_id INTO v_shipper_id
  FROM public.shipper_users su
  WHERE su.auth_user_id = auth.uid()
    AND su.active = true
  ORDER BY su.created_at DESC
  LIMIT 1;

  IF v_shipper_id IS NULL THEN
    RAISE EXCEPTION 'Active shipper user account not found.';
  END IF;

  RETURN QUERY
  SELECT
    o.id,
    o.order_ref::text,
    h.tracking_submission_id,
    ots.tracking_ref::text,
    h.supplier_invoice_line_id,
    h.requested_scope::text,
    h.status::text,
    'CUSTOMER HOLD — SET ASIDE / DO NOT SHIP UNTIL SUPERVISOR CLEARS'::text
  FROM public.customer_pre_shipment_hold_requests h
  JOIN public.orders o ON o.id = h.order_id
  LEFT JOIN public.order_tracking_submissions ots ON ots.id = h.tracking_submission_id
  WHERE o.shipper_id = v_shipper_id
    AND h.status = 'supervisor_approved'
  ORDER BY h.created_at DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_create_customer_order_review_link_v1(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.customer_pre_shipment_hold_review_v1(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.customer_submit_pre_shipment_hold_request_v1(text,text,uuid,uuid,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_customer_pre_shipment_holds_v1(boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_review_customer_pre_shipment_hold_v1(uuid,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.shipper_customer_hold_set_aside_v1() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.internal_create_customer_order_review_link_v1(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.customer_pre_shipment_hold_review_v1(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.customer_submit_pre_shipment_hold_request_v1(text,text,uuid,uuid,text,text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.internal_customer_pre_shipment_holds_v1(boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.internal_review_customer_pre_shipment_hold_v1(uuid,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.shipper_customer_hold_set_aside_v1() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
