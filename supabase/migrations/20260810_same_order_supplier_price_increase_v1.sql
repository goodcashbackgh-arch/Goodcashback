BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Governed by:
-- docs/governing-pack/architecture/SAME_ORDER_SUPPLIER_PRICE_INCREASE_ADDENDUM_v1.md
-- docs/governing-pack/architecture/SAME_ORDER_SUPPLIER_PRICE_INCREASE_VERIFIED_BUNDLE_CLARIFICATION_v1.md
--
-- This migration is deliberately additive. It does not replace the existing
-- header-review RPC, supplier-approval RPC, funding functions, supplier-payment
-- functions, Build 4 reconciliation, VAT, Sage, shipping, tracking or replacement
-- authorities.

DO $preflight$
DECLARE
  v_md5 text;
BEGIN
  IF to_regclass('public.orders') IS NULL
     OR to_regclass('public.supplier_invoices') IS NULL
     OR to_regclass('public.supplier_invoice_review_flags') IS NULL
     OR to_regclass('public.supplier_invoice_accounting_coding_totals_vw') IS NULL
     OR to_regclass('public.supplier_invoice_match_decision_vw') IS NULL
     OR to_regclass('public.order_funding_position_vw') IS NULL
     OR to_regclass('public.order_funding_events') IS NULL
     OR to_regclass('public.importer_credit_ledger') IS NULL
     OR to_regclass('public.order_pending_funding_surplus') IS NULL THEN
    RAISE EXCEPTION 'Same-order price-increase prerequisite relation/view is missing.';
  END IF;

  IF to_regprocedure('public.staff_save_supplier_invoice_header_review(uuid,text,text,text,date,numeric,numeric,numeric,text)') IS NULL THEN
    RAISE EXCEPTION 'Expected current nine-argument supplier header-review RPC is missing.';
  END IF;
  IF to_regprocedure('public.staff_approve_supplier_invoice_current(uuid,text,text,text,date,numeric,text)') IS NULL THEN
    RAISE EXCEPTION 'Expected supplier-invoice approval RPC is missing.';
  END IF;
  IF to_regprocedure('public.order_funding_total_gbp(uuid)') IS NULL
     OR to_regprocedure('public.order_funding_gap_gbp(uuid)') IS NULL
     OR to_regprocedure('public.recompute_order_platform_funded(uuid)') IS NULL
     OR to_regprocedure('public.sync_order_overfunding_credit(uuid)') IS NULL
     OR to_regprocedure('public.enforce_order_locks()') IS NULL THEN
    RAISE EXCEPTION 'Established funding/order-lock authority is missing.';
  END IF;

  -- Live fingerprints gathered during the pre-build dependency audit. Abort on
  -- drift rather than silently modifying a database whose governing authorities
  -- no longer match the reviewed state.
  SELECT md5(pg_get_functiondef('public.staff_save_supplier_invoice_header_review(uuid,text,text,text,date,numeric,numeric,numeric,text)'::regprocedure))
    INTO v_md5;
  IF v_md5 IS DISTINCT FROM '44719b0f9a435f01ea138e1cca6a034e' THEN
    RAISE EXCEPTION 'Drift stop: supplier header-review RPC changed (%). No changes applied.', v_md5;
  END IF;

  SELECT md5(pg_get_functiondef('public.enforce_order_locks()'::regprocedure)) INTO v_md5;
  IF v_md5 IS DISTINCT FROM '497230d0cf04001f37c5e805cdd8da25' THEN
    RAISE EXCEPTION 'Drift stop: enforce_order_locks changed (%). No changes applied.', v_md5;
  END IF;

  SELECT md5(pg_get_functiondef('public.order_funding_total_gbp(uuid)'::regprocedure)) INTO v_md5;
  IF v_md5 IS DISTINCT FROM '7f71d968c6662c1df535a50428797fb4' THEN
    RAISE EXCEPTION 'Drift stop: order_funding_total_gbp changed (%). No changes applied.', v_md5;
  END IF;

  SELECT md5(pg_get_functiondef('public.order_funding_gap_gbp(uuid)'::regprocedure)) INTO v_md5;
  IF v_md5 IS DISTINCT FROM '8c2ce167a7012ee50b98d9886c455454' THEN
    RAISE EXCEPTION 'Drift stop: order_funding_gap_gbp changed (%). No changes applied.', v_md5;
  END IF;

  SELECT md5(pg_get_functiondef('public.recompute_order_platform_funded(uuid)'::regprocedure)) INTO v_md5;
  IF v_md5 IS DISTINCT FROM 'cfd3c7bca289b26e748a00c8170a3a9b' THEN
    RAISE EXCEPTION 'Drift stop: recompute_order_platform_funded changed (%). No changes applied.', v_md5;
  END IF;

  SELECT md5(pg_get_functiondef('public.sync_order_overfunding_credit(uuid)'::regprocedure)) INTO v_md5;
  IF v_md5 IS DISTINCT FROM 'f2dcd920585c696b59c80b8baab220b8' THEN
    RAISE EXCEPTION 'Drift stop: sync_order_overfunding_credit changed (%). No changes applied.', v_md5;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'supplier_invoice_accounting_coding_totals_vw'
      AND column_name = 'accepted_invoice_gross_gbp'
  ) THEN
    RAISE EXCEPTION 'Accepted supplier gross authority is missing.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'order_funding_position_vw'
      AND column_name IN ('funded_total_gbp','gap_remaining_gbp','threshold_met_yn','already_funded_yn')
    GROUP BY table_schema, table_name
    HAVING COUNT(*) = 4
  ) THEN
    RAISE EXCEPTION 'Funding-position view does not expose the reviewed authority columns.';
  END IF;
