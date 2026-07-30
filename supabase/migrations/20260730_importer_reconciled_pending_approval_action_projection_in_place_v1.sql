BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Governing addendum:
-- docs/governing-pack/ui/IMPORTER_RECONCILED_PENDING_APPROVAL_ACTION_PROJECTION_ADDENDUM_v1.md
--
-- One read-model correction only. Patch the live function definition in place by three
-- exact fail-closed substitutions. This preserves the existing function OID, owner,
-- ACL, SECURITY DEFINER boundary, search_path, predecessor chain and every existing
-- projection expression outside the importer-next-action correction governed here.
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
  v_patched text;
  v_result_signature text;
  v_security_definer boolean;
  v_config text[];
  v_old record;
  v_new record;

  v_expected_signature constant text :=
    'TABLE(order_id uuid, order_ref text, raw_order_status text, lifecycle_status text, importer_id uuid, importer_name text, retailer_id uuid, retailer_name text, accepted_estimate_gbp numeric, final_sale_value_gbp numeric, canonical_amount_received_gbp numeric, canonical_balance_due_gbp numeric, potential_credit_pending_review_gbp numeric, internal_current_stage text, internal_current_stage_label text, internal_next_owner text, internal_next_action text, internal_next_href text, internal_status_tone text, gate_complete_count integer, gate_total integer, funding_state text, dva_state text, supplier_state text, reconciliation_state text, tracking_state text, shipment_state text, export_evidence_state text, pod_delivery_state text, customer_sales_state text, shipper_ap_state text, accounting_sage_state text, vat_compliance_state text, internal_complete_yn boolean, customer_complete_yn boolean, importer_complete_yn boolean, shipper_complete_yn boolean, customer_status_label text, customer_next_action text, importer_status_label text, importer_next_action text, shipper_status_label text, shipper_next_action text)';

  v_cte_anchor constant text := $anchor$  ), tracking_projected AS (
$anchor$;

  v_candidate_ctes constant text := $patch$  ), importer_pending_review_candidates AS (
    SELECT b.order_id
    FROM residual_projected b
    WHERE b.supplier_state = 'review_needed'
      AND b.reconciliation_state = 'complete'
      AND b.corrected_importer_next_action = 'Resolve evidence issue'
      AND COALESCE(b.corrected_balance_due_gbp, 0) <= 0.01
      AND COALESCE(b.internal_current_stage, '') <> 'exception_or_hold_open'
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
    JOIN importer_pending_review_candidates c ON c.order_id = si.order_id
    GROUP BY si.order_id
  ), pending_review_flags AS (
    SELECT
      si.order_id,
      COUNT(*) FILTER (WHERE f.status IN ('open', 'under_review'))::integer AS open_review_flag_count
    FROM public.supplier_invoices si
    JOIN importer_pending_review_candidates c ON c.order_id = si.order_id
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
    JOIN importer_pending_review_candidates c ON c.order_id = si.order_id
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
    JOIN importer_pending_review_candidates c ON c.order_id = si.order_id
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
$patch$;

  v_tracking_old constant text := $old$      ) AS tracking_assignment_needed
    FROM residual_projected b
    LEFT JOIN open_queries oq ON oq.order_id = b.order_id
    LEFT JOIN active_tracking at ON at.order_id = b.order_id
    LEFT JOIN assignment_scope a ON a.order_id = b.order_id
  )
$old$;

  v_tracking_new constant text := $new$      ) AS tracking_assignment_needed,
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
$new$;

  v_action_old constant text := $old$    CASE
      WHEN p.tracking_assignment_needed THEN 'Assign tracking'
      ELSE p.corrected_importer_next_action
    END::text AS importer_next_action,
$old$;

  v_action_new constant text := $new$    CASE
      WHEN p.tracking_assignment_needed THEN 'Assign tracking'
      WHEN p.supplier_state = 'review_needed'
       AND p.reconciliation_state = 'complete'
       AND p.corrected_importer_next_action = 'Resolve evidence issue'
       AND COALESCE(p.corrected_balance_due_gbp, 0) <= 0.01
       AND COALESCE(p.internal_current_stage, '') <> 'exception_or_hold_open'
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
$new$;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM _importer_pending_approval_function_contract) THEN
    RAISE EXCEPTION 'Missing public.order_audience_status_v1(uuid)';
  END IF;

  IF to_regclass('public.supplier_invoice_line_resolutions') IS NULL
     OR to_regclass('public.supplier_invoice_review_flags') IS NULL
     OR to_regclass('public.dispute_lines') IS NULL
     OR to_regclass('public.disputes') IS NULL
  THEN
    RAISE EXCEPTION 'Importer pending-approval projection dependency missing; stop before patching.';
  END IF;

  SELECT
    pg_get_functiondef(p.oid),
    lower(regexp_replace(pg_get_functiondef(p.oid), '\s+', ' ', 'g')),
    pg_get_function_result(p.oid),
    p.prosecdef,
    p.proconfig
  INTO
    v_definition,
    v_normalized,
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

  IF position('from public.order_audience_status_pre_receipt_residual_overlay_v1(p_order_id)' IN v_normalized) = 0
     OR position('still_order_applied_residual_gbp' IN v_normalized) = 0
     OR position('corrected_balance_due_gbp' IN v_normalized) = 0
     OR position('tracking_assignment_needed' IN v_normalized) = 0
     OR position('coalesce(si.is_current_for_order, true) = true' IN v_normalized) = 0
     OR position('si.review_status in (''approved_current'', ''ref_corrected_approved'')' IN v_normalized) = 0
     OR position('when p.tracking_assignment_needed then ''assign tracking''' IN v_normalized) = 0
     OR position('else p.corrected_importer_next_action' IN v_normalized) = 0
     OR position('importer_pending_review_candidates' IN v_normalized) > 0
  THEN
    RAISE EXCEPTION 'Live audience function is no longer the unpatched proven 30 July residual/tracking projection; stop before patching.';
  END IF;

  IF length(v_definition) - length(replace(v_definition, v_cte_anchor, '')) <> length(v_cte_anchor)
     OR length(v_definition) - length(replace(v_definition, v_tracking_old, '')) <> length(v_tracking_old)
     OR length(v_definition) - length(replace(v_definition, v_action_old, '')) <> length(v_action_old)
  THEN
    RAISE EXCEPTION 'Expected patch anchors are missing or duplicated; stop before patching.';
  END IF;

  v_patched := replace(v_definition, v_cte_anchor, v_candidate_ctes);
  v_patched := replace(v_patched, v_tracking_old, v_tracking_new);
  v_patched := replace(v_patched, v_action_old, v_action_new);

  IF v_patched IS NOT DISTINCT FROM v_definition THEN
    RAISE EXCEPTION 'Importer projection patch produced no definition change.';
  END IF;

  EXECUTE v_patched;

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
