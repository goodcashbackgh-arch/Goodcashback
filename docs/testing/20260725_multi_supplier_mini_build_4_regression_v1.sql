-- MINI 4 IMMUTABLE REVIEW / HOLD / CUSTOMER CREDIT REGRESSION
-- Rollback-only. No Sage posting. Run after migrations 20260725a and 20260725b.

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
DECLARE
  v_def text;
  v_bad integer;
BEGIN
  IF to_regclass('public.customer_review_cycle_memberships') IS NULL
     OR to_regclass('public.customer_review_cycle_legacy_issues') IS NULL
  THEN
    RAISE EXCEPTION 'FAIL: immutable review-cycle structures missing';
  END IF;

  IF to_regclass('public.customer_hold_review_memberships') IS NULL
     OR to_regclass('public.customer_hold_released_credit_requirements') IS NULL
     OR to_regclass('public.customer_hold_credit_note_documents') IS NULL
  THEN
    RAISE EXCEPTION 'FAIL: exact hold/customer-credit structures missing';
  END IF;

  IF to_regprocedure('public.customer_review_cycle_candidates_v1(uuid)') IS NULL
     OR to_regprocedure('public.internal_materialize_customer_review_cycles_v1(uuid,uuid)') IS NULL
     OR to_regprocedure('public.internal_resolve_customer_review_cycle_legacy_issue_v1(uuid,text)') IS NULL
     OR to_regprocedure('public.customer_materialize_hold_review_memberships_v1(uuid)') IS NULL
     OR to_regprocedure('public.customer_materialize_hold_credit_requirements_v1(uuid)') IS NULL
     OR to_regprocedure('public.internal_create_customer_credit_note_drafts_v1(uuid,uuid)') IS NULL
  THEN
    RAISE EXCEPTION 'FAIL: Mini 4 function chain incomplete';
  END IF;

  SELECT pg_get_functiondef(
    'public.customer_review_cycle_candidates_v1(uuid)'::regprocedure
  ) INTO v_def;

  IF v_def NOT ILIKE '%GREATEST(b.prior_review_qty, b.prior_released_qty)%'
     OR v_def ILIKE '%prior_review_qty - b.prior_released_qty%'
     OR v_def NOT ILIKE '%customer_sales_release_lines%'
     OR v_def NOT ILIKE '%customer_pre_shipment_hold_requests%'
     OR v_def NOT ILIKE '%dispute_lines%'
  THEN
    RAISE EXCEPTION
      'FAIL: newly eligible review quantity is not exact/ledger/hold/exception aware';
  END IF;

  SELECT pg_get_functiondef(
    'public.customer_active_order_review_link_v1(uuid)'::regprocedure
  ) INTO v_def;

  IF v_def ILIKE '%SET expires_at = v_deadline%'
     OR v_def ILIKE '%UPDATE public.customer_order_review_links l%SET expires_at%'
     OR v_def ILIKE '%sage_status::text%IN (%draft%,%posted%'
     OR v_def NOT ILIKE '%internal_materialize_customer_review_cycles_v1%'
  THEN
    RAISE EXCEPTION
      'FAIL: active review link still extends/reuses the old mutable cycle or blocks later cycles by invoice existence';
  END IF;

  SELECT pg_get_functiondef(
    'public.customer_pre_shipment_hold_review_v1(text)'::regprocedure
  ) INTO v_def;

  IF v_def NOT ILIKE '%m.review_link_id = v_link_id%'
     OR v_def NOT ILIKE '%review_membership_id%'
     OR v_def ILIKE '%customer_review_ready_line_ids_v1(o.id) rl%v_expires_at IS NOT NULL%'
  THEN
    RAISE EXCEPTION
      'FAIL: timed token payload is not frozen to the exact review-link membership';
  END IF;

  SELECT pg_get_functiondef(
    'public.customer_close_order_review_links_for_invoice_v1()'::regprocedure
  ) INTO v_def;

  IF v_def ILIKE '%SET is_active = false%' THEN
    RAISE EXCEPTION
      'FAIL: main/supplementary invoice trigger still closes every active review cycle';
  END IF;

  SELECT pg_get_functiondef(
    'public.customer_line_has_active_hold_conflict_v1(uuid,uuid,uuid)'::regprocedure
  ) INTO v_def;

  IF v_def NOT ILIKE '%customer_review_cycle_legacy_issues%'
     OR v_def NOT ILIKE '%customer_pre_shipment_hold_requests%'
  THEN
    RAISE EXCEPTION
      'FAIL: shipment hold truth does not include unresolved historical review ambiguity';
  END IF;

  SELECT pg_get_functiondef(
    'public.shipper_shipment_batch_candidates_v1()'::regprocedure
  ) INTO v_def;

  IF v_def NOT ILIKE '%customer_line_has_active_hold_conflict_v1%'
     OR v_def NOT ILIKE '%24 hours%'
  THEN
    RAISE EXCEPTION
      'FAIL: protected shipment candidate route no longer uses shared hold/review truth';
  END IF;

  SELECT pg_get_functiondef(
    'public.shipper_create_shipment_batch_v1(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text)'::regprocedure
  ) INTO v_def;

  IF v_def NOT ILIKE '%customer_line_has_active_hold_conflict_v1%'
     OR v_def NOT ILIKE '%shipper_shipment_batch_line_memberships%'
     OR v_def NOT ILIKE '%24-hour customer review window%'
  THEN
    RAISE EXCEPTION
      'FAIL: protected direct shipment creation lost review/hold/immutable-line enforcement';
  END IF;

  IF to_regprocedure(
    'public.internal_customer_sales_release_sources_pre_mini4_v1(uuid)'
  ) IS NULL THEN
    RAISE EXCEPTION 'FAIL: prior Mini 3 source resolver was not preserved';
  END IF;

  SELECT pg_get_functiondef(
    'public.internal_customer_sales_release_sources_v1(uuid)'::regprocedure
  ) INTO v_def;

  IF v_def NOT ILIKE '%internal_customer_sales_release_sources_pre_mini4_v1%'
     OR v_def NOT ILIKE '%customer_review_cycle_legacy_membership_unresolved%'
  THEN
    RAISE EXCEPTION
      'FAIL: canonical Mini 3 source route is not a bounded fail-closed wrapper';
  END IF;

  SELECT pg_get_functiondef(
    'public.internal_customer_sales_release_sources_pre_mini4_v1(uuid)'::regprocedure
  ) INTO v_def;

  IF v_def NOT ILIKE '%shipper_shipment_batch_effective_lines_v1%'
     OR v_def NOT ILIKE '%customer_sales_release_lines%'
  THEN
    RAISE EXCEPTION
      'FAIL: preserved Mini 3 resolver lost immutable shipment/release-ledger authority';
  END IF;

  SELECT pg_get_functiondef(
    'public.customer_hold_refund_target_lines_v1(uuid)'::regprocedure
  ) INTO v_def;

  IF v_def NOT ILIKE '%customer_hold_review_memberships%'
     OR v_def NOT ILIKE '%l.expires_at IS NULL%'
  THEN
    RAISE EXCEPTION
      'FAIL: refund target route does not prefer exact membership with untimed-only legacy fallback';
  END IF;

  SELECT pg_get_functiondef(
    'public.customer_materialize_hold_credit_requirements_v1(uuid)'::regprocedure
  ) INTO v_def;

  IF v_def NOT ILIKE '%review_start_qty%'
     OR v_def NOT ILIKE '%release_start_qty%'
     OR v_def NOT ILIKE '%LEAST(%'
     OR v_def NOT ILIKE '%GREATEST(%'
  THEN
    RAISE EXCEPTION
      'FAIL: released customer value is not attributed by exact review/release quantity-range overlap';
  END IF;

  SELECT pg_get_functiondef(
    'public.internal_create_customer_credit_note_drafts_v1(uuid,uuid)'::regprocedure
  ) INTO v_def;

  IF v_def NOT ILIKE '%invoice_type%'
     OR v_def NOT ILIKE '%credit_note%'
     OR v_def NOT ILIKE '%linked_invoice_id%'
     OR v_def NOT ILIKE '%customer_hold_released_credit_requirements%'
     OR v_def NOT ILIKE '%sage_status%'
     OR v_def NOT ILIKE '%draft%'
     OR v_def ILIKE '%sage_status%posted%RETURNING id INTO v_credit_note_id%'
  THEN
    RAISE EXCEPTION
      'FAIL: exact customer credit-note draft does not reuse the existing positive linked sales_invoices draft lane';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger trigger_row
    JOIN pg_class table_row ON table_row.oid = trigger_row.tgrelid
    JOIN pg_namespace namespace_row ON namespace_row.oid = table_row.relnamespace
    WHERE namespace_row.nspname = 'public'
      AND table_row.relname = 'customer_sales_release_lines'
      AND trigger_row.tgname = 'trg_customer_review_legacy_block_release_v1'
      AND NOT trigger_row.tgisinternal
  ) THEN
    RAISE EXCEPTION
      'FAIL: direct release insert/update lacks historical-review fail-closed trigger';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger trigger_row
    JOIN pg_class table_row ON table_row.oid = trigger_row.tgrelid
    JOIN pg_namespace namespace_row ON namespace_row.oid = table_row.relnamespace
    WHERE namespace_row.nspname = 'public'
      AND table_row.relname = 'sales_invoices'
      AND trigger_row.tgname = 'trg_customer_credit_note_document_sync_v1'
      AND NOT trigger_row.tgisinternal
  ) THEN
    RAISE EXCEPTION
      'FAIL: customer credit-note lifecycle sync trigger missing';
  END IF;

  SELECT COUNT(*)::integer
  INTO v_bad
  FROM pg_index index_row
  JOIN pg_class table_row ON table_row.oid = index_row.indrelid
  JOIN pg_namespace namespace_row ON namespace_row.oid = table_row.relnamespace
  WHERE namespace_row.nspname = 'public'
    AND table_row.relname = 'customer_order_review_links'
    AND index_row.indisunique
    AND index_row.indpred IS NULL
    AND pg_get_indexdef(index_row.indexrelid) ~* '\(order_id\)';

  IF v_bad <> 0 THEN
    RAISE EXCEPTION
      'FAIL: unique order-only review-link index blocks repeated cycles';
  END IF;
