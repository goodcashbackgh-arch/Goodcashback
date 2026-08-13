BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
DECLARE
  v_fn_oid oid := to_regprocedure('public.customer_pre_shipment_hold_review_v1(text)');
  v_body_hash text;
  v_security_definer boolean;
  v_config text[];
BEGIN
  IF to_regclass('public.customer_pre_shipment_hold_requests') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.customer_pre_shipment_hold_requests';
  END IF;
  IF to_regclass('public.supplier_invoice_lines') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoice_lines';
  END IF;
  IF to_regclass('public.customer_order_review_links') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.customer_order_review_links';
  END IF;
  IF to_regprocedure('public.customer_review_ready_line_ids_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.customer_review_ready_line_ids_v1(uuid)';
  END IF;
  IF v_fn_oid IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.customer_pre_shipment_hold_review_v1(text)';
  END IF;

  SELECT md5(p.prosrc), p.prosecdef, p.proconfig
    INTO v_body_hash, v_security_definer, v_config
  FROM pg_proc p
  WHERE p.oid = v_fn_oid;

  -- Fail closed against unreviewed live drift. This hash is the exact stored
  -- PL/pgSQL body from 20260719_customer_hold_review_orderwide_state_v1.sql.
  IF v_body_hash IS DISTINCT FROM '67da874101ecfa2620169d89fb5fec9c' THEN
    RAISE EXCEPTION
      'Customer review RPC drift detected; expected baseline body hash 67da874101ecfa2620169d89fb5fec9c, got %. No changes applied.',
      v_body_hash;
  END IF;

  IF v_security_definer IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Customer review RPC drift detected: SECURITY DEFINER changed. No changes applied.';
  END IF;

  IF NOT ('search_path=public, pg_temp' = ANY(COALESCE(v_config, ARRAY[]::text[]))) THEN
    RAISE EXCEPTION 'Customer review RPC drift detected: search_path changed to %. No changes applied.', v_config;
  END IF;

  IF NOT has_function_privilege('anon', v_fn_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'Customer review RPC drift detected: anon EXECUTE privilege missing. No changes applied.';
  END IF;

  IF NOT has_function_privilege('authenticated', v_fn_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'Customer review RPC drift detected: authenticated EXECUTE privilege missing. No changes applied.';
  END IF;
END $$;

-- Governing authority:
-- docs/governing-pack/ui/CUSTOMER_HOLD_INTEGRITY_AND_EXCEPTION_BRIDGE_ADDENDUM_v1.md
-- Sections 16-17 only.
-- Additive read-model enrichment for historical line-level hold identity.
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
        'supervisor_review_note', h.supervisor_review_note,
        'line_description', hsil.description,
        'line_qty', hsil.qty,
        'line_amount_inc_vat_gbp', hsil.amount_inc_vat_gbp
      ) ORDER BY h.created_at DESC)
      FROM public.customer_pre_shipment_hold_requests h
      LEFT JOIN public.supplier_invoice_lines hsil
        ON hsil.id = h.supplier_invoice_line_id
      WHERE h.order_id = o.id
    ), '[]'::jsonb)
  ) INTO v_result
  FROM public.orders o
  LEFT JOIN public.retailers r ON r.id = o.retailer_id
  WHERE o.id = v_order_id;

  RETURN v_result;
END;
$$;

-- CREATE OR REPLACE preserves the existing function owner and privileges.
-- Do not REVOKE/GRANT here: this migration is not authorised to alter access.

NOTIFY pgrst, 'reload schema';

COMMIT;
