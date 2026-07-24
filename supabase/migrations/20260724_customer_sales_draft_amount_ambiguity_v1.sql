BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- =============================================================================
-- Customer sales draft creation ambiguity hotfix.
--
-- Root cause:
-- Mini-build 3 replaced the previously hardened bulk-draft function and
-- reintroduced unqualified sales_invoices/order/source column references whose
-- names also exist as RETURNS TABLE output variables (notably amount_gbp).
--
-- Scope:
-- Re-deploy the current Mini-build 3 function byte-for-byte in behaviour while
-- qualifying only those internal SQL column references. No queue, grouping,
-- release-membership, main/supplementary, Sage, VAT, shipment, hold, refund,
-- funding or status logic is changed.
-- =============================================================================

DO $$
BEGIN
  IF to_regprocedure('public.internal_customer_invoice_release_create_drafts_v1(uuid[])') IS NULL THEN
    RAISE EXCEPTION 'Missing public.internal_customer_invoice_release_create_drafts_v1(uuid[])';
  END IF;

  IF to_regclass('public.customer_sales_release_lines') IS NULL
     OR to_regclass('public.sales_invoices') IS NULL
     OR to_regclass('public.orders') IS NULL
  THEN
    RAISE EXCEPTION 'Customer sales release prerequisite relation missing.';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.internal_customer_invoice_release_create_drafts_v1(
  p_shipment_batch_ids uuid[]
)
RETURNS TABLE (
  shipment_batch_id uuid,
  order_id uuid,
  order_ref text,
  booking_ref text,
  invoice_type text,
  result_status text,
  sales_invoice_id uuid,
  amount_gbp numeric,
  message text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff uuid;
  v_batch uuid;
  v_parent uuid;
  v_type text;
  v_main uuid;
  v_invoice uuid;
  v_amount numeric;
  v_payload jsonb;
  v_ref text;
  v_booking text;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff required';
  END IF;

  IF p_shipment_batch_ids IS NULL OR array_length(p_shipment_batch_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'At least one shipment batch id is required';
  END IF;

  SELECT st.id
    INTO v_staff
  FROM public.staff st
  WHERE st.auth_user_id = auth.uid()
    AND st.active = true
  LIMIT 1;

  CREATE TEMP TABLE _release_src ON COMMIT DROP AS
  SELECT src.*
  FROM (
    SELECT DISTINCT unnest(p_shipment_batch_ids) AS selected_batch_id
  ) selected
  CROSS JOIN LATERAL public.internal_customer_sales_release_sources_v1(selected.selected_batch_id) src
  WHERE src.blocker IS NULL
     OR src.blocker = 'customer_sales_release_draft_already_exists';

  CREATE INDEX ON _release_src (commercial_parent_order_id, proposed_invoice_type);

  FOR v_parent IN
    SELECT DISTINCT rs.commercial_parent_order_id
    FROM _release_src rs
    ORDER BY rs.commercial_parent_order_id
  LOOP
    PERFORM pg_advisory_xact_lock(hashtext('customer_sales_release|' || v_parent::text));

    PERFORM 1
    FROM public.orders o
    WHERE o.id = v_parent
    FOR UPDATE;

    SELECT
      si.id,
      si.amount_gbp,
      si.invoice_type::text
    INTO
      v_invoice,
      v_amount,
      v_type
    FROM public.sales_invoices si
    WHERE si.order_id = v_parent
      AND si.invoice_type IN ('main', 'supplementary')
      AND si.sage_status = 'draft'
    ORDER BY si.created_at DESC
    LIMIT 1;

    SELECT
      MIN(rs.shipment_batch_id),
      MIN(rs.order_ref),
      string_agg(DISTINCT rs.booking_ref, ', ' ORDER BY rs.booking_ref)
    INTO
      v_batch,
      v_ref,
      v_booking
    FROM _release_src rs
    WHERE rs.commercial_parent_order_id = v_parent;

    IF v_invoice IS NOT NULL THEN
      RETURN QUERY
      SELECT
        v_batch,
        v_parent,
        v_ref,
        v_booking,
        v_type,
        'skipped_draft_already_exists'::text,
        v_invoice,
        v_amount,
        'Existing draft reused; no duplicate release membership created'::text;
      CONTINUE;
    END IF;

    IF NOT EXISTS (
      SELECT 1
      FROM _release_src rs
      WHERE rs.commercial_parent_order_id = v_parent
        AND rs.blocker IS NULL
    ) THEN
      CONTINUE;
    END IF;

    SELECT si.id
      INTO v_main
    FROM public.sales_invoices si
    WHERE si.order_id = v_parent
      AND si.invoice_type = 'main'
      AND si.sage_status <> 'void'
    ORDER BY si.created_at
    LIMIT 1;

    IF v_main IS NULL THEN
      v_type := 'main';
    ELSE
      v_type := 'supplementary';
    END IF;

    SELECT
      ROUND(SUM(rs.customer_charge_amount_gbp), 2),
      jsonb_build_object(
        'sage_header',
        jsonb_build_object(
          'reference', MIN(rs.order_ref),
          'notes', 'Booking ' || string_agg(DISTINCT rs.booking_ref, ', ' ORDER BY rs.booking_ref)
        ),
        'tax_resolution',
        jsonb_build_object(
          'tax_treatment', 'zero_rated_export',
          'display_vat_code', 'zero-rated export'
        ),
        'lines',
        jsonb_agg(
          jsonb_build_object(
            'source_order_id', rs.source_order_id,
            'source_commercial_parent_order_id', rs.commercial_parent_order_id,
            'source_shipment_batch_id', rs.shipment_batch_id,
            'source_tracking_submission_id', rs.tracking_submission_id,
            'source_tracking_line_allocation_id', rs.tracking_line_allocation_id,
            'source_supplier_invoice_id', rs.supplier_invoice_id,
            'source_supplier_invoice_line_id', rs.supplier_invoice_line_id,
            'released_qty', rs.release_qty,
            'goods_amount_gbp', rs.goods_amount_gbp,
            'delivery_share_gbp', rs.delivery_share_gbp,
            'discount_share_gbp', rs.discount_share_gbp,
            'shipping_amount_gbp', rs.shipping_amount_gbp,
            'customer_charge_amount_gbp', rs.customer_charge_amount_gbp,
            'membership_fingerprint', rs.membership_fingerprint,
            'description', rs.item_description,
            'quantity', CASE WHEN rs.release_qty > 0 THEN rs.release_qty ELSE 1 END,
            'total_line_amount_gbp', rs.customer_charge_amount_gbp,
            'ledger_account_role', 'export_sale_income'
          )
          ORDER BY rs.booking_ref, rs.tracking_ref, rs.item_description
        ),
        'draft_control',
        jsonb_build_object(
          'created_from', 'customer_invoice_release_queue',
          'shipment_batch_id', MIN(rs.shipment_batch_id),
          'shipment_batch_ids', jsonb_agg(DISTINCT rs.shipment_batch_id),
          'status', 'internal_draft_only_not_posted_to_sage'
        )
      )
    INTO
      v_amount,
      v_payload
    FROM _release_src rs
    WHERE rs.commercial_parent_order_id = v_parent
      AND rs.blocker IS NULL;

    IF COALESCE(v_amount, 0) <= 0 THEN
      CONTINUE;
    END IF;

    INSERT INTO public.sales_invoices (
      order_id,
      invoice_type,
      linked_invoice_id,
      consideration_received_date,
      sage_invoice_date,
      tax_point_period,
      sage_invoice_period,
      vat_box6_reported_period,
      amount_gbp,
      vat_code,
      line_items_json,
      sage_invoice_id,
      sage_posted_at,
      sage_status,
      export_evidence_complete_date,
      zero_rating_deadline_date,
      zero_rating_status,
      vat_adjustment_posted_at,
      reversal_posted_at,
      raised_by_trigger
    )
    VALUES (
      v_parent,
      v_type,
      CASE WHEN v_type = 'supplementary' THEN v_main ELSE NULL END,
      CURRENT_DATE,
      CURRENT_DATE,
      to_char(CURRENT_DATE, 'YYYY-MM'),
      to_char(CURRENT_DATE, 'YYYY-MM'),
      NULL,
      v_amount,
      'ZERO_RATED_EXPORT_INTENT',
      v_payload,
      NULL,
      NULL,
      'draft',
      NULL,
      (CURRENT_DATE + INTERVAL '90 days')::date,
      'on_track',
      NULL,
      NULL,
      false
    )
    RETURNING public.sales_invoices.id
      INTO v_invoice;

    INSERT INTO public.customer_sales_release_lines (
      sales_invoice_id,
      sales_invoice_type,
      order_id,
      commercial_parent_order_id,
      source_shipment_batch_id,
      supplier_invoice_id,
      supplier_invoice_line_id,
      tracking_submission_id,
      tracking_line_allocation_id,
      released_qty,
      goods_amount_gbp,
      delivery_share_gbp,
      discount_share_gbp,
      shipping_amount_gbp,
      customer_charge_amount_gbp,
      membership_fingerprint,
      created_by_staff_id
    )
    SELECT
      v_invoice,
      v_type,
      rs.source_order_id,
      rs.commercial_parent_order_id,
      rs.shipment_batch_id,
      rs.supplier_invoice_id,
      rs.supplier_invoice_line_id,
      rs.tracking_submission_id,
      rs.tracking_line_allocation_id,
      rs.release_qty,
      rs.goods_amount_gbp,
      rs.delivery_share_gbp,
      rs.discount_share_gbp,
      rs.shipping_amount_gbp,
      rs.customer_charge_amount_gbp,
      rs.membership_fingerprint,
      v_staff
    FROM _release_src rs
    WHERE rs.commercial_parent_order_id = v_parent
      AND rs.blocker IS NULL;

    RETURN QUERY
    SELECT
      v_batch,
      v_parent,
      v_ref,
      v_booking,
      v_type,
      'draft_created'::text,
      v_invoice,
      v_amount,
      'Draft sales invoice created with durable exact release membership. Not posted to Sage.'::text;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_customer_invoice_release_create_drafts_v1(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_customer_invoice_release_create_drafts_v1(uuid[]) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
