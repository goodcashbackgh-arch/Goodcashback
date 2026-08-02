-- Governed by docs/governing-pack/architecture/HYBRID_PHYSICAL_RECEIPT_BUILD_4_AUTHORITY_VERSIONING_CORRECTION_ADDENDUM_v1.md.
BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE TEMP TABLE authority_correction_state_v1 (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  guard_oid oid NOT NULL,
  guard_owner oid NOT NULL,
  guard_acl aclitem[],
  guard_canonical_md5 text NOT NULL,
  trigger_oid oid NOT NULL,
  trigger_function_oid oid NOT NULL,
  legacy_view_oid oid NOT NULL,
  legacy_view_owner oid NOT NULL,
  legacy_view_acl aclitem[]
) ON COMMIT DROP;

CREATE TEMP TABLE authority_correction_columns_before_v1 (
  ordinal_position integer PRIMARY KEY,
  column_name name NOT NULL,
  data_type text NOT NULL
) ON COMMIT DROP;

CREATE TEMP TABLE b4_legacy_dependents_before (
  dependent_classid oid NOT NULL,
  dependent_objid oid NOT NULL,
  dependent_objsubid integer NOT NULL,
  referenced_objsubid integer NOT NULL,
  dependent_class text NOT NULL,
  dependent_schema text,
  dependent_name text,
  dependent_identity text NOT NULL,
  dependency_type "char" NOT NULL,
  PRIMARY KEY (dependent_classid, dependent_objid, dependent_objsubid, referenced_objsubid, dependency_type)
) ON COMMIT DROP;

DO $initial_preflight$
BEGIN
  IF to_regprocedure('public.physical_remedy_allocation_guard_v1()') IS NULL
     OR to_regclass('public.physical_exception_remedy_allocations') IS NULL
     OR to_regclass('public.order_reconciliation_vw') IS NULL
     OR to_regclass('public.order_reconciliation_anomalies_v1') IS NULL THEN
    RAISE EXCEPTION 'Authority correction preflight: an expected source object is missing.';
  END IF;
  IF to_regprocedure('public.physical_remedy_allocation_guard_v2()') IS NOT NULL
     OR to_regclass('public.order_reconciliation_v2_vw') IS NOT NULL THEN
    RAISE EXCEPTION 'Authority correction preflight: a v2 target already exists.';
  END IF;
END
$initial_preflight$;

INSERT INTO authority_correction_columns_before_v1
SELECT a.attnum, a.attname, format_type(a.atttypid, a.atttypmod)
FROM pg_attribute a
WHERE a.attrelid = 'public.order_reconciliation_vw'::regclass
  AND a.attnum > 0 AND NOT a.attisdropped;

INSERT INTO b4_legacy_dependents_before
SELECT d.classid, d.objid, d.objsubid, d.refobjsubid,
       i.type, i.schema, i.name, i.identity, d.deptype
FROM pg_depend d
CROSS JOIN LATERAL pg_identify_object(d.classid, d.objid, d.objsubid) i
WHERE d.refobjid = 'public.order_reconciliation_vw'::regclass
  AND NOT EXISTS (
    SELECT 1 FROM pg_rewrite rw
    WHERE d.classid = 'pg_rewrite'::regclass AND rw.oid = d.objid
      AND rw.ev_class = 'public.order_reconciliation_anomalies_v1'::regclass
  );

DO $capture$
DECLARE
  v_definition_md5 text;
  v_trigger_count integer;
BEGIN
  SELECT md5(pg_get_functiondef(p.oid))
  INTO v_definition_md5
  FROM pg_proc p
  WHERE p.oid = 'public.physical_remedy_allocation_guard_v1()'::regprocedure;
  IF v_definition_md5 IS DISTINCT FROM '32e1d3eb9161cdc3e09114edb8c0d3c0' THEN
    RAISE EXCEPTION 'Authority correction preflight: unexpected Build 2 guard fingerprint %.', v_definition_md5;
  END IF;

  SELECT count(*) INTO v_trigger_count
  FROM pg_trigger t
  WHERE t.tgrelid = 'public.physical_exception_remedy_allocations'::regclass
    AND t.tgname = 'trg_physical_remedy_allocation_guard_v1' AND NOT t.tgisinternal;
  IF v_trigger_count <> 1 THEN
    RAISE EXCEPTION 'Authority correction preflight: expected exactly one remedy guard trigger, found %.', v_trigger_count;
  END IF;

  INSERT INTO authority_correction_state_v1(
    guard_oid, guard_owner, guard_acl, guard_canonical_md5,
    trigger_oid, trigger_function_oid, legacy_view_oid, legacy_view_owner, legacy_view_acl
  )
  SELECT p.oid, p.proowner, p.proacl,
         md5(concat_ws('|', p.prosrc, l.lanname, p.provolatile, p.prosecdef::text,
           p.proisstrict::text, p.proparallel, p.proleakproof::text,
           p.prorettype::regtype::text, p.proargtypes::text,
           COALESCE(array_to_string(p.proconfig, ','), ''))),
         t.oid, t.tgfoid, c.oid, c.relowner, c.relacl
  FROM pg_proc p
  JOIN pg_language l ON l.oid = p.prolang
  JOIN pg_trigger t ON t.tgfoid = p.oid
    AND t.tgrelid = 'public.physical_exception_remedy_allocations'::regclass
    AND t.tgname = 'trg_physical_remedy_allocation_guard_v1' AND NOT t.tgisinternal
  JOIN pg_class c ON c.oid = 'public.order_reconciliation_vw'::regclass
  WHERE p.oid = 'public.physical_remedy_allocation_guard_v1()'::regprocedure;

  IF NOT EXISTS (SELECT 1 FROM authority_correction_state_v1) THEN
    RAISE EXCEPTION 'Authority correction preflight: failed to capture source authority state.';
  END IF;