END
$preflight$;

-- One read-only live commercial position. Accepted supplier gross is reused from
-- the established accounting totals view; no second gross hierarchy is created.
CREATE OR REPLACE VIEW public.order_supplier_price_position_v1
WITH (security_invoker = true)
AS
WITH active_invoices AS (
  SELECT
    si.order_id,
    si.id AS supplier_invoice_id,
    si.uploaded_at,
    COALESCE(si.review_status, 'pending_review')::text AS review_status,
    totals.accepted_invoice_gross_gbp::numeric AS accepted_invoice_gross_gbp,
    md.retailer_match_yn,
    md.invoice_ref_match_yn,
    md.total_match_yn,
    COALESCE(md.ocr_line_count, 0)::integer AS ocr_line_count,
    COALESCE(md.pending_adjustment_yn, false) AS pending_adjustment_yn,
    EXISTS (
      SELECT 1
      FROM public.supplier_invoice_review_flags f
      WHERE f.supplier_invoice_id = si.id
        AND f.status IN ('open','under_review')
        AND f.flag_type <> 'order_bundle_limit_breach'
    ) AS non_bundle_review_flag_yn
  FROM public.supplier_invoices si
  LEFT JOIN public.supplier_invoice_accounting_coding_totals_vw totals
    ON totals.supplier_invoice_id = si.id
  LEFT JOIN public.supplier_invoice_match_decision_vw md
    ON md.supplier_invoice_id = si.id
  WHERE COALESCE(si.review_status, 'pending_review') NOT IN (
    'rejected_resubmit_required',
    'duplicate_blocked',
    'superseded'
  )
), classified AS (
  SELECT
    ai.*,
    CASE
      WHEN ai.review_status IN ('approved_current','ref_corrected_approved') THEN true
      WHEN ai.review_status = 'pending_review'
        AND ai.retailer_match_yn IS TRUE
        AND ai.invoice_ref_match_yn IS TRUE
        AND ai.total_match_yn IS TRUE
        AND ai.ocr_line_count > 0
        AND ai.pending_adjustment_yn IS FALSE
        AND ai.non_bundle_review_flag_yn IS FALSE
      THEN true
      ELSE false
    END AS price_verified_yn
  FROM active_invoices ai
), aggregated AS (
  SELECT
    c.order_id,
    COUNT(*)::integer AS active_invoice_count,
    COUNT(*) FILTER (WHERE c.accepted_invoice_gross_gbp IS NULL)::integer AS missing_accepted_total_count,
    COUNT(*) FILTER (WHERE c.price_verified_yn IS FALSE)::integer AS unverified_invoice_count,
    ROUND(COALESCE(SUM(c.accepted_invoice_gross_gbp), 0)::numeric, 2) AS accepted_supplier_bundle_gbp,
    (
      ARRAY_AGG(
        c.supplier_invoice_id
        ORDER BY c.uploaded_at DESC NULLS LAST, c.supplier_invoice_id DESC
      ) FILTER (WHERE c.review_status = 'pending_review')
    )[1] AS review_anchor_supplier_invoice_id
  FROM classified c
  GROUP BY c.order_id
)
SELECT
  o.id AS order_id,
  COALESCE(o.order_type, 'original')::text AS order_type,
  ROUND(COALESCE(o.order_total_gbp_declared, 0)::numeric, 2) AS current_order_value_gbp,
  COALESCE(a.accepted_supplier_bundle_gbp, 0)::numeric(12,2) AS accepted_supplier_bundle_gbp,
  ROUND(GREATEST(
    COALESCE(a.accepted_supplier_bundle_gbp, 0)
      - COALESCE(o.order_total_gbp_declared, 0),
    0
  )::numeric, 2) AS price_increase_required_gbp,
  (
    COALESCE(a.accepted_supplier_bundle_gbp, 0)
      > COALESCE(o.order_total_gbp_declared, 0) + 0.01
  ) AS over_limit_yn,
  COALESCE(a.active_invoice_count, 0)::integer AS active_invoice_count,
  COALESCE(a.missing_accepted_total_count, 0)::integer AS missing_accepted_total_count,
  COALESCE(a.unverified_invoice_count, 0)::integer AS unverified_invoice_count,
  a.review_anchor_supplier_invoice_id,
  now() AS last_refreshed_at
