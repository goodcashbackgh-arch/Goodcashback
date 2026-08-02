BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Governed by:
-- docs/governing-pack/architecture/
-- HYBRID_PHYSICAL_RECEIPT_BUILD_4_AUTHORITY_VERSIONING_CORRECTION_ADDENDUM_v1.md
--
-- Corrective migration only. No feature authority is changed. The installed
-- Build-2 guard object is versioned by rename, the exact foundation v1 is
-- restored literally, the Build-4 reconciliation is preserved under v2, the
-- legacy reconciliation is restored, and only the Build-4 anomaly view is
-- redirected to v2.

CREATE TEMP TABLE b4_authority_correction_snapshot (
  snapshot_key text PRIMARY KEY,
  snapshot_value text NOT NULL
) ON COMMIT DROP;

CREATE TEMP TABLE b4_legacy_dependents_before (
  dependent_class text NOT NULL,
  dependent_oid oid NOT NULL,
  dependent_subid integer NOT NULL,
  dependency_type "char" NOT NULL,
  dependent_identity text NOT NULL,
  referenced_subid integer NOT NULL
) ON COMMIT DROP;

DO $preflight$
DECLARE
  v_guard_fingerprint text;
  v_view_fingerprint text;
  v_columns text[];
  v_trigger_oid oid;
  v_guard_oid oid;
  v_view_owner text;
  v_view_acl text;
BEGIN
  IF to_regprocedure('public.physical_remedy_allocation_guard_v1()') IS NULL THEN
    RAISE EXCEPTION 'Expected physical_remedy_allocation_guard_v1() is missing.';
  END IF;
  IF to_regprocedure('public.physical_remedy_allocation_guard_v2()') IS NOT NULL THEN
    RAISE EXCEPTION 'physical_remedy_allocation_guard_v2() already exists; inspect rather than replace.';
  END IF;

  SELECT md5(pg_get_functiondef('public.physical_remedy_allocation_guard_v1()'::regprocedure)),
         'public.physical_remedy_allocation_guard_v1()'::regprocedure::oid
  INTO v_guard_fingerprint, v_guard_oid;

  IF v_guard_fingerprint IS DISTINCT FROM '32e1d3eb9161cdc3e09114edb8c0d3c0' THEN
    RAISE EXCEPTION 'Unexpected Build-2 physical remedy guard baseline: %', v_guard_fingerprint;
  END IF;

  SELECT t.tgfoid
  INTO v_trigger_oid
  FROM pg_trigger t
  WHERE t.tgrelid = 'public.physical_exception_remedy_allocations'::regclass
    AND t.tgname = 'trg_physical_remedy_allocation_guard_v1'
    AND NOT t.tgisinternal;

  IF v_trigger_oid IS DISTINCT FROM v_guard_oid THEN
    RAISE EXCEPTION 'Expected hybrid remedy trigger is not bound to the reviewed Build-2 guard object.';
  END IF;

  IF to_regclass('public.order_reconciliation_vw') IS NULL THEN
    RAISE EXCEPTION 'Expected public.order_reconciliation_vw is missing.';
  END IF;
  IF to_regclass('public.order_reconciliation_v2_vw') IS NOT NULL THEN
    RAISE EXCEPTION 'public.order_reconciliation_v2_vw already exists; inspect rather than replace.';
  END IF;
  IF to_regclass('public.order_reconciliation_anomalies_v1') IS NULL THEN
    RAISE EXCEPTION 'Expected public.order_reconciliation_anomalies_v1 is missing.';
  END IF;

  SELECT md5(definition)
  INTO v_view_fingerprint
  FROM pg_views
  WHERE schemaname = 'public' AND viewname = 'order_reconciliation_vw';

  IF v_view_fingerprint IS DISTINCT FROM '89cc95922a2b8ec1fa040ba79f12907a' THEN
    RAISE EXCEPTION 'Unexpected Build-4 reconciliation baseline: %', v_view_fingerprint;
  END IF;

  SELECT array_agg(column_name ORDER BY ordinal_position)
  INTO v_columns
  FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'order_reconciliation_vw';

  IF v_columns IS DISTINCT FROM ARRAY[
    'order_id','qty_target','qty_progressed_invoiceable','qty_resolved_noninvoiceable',
    'qty_unresolved','amount_target_gbp','amount_progressed_invoiceable_gbp',
    'amount_resolved_noninvoiceable_gbp','amount_unresolved_gbp',
    'invoiceable_subset_released_yn','whole_order_cleared_yn','last_refreshed_at'
  ]::text[] THEN
    RAISE EXCEPTION 'Unexpected reconciliation public contract: %', v_columns;
  END IF;

  SELECT pg_get_userbyid(c.relowner), COALESCE(c.relacl::text, '')
  INTO v_view_owner, v_view_acl
  FROM pg_class c
  WHERE c.oid = 'public.order_reconciliation_vw'::regclass;

  INSERT INTO b4_authority_correction_snapshot(snapshot_key, snapshot_value) VALUES
    ('build2_guard_oid', v_guard_oid::text),
    ('build2_guard_fingerprint', v_guard_fingerprint),
    ('build4_view_definition', (SELECT definition FROM pg_views WHERE schemaname='public' AND viewname='order_reconciliation_vw')),
    ('legacy_view_owner', v_view_owner),
    ('legacy_view_acl', v_view_acl);

  INSERT INTO b4_legacy_dependents_before(
    dependent_class, dependent_oid, dependent_subid,
    dependency_type, dependent_identity, referenced_subid
  )
  SELECT
    d.classid::regclass::text,
    d.objid,
    d.objsubid,
    d.deptype,
    pg_describe_object(d.classid, d.objid, d.objsubid),
    d.refobjsubid
  FROM pg_depend d
  WHERE d.refobjid = 'public.order_reconciliation_vw'::regclass;
END
$preflight$;

-- Prove the reviewed current anomaly body before redirecting it. The reference
-- view is transaction-local and differs only by object name.
CREATE TEMP VIEW b4_expected_current_anomalies AS
WITH raw_eligible AS (
  SELECT si.order_id,
         COALESCE(SUM(COALESCE(sil.qty_confirmed, 0)), 0)::numeric AS raw_qty,
         COALESCE(SUM(COALESCE(sil.amount_confirmed, 0)), 0)::numeric AS raw_amount_gbp
  FROM public.supplier_invoices si
  JOIN public.supplier_invoice_lines sil ON sil.supplier_invoice_id = si.id
  WHERE sil.eligible_for_invoice_yn = 'Y'
  GROUP BY si.order_id
),
non_authoritative AS (
  SELECT si.order_id,
         COALESCE(SUM(COALESCE(sil.qty_confirmed, 0)), 0)::numeric AS non_authoritative_qty,
         COALESCE(SUM(COALESCE(sil.amount_confirmed, 0)), 0)::numeric AS non_authoritative_amount_gbp,
         jsonb_agg(
           jsonb_build_object(
             'supplier_invoice_id', si.id,
             'invoice_ref', si.invoice_ref,
             'review_status', si.review_status,
             'blocked_from_sage_yn', si.blocked_from_sage_yn,
             'is_current_for_order', si.is_current_for_order,
             'superseded_by_supplier_invoice_id', si.superseded_by_supplier_invoice_id,
             'supplier_invoice_line_id', sil.id,
             'qty_confirmed', sil.qty_confirmed,
             'amount_confirmed', sil.amount_confirmed
           ) ORDER BY si.uploaded_at, si.id, sil.line_order, sil.id
         ) AS evidence_json
  FROM public.supplier_invoices si
  JOIN public.supplier_invoice_lines sil ON sil.supplier_invoice_id = si.id
  WHERE sil.eligible_for_invoice_yn = 'Y'
    AND (
      si.is_current_for_order IS DISTINCT FROM true
      OR si.review_status IS NULL
      OR si.review_status NOT IN ('approved_current','ref_corrected_approved')
      OR si.blocked_from_sage_yn IS DISTINCT FROM false
      OR si.superseded_by_supplier_invoice_id IS NOT NULL
    )
  GROUP BY si.order_id
),
canonical AS (SELECT * FROM public.order_reconciliation_vw)
SELECT c.order_id,
       'AUTHORITATIVE_QTY_OVER_PROGRESS'::text AS anomaly_code,
       c.qty_target::numeric AS qty_target,
       c.qty_progressed_invoiceable::numeric AS qty_observed,
       greatest(c.qty_progressed_invoiceable::numeric - c.qty_target::numeric, 0::numeric) AS qty_over,
       c.amount_target_gbp,
       c.amount_progressed_invoiceable_gbp AS amount_observed_gbp,
       greatest(c.amount_progressed_invoiceable_gbp - c.amount_target_gbp, 0::numeric) AS amount_over_gbp,
       jsonb_build_object('source','canonical_authoritative_supplier_lines') AS detail_json,
       now() AS last_refreshed_at
