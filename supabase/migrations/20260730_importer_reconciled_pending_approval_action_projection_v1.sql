BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Importer next-action projection only.
-- Governing addendum:
-- docs/governing-pack/ui/IMPORTER_RECONCILED_PENDING_APPROVAL_ACTION_PROJECTION_ADDENDUM_v1.md
--
-- No business-data writes. No supplier approval/coding/funding/Sage/internal/customer/
-- shipper changes. The live audience function is preserved as an exact predecessor;
-- the new public wrapper overrides importer_next_action only when importer-owned
-- reconciliation work is proven complete.

DO $$
DECLARE
  v_definition text;
  v_result text;
  v_expected_result constant text :=
    'TABLE(order_id uuid, order_ref text, raw_order_status text, lifecycle_status text, importer_id uuid, importer_name text, retailer_id uuid, retailer_name text, accepted_estimate_gbp numeric, final_sale_value_gbp numeric, canonical_amount_received_gbp numeric, canonical_balance_due_gbp numeric, potential_credit_pending_review_gbp numeric, internal_current_stage text, internal_current_stage_label text, internal_next_owner text, internal_next_action text, internal_next_href text, internal_status_tone text, gate_complete_count integer, gate_total integer, funding_state text, dva_state text, supplier_state text, reconciliation_state text, tracking_state text, shipment_state text, export_evidence_state text, pod_delivery_state text, customer_sales_state text, shipper_ap_state text, accounting_sage_state text, vat_compliance_state text, internal_complete_yn boolean, customer_complete_yn boolean, importer_complete_yn boolean, shipper_complete_yn boolean, customer_status_label text, customer_next_action text, importer_status_label text, importer_next_action text, shipper_status_label text, shipper_next_action text)';
