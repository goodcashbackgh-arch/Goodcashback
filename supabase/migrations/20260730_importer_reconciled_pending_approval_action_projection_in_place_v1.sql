BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Governing addendum:
-- docs/governing-pack/ui/IMPORTER_RECONCILED_PENDING_APPROVAL_ACTION_PROJECTION_ADDENDUM_v1.md
--
-- One read-model correction only. Replace the body of the existing
-- public.order_audience_status_v1(uuid) in place, preserving its OID, owner, ACL,
-- SECURITY DEFINER boundary, search_path and every projected field except the exact
-- importer_next_action defect governed by the addendum.
--
-- No predecessor rename. No helper RPC. No grant/revoke changes. No business-data writes.

CREATE TEMP TABLE _importer_pending_approval_function_contract
ON COMMIT DROP
AS
SELECT
  p.oid,
  p.proowner,
  p.proacl,
  p.prosecdef,
  p.proconfig,
  pg_get_function_result(p.oid) AS result_signature
FROM pg_proc p
WHERE p.oid = to_regprocedure('public.order_audience_status_v1(uuid)');

DO $$
DECLARE
  v_definition text;
  v_normalized text;
  v_result_signature text;
  v_security_definer boolean;
  v_config text[];
  v_expected_signature constant text :=
    'TABLE(order_id uuid, order_ref text, raw_order_status text, lifecycle_status text, importer_id uuid, importer_name text, retailer_id uuid, retailer_name text, accepted_estimate_gbp numeric, final_sale_value_gbp numeric, canonical_amount_received_gbp numeric, canonical_balance_due_gbp numeric, potential_credit_pending_review_gbp numeric, internal_current_stage text, internal_current_stage_label text, internal_next_owner text, internal_next_action text, internal_next_href text, internal_status_tone text, gate_complete_count integer, gate_total integer, funding_state text, dva_state text, supplier_state text, reconciliation_state text, tracking_state text, shipment_state text, export_evidence_state text, pod_delivery_state text, customer_sales_state text, shipper_ap_state text, accounting_sage_state text, vat_compliance_state text, internal_complete_yn boolean, customer_complete_yn boolean, importer_complete_yn boolean, shipper_complete_yn boolean, customer_status_label text, customer_next_action text, importer_status_label text, importer_next_action text, shipper_status_label text, shipper_next_action text)';
