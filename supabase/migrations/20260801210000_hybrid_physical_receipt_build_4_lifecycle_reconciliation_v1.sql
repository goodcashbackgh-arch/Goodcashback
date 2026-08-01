-- Hybrid Physical Receipt Build 4: lifecycle and reconciliation
-- Governing authority:
-- docs/governing-pack/architecture/HYBRID_PHYSICAL_RECEIPT_BUILD_4_LIFECYCLE_AND_RECONCILIATION_ALIGNMENT_ADDENDUM_v1.md

begin;

do $drift$
declare
  v_md5 text;
begin
  select md5(pg_get_functiondef('public.create_replacement_child_order(uuid,uuid,uuid,text)'::regprocedure)) into v_md5;
  if v_md5 is distinct from 'fdf1c2e955a34b81fbfc75c6a34a21b4' then
    raise exception 'Build 4 drift stop: create_replacement_child_order changed (%).', v_md5;
  end if;

  select md5(pg_get_functiondef('public.order_has_open_child_exceptions(uuid)'::regprocedure)) into v_md5;
  if v_md5 is distinct from '8dbf93826e18a04b61d8fbc1d5b1922c' then
    raise exception 'Build 4 drift stop: order_has_open_child_exceptions changed (%).', v_md5;
  end if;

  select md5(definition) into v_md5
  from pg_views
  where schemaname = 'public' and viewname = 'order_reconciliation_vw';
  if v_md5 is distinct from '89cc95922a2b8ec1fa040ba79f12907a' then
    raise exception 'Build 4 drift stop: order_reconciliation_vw changed (%).', v_md5;
  end if;

  select md5(pg_get_functiondef('public.approve_vat_release(uuid,uuid,jsonb)'::regprocedure)) into v_md5;
  if v_md5 is distinct from '13491a2d250a480ebb1ac607ce7acce5' then raise exception 'Build 4 drift stop: approve_vat_release changed (%).', v_md5; end if;
  select md5(pg_get_functiondef('public.mark_order_accounting_release_ready(uuid,uuid)'::regprocedure)) into v_md5;
  if v_md5 is distinct from 'dacaf00c6470a626cfc2d7e7aac2ccb8' then raise exception 'Build 4 drift stop: mark_order_accounting_release_ready changed (%).', v_md5; end if;
  select md5(pg_get_functiondef('public.recompute_order_status(uuid)'::regprocedure)) into v_md5;
  if v_md5 is distinct from '110d55541d4f729ff9331e23515fb563' then raise exception 'Build 4 drift stop: recompute_order_status changed (%).', v_md5; end if;
  select md5(pg_get_functiondef('public.physical_remedy_allocation_guard_v1()'::regprocedure)) into v_md5;
  if v_md5 is distinct from '32e1d3eb9161cdc3e09114edb8c0d3c0' then raise exception 'Build 4 drift stop: physical_remedy_allocation_guard_v1 changed (%).', v_md5; end if;
  select md5(pg_get_functiondef('public.physical_remedy_sequence_guard_v1()'::regprocedure)) into v_md5;
  if v_md5 is distinct from '3c5067f31d4f2112207e02d1f307e233' then raise exception 'Build 4 drift stop: physical_remedy_sequence_guard_v1 changed (%).', v_md5; end if;
  select md5(pg_get_functiondef('public.physical_remedy_terminal_immutability_guard_v1()'::regprocedure)) into v_md5;
  if v_md5 is distinct from 'a7aa361f066b454a6f9c4f9b81734834' then raise exception 'Build 4 drift stop: physical_remedy_terminal_immutability_guard_v1 changed (%).', v_md5; end if;
  select md5(pg_get_functiondef('public.enforce_status_transition()'::regprocedure)) into v_md5;
  if v_md5 is distinct from '5fc40897ac22a4adae838ecc6a3e1cb9' then raise exception 'Build 4 drift stop: enforce_status_transition changed (%).', v_md5; end if;
  select md5(pg_get_functiondef('public.enforce_order_locks()'::regprocedure)) into v_md5;
  if v_md5 is distinct from '497230d0cf04001f37c5e805cdd8da25' then raise exception 'Build 4 drift stop: enforce_order_locks changed (%).', v_md5; end if;
end
$drift$;

create or replace function public.create_replacement_child_order(
  p_parent_order_id uuid,
  p_dispute_line_id uuid,
  p_staff_id uuid,
  p_notes text default null::text
)
returns uuid
language plpgsql
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_parent public.orders%rowtype;
  v_dispute_id uuid;
  v_child_id uuid;
  v_sequence integer;
  v_qty integer;
  v_amount numeric;
  v_parent_has_funding_anomaly boolean := false;
  v_physical_remedy_id uuid;
  v_physical_remedy public.physical_exception_remedy_allocations%rowtype;
  v_review_order_id uuid;