FROM public.orders o
LEFT JOIN aggregated a ON a.order_id = o.id;

COMMENT ON VIEW public.order_supplier_price_position_v1 IS
'Live same-order supplier price position. Reuses accepted_invoice_gross_gbp, excludes retired supplier invoices, surfaces one deterministic pending-review anchor, and distinguishes known over-limit value from price-verification readiness.';

REVOKE ALL ON public.order_supplier_price_position_v1 FROM PUBLIC, anon;
GRANT SELECT ON public.order_supplier_price_position_v1 TO authenticated, service_role;

-- Additive database backstop. Existing approval RPCs are untouched. The trigger
-- fires after the invoice UPDATE so the live position includes any accepted gross
-- supplied by that same approval statement. Raising here rolls the whole approval
-- transaction back before its later flag-resolution statement can commit.
CREATE OR REPLACE FUNCTION public.enforce_supplier_invoice_order_price_limit_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order record;
  v_position record;
BEGIN
  IF COALESCE(NEW.review_status, '') NOT IN ('approved_current','ref_corrected_approved')
     OR COALESCE(NEW.blocked_from_sage_yn, true) = true THEN
    RETURN NEW;
  END IF;

  SELECT
    o.id,
    COALESCE(o.order_type, 'original')::text AS order_type,
    ROUND(COALESCE(o.order_total_gbp_declared, 0)::numeric, 2) AS order_total_gbp_declared
  INTO v_order
  FROM public.orders o
  WHERE o.id = NEW.order_id
  FOR UPDATE;

  IF v_order.id IS NULL OR v_order.order_type <> 'original' THEN
    RETURN NEW;
  END IF;

  SELECT p.*
  INTO v_position
  FROM public.order_supplier_price_position_v1 p
  WHERE p.order_id = NEW.order_id;

  IF COALESCE(v_position.accepted_supplier_bundle_gbp, 0)
       > v_order.order_total_gbp_declared + 0.01 THEN
    RAISE EXCEPTION
      'Supplier invoice approval blocked: live accepted supplier bundle GBP % exceeds accepted order value GBP %. Approve the order price increase first.',
      v_position.accepted_supplier_bundle_gbp,
      v_order.order_total_gbp_declared;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_supplier_invoice_order_price_limit_v1
  ON public.supplier_invoices;
CREATE TRIGGER trg_enforce_supplier_invoice_order_price_limit_v1
AFTER UPDATE OF order_id, review_status, blocked_from_sage_yn, ocr_invoice_total_gbp, ocr_raw_json
ON public.supplier_invoices
FOR EACH ROW
EXECUTE FUNCTION public.enforce_supplier_invoice_order_price_limit_v1();

