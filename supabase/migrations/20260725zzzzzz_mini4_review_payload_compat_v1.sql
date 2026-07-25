BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Preserve the existing customer review payload values exactly. Timed cycles
-- use immutable membership only to select line/tracking identities; the visible
-- qty and amount_inc_vat_gbp fields continue to come from supplier_invoice_lines.
-- No UI, posting, accounting, cash, credit-note or Sage object is changed.

DO $prerequisites$
DECLARE
  v_definition text;
BEGIN
  IF to_regclass('public.customer_review_cycle_memberships') IS NULL
     OR to_regprocedure(
       'public.customer_pre_shipment_hold_review_v1(text)'
     ) IS NULL
  THEN
    RAISE EXCEPTION 'Mini 4 review payload prerequisites are missing.';
  END IF;

  SELECT lower(pg_get_functiondef(
    'public.customer_pre_shipment_hold_review_v1(text)'::regprocedure
  )) INTO v_definition;

  IF position('customer_review_cycle_memberships' IN v_definition) = 0
     OR position('membership.goods_amount_gbp' IN v_definition) = 0
  THEN
    RAISE EXCEPTION
      'Current review payload no longer matches the audited pre-compatibility Mini 4 definition.';
  END IF;
END
$prerequisites$;

CREATE OR REPLACE FUNCTION public.customer_pre_shipment_hold_review_v1(
  p_secure_token text
)
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
        'supervisor_review_note', hold_row.supervisor_review_note
      ) ORDER BY hold_row.created_at DESC)
      FROM public.customer_pre_shipment_hold_requests hold_row
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

REVOKE ALL ON FUNCTION public.customer_pre_shipment_hold_review_v1(text)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.customer_pre_shipment_hold_review_v1(text)
  TO anon, authenticated;

DO $proof$
DECLARE
  v_definition text;
BEGIN
  SELECT lower(pg_get_functiondef(
    'public.customer_pre_shipment_hold_review_v1(text)'::regprocedure
  )) INTO v_definition;

  IF position('customer_review_cycle_memberships' IN v_definition) = 0
     OR position('''qty'', supplier_line.qty' IN v_definition) = 0
     OR position(
          '''amount_inc_vat_gbp'', supplier_line.amount_inc_vat_gbp'
          IN v_definition
        ) = 0
     OR position('membership.goods_amount_gbp' IN v_definition) > 0
     OR position('membership.delivery_share_gbp' IN v_definition) > 0
     OR position('membership.discount_share_gbp' IN v_definition) > 0
  THEN
    RAISE EXCEPTION
      'Customer review payload compatibility proof failed.';
  END IF;
END
$proof$;

NOTIFY pgrst, 'reload schema';

COMMIT;