begin
  select * into v_parent from public.orders where id = p_parent_order_id for update;
  if not found then raise exception 'Parent order % not found', p_parent_order_id; end if;
  if v_parent.order_type = 'replacement_child' then raise exception 'Cannot create replacement of a replacement in Phase 1'; end if;

  select exists (
    select 1 from public.escalation_events ee
    join public.escalation_rules er on er.id = ee.rule_id
    where ee.entity_type = 'order' and ee.entity_id = p_parent_order_id
      and ee.resolved_at is null and er.rule_code = 'FUND_LATE_MATCH'
  ) into v_parent_has_funding_anomaly;

  if v_parent.funded_at is null and not v_parent_has_funding_anomaly then
    raise exception 'Parent order % must be platform-funded or explicitly in the funding anomaly queue before replacement can be created', p_parent_order_id;
  end if;

  select dl.dispute_id,
         greatest(coalesce(dl.qty_impact, 1), 1),
         coalesce(dl.amount_impact_gbp, 0),
         dl.physical_remedy_allocation_id
  into v_dispute_id, v_qty, v_amount, v_physical_remedy_id
  from public.dispute_lines dl
  join public.disputes d on d.id = dl.dispute_id and d.order_id = p_parent_order_id
  where dl.id = p_dispute_line_id
  for update of dl;

  if v_dispute_id is null then
    raise exception 'Dispute line % not found or not linked to parent order %', p_dispute_line_id, p_parent_order_id;
  end if;
  if exists (select 1 from public.orders o where o.replacement_source_dispute_line_id = p_dispute_line_id) then
    raise exception 'Replacement child order already exists for dispute line %', p_dispute_line_id;
  end if;

  if v_physical_remedy_id is not null then
    select remedy.* into v_physical_remedy
    from public.physical_exception_remedy_allocations remedy
    where remedy.id = v_physical_remedy_id
    for update;

    select review_row.order_id into v_review_order_id
    from public.physical_receipt_reviews review_row
    where review_row.id = v_physical_remedy.physical_receipt_review_id;

    if v_physical_remedy.id is null
       or v_physical_remedy.dispute_line_id is distinct from p_dispute_line_id
       or v_physical_remedy.approved_remedy_type is distinct from 'replacement'
       or v_physical_remedy.approved_remedy_qty is null
       or v_physical_remedy.approved_remedy_qty <= 0
       or trunc(v_physical_remedy.approved_remedy_qty) <> v_physical_remedy.approved_remedy_qty
       or v_physical_remedy.supplier_cost_mode not in ('free_replacement','charged_repurchase','pending_supplier_evidence')
       or v_physical_remedy.status not in ('approved','linked_to_exception')
       or v_physical_remedy.replacement_child_order_id is not null
       or v_review_order_id is distinct from p_parent_order_id
    then
      raise exception 'Physical replacement remedy % is not an approved, exact and unconsumed replacement authority for dispute line %', v_physical_remedy_id, p_dispute_line_id;
    end if;

    v_qty := v_physical_remedy.approved_remedy_qty::integer;
    v_amount := coalesce(v_physical_remedy.customer_commercial_value_gbp, v_amount, 0);
  end if;

  select count(*) + 1 into v_sequence from public.orders o where o.parent_order_id = p_parent_order_id;

  insert into public.orders (
    order_ref, payment_auth_id, importer_id, operator_id, shipper_id, retailer_id,
    destination_hub_id, parent_order_id, order_type, order_total_gbp_declared,
    total_qty_declared, quote_fx_rate, quote_card_markup_pct, quote_fx_rate_locked,
    quote_card_markup_pct_locked, quote_rate_date_locked, quote_rate_locked_at,
    status, sop_version, replacement_source_dispute_line_id, funded_at, created_at, updated_at
  ) values (
    v_parent.order_ref || '-R' || v_sequence, null, v_parent.importer_id,
    v_parent.operator_id, v_parent.shipper_id, v_parent.retailer_id,
    v_parent.destination_hub_id, p_parent_order_id, 'replacement_child',
    v_amount, v_qty, v_parent.quote_fx_rate, v_parent.quote_card_markup_pct,
    v_parent.quote_fx_rate_locked, v_parent.quote_card_markup_pct_locked,
    v_parent.quote_rate_date_locked, v_parent.quote_rate_locked_at,
    'evidence_collecting', v_parent.sop_version, p_dispute_line_id,
    null, now(), now()
  ) returning id into v_child_id;

  insert into public.order_category_lines (
    order_id, markup_category_id, qty, amount_inc_vat_gbp,
    markup_pct_applied, markup_gbp_calculated, created_at
  )
  select v_child_id, ocl.markup_category_id, v_qty, v_amount,
         ocl.markup_pct_applied, coalesce(ocl.markup_gbp_calculated, 0), now()
  from public.order_category_lines ocl
  where ocl.order_id = p_parent_order_id
  order by ocl.id
  limit 1;

  if v_physical_remedy_id is not null then
    update public.physical_exception_remedy_allocations
    set replacement_child_order_id = v_child_id, status = 'in_progress', updated_at = now()
    where id = v_physical_remedy_id;
  end if;

  update public.disputes
  set replacement_child_order_id = v_child_id, resolved_at = coalesce(resolved_at, now())
  where id = v_dispute_id;

  update public.dispute_lines
  set resolved_via_child_order_id = v_child_id,
      conversation_status = 'resolved_replacement',
      resolution_method = 'replacement',
      resolved_at = coalesce(resolved_at, now())
  where id = p_dispute_line_id;

  perform public.raise_escalation(
    'REPLACEMENT_CHILD', 'order', v_child_id,
    jsonb_build_object(
      'parent_order_id', p_parent_order_id,
      'dispute_line_id', p_dispute_line_id,
      'physical_remedy_allocation_id', v_physical_remedy_id,
      'approved_replacement_qty', v_qty,
      'notes', p_notes,
      'staff_id', p_staff_id
    )
  );

  return v_child_id;
