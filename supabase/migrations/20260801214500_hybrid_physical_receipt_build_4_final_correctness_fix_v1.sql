-- Hybrid Physical Receipt Build 4 final correctness fix.
-- 1. Canonical reconciliation requires the explicit current invoice identity.
-- 2. Atomic replacement acceptance keeps exact physical provenance and does not
--    falsely attribute a legacy multi-line child to one arbitrary source line.

begin;

create or replace view public.order_reconciliation_vw as
with authoritative_supplier_lines as (
  select
    si.order_id,
    sil.id as supplier_invoice_line_id,
    coalesce(sil.qty_confirmed, 0)::bigint as qty_confirmed,
    coalesce(sil.amount_confirmed, 0)::numeric as amount_confirmed
  from public.supplier_invoices si
  join public.supplier_invoice_lines sil
    on sil.supplier_invoice_id = si.id
  where si.is_current_for_order = true
    and si.review_status in ('approved_current','ref_corrected_approved')
    and si.blocked_from_sage_yn = false
    and si.superseded_by_supplier_invoice_id is null
    and sil.eligible_for_invoice_yn = 'Y'
),
supplier_line_totals as (
  select
    asl.order_id,
    coalesce(sum(asl.qty_confirmed), 0::numeric)::bigint as qty_progressed_invoiceable,
    coalesce(sum(asl.amount_confirmed), 0::numeric) as amount_progressed_invoiceable_gbp
  from authoritative_supplier_lines asl
  group by asl.order_id
),
dispute_line_totals as (
  select
    d.order_id,
    coalesce(sum(
      case
        when dl.line_status = 'resolved'
         and asl.supplier_invoice_line_id is null
          then dl.qty_impact
        else 0
      end
    ), 0::bigint) as qty_resolved_noninvoiceable,
    coalesce(sum(
      case
        when dl.line_status = 'resolved'
         and asl.supplier_invoice_line_id is null
          then dl.amount_impact_gbp
        else 0::numeric
      end
    ), 0::numeric) as amount_resolved_dispute_gbp
  from public.disputes d
  join public.dispute_lines dl
    on dl.dispute_id = d.id
  left join authoritative_supplier_lines asl
    on asl.order_id = d.order_id
   and asl.supplier_invoice_line_id = dl.supplier_invoice_line_id
  group by d.order_id
),
resolved_nonphysical as (
  select
    r.order_id,
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
  where r.active = true
    and r.resolution_type = 'non_physical_financial'
  group by r.order_id
),
reconciled as (
  select
    o.id as order_id,
    o.total_qty_declared as qty_target,
    coalesce(slt.qty_progressed_invoiceable, 0::bigint) as qty_progressed_invoiceable,
    coalesce(dlt.qty_resolved_noninvoiceable, 0::bigint) as qty_resolved_noninvoiceable,
    o.total_qty_declared
      - coalesce(slt.qty_progressed_invoiceable, 0::bigint)
      - coalesce(dlt.qty_resolved_noninvoiceable, 0::bigint) as qty_unresolved,
    o.order_total_gbp_declared as amount_target_gbp,
    coalesce(slt.amount_progressed_invoiceable_gbp, 0::numeric) as amount_progressed_invoiceable_gbp,
    coalesce(dlt.amount_resolved_dispute_gbp, 0::numeric)
      + coalesce(rn.signed_nonphysical_amount_gbp, 0::numeric) as amount_resolved_noninvoiceable_gbp,
    o.order_total_gbp_declared
      - coalesce(slt.amount_progressed_invoiceable_gbp, 0::numeric)
      - coalesce(dlt.amount_resolved_dispute_gbp, 0::numeric)
      - coalesce(rn.signed_nonphysical_amount_gbp, 0::numeric) as amount_unresolved_gbp,
    exists (
      select 1
      from authoritative_supplier_lines released
      where released.order_id = o.id
    ) as invoiceable_subset_released_yn
  from public.orders o
  left join supplier_line_totals slt on slt.order_id = o.id
  left join dispute_line_totals dlt on dlt.order_id = o.id
  left join resolved_nonphysical rn on rn.order_id = o.id
)
select
  r.order_id,
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

