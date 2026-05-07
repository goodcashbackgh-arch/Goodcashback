-- staff_dva_dispute_hold_allocation_v1a_schema_fix.sql
-- Status: EXECUTABLE SQL PATCH - RUN ONLY AFTER REVIEW/APPROVAL IN CURRENT CHAT.
-- Scope: fixes stale live-schema reference in staff_allocate_statement_line_to_dispute_or_hold.
--
-- Problem found during refund-IN allocation test:
--   The v1 RPC selected d.dispute_type from public.disputes.
--   The live canonical disputes table does not have dispute_type; it has issue_type and desired_outcome.
--
-- Behaviour:
--   Replaces only the RPC body; no table, constraint, RLS, or allocation schema changes.

begin;

create or replace function public.staff_allocate_statement_line_to_dispute_or_hold(
  p_dva_statement_line_id uuid,
  p_allocation_type varchar,
  p_dispute_id uuid default null,
  p_allocated_gbp_amount numeric default null,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_auth_uid uuid := auth.uid();
  v_staff record;
  v_line record;
  v_dispute record;
  v_order record;
  v_existing_active_allocation_id uuid;
  v_existing_confirmed_total numeric(12,2);
  v_confirmed_total_after numeric(12,2);
  v_unallocated_before numeric(12,2);
  v_unallocated_after numeric(12,2);
  v_amount numeric(12,2);
  v_allocation_id uuid;
begin
  if v_auth_uid is null then
    raise exception 'Unauthenticated user: operational allocation requires auth.uid()';
  end if;

  select s.id, s.role_type
    into v_staff
  from public.staff s
  where s.auth_user_id = v_auth_uid
    and coalesce(s.active, true) = true
  limit 1;

  if v_staff.id is null then
    raise exception 'Active staff user not found for auth user %', v_auth_uid;
  end if;

  if v_staff.role_type not in ('admin', 'supervisor') then
    raise exception 'Only admin or supervisor staff can allocate DVA/card operational targets. Current role: %', v_staff.role_type;
  end if;

  if p_allocation_type not in ('retailer_refund', 'exception_hold', 'not_charged_closure', 'unmatched_hold') then
    raise exception 'Unsupported operational allocation type %. Use retailer_refund, exception_hold, not_charged_closure, or unmatched_hold', p_allocation_type;
  end if;

  if p_allocation_type in ('retailer_refund', 'exception_hold', 'not_charged_closure') and p_dispute_id is null then
    raise exception 'Dispute reference is required for allocation type %', p_allocation_type;
  end if;

  if p_allocation_type = 'unmatched_hold' and p_dispute_id is not null then
    raise exception 'Unmatched hold should not be linked to a dispute. Use exception_hold for dispute-linked holds.';
  end if;

  v_amount := round(coalesce(p_allocated_gbp_amount, 0)::numeric, 2);

  if v_amount <= 0 then
    raise exception 'Allocated GBP amount must be greater than zero. Received: %', v_amount;
  end if;

  select
    dsl.id,
    dsl.direction,
    dsl.amount_gbp_equivalent,
    dsl.fx_rate_applied,
    dsl.card_markup_pct_applied,
    ds.importer_id
  into v_line
  from public.dva_statement_lines dsl
  join public.dva_statements ds
    on ds.id = dsl.dva_statement_id
  where dsl.id = p_dva_statement_line_id
  for update of dsl;

  if v_line.id is null then
    raise exception 'DVA/card statement line not found: %', p_dva_statement_line_id;
  end if;

  if coalesce(v_line.amount_gbp_equivalent, 0) <= 0 then
    raise exception 'Statement line % has invalid GBP equivalent %', p_dva_statement_line_id, v_line.amount_gbp_equivalent;
  end if;

  if p_allocation_type = 'retailer_refund' and v_line.direction <> 'in' then
    raise exception 'Retailer refund allocation requires an IN statement line. Line % has direction %', p_dva_statement_line_id, v_line.direction;
  end if;

  if p_allocation_type in ('exception_hold', 'not_charged_closure', 'unmatched_hold') and v_line.direction <> 'out' then
    raise exception 'Exception/hold allocation requires an OUT statement line. Line % has direction %', p_dva_statement_line_id, v_line.direction;
  end if;

  if p_dispute_id is not null then
    select
      d.id,
      d.order_id,
      d.status,
      d.issue_type,
      d.desired_outcome,
      d.replacement_child_order_id
    into v_dispute
    from public.disputes d
    where d.id = p_dispute_id
    for update;

    if v_dispute.id is null then
      raise exception 'Dispute not found: %', p_dispute_id;
    end if;

    select
      o.id,
      o.order_ref,
      o.importer_id,
      o.status,
      coalesce(o.order_type, 'original') as order_type
    into v_order
    from public.orders o
    where o.id = v_dispute.order_id
    for update;

    if v_order.id is null then
      raise exception 'Order not found for dispute %', p_dispute_id;
    end if;

    if v_order.importer_id is distinct from v_line.importer_id then
      raise exception 'Importer mismatch: statement line importer % cannot allocate to dispute % / order % importer %',
        v_line.importer_id, p_dispute_id, v_order.id, v_order.importer_id;
    end if;

    if v_order.status in ('archived', 'cancelled') then
      raise exception 'Cannot allocate statement line to dispute on order % with status %', v_order.id, v_order.status;
    end if;

    select a.id
      into v_existing_active_allocation_id
    from public.dva_statement_line_allocations a
    where a.dva_statement_line_id = p_dva_statement_line_id
      and a.dispute_id = p_dispute_id
      and a.allocation_type = p_allocation_type
      and a.allocation_status <> 'reversed'
    limit 1;

    if v_existing_active_allocation_id is not null then
      raise exception 'Active allocation already exists for statement line %, dispute %, type %: %',
        p_dva_statement_line_id, p_dispute_id, p_allocation_type, v_existing_active_allocation_id;
    end if;
  end if;

  select round(coalesce(sum(a.allocated_gbp_amount), 0)::numeric, 2)
    into v_existing_confirmed_total
  from public.dva_statement_line_allocations a
  where a.dva_statement_line_id = p_dva_statement_line_id
    and a.allocation_status = 'confirmed';

  v_unallocated_before := round(v_line.amount_gbp_equivalent::numeric - v_existing_confirmed_total, 2);

  if v_amount > v_unallocated_before + 0.01 then
    raise exception 'Operational allocation would over-allocate statement line %. Statement GBP %, already confirmed %, remaining %, proposed %',
      p_dva_statement_line_id,
      round(v_line.amount_gbp_equivalent::numeric, 2),
      v_existing_confirmed_total,
      v_unallocated_before,
      v_amount;
  end if;

  insert into public.dva_statement_line_allocations (
    dva_statement_line_id,
    allocation_type,
    supplier_invoice_id,
    dispute_id,
    order_id,
    allocated_gbp_amount,
    allocation_status,
    fx_rate_applied,
    card_markup_pct_applied,
    notes,
    created_by_staff_id,
    created_at,
    confirmed_by_staff_id,
    confirmed_at
  )
  values (
    p_dva_statement_line_id,
    p_allocation_type,
    null,
    p_dispute_id,
    case when p_dispute_id is not null then v_order.id else null end,
    v_amount,
    'confirmed',
    v_line.fx_rate_applied,
    v_line.card_markup_pct_applied,
    p_notes,
    v_staff.id,
    now(),
    v_staff.id,
    now()
  )
  returning id into v_allocation_id;

  select round(coalesce(sum(a.allocated_gbp_amount), 0)::numeric, 2)
    into v_confirmed_total_after
  from public.dva_statement_line_allocations a
  where a.dva_statement_line_id = p_dva_statement_line_id
    and a.allocation_status = 'confirmed';

  v_unallocated_after := round(v_line.amount_gbp_equivalent::numeric - v_confirmed_total_after, 2);

  return jsonb_build_object(
    'ok', true,
    'allocation_id', v_allocation_id,
    'dva_statement_line_id', p_dva_statement_line_id,
    'allocation_type', p_allocation_type,
    'dispute_id', p_dispute_id,
    'order_id', case when p_dispute_id is not null then v_order.id else null end,
    'order_ref', case when p_dispute_id is not null then v_order.order_ref else null end,
    'importer_id', v_line.importer_id,
    'allocated_gbp_amount', v_amount,
    'statement_gbp_amount', round(v_line.amount_gbp_equivalent::numeric, 2),
    'confirmed_allocated_before_gbp', v_existing_confirmed_total,
    'confirmed_unallocated_before_gbp', v_unallocated_before,
    'confirmed_allocated_after_gbp', v_confirmed_total_after,
    'confirmed_unallocated_after_gbp', v_unallocated_after,
    'balanced_yn', abs(v_unallocated_after) < 0.01
  );
end;
$$;

comment on function public.staff_allocate_statement_line_to_dispute_or_hold(uuid, varchar, uuid, numeric, text) is
'Staff/supervisor SECURITY DEFINER RPC to allocate one DVA/card statement line to a refund dispute, exception hold, not-charged closure, or unmatched hold. v1a fixes stale disputes.dispute_type reference to live issue_type/desired_outcome schema. Does not post to Sage.';

revoke all on function public.staff_allocate_statement_line_to_dispute_or_hold(uuid, varchar, uuid, numeric, text) from public;
grant execute on function public.staff_allocate_statement_line_to_dispute_or_hold(uuid, varchar, uuid, numeric, text) to authenticated;

commit;
