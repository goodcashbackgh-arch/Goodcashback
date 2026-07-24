BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.disputes') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.disputes';
  END IF;
  IF to_regclass('public.customer_pre_shipment_hold_requests') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.customer_pre_shipment_hold_requests';
  END IF;
  IF to_regclass('public.dispute_refund_evidence_submissions') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.dispute_refund_evidence_submissions';
  END IF;
  IF to_regclass('public.dva_statement_line_allocations') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.dva_statement_line_allocations';
  END IF;
  IF to_regclass('public.order_surplus_evidence_position_v3') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.order_surplus_evidence_position_v3';
  END IF;
END $$;

/*
 * Canonical issue lifecycle rule:
 * - a converted hold delegates to its linked dispute;
 * - a refund dispute is economically complete only when approved-current
 *   supplier evidence exists and a confirmed retailer-refund IN allocation exists;
 * - terminal dispute statuses and resolved_at remain authoritative.
 *
 * This is deliberately additive and read-model first. It does not alter funding,
 * statement amounts, allocations, supplier evidence, Sage, VAT or shipment facts.
 */
CREATE OR REPLACE VIEW public.canonical_order_issue_position_v1 AS
WITH refund_evidence AS (
  SELECT
    s.dispute_id,
    bool_or(
      s.supplier_approval_status = 'approved_current'
      AND s.supplier_control_status = 'approved_current'
    ) AS approved_refund_evidence_yn
  FROM public.dispute_refund_evidence_submissions s
  GROUP BY s.dispute_id
), refund_cash AS (
  SELECT
    a.dispute_id,
    bool_or(
      a.allocation_type = 'retailer_refund'
      AND a.allocation_status = 'confirmed'
    ) AS confirmed_refund_in_yn,
    round(COALESCE(sum(a.allocated_gbp_amount) FILTER (
      WHERE a.allocation_type = 'retailer_refund'
        AND a.allocation_status = 'confirmed'
    ), 0), 2) AS confirmed_refund_in_gbp
  FROM public.dva_statement_line_allocations a
  WHERE a.dispute_id IS NOT NULL
  GROUP BY a.dispute_id
), dispute_position AS (
  SELECT
    d.id AS issue_id,
    d.order_id,
    'dispute'::text AS issue_source,
    d.status::text AS raw_status,
    d.desired_outcome::text AS desired_outcome,
    d.resolved_at,
    COALESCE(re.approved_refund_evidence_yn, false) AS approved_refund_evidence_yn,
    COALESCE(rc.confirmed_refund_in_yn, false) AS confirmed_refund_in_yn,
    COALESCE(rc.confirmed_refund_in_gbp, 0)::numeric AS confirmed_refund_in_gbp,
    CASE
      WHEN d.resolved_at IS NOT NULL THEN 'resolved'
      WHEN COALESCE(d.status, '') IN ('closed','resolved','refunded','replaced','closed_no_action') THEN d.status::text
      WHEN d.desired_outcome = 'refund'
       AND COALESCE(re.approved_refund_evidence_yn, false)
       AND COALESCE(rc.confirmed_refund_in_yn, false)
        THEN 'refund_completed'
      ELSE COALESCE(NULLIF(d.status::text, ''), 'open')
    END AS effective_status,
    CASE
      WHEN d.resolved_at IS NOT NULL THEN false
      WHEN COALESCE(d.status, '') IN ('closed','resolved','refunded','replaced','closed_no_action') THEN false
      WHEN d.desired_outcome = 'refund'
       AND COALESCE(re.approved_refund_evidence_yn, false)
       AND COALESCE(rc.confirmed_refund_in_yn, false)
        THEN false
      ELSE true
    END AS is_blocking
  FROM public.disputes d
  LEFT JOIN refund_evidence re ON re.dispute_id = d.id
  LEFT JOIN refund_cash rc ON rc.dispute_id = d.id
), hold_position AS (
  SELECT
    h.id AS issue_id,
    h.order_id,
    'customer_hold'::text AS issue_source,
    h.status::text AS raw_status,
    'hold'::text AS desired_outcome,
    h.resolved_at,
    false AS approved_refund_evidence_yn,
    false AS confirmed_refund_in_yn,
    0::numeric AS confirmed_refund_in_gbp,
    CASE
      WHEN h.resolved_at IS NOT NULL THEN 'resolved'
      WHEN h.superseded_by_hold_request_id IS NOT NULL THEN 'superseded'
      WHEN h.converted_dispute_id IS NOT NULL
       AND COALESCE(dp.is_blocking, false) = false THEN 'converted_issue_completed'
      WHEN h.converted_dispute_id IS NOT NULL THEN 'converted_to_open_issue'
      ELSE COALESCE(NULLIF(h.status::text, ''), 'open')
    END AS effective_status,
    CASE
      WHEN h.resolved_at IS NOT NULL THEN false
      WHEN h.superseded_by_hold_request_id IS NOT NULL THEN false
      WHEN h.converted_dispute_id IS NOT NULL THEN COALESCE(dp.is_blocking, false)
      WHEN COALESCE(h.status, '') IN ('requested','supervisor_approved','converted_to_exception') THEN true
      ELSE false
    END AS is_blocking
  FROM public.customer_pre_shipment_hold_requests h
  LEFT JOIN dispute_position dp ON dp.issue_id = h.converted_dispute_id
)
SELECT * FROM dispute_position
UNION ALL
SELECT * FROM hold_position;