end;
$function$;

comment on function public.create_replacement_child_order(uuid,uuid,uuid,text) is
  'Hardened physical replacement-child authority preserving exact approved physical-remedy provenance.';

create or replace function public.order_has_open_child_exceptions(p_order_id uuid)
returns boolean
language sql
stable
set search_path to 'public', 'pg_temp'
as $function$
  select exists (
    select 1
    from public.disputes d
    join public.dispute_lines dl on dl.dispute_id = d.id
    where d.order_id = p_order_id
      and dl.conversation_status in (
        'child_exception_created','remedy_selected','refund_pending_approval',
        'retailer_draft_ready','retailer_contacted','retailer_response_received',
        'ai_next_draft_ready','awaiting_retailer_resolution'
      )
    union all
    select 1
    from public.physical_exception_remedy_allocations remedy
    join public.physical_receipt_reviews review_row on review_row.id = remedy.physical_receipt_review_id
    where review_row.order_id = p_order_id
      and remedy.status not in ('completed','rerouted','closed_no_action')
    union all
    select 1
    from public.orders child
    where child.parent_order_id = p_order_id
      and child.order_type = 'replacement_child'
      and (
        child.status not in ('completed','archived','cancelled')
        or (
          child.status = 'cancelled'
          and not exists (
            select 1
            from public.physical_exception_remedy_allocations remedy
            where remedy.replacement_child_order_id = child.id
              and remedy.status in ('rerouted','closed_no_action')
          )
        )
      )
  )
$function$;

comment on function public.order_has_open_child_exceptions(uuid) is
  'Returns true for open legacy exception states, unresolved physical remedies, unfinished replacement children, and cancelled children not rerouted or explicitly closed.';

create or replace view public.order_reconciliation_vw as
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

comment on view public.order_reconciliation_vw is
  'Canonical order reconciliation using current, approved, unblocked and non-superseded supplier invoice identity. Public column contract preserved.';

create or replace view public.order_reconciliation_anomalies_v1 as
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

comment on view public.order_reconciliation_anomalies_v1 is
  'Read-only Build 4 anomaly model using a null-safe inverse of the exact current/approved/unblocked/non-superseded canonical authority predicate.';

revoke all on public.order_reconciliation_anomalies_v1 from public;
revoke all on public.order_reconciliation_anomalies_v1 from anon;
grant select on public.order_reconciliation_anomalies_v1 to authenticated;
grant select on public.order_reconciliation_anomalies_v1 to service_role;

do $contract$
declare
  v_columns text[];
begin
  select array_agg(column_name order by ordinal_position) into v_columns
  from information_schema.columns
  where table_schema = 'public' and table_name = 'order_reconciliation_vw';

  if v_columns is distinct from array[
    'order_id','qty_target','qty_progressed_invoiceable','qty_resolved_noninvoiceable',
    'qty_unresolved','amount_target_gbp','amount_progressed_invoiceable_gbp',
    'amount_resolved_noninvoiceable_gbp','amount_unresolved_gbp',
    'invoiceable_subset_released_yn','whole_order_cleared_yn','last_refreshed_at'
  ]::text[] then
    raise exception 'Build 4 contract failure: order_reconciliation_vw public columns changed: %', v_columns;
  end if;
end
$contract$;

commit;