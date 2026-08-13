BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
DECLARE
  v_fn_oid oid := to_regprocedure('public.customer_pre_shipment_hold_review_v1(text)');
  v_body_hash text;
  v_security_definer boolean;
  v_config text[];
  v_owner text;
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
  IF to_regclass('public.customer_review_cycle_memberships') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.customer_review_cycle_memberships';
  END IF;
  IF to_regprocedure('public.customer_review_ready_line_ids_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.customer_review_ready_line_ids_v1(uuid)';
  END IF;
  IF v_fn_oid IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.customer_pre_shipment_hold_review_v1(text)';
  END IF;

  SELECT md5(p.prosrc), p.prosecdef, p.proconfig, pg_get_userbyid(p.proowner)
    INTO v_body_hash, v_security_definer, v_config, v_owner
  FROM pg_proc p
  WHERE p.oid = v_fn_oid;

  -- Fail closed against unreviewed live drift. This is the exact live body hash
  -- proved by the read-only 2026-08-13 drift probe. It includes the protected
  -- immutable timed-review membership selection and legacy untimed fallback.
  IF v_body_hash IS DISTINCT FROM '6a0db733f7190e746efddcb1e938aa17' THEN
    RAISE EXCEPTION
      'Customer review RPC drift detected; expected governed live baseline body hash 6a0db733f7190e746efddcb1e938aa17, got %. No changes applied.',
      v_body_hash;
  END IF;

  IF v_security_definer IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Customer review RPC drift detected: SECURITY DEFINER changed. No changes applied.';
  END IF;

  IF NOT ('search_path=public, pg_temp' = ANY(COALESCE(v_config, ARRAY[]::text[]))) THEN
    RAISE EXCEPTION 'Customer review RPC drift detected: search_path changed to %. No changes applied.', v_config;
  END IF;

  IF v_owner IS DISTINCT FROM 'postgres' THEN
    RAISE EXCEPTION 'Customer review RPC drift detected: owner changed to %. No changes applied.', v_owner;
  END IF;

  IF NOT has_function_privilege('anon', v_fn_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'Customer review RPC drift detected: anon EXECUTE privilege missing. No changes applied.';
  END IF;

  IF NOT has_function_privilege('authenticated', v_fn_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'Customer review RPC drift detected: authenticated EXECUTE privilege missing. No changes applied.';
  END IF;

  IF NOT has_function_privilege('service_role', v_fn_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'Customer review RPC drift detected: service_role EXECUTE privilege missing. No changes applied.';
  END IF;
END $$;

-- Governing authority:
-- docs/governing-pack/ui/CUSTOMER_HOLD_INTEGRITY_AND_EXCEPTION_BRIDGE_ADDENDUM_v1.md
-- Sections 16-17 only.
-- Additive read-model enrichment for historical line-level hold identity.
-- The live immutable timed-review selection and legacy fallback are preserved.
CREATE OR REPLACE FUNCTION public.customer_pre_shipment_hold_review_v1(p_secure_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_link_id uuid;
  v_order_id uuid;
  v_expires_at timestamptz;
  v_result jsonb;
BEGIN
  SELECT link_row.id, link_row.order_id, link_row.expires_at
  INTO v_link_id, v_order_id, v_expires_at
  FROM public.customer_order_review_links link_row
  WHERE link_row.secure_token = p_secure_token
    AND link_row.is_active = true
    AND (link_row.expires_at IS NULL OR link_row.expires_at > now())
  LIMIT 1;

  IF v_order_id IS NULL THEN
    RAISE EXCEPTION 'Customer review link is invalid or expired.';
  END IF;

  UPDATE public.customer_order_review_links
  SET last_used_at = now()
  WHERE id = v_link_id;

  SELECT jsonb_build_object(
    'order', jsonb_build_object(
      'id', order_row.id,
      'order_ref', order_row.order_ref,
      'retailer_name', retailer_row.name,
      'status', order_row.status,
      'order_type', order_row.order_type,
      'total_qty_declared', order_row.total_qty_declared
    ),
    'tracking', '[]'::jsonb,
    'lines', COALESCE((
      WITH timed_lines AS (
        SELECT DISTINCT
          membership.supplier_invoice_line_id,
          membership.tracking_submission_id
        FROM public.customer_review_cycle_memberships membership
        WHERE membership.review_link_id = v_link_id
          AND membership.membership_status = 'active'
          AND v_expires_at IS NOT NULL
      ),
      legacy_lines AS (
        SELECT DISTINCT
          ready_line.supplier_invoice_line_id,
          ready_line.tracking_submission_id
        FROM public.customer_review_ready_line_ids_v1(v_order_id) ready_line
        WHERE v_expires_at IS NULL
      ),
      review_lines AS (
        SELECT * FROM timed_lines
        UNION
        SELECT * FROM legacy_lines
      )
      SELECT jsonb_agg(jsonb_build_object(
        'id', supplier_line.id,
        'description', supplier_line.description,
        'size', supplier_line.size,
        'retailer_sku', supplier_line.retailer_sku,
        'qty', supplier_line.qty,
        'amount_inc_vat_gbp', supplier_line.amount_inc_vat_gbp,
        'tracking_submission_id', review_line.tracking_submission_id,
        'eligible_for_invoice_yn', supplier_line.eligible_for_invoice_yn
      ) ORDER BY supplier_line.created_at NULLS LAST, supplier_line.id)
      FROM review_lines review_line
      JOIN public.supplier_invoice_lines supplier_line
        ON supplier_line.id = review_line.supplier_invoice_line_id
    ), '[]'::jsonb),
    'holds', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', hold_row.id,
        'requested_scope', hold_row.requested_scope,
        'tracking_submission_id', hold_row.tracking_submission_id,
        'supplier_invoice_line_id', hold_row.supplier_invoice_line_id,
        'narrowed_from_hold_request_id', hold_row.narrowed_from_hold_request_id,
        'converted_dispute_id', hold_row.converted_dispute_id,
        'status', hold_row.status,
        'reason', hold_row.reason,
        'created_at', hold_row.created_at,
        'supervisor_review_note', hold_row.supervisor_review_note,
        'line_description', hold_line.description,
        'line_qty', hold_line.qty,
        'line_amount_inc_vat_gbp', hold_line.amount_inc_vat_gbp
      ) ORDER BY hold_row.created_at DESC)
      FROM public.customer_pre_shipment_hold_requests hold_row
      LEFT JOIN public.supplier_invoice_lines hold_line
        ON hold_line.id = hold_row.supplier_invoice_line_id
      WHERE hold_row.order_id = order_row.id
    ), '[]'::jsonb)
  )
  INTO v_result
  FROM public.orders order_row
  LEFT JOIN public.retailers retailer_row
    ON retailer_row.id = order_row.retailer_id
  WHERE order_row.id = v_order_id;

  RETURN v_result;
END;
$$;

-- CREATE OR REPLACE preserves the existing function owner and privileges.
-- Do not REVOKE/GRANT here: this migration is not authorised to alter access.

NOTIFY pgrst, 'reload schema';

COMMIT;
