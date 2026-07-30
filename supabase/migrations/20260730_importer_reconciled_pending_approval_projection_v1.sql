BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Importer-only read-model correction.
--
-- A supplier invoice may legitimately remain pending_review / blocked_from_sage_yn
-- after importer reconciliation because accounting coding and supervisor approval are
-- later controls. The importer audience must therefore distinguish:
--   * genuine evidence/reconciliation work still open; from
--   * reconciliation complete, awaiting internal coding/approval.
--
-- This migration changes no supplier invoice, line, coding, review, tracking,
-- allocation, funding, settlement, Sage, customer, shipper or supervisor data.
-- It changes only importer-facing status/action projection in order_audience_status_v1.

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

  IF to_regprocedure('public.order_audience_status_pre_receipt_residual_overlay_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Missing canonical audience predecessor';
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
    RAISE EXCEPTION 'Importer reconciliation projection dependency missing; stop before patching.';
  END IF;

  SELECT lower(pg_get_functiondef(p.oid)), pg_get_function_result(p.oid)
    INTO v_definition, v_result
  FROM pg_proc p
  WHERE p.oid = 'public.order_audience_status_v1(uuid)'::regprocedure;

  IF v_result IS DISTINCT FROM v_expected_result THEN
    RAISE EXCEPTION 'Audience return contract changed; stop before patching.';
  END IF;

  IF position('from public.order_audience_status_pre_receipt_residual_overlay_v1(p_order_id)' IN regexp_replace(v_definition, '\s+', ' ', 'g')) = 0
     OR position('tracking_assignment_needed' IN regexp_replace(v_definition, '\s+', ' ', 'g')) = 0
     OR position('when p.tracking_assignment_needed then ''assign tracking''' IN regexp_replace(v_definition, '\s+', ' ', 'g')) = 0
  THEN
    RAISE EXCEPTION 'Live audience function is not the proven 30 July residual/tracking projection; stop before patching.';
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
  WITH canonical_base AS (
    SELECT *
    FROM public.order_audience_status_pre_receipt_residual_overlay_v1(p_order_id)
  ), active_pending AS (
    SELECT
      p.order_id,
      ROUND(COALESCE(SUM(p.pending_surplus_gbp), 0)::numeric, 2) AS active_pending_receipt_gbp
    FROM public.order_pending_funding_surplus p
    JOIN canonical_base b ON b.order_id = p.order_id
    WHERE p.status IN ('pending_evidence', 'credit_confirmed')
      AND p.reversed_at IS NULL
    GROUP BY p.order_id
  ), distinct_credit_links AS (
    SELECT DISTINCT
      p.order_id,
      p.importer_id,
      p.confirmed_credit_ledger_id
    FROM public.order_pending_funding_surplus p
    JOIN canonical_base b ON b.order_id = p.order_id
    WHERE p.status = 'credit_confirmed'
      AND p.reversed_at IS NULL
      AND p.confirmed_credit_ledger_id IS NOT NULL
  ), linked_confirmed_credit AS (
    SELECT
      l.order_id,
      ROUND(COALESCE(SUM(ABS(c.amount_gbp)), 0)::numeric, 2) AS linked_confirmed_credit_gbp
    FROM distinct_credit_links l
    JOIN public.importer_credit_ledger c
      ON c.id = l.confirmed_credit_ledger_id
     AND c.importer_id = l.importer_id
     AND c.direction = 'credit'
     AND c.entry_type = 'manual_credit'
     AND c.source_type = 'overfunding'
     AND c.source_table = 'orders'
     AND c.source_id = l.order_id
     AND c.linked_order_id = l.order_id
     AND c.source_entity_type = 'order'
     AND c.source_entity_id = l.order_id
    GROUP BY l.order_id
  ), residual_scoped AS (
    SELECT
      b.*,
      ROUND(
        GREATEST(
          COALESCE(ap.active_pending_receipt_gbp, 0)
            - COALESCE(lcc.linked_confirmed_credit_gbp, 0),
          0
        )::numeric,
        2
      ) AS still_order_applied_residual_gbp,
      ROUND(
        CASE
          WHEN COALESCE(ap.active_pending_receipt_gbp, 0) > 0.01
          THEN GREATEST(
            COALESCE(b.canonical_balance_due_gbp, 0)
              - GREATEST(
                  COALESCE(ap.active_pending_receipt_gbp, 0)
                    - COALESCE(lcc.linked_confirmed_credit_gbp, 0),
                  0
                ),
            0
          )
          ELSE COALESCE(b.canonical_balance_due_gbp, 0)
        END::numeric,
        2
      ) AS corrected_balance_due_gbp
    FROM canonical_base b
    LEFT JOIN active_pending ap ON ap.order_id = b.order_id
    LEFT JOIN linked_confirmed_credit lcc ON lcc.order_id = b.order_id
  ), open_queries AS (
    SELECT
      q.order_id,
      COUNT(*) FILTER (WHERE q.status = 'open')::integer AS open_query_count
    FROM public.order_evidence_queries q
    JOIN residual_scoped b ON b.order_id = q.order_id
    GROUP BY q.order_id
  ), invoice_control AS (
    SELECT
      si.order_id,
      COUNT(*) FILTER (
        WHERE COALESCE(si.review_status, '') NOT IN ('rejected_resubmit_required', 'superseded', 'duplicate_blocked')
      )::integer AS live_invoice_count,
      COUNT(*) FILTER (
        WHERE si.review_status = 'rejected_resubmit_required'
          AND COALESCE(si.rejection_requires_resubmission_yn, true) = true
      )::integer AS genuine_resubmission_required_count,
      COUNT(*) FILTER (
        WHERE COALESCE(si.review_status, '') NOT IN ('pending_review', 'approved_current', 'ref_corrected_approved', 'rejected_resubmit_required', 'superseded', 'duplicate_blocked')
      )::integer AS other_review_state_count
    FROM public.supplier_invoices si
    JOIN residual_scoped b ON b.order_id = si.order_id
    GROUP BY si.order_id
  ), line_control AS (
    SELECT
      si.order_id,
      COUNT(sil.id)::integer AS live_line_count,
      COUNT(sil.id) FILTER (
        WHERE lower(COALESCE(sil.eligible_for_invoice_yn::text, '')) IN ('y', 'yes', 'true', '1')
      )::integer AS progressed_line_count,
      COUNT(sil.id) FILTER (
        WHERE lower(COALESCE(sil.eligible_for_invoice_yn::text, '')) IN ('y', 'yes', 'true', '1')
          AND (sil.qty_confirmed IS NULL OR sil.amount_confirmed IS NULL)
      )::integer AS progressed_missing_confirmation_count,
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
      )::integer AS unresolved_line_count
    FROM public.supplier_invoices si
    JOIN residual_scoped b ON b.order_id = si.order_id
    JOIN public.supplier_invoice_lines sil ON sil.supplier_invoice_id = si.id
    WHERE COALESCE(si.review_status, '') NOT IN ('rejected_resubmit_required', 'superseded', 'duplicate_blocked')
    GROUP BY si.order_id
  ), review_flags AS (
    SELECT
      si.order_id,
      COUNT(*) FILTER (WHERE f.status IN ('open', 'under_review'))::integer AS open_review_flag_count
    FROM public.supplier_invoices si
    JOIN residual_scoped b ON b.order_id = si.order_id
    JOIN public.supplier_invoice_review_flags f ON f.supplier_invoice_id = si.id
    WHERE COALESCE(si.review_status, '') NOT IN ('rejected_resubmit_required', 'superseded', 'duplicate_blocked')
    GROUP BY si.order_id
  ), active_tracking AS (
    SELECT
      ots.order_id,
      COUNT(*)::integer AS active_tracking_count
    FROM public.order_tracking_submissions ots
    JOIN residual_scoped b ON b.order_id = ots.order_id
    WHERE ots.superseded_at IS NULL
    GROUP BY ots.order_id
  ), physical_line_position AS (
    SELECT
      si.order_id,
      sil.id AS supplier_invoice_line_id,
      GREATEST(COALESCE(sil.qty_confirmed, sil.qty, 0), 0)::numeric AS required_qty,
      COALESCE(SUM(otla.qty_allocated) FILTER (WHERE ats.id IS NOT NULL), 0)::numeric AS active_tracking_allocated_qty
    FROM public.supplier_invoices si
    JOIN residual_scoped b ON b.order_id = si.order_id
    JOIN public.supplier_invoice_lines sil ON sil.supplier_invoice_id = si.id
    LEFT JOIN public.order_tracking_line_allocations otla
      ON otla.order_id = si.order_id
     AND otla.supplier_invoice_line_id = sil.id
     AND otla.tracking_submission_id IS NOT NULL
    LEFT JOIN public.order_tracking_submissions ats
      ON ats.id = otla.tracking_submission_id
     AND ats.order_id = si.order_id
     AND ats.superseded_at IS NULL
    WHERE COALESCE(si.review_status, '') NOT IN ('rejected_resubmit_required', 'superseded', 'duplicate_blocked')
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
  ), importer_control AS (
    SELECT
      r.*,
      COALESCE(oq.open_query_count, 0) AS open_query_count,
      COALESCE(ic.live_invoice_count, 0) AS live_invoice_count,
      COALESCE(ic.genuine_resubmission_required_count, 0) AS genuine_resubmission_required_count,
      COALESCE(ic.other_review_state_count, 0) AS other_review_state_count,
      COALESCE(lc.live_line_count, 0) AS live_line_count,
      COALESCE(lc.progressed_line_count, 0) AS progressed_line_count,
      COALESCE(lc.progressed_missing_confirmation_count, 0) AS progressed_missing_confirmation_count,
      COALESCE(lc.unresolved_line_count, 0) AS unresolved_line_count,
      COALESCE(rf.open_review_flag_count, 0) AS open_review_flag_count,
      COALESCE(at.active_tracking_count, 0) AS active_tracking_count,
      COALESCE(a.unassigned_physical_line_count, 0) AS unassigned_physical_line_count,
      (
        COALESCE(ic.live_invoice_count, 0) > 0
        AND COALESCE(lc.live_line_count, 0) > 0
        AND COALESCE(lc.progressed_line_count, 0) > 0
        AND COALESCE(lc.unresolved_line_count, 0) = 0
        AND COALESCE(lc.progressed_missing_confirmation_count, 0) = 0
        AND COALESCE(rf.open_review_flag_count, 0) = 0
        AND COALESCE(ic.genuine_resubmission_required_count, 0) = 0
        AND COALESCE(ic.other_review_state_count, 0) = 0
      ) AS importer_reconciliation_complete
    FROM residual_scoped r
    LEFT JOIN open_queries oq ON oq.order_id = r.order_id
    LEFT JOIN invoice_control ic ON ic.order_id = r.order_id
    LEFT JOIN line_control lc ON lc.order_id = r.order_id
    LEFT JOIN review_flags rf ON rf.order_id = r.order_id
    LEFT JOIN active_tracking at ON at.order_id = r.order_id
    LEFT JOIN assignment_scope a ON a.order_id = r.order_id
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
    p.corrected_balance_due_gbp::numeric AS canonical_balance_due_gbp,
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
    CASE
      WHEN COALESCE(p.canonical_balance_due_gbp, 0) > 0.01 THEN p.customer_status_label
      ELSE p.customer_status_label
    END::text AS customer_status_label,
    p.customer_next_action,
    CASE
      WHEN COALESCE(p.corrected_balance_due_gbp, 0) > 0.01
        OR COALESCE(p.internal_current_stage, '') = 'exception_or_hold_open'
        OR p.open_query_count > 0
        OR NOT p.importer_reconciliation_complete
      THEN p.importer_status_label
      WHEN p.pod_delivery_state = 'accepted_current' THEN 'Order complete'
      WHEN p.active_tracking_count = 0 THEN 'Invoice reconciled; tracking open'
      WHEN p.unassigned_physical_line_count > 0 THEN 'Tracking submitted'
      ELSE 'Tracking assigned'
    END::text AS importer_status_label,
    CASE
      WHEN COALESCE(p.corrected_balance_due_gbp, 0) > 0.01
        OR COALESCE(p.internal_current_stage, '') = 'exception_or_hold_open'
        OR p.open_query_count > 0
        OR NOT p.importer_reconciliation_complete
      THEN p.importer_next_action
      WHEN p.pod_delivery_state = 'accepted_current' THEN 'Order complete'
      WHEN p.active_tracking_count = 0 THEN 'Add tracking'
      WHEN p.unassigned_physical_line_count > 0 THEN 'Assign tracking'
      ELSE 'No importer action required'
    END::text AS importer_next_action,
    p.shipper_status_label,
    p.shipper_next_action
  FROM importer_control p
  ORDER BY p.order_ref;
END;
$$;

REVOKE ALL ON FUNCTION public.order_audience_status_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.order_audience_status_v1(uuid) TO authenticated;

COMMIT;