FROM canonical c
WHERE c.qty_progressed_invoiceable > c.qty_target
UNION ALL
SELECT c.order_id,
       'AUTHORITATIVE_AMOUNT_OVER_PROGRESS',
       c.qty_target::numeric,
       c.qty_progressed_invoiceable::numeric,
       greatest(c.qty_progressed_invoiceable::numeric - c.qty_target::numeric, 0::numeric),
       c.amount_target_gbp,
       c.amount_progressed_invoiceable_gbp,
       greatest(c.amount_progressed_invoiceable_gbp - c.amount_target_gbp, 0::numeric),
       jsonb_build_object('source','canonical_authoritative_supplier_lines'),
       now()
FROM canonical c
WHERE c.amount_progressed_invoiceable_gbp > c.amount_target_gbp
UNION ALL
SELECT o.id,
       'NON_AUTHORITATIVE_INVOICEABLE_EVIDENCE',
       o.total_qty_declared::numeric,
       na.non_authoritative_qty,
       greatest(na.non_authoritative_qty - o.total_qty_declared::numeric, 0::numeric),
       o.order_total_gbp_declared,
       na.non_authoritative_amount_gbp,
       greatest(na.non_authoritative_amount_gbp - o.order_total_gbp_declared, 0::numeric),
       jsonb_build_object('evidence', na.evidence_json),
       now()
FROM public.orders o
JOIN non_authoritative na ON na.order_id = o.id
WHERE na.non_authoritative_qty <> 0 OR na.non_authoritative_amount_gbp <> 0
UNION ALL
SELECT o.id,
       'RAW_QTY_OVER_PROGRESS',
       o.total_qty_declared::numeric,
       raw.raw_qty,
       greatest(raw.raw_qty - o.total_qty_declared::numeric, 0::numeric),
       o.order_total_gbp_declared,
       raw.raw_amount_gbp,
       greatest(raw.raw_amount_gbp - o.order_total_gbp_declared, 0::numeric),
       jsonb_build_object('source','all_eligible_lines_regardless_of_invoice_authority'),
       now()
FROM public.orders o
JOIN raw_eligible raw ON raw.order_id = o.id
WHERE raw.raw_qty > o.total_qty_declared::numeric
UNION ALL
SELECT o.id,
       'RAW_AMOUNT_OVER_PROGRESS',
       o.total_qty_declared::numeric,
       raw.raw_qty,
       greatest(raw.raw_qty - o.total_qty_declared::numeric, 0::numeric),
       o.order_total_gbp_declared,
       raw.raw_amount_gbp,
       greatest(raw.raw_amount_gbp - o.order_total_gbp_declared, 0::numeric),
       jsonb_build_object('source','all_eligible_lines_regardless_of_invoice_authority'),
       now()
FROM public.orders o
JOIN raw_eligible raw ON raw.order_id = o.id
WHERE raw.raw_amount_gbp > o.order_total_gbp_declared;

DO $anomaly_preflight$
DECLARE
  v_actual text;
  v_expected text;
BEGIN
  SELECT pg_get_viewdef('public.order_reconciliation_anomalies_v1'::regclass, false)
  INTO v_actual;
  SELECT pg_get_viewdef('b4_expected_current_anomalies'::regclass, false)
  INTO v_expected;

  IF md5(v_actual) IS DISTINCT FROM md5(v_expected) THEN
    RAISE EXCEPTION 'Build-4 anomaly view differs from the reviewed definition; no correction applied.';
  END IF;
END
$anomaly_preflight$;

DROP VIEW b4_expected_current_anomalies;

-- Rename the exact installed Build-2 function object. The existing trigger keeps
-- its object-OID binding and therefore continues to execute the unchanged v2 body.
ALTER FUNCTION public.physical_remedy_allocation_guard_v1()
  RENAME TO physical_remedy_allocation_guard_v2;

COMMENT ON FUNCTION public.physical_remedy_allocation_guard_v2() IS
  'Build-2 outcome-specific physical dispute compatibility guard, versioned by object rename without body replacement.';