END
$capture$;

CREATE TEMP VIEW authority_correction_build4_reference_v1 AS
with authoritative_supplier_lines as (
  select si.order_id,
         sil.id as supplier_invoice_line_id,
         coalesce(sil.qty_confirmed, 0)::bigint as qty_confirmed,
         coalesce(sil.amount_confirmed, 0)::numeric as amount_confirmed
  from public.supplier_invoices si
  join public.supplier_invoice_lines sil on sil.supplier_invoice_id = si.id
  where si.is_current_for_order = true
    and si.review_status in ('approved_current','ref_corrected_approved')
    and si.blocked_from_sage_yn = false
    and si.superseded_by_supplier_invoice_id is null
    and sil.eligible_for_invoice_yn = 'Y'
),
supplier_line_totals as (
  select order_id,
         coalesce(sum(qty_confirmed), 0::numeric)::bigint as qty_progressed_invoiceable,
         coalesce(sum(amount_confirmed), 0::numeric) as amount_progressed_invoiceable_gbp
  from authoritative_supplier_lines
  group by order_id
),
dispute_line_totals as (
  select d.order_id,
         coalesce(sum(case when dl.line_status = 'resolved' and asl.supplier_invoice_line_id is null then dl.qty_impact else 0 end), 0::bigint) as qty_resolved_noninvoiceable,
         coalesce(sum(case when dl.line_status = 'resolved' and asl.supplier_invoice_line_id is null then dl.amount_impact_gbp else 0::numeric end), 0::numeric) as amount_resolved_dispute_gbp
  from public.disputes d
  join public.dispute_lines dl on dl.dispute_id = d.id
  left join authoritative_supplier_lines asl
    on asl.order_id = d.order_id
   and asl.supplier_invoice_line_id = dl.supplier_invoice_line_id
  group by d.order_id
),
resolved_nonphysical as (
  select r.order_id,
         coalesce(sum(
           case r.financial_type
             when 'delivery' then abs(coalesce(r.amount_gbp, 0::numeric))
             when 'fee' then abs(coalesce(r.amount_gbp, 0::numeric))
             when 'discount' then -abs(coalesce(r.amount_gbp, 0::numeric))
             when 'zero_value_delivery' then 0::numeric
             else 0::numeric
           end
         ), 0::numeric) as signed_nonphysical_amount_gbp
  from public.supplier_invoice_line_resolutions r
  where r.active = true and r.resolution_type = 'non_physical_financial'
  group by r.order_id
),
reconciled as (
  select o.id as order_id,
         o.total_qty_declared as qty_target,
         coalesce(slt.qty_progressed_invoiceable, 0::bigint) as qty_progressed_invoiceable,
         coalesce(dlt.qty_resolved_noninvoiceable, 0::bigint) as qty_resolved_noninvoiceable,
         o.total_qty_declared - coalesce(slt.qty_progressed_invoiceable, 0::bigint) - coalesce(dlt.qty_resolved_noninvoiceable, 0::bigint) as qty_unresolved,
         o.order_total_gbp_declared as amount_target_gbp,
         coalesce(slt.amount_progressed_invoiceable_gbp, 0::numeric) as amount_progressed_invoiceable_gbp,
         coalesce(dlt.amount_resolved_dispute_gbp, 0::numeric) + coalesce(rn.signed_nonphysical_amount_gbp, 0::numeric) as amount_resolved_noninvoiceable_gbp,
         o.order_total_gbp_declared - coalesce(slt.amount_progressed_invoiceable_gbp, 0::numeric) - coalesce(dlt.amount_resolved_dispute_gbp, 0::numeric) - coalesce(rn.signed_nonphysical_amount_gbp, 0::numeric) as amount_unresolved_gbp,
         exists (select 1 from authoritative_supplier_lines released where released.order_id = o.id) as invoiceable_subset_released_yn
  from public.orders o
  left join supplier_line_totals slt on slt.order_id = o.id
  left join dispute_line_totals dlt on dlt.order_id = o.id
  left join resolved_nonphysical rn on rn.order_id = o.id
)
select r.order_id,
       r.qty_target,
       r.qty_progressed_invoiceable,
       r.qty_resolved_noninvoiceable,
       r.qty_unresolved,
       r.amount_target_gbp,
       r.amount_progressed_invoiceable_gbp,
       r.amount_resolved_noninvoiceable_gbp,
       r.amount_unresolved_gbp,
       r.invoiceable_subset_released_yn,
       (
         r.qty_unresolved = 0
         and r.amount_unresolved_gbp = 0::numeric
         and r.qty_progressed_invoiceable + r.qty_resolved_noninvoiceable <= r.qty_target
         and r.amount_progressed_invoiceable_gbp + r.amount_resolved_noninvoiceable_gbp <= r.amount_target_gbp
       ) as whole_order_cleared_yn,
       now() as last_refreshed_at