BEGIN
  IF to_regprocedure('public.order_audience_status_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Missing public.order_audience_status_v1(uuid)';
  END IF;

  IF to_regprocedure('public.order_audience_status_pre_importer_reconciled_action_v1(uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'Importer reconciled-action predecessor already exists; stop before patching.';
  END IF;

  IF to_regclass('public.supplier_invoices') IS NULL
     OR to_regclass('public.supplier_invoice_lines') IS NULL
     OR to_regclass('public.supplier_invoice_line_resolutions') IS NULL
     OR to_regclass('public.supplier_invoice_review_flags') IS NULL
     OR to_regclass('public.dispute_lines') IS NULL
     OR to_regclass('public.disputes') IS NULL
     OR to_regclass('public.order_evidence_queries') IS NULL
     OR to_regclass('public.order_tracking_submissions') IS NULL
     OR to_regclass('public.order_tracking_line_allocations') IS NULL
  THEN
    RAISE EXCEPTION 'Importer reconciled-action dependency missing; stop before patching.';
  END IF;

  SELECT lower(pg_get_functiondef(p.oid)), pg_get_function_result(p.oid)
    INTO v_definition, v_result
  FROM pg_proc p
  WHERE p.oid = 'public.order_audience_status_v1(uuid)'::regprocedure;

  IF v_result IS DISTINCT FROM v_expected_result THEN
    RAISE EXCEPTION 'Audience return contract changed; stop before patching.';
  END IF;

  v_definition := regexp_replace(v_definition, '\s+', ' ', 'g');

  IF position('from public.order_audience_status_pre_receipt_residual_overlay_v1(p_order_id)' IN v_definition) = 0
     OR position('tracking_assignment_needed' IN v_definition) = 0
     OR position('when p.tracking_assignment_needed then ''assign tracking''' IN v_definition) = 0
  THEN
    RAISE EXCEPTION 'Live audience function is no longer the proven 30 July residual/tracking projection; stop before patching.';
  END IF;
END $$;

ALTER FUNCTION public.order_audience_status_v1(uuid)
  RENAME TO order_audience_status_pre_importer_reconciled_action_v1;

CREATE OR REPLACE FUNCTION public.internal_importer_reconciled_next_action_v1(
  p_order_id uuid,
  p_fallback_action text,
  p_canonical_balance_due_gbp numeric,
  p_internal_current_stage text,
  p_pod_delivery_state text
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_live_invoice_count integer := 0;
  v_genuine_resubmission_count integer := 0;
  v_open_query_count integer := 0;
  v_open_review_flag_count integer := 0;
  v_progressed_physical_count integer := 0;
  v_progressed_missing_confirmation_count integer := 0;
  v_unresolved_line_count integer := 0;
  v_active_tracking_count integer := 0;
  v_unassigned_physical_line_count integer := 0;
BEGIN
  -- Preserve all existing higher-priority action semantics.
  IF COALESCE(p_canonical_balance_due_gbp, 0) > 0.01
     OR COALESCE(p_internal_current_stage, '') = 'exception_or_hold_open'
  THEN
    RETURN p_fallback_action;
  END IF;

  IF p_pod_delivery_state = 'accepted_current' THEN
    RETURN 'Order complete';
  END IF;

  SELECT
    COUNT(*) FILTER (
      WHERE COALESCE(si.review_status, '') NOT IN (
        'rejected_resubmit_required', 'superseded', 'duplicate_blocked'
      )
    )::integer,
    COUNT(*) FILTER (
      WHERE si.review_status = 'rejected_resubmit_required'
        AND COALESCE(si.rejection_requires_resubmission_yn, true) = true
    )::integer
  INTO v_live_invoice_count, v_genuine_resubmission_count
  FROM public.supplier_invoices si
  WHERE si.order_id = p_order_id;

  IF v_live_invoice_count = 0 OR v_genuine_resubmission_count > 0 THEN
    RETURN p_fallback_action;
  END IF;

  SELECT COUNT(*)::integer
  INTO v_open_query_count
  FROM public.order_evidence_queries q
  WHERE q.order_id = p_order_id
    AND q.status = 'open';

  IF v_open_query_count > 0 THEN
    RETURN p_fallback_action;
  END IF;

  SELECT COUNT(*)::integer
  INTO v_open_review_flag_count
  FROM public.supplier_invoice_review_flags f
  JOIN public.supplier_invoices si ON si.id = f.supplier_invoice_id
  WHERE si.order_id = p_order_id
    AND COALESCE(si.review_status, '') NOT IN (
      'rejected_resubmit_required', 'superseded', 'duplicate_blocked'
    )
    AND f.status IN ('open', 'under_review');

  IF v_open_review_flag_count > 0 THEN
    RETURN p_fallback_action;
  END IF;

  SELECT
    COUNT(sil.id) FILTER (
      WHERE lower(COALESCE(sil.eligible_for_invoice_yn::text, '')) IN ('y', 'yes', 'true', '1')
    )::integer,
    COUNT(sil.id) FILTER (
      WHERE lower(COALESCE(sil.eligible_for_invoice_yn::text, '')) IN ('y', 'yes', 'true', '1')
        AND (sil.qty_confirmed IS NULL OR sil.amount_confirmed IS NULL)
    )::integer,
    COUNT(sil.id) FILTER (
      WHERE lower(COALESCE(sil.eligible_for_invoice_yn::text, '')) NOT IN ('y', 'yes', 'true', '1')
        AND NOT EXISTS (
          SELECT 1
          FROM public.supplier_invoice_line_resolutions r
          WHERE r.supplier_invoice_line_id = sil.id
            AND r.supplier_invoice_id = si.id
            AND r.resolution_type = 'non_physical_financial'
            AND r.active = true
        )
        AND NOT EXISTS (
          SELECT 1
          FROM public.dispute_lines dl
          JOIN public.disputes d ON d.id = dl.dispute_id
          WHERE dl.supplier_invoice_line_id = sil.id
            AND dl.resolved_at IS NULL
            AND d.resolved_at IS NULL
        )
    )::integer
  INTO
    v_progressed_physical_count,
    v_progressed_missing_confirmation_count,
    v_unresolved_line_count
  FROM public.supplier_invoices si
  JOIN public.supplier_invoice_lines sil ON sil.supplier_invoice_id = si.id
  WHERE si.order_id = p_order_id
    AND COALESCE(si.review_status, '') NOT IN (
      'rejected_resubmit_required', 'superseded', 'duplicate_blocked'
    );

  IF v_progressed_physical_count = 0
     OR v_progressed_missing_confirmation_count > 0
     OR v_unresolved_line_count > 0
  THEN
    RETURN p_fallback_action;
  END IF;

  SELECT COUNT(*)::integer
  INTO v_active_tracking_count
  FROM public.order_tracking_submissions ots
  WHERE ots.order_id = p_order_id
    AND ots.superseded_at IS NULL;

  IF v_active_tracking_count = 0 THEN
    RETURN 'Add tracking';
  END IF;

  WITH physical_position AS (
    SELECT
      sil.id,
      GREATEST(COALESCE(sil.qty_confirmed, sil.qty, 0), 0)::numeric AS required_qty,
      COALESCE(SUM(otla.qty_allocated) FILTER (WHERE ats.id IS NOT NULL), 0)::numeric
        AS active_tracking_allocated_qty
    FROM public.supplier_invoices si
    JOIN public.supplier_invoice_lines sil ON sil.supplier_invoice_id = si.id
    LEFT JOIN public.order_tracking_line_allocations otla
      ON otla.order_id = si.order_id
     AND otla.supplier_invoice_line_id = sil.id
     AND otla.tracking_submission_id IS NOT NULL
    LEFT JOIN public.order_tracking_submissions ats
      ON ats.id = otla.tracking_submission_id
     AND ats.order_id = si.order_id
     AND ats.superseded_at IS NULL
    WHERE si.order_id = p_order_id
      AND COALESCE(si.review_status, '') NOT IN (
        'rejected_resubmit_required', 'superseded', 'duplicate_blocked'
      )
      AND lower(COALESCE(sil.eligible_for_invoice_yn::text, '')) IN ('y', 'yes', 'true', '1')
    GROUP BY sil.id, sil.qty_confirmed, sil.qty
  )
  SELECT COUNT(*) FILTER (
    WHERE required_qty > 0
      AND active_tracking_allocated_qty + 0.0005 < required_qty
  )::integer
  INTO v_unassigned_physical_line_count
  FROM physical_position;

  IF v_unassigned_physical_line_count > 0 THEN
    RETURN 'Assign tracking';
  END IF;

  RETURN 'No importer action required';
END;
$$;

REVOKE ALL ON FUNCTION public.internal_importer_reconciled_next_action_v1(uuid, text, numeric, text, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.internal_importer_reconciled_next_action_v1(uuid, text, numeric, text, text)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.order_audience_status_v1(
  p_order_id uuid DEFAULT NULL
)
RETURNS TABLE (
  order_id uuid,
  order_ref text,
  raw_order_status text,
  lifecycle_status text,
  importer_id uuid,
  importer_name text,
  retailer_id uuid,
  retailer_name text,
  accepted_estimate_gbp numeric,
  final_sale_value_gbp numeric,
  canonical_amount_received_gbp numeric,
  canonical_balance_due_gbp numeric,
  potential_credit_pending_review_gbp numeric,
  internal_current_stage text,
  internal_current_stage_label text,
  internal_next_owner text,
  internal_next_action text,
  internal_next_href text,
  internal_status_tone text,
  gate_complete_count integer,
  gate_total integer,
  funding_state text,
  dva_state text,
  supplier_state text,
  reconciliation_state text,
  tracking_state text,
  shipment_state text,
  export_evidence_state text,
  pod_delivery_state text,
  customer_sales_state text,
  shipper_ap_state text,
  accounting_sage_state text,
  vat_compliance_state text,
  internal_complete_yn boolean,
  customer_complete_yn boolean,
  importer_complete_yn boolean,
  shipper_complete_yn boolean,
  customer_status_label text,
  customer_next_action text,
  importer_status_label text,
  importer_next_action text,
  shipper_status_label text,
  shipper_next_action text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: order audience status requires auth.uid()';
  END IF;

  RETURN QUERY
  SELECT
    b.order_id,
    b.order_ref,
    b.raw_order_status,
    b.lifecycle_status,
    b.importer_id,
    b.importer_name,
    b.retailer_id,
    b.retailer_name,
    b.accepted_estimate_gbp,
    b.final_sale_value_gbp,
    b.canonical_amount_received_gbp,
    b.canonical_balance_due_gbp,
    b.potential_credit_pending_review_gbp,
    b.internal_current_stage,
    b.internal_current_stage_label,
    b.internal_next_owner,
    b.internal_next_action,
    b.internal_next_href,
    b.internal_status_tone,
    b.gate_complete_count,
    b.gate_total,
    b.funding_state,
    b.dva_state,
    b.supplier_state,
    b.reconciliation_state,
    b.tracking_state,
    b.shipment_state,
    b.export_evidence_state,
    b.pod_delivery_state,
    b.customer_sales_state,
    b.shipper_ap_state,
    b.accounting_sage_state,
    b.vat_compliance_state,
    b.internal_complete_yn,
    b.customer_complete_yn,
    b.importer_complete_yn,
    b.shipper_complete_yn,
    b.customer_status_label,
    b.customer_next_action,
    b.importer_status_label,
    public.internal_importer_reconciled_next_action_v1(
      b.order_id,
      b.importer_next_action,
      b.canonical_balance_due_gbp,
      b.internal_current_stage,
      b.pod_delivery_state
    ) AS importer_next_action,
    b.shipper_status_label,
    b.shipper_next_action
  FROM public.order_audience_status_pre_importer_reconciled_action_v1(p_order_id) b
  ORDER BY b.order_ref;
END;
$$;

REVOKE ALL ON FUNCTION public.order_audience_status_v1(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.order_audience_status_v1(uuid) TO authenticated;

COMMENT ON FUNCTION public.order_audience_status_v1(uuid) IS
'Importer-action-only wrapper. Preserves the complete prior audience projection and changes only importer_next_action when importer reconciliation is proven complete while supplier invoices legitimately await later internal coding/supervisor approval.';

NOTIFY pgrst, 'reload schema';

COMMIT;