-- Exact literal foundation definition copied from
-- 20260801131000_hybrid_physical_receipt_integrity_v1.sql.
CREATE FUNCTION public.physical_remedy_allocation_guard_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_disposition public.shipper_package_receipt_line_dispositions%ROWTYPE;
  v_review public.physical_receipt_reviews%ROWTYPE;
  v_dispute_line_supplier_id uuid;
  v_dispute_order_id uuid;
  v_dispute_id uuid;
  v_child_order public.orders%ROWTYPE;
  v_child_allocation_order_id uuid;
  v_existing_qty numeric := 0;
  v_new_qty numeric := 0;
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION
      'Physical remedy provenance cannot be deleted; cancel or reroute it through an audited transition.';
  END IF;

  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'proposed'
       OR NEW.approved_remedy_type IS NOT NULL
       OR NEW.approved_remedy_qty IS NOT NULL
       OR NEW.approved_by_staff_id IS NOT NULL
       OR NEW.approved_at IS NOT NULL
       OR NEW.dispute_line_id IS NOT NULL
       OR NEW.replacement_child_order_id IS NOT NULL
       OR NEW.replacement_child_tracking_allocation_id IS NOT NULL
       OR NEW.rerouted_to_remedy_allocation_id IS NOT NULL
    THEN
      RAISE EXCEPTION
        'A remedy allocation must start as the importer proposal only.';
    END IF;
  ELSE
    IF NEW.physical_receipt_review_id IS DISTINCT FROM OLD.physical_receipt_review_id
       OR NEW.receipt_line_disposition_id IS DISTINCT FROM OLD.receipt_line_disposition_id
       OR NEW.tracking_line_allocation_id IS DISTINCT FROM OLD.tracking_line_allocation_id
       OR NEW.supplier_invoice_line_id IS DISTINCT FROM OLD.supplier_invoice_line_id
       OR NEW.proposed_remedy_type IS DISTINCT FROM OLD.proposed_remedy_type
       OR NEW.proposed_remedy_qty IS DISTINCT FROM OLD.proposed_remedy_qty
       OR NEW.proposed_by_operator_id IS DISTINCT FROM OLD.proposed_by_operator_id
       OR NEW.proposed_at IS DISTINCT FROM OLD.proposed_at
       OR NEW.created_at IS DISTINCT FROM OLD.created_at
    THEN
      RAISE EXCEPTION
        'Importer remedy proposal and exact source identity are immutable; reroute with a new allocation.';
    END IF;

    IF OLD.approved_at IS NOT NULL
       AND (
         NEW.approved_remedy_type IS DISTINCT FROM OLD.approved_remedy_type
         OR NEW.approved_remedy_qty IS DISTINCT FROM OLD.approved_remedy_qty
         OR NEW.approved_by_staff_id IS DISTINCT FROM OLD.approved_by_staff_id
         OR NEW.approved_at IS DISTINCT FROM OLD.approved_at
       )
    THEN
      RAISE EXCEPTION
        'Supervisor-approved remedy route and quantity are immutable; reroute with a new allocation.';
    END IF;

    IF OLD.status IN ('completed','closed_no_action','rerouted')
       AND NEW.status IS DISTINCT FROM OLD.status
    THEN
      RAISE EXCEPTION 'Completed, no-action or rerouted remedy state cannot be reopened.';
    END IF;

    IF NEW.status IS DISTINCT FROM OLD.status
       AND NOT (
         (OLD.status = 'proposed'
          AND NEW.status IN ('approved','cancelled','rerouted'))
         OR
         (OLD.status = 'approved'
          AND NEW.status IN (
            'linked_to_exception','in_progress','completed',
            'closed_no_action','cancelled','rerouted'
          ))
         OR
         (OLD.status = 'linked_to_exception'
          AND NEW.status IN ('in_progress','completed','cancelled','rerouted'))
         OR
         (OLD.status = 'in_progress'
          AND NEW.status IN ('completed','cancelled','rerouted'))
         OR
         (OLD.status = 'cancelled' AND NEW.status = 'rerouted')
       )
    THEN
      RAISE EXCEPTION
        'Invalid physical remedy state transition: % -> %',
        OLD.status,
        NEW.status;
    END IF;
  END IF;

  SELECT disposition.*
  INTO v_disposition
  FROM public.shipper_package_receipt_line_dispositions disposition
  WHERE disposition.id = NEW.receipt_line_disposition_id
  FOR UPDATE;

  SELECT review_row.*
  INTO v_review
  FROM public.physical_receipt_reviews review_row
  WHERE review_row.id = NEW.physical_receipt_review_id
  FOR SHARE;

  IF v_disposition.id IS NULL
     OR v_disposition.disposition_type = 'clean'
     OR v_review.id IS NULL
     OR v_review.receipt_id IS DISTINCT FROM v_disposition.receipt_id
     OR v_disposition.tracking_line_allocation_id IS DISTINCT FROM NEW.tracking_line_allocation_id
     OR v_disposition.supplier_invoice_line_id IS DISTINCT FROM NEW.supplier_invoice_line_id
  THEN
    RAISE EXCEPTION
      'Physical remedy does not match one affected receipt disposition and review.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.operators operator_row
    JOIN public.operator_importers access_row
      ON access_row.operator_id = operator_row.id
     AND access_row.importer_id = v_review.importer_id
     AND access_row.revoked_at IS NULL
    WHERE operator_row.id = NEW.proposed_by_operator_id
      AND COALESCE(operator_row.active, true) = true
  ) THEN
    RAISE EXCEPTION
      'Remedy proposal actor is not an active operator for the review importer.';
  END IF;

  IF NEW.status IN (
    'approved','linked_to_exception','in_progress','completed','closed_no_action'
  ) THEN
    IF NEW.approved_remedy_type IS NULL
       OR NEW.approved_remedy_qty IS NULL
       OR NEW.approved_by_staff_id IS NULL
       OR NEW.approved_at IS NULL
       OR NOT EXISTS (
         SELECT 1
         FROM public.staff staff_row
         WHERE staff_row.id = NEW.approved_by_staff_id
           AND COALESCE(staff_row.active, true) = true
       )
    THEN
      RAISE EXCEPTION
        'Approved remedy state requires the exact supervisor-approved route, quantity, actor and timestamp.';
    END IF;
  END IF;

  IF NEW.approved_remedy_type = 'replacement' THEN
    IF NEW.supplier_cost_mode NOT IN (
      'free_replacement','charged_repurchase','pending_supplier_evidence'
    ) THEN
      RAISE EXCEPTION
        'Approved replacement requires an explicit supplier cost mode.';
    END IF;
  ELSIF NEW.approved_remedy_type IS NOT NULL THEN
    IF COALESCE(NEW.supplier_cost_mode, 'not_applicable') <> 'not_applicable'
       OR NEW.replacement_child_order_id IS NOT NULL
       OR NEW.replacement_child_tracking_allocation_id IS NOT NULL
    THEN
      RAISE EXCEPTION
        'Non-replacement remedy cannot carry replacement supplier cost or child provenance.';
    END IF;
  ELSE
    IF NEW.supplier_cost_mode IS NOT NULL
       OR NEW.replacement_child_order_id IS NOT NULL
       OR NEW.replacement_child_tracking_allocation_id IS NOT NULL
    THEN
      RAISE EXCEPTION
        'Unapproved proposal cannot carry replacement cost or child provenance.';
    END IF;
  END IF;

  IF NEW.status IN ('linked_to_exception','in_progress','completed')
     AND NEW.approved_remedy_type IN ('refund','replacement')
  THEN
    IF NEW.dispute_line_id IS NULL THEN
      RAISE EXCEPTION
        'Progressed refund/replacement remedy requires its exact existing dispute line.';
    END IF;
  END IF;

  IF NEW.dispute_line_id IS NOT NULL THEN
    SELECT
      dispute_line.supplier_invoice_line_id,
      dispute_row.order_id,
      dispute_row.id
    INTO
      v_dispute_line_supplier_id,
      v_dispute_order_id,
      v_dispute_id
    FROM public.dispute_lines dispute_line
    JOIN public.disputes dispute_row ON dispute_row.id = dispute_line.dispute_id
    WHERE dispute_line.id = NEW.dispute_line_id;

    IF v_dispute_line_supplier_id IS DISTINCT FROM NEW.supplier_invoice_line_id
       OR v_dispute_order_id IS DISTINCT FROM v_review.order_id
       OR (
         v_review.linked_dispute_id IS NOT NULL
         AND v_review.linked_dispute_id IS DISTINCT FROM v_dispute_id
       )
    THEN
      RAISE EXCEPTION
        'Physical remedy dispute line does not match the exact source line, order and linked dispute.';
    END IF;
  END IF;

  IF NEW.approved_remedy_type = 'replacement'
     AND NEW.status IN ('in_progress','completed')
  THEN
    IF NEW.replacement_child_order_id IS NULL THEN
      RAISE EXCEPTION
        'Replacement in progress or completed requires its exact replacement child order.';
    END IF;

    SELECT child.*
    INTO v_child_order
    FROM public.orders child
    WHERE child.id = NEW.replacement_child_order_id;

    IF v_child_order.id IS NULL
       OR v_child_order.order_type IS DISTINCT FROM 'replacement_child'
       OR v_child_order.parent_order_id IS DISTINCT FROM v_review.order_id
       OR (
         v_child_order.replacement_source_dispute_line_id IS NOT NULL
         AND v_child_order.replacement_source_dispute_line_id IS DISTINCT FROM NEW.dispute_line_id
       )
    THEN
      RAISE EXCEPTION
        'Replacement child does not match the parent order and source dispute line.';
    END IF;
  END IF;

  IF NEW.status = 'completed'
     AND NEW.approved_remedy_type = 'replacement'
  THEN
    IF NEW.replacement_child_tracking_allocation_id IS NULL THEN
      RAISE EXCEPTION
        'Completed replacement requires exact replacement-child tracking allocation provenance.';
    END IF;

    SELECT allocation.order_id
    INTO v_child_allocation_order_id
    FROM public.order_tracking_line_allocations allocation
    WHERE allocation.id = NEW.replacement_child_tracking_allocation_id;

    IF v_child_allocation_order_id IS DISTINCT FROM NEW.replacement_child_order_id THEN
      RAISE EXCEPTION
        'Replacement-child tracking allocation does not belong to the replacement child order.';
    END IF;
  END IF;

  IF NEW.status = 'closed_no_action'
     AND NEW.approved_remedy_type IS DISTINCT FROM 'no_action'
  THEN
    RAISE EXCEPTION 'Closed-no-action status requires an approved no-action route.';
  END IF;

  IF NEW.status = 'rerouted' THEN
    IF NEW.rerouted_to_remedy_allocation_id IS NULL
       OR NEW.rerouted_to_remedy_allocation_id = NEW.id
       OR NOT EXISTS (
         SELECT 1
         FROM public.physical_exception_remedy_allocations target
         WHERE target.id = NEW.rerouted_to_remedy_allocation_id
           AND target.physical_receipt_review_id = NEW.physical_receipt_review_id
           AND target.receipt_line_disposition_id = NEW.receipt_line_disposition_id
       )
    THEN
      RAISE EXCEPTION
        'Rerouted remedy must identify a different allocation for the same review and affected disposition.';
    END IF;
  ELSIF NEW.rerouted_to_remedy_allocation_id IS NOT NULL THEN
    RAISE EXCEPTION 'Only a rerouted remedy may carry a reroute target.';
  END IF;

  SELECT COALESCE(SUM(
    CASE
      WHEN remedy_row.status = 'proposed'
        THEN remedy_row.proposed_remedy_qty
      WHEN remedy_row.status IN (
        'approved','linked_to_exception','in_progress',
        'completed','closed_no_action'
      )
        THEN remedy_row.approved_remedy_qty
      ELSE 0
    END
  ), 0)::numeric
  INTO v_existing_qty
  FROM public.physical_exception_remedy_allocations remedy_row
  WHERE remedy_row.receipt_line_disposition_id = NEW.receipt_line_disposition_id
    AND (TG_OP = 'INSERT' OR remedy_row.id <> NEW.id);

  v_new_qty := CASE
    WHEN NEW.status = 'proposed' THEN NEW.proposed_remedy_qty
    WHEN NEW.status IN (
      'approved','linked_to_exception','in_progress',
      'completed','closed_no_action'
    ) THEN NEW.approved_remedy_qty
    ELSE 0
  END;

  IF v_existing_qty + COALESCE(v_new_qty, 0)
       > v_disposition.quantity + 0.0005
  THEN
    RAISE EXCEPTION
      'Proposed/approved remedy quantity exceeds the affected receipt quantity.';
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.physical_remedy_allocation_guard_v1()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.physical_remedy_allocation_guard_v2()
  FROM PUBLIC, anon, authenticated;