from reconciled r;

CREATE TEMP VIEW authority_correction_anomaly_reference_v1 AS
with raw_eligible as (
  select si.order_id,
         coalesce(sum(coalesce(sil.qty_confirmed, 0)), 0)::numeric as raw_qty,
         coalesce(sum(coalesce(sil.amount_confirmed, 0)), 0)::numeric as raw_amount_gbp
  from public.supplier_invoices si
  join public.supplier_invoice_lines sil on sil.supplier_invoice_id = si.id
  where sil.eligible_for_invoice_yn = 'Y'
  group by si.order_id
),
non_authoritative as (
  select si.order_id,
         coalesce(sum(coalesce(sil.qty_confirmed, 0)), 0)::numeric as non_authoritative_qty,
         coalesce(sum(coalesce(sil.amount_confirmed, 0)), 0)::numeric as non_authoritative_amount_gbp,
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
           ) order by si.uploaded_at, si.id, sil.line_order, sil.id
         ) as evidence_json
  from public.supplier_invoices si
  join public.supplier_invoice_lines sil on sil.supplier_invoice_id = si.id
  where sil.eligible_for_invoice_yn = 'Y'
    and (
      si.is_current_for_order is distinct from true
      or si.review_status is null
      or si.review_status not in ('approved_current','ref_corrected_approved')
      or si.blocked_from_sage_yn is distinct from false
      or si.superseded_by_supplier_invoice_id is not null
    )
  group by si.order_id
),
canonical as (select * from public.order_reconciliation_vw)
select c.order_id,
       'AUTHORITATIVE_QTY_OVER_PROGRESS'::text as anomaly_code,
       c.qty_target::numeric as qty_target,
       c.qty_progressed_invoiceable::numeric as qty_observed,
       greatest(c.qty_progressed_invoiceable::numeric - c.qty_target::numeric, 0::numeric) as qty_over,
       c.amount_target_gbp,
       c.amount_progressed_invoiceable_gbp as amount_observed_gbp,
       greatest(c.amount_progressed_invoiceable_gbp - c.amount_target_gbp, 0::numeric) as amount_over_gbp,
       jsonb_build_object('source','canonical_authoritative_supplier_lines') as detail_json,
       now() as last_refreshed_at
from canonical c
where c.qty_progressed_invoiceable > c.qty_target
union all
select c.order_id,
       'AUTHORITATIVE_AMOUNT_OVER_PROGRESS',
       c.qty_target::numeric,
       c.qty_progressed_invoiceable::numeric,
       greatest(c.qty_progressed_invoiceable::numeric - c.qty_target::numeric, 0::numeric),
       c.amount_target_gbp,
       c.amount_progressed_invoiceable_gbp,
       greatest(c.amount_progressed_invoiceable_gbp - c.amount_target_gbp, 0::numeric),
       jsonb_build_object('source','canonical_authoritative_supplier_lines'),
       now()
from canonical c
where c.amount_progressed_invoiceable_gbp > c.amount_target_gbp
union all
select o.id,
       'NON_AUTHORITATIVE_INVOICEABLE_EVIDENCE',
       o.total_qty_declared::numeric,
       na.non_authoritative_qty,
       greatest(na.non_authoritative_qty - o.total_qty_declared::numeric, 0::numeric),
       o.order_total_gbp_declared,
       na.non_authoritative_amount_gbp,
       greatest(na.non_authoritative_amount_gbp - o.order_total_gbp_declared, 0::numeric),
       jsonb_build_object('evidence', na.evidence_json),
       now()
from public.orders o
join non_authoritative na on na.order_id = o.id
where na.non_authoritative_qty <> 0 or na.non_authoritative_amount_gbp <> 0
union all
select o.id,
       'RAW_QTY_OVER_PROGRESS',
       o.total_qty_declared::numeric,
       raw.raw_qty,
       greatest(raw.raw_qty - o.total_qty_declared::numeric, 0::numeric),
       o.order_total_gbp_declared,
       raw.raw_amount_gbp,
       greatest(raw.raw_amount_gbp - o.order_total_gbp_declared, 0::numeric),
       jsonb_build_object('source','all_eligible_lines_regardless_of_invoice_authority'),
       now()
