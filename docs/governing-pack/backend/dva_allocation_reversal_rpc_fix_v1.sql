-- dva_allocation_reversal_rpc_fix_v1.sql
-- Status: EXECUTABLE SQL PATCH - RUN IN SUPABASE SQL EDITOR.
--
-- Fixes:
--   new row for relation "dva_statement_line_allocations" violates check constraint
--   "dva_statement_line_allocations_reversed_check"
--
-- Cause:
--   The table requires reversed_by_staff_id, reversed_at, and reversal_reason whenever
--   allocation_status = 'reversed'. The previous reversal RPC only changed status + notes.
--
-- Scope:
--   Replace reversal RPC only. No table/constraint changes. No deletion. No Sage posting.

begin;

set local lock_timeout = '15s';
set local statement_timeout = '0';

create or replace function public.staff_reverse_dva_statement_line_allocation(
  p_allocation_id uuid,
  p_reversal_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_auth_uid uuid := auth.uid();
  v_staff record;
  v_allocation record;
  v_reason text := nullif(trim(coalesce(p_reversal_reason, '')), '');
  v_remaining_after numeric(12,2);
  v_allocated_after numeric(12,2);
begin
  if v_auth_uid is null then
    raise exception 'Unauthenticated user: allocation reversal requires auth.uid()';
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
    raise exception 'Only admin or supervisor staff can reverse DVA/card allocations. Current role: %', v_staff.role_type;
  end if;

  if v_reason is null or length(v_reason) < 8 then
    raise exception 'A reversal reason of at least 8 characters is required.';
  end if;

  select a.*
    into v_allocation
  from public.dva_statement_line_allocations a
  where a.id = p_allocation_id
  for update;

  if v_allocation.id is null then
    raise exception 'Allocation not found: %', p_allocation_id;
  end if;

  if v_allocation.allocation_status = 'reversed' then
    raise exception 'Allocation % is already reversed.', p_allocation_id;
  end if;

  update public.dva_statement_line_allocations a
     set allocation_status = 'reversed',
         reversed_by_staff_id = v_staff.id,
         reversed_at = now(),
         reversal_reason = v_reason,
         notes = concat_ws(E'\n', a.notes, 'REVERSAL: ' || v_reason)
   where a.id = p_allocation_id;

  select
    round(coalesce(sum(a.allocated_gbp_amount), 0)::numeric, 2),
    round(coalesce(max(dsl.amount_gbp_equivalent), 0)::numeric - coalesce(sum(a.allocated_gbp_amount), 0)::numeric, 2)
    into v_allocated_after, v_remaining_after
  from public.dva_statement_lines dsl
  left join public.dva_statement_line_allocations a
    on a.dva_statement_line_id = dsl.id
   and a.allocation_status = 'confirmed'
  where dsl.id = v_allocation.dva_statement_line_id;

  return jsonb_build_object(
    'ok', true,
    'allocation_id', p_allocation_id,
    'dva_statement_line_id', v_allocation.dva_statement_line_id,
    'reversed_allocation_type', v_allocation.allocation_type,
    'reversed_amount_gbp', v_allocation.allocated_gbp_amount,
    'confirmed_allocated_after_gbp', coalesce(v_allocated_after, 0),
    'confirmed_unallocated_after_gbp', coalesce(v_remaining_after, 0),
    'reversal_reason', v_reason
  );
end;
$$;

comment on function public.staff_reverse_dva_statement_line_allocation(uuid, text) is
'Staff/supervisor SECURITY DEFINER RPC to reverse one DVA/card allocation row by marking it reversed and populating reversed_by_staff_id, reversed_at, and reversal_reason for the table check constraint.';

revoke all on function public.staff_reverse_dva_statement_line_allocation(uuid, text) from public;
grant execute on function public.staff_reverse_dva_statement_line_allocation(uuid, text) to authenticated;

commit;

-- Smoke check:
-- select to_regprocedure('public.staff_reverse_dva_statement_line_allocation(uuid,text)') as reversal_rpc;