REVOKE ALL ON FUNCTION public.enforce_supplier_invoice_order_price_limit_v1() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.staff_approve_order_supplier_price_increase_v1(
  p_order_id uuid,
  p_review_notes text DEFAULT NULL
)
RETURNS TABLE(
  order_id uuid,
  old_order_value_gbp numeric,
  new_order_value_gbp numeric,
  increase_gbp numeric,
  funding_total_gbp numeric,
  funding_gap_gbp numeric,
  funded_at timestamptz,
  quote_total_ghs numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff record;
  v_order public.orders%ROWTYPE;
  v_position record;
  v_funding_before record;
  v_funding_after record;
  v_old_total numeric(12,2);
  v_new_total numeric(12,2);
  v_increase numeric(12,2);
  v_event_total numeric(12,2);
  v_event_gap_before numeric(12,2);
  v_expected_gap_after numeric(12,2);
  v_new_quote_total_ghs numeric;
  v_event_count_before bigint;
  v_event_count_after bigint;
  v_expected_threshold_before boolean;
  v_expected_threshold_after boolean;
  v_notes text := NULLIF(btrim(COALESCE(p_review_notes, '')), '');
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user.';
  END IF;

  SELECT s.id, s.role_type::text
  INTO v_staff
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND COALESCE(s.active, true) = true
  LIMIT 1;

  IF v_staff.id IS NULL OR v_staff.role_type NOT IN ('admin','supervisor') THEN
    RAISE EXCEPTION 'Only an active admin or supervisor can approve an order price increase.';
  END IF;

  -- Match the established invoice-first lock order. Lock live supplier invoices
  -- deterministically before the order row so this new action does not invert the
  -- canonical supplier-approval path.
  PERFORM 1
  FROM public.supplier_invoices si
  WHERE si.order_id = p_order_id
    AND COALESCE(si.review_status, 'pending_review') NOT IN (
      'rejected_resubmit_required','duplicate_blocked','superseded'
    )
  ORDER BY si.id
  FOR UPDATE;

  -- Freeze existing operator/supervisor financial-summary values as well. This
  -- serialises a concurrent delivery/discount total correction without modifying
  -- that established action.
  PERFORM 1
  FROM public.supplier_invoice_financial_summary fs
  JOIN public.supplier_invoices si ON si.id = fs.supplier_invoice_id
  WHERE si.order_id = p_order_id
    AND COALESCE(si.review_status, 'pending_review') NOT IN (
      'rejected_resubmit_required','duplicate_blocked','superseded'
    )
  ORDER BY fs.id
  FOR UPDATE OF fs;

  SELECT *
  INTO v_order
  FROM public.orders o
  WHERE o.id = p_order_id
  FOR UPDATE;

  IF v_order.id IS NULL THEN
    RAISE EXCEPTION 'Order not found.';
  END IF;
  IF COALESCE(v_order.order_type, 'original') <> 'original' THEN
    RAISE EXCEPTION 'Same-order supplier price increase is only available for original orders.';
  END IF;
  IF v_order.content_locked_at IS NOT NULL THEN
    RAISE EXCEPTION 'Order content is locked (content_locked_at set). Price increase not applied.';
  END IF;
  IF COALESCE(v_order.status::text, '') IN ('archived','cancelled','completed') THEN
    RAISE EXCEPTION 'Cannot increase the price of a terminal order with status %.', v_order.status;
  END IF;
  IF ABS(COALESCE(v_order.markup_applied_gbp, 0)) > 0.005 THEN
    RAISE EXCEPTION 'Price increase v1 requires zero order markup because live funding authorities use different markup thresholds.';
  END IF;

  -- Lock existing funding-side rows that this action validates. The action does
  -- not edit these rows; locks only prevent a concurrent funding/credit decision
  -- from changing the precondition halfway through the amendment.
  PERFORM 1
  FROM public.order_funding_events ofe
  WHERE ofe.order_id = p_order_id
  ORDER BY ofe.created_at, ofe.id
  FOR UPDATE;

  PERFORM 1
  FROM public.importer_credit_ledger icl
  WHERE icl.importer_id = v_order.importer_id
    AND (
      icl.linked_order_id = p_order_id
      OR icl.applied_to_order_id = p_order_id
      OR (
        icl.source_type = 'overfunding'
        AND icl.source_entity_type = 'order'
        AND icl.source_entity_id = p_order_id
      )
    )
  ORDER BY icl.id
  FOR UPDATE;

  PERFORM 1
  FROM public.order_pending_funding_surplus ps
  WHERE ps.order_id = p_order_id
    AND ps.status IN ('pending_evidence','credit_confirmed')
  ORDER BY ps.created_at, ps.id
  FOR UPDATE;

  SELECT p.*
  INTO v_position
  FROM public.order_supplier_price_position_v1 p
  WHERE p.order_id = p_order_id;

  IF v_position.order_id IS NULL OR COALESCE(v_position.active_invoice_count, 0) = 0 THEN
    RAISE EXCEPTION 'No live supplier invoice bundle exists for this order.';
  END IF;
  IF COALESCE(v_position.missing_accepted_total_count, 0) <> 0 THEN
    RAISE EXCEPTION 'Price increase blocked: % live supplier invoice(s) have no accepted gross total.', v_position.missing_accepted_total_count;
  END IF;
  IF COALESCE(v_position.unverified_invoice_count, 0) <> 0 THEN
    RAISE EXCEPTION 'Price increase blocked: % live supplier invoice(s) still need ordinary document/adjustment verification.', v_position.unverified_invoice_count;
  END IF;

  v_old_total := ROUND(COALESCE(v_order.order_total_gbp_declared, 0)::numeric, 2);
  v_new_total := ROUND(COALESCE(v_position.accepted_supplier_bundle_gbp, 0)::numeric, 2);
  v_increase := ROUND((v_new_total - v_old_total)::numeric, 2);

  IF v_new_total <= v_old_total + 0.01 OR v_increase <= 0.01 THEN
    RAISE EXCEPTION 'No live supplier price increase is currently required. Order GBP %, live bundle GBP %.', v_old_total, v_new_total;
  END IF;

  -- Do not run the existing overfunding synchroniser across reversal history in
  -- this v1: its historical summation semantics differ from the canonical helper.
  IF EXISTS (
    SELECT 1
    FROM public.order_funding_events ofe
    WHERE ofe.order_id = p_order_id
      AND ofe.event_type = 'funding_reversed'
  ) THEN
    RAISE EXCEPTION 'Price increase v1 is blocked for orders with funding-reversal history. No funding authority was changed.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.importer_credit_ledger icl
    WHERE icl.source_type = 'overfunding'
      AND icl.source_entity_type = 'order'
      AND icl.source_entity_id = p_order_id
  ) THEN
    RAISE EXCEPTION 'Price increase blocked: existing order-sourced overfunding credit must be resolved separately.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.order_pending_funding_surplus ps
    WHERE ps.order_id = p_order_id
      AND ps.status IN ('pending_evidence','credit_confirmed')
  ) THEN
    RAISE EXCEPTION 'Price increase blocked: this order has an active pending/confirmed funding-surplus position.';
  END IF;

  v_event_total := ROUND(COALESCE(public.order_funding_total_gbp(p_order_id), 0)::numeric, 2);
  v_event_gap_before := ROUND(GREATEST(v_old_total - v_event_total, 0)::numeric, 2);
  v_expected_threshold_before := v_event_total >= v_old_total - 0.01;

  SELECT f.*
  INTO v_funding_before
  FROM public.order_funding_position_vw f
  WHERE f.order_id = p_order_id;

  IF v_funding_before.order_id IS NULL THEN
    RAISE EXCEPTION 'Price increase blocked: live funding position is missing.';
  END IF;

  IF ABS(COALESCE(v_funding_before.funded_total_gbp, 0) - v_event_total) > 0.01
     OR ABS(COALESCE(v_funding_before.gap_remaining_gbp, 0) - v_event_gap_before) > 0.01
     OR v_funding_before.threshold_met_yn IS DISTINCT FROM v_expected_threshold_before
     OR v_funding_before.already_funded_yn IS DISTINCT FROM (v_order.funded_at IS NOT NULL)
     OR (v_order.funded_at IS NOT NULL) IS DISTINCT FROM v_expected_threshold_before THEN
    RAISE EXCEPTION
      'Price increase blocked: target order funding authorities disagree (event total %, view total %, event gap %, view gap %, funded_at %, threshold_met %).',
      v_event_total,
      v_funding_before.funded_total_gbp,
      v_event_gap_before,
      v_funding_before.gap_remaining_gbp,
      (v_order.funded_at IS NOT NULL),
      v_funding_before.threshold_met_yn;
  END IF;

  IF v_event_total > v_old_total + 0.01 THEN
    RAISE EXCEPTION 'Price increase blocked: funding already exceeds the current order value and must be resolved through existing overfunding controls first.';
  END IF;

  SELECT COUNT(*)
  INTO v_event_count_before
  FROM public.order_funding_events ofe
  WHERE ofe.order_id = p_order_id;

  v_new_quote_total_ghs := v_order.quote_total_ghs;
  IF v_old_total > 0
     AND COALESCE(v_order.quote_total_ghs, 0) > 0 THEN
    v_new_quote_total_ghs := ROUND(
      (v_order.quote_total_ghs / v_old_total) * v_new_total,
      2
    );
  END IF;

  UPDATE public.orders o
  SET
    order_total_gbp_declared = v_new_total,
    quote_total_ghs = v_new_quote_total_ghs,
    updated_at = now()
  WHERE o.id = p_order_id;

  -- Existing authority; do not restamp funding directly here.
  PERFORM public.recompute_order_platform_funded(p_order_id);
  PERFORM public.sync_order_overfunding_credit(p_order_id);

  v_expected_gap_after := ROUND(GREATEST(v_new_total - v_event_total, 0)::numeric, 2);
  v_expected_threshold_after := v_event_total >= v_new_total - 0.01;

  SELECT f.*
  INTO v_funding_after
  FROM public.order_funding_position_vw f
  WHERE f.order_id = p_order_id;

  SELECT COUNT(*)
  INTO v_event_count_after
  FROM public.order_funding_events ofe
  WHERE ofe.order_id = p_order_id;

  IF v_event_count_after <> v_event_count_before THEN
    RAISE EXCEPTION 'Price amendment unexpectedly created or removed an order funding event. Transaction rolled back.';
  END IF;

  IF ABS(COALESCE(v_funding_after.funded_total_gbp, 0) - v_event_total) > 0.01
     OR ABS(COALESCE(v_funding_after.gap_remaining_gbp, 0) - v_expected_gap_after) > 0.01
     OR v_funding_after.threshold_met_yn IS DISTINCT FROM v_expected_threshold_after
     OR v_funding_after.already_funded_yn IS DISTINCT FROM v_expected_threshold_after THEN
    RAISE EXCEPTION
      'Price amendment postcondition failed (expected gap %, view gap %, threshold expected %, threshold actual %, funded actual %). Transaction rolled back.',
      v_expected_gap_after,
      v_funding_after.gap_remaining_gbp,
      v_expected_threshold_after,
      v_funding_after.threshold_met_yn,
      v_funding_after.already_funded_yn;
  END IF;

  -- The commercial position is now covered by the new baseline. Only the
  -- dedicated bundle flag type is resolved here. Ordinary header-review flags are
  -- deliberately outside this action.
  UPDATE public.supplier_invoice_review_flags f
  SET
    status = 'resolved',
    resolved_by_staff_id = v_staff.id,
    resolved_at = now(),
    resolution_notes = COALESCE(
      v_notes,
      format('Order price increased from GBP %s to GBP %s after live accepted supplier-bundle verification.', v_old_total, v_new_total)
    ),
    updated_at = now()
  WHERE f.order_id = p_order_id
    AND f.flag_type = 'order_bundle_limit_breach'
    AND f.status IN ('open','under_review');

  RETURN QUERY
  SELECT
    p_order_id,
    v_old_total::numeric,
    v_new_total::numeric,
    v_increase::numeric,
    v_event_total::numeric,
    v_expected_gap_after::numeric,
    (SELECT o.funded_at FROM public.orders o WHERE o.id = p_order_id),
    v_new_quote_total_ghs::numeric;
END;
$$;

COMMENT ON FUNCTION public.staff_approve_order_supplier_price_increase_v1(uuid, text) IS
'Admin/supervisor-only same-order supplier price increase for original orders. New total is server-derived from the verified live accepted supplier bundle; no client amount is accepted. Existing header review, supplier approval, funding, payment and reconciliation authorities remain unchanged.';

REVOKE ALL ON FUNCTION public.staff_approve_order_supplier_price_increase_v1(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.staff_approve_order_supplier_price_increase_v1(uuid, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