from public.orders o
join raw_eligible raw on raw.order_id = o.id
where raw.raw_qty > o.total_qty_declared::numeric
union all
select o.id,
       'RAW_AMOUNT_OVER_PROGRESS',
       o.total_qty_declared::numeric,
       raw.raw_qty,
       greatest(raw.raw_qty - o.total_qty_declared::numeric, 0::numeric),
       o.order_total_gbp_declared,
       raw.raw_amount_gbp,
       greatest(raw.raw_amount_gbp - o.order_total_gbp_declared, 0::numeric),
       jsonb_build_object('source','all_eligible_lines_regardless_of_invoice_authority'),
       now()
from public.orders o
join raw_eligible raw on raw.order_id = o.id
where raw.raw_amount_gbp > o.order_total_gbp_declared;

DO $definition_preflight$
DECLARE
  v_installed text;
  v_frozen text;
BEGIN
  SELECT regexp_replace(pg_get_viewdef('public.order_reconciliation_vw'::regclass, true), '\s+', '', 'g'),
         regexp_replace(pg_get_viewdef('authority_correction_build4_reference_v1'::regclass, true), '\s+', '', 'g')
    INTO v_installed, v_frozen;
  IF v_installed IS DISTINCT FROM v_frozen THEN
    RAISE EXCEPTION 'Authority correction preflight: installed reconciliation is not the frozen Build 4 definition.';
  END IF;

  SELECT regexp_replace(pg_get_viewdef('public.order_reconciliation_anomalies_v1'::regclass, true), '\s+', '', 'g'),
         regexp_replace(pg_get_viewdef('authority_correction_anomaly_reference_v1'::regclass, true), '\s+', '', 'g')
    INTO v_installed, v_frozen;
  IF v_installed IS DISTINCT FROM v_frozen THEN
    RAISE EXCEPTION 'Authority correction preflight: installed anomaly view is not the frozen Build 4 definition.';
  END IF;
END
$definition_preflight$;

DROP VIEW authority_correction_anomaly_reference_v1;
DROP VIEW authority_correction_build4_reference_v1;

ALTER FUNCTION public.physical_remedy_allocation_guard_v1()
RENAME TO physical_remedy_allocation_guard_v2;

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

REVOKE ALL ON FUNCTION public.physical_remedy_allocation_guard_v1() FROM PUBLIC, anon, authenticated;

CREATE VIEW public.order_reconciliation_v2_vw AS
with authoritative_supplier_lines as (
  select si.order_id,
         sil.id as supplier_invoice_line_id,
         coalesce(sil.qty_confirmed, 0)::bigint as qty_confirmed,
         coalesce(sil.amount_confirmed, 0)::numeric as amount_confirmed
  from public.supplier_invoices si
  join public.supplier_invoice_lines sil on sil.supplier_invoice_id = si.id
  where si.is_current_for_order = true
    and si.review_status in ('approved_current','ref_corrected_approved')
    and si.blocked_from_sage_yn = false
    and si.superseded_by_supplier_invoice_id is null
    and sil.eligible_for_invoice_yn = 'Y'
),
supplier_line_totals as (
  select order_id,
         coalesce(sum(qty_confirmed), 0::numeric)::bigint as qty_progressed_invoiceable,
         coalesce(sum(amount_confirmed), 0::numeric) as amount_progressed_invoiceable_gbp
  from authoritative_supplier_lines
  group by order_id
),
dispute_line_totals as (
  select d.order_id,
         coalesce(sum(case when dl.line_status = 'resolved' and asl.supplier_invoice_line_id is null then dl.qty_impact else 0 end), 0::bigint) as qty_resolved_noninvoiceable,
         coalesce(sum(case when dl.line_status = 'resolved' and asl.supplier_invoice_line_id is null then dl.amount_impact_gbp else 0::numeric end), 0::numeric) as amount_resolved_dispute_gbp
  from public.disputes d
  join public.dispute_lines dl on dl.dispute_id = d.id
  left join authoritative_supplier_lines asl
    on asl.order_id = d.order_id
   and asl.supplier_invoice_line_id = dl.supplier_invoice_line_id
  group by d.order_id
),
resolved_nonphysical as (
  select r.order_id,
         coalesce(sum(
           case r.financial_type
             when 'delivery' then abs(coalesce(r.amount_gbp, 0::numeric))
             when 'fee' then abs(coalesce(r.amount_gbp, 0::numeric))
             when 'discount' then -abs(coalesce(r.amount_gbp, 0::numeric))
             when 'zero_value_delivery' then 0::numeric
             else 0::numeric
           end
         ), 0::numeric) as signed_nonphysical_amount_gbp
  from public.supplier_invoice_line_resolutions r
  where r.active = true and r.resolution_type = 'non_physical_financial'
  group by r.order_id
),
reconciled as (
  select o.id as order_id,
         o.total_qty_declared as qty_target,
         coalesce(slt.qty_progressed_invoiceable, 0::bigint) as qty_progressed_invoiceable,
         coalesce(dlt.qty_resolved_noninvoiceable, 0::bigint) as qty_resolved_noninvoiceable,
         o.total_qty_declared - coalesce(slt.qty_progressed_invoiceable, 0::bigint) - coalesce(dlt.qty_resolved_noninvoiceable, 0::bigint) as qty_unresolved,
         o.order_total_gbp_declared as amount_target_gbp,
         coalesce(slt.amount_progressed_invoiceable_gbp, 0::numeric) as amount_progressed_invoiceable_gbp,
         coalesce(dlt.amount_resolved_dispute_gbp, 0::numeric) + coalesce(rn.signed_nonphysical_amount_gbp, 0::numeric) as amount_resolved_noninvoiceable_gbp,
         o.order_total_gbp_declared - coalesce(slt.amount_progressed_invoiceable_gbp, 0::numeric) - coalesce(dlt.amount_resolved_dispute_gbp, 0::numeric) - coalesce(rn.signed_nonphysical_amount_gbp, 0::numeric) as amount_unresolved_gbp,
         exists (select 1 from authoritative_supplier_lines released where released.order_id = o.id) as invoiceable_subset_released_yn
  from public.orders o
  left join supplier_line_totals slt on slt.order_id = o.id
  left join dispute_line_totals dlt on dlt.order_id = o.id
  left join resolved_nonphysical rn on rn.order_id = o.id
)
select r.order_id,
       r.qty_target,
       r.qty_progressed_invoiceable,
       r.qty_resolved_noninvoiceable,
       r.qty_unresolved,
       r.amount_target_gbp,
       r.amount_progressed_invoiceable_gbp,
       r.amount_resolved_noninvoiceable_gbp,
       r.amount_unresolved_gbp,
       r.invoiceable_subset_released_yn,
       (
         r.qty_unresolved = 0
         and r.amount_unresolved_gbp = 0::numeric
         and r.qty_progressed_invoiceable + r.qty_resolved_noninvoiceable <= r.qty_target
         and r.amount_progressed_invoiceable_gbp + r.amount_resolved_noninvoiceable_gbp <= r.amount_target_gbp
       ) as whole_order_cleared_yn,
       now() as last_refreshed_at
