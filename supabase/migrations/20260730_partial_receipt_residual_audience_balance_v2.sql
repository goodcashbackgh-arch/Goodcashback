BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Narrow repair of the receipt-residual audience balance against the ACTUAL live
-- chain proven from production metadata:
--
--   order_audience_status_v1(uuid)
--     -> order_audience_status_pre_importer_tracking_assignment_v1(uuid)
--     -> order_audience_status_pre_receipt_residual_overlay_v1(uuid)
--
-- The middle function is the defective 28 July all-or-nothing receipt-residual
-- overlay. The live top-level function then adds only importer tracking-assignment
-- presentation. This migration preserves that tracking behaviour while replacing
-- only the defective receipt-residual arithmetic.
--
-- Accounting rule:
--   still_order_applied_residual
--     = max(active_non_reversed_physical_residual - exact_linked_overfunding_credit, 0)
--
--   collectible_balance
--     = max(existing_pre_overlay_canonical_balance - still_order_applied_residual, 0)
--
-- FX/card residuals and attributed-receipt totals are deliberately excluded from
-- collectible-balance arithmetic. No financial or operational data is written.

DO $$
DECLARE
  v_current_definition text;
  v_current_normalized text;
  v_current_result_signature text;
  v_current_prosecdef boolean;
  v_current_proconfig text[];

  v_overlay_definition text;
  v_overlay_normalized text;
  v_overlay_result_signature text;
  v_overlay_prosecdef boolean;
  v_overlay_proconfig text[];

  v_expected_signature constant text :=
    'TABLE(order_id uuid, order_ref text, raw_order_status text, lifecycle_status text, importer_id uuid, importer_name text, retailer_id uuid, retailer_name text, accepted_estimate_gbp numeric, final_sale_value_gbp numeric, canonical_amount_received_gbp numeric, canonical_balance_due_gbp numeric, potential_credit_pending_review_gbp numeric, internal_current_stage text, internal_current_stage_label text, internal_next_owner text, internal_next_action text, internal_next_href text, internal_status_tone text, gate_complete_count integer, gate_total integer, funding_state text, dva_state text, supplier_state text, reconciliation_state text, tracking_state text, shipment_state text, export_evidence_state text, pod_delivery_state text, customer_sales_state text, shipper_ap_state text, accounting_sage_state text, vat_compliance_state text, internal_complete_yn boolean, customer_complete_yn boolean, importer_complete_yn boolean, shipper_complete_yn boolean, customer_status_label text, customer_next_action text, importer_status_label text, importer_next_action text, shipper_status_label text, shipper_next_action text)';
