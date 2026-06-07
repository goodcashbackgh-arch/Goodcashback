BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regprocedure('public.internal_order_final_sale_settlement_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.internal_order_final_sale_settlement_v1(uuid)';
  END IF;
  IF to_regclass('public.supplier_invoices') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoices';
  END IF;
  IF to_regclass('public.supplier_invoice_lines') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoice_lines';
  END IF;
  IF to_regclass('public.supplier_invoice_line_resolutions') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoice_line_resolutions';
  END IF;
  IF to_regclass('public.supplier_invoice_line_accounting_codes') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoice_line_accounting_codes';
  END IF;
  IF to_regclass('public.importer_credit_ledger') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.importer_credit_ledger';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.internal_order_qualifying_net_spend_v1(p_order_id uuid DEFAULT NULL)
RETURNS TABLE (
  order_id uuid,
  order_ref text,
  importer_id uuid,
  final_sale_value_exists boolean,
  final_settlement_state text,
  completion_state text,
  completion_blocker text,
  customer_sales_state text,
  shipment_state text,
  export_evidence_state text,
  pod_delivery_state text,
  exception_state text,
  hold_state text,
  final_balance_due_gbp numeric,
  qualifying_physical_gross_basis_gbp numeric,
  qualifying_adjustment_gross_basis_gbp numeric,
  qualifying_signed_gross_basis_gbp numeric,
  qualifying_net_spend_gbp numeric,
  eligible_physical_line_count integer,
  blocked_line_count integer,
  unresolved_default_n_count integer,
  missing_accounting_coding_count integer,
  non_20_rate_count integer,
  admin_review_required_count integer,
  unresolved_financial_treatment_count integer,
  active_hold_count integer,
  open_dispute_count integer,
  existing_reward_credit_id uuid,
  existing_reward_credit_status text,
  basis_status text,
  basis_blocker text,
  blocker_details_json jsonb,
  source_detail_json jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: qualifying net spend read model requires auth.uid()';
  END IF;

  IF NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff account required for qualifying net spend read model.';
  END IF;

  RETURN QUERY
  WITH settlement AS (
    SELECT s.*
    FROM public.internal_order_final_sale_settlement_v1(p_order_id) s
  ), active_resolutions AS (
    SELECT DISTINCT ON (r.supplier_invoice_line_id)
      r.supplier_invoice_line_id,
      r.id AS resolution_id,
      r.financial_type::text AS financial_type,
      r.amount_gbp::numeric AS resolution_amount_gbp,
      r.resolved_at
    FROM public.supplier_invoice_line_resolutions r
    WHERE r.active = true
      AND r.resolution_type = 'non_physical_financial'
    ORDER BY r.supplier_invoice_line_id, r.resolved_at DESC, r.id DESC
  ), active_dispute_lines AS (
    SELECT DISTINCT dl.supplier_invoice_line_id
    FROM public.dispute_lines dl
    JOIN public.disputes d ON d.id = dl.dispute_id
    WHERE d.resolved_at IS NULL
      AND COALESCE(d.status::text, '') NOT IN ('resolved','closed','rejected','cancelled','superseded')
  ), latest_accounting_codes AS (
    SELECT DISTINCT ON (ac.supplier_invoice_line_id)
      ac.supplier_invoice_line_id,
      ac.id AS accounting_code_id,
      ac.gross_amount_gbp::numeric AS gross_amount_gbp,
      ac.net_amount_gbp::numeric AS net_amount_gbp,
      ac.vat_amount_gbp::numeric AS vat_amount_gbp,
      ac.vat_rate_percent::numeric AS vat_rate_percent,
      ac.tax_rate_id::text AS tax_rate_id,
      ac.tax_rate_label::text AS tax_rate_label,
      ac.admin_review_required_yn::boolean AS admin_review_required_yn,
      ac.review_reason::text AS review_reason,
      ac.coded_at
    FROM public.supplier_invoice_line_accounting_codes ac
    ORDER BY ac.supplier_invoice_line_id, ac.coded_at DESC, ac.id DESC
  ), scoped_lines AS (
    SELECT
      si.order_id,
      sil.id AS supplier_invoice_line_id,
      sil.description::text AS line_description,
      sil.qty::numeric AS qty,
      sil.amount_inc_vat_gbp::numeric AS source_gross_amount_gbp,
      sil.eligible_for_invoice_yn::text AS eligible_for_invoice_yn,
      ar.resolution_id,
      ar.financial_type,
      ar.resolution_amount_gbp,
      adl.supplier_invoice_line_id IS NOT NULL AS active_dispute_link_yn,
      ac.accounting_code_id,
      ac.gross_amount_gbp AS coded_gross_amount_gbp,
      ac.net_amount_gbp AS coded_net_amount_gbp,
      ac.vat_amount_gbp AS coded_vat_amount_gbp,
      ac.vat_rate_percent,
      ac.tax_rate_id,
      ac.tax_rate_label,
      COALESCE(ac.admin_review_required_yn, false) AS admin_review_required_yn,
      ac.review_reason,
      CASE
        WHEN sil.eligible_for_invoice_yn = 'Y' THEN 'physical_product_progressed'
        WHEN sil.eligible_for_invoice_yn = 'N' AND adl.supplier_invoice_line_id IS NOT NULL THEN 'exception_linked'
        WHEN sil.eligible_for_invoice_yn = 'N' AND ar.resolution_id IS NOT NULL THEN 'parked_non_physical'
        ELSE 'unresolved_default_n'
      END::text AS line_state
    FROM public.supplier_invoice_lines sil
    JOIN public.supplier_invoices si ON si.id = sil.supplier_invoice_id
    LEFT JOIN active_resolutions ar ON ar.supplier_invoice_line_id = sil.id
    LEFT JOIN active_dispute_lines adl ON adl.supplier_invoice_line_id = sil.id
    LEFT JOIN latest_accounting_codes ac ON ac.supplier_invoice_line_id = sil.id
    WHERE (p_order_id IS NULL OR si.order_id = p_order_id)
      AND COALESCE(si.review_status::text, '') NOT IN ('rejected_resubmit_required','duplicate_blocked','superseded')
      AND COALESCE(si.is_current_for_order, false) = true
  ), order_line_summary AS (
    SELECT
      sl.order_id,
      COUNT(*) FILTER (WHERE sl.line_state = 'physical_product_progressed')::integer AS eligible_physical_line_count,
      COUNT(*) FILTER (WHERE sl.line_state = 'unresolved_default_n')::integer AS unresolved_default_n_count,
      COUNT(*) FILTER (WHERE sl.line_state = 'physical_product_progressed' AND sl.accounting_code_id IS NULL)::integer AS missing_accounting_coding_count,
      COUNT(*) FILTER (
        WHERE sl.line_state = 'physical_product_progressed'
          AND sl.accounting_code_id IS NOT NULL
          AND COALESCE(sl.vat_rate_percent, -1) <> 20
      )::integer AS non_20_rate_count,
      COUNT(*) FILTER (
        WHERE sl.line_state = 'physical_product_progressed'
          AND sl.accounting_code_id IS NOT NULL
          AND COALESCE(sl.admin_review_required_yn, false) = true
      )::integer AS admin_review_required_count,
      COUNT(*) FILTER (
        WHERE sl.line_state = 'parked_non_physical'
          AND COALESCE(sl.source_gross_amount_gbp, sl.resolution_amount_gbp, 0) <> 0
          AND COALESCE(sl.financial_type, '') <> 'zero_value_delivery'
      )::integer AS unresolved_financial_treatment_count,
      COALESCE(SUM(
        CASE
          WHEN sl.line_state = 'physical_product_progressed'
           AND sl.accounting_code_id IS NOT NULL
           AND COALESCE(sl.vat_rate_percent, -1) = 20
           AND COALESCE(sl.admin_review_required_yn, false) = false
          THEN COALESCE(sl.coded_gross_amount_gbp, 0)
          ELSE 0
        END
      ), 0)::numeric AS qualifying_physical_gross_basis_gbp,
      jsonb_agg(
        jsonb_build_object(
          'supplier_invoice_line_id', sl.supplier_invoice_line_id,
          'description', sl.line_description,
          'qty', sl.qty,
          'source_gross_amount_gbp', sl.source_gross_amount_gbp,
          'line_state', sl.line_state,
          'financial_type', sl.financial_type,
          'accounting_code_id', sl.accounting_code_id,
          'coded_gross_amount_gbp', sl.coded_gross_amount_gbp,
          'vat_rate_percent', sl.vat_rate_percent,
          'admin_review_required_yn', sl.admin_review_required_yn,
          'review_reason', sl.review_reason
        )
        ORDER BY sl.line_description, sl.supplier_invoice_line_id
      ) AS line_detail_json
    FROM scoped_lines sl
    GROUP BY sl.order_id
  ), order_controls AS (
    SELECT
      s.order_id,
      COALESCE((
        SELECT COUNT(*)::integer
        FROM public.customer_pre_shipment_hold_requests h
        WHERE h.order_id = s.order_id
          AND h.status IN ('requested','supervisor_approved')
      ), 0) AS active_hold_count,
      COALESCE((
        SELECT COUNT(*)::integer
        FROM public.disputes d
        WHERE d.order_id = s.order_id
          AND d.resolved_at IS NULL
          AND COALESCE(d.status::text, '') NOT IN ('resolved','closed','rejected','cancelled','superseded')
      ), 0) AS open_dispute_count,
      (
        SELECT icl.id
        FROM public.importer_credit_ledger icl
        WHERE icl.source_type = 'completion_loyalty_reward'
          AND icl.source_entity_type = 'order'
          AND icl.source_entity_id = s.order_id
        ORDER BY icl.created_at DESC, icl.id DESC
        LIMIT 1
      ) AS existing_reward_credit_id,
      (
        SELECT CASE WHEN icl.lock_reason IS NULL THEN 'unlocked_available' ELSE 'locked_' || icl.lock_reason END
        FROM public.importer_credit_ledger icl
        WHERE icl.source_type = 'completion_loyalty_reward'
          AND icl.source_entity_type = 'order'
          AND icl.source_entity_id = s.order_id
        ORDER BY icl.created_at DESC, icl.id DESC
        LIMIT 1
      )::text AS existing_reward_credit_status
    FROM settlement s
  ), joined AS (
    SELECT
      s.order_id,
      s.order_ref,
      s.importer_id,
      s.final_sale_value_exists,
      s.final_settlement_state,
      s.completion_state,
      s.completion_blocker,
      s.customer_sales_state,
      s.shipment_state,
      s.export_evidence_state,
      s.pod_delivery_state,
      s.exception_state,
      s.hold_state,
      s.final_balance_due_gbp,
      COALESCE(ols.qualifying_physical_gross_basis_gbp, 0)::numeric AS qualifying_physical_gross_basis_gbp,
      0::numeric AS qualifying_adjustment_gross_basis_gbp,
      COALESCE(ols.eligible_physical_line_count, 0)::integer AS eligible_physical_line_count,
      COALESCE(ols.unresolved_default_n_count, 0)::integer AS unresolved_default_n_count,
      COALESCE(ols.missing_accounting_coding_count, 0)::integer AS missing_accounting_coding_count,
      COALESCE(ols.non_20_rate_count, 0)::integer AS non_20_rate_count,
      COALESCE(ols.admin_review_required_count, 0)::integer AS admin_review_required_count,
      COALESCE(ols.unresolved_financial_treatment_count, 0)::integer AS unresolved_financial_treatment_count,
      COALESCE(oc.active_hold_count, 0)::integer AS active_hold_count,
      COALESCE(oc.open_dispute_count, 0)::integer AS open_dispute_count,
      oc.existing_reward_credit_id,
      oc.existing_reward_credit_status,
      COALESCE(ols.line_detail_json, '[]'::jsonb) AS line_detail_json
    FROM settlement s
    LEFT JOIN order_line_summary ols ON ols.order_id = s.order_id
    LEFT JOIN order_controls oc ON oc.order_id = s.order_id
  ), evaluated AS (
    SELECT
      j.*,
      (j.qualifying_physical_gross_basis_gbp + j.qualifying_adjustment_gross_basis_gbp)::numeric AS qualifying_signed_gross_basis_gbp,
      (
        COALESCE(j.unresolved_default_n_count, 0)
        + COALESCE(j.missing_accounting_coding_count, 0)
        + COALESCE(j.non_20_rate_count, 0)
        + COALESCE(j.admin_review_required_count, 0)
        + COALESCE(j.unresolved_financial_treatment_count, 0)
      )::integer AS blocked_line_count,
      CASE
        WHEN j.final_sale_value_exists IS DISTINCT FROM true THEN 'final_sale_documents_missing'
        WHEN COALESCE(j.customer_sales_state, '') = 'partial_posted' THEN 'partial_customer_sale_or_partial_coverage'
        WHEN COALESCE(j.completion_state, '') <> 'complete' THEN COALESCE(j.completion_blocker, 'completion_not_complete')
        WHEN COALESCE(j.final_balance_due_gbp, 0) > 0 THEN 'final_balance_due'
        WHEN COALESCE(j.active_hold_count, 0) > 0 THEN 'active_customer_hold'
        WHEN COALESCE(j.open_dispute_count, 0) > 0 THEN 'open_exception_or_dispute'
        WHEN COALESCE(j.existing_reward_credit_id::text, '') <> '' THEN 'completion_loyalty_reward_already_exists'
        WHEN COALESCE(j.eligible_physical_line_count, 0) = 0 THEN 'no_qualifying_physical_lines'
        WHEN COALESCE(j.unresolved_default_n_count, 0) > 0 THEN 'unresolved_default_n_supplier_lines'
        WHEN COALESCE(j.missing_accounting_coding_count, 0) > 0 THEN 'missing_supplier_accounting_coding'
        WHEN COALESCE(j.non_20_rate_count, 0) > 0 THEN 'non_20_percent_or_unknown_rate'
        WHEN COALESCE(j.admin_review_required_count, 0) > 0 THEN 'supplier_accounting_admin_review_required'
        WHEN COALESCE(j.unresolved_financial_treatment_count, 0) > 0 THEN 'unresolved_delivery_discount_fee_treatment'
        WHEN (j.qualifying_physical_gross_basis_gbp + j.qualifying_adjustment_gross_basis_gbp) <= 0 THEN 'qualifying_basis_zero_or_negative'
        ELSE NULL
      END::text AS basis_blocker
    FROM joined j
  )
  SELECT
    e.order_id,
    e.order_ref::text,
    e.importer_id,
    e.final_sale_value_exists,
    e.final_settlement_state::text,
    e.completion_state::text,
    e.completion_blocker::text,
    e.customer_sales_state::text,
    e.shipment_state::text,
    e.export_evidence_state::text,
    e.pod_delivery_state::text,
    e.exception_state::text,
    e.hold_state::text,
    COALESCE(e.final_balance_due_gbp, 0)::numeric,
    e.qualifying_physical_gross_basis_gbp,
    e.qualifying_adjustment_gross_basis_gbp,
    e.qualifying_signed_gross_basis_gbp,
    CASE WHEN e.basis_blocker IS NULL THEN ROUND(e.qualifying_signed_gross_basis_gbp / 1.20, 2) ELSE 0::numeric END AS qualifying_net_spend_gbp,
    e.eligible_physical_line_count,
    e.blocked_line_count,
    e.unresolved_default_n_count,
    e.missing_accounting_coding_count,
    e.non_20_rate_count,
    e.admin_review_required_count,
    e.unresolved_financial_treatment_count,
    e.active_hold_count,
    e.open_dispute_count,
    e.existing_reward_credit_id,
    COALESCE(e.existing_reward_credit_status, 'none')::text,
    CASE WHEN e.basis_blocker IS NULL THEN 'ready' ELSE 'blocked' END::text AS basis_status,
    e.basis_blocker,
    jsonb_build_object(
      'final_sale_value_exists', e.final_sale_value_exists,
      'final_settlement_state', e.final_settlement_state,
      'completion_state', e.completion_state,
      'completion_blocker', e.completion_blocker,
      'final_balance_due_gbp', COALESCE(e.final_balance_due_gbp, 0),
      'eligible_physical_line_count', e.eligible_physical_line_count,
      'unresolved_default_n_count', e.unresolved_default_n_count,
      'missing_accounting_coding_count', e.missing_accounting_coding_count,
      'non_20_rate_count', e.non_20_rate_count,
      'admin_review_required_count', e.admin_review_required_count,
      'unresolved_financial_treatment_count', e.unresolved_financial_treatment_count,
      'active_hold_count', e.active_hold_count,
      'open_dispute_count', e.open_dispute_count,
      'existing_reward_credit_id', e.existing_reward_credit_id
    ) AS blocker_details_json,
    jsonb_build_object(
      'source', 'internal_order_qualifying_net_spend_v1',
      'basis_rule', 'qualifying_net_spend_gbp = qualifying_signed_gross_basis_gbp / 1.20 only when basis_status = ready',
      'physical_gross_basis_source', 'latest supplier_invoice_line_accounting_codes gross_amount_gbp for progressed Y lines coded at 20 percent with no admin review flag',
      'adjustments_status', 'non-physical delivery/discount/fee adjustments block unless explicitly classified and safely treatable by a later enhancement',
      'lines', e.line_detail_json
    ) AS source_detail_json
  FROM evaluated e
  ORDER BY e.order_ref;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_order_qualifying_net_spend_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_order_qualifying_net_spend_v1(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
