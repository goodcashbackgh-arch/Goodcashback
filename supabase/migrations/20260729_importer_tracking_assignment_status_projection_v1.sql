BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Scope: one importer audience-status projection only.
--
-- Preserve the current canonical audience status function exactly as the base,
-- then override importer_next_action only where all of these are true:
--   * supplier evidence is already approved/current;
--   * supplier reconciliation is complete;
--   * submitted tracking exists;
--   * there is no higher-priority open evidence query / exception / balance blocker;
--   * at least one progressed physical supplier line still has quantity not assigned
--     to an active tracking submission.
--
-- No operational row is mutated by this migration.

DO $$
BEGIN
  IF to_regprocedure('public.order_audience_status_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Missing public.order_audience_status_v1(uuid) prerequisite';
  END IF;

  IF to_regclass('public.supplier_invoices') IS NULL THEN
    RAISE EXCEPTION 'Missing public.supplier_invoices prerequisite';
  END IF;

  IF to_regclass('public.supplier_invoice_lines') IS NULL THEN
    RAISE EXCEPTION 'Missing public.supplier_invoice_lines prerequisite';
  END IF;

  IF to_regclass('public.order_tracking_submissions') IS NULL THEN
    RAISE EXCEPTION 'Missing public.order_tracking_submissions prerequisite';
  END IF;

  IF to_regclass('public.order_tracking_line_allocations') IS NULL THEN
    RAISE EXCEPTION 'Missing public.order_tracking_line_allocations prerequisite';
  END IF;

  IF to_regclass('public.order_evidence_queries') IS NULL THEN
    RAISE EXCEPTION 'Missing public.order_evidence_queries prerequisite';
  END IF;

  IF to_regprocedure('public.order_audience_status_pre_importer_tracking_assignment_v1(uuid)') IS NULL THEN
    ALTER FUNCTION public.order_audience_status_v1(uuid)
      RENAME TO order_audience_status_pre_importer_tracking_assignment_v1;
  END IF;
END $$;

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
  WITH base AS (
    SELECT *
    FROM public.order_audience_status_pre_importer_tracking_assignment_v1(p_order_id)
  ), open_queries AS (
    SELECT
      q.order_id,
      COUNT(*) FILTER (WHERE q.status = 'open')::integer AS open_query_count
    FROM public.order_evidence_queries q
    JOIN base b ON b.order_id = q.order_id
    GROUP BY q.order_id
  ), active_tracking AS (
    SELECT
      ots.order_id,
      COUNT(*)::integer AS active_tracking_count
    FROM public.order_tracking_submissions ots
    JOIN base b ON b.order_id = ots.order_id
    WHERE ots.superseded_at IS NULL
    GROUP BY ots.order_id
  ), physical_line_position AS (
    SELECT
      si.order_id,
      sil.id AS supplier_invoice_line_id,
      GREATEST(COALESCE(sil.qty_confirmed, sil.qty, 0), 0)::numeric AS required_qty,
      COALESCE(SUM(otla.qty_allocated) FILTER (
        WHERE ats.id IS NOT NULL
      ), 0)::numeric AS active_tracking_allocated_qty
    FROM public.supplier_invoices si
    JOIN base b ON b.order_id = si.order_id
    JOIN public.supplier_invoice_lines sil
      ON sil.supplier_invoice_id = si.id
    LEFT JOIN public.order_tracking_line_allocations otla
      ON otla.order_id = si.order_id
     AND otla.supplier_invoice_line_id = sil.id
     AND otla.tracking_submission_id IS NOT NULL
    LEFT JOIN public.order_tracking_submissions ats
      ON ats.id = otla.tracking_submission_id
     AND ats.order_id = si.order_id
     AND ats.superseded_at IS NULL
    WHERE COALESCE(si.is_current_for_order, true) = true
      AND si.review_status IN ('approved_current', 'ref_corrected_approved')
      AND COALESCE(si.blocked_from_sage_yn, false) = false
      AND lower(COALESCE(sil.eligible_for_invoice_yn::text, '')) IN ('y', 'yes', 'true', '1')
    GROUP BY si.order_id, sil.id, sil.qty_confirmed, sil.qty
  ), assignment_scope AS (
    SELECT
      plp.order_id,
      COUNT(*) FILTER (
        WHERE plp.required_qty > 0
          AND plp.active_tracking_allocated_qty + 0.0005 < plp.required_qty
      )::integer AS unassigned_physical_line_count
    FROM physical_line_position plp
    GROUP BY plp.order_id
  ), projected AS (
    SELECT
      b.*,
      (
        COALESCE(b.canonical_balance_due_gbp, 0) <= 0.01
        AND COALESCE(b.internal_current_stage, '') <> 'exception_or_hold_open'
        AND b.supplier_state = 'approved_current'
        AND b.reconciliation_state = 'complete'
        AND b.tracking_state IN ('allocation_incomplete', 'submitted')
        AND COALESCE(at.active_tracking_count, 0) > 0
        AND COALESCE(oq.open_query_count, 0) = 0
        AND COALESCE(a.unassigned_physical_line_count, 0) > 0
      ) AS tracking_assignment_needed
    FROM base b
    LEFT JOIN open_queries oq ON oq.order_id = b.order_id
    LEFT JOIN active_tracking at ON at.order_id = b.order_id
    LEFT JOIN assignment_scope a ON a.order_id = b.order_id
  )
  SELECT
    p.order_id,
    p.order_ref,
    p.raw_order_status,
    p.lifecycle_status,
    p.importer_id,
    p.importer_name,
    p.retailer_id,
    p.retailer_name,
    p.accepted_estimate_gbp,
    p.final_sale_value_gbp,
    p.canonical_amount_received_gbp,
    p.canonical_balance_due_gbp,
    p.potential_credit_pending_review_gbp,
    p.internal_current_stage,
    p.internal_current_stage_label,
    p.internal_next_owner,
    p.internal_next_action,
    p.internal_next_href,
    p.internal_status_tone,
    p.gate_complete_count,
    p.gate_total,
    p.funding_state,
    p.dva_state,
    p.supplier_state,
    p.reconciliation_state,
    p.tracking_state,
    p.shipment_state,
    p.export_evidence_state,
    p.pod_delivery_state,
    p.customer_sales_state,
    p.shipper_ap_state,
    p.accounting_sage_state,
    p.vat_compliance_state,
    p.internal_complete_yn,
    p.customer_complete_yn,
    p.importer_complete_yn,
    p.shipper_complete_yn,
    p.customer_status_label,
    p.customer_next_action,
    p.importer_status_label,
    CASE
      WHEN p.tracking_assignment_needed THEN 'Assign tracking'
      ELSE p.importer_next_action
    END::text AS importer_next_action,
    p.shipper_status_label,
    p.shipper_next_action
  FROM projected p
  ORDER BY p.order_ref;
END;
$$;

REVOKE ALL ON FUNCTION public.order_audience_status_v1(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.order_audience_status_v1(uuid) TO authenticated;

COMMENT ON FUNCTION public.order_audience_status_v1(uuid) IS
'Canonical audience status with one narrow importer tracking-assignment projection: when approved/reconciled physical lines remain unassigned to already-submitted active tracking, importer_next_action is Assign tracking. Existing missing-evidence, missing-tracking and downstream status behaviour pass through unchanged.';

NOTIFY pgrst, 'reload schema';

COMMIT;
