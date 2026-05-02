-- staff_dva_fx_card_fee_allocation_v1.sql
-- Status: EXECUTABLE SQL PATCH - RUN ONLY AFTER REVIEW/APPROVAL IN CURRENT CHAT.
-- Scope: staff/supervisor allocation of remaining OUT DVA/card statement-line balance
--        to FX/card difference or bank fee.
--
-- Creates:
--   public.staff_allocate_statement_line_to_fx_card_or_fee(...)
--
-- Does not:
--   - alter tables;
--   - change funding reconciliation;
--   - allocate to supplier invoices;
--   - post to Sage;
--   - create direct browser table writes.
--
-- Boundary:
--   This is only for residual card/FX/fee balances after operational allocation review.
--   Supplier purchase allocation remains staff_allocate_statement_line_to_supplier_invoice(...).

begin;

set local lock_timeout = '15s';
set local statement_timeout = '0';

create or replace function public.staff_allocate_statement_line_to_fx_card_or_fee(
  p_dva_statement_line_id uuid,
  p_allocation_type varchar,
  p_allocated_gbp_amount numeric,
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
  v_existing_confirmed_total numeric(12,2);
  v_confirmed_total_after numeric(12,2);
  v_unallocated_before numeric(12,2);
  v_unallocated_after numeric(12,2);
  v_amount numeric(12,2);
  v_allocation_id uuid;
begin
  if v_auth_uid is null then
    raise exception 'Unauthenticated user: FX/card/fee allocation requires auth.uid()';
  end if;

  select s.id, s.role_type
    into v_staff
  from staff s
  where s.auth_user_id = v_auth_uid
    and coalesce(s.active, true) = true
  limit 1;

  if v_staff.id is null then
    raise exception 'Active staff user not found for auth user %', v_auth_uid;
  end if;

  if v_staff.role_type not in ('admin', 'supervisor') then
    raise exception 'Only admin or supervisor staff can allocate FX/card/fee differences. Current role: %', v_staff.role_type;
  end if;

  if p_allocation_type not in ('fx_card_difference', 'bank_fee') then
    raise exception 'Unsupported allocation type %. Use fx_card_difference or bank_fee', p_allocation_type;
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
  from dva_statement_lines dsl
  join dva_statements ds
    on ds.id = dsl.dva_statement_id
  where dsl.id = p_dva_statement_line_id
  for update of dsl;

  if v_line.id is null then
    raise exception 'DVA/card statement line not found: %', p_dva_statement_line_id;
  end if;

  if v_line.direction <> 'out' then
    raise exception 'FX/card/fee allocation currently requires an OUT statement line. Line % has direction %', p_dva_statement_line_id, v_line.direction;
  end if;

  if coalesce(v_line.amount_gbp_equivalent, 0) <= 0 then
    raise exception 'Statement line % has invalid GBP equivalent %', p_dva_statement_line_id, v_line.amount_gbp_equivalent;
  end if;

  select round(coalesce(sum(a.allocated_gbp_amount), 0)::numeric, 2)
    into v_existing_confirmed_total
  from dva_statement_line_allocations a
  where a.dva_statement_line_id = p_dva_statement_line_id
    and a.allocation_status = 'confirmed';

  v_unallocated_before := round(v_line.amount_gbp_equivalent::numeric - v_existing_confirmed_total, 2);

  if v_amount > v_unallocated_before + 0.01 then
    raise exception 'FX/card/fee allocation would over-allocate statement line %. Statement GBP %, already confirmed %, remaining %, proposed %',
      p_dva_statement_line_id,
      round(v_line.amount_gbp_equivalent::numeric, 2),
      v_existing_confirmed_total,
      v_unallocated_before,
      v_amount;
  end if;

  insert into dva_statement_line_allocations (
    dva_statement_line_id,
    allocation_type,
    supplier_invoice_id,
    dispute_id,
    order_id,
    allocated_gbp_amount,
    allocation_status,
    fx_rate_applied,
    card_markup_pct_applied,
    fx_or_card_diff_gbp,
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
    null,
    null,
    v_amount,
    'confirmed',
    v_line.fx_rate_applied,
    v_line.card_markup_pct_applied,
    case when p_allocation_type = 'fx_card_difference' then v_amount else null end,
    p_notes,
    v_staff.id,
    now(),
    v_staff.id,
    now()
  )
  returning id into v_allocation_id;

  select round(coalesce(sum(a.allocated_gbp_amount), 0)::numeric, 2)
    into v_confirmed_total_after
  from dva_statement_line_allocations a
  where a.dva_statement_line_id = p_dva_statement_line_id
    and a.allocation_status = 'confirmed';

  v_unallocated_after := round(v_line.amount_gbp_equivalent::numeric - v_confirmed_total_after, 2);

  return jsonb_build_object(
    'ok', true,
    'allocation_id', v_allocation_id,
    'dva_statement_line_id', p_dva_statement_line_id,
    'allocation_type', p_allocation_type,
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

comment on function public.staff_allocate_statement_line_to_fx_card_or_fee(uuid, varchar, numeric, text) is
'Staff/supervisor SECURITY DEFINER RPC to allocate remaining OUT DVA/card statement-line balance to FX/card difference or bank fee. Does not post to Sage.';

revoke all on function public.staff_allocate_statement_line_to_fx_card_or_fee(uuid, varchar, numeric, text) from public;
grant execute on function public.staff_allocate_statement_line_to_fx_card_or_fee(uuid, varchar, numeric, text) to authenticated;

commit;

-- Smoke checks after execution:
-- select to_regprocedure('public.staff_allocate_statement_line_to_fx_card_or_fee(uuid,character varying,numeric,text)') as fx_fee_rpc;