-- Independent clean-replay reference for the restored v1 canonical body and
-- metadata. It is never attached to a trigger and is dropped before commit.
CREATE FUNCTION pg_temp.b4_foundation_guard_reference()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_disposition public.shipper_package_receipt_line_dispositions%ROWTYPE;
  v_review public.physical_receipt_reviews%ROWTYPE;
  v_dispute_line_supplier_id uuid;
  v_dispute_order_id uuid;
  v_dispute_id uuid;
  v_child_order public.orders%ROWTYPE;
  v_child_allocation_order_id uuid;
  v_existing_qty numeric := 0;
  v_new_qty numeric := 0;
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION
      'Physical remedy provenance cannot be deleted; cancel or reroute it through an audited transition.';
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'proposed'
       OR NEW.approved_remedy_type IS NOT NULL
       OR NEW.approved_remedy_qty IS NOT NULL
       OR NEW.approved_by_staff_id IS NOT NULL
       OR NEW.approved_at IS NOT NULL
       OR NEW.dispute_line_id IS NOT NULL
       OR NEW.replacement_child_order_id IS NOT NULL
       OR NEW.replacement_child_tracking_allocation_id IS NOT NULL
       OR NEW.rerouted_to_remedy_allocation_id IS NOT NULL
    THEN RAISE EXCEPTION 'A remedy allocation must start as the importer proposal only.'; END IF;
  ELSE
    IF NEW.physical_receipt_review_id IS DISTINCT FROM OLD.physical_receipt_review_id
       OR NEW.receipt_line_disposition_id IS DISTINCT FROM OLD.receipt_line_disposition_id
       OR NEW.tracking_line_allocation_id IS DISTINCT FROM OLD.tracking_line_allocation_id
       OR NEW.supplier_invoice_line_id IS DISTINCT FROM OLD.supplier_invoice_line_id
       OR NEW.proposed_remedy_type IS DISTINCT FROM OLD.proposed_remedy_type
       OR NEW.proposed_remedy_qty IS DISTINCT FROM OLD.proposed_remedy_qty
       OR NEW.proposed_by_operator_id IS DISTINCT FROM OLD.proposed_by_operator_id
       OR NEW.proposed_at IS DISTINCT FROM OLD.proposed_at
       OR NEW.created_at IS DISTINCT FROM OLD.created_at
    THEN RAISE EXCEPTION 'Importer remedy proposal and exact source identity are immutable; reroute with a new allocation.'; END IF;
    IF OLD.approved_at IS NOT NULL AND (
      NEW.approved_remedy_type IS DISTINCT FROM OLD.approved_remedy_type OR
      NEW.approved_remedy_qty IS DISTINCT FROM OLD.approved_remedy_qty OR
      NEW.approved_by_staff_id IS DISTINCT FROM OLD.approved_by_staff_id OR
      NEW.approved_at IS DISTINCT FROM OLD.approved_at
    ) THEN RAISE EXCEPTION 'Supervisor-approved remedy route and quantity are immutable; reroute with a new allocation.'; END IF;
    IF OLD.status IN ('completed','closed_no_action','rerouted') AND NEW.status IS DISTINCT FROM OLD.status
    THEN RAISE EXCEPTION 'Completed, no-action or rerouted remedy state cannot be reopened.'; END IF;
    IF NEW.status IS DISTINCT FROM OLD.status AND NOT (
      (OLD.status='proposed' AND NEW.status IN ('approved','cancelled','rerouted')) OR
      (OLD.status='approved' AND NEW.status IN ('linked_to_exception','in_progress','completed','closed_no_action','cancelled','rerouted')) OR
      (OLD.status='linked_to_exception' AND NEW.status IN ('in_progress','completed','cancelled','rerouted')) OR
      (OLD.status='in_progress' AND NEW.status IN ('completed','cancelled','rerouted')) OR
      (OLD.status='cancelled' AND NEW.status='rerouted')
    ) THEN RAISE EXCEPTION 'Invalid physical remedy state transition: % -> %', OLD.status, NEW.status; END IF;
  END IF;
  SELECT disposition.* INTO v_disposition FROM public.shipper_package_receipt_line_dispositions disposition WHERE disposition.id=NEW.receipt_line_disposition_id FOR UPDATE;
  SELECT review_row.* INTO v_review FROM public.physical_receipt_reviews review_row WHERE review_row.id=NEW.physical_receipt_review_id FOR SHARE;
  IF v_disposition.id IS NULL OR v_disposition.disposition_type='clean' OR v_review.id IS NULL OR v_review.receipt_id IS DISTINCT FROM v_disposition.receipt_id OR v_disposition.tracking_line_allocation_id IS DISTINCT FROM NEW.tracking_line_allocation_id OR v_disposition.supplier_invoice_line_id IS DISTINCT FROM NEW.supplier_invoice_line_id
  THEN RAISE EXCEPTION 'Physical remedy does not match one affected receipt disposition and review.'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.operators operator_row JOIN public.operator_importers access_row ON access_row.operator_id=operator_row.id AND access_row.importer_id=v_review.importer_id AND access_row.revoked_at IS NULL WHERE operator_row.id=NEW.proposed_by_operator_id AND COALESCE(operator_row.active,true)=true)
  THEN RAISE EXCEPTION 'Remedy proposal actor is not an active operator for the review importer.'; END IF;
  IF NEW.status IN ('approved','linked_to_exception','in_progress','completed','closed_no_action') THEN
    IF NEW.approved_remedy_type IS NULL OR NEW.approved_remedy_qty IS NULL OR NEW.approved_by_staff_id IS NULL OR NEW.approved_at IS NULL OR NOT EXISTS (SELECT 1 FROM public.staff staff_row WHERE staff_row.id=NEW.approved_by_staff_id AND COALESCE(staff_row.active,true)=true)
    THEN RAISE EXCEPTION 'Approved remedy state requires the exact supervisor-approved route, quantity, actor and timestamp.'; END IF;
  END IF;
  IF NEW.approved_remedy_type='replacement' THEN
    IF NEW.supplier_cost_mode NOT IN ('free_replacement','charged_repurchase','pending_supplier_evidence') THEN RAISE EXCEPTION 'Approved replacement requires an explicit supplier cost mode.'; END IF;
  ELSIF NEW.approved_remedy_type IS NOT NULL THEN
    IF COALESCE(NEW.supplier_cost_mode,'not_applicable')<>'not_applicable' OR NEW.replacement_child_order_id IS NOT NULL OR NEW.replacement_child_tracking_allocation_id IS NOT NULL THEN RAISE EXCEPTION 'Non-replacement remedy cannot carry replacement supplier cost or child provenance.'; END IF;
  ELSE
    IF NEW.supplier_cost_mode IS NOT NULL OR NEW.replacement_child_order_id IS NOT NULL OR NEW.replacement_child_tracking_allocation_id IS NOT NULL THEN RAISE EXCEPTION 'Unapproved proposal cannot carry replacement cost or child provenance.'; END IF;
  END IF;
  IF NEW.status IN ('linked_to_exception','in_progress','completed') AND NEW.approved_remedy_type IN ('refund','replacement') AND NEW.dispute_line_id IS NULL THEN RAISE EXCEPTION 'Progressed refund/replacement remedy requires its exact existing dispute line.'; END IF;
  IF NEW.dispute_line_id IS NOT NULL THEN
    SELECT dispute_line.supplier_invoice_line_id, dispute_row.order_id, dispute_row.id INTO v_dispute_line_supplier_id,v_dispute_order_id,v_dispute_id FROM public.dispute_lines dispute_line JOIN public.disputes dispute_row ON dispute_row.id=dispute_line.dispute_id WHERE dispute_line.id=NEW.dispute_line_id;
    IF v_dispute_line_supplier_id IS DISTINCT FROM NEW.supplier_invoice_line_id OR v_dispute_order_id IS DISTINCT FROM v_review.order_id OR (v_review.linked_dispute_id IS NOT NULL AND v_review.linked_dispute_id IS DISTINCT FROM v_dispute_id) THEN RAISE EXCEPTION 'Physical remedy dispute line does not match the exact source line, order and linked dispute.'; END IF;
  END IF;
  IF NEW.approved_remedy_type='replacement' AND NEW.status IN ('in_progress','completed') THEN
    IF NEW.replacement_child_order_id IS NULL THEN RAISE EXCEPTION 'Replacement in progress or completed requires its exact replacement child order.'; END IF;
    SELECT child.* INTO v_child_order FROM public.orders child WHERE child.id=NEW.replacement_child_order_id;
    IF v_child_order.id IS NULL OR v_child_order.order_type IS DISTINCT FROM 'replacement_child' OR v_child_order.parent_order_id IS DISTINCT FROM v_review.order_id OR (v_child_order.replacement_source_dispute_line_id IS NOT NULL AND v_child_order.replacement_source_dispute_line_id IS DISTINCT FROM NEW.dispute_line_id) THEN RAISE EXCEPTION 'Replacement child does not match the parent order and source dispute line.'; END IF;
  END IF;
  IF NEW.status='completed' AND NEW.approved_remedy_type='replacement' THEN
    IF NEW.replacement_child_tracking_allocation_id IS NULL THEN RAISE EXCEPTION 'Completed replacement requires exact replacement-child tracking allocation provenance.'; END IF;
    SELECT allocation.order_id INTO v_child_allocation_order_id FROM public.order_tracking_line_allocations allocation WHERE allocation.id=NEW.replacement_child_tracking_allocation_id;
    IF v_child_allocation_order_id IS DISTINCT FROM NEW.replacement_child_order_id THEN RAISE EXCEPTION 'Replacement-child tracking allocation does not belong to the replacement child order.'; END IF;
  END IF;
  IF NEW.status='closed_no_action' AND NEW.approved_remedy_type IS DISTINCT FROM 'no_action' THEN RAISE EXCEPTION 'Closed-no-action status requires an approved no-action route.'; END IF;
  IF NEW.status='rerouted' THEN
    IF NEW.rerouted_to_remedy_allocation_id IS NULL OR NEW.rerouted_to_remedy_allocation_id=NEW.id OR NOT EXISTS (SELECT 1 FROM public.physical_exception_remedy_allocations target WHERE target.id=NEW.rerouted_to_remedy_allocation_id AND target.physical_receipt_review_id=NEW.physical_receipt_review_id AND target.receipt_line_disposition_id=NEW.receipt_line_disposition_id) THEN RAISE EXCEPTION 'Rerouted remedy must identify a different allocation for the same review and affected disposition.'; END IF;
  ELSIF NEW.rerouted_to_remedy_allocation_id IS NOT NULL THEN RAISE EXCEPTION 'Only a rerouted remedy may carry a reroute target.'; END IF;
  SELECT COALESCE(SUM(CASE WHEN remedy_row.status='proposed' THEN remedy_row.proposed_remedy_qty WHEN remedy_row.status IN ('approved','linked_to_exception','in_progress','completed','closed_no_action') THEN remedy_row.approved_remedy_qty ELSE 0 END),0)::numeric INTO v_existing_qty FROM public.physical_exception_remedy_allocations remedy_row WHERE remedy_row.receipt_line_disposition_id=NEW.receipt_line_disposition_id AND (TG_OP='INSERT' OR remedy_row.id<>NEW.id);
  v_new_qty := CASE WHEN NEW.status='proposed' THEN NEW.proposed_remedy_qty WHEN NEW.status IN ('approved','linked_to_exception','in_progress','completed','closed_no_action') THEN NEW.approved_remedy_qty ELSE 0 END;
  IF v_existing_qty+COALESCE(v_new_qty,0)>v_disposition.quantity+0.0005 THEN RAISE EXCEPTION 'Proposed/approved remedy quantity exceeds the affected receipt quantity.'; END IF;
  NEW.updated_at:=now(); RETURN NEW;