BEGIN
  IF to_regprocedure('public.order_audience_status_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Missing public.order_audience_status_v1(uuid)';
  END IF;

  IF to_regprocedure('public.order_audience_status_pre_importer_tracking_assignment_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Missing live tracking predecessor public.order_audience_status_pre_importer_tracking_assignment_v1(uuid)';
  END IF;

  IF to_regprocedure('public.order_audience_status_pre_receipt_residual_overlay_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Missing public.order_audience_status_pre_receipt_residual_overlay_v1(uuid)';
  END IF;

  IF to_regclass('public.order_pending_funding_surplus') IS NULL THEN
    RAISE EXCEPTION 'Missing public.order_pending_funding_surplus';
  END IF;

  IF to_regclass('public.importer_credit_ledger') IS NULL THEN
    RAISE EXCEPTION 'Missing public.importer_credit_ledger';
  END IF;

  IF to_regclass('public.order_evidence_queries') IS NULL
     OR to_regclass('public.order_tracking_submissions') IS NULL
     OR to_regclass('public.order_tracking_line_allocations') IS NULL
     OR to_regclass('public.supplier_invoices') IS NULL
     OR to_regclass('public.supplier_invoice_lines') IS NULL
  THEN
    RAISE EXCEPTION 'Missing live importer tracking-assignment dependency; stop before patching.';
  END IF;

  SELECT
    lower(pg_get_functiondef(p.oid)),
    pg_get_function_result(p.oid),
    p.prosecdef,
    p.proconfig
  INTO
    v_current_definition,
    v_current_result_signature,
    v_current_prosecdef,
    v_current_proconfig
  FROM pg_proc p
  WHERE p.oid = 'public.order_audience_status_v1(uuid)'::regprocedure;

  SELECT
    lower(pg_get_functiondef(p.oid)),
    pg_get_function_result(p.oid),
    p.prosecdef,
    p.proconfig
  INTO
    v_overlay_definition,
    v_overlay_result_signature,
    v_overlay_prosecdef,
    v_overlay_proconfig
  FROM pg_proc p
  WHERE p.oid = 'public.order_audience_status_pre_importer_tracking_assignment_v1(uuid)'::regprocedure;

  v_current_normalized := regexp_replace(v_current_definition, '\s+', ' ', 'g');
  v_overlay_normalized := regexp_replace(v_overlay_definition, '\s+', ' ', 'g');

  IF v_current_result_signature IS DISTINCT FROM v_expected_signature
     OR v_overlay_result_signature IS DISTINCT FROM v_expected_signature
  THEN
    RAISE EXCEPTION 'Audience return contract changed; stop before patching.';
  END IF;

  IF NOT COALESCE(v_current_prosecdef, false)
     OR NOT COALESCE(v_current_proconfig, ARRAY[]::text[]) @> ARRAY['search_path=public, pg_temp']::text[]
     OR NOT COALESCE(v_overlay_prosecdef, false)
     OR NOT COALESCE(v_overlay_proconfig, ARRAY[]::text[]) @> ARRAY['search_path=public, pg_temp']::text[]
  THEN
    RAISE EXCEPTION 'Audience execution boundary changed; stop before patching.';
  END IF;

  -- Prove the live top-level function is the tracking-assignment wrapper supplied
  -- in production, and that its only base is the defective 28 July overlay.
  IF position('from public.order_audience_status_pre_importer_tracking_assignment_v1(p_order_id)' IN v_current_normalized) = 0
     OR position('tracking_assignment_needed' IN v_current_normalized) = 0
     OR position('from public.order_evidence_queries' IN v_current_normalized) = 0
     OR position('from public.order_tracking_submissions' IN v_current_normalized) = 0
     OR position('join public.order_tracking_line_allocations' IN v_current_normalized) = 0
     OR position('when p.tracking_assignment_needed then ''assign tracking''' IN v_current_normalized) = 0
  THEN
    RAISE EXCEPTION 'Live top-level audience function is no longer the proven importer tracking-assignment wrapper; stop before patching.';
  END IF;

  -- Prove the middle predecessor is exactly the defective receipt-residual overlay
  -- and that it directly preserves the pre-overlay canonical audience chain.
  IF position('from public.order_audience_status_pre_receipt_residual_overlay_v1(p_order_id)' IN v_overlay_normalized) = 0
     OR position('false_positive_final_balance' IN v_overlay_normalized) = 0
     OR position('order_settlement_resolution_position_v1' IN v_overlay_normalized) = 0
     OR position('order_attributed_receipt_gbp' IN v_overlay_normalized) = 0
     OR position('pending_receipt_residual_gbp' IN v_overlay_normalized) = 0
  THEN
    RAISE EXCEPTION 'Live middle audience predecessor is no longer the proven 28 July receipt-residual overlay; stop before patching.';
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
    -- Bypass only the defective middle 28 July all-or-nothing overlay.
    -- This is the exact live predecessor beneath that overlay.
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
  ), residual_projected AS (
    SELECT
      r.*,
      (
        COALESCE(r.canonical_balance_due_gbp, 0) > 0.01
        AND COALESCE(r.corrected_balance_due_gbp, 0) <= 0.01
      ) AS balance_cleared_by_physical_residual,
      CASE
        WHEN NOT (
          COALESCE(r.canonical_balance_due_gbp, 0) > 0.01
          AND COALESCE(r.corrected_balance_due_gbp, 0) <= 0.01
        ) THEN r.customer_status_label
        WHEN r.pod_delivery_state = 'accepted_current' THEN 'Completed'
        WHEN r.export_evidence_state = 'accepted_current' THEN 'Shipment delivered'
        WHEN r.shipment_state = 'allocated' THEN 'Shipment arranged'
        WHEN r.funding_state = 'complete' THEN 'Payment received; processing'
        ELSE 'In progress'
      END::text AS corrected_customer_status_label,
      CASE
        WHEN NOT (
          COALESCE(r.canonical_balance_due_gbp, 0) > 0.01
          AND COALESCE(r.corrected_balance_due_gbp, 0) <= 0.01
        ) THEN r.customer_next_action
        WHEN r.pod_delivery_state = 'accepted_current' THEN 'Order complete'
        WHEN r.export_evidence_state = 'accepted_current' THEN 'Delivery confirmation received'
        WHEN r.shipment_state = 'allocated' THEN 'Waiting for delivery confirmation'
        ELSE 'No action needed right now'
      END::text AS corrected_customer_next_action,
      CASE
        WHEN NOT (
          COALESCE(r.canonical_balance_due_gbp, 0) > 0.01
          AND COALESCE(r.corrected_balance_due_gbp, 0) <= 0.01
        ) THEN r.importer_status_label
        WHEN COALESCE(r.internal_current_stage, '') = 'exception_or_hold_open' THEN r.importer_status_label
        WHEN r.supplier_state IN ('rejected_resubmit_required', 'review_needed') THEN r.importer_status_label
        WHEN r.reconciliation_state = 'incomplete' THEN 'Invoice reconciliation open'
        WHEN r.reconciliation_state = 'complete' AND r.tracking_state = 'missing' THEN 'Invoice reconciled; tracking open'
        WHEN r.reconciliation_state = 'complete' AND r.tracking_state IN ('allocation_incomplete', 'submitted') THEN 'Tracking submitted'
        WHEN r.pod_delivery_state = 'accepted_current' THEN 'Order complete'
        ELSE 'No importer action required'
      END::text AS corrected_importer_status_label,
      CASE
        WHEN NOT (
          COALESCE(r.canonical_balance_due_gbp, 0) > 0.01
          AND COALESCE(r.corrected_balance_due_gbp, 0) <= 0.01
        ) THEN r.importer_next_action
        WHEN COALESCE(r.internal_current_stage, '') = 'exception_or_hold_open' THEN r.importer_next_action
        WHEN r.supplier_state IN ('rejected_resubmit_required', 'review_needed') THEN r.importer_next_action
        WHEN r.reconciliation_state = 'incomplete' THEN 'Continue invoice reconciliation'
        WHEN r.reconciliation_state = 'complete' AND r.tracking_state = 'missing' THEN 'Add tracking'
        WHEN r.pod_delivery_state = 'accepted_current' THEN 'Order complete'
        ELSE 'No importer action required'
      END::text AS corrected_importer_next_action
    FROM residual_scoped r
  ), open_queries AS (
    SELECT
      q.order_id,
      COUNT(*) FILTER (WHERE q.status = 'open')::integer AS open_query_count
    FROM public.order_evidence_queries q
    JOIN residual_projected b ON b.order_id = q.order_id
    GROUP BY q.order_id
  ), active_tracking AS (
    SELECT
      ots.order_id,
      COUNT(*)::integer AS active_tracking_count
    FROM public.order_tracking_submissions ots
    JOIN residual_projected b ON b.order_id = ots.order_id
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
    JOIN residual_projected b ON b.order_id = si.order_id
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
  ), tracking_projected AS (
    SELECT
      b.*,
      (
        COALESCE(b.corrected_balance_due_gbp, 0) <= 0.01
        AND COALESCE(b.internal_current_stage, '') <> 'exception_or_hold_open'
        AND b.supplier_state = 'approved_current'
        AND b.reconciliation_state = 'complete'
        AND b.tracking_state IN ('allocation_incomplete', 'submitted')
        AND COALESCE(at.active_tracking_count, 0) > 0
        AND COALESCE(oq.open_query_count, 0) = 0
        AND COALESCE(a.unassigned_physical_line_count, 0) > 0
      ) AS tracking_assignment_needed
    FROM residual_projected b
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
    p.corrected_customer_status_label AS customer_status_label,
    p.corrected_customer_next_action AS customer_next_action,
    p.corrected_importer_status_label AS importer_status_label,
    CASE
      WHEN p.tracking_assignment_needed THEN 'Assign tracking'
      ELSE p.corrected_importer_next_action
    END::text AS importer_next_action,
    p.shipper_status_label,
    p.shipper_next_action
  FROM tracking_projected p
  ORDER BY p.order_ref;
END;
$$;

REVOKE ALL ON FUNCTION public.order_audience_status_v1(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.order_audience_status_v1(uuid) TO authenticated;

COMMENT ON FUNCTION public.order_audience_status_v1(uuid) IS
'Live audience projection repaired in place. Preserves importer tracking-assignment presentation while bypassing only the defective 28 July all-or-nothing receipt-residual predecessor. Collectible balance equals the preserved pre-overlay canonical balance less active non-reversed physical receipt residual still belonging to the order after exact linked overfunding-credit conversion. FX/card and attributed-receipt amounts are excluded.';

NOTIFY pgrst, 'reload schema';

COMMIT;