CREATE OR REPLACE VIEW public.canonical_order_issue_blockers_v1 AS
SELECT
  o.id AS order_id,
  count(p.issue_id) FILTER (WHERE p.issue_source = 'dispute' AND p.is_blocking)::integer AS open_dispute_count,
  count(p.issue_id) FILTER (WHERE p.issue_source = 'customer_hold' AND p.is_blocking)::integer AS active_hold_count,
  count(p.issue_id) FILTER (WHERE p.is_blocking)::integer AS blocking_issue_count,
  COALESCE(bool_or(p.is_blocking), false) AS is_blocking,
  COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'issue_id', p.issue_id,
        'issue_source', p.issue_source,
        'raw_status', p.raw_status,
        'effective_status', p.effective_status,
        'desired_outcome', p.desired_outcome
      ) ORDER BY p.issue_source, p.issue_id
    ) FILTER (WHERE p.is_blocking),
    '[]'::jsonb
  ) AS blocker_details
FROM public.orders o
LEFT JOIN public.canonical_order_issue_position_v1 p ON p.order_id = o.id
GROUP BY o.id;

/*
 * Synchronise stale raw lifecycle rows after the canonical completion facts exist.
 * This makes existing platform consumers that already honour resolved_at/terminal
 * dispute statuses automatically follow the latest state without bespoke patches.
 */