END;
$function$;

DO $guard_postflight$
DECLARE
  v_v1_digest text;
  v_reference_digest text;
  v_v2_fingerprint text;
  v_trigger_oid oid;
  v_v2_oid oid;
  v_v1_owner text;
  v_v2_owner text;
BEGIN
  SELECT md5(concat_ws('|', p.prosrc, p.prolang::regproc::text, p.provolatile::text,
                       p.prosecdef::text, COALESCE(array_to_string(p.proconfig, ','), '')))
  INTO v_v1_digest
  FROM pg_proc p
  WHERE p.oid = 'public.physical_remedy_allocation_guard_v1()'::regprocedure;

  SELECT md5(concat_ws('|', p.prosrc, p.prolang::regproc::text, p.provolatile::text,
                       p.prosecdef::text, COALESCE(array_to_string(p.proconfig, ','), '')))
  INTO v_reference_digest
  FROM pg_proc p
  WHERE p.oid = 'pg_temp.b4_foundation_guard_reference()'::regprocedure;

  IF v_v1_digest IS DISTINCT FROM v_reference_digest THEN
    RAISE EXCEPTION 'Restored foundation v1 differs from the clean-replay reference (% versus %).', v_v1_digest, v_reference_digest;
  END IF;

  SELECT md5(pg_get_functiondef('public.physical_remedy_allocation_guard_v2()'::regprocedure)),
         'public.physical_remedy_allocation_guard_v2()'::regprocedure::oid
  INTO v_v2_fingerprint, v_v2_oid;

  IF v_v2_fingerprint IS DISTINCT FROM '32e1d3eb9161cdc3e09114edb8c0d3c0' THEN
    RAISE EXCEPTION 'Versioned Build-2 v2 body changed: %', v_v2_fingerprint;
  END IF;

  SELECT t.tgfoid INTO v_trigger_oid
  FROM pg_trigger t
  WHERE t.tgrelid='public.physical_exception_remedy_allocations'::regclass
    AND t.tgname='trg_physical_remedy_allocation_guard_v1'
    AND NOT t.tgisinternal;

  IF v_trigger_oid IS DISTINCT FROM v_v2_oid THEN
    RAISE EXCEPTION 'Hybrid remedy trigger did not retain the exact renamed v2 object binding.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_trigger t
    WHERE t.tgfoid='public.physical_remedy_allocation_guard_v1()'::regprocedure
      AND NOT t.tgisinternal
  ) THEN
    RAISE EXCEPTION 'Restored foundation v1 was unexpectedly attached to a trigger.';
  END IF;

  SELECT pg_get_userbyid(p.proowner) INTO v_v1_owner
  FROM pg_proc p WHERE p.oid='public.physical_remedy_allocation_guard_v1()'::regprocedure;
  SELECT pg_get_userbyid(p.proowner) INTO v_v2_owner
  FROM pg_proc p WHERE p.oid='public.physical_remedy_allocation_guard_v2()'::regprocedure;

  IF v_v1_owner IS DISTINCT FROM v_v2_owner THEN
    RAISE EXCEPTION 'Guard ownership diverged: v1 %, v2 %', v_v1_owner, v_v2_owner;
  END IF;

  IF has_function_privilege('PUBLIC','public.physical_remedy_allocation_guard_v1()','EXECUTE')
     OR has_function_privilege('anon','public.physical_remedy_allocation_guard_v1()','EXECUTE')
     OR has_function_privilege('authenticated','public.physical_remedy_allocation_guard_v1()','EXECUTE')
     OR has_function_privilege('PUBLIC','public.physical_remedy_allocation_guard_v2()','EXECUTE')
     OR has_function_privilege('anon','public.physical_remedy_allocation_guard_v2()','EXECUTE')
     OR has_function_privilege('authenticated','public.physical_remedy_allocation_guard_v2()','EXECUTE')
  THEN
    RAISE EXCEPTION 'One or more internal physical remedy guards are directly executable.';
  END IF;