from reconciled r;

COMMENT ON VIEW public.order_reconciliation_v2_vw IS
  'Build 4 authoritative-supplier reconciliation preserved under an additive versioned authority.';

CREATE OR REPLACE VIEW public.order_reconciliation_vw AS
WITH resolved_nonphysical AS (
  SELECT
    r.order_id,
    COALESCE(SUM(
      CASE r.financial_type
        WHEN 'delivery' THEN ABS(COALESCE(r.amount_gbp, 0))
        WHEN 'fee' THEN ABS(COALESCE(r.amount_gbp, 0))
        WHEN 'discount' THEN -ABS(COALESCE(r.amount_gbp, 0))
        WHEN 'zero_value_delivery' THEN 0::numeric
        ELSE 0::numeric
      END
    ), 0)::numeric AS signed_nonphysical_amount_gbp
  FROM public.supplier_invoice_line_resolutions r
  WHERE r.active = true
    AND r.resolution_type = 'non_physical_financial'
  GROUP BY r.order_id
)
SELECT
  o.id AS order_id,
  o.total_qty_declared AS qty_target,
  COALESCE(SUM(CASE WHEN sil.eligible_for_invoice_yn = 'Y' THEN sil.qty_confirmed ELSE 0 END), 0) AS qty_progressed_invoiceable,
  COALESCE(SUM(CASE WHEN dl.line_status = 'resolved' THEN dl.qty_impact ELSE 0 END), 0) AS qty_resolved_noninvoiceable,
  o.total_qty_declared
    - COALESCE(SUM(CASE WHEN sil.eligible_for_invoice_yn = 'Y' THEN sil.qty_confirmed ELSE 0 END), 0)
    - COALESCE(SUM(CASE WHEN dl.line_status = 'resolved' THEN dl.qty_impact ELSE 0 END), 0)
    AS qty_unresolved,
  o.order_total_gbp_declared AS amount_target_gbp,
  COALESCE(SUM(CASE WHEN sil.eligible_for_invoice_yn = 'Y' THEN sil.amount_confirmed ELSE 0 END), 0) AS amount_progressed_invoiceable_gbp,
  COALESCE(SUM(CASE WHEN dl.line_status = 'resolved' THEN dl.amount_impact_gbp ELSE 0 END), 0)
    + COALESCE(MAX(rn.signed_nonphysical_amount_gbp), 0)
    AS amount_resolved_noninvoiceable_gbp,
  o.order_total_gbp_declared
    - COALESCE(SUM(CASE WHEN sil.eligible_for_invoice_yn = 'Y' THEN sil.amount_confirmed ELSE 0 END), 0)
    - COALESCE(SUM(CASE WHEN dl.line_status = 'resolved' THEN dl.amount_impact_gbp ELSE 0 END), 0)
    - COALESCE(MAX(rn.signed_nonphysical_amount_gbp), 0)
    AS amount_unresolved_gbp,
  CASE WHEN EXISTS (
    SELECT 1
    FROM public.supplier_invoice_lines sil2
    JOIN public.supplier_invoices si2 ON si2.id = sil2.supplier_invoice_id
    WHERE si2.order_id = o.id
      AND sil2.eligible_for_invoice_yn = 'Y'
  ) THEN true ELSE false END AS invoiceable_subset_released_yn,
  CASE WHEN (
    o.total_qty_declared
      - COALESCE(SUM(CASE WHEN sil.eligible_for_invoice_yn = 'Y' THEN sil.qty_confirmed ELSE 0 END), 0)
      - COALESCE(SUM(CASE WHEN dl.line_status = 'resolved' THEN dl.qty_impact ELSE 0 END), 0) = 0
    AND o.order_total_gbp_declared
      - COALESCE(SUM(CASE WHEN sil.eligible_for_invoice_yn = 'Y' THEN sil.amount_confirmed ELSE 0 END), 0)
      - COALESCE(SUM(CASE WHEN dl.line_status = 'resolved' THEN dl.amount_impact_gbp ELSE 0 END), 0)
      - COALESCE(MAX(rn.signed_nonphysical_amount_gbp), 0) = 0
  ) THEN true ELSE false END AS whole_order_cleared_yn,
  now() AS last_refreshed_at