BEGIN
  IF NOT EXISTS (SELECT 1 FROM _importer_pending_approval_function_contract) THEN
    RAISE EXCEPTION 'Missing public.order_audience_status_v1(uuid)';
  END IF;

  IF to_regprocedure('public.order_audience_status_pre_receipt_residual_overlay_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Missing public.order_audience_status_pre_receipt_residual_overlay_v1(uuid)';
  END IF;

  IF to_regclass('public.order_pending_funding_surplus') IS NULL
     OR to_regclass('public.importer_credit_ledger') IS NULL
     OR to_regclass('public.order_evidence_queries') IS NULL
     OR to_regclass('public.order_tracking_submissions') IS NULL
     OR to_regclass('public.order_tracking_line_allocations') IS NULL
     OR to_regclass('public.supplier_invoices') IS NULL
     OR to_regclass('public.supplier_invoice_lines') IS NULL
     OR to_regclass('public.supplier_invoice_line_resolutions') IS NULL
     OR to_regclass('public.supplier_invoice_review_flags') IS NULL
     OR to_regclass('public.dispute_lines') IS NULL
     OR to_regclass('public.disputes') IS NULL
  THEN
    RAISE EXCEPTION 'Importer pending-approval projection dependency missing; stop before patching.';
  END IF;

  SELECT
    lower(pg_get_functiondef(p.oid)),
    pg_get_function_result(p.oid),
    p.prosecdef,
    p.proconfig
  INTO
    v_definition,
    v_result_signature,
    v_security_definer,
    v_config
  FROM pg_proc p
  WHERE p.oid = 'public.order_audience_status_v1(uuid)'::regprocedure;

  IF v_result_signature IS DISTINCT FROM v_expected_signature THEN
    RAISE EXCEPTION 'Audience return contract changed; stop before patching.';
  END IF;

  IF v_security_definer IS DISTINCT FROM true
     OR NOT COALESCE(v_config, ARRAY[]::text[]) @> ARRAY['search_path=public, pg_temp']::text[]
  THEN
    RAISE EXCEPTION 'Audience execution boundary changed; stop before patching.';
  END IF;

  v_normalized := regexp_replace(v_definition, '\s+', ' ', 'g');

  -- Fail closed unless the live function is the exact 30 July residual/tracking shape
  -- this correction was designed against.
  IF position('from public.order_audience_status_pre_receipt_residual_overlay_v1(p_order_id)' IN v_normalized) = 0
     OR position('still_order_applied_residual_gbp' IN v_normalized) = 0
     OR position('corrected_balance_due_gbp' IN v_normalized) = 0
     OR position('tracking_assignment_needed' IN v_normalized) = 0
     OR position('coalesce(si.is_current_for_order, true) = true' IN v_normalized) = 0
     OR position('si.review_status in (''approved_current'', ''ref_corrected_approved'')' IN v_normalized) = 0
     OR position('when p.tracking_assignment_needed then ''assign tracking''' IN v_normalized) = 0
     OR position('else p.corrected_importer_next_action' IN v_normalized) = 0
  THEN
    RAISE EXCEPTION 'Live audience function is no longer the proven 30 July residual/tracking projection; stop before patching.';
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
    -- Existing approved-current tracking-assignment scope: unchanged.
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
  ), pending_review_position AS (
    SELECT
      si.order_id,
      COUNT(*) FILTER (WHERE si.review_status = 'pending_review')::integer AS pending_review_invoice_count,
      COUNT(*) FILTER (
        WHERE si.review_status = 'rejected_resubmit_required'
          AND COALESCE(si.is_current_for_order, true) = true
          AND COALESCE(si.rejection_requires_resubmission_yn, true) = true
      )::integer AS genuine_resubmission_count
    FROM public.supplier_invoices si
    JOIN residual_projected b ON b.order_id = si.order_id
    GROUP BY si.order_id
  ), pending_review_flags AS (
    SELECT
      si.order_id,
      COUNT(*) FILTER (WHERE f.status IN ('open', 'under_review'))::integer AS open_review_flag_count
    FROM public.supplier_invoices si
    JOIN residual_projected b ON b.order_id = si.order_id
    JOIN public.supplier_invoice_review_flags f ON f.supplier_invoice_id = si.id
    WHERE si.review_status IN ('pending_review', 'approved_current', 'ref_corrected_approved')
    GROUP BY si.order_id
  ), importer_line_position AS (
    SELECT
      si.order_id,
      COUNT(*) FILTER (
        WHERE lower(COALESCE(sil.eligible_for_invoice_yn::text, '')) IN ('y', 'yes', 'true', '1')
      )::integer AS progressed_physical_line_count,
      COUNT(*) FILTER (
        WHERE lower(COALESCE(sil.eligible_for_invoice_yn::text, '')) IN ('y', 'yes', 'true', '1')
          AND (sil.qty_confirmed IS NULL OR sil.amount_confirmed IS NULL)
      )::integer AS missing_confirmation_count,
      COUNT(*) FILTER (
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
    JOIN residual_projected b ON b.order_id = si.order_id
    JOIN public.supplier_invoice_lines sil ON sil.supplier_invoice_id = si.id
    WHERE si.review_status IN ('pending_review', 'approved_current', 'ref_corrected_approved')
    GROUP BY si.order_id
  ), importer_physical_position AS (
    SELECT
      si.order_id,
      sil.id AS supplier_invoice_line_id,
      GREATEST(COALESCE(sil.qty_confirmed, sil.qty, 0), 0)::numeric AS required_qty,
      COALESCE(SUM(otla.qty_allocated) FILTER (WHERE ats.id IS NOT NULL), 0)::numeric AS active_tracking_allocated_qty
    FROM public.supplier_invoices si
    JOIN residual_projected b ON b.order_id = si.order_id
    JOIN public.supplier_invoice_lines sil ON sil.supplier_invoice_id = si.id
    LEFT JOIN public.order_tracking_line_allocations otla
      ON otla.order_id = si.order_id
     AND otla.supplier_invoice_line_id = sil.id
     AND otla.tracking_submission_id IS NOT NULL
    LEFT JOIN public.order_tracking_submissions ats
      ON ats.id = otla.tracking_submission_id
     AND ats.order_id = si.order_id
     AND ats.superseded_at IS NULL
    WHERE si.review_status IN ('pending_review', 'approved_current', 'ref_corrected_approved')
      AND lower(COALESCE(sil.eligible_for_invoice_yn::text, '')) IN ('y', 'yes', 'true', '1')
    GROUP BY si.order_id, sil.id, sil.qty_confirmed, sil.qty
  ), importer_assignment_scope AS (
    SELECT
      ipp.order_id,
      COUNT(*) FILTER (
        WHERE ipp.required_qty > 0
          AND ipp.active_tracking_allocated_qty + 0.0005 < ipp.required_qty
      )::integer AS unassigned_physical_line_count
    FROM importer_physical_position ipp
    GROUP BY ipp.order_id
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
      ) AS tracking_assignment_needed,
      COALESCE(prp.pending_review_invoice_count, 0) AS pending_review_invoice_count,
      COALESCE(prp.genuine_resubmission_count, 0) AS genuine_resubmission_count,
      COALESCE(prf.open_review_flag_count, 0) AS open_review_flag_count,
      COALESCE(ilp.progressed_physical_line_count, 0) AS importer_progressed_physical_line_count,
      COALESCE(ilp.missing_confirmation_count, 0) AS importer_missing_confirmation_count,
      COALESCE(ilp.unresolved_line_count, 0) AS importer_unresolved_line_count,
      COALESCE(ias.unassigned_physical_line_count, 0) AS importer_unassigned_physical_line_count,
      COALESCE(at.active_tracking_count, 0) AS active_tracking_count,
      COALESCE(oq.open_query_count, 0) AS open_query_count
    FROM residual_projected b
    LEFT JOIN open_queries oq ON oq.order_id = b.order_id
    LEFT JOIN active_tracking at ON at.order_id = b.order_id
    LEFT JOIN assignment_scope a ON a.order_id = b.order_id
    LEFT JOIN pending_review_position prp ON prp.order_id = b.order_id
    LEFT JOIN pending_review_flags prf ON prf.order_id = b.order_id
    LEFT JOIN importer_line_position ilp ON ilp.order_id = b.order_id
    LEFT JOIN importer_assignment_scope ias ON ias.order_id = b.order_id
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
      -- Preserve the already-working approved-current tracking-assignment projection exactly.
      WHEN p.tracking_assignment_needed THEN 'Assign tracking'

      -- Narrow pending-internal-approval correction only.
      WHEN p.supplier_state = 'review_needed'
       AND p.reconciliation_state = 'complete'
       AND p.corrected_importer_next_action = 'Resolve evidence issue'
       AND COALESCE(p.corrected_balance_due_gbp, 0) <= 0.01
       AND COALESCE(p.internal_current_stage, '') <> 'exception_or_hold_open'
       AND p.pod_delivery_state IS DISTINCT FROM 'accepted_current'
       AND p.pending_review_invoice_count > 0
       AND p.genuine_resubmission_count = 0
       AND p.open_query_count = 0
       AND p.open_review_flag_count = 0
       AND p.importer_unresolved_line_count = 0
       AND p.importer_missing_confirmation_count = 0
       AND p.importer_progressed_physical_line_count > 0
      THEN CASE
        WHEN p.active_tracking_count = 0 THEN 'Add tracking'
        WHEN p.importer_unassigned_physical_line_count > 0 THEN 'Assign tracking'
        ELSE 'No importer action required'
      END

      ELSE p.corrected_importer_next_action
    END::text AS importer_next_action,
    p.shipper_status_label,
    p.shipper_next_action
  FROM tracking_projected p
  ORDER BY p.order_ref;
END;
$$;

-- Prove CREATE OR REPLACE preserved the existing function identity and execution contract.
DO $$
DECLARE
  v_old record;
  v_new record;
BEGIN
  SELECT * INTO v_old FROM _importer_pending_approval_function_contract;

  SELECT
    p.oid,
    p.proowner,
    p.proacl,
    p.prosecdef,
    p.proconfig,
    pg_get_function_result(p.oid) AS result_signature
  INTO v_new
  FROM pg_proc p
  WHERE p.oid = 'public.order_audience_status_v1(uuid)'::regprocedure;

  IF v_new.oid IS DISTINCT FROM v_old.oid
     OR v_new.proowner IS DISTINCT FROM v_old.proowner
     OR v_new.proacl IS DISTINCT FROM v_old.proacl
     OR v_new.prosecdef IS DISTINCT FROM v_old.prosecdef
     OR v_new.proconfig IS DISTINCT FROM v_old.proconfig
     OR v_new.result_signature IS DISTINCT FROM v_old.result_signature
  THEN
    RAISE EXCEPTION 'Function identity/grant/security contract changed; rolling back importer projection patch.';
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';

COMMIT;