END
$guard_postflight$;

DROP FUNCTION pg_temp.b4_foundation_guard_reference();

-- Preserve the exact Build-4 calculation under an additive v2 name.
CREATE VIEW public.order_reconciliation_v2_vw AS
WITH authoritative_supplier_lines AS (
  SELECT si.order_id,
         sil.id AS supplier_invoice_line_id,
         COALESCE(sil.qty_confirmed, 0)::bigint AS qty_confirmed,
         COALESCE(sil.amount_confirmed, 0)::numeric AS amount_confirmed
  FROM public.supplier_invoices si
  JOIN public.supplier_invoice_lines sil ON sil.supplier_invoice_id = si.id
  WHERE si.is_current_for_order = true
    AND si.review_status IN ('approved_current','ref_corrected_approved')
    AND si.blocked_from_sage_yn = false
    AND si.superseded_by_supplier_invoice_id IS NULL
    AND sil.eligible_for_invoice_yn = 'Y'
),
supplier_line_totals AS (
  SELECT order_id,
         COALESCE(SUM(qty_confirmed), 0::numeric)::bigint AS qty_progressed_invoiceable,
         COALESCE(SUM(amount_confirmed), 0::numeric) AS amount_progressed_invoiceable_gbp
  FROM authoritative_supplier_lines GROUP BY order_id
),
dispute_line_totals AS (
  SELECT d.order_id,
         COALESCE(SUM(CASE WHEN dl.line_status='resolved' AND asl.supplier_invoice_line_id IS NULL THEN dl.qty_impact ELSE 0 END),0::bigint) AS qty_resolved_noninvoiceable,
         COALESCE(SUM(CASE WHEN dl.line_status='resolved' AND asl.supplier_invoice_line_id IS NULL THEN dl.amount_impact_gbp ELSE 0::numeric END),0::numeric) AS amount_resolved_dispute_gbp
  FROM public.disputes d
  JOIN public.dispute_lines dl ON dl.dispute_id=d.id
  LEFT JOIN authoritative_supplier_lines asl ON asl.order_id=d.order_id AND asl.supplier_invoice_line_id=dl.supplier_invoice_line_id
  GROUP BY d.order_id
),
resolved_nonphysical AS (
  SELECT r.order_id,
         COALESCE(SUM(CASE r.financial_type WHEN 'delivery' THEN ABS(COALESCE(r.amount_gbp,0::numeric)) WHEN 'fee' THEN ABS(COALESCE(r.amount_gbp,0::numeric)) WHEN 'discount' THEN -ABS(COALESCE(r.amount_gbp,0::numeric)) WHEN 'zero_value_delivery' THEN 0::numeric ELSE 0::numeric END),0::numeric) AS signed_nonphysical_amount_gbp
  FROM public.supplier_invoice_line_resolutions r
  WHERE r.active=true AND r.resolution_type='non_physical_financial'
  GROUP BY r.order_id
),
reconciled AS (
  SELECT o.id AS order_id,
         o.total_qty_declared AS qty_target,
         COALESCE(slt.qty_progressed_invoiceable,0::bigint) AS qty_progressed_invoiceable,
         COALESCE(dlt.qty_resolved_noninvoiceable,0::bigint) AS qty_resolved_noninvoiceable,
         o.total_qty_declared-COALESCE(slt.qty_progressed_invoiceable,0::bigint)-COALESCE(dlt.qty_resolved_noninvoiceable,0::bigint) AS qty_unresolved,
         o.order_total_gbp_declared AS amount_target_gbp,
         COALESCE(slt.amount_progressed_invoiceable_gbp,0::numeric) AS amount_progressed_invoiceable_gbp,
         COALESCE(dlt.amount_resolved_dispute_gbp,0::numeric)+COALESCE(rn.signed_nonphysical_amount_gbp,0::numeric) AS amount_resolved_noninvoiceable_gbp,
         o.order_total_gbp_declared-COALESCE(slt.amount_progressed_invoiceable_gbp,0::numeric)-COALESCE(dlt.amount_resolved_dispute_gbp,0::numeric)-COALESCE(rn.signed_nonphysical_amount_gbp,0::numeric) AS amount_unresolved_gbp,
         EXISTS(SELECT 1 FROM authoritative_supplier_lines released WHERE released.order_id=o.id) AS invoiceable_subset_released_yn
  FROM public.orders o
  LEFT JOIN supplier_line_totals slt ON slt.order_id=o.id
  LEFT JOIN dispute_line_totals dlt ON dlt.order_id=o.id
  LEFT JOIN resolved_nonphysical rn ON rn.order_id=o.id
)
SELECT r.order_id,r.qty_target,r.qty_progressed_invoiceable,r.qty_resolved_noninvoiceable,r.qty_unresolved,
       r.amount_target_gbp,r.amount_progressed_invoiceable_gbp,r.amount_resolved_noninvoiceable_gbp,r.amount_unresolved_gbp,
       r.invoiceable_subset_released_yn,
       (r.qty_unresolved=0 AND r.amount_unresolved_gbp=0::numeric
        AND r.qty_progressed_invoiceable+r.qty_resolved_noninvoiceable<=r.qty_target
        AND r.amount_progressed_invoiceable_gbp+r.amount_resolved_noninvoiceable_gbp<=r.amount_target_gbp) AS whole_order_cleared_yn,
       now() AS last_refreshed_at
FROM reconciled r;