FROM public.orders o
LEFT JOIN public.supplier_invoices si ON si.order_id = o.id
LEFT JOIN public.supplier_invoice_lines sil ON sil.supplier_invoice_id = si.id
LEFT JOIN public.disputes d ON d.order_id = o.id
LEFT JOIN public.dispute_lines dl ON dl.dispute_id = d.id
LEFT JOIN resolved_nonphysical rn ON rn.order_id = o.id
GROUP BY o.id, o.total_qty_declared, o.order_total_gbp_declared;

COMMENT ON VIEW public.order_reconciliation_vw IS
'Baseline order reconciliation preserved, with active non-physical financial resolutions added once per order using explicit commercial sign: delivery/fee positive, discount negative and zero-value delivery zero. Ambiguous types remain unresolved.';

CREATE OR REPLACE VIEW public.order_reconciliation_anomalies_v1 as
with raw_eligible as (
  select si.order_id,
         coalesce(sum(coalesce(sil.qty_confirmed, 0)), 0)::numeric as raw_qty,
         coalesce(sum(coalesce(sil.amount_confirmed, 0)), 0)::numeric as raw_amount_gbp
  from public.supplier_invoices si
  join public.supplier_invoice_lines sil on sil.supplier_invoice_id = si.id
  where sil.eligible_for_invoice_yn = 'Y'
  group by si.order_id
),
non_authoritative as (
  select si.order_id,
         coalesce(sum(coalesce(sil.qty_confirmed, 0)), 0)::numeric as non_authoritative_qty,
         coalesce(sum(coalesce(sil.amount_confirmed, 0)), 0)::numeric as non_authoritative_amount_gbp,
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
           ) order by si.uploaded_at, si.id, sil.line_order, sil.id
         ) as evidence_json
  from public.supplier_invoices si
  join public.supplier_invoice_lines sil on sil.supplier_invoice_id = si.id
  where sil.eligible_for_invoice_yn = 'Y'
    and (
      si.is_current_for_order is distinct from true
      or si.review_status is null
      or si.review_status not in ('approved_current','ref_corrected_approved')
      or si.blocked_from_sage_yn is distinct from false
      or si.superseded_by_supplier_invoice_id is not null
    )
  group by si.order_id
),
canonical as (select * from public.order_reconciliation_v2_vw)
select c.order_id,
       'AUTHORITATIVE_QTY_OVER_PROGRESS'::text as anomaly_code,
       c.qty_target::numeric as qty_target,
       c.qty_progressed_invoiceable::numeric as qty_observed,
       greatest(c.qty_progressed_invoiceable::numeric - c.qty_target::numeric, 0::numeric) as qty_over,
       c.amount_target_gbp,
       c.amount_progressed_invoiceable_gbp as amount_observed_gbp,
       greatest(c.amount_progressed_invoiceable_gbp - c.amount_target_gbp, 0::numeric) as amount_over_gbp,
       jsonb_build_object('source','canonical_authoritative_supplier_lines') as detail_json,
       now() as last_refreshed_at
from canonical c
where c.qty_progressed_invoiceable > c.qty_target
union all
select c.order_id,
       'AUTHORITATIVE_AMOUNT_OVER_PROGRESS',
       c.qty_target::numeric,
       c.qty_progressed_invoiceable::numeric,
       greatest(c.qty_progressed_invoiceable::numeric - c.qty_target::numeric, 0::numeric),
       c.amount_target_gbp,
       c.amount_progressed_invoiceable_gbp,
       greatest(c.amount_progressed_invoiceable_gbp - c.amount_target_gbp, 0::numeric),
       jsonb_build_object('source','canonical_authoritative_supplier_lines'),
       now()