END;
$$;

DO $$
DECLARE
  v_bad integer;
BEGIN
  SELECT COUNT(*)::integer
  INTO v_bad
  FROM public.customer_review_cycle_memberships membership
  JOIN public.customer_order_review_links review_link
    ON review_link.id = membership.review_link_id
  JOIN public.order_tracking_line_allocations allocation
    ON allocation.id = membership.tracking_line_allocation_id
  JOIN public.supplier_invoice_lines supplier_line
    ON supplier_line.id = membership.supplier_invoice_line_id
  WHERE membership.order_id IS DISTINCT FROM review_link.order_id
     OR membership.order_id IS DISTINCT FROM allocation.order_id
     OR membership.tracking_submission_id IS DISTINCT FROM
          allocation.tracking_submission_id
     OR membership.supplier_invoice_line_id IS DISTINCT FROM
          allocation.supplier_invoice_line_id
     OR membership.supplier_invoice_id IS DISTINCT FROM
          supplier_line.supplier_invoice_id;

  IF v_bad > 0 THEN
    RAISE EXCEPTION
      'FAIL: immutable review membership contains mismatched exact source identity';
  END IF;

  SELECT COUNT(*)::integer
  INTO v_bad
  FROM public.customer_review_cycle_memberships membership
  JOIN public.customer_order_review_links review_link
    ON review_link.id = membership.review_link_id
  JOIN public.order_tracking_line_allocations allocation
    ON allocation.id = membership.tracking_line_allocation_id
  JOIN public.supplier_invoice_lines supplier_line
    ON supplier_line.id = membership.supplier_invoice_line_id
  JOIN public.supplier_invoices supplier_invoice
    ON supplier_invoice.id = membership.supplier_invoice_id
  WHERE membership.legacy_backfill_yn = true
    AND (
      membership.receipt_recorded_at > review_link.created_at
      OR allocation.created_at > review_link.created_at
      OR supplier_line.created_at > review_link.created_at
      OR supplier_invoice.uploaded_at > review_link.created_at
    );

  IF v_bad > 0 THEN
    RAISE EXCEPTION
      'FAIL: historical review link acquired source created or received after that link';
  END IF;

  SELECT COUNT(*)::integer
  INTO v_bad
  FROM (
    SELECT
      membership.tracking_line_allocation_id
    FROM public.customer_review_cycle_memberships membership
    WHERE membership.membership_status = 'active'
    GROUP BY membership.tracking_line_allocation_id
    HAVING COUNT(DISTINCT membership.review_link_id) > 1
  ) duplicate_active;

  IF v_bad > 0 THEN
    RAISE EXCEPTION
      'FAIL: exact source allocation belongs to more than one active review cycle';
  END IF;

  SELECT COUNT(*)::integer
  INTO v_bad
  FROM public.customer_order_review_links review_link
  WHERE review_link.expires_at IS NOT NULL
    AND review_link.is_active = true
    AND review_link.expires_at > now()
    AND NOT EXISTS (
      SELECT 1
      FROM public.customer_review_cycle_memberships membership
      WHERE membership.review_link_id = review_link.id
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.customer_review_cycle_legacy_issues issue
      WHERE issue.review_link_id = review_link.id
        AND issue.resolved_at IS NULL
    );

  IF v_bad > 0 THEN
    RAISE EXCEPTION
      'FAIL: active timed legacy link has neither exact membership nor explicit fail-closed issue';
  END IF;

  SELECT COUNT(*)::integer
  INTO v_bad
  FROM (
    SELECT
      membership.tracking_line_allocation_id,
      MAX(allocation.qty_allocated)::numeric AS allocated_qty,
      SUM(membership.review_qty)::numeric AS reviewed_qty,
      COALESCE(MAX(released.released_qty), 0)::numeric AS released_qty
    FROM public.customer_review_cycle_memberships membership
    JOIN public.order_tracking_line_allocations allocation
      ON allocation.id = membership.tracking_line_allocation_id
    LEFT JOIN LATERAL (
      SELECT SUM(release_line.released_qty)::numeric AS released_qty
      FROM public.customer_sales_release_lines release_line
      WHERE release_line.tracking_line_allocation_id =
            membership.tracking_line_allocation_id
        AND release_line.release_status = 'active'
    ) released ON true
    WHERE membership.membership_status <> 'legacy_unresolved'
    GROUP BY membership.tracking_line_allocation_id
    HAVING GREATEST(
      SUM(membership.review_qty),
      COALESCE(MAX(released.released_qty), 0)
    ) > MAX(allocation.qty_allocated) + 0.001
  ) over_membership;

  IF v_bad > 0 THEN
    RAISE EXCEPTION
      'FAIL: review/release quantity exceeds exact tracking allocation';
  END IF;

  SELECT COUNT(*)::integer
  INTO v_bad
  FROM public.customer_hold_released_credit_requirements requirement
  JOIN public.customer_sales_release_lines release_line
    ON release_line.id = requirement.customer_sales_release_line_id
  WHERE requirement.original_sales_invoice_id IS DISTINCT FROM
          release_line.sales_invoice_id
     OR requirement.affected_qty > release_line.released_qty + 0.001
     OR requirement.affected_customer_value_gbp >
          release_line.customer_charge_amount_gbp + 0.02;

  IF v_bad > 0 THEN
    RAISE EXCEPTION
      'FAIL: customer-credit requirement exceeds or misattributes exact release membership';
  END IF;

  SELECT COUNT(*)::integer
  INTO v_bad
  FROM (
    SELECT
      requirement.hold_request_id,
      requirement.customer_sales_release_line_id,
      SUM(requirement.affected_qty)::numeric AS affected_qty,
      SUM(requirement.affected_customer_value_gbp)::numeric AS affected_value,
      MAX(release_line.released_qty)::numeric AS released_qty,
      MAX(release_line.customer_charge_amount_gbp)::numeric AS released_value
    FROM public.customer_hold_released_credit_requirements requirement
    JOIN public.customer_sales_release_lines release_line
      ON release_line.id = requirement.customer_sales_release_line_id
    GROUP BY
      requirement.hold_request_id,
      requirement.customer_sales_release_line_id
    HAVING SUM(requirement.affected_qty) >
             MAX(release_line.released_qty) + 0.001
        OR SUM(requirement.affected_customer_value_gbp) >
             MAX(release_line.customer_charge_amount_gbp) + 0.02
  ) over_credit;

  IF v_bad > 0 THEN
    RAISE EXCEPTION
      'FAIL: cumulative customer credit exceeds the original released line';
  END IF;

  SELECT COUNT(*)::integer
  INTO v_bad
  FROM public.customer_hold_credit_note_documents document
  JOIN public.sales_invoices credit_note
    ON credit_note.id = document.customer_credit_note_id
  WHERE credit_note.invoice_type <> 'credit_note'
     OR credit_note.linked_invoice_id IS DISTINCT FROM
          document.original_sales_invoice_id
     OR credit_note.amount_gbp <= 0
     OR credit_note.line_items_json
          #>> '{credit_note_control,hold_request_id}'
          IS DISTINCT FROM document.hold_request_id::text
     OR LENGTH(COALESCE(
          credit_note.line_items_json #>> '{sage_header,reference}',
          ''
        )) > 32;

  IF v_bad > 0 THEN
    RAISE EXCEPTION
      'FAIL: Mini 4 customer credit note is not positive, exactly linked, auditable or Sage-reference safe';
  END IF;

  SELECT COUNT(*)::integer
  INTO v_bad
  FROM public.customer_hold_released_credit_requirements requirement
  JOIN public.customer_hold_credit_note_documents document
    ON document.customer_credit_note_id =
         requirement.customer_credit_note_id
  WHERE requirement.customer_credit_note_id IS NOT NULL
    AND requirement.original_sales_invoice_id IS DISTINCT FROM
         document.original_sales_invoice_id
     OR requirement.customer_credit_note_id IS NOT NULL
    AND requirement.hold_request_id IS DISTINCT FROM
         document.hold_request_id;

  IF v_bad > 0 THEN
    RAISE EXCEPTION
      'FAIL: customer credit requirement crossed its original main/supplementary invoice boundary';
  END IF;
END;
$$;

SELECT
  'PASS'::text AS regression_result,
  'Mini 4 freezes exact review membership behind the existing token/deadline, permits only newly eligible repeated cycles, fails closed for ambiguous history through existing shipment and release controls, materialises exact hold quantity, and creates separate positive linked customer-credit drafts per affected original main/supplementary invoice without posting to Sage.'::text AS details;

ROLLBACK;