COMMENT ON VIEW public.order_reconciliation_v2_vw IS
  'Versioned Build-4 authoritative-supplier reconciliation. Existing platform callers remain on public.order_reconciliation_vw.';
REVOKE ALL ON public.order_reconciliation_v2_vw FROM PUBLIC, anon;
GRANT SELECT ON public.order_reconciliation_v2_vw TO authenticated, service_role;

DO $v2_view_proof$
DECLARE
  v_expected text;
  v_actual text;
BEGIN
  SELECT snapshot_value INTO v_expected FROM b4_authority_correction_snapshot WHERE snapshot_key='build4_view_definition';
  SELECT definition INTO v_actual FROM pg_views WHERE schemaname='public' AND viewname='order_reconciliation_v2_vw';
  IF md5(v_actual) IS DISTINCT FROM md5(v_expected) THEN
    RAISE EXCEPTION 'Versioned Build-4 reconciliation body changed while moving to v2.';
  END IF;
END
$v2_view_proof$;

-- Restore the exact pre-Build-4 public authority while retaining object identity.
CREATE OR REPLACE VIEW public.order_reconciliation_vw AS
WITH resolved_nonphysical AS (
  SELECT r.order_id,
    COALESCE(SUM(CASE r.financial_type
      WHEN 'delivery' THEN ABS(COALESCE(r.amount_gbp,0))
      WHEN 'fee' THEN ABS(COALESCE(r.amount_gbp,0))
      WHEN 'discount' THEN -ABS(COALESCE(r.amount_gbp,0))
      WHEN 'zero_value_delivery' THEN 0::numeric ELSE 0::numeric END),0)::numeric AS signed_nonphysical_amount_gbp
  FROM public.supplier_invoice_line_resolutions r
  WHERE r.active=true AND r.resolution_type='non_physical_financial'
  GROUP BY r.order_id
)
SELECT o.id AS order_id,
  o.total_qty_declared AS qty_target,
  COALESCE(SUM(CASE WHEN sil.eligible_for_invoice_yn='Y' THEN sil.qty_confirmed ELSE 0 END),0) AS qty_progressed_invoiceable,
  COALESCE(SUM(CASE WHEN dl.line_status='resolved' THEN dl.qty_impact ELSE 0 END),0) AS qty_resolved_noninvoiceable,
  o.total_qty_declared-COALESCE(SUM(CASE WHEN sil.eligible_for_invoice_yn='Y' THEN sil.qty_confirmed ELSE 0 END),0)-COALESCE(SUM(CASE WHEN dl.line_status='resolved' THEN dl.qty_impact ELSE 0 END),0) AS qty_unresolved,
  o.order_total_gbp_declared AS amount_target_gbp,
  COALESCE(SUM(CASE WHEN sil.eligible_for_invoice_yn='Y' THEN sil.amount_confirmed ELSE 0 END),0) AS amount_progressed_invoiceable_gbp,
  COALESCE(SUM(CASE WHEN dl.line_status='resolved' THEN dl.amount_impact_gbp ELSE 0 END),0)+COALESCE(MAX(rn.signed_nonphysical_amount_gbp),0) AS amount_resolved_noninvoiceable_gbp,
  o.order_total_gbp_declared-COALESCE(SUM(CASE WHEN sil.eligible_for_invoice_yn='Y' THEN sil.amount_confirmed ELSE 0 END),0)-COALESCE(SUM(CASE WHEN dl.line_status='resolved' THEN dl.amount_impact_gbp ELSE 0 END),0)-COALESCE(MAX(rn.signed_nonphysical_amount_gbp),0) AS amount_unresolved_gbp,
  CASE WHEN EXISTS(SELECT 1 FROM public.supplier_invoice_lines sil2 JOIN public.supplier_invoices si2 ON si2.id=sil2.supplier_invoice_id WHERE si2.order_id=o.id AND sil2.eligible_for_invoice_yn='Y') THEN true ELSE false END AS invoiceable_subset_released_yn,
  CASE WHEN o.total_qty_declared-COALESCE(SUM(CASE WHEN sil.eligible_for_invoice_yn='Y' THEN sil.qty_confirmed ELSE 0 END),0)-COALESCE(SUM(CASE WHEN dl.line_status='resolved' THEN dl.qty_impact ELSE 0 END),0)=0
    AND o.order_total_gbp_declared-COALESCE(SUM(CASE WHEN sil.eligible_for_invoice_yn='Y' THEN sil.amount_confirmed ELSE 0 END),0)-COALESCE(SUM(CASE WHEN dl.line_status='resolved' THEN dl.amount_impact_gbp ELSE 0 END),0)-COALESCE(MAX(rn.signed_nonphysical_amount_gbp),0)=0 THEN true ELSE false END AS whole_order_cleared_yn,
  now() AS last_refreshed_at
FROM public.orders o
LEFT JOIN public.supplier_invoices si ON si.order_id=o.id
LEFT JOIN public.supplier_invoice_lines sil ON sil.supplier_invoice_id=si.id
LEFT JOIN public.disputes d ON d.order_id=o.id
LEFT JOIN public.dispute_lines dl ON dl.dispute_id=d.id
LEFT JOIN resolved_nonphysical rn ON rn.order_id=o.id
GROUP BY o.id,o.total_qty_declared,o.order_total_gbp_declared;

COMMENT ON VIEW public.order_reconciliation_vw IS
  'Baseline order reconciliation preserved, with active non-physical financial resolutions added once per order using explicit commercial sign: delivery/fee positive, discount negative and zero-value delivery zero. Ambiguous types remain unresolved.';