from canonical c
where c.amount_progressed_invoiceable_gbp > c.amount_target_gbp
union all
select o.id,
       'NON_AUTHORITATIVE_INVOICEABLE_EVIDENCE',
       o.total_qty_declared::numeric,
       na.non_authoritative_qty,
       greatest(na.non_authoritative_qty - o.total_qty_declared::numeric, 0::numeric),
       o.order_total_gbp_declared,
       na.non_authoritative_amount_gbp,
       greatest(na.non_authoritative_amount_gbp - o.order_total_gbp_declared, 0::numeric),
       jsonb_build_object('evidence', na.evidence_json),
       now()
from public.orders o
join non_authoritative na on na.order_id = o.id
where na.non_authoritative_qty <> 0 or na.non_authoritative_amount_gbp <> 0
union all
select o.id,
       'RAW_QTY_OVER_PROGRESS',
       o.total_qty_declared::numeric,
       raw.raw_qty,
       greatest(raw.raw_qty - o.total_qty_declared::numeric, 0::numeric),
       o.order_total_gbp_declared,
       raw.raw_amount_gbp,
       greatest(raw.raw_amount_gbp - o.order_total_gbp_declared, 0::numeric),
       jsonb_build_object('source','all_eligible_lines_regardless_of_invoice_authority'),
       now()
from public.orders o
join raw_eligible raw on raw.order_id = o.id
where raw.raw_qty > o.total_qty_declared::numeric
union all
select o.id,
       'RAW_AMOUNT_OVER_PROGRESS',
       o.total_qty_declared::numeric,
       raw.raw_qty,
       greatest(raw.raw_qty - o.total_qty_declared::numeric, 0::numeric),
       o.order_total_gbp_declared,
       raw.raw_amount_gbp,
       greatest(raw.raw_amount_gbp - o.order_total_gbp_declared, 0::numeric),
       jsonb_build_object('source','all_eligible_lines_regardless_of_invoice_authority'),
       now()
from public.orders o
join raw_eligible raw on raw.order_id = o.id
where raw.raw_amount_gbp > o.order_total_gbp_declared;

COMMENT ON VIEW public.order_reconciliation_anomalies_v1 IS
  'Read-only Build 4 anomaly model using order_reconciliation_v2_vw as its canonical authority.';


DO $postflight$
DECLARE
  s authority_correction_state_v1%ROWTYPE;
  v_v1_hash text;
  v_v2_hash text;
  v_public oid := 0;
  v_anon oid;
  v_authenticated oid;
  v_legacy_md5 text;
  v_mismatch integer;