create or replace function public.staff_accept_replacement_outcome_v1(
  p_dispute_id uuid,
  p_staff_id uuid,
  p_notes text default null::text
)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_dispute public.disputes%rowtype;
  v_parent public.orders%rowtype;
  v_active_line_count integer;
  v_physical_line_count integer;
  v_non_manual_line_count integer;
  v_first_line_id uuid;
  v_child_id uuid;
  v_sequence integer;
  v_legacy_qty integer;
  v_legacy_amount numeric;
  v_parent_has_funding_anomaly boolean := false;
begin
  if auth.uid() is null then
    raise exception 'Unauthenticated user';
  end if;

  if not exists (
    select 1 from public.staff s
    where s.id = p_staff_id
      and s.auth_user_id = auth.uid()
      and coalesce(s.active, true) = true
  ) then
    raise exception 'Active staff authority not found';
  end if;

  select * into v_dispute
  from public.disputes
  where id = p_dispute_id
  for update;

  if not found then raise exception 'Dispute % not found', p_dispute_id; end if;
  if v_dispute.desired_outcome is distinct from 'replacement' then
    raise exception 'Dispute % is not a replacement dispute', p_dispute_id;
  end if;
  if v_dispute.replacement_child_order_id is not null then
    raise exception 'Replacement child order already exists for dispute %', p_dispute_id;
  end if;
  if v_dispute.status not in ('raised','under_review') then
    raise exception 'Replacement final acceptance requires dispute status raised or under_review. Current status: %', v_dispute.status;
  end if;

  select * into v_parent
  from public.orders
  where id = v_dispute.order_id
  for update;

  if v_parent.order_type = 'replacement_child' then
    raise exception 'Cannot create replacement of a replacement in Phase 1';
  end if;

  select exists (
    select 1
    from public.escalation_events ee
    join public.escalation_rules er on er.id = ee.rule_id
    where ee.entity_type = 'order'
      and ee.entity_id = v_parent.id
      and ee.resolved_at is null
      and er.rule_code = 'FUND_LATE_MATCH'
  ) into v_parent_has_funding_anomaly;

  if v_parent.funded_at is null and not v_parent_has_funding_anomaly then
    raise exception 'Parent order % must be platform-funded or explicitly in the funding anomaly queue before replacement can be created', v_parent.id;
  end if;

  if not exists (
    select 1 from public.dispute_messages dm
    where dm.dispute_id = p_dispute_id
      and dm.message_type = 'retailer_reply'
      and dm.counterparty = 'retailer'
  ) then
    raise exception 'At least one retailer reply is required before accepting final outcome';
  end if;

  select
    count(*),
    count(*) filter (where dl.physical_remedy_allocation_id is not null),
    count(*) filter (where sil.line_source is distinct from 'manually_added'),
    min(dl.id),
    coalesce(sum(abs(dl.qty_impact)), 0)::integer,
    coalesce(sum(abs(dl.amount_impact_gbp)), 0)::numeric
  into v_active_line_count, v_physical_line_count, v_non_manual_line_count,
       v_first_line_id, v_legacy_qty, v_legacy_amount
  from public.dispute_lines dl
  join public.supplier_invoice_lines sil on sil.id = dl.supplier_invoice_line_id
  where dl.dispute_id = p_dispute_id
    and dl.resolved_at is null
    and dl.conversation_status = 'retailer_response_received';

  if v_active_line_count = 0 then
    raise exception 'No active retailer-accepted replacement dispute lines found';
  end if;
  if exists (
    select 1 from public.dispute_lines dl
    where dl.dispute_id = p_dispute_id
      and dl.resolved_at is null
      and dl.conversation_status is distinct from 'retailer_response_received'
  ) then
    raise exception 'Every active dispute line must have an accepted retailer outcome before final replacement acceptance';
  end if;
  if v_physical_line_count > 0 and v_physical_line_count <> v_active_line_count then
    raise exception 'Physical and legacy replacement lines cannot be mixed in one final acceptance';
  end if;
  if v_physical_line_count > 0 and v_active_line_count <> 1 then
    raise exception 'A physical replacement requires exactly one approved remedy-linked dispute line';
  end if;

  if v_dispute.status = 'raised' then
    update public.disputes set status = 'under_review' where id = p_dispute_id;
  end if;
  update public.disputes set status = 'approved_replacement' where id = p_dispute_id;

  if v_physical_line_count = 1 then
    v_child_id := public.create_replacement_child_order(
      v_parent.id, v_first_line_id, p_staff_id, p_notes
    );
  else
    if v_non_manual_line_count > 0 then
      raise exception 'Legacy replacement child creation requires manual missing-item lines';
    end if;
    if v_legacy_qty <= 0 then raise exception 'Legacy replacement child creation requires a positive quantity'; end if;
    if v_legacy_amount <= 0 then raise exception 'Legacy replacement child creation requires a positive value'; end if;

    select count(*) + 1 into v_sequence
    from public.orders o where o.parent_order_id = v_parent.id;

    insert into public.orders (
      order_ref, payment_auth_id, importer_id, operator_id, shipper_id,
      retailer_id, destination_hub_id, parent_order_id, order_type,
      order_total_gbp_declared, total_qty_declared, quote_fx_rate,
      quote_card_markup_pct, quote_fx_rate_locked, quote_card_markup_pct_locked,
      quote_rate_date_locked, quote_rate_locked_at, status, sop_version,
      replacement_source_dispute_line_id, funded_at, created_at, updated_at
    ) values (
      v_parent.order_ref || '-R' || v_sequence, null, v_parent.importer_id,
      v_parent.operator_id, v_parent.shipper_id, v_parent.retailer_id,
      v_parent.destination_hub_id, v_parent.id, 'replacement_child',
      v_legacy_amount, v_legacy_qty, v_parent.quote_fx_rate,
      v_parent.quote_card_markup_pct, v_parent.quote_fx_rate_locked,
      v_parent.quote_card_markup_pct_locked, v_parent.quote_rate_date_locked,
      v_parent.quote_rate_locked_at, 'evidence_collecting', v_parent.sop_version,
      null, null, now(), now()
    ) returning id into v_child_id;

    insert into public.order_category_lines (
      order_id, markup_category_id, qty, amount_inc_vat_gbp,
      markup_pct_applied, markup_gbp_calculated, created_at
    )
    select v_child_id, ocl.markup_category_id, v_legacy_qty, v_legacy_amount,
           ocl.markup_pct_applied, coalesce(ocl.markup_gbp_calculated, 0), now()
    from public.order_category_lines ocl
    where ocl.order_id = v_parent.id
    order by ocl.id
    limit 1;

    update public.dispute_lines
    set resolved_via_child_order_id = v_child_id,
        conversation_status = 'resolved_replacement',
        resolution_method = 'replacement',
        resolved_at = coalesce(resolved_at, now())
    where dispute_id = p_dispute_id
      and resolved_at is null;

    perform public.raise_escalation(
      'REPLACEMENT_CHILD', 'order', v_child_id,
      jsonb_build_object(
        'parent_order_id', v_parent.id,
        'dispute_id', p_dispute_id,
        'legacy_source_dispute_line_ids', (
          select jsonb_agg(dl.id order by dl.id)
          from public.dispute_lines dl
          where dl.dispute_id = p_dispute_id
            and dl.resolved_via_child_order_id = v_child_id
        ),
        'approved_replacement_qty', v_legacy_qty,
        'notes', p_notes,
        'staff_id', p_staff_id
      )
    );
  end if;

  update public.disputes
  set status = 'replaced',
      replacement_child_order_id = v_child_id,
      resolved_at = coalesce(resolved_at, now())
  where id = p_dispute_id;

  return v_child_id;
end;
$function$;

comment on function public.staff_accept_replacement_outcome_v1(uuid,uuid,text) is
  'Atomic final replacement acceptance. Physical replacements use one exact remedy-linked line; legacy multi-line children retain aggregate provenance in escalation metadata without falsely claiming one source line.';

commit;