-- Redirect only the new Build-4 anomaly model to v2; all classifications remain unchanged.
CREATE OR REPLACE VIEW public.order_reconciliation_anomalies_v1 AS
WITH raw_eligible AS (
  SELECT si.order_id,COALESCE(SUM(COALESCE(sil.qty_confirmed,0)),0)::numeric AS raw_qty,COALESCE(SUM(COALESCE(sil.amount_confirmed,0)),0)::numeric AS raw_amount_gbp
  FROM public.supplier_invoices si JOIN public.supplier_invoice_lines sil ON sil.supplier_invoice_id=si.id
  WHERE sil.eligible_for_invoice_yn='Y' GROUP BY si.order_id
),
non_authoritative AS (
  SELECT si.order_id,COALESCE(SUM(COALESCE(sil.qty_confirmed,0)),0)::numeric AS non_authoritative_qty,COALESCE(SUM(COALESCE(sil.amount_confirmed,0)),0)::numeric AS non_authoritative_amount_gbp,
    jsonb_agg(jsonb_build_object('supplier_invoice_id',si.id,'invoice_ref',si.invoice_ref,'review_status',si.review_status,'blocked_from_sage_yn',si.blocked_from_sage_yn,'is_current_for_order',si.is_current_for_order,'superseded_by_supplier_invoice_id',si.superseded_by_supplier_invoice_id,'supplier_invoice_line_id',sil.id,'qty_confirmed',sil.qty_confirmed,'amount_confirmed',sil.amount_confirmed) ORDER BY si.uploaded_at,si.id,sil.line_order,sil.id) AS evidence_json
  FROM public.supplier_invoices si JOIN public.supplier_invoice_lines sil ON sil.supplier_invoice_id=si.id
  WHERE sil.eligible_for_invoice_yn='Y' AND (si.is_current_for_order IS DISTINCT FROM true OR si.review_status IS NULL OR si.review_status NOT IN ('approved_current','ref_corrected_approved') OR si.blocked_from_sage_yn IS DISTINCT FROM false OR si.superseded_by_supplier_invoice_id IS NOT NULL)
  GROUP BY si.order_id
),
canonical AS (SELECT * FROM public.order_reconciliation_v2_vw)
SELECT c.order_id,'AUTHORITATIVE_QTY_OVER_PROGRESS'::text AS anomaly_code,c.qty_target::numeric AS qty_target,c.qty_progressed_invoiceable::numeric AS qty_observed,greatest(c.qty_progressed_invoiceable::numeric-c.qty_target::numeric,0::numeric) AS qty_over,c.amount_target_gbp,c.amount_progressed_invoiceable_gbp AS amount_observed_gbp,greatest(c.amount_progressed_invoiceable_gbp-c.amount_target_gbp,0::numeric) AS amount_over_gbp,jsonb_build_object('source','canonical_authoritative_supplier_lines') AS detail_json,now() AS last_refreshed_at FROM canonical c WHERE c.qty_progressed_invoiceable>c.qty_target
UNION ALL SELECT c.order_id,'AUTHORITATIVE_AMOUNT_OVER_PROGRESS',c.qty_target::numeric,c.qty_progressed_invoiceable::numeric,greatest(c.qty_progressed_invoiceable::numeric-c.qty_target::numeric,0::numeric),c.amount_target_gbp,c.amount_progressed_invoiceable_gbp,greatest(c.amount_progressed_invoiceable_gbp-c.amount_target_gbp,0::numeric),jsonb_build_object('source','canonical_authoritative_supplier_lines'),now() FROM canonical c WHERE c.amount_progressed_invoiceable_gbp>c.amount_target_gbp
UNION ALL SELECT o.id,'NON_AUTHORITATIVE_INVOICEABLE_EVIDENCE',o.total_qty_declared::numeric,na.non_authoritative_qty,greatest(na.non_authoritative_qty-o.total_qty_declared::numeric,0::numeric),o.order_total_gbp_declared,na.non_authoritative_amount_gbp,greatest(na.non_authoritative_amount_gbp-o.order_total_gbp_declared,0::numeric),jsonb_build_object('evidence',na.evidence_json),now() FROM public.orders o JOIN non_authoritative na ON na.order_id=o.id WHERE na.non_authoritative_qty<>0 OR na.non_authoritative_amount_gbp<>0
UNION ALL SELECT o.id,'RAW_QTY_OVER_PROGRESS',o.total_qty_declared::numeric,raw.raw_qty,greatest(raw.raw_qty-o.total_qty_declared::numeric,0::numeric),o.order_total_gbp_declared,raw.raw_amount_gbp,greatest(raw.raw_amount_gbp-o.order_total_gbp_declared,0::numeric),jsonb_build_object('source','all_eligible_lines_regardless_of_invoice_authority'),now() FROM public.orders o JOIN raw_eligible raw ON raw.order_id=o.id WHERE raw.raw_qty>o.total_qty_declared::numeric
UNION ALL SELECT o.id,'RAW_AMOUNT_OVER_PROGRESS',o.total_qty_declared::numeric,raw.raw_qty,greatest(raw.raw_qty-o.total_qty_declared::numeric,0::numeric),o.order_total_gbp_declared,raw.raw_amount_gbp,greatest(raw.raw_amount_gbp-o.order_total_gbp_declared,0::numeric),jsonb_build_object('source','all_eligible_lines_regardless_of_invoice_authority'),now() FROM public.orders o JOIN raw_eligible raw ON raw.order_id=o.id WHERE raw.raw_amount_gbp>o.order_total_gbp_declared;

COMMENT ON VIEW public.order_reconciliation_anomalies_v1 IS
  'Read-only Build 4 anomaly model using the versioned authoritative-supplier reconciliation authority.';
REVOKE ALL ON public.order_reconciliation_anomalies_v1 FROM PUBLIC, anon;
GRANT SELECT ON public.order_reconciliation_anomalies_v1 TO authenticated, service_role;

DO $final_proof$
DECLARE
  v_legacy_fingerprint text;
  v_columns text[];
  v_owner text;
  v_acl text;
BEGIN
  SELECT md5(definition) INTO v_legacy_fingerprint
  FROM pg_views WHERE schemaname='public' AND viewname='order_reconciliation_vw';
  IF v_legacy_fingerprint IS DISTINCT FROM '89cc95922a2b8ec1fa040ba79f12907a' THEN
    RAISE EXCEPTION 'Legacy reconciliation was not restored exactly: %', v_legacy_fingerprint;
  END IF;

  SELECT array_agg(column_name ORDER BY ordinal_position) INTO v_columns
  FROM information_schema.columns WHERE table_schema='public' AND table_name='order_reconciliation_vw';
  IF v_columns IS DISTINCT FROM ARRAY['order_id','qty_target','qty_progressed_invoiceable','qty_resolved_noninvoiceable','qty_unresolved','amount_target_gbp','amount_progressed_invoiceable_gbp','amount_resolved_noninvoiceable_gbp','amount_unresolved_gbp','invoiceable_subset_released_yn','whole_order_cleared_yn','last_refreshed_at']::text[] THEN
    RAISE EXCEPTION 'Legacy reconciliation columns changed: %', v_columns;
  END IF;

  SELECT pg_get_userbyid(c.relowner),COALESCE(c.relacl::text,'') INTO v_owner,v_acl
  FROM pg_class c WHERE c.oid='public.order_reconciliation_vw'::regclass;
  IF v_owner IS DISTINCT FROM (SELECT snapshot_value FROM b4_authority_correction_snapshot WHERE snapshot_key='legacy_view_owner')
     OR v_acl IS DISTINCT FROM (SELECT snapshot_value FROM b4_authority_correction_snapshot WHERE snapshot_key='legacy_view_acl') THEN
    RAISE EXCEPTION 'Legacy reconciliation owner or grants changed.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_depend d
    WHERE d.objid='public.order_reconciliation_anomalies_v1'::regclass
      AND d.refobjid='public.order_reconciliation_v2_vw'::regclass
  ) OR EXISTS (
    SELECT 1 FROM pg_depend d
    WHERE d.objid='public.order_reconciliation_anomalies_v1'::regclass
      AND d.refobjid='public.order_reconciliation_vw'::regclass
  ) THEN
    RAISE EXCEPTION 'Build-4 anomaly dependency was not redirected exclusively to v2.';
  END IF;
END
$final_proof$;

-- Compare exact dependency identities. The only authorised change is removal of
-- anomaly-view dependencies from legacy and addition of its dependency on v2.
DO $dependency_proof$
BEGIN
  IF EXISTS (
    SELECT dependent_class,dependent_oid,dependent_subid,dependency_type,dependent_identity,referenced_subid
    FROM b4_legacy_dependents_before
    WHERE dependent_identity NOT LIKE '%order_reconciliation_anomalies_v1%'
    EXCEPT
    SELECT d.classid::regclass::text,d.objid,d.objsubid,d.deptype,
           pg_describe_object(d.classid,d.objid,d.objsubid),d.refobjsubid
    FROM pg_depend d
    WHERE d.refobjid='public.order_reconciliation_vw'::regclass
      AND pg_describe_object(d.classid,d.objid,d.objsubid) NOT LIKE '%order_reconciliation_anomalies_v1%'
  ) OR EXISTS (
    SELECT d.classid::regclass::text,d.objid,d.objsubid,d.deptype,
           pg_describe_object(d.classid,d.objid,d.objsubid),d.refobjsubid
    FROM pg_depend d
    WHERE d.refobjid='public.order_reconciliation_vw'::regclass
      AND pg_describe_object(d.classid,d.objid,d.objsubid) NOT LIKE '%order_reconciliation_anomalies_v1%'
    EXCEPT
    SELECT dependent_class,dependent_oid,dependent_subid,dependency_type,dependent_identity,referenced_subid
    FROM b4_legacy_dependents_before
    WHERE dependent_identity NOT LIKE '%order_reconciliation_anomalies_v1%'
  ) THEN
    RAISE EXCEPTION 'Unexpected legacy reconciliation dependency identity changed.';
  END IF;
END
$dependency_proof$;

NOTIFY pgrst, 'reload schema';
COMMIT;