BEGIN
  SELECT * INTO STRICT s FROM authority_correction_state_v1;
  SELECT oid INTO v_anon FROM pg_roles WHERE rolname = 'anon';
  SELECT oid INTO v_authenticated FROM pg_roles WHERE rolname = 'authenticated';
  IF v_anon IS NULL OR v_authenticated IS NULL THEN
    RAISE EXCEPTION 'Authority correction postflight: expected API roles are missing.';
  END IF;

  SELECT md5(concat_ws('|', p.prosrc, l.lanname, p.provolatile, p.prosecdef::text,
           p.proisstrict::text, p.proparallel, p.proleakproof::text,
           p.prorettype::regtype::text, p.proargtypes::text,
           COALESCE(array_to_string(p.proconfig, ','), '')))
    INTO v_v1_hash
  FROM pg_proc p JOIN pg_language l ON l.oid = p.prolang
  WHERE p.oid = 'public.physical_remedy_allocation_guard_v1()'::regprocedure;
  IF v_v1_hash IS DISTINCT FROM '524d594dd765b73cc52c5713207dcd43' THEN
    RAISE EXCEPTION 'Authority correction postflight: restored foundation v1 body/metadata hash is %.', v_v1_hash;
  END IF;

  SELECT md5(concat_ws('|', p.prosrc, l.lanname, p.provolatile, p.prosecdef::text,
           p.proisstrict::text, p.proparallel, p.proleakproof::text,
           p.prorettype::regtype::text, p.proargtypes::text,
           COALESCE(array_to_string(p.proconfig, ','), '')))
    INTO v_v2_hash
  FROM pg_proc p JOIN pg_language l ON l.oid = p.prolang
  WHERE p.oid = 'public.physical_remedy_allocation_guard_v2()'::regprocedure;
  IF 'public.physical_remedy_allocation_guard_v2()'::regprocedure::oid IS DISTINCT FROM s.guard_oid
     OR (SELECT proowner FROM pg_proc WHERE oid = s.guard_oid) IS DISTINCT FROM s.guard_owner
     OR (SELECT proacl FROM pg_proc WHERE oid = s.guard_oid) IS DISTINCT FROM s.guard_acl
     OR v_v2_hash IS DISTINCT FROM s.guard_canonical_md5 THEN
    RAISE EXCEPTION 'Authority correction postflight: v2 OID, owner, ACL or canonical hash changed.';
  END IF;
  IF (SELECT proowner FROM pg_proc WHERE oid = 'public.physical_remedy_allocation_guard_v1()'::regprocedure) IS DISTINCT FROM s.guard_owner THEN
    RAISE EXCEPTION 'Authority correction postflight: restored v1 owner differs from the privileged owner.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger t WHERE t.oid = s.trigger_oid AND t.tgfoid = s.guard_oid)
     OR EXISTS (SELECT 1 FROM pg_trigger t WHERE NOT t.tgisinternal AND t.tgfoid = 'public.physical_remedy_allocation_guard_v1()'::regprocedure) THEN
    RAISE EXCEPTION 'Authority correction postflight: trigger OID binding was not retained exclusively by v2.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_proc p
    CROSS JOIN LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
    WHERE p.oid IN ('public.physical_remedy_allocation_guard_v1()'::regprocedure,
                    'public.physical_remedy_allocation_guard_v2()'::regprocedure)
      AND a.grantee IN (v_public, v_anon, v_authenticated) AND a.privilege_type = 'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'Authority correction postflight: a guard is executable by PUBLIC, anon or authenticated.';
  END IF;

  IF 'public.order_reconciliation_vw'::regclass::oid IS DISTINCT FROM s.legacy_view_oid
     OR (SELECT relowner FROM pg_class WHERE oid = s.legacy_view_oid) IS DISTINCT FROM s.legacy_view_owner
     OR (SELECT relacl FROM pg_class WHERE oid = s.legacy_view_oid) IS DISTINCT FROM s.legacy_view_acl THEN
    RAISE EXCEPTION 'Authority correction postflight: legacy view OID, owner or ACL changed.';
  END IF;
  SELECT md5(definition) INTO v_legacy_md5 FROM pg_views
  WHERE schemaname = 'public' AND viewname = 'order_reconciliation_vw';
  IF v_legacy_md5 IS DISTINCT FROM '89cc95922a2b8ec1fa040ba79f12907a' THEN
    RAISE EXCEPTION 'Authority correction postflight: legacy reconciliation fingerprint is %.', v_legacy_md5;
  END IF;

  SELECT count(*) INTO v_mismatch FROM (
    (SELECT ordinal_position, column_name, data_type FROM authority_correction_columns_before_v1
     EXCEPT
     SELECT a.attnum, a.attname, format_type(a.atttypid, a.atttypmod)
     FROM pg_attribute a WHERE a.attrelid = s.legacy_view_oid AND a.attnum > 0 AND NOT a.attisdropped)
    UNION ALL
    (SELECT a.attnum, a.attname, format_type(a.atttypid, a.atttypmod)
     FROM pg_attribute a WHERE a.attrelid = s.legacy_view_oid AND a.attnum > 0 AND NOT a.attisdropped
     EXCEPT
     SELECT ordinal_position, column_name, data_type FROM authority_correction_columns_before_v1)
  ) differences;
  IF v_mismatch <> 0 THEN
    RAISE EXCEPTION 'Authority correction postflight: legacy view columns or data types changed.';
  END IF;

  WITH dependencies_after AS (
    SELECT d.classid AS dependent_classid, d.objid AS dependent_objid,
           d.objsubid AS dependent_objsubid, d.refobjsubid AS referenced_objsubid,
           i.type AS dependent_class, i.schema AS dependent_schema,
           i.name AS dependent_name, i.identity AS dependent_identity,
           d.deptype AS dependency_type
    FROM pg_depend d
    CROSS JOIN LATERAL pg_identify_object(d.classid, d.objid, d.objsubid) i
    WHERE d.refobjid = s.legacy_view_oid
      AND NOT EXISTS (
        SELECT 1 FROM pg_rewrite rw
        WHERE d.classid = 'pg_rewrite'::regclass AND rw.oid = d.objid
          AND rw.ev_class = 'public.order_reconciliation_anomalies_v1'::regclass)
  ), differences AS (
    (SELECT * FROM b4_legacy_dependents_before EXCEPT SELECT * FROM dependencies_after)
    UNION ALL
    (SELECT * FROM dependencies_after EXCEPT SELECT * FROM b4_legacy_dependents_before)
  )
  SELECT count(*) INTO v_mismatch FROM differences;
  IF v_mismatch <> 0 THEN
    RAISE EXCEPTION 'Unexpected legacy reconciliation dependency identity changed (% differences).', v_mismatch;
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_depend d JOIN pg_rewrite rw ON d.classid = 'pg_rewrite'::regclass AND rw.oid = d.objid
    WHERE d.refobjid = s.legacy_view_oid AND rw.ev_class = 'public.order_reconciliation_anomalies_v1'::regclass
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_depend d JOIN pg_rewrite rw ON d.classid = 'pg_rewrite'::regclass AND rw.oid = d.objid
    WHERE d.refobjid = 'public.order_reconciliation_v2_vw'::regclass
      AND rw.ev_class = 'public.order_reconciliation_anomalies_v1'::regclass
  ) THEN
    RAISE EXCEPTION 'Authority correction postflight: anomaly dependency was not redirected exclusively to v2.';
  END IF;
END
$postflight$;

NOTIFY pgrst, 'reload schema';

COMMIT;