CREATE OR REPLACE FUNCTION public.refresh_canonical_issue_resolution_v1(
  p_order_id uuid DEFAULT NULL
)
RETURNS TABLE (
  disputes_resolved integer,
  holds_resolved integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_disputes integer := 0;
  v_holds integer := 0;
BEGIN
  WITH completed AS (
    SELECT p.issue_id
    FROM public.canonical_order_issue_position_v1 p
    WHERE p.issue_source = 'dispute'
      AND p.effective_status = 'refund_completed'
      AND (p_order_id IS NULL OR p.order_id = p_order_id)
  )
  UPDATE public.disputes d
  SET status = 'refunded',
      resolved_at = COALESCE(d.resolved_at, now())
  FROM completed c
  WHERE d.id = c.issue_id
    AND d.resolved_at IS NULL;
  GET DIAGNOSTICS v_disputes = ROW_COUNT;

  UPDATE public.customer_pre_shipment_hold_requests h
  SET resolved_at = COALESCE(h.resolved_at, d.resolved_at, now()),
      updated_at = now()
  FROM public.disputes d
  WHERE h.converted_dispute_id = d.id
    AND d.resolved_at IS NOT NULL
    AND h.resolved_at IS NULL
    AND (p_order_id IS NULL OR h.order_id = p_order_id);
  GET DIAGNOSTICS v_holds = ROW_COUNT;

  RETURN QUERY SELECT v_disputes, v_holds;
END;
$$;

REVOKE ALL ON FUNCTION public.refresh_canonical_issue_resolution_v1(uuid) FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.trg_refresh_canonical_issue_resolution_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order_id uuid;
BEGIN
  IF TG_TABLE_NAME = 'dva_statement_line_allocations' THEN
    SELECT d.order_id INTO v_order_id
    FROM public.disputes d
    WHERE d.id = NEW.dispute_id;
  ELSE
    SELECT d.order_id INTO v_order_id
    FROM public.disputes d
    WHERE d.id = NEW.dispute_id;
  END IF;

  IF v_order_id IS NOT NULL THEN
    PERFORM public.refresh_canonical_issue_resolution_v1(v_order_id);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_refresh_issue_resolution_from_refund_allocation_v1
  ON public.dva_statement_line_allocations;
CREATE TRIGGER trg_refresh_issue_resolution_from_refund_allocation_v1
AFTER INSERT OR UPDATE OF allocation_status, allocation_type, dispute_id
ON public.dva_statement_line_allocations
FOR EACH ROW
WHEN (NEW.dispute_id IS NOT NULL)
EXECUTE FUNCTION public.trg_refresh_canonical_issue_resolution_v1();

DROP TRIGGER IF EXISTS trg_refresh_issue_resolution_from_refund_evidence_v1
  ON public.dispute_refund_evidence_submissions;
CREATE TRIGGER trg_refresh_issue_resolution_from_refund_evidence_v1
AFTER INSERT OR UPDATE OF supplier_approval_status, supplier_control_status
ON public.dispute_refund_evidence_submissions
FOR EACH ROW
EXECUTE FUNCTION public.trg_refresh_canonical_issue_resolution_v1();

/* Backfill existing completed refund lifecycles, including the current order. */
SELECT * FROM public.refresh_canonical_issue_resolution_v1(NULL);

/*
 * Patch only the surplus read model's blocker source. Monetary calculations and
 * status names remain unchanged; it now consumes the canonical blocker decision.
 */
CREATE OR REPLACE VIEW public.order_surplus_evidence_position_v3 AS
WITH pending AS (
  SELECT
    p.order_id,
    round(sum(p.pending_surplus_gbp), 2) AS pending_surplus_gbp,
    count(*)::integer AS pending_position_count,
    count(*) FILTER (WHERE p.status = 'credit_confirmed')::integer AS pending_credit_confirmed_count
  FROM public.order_pending_funding_surplus p
  WHERE p.status = ANY (ARRAY['pending_evidence'::text, 'credit_confirmed'::text])
  GROUP BY p.order_id
), calculated AS (
  SELECT
    v.*,
    COALESCE(p.pending_surplus_gbp, 0::numeric) AS pending_surplus_gbp,
    COALESCE(p.pending_position_count, 0) AS pending_position_count,
    COALESCE(p.pending_credit_confirmed_count, 0) AS pending_credit_confirmed_count,
    round(v.funding_total_gbp + COALESCE(p.pending_surplus_gbp, 0::numeric), 2) AS effective_receipt_gbp,
    round((v.funding_total_gbp + COALESCE(p.pending_surplus_gbp, 0::numeric)) - v.evidence_value_gbp, 2) AS pending_aware_evidence_surplus_gbp,
    COALESCE(b.open_dispute_count, 0) AS canonical_open_dispute_count,
    COALESCE(b.active_hold_count, 0) AS canonical_active_hold_count,
    COALESCE(b.is_blocking, false) AS canonical_is_blocking
  FROM public.order_surplus_evidence_position_v2 v
  LEFT JOIN pending p ON p.order_id = v.order_id
  LEFT JOIN public.canonical_order_issue_blockers_v1 b ON b.order_id = v.order_id
)
SELECT
  order_id,
  order_ref,
  importer_id,
  payment_auth_id,
  declared_order_gbp,
  funding_total_gbp,
  supplier_out_gbp,
  supplier_out_count,
  posted_invoice_gbp,
  posted_invoice_count,
  draft_invoice_gbp,
  draft_invoice_count,
  credit_created_gbp,
  canonical_open_dispute_count AS open_dispute_count,
  canonical_active_hold_count AS active_hold_count,
  evidence_value_gbp,
  CASE WHEN pending_position_count > 0 THEN pending_aware_evidence_surplus_gbp ELSE evidence_surplus_gbp END AS evidence_surplus_gbp,
  CASE
    WHEN pending_position_count = 0 THEN
      CASE WHEN canonical_is_blocking THEN 'blocked_by_open_issue'::text ELSE evidence_status END
    WHEN credit_created_gbp > 0 THEN 'credit_created'::text
    WHEN canonical_is_blocking THEN 'blocked_by_open_issue'::text
    WHEN effective_receipt_gbp <= 0 THEN 'no_confirmed_funding'::text
    WHEN evidence_basis = 'posted_customer_invoice' AND pending_aware_evidence_surplus_gbp > 0 THEN 'ready_posted_invoice_surplus'::text
    WHEN evidence_basis = 'draft_customer_invoice' AND pending_aware_evidence_surplus_gbp > 0 THEN 'ready_draft_invoice_surplus'::text
    WHEN evidence_basis = 'matched_supplier_out' AND pending_aware_evidence_surplus_gbp > 0 THEN 'ready_strong_in_out_surplus'::text
    WHEN evidence_basis = 'matched_supplier_out' THEN 'in_out_no_surplus'::text
    ELSE 'pending_insufficient_evidence'::text
  END AS evidence_status,
  evidence_basis,
  effective_receipt_gbp,
  pending_surplus_gbp,
  pending_position_count,
  pending_credit_confirmed_count
FROM calculated;

GRANT SELECT ON public.canonical_order_issue_position_v1 TO authenticated;
GRANT SELECT ON public.canonical_order_issue_blockers_v1 TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
