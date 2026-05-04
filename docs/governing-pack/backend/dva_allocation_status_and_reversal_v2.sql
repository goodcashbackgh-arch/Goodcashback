-- dva_allocation_status_and_reversal_v2.sql
-- Status: EXECUTABLE SQL PATCH - RUN ONLY AFTER REVIEW/APPROVAL IN CURRENT CHAT.
-- Fixes v1 failure where live public.dva_statement_lines did not contain transaction_date.
--
-- Scope: server-side allocation status/read views + staff/supervisor reversal RPC.
-- Schema-safe approach:
--   - Do not assume optional display columns exist on public.dva_statement_lines.
--   - Use import linkage tables for statement/transaction dates where available.
--   - Dynamically creates views using only columns present in the live DB.
--
-- Creates/replaces:
--   public.dva_statement_line_allocation_status_vw
--   public.dva_statement_line_allocation_detail_vw
--   public.staff_reverse_dva_statement_line_allocation(uuid, text)

begin;

set local lock_timeout = '15s';
set local statement_timeout = '0';

-- -----------------------------------------------------------------------------
-- 1. Schema-safe status/detail views
-- -----------------------------------------------------------------------------

do $$
declare
  v_line_statement_date_expr text;
  v_line_transaction_date_expr text;
  v_line_description_expr text;
  v_line_reference_expr text;
  v_line_amount_local_expr text;
  v_line_currency_expr text;
  v_supplier_invoice_ref_expr text;
  v_order_ref_expr text;
  v_has_col boolean;
begin
  -- Prefer active statement-line columns when present, otherwise fall back to import row linkage.
  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'dva_statement_lines' and column_name = 'statement_date'
  ) into v_has_col;
  v_line_statement_date_expr := case when v_has_col then 'coalesce(dsl.statement_date, dir.statement_date)' else 'dir.statement_date' end;

  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'dva_statement_lines' and column_name = 'transaction_date'
  ) into v_has_col;
  v_line_transaction_date_expr := case when v_has_col then 'coalesce(dsl.transaction_date, dir.transaction_date)' else 'dir.transaction_date' end;

  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'dva_statement_lines' and column_name = 'description'
  ) into v_has_col;
  v_line_description_expr := case when v_has_col then 'dsl.description' else 'dir.raw_text' end;

  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'dva_statement_lines' and column_name = 'reference'
  ) into v_has_col;
  v_line_reference_expr := case when v_has_col then 'dsl.reference' else 'dir.bank_reference' end;

  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'dva_statement_lines' and column_name = 'amount_local_ccy'
  ) into v_has_col;
  v_line_amount_local_expr := case when v_has_col then 'dsl.amount_local_ccy' else 'dir.amount_local_ccy' end;

  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'dva_statement_lines' and column_name = 'currency'
  ) into v_has_col;
  v_line_currency_expr := case when v_has_col then 'dsl.currency' else 'dir.local_ccy' end;

  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'supplier_invoices' and column_name = 'invoice_ref'
  ) into v_has_col;
  v_supplier_invoice_ref_expr := case when v_has_col then 'si.invoice_ref' else 'null::text' end;

  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'orders' and column_name = 'order_ref'
  ) into v_has_col;
  v_order_ref_expr := case when v_has_col then 'o.order_ref' else 'null::text' end;

  execute format($sql$
    create or replace view public.dva_statement_line_allocation_status_vw as
    with allocation_totals as (
      select
        a.dva_statement_line_id,
        round(coalesce(sum(a.allocated_gbp_amount) filter (where a.allocation_status = 'confirmed'), 0)::numeric, 2) as confirmed_allocated_gbp,
        round(coalesce(sum(a.allocated_gbp_amount) filter (where a.allocation_status = 'confirmed' and a.allocation_type = 'supplier_invoice'), 0)::numeric, 2) as confirmed_supplier_invoice_gbp,
        round(coalesce(sum(a.allocated_gbp_amount) filter (where a.allocation_status = 'confirmed' and a.allocation_type in ('retailer_refund', 'exception_hold', 'not_charged_closure', 'unmatched_hold')), 0)::numeric, 2) as confirmed_operational_gbp,
        round(coalesce(sum(a.allocated_gbp_amount) filter (where a.allocation_status = 'confirmed' and a.allocation_type in ('fx_card_difference', 'bank_fee')), 0)::numeric, 2) as confirmed_fx_fee_gbp,
        count(*) filter (where a.allocation_status = 'confirmed') as confirmed_allocation_count,
        count(*) filter (where a.allocation_status = 'held') as held_allocation_count,
        count(*) filter (where a.allocation_status = 'reversed') as reversed_allocation_count,
        count(*) as total_allocation_count
      from public.dva_statement_line_allocations a
      group by a.dva_statement_line_id
    )
    select
      dsl.id as dva_statement_line_id,
      dsl.dva_statement_id,
      ds.importer_id,
      %s as statement_date,
      %s as transaction_date,
      %s as description,
      %s as reference,
      dsl.direction,
      round(coalesce(dsl.amount_gbp_equivalent, 0)::numeric, 2) as statement_gbp_amount,
      round(coalesce(%s, 0)::numeric, 2) as amount_local_ccy,
      %s as currency,
      coalesce(t.confirmed_allocated_gbp, 0::numeric) as confirmed_allocated_gbp,
      coalesce(t.confirmed_supplier_invoice_gbp, 0::numeric) as confirmed_supplier_invoice_gbp,
      coalesce(t.confirmed_operational_gbp, 0::numeric) as confirmed_operational_gbp,
      coalesce(t.confirmed_fx_fee_gbp, 0::numeric) as confirmed_fx_fee_gbp,
      round(coalesce(dsl.amount_gbp_equivalent, 0)::numeric - coalesce(t.confirmed_allocated_gbp, 0::numeric), 2) as confirmed_unallocated_gbp,
      coalesce(t.confirmed_allocation_count, 0) as confirmed_allocation_count,
      coalesce(t.held_allocation_count, 0) as held_allocation_count,
      coalesce(t.reversed_allocation_count, 0) as reversed_allocation_count,
      coalesce(t.total_allocation_count, 0) as total_allocation_count,
      case
        when coalesce(t.held_allocation_count, 0) > 0 then 'held'
        when coalesce(t.confirmed_allocation_count, 0) = 0 and coalesce(t.reversed_allocation_count, 0) > 0 then 'reversed_only'
        when coalesce(t.confirmed_allocation_count, 0) = 0 then 'unmatched'
        when abs(round(coalesce(dsl.amount_gbp_equivalent, 0)::numeric - coalesce(t.confirmed_allocated_gbp, 0::numeric), 2)) < 0.01 then 'balanced'
        when coalesce(t.confirmed_allocated_gbp, 0::numeric) > 0 then 'part_allocated'
        else 'unmatched'
      end as allocation_status_bucket,
      case
        when coalesce(t.confirmed_allocation_count, 0) = 0 then true
        when abs(round(coalesce(dsl.amount_gbp_equivalent, 0)::numeric - coalesce(t.confirmed_allocated_gbp, 0::numeric), 2)) >= 0.01 then true
        else false
      end as selectable_for_new_allocation_yn,
      case
        when abs(round(coalesce(dsl.amount_gbp_equivalent, 0)::numeric - coalesce(t.confirmed_allocated_gbp, 0::numeric), 2)) < 0.01
          and coalesce(t.confirmed_allocation_count, 0) > 0
          and coalesce(t.held_allocation_count, 0) = 0
        then true else false
      end as ready_for_supervisor_review_yn
    from public.dva_statement_lines dsl
    join public.dva_statements ds
      on ds.id = dsl.dva_statement_id
    left join public.dva_statement_line_import_links dlil
      on dlil.dva_statement_line_id = dsl.id
    left join public.dva_statement_import_rows dir
      on dir.id = dlil.import_row_id
    left join allocation_totals t
      on t.dva_statement_line_id = dsl.id;
  $sql$,
    v_line_statement_date_expr,
    v_line_transaction_date_expr,
    v_line_description_expr,
    v_line_reference_expr,
    v_line_amount_local_expr,
    v_line_currency_expr
  );

  execute format($sql$
    create or replace view public.dva_statement_line_allocation_detail_vw as
    select
      a.id as allocation_id,
      a.dva_statement_line_id,
      ds.id as dva_statement_id,
      ds.importer_id,
      %s as transaction_date,
      %s as statement_date,
      %s as statement_description,
      %s as statement_reference,
      dsl.direction as statement_direction,
      round(coalesce(dsl.amount_gbp_equivalent, 0)::numeric, 2) as statement_gbp_amount,
      a.allocation_type,
      a.allocation_status,
      a.supplier_invoice_id,
      %s as supplier_invoice_ref,
      a.dispute_id,
      a.order_id,
      %s as order_ref,
      round(a.allocated_gbp_amount::numeric, 2) as allocated_gbp_amount,
      a.fx_rate_applied,
      a.card_markup_pct_applied,
      a.notes,
      a.created_by_staff_id,
      a.created_at,
      a.confirmed_by_staff_id,
      a.confirmed_at,
      case when a.allocation_status = 'reversed' then true else false end as reversed_yn
    from public.dva_statement_line_allocations a
    join public.dva_statement_lines dsl
      on dsl.id = a.dva_statement_line_id
    join public.dva_statements ds
      on ds.id = dsl.dva_statement_id
    left join public.dva_statement_line_import_links dlil
      on dlil.dva_statement_line_id = dsl.id
    left join public.dva_statement_import_rows dir
      on dir.id = dlil.import_row_id
    left join public.supplier_invoices si
      on si.id = a.supplier_invoice_id
    left join public.orders o
      on o.id = a.order_id;
  $sql$,
    v_line_transaction_date_expr,
    v_line_statement_date_expr,
    v_line_description_expr,
    v_line_reference_expr,
    v_supplier_invoice_ref_expr,
    v_order_ref_expr
  );
end $$;

comment on view public.dva_statement_line_allocation_status_vw is
'DB-backed status view for DVA/card statement-line allocation: unmatched, part_allocated, balanced, held, reversed_only. Used by supervisor workspace and review pages.';

grant select on public.dva_statement_line_allocation_status_vw to authenticated;

comment on view public.dva_statement_line_allocation_detail_vw is
'Detail view for confirmed/held/reversed DVA/card allocations across supplier invoices, disputes, FX/card differences, bank fees, and holds.';

grant select on public.dva_statement_line_allocation_detail_vw to authenticated;

-- -----------------------------------------------------------------------------
-- 2. Reversal RPC
-- -----------------------------------------------------------------------------

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
         notes = concat_ws(E'\n', a.notes, 'REVERSAL: ' || v_reason || ' | reversed_by_staff_id=' || v_staff.id::text || ' | reversed_at=' || now()::text)
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
'Staff/supervisor SECURITY DEFINER RPC to reverse a confirmed/held DVA/card allocation by marking the allocation row reversed and preserving an audit trail in notes.';

revoke all on function public.staff_reverse_dva_statement_line_allocation(uuid, text) from public;
grant execute on function public.staff_reverse_dva_statement_line_allocation(uuid, text) to authenticated;

commit;

-- Smoke checks after execution:
-- select to_regclass('public.dva_statement_line_allocation_status_vw') as status_view;
-- select to_regclass('public.dva_statement_line_allocation_detail_vw') as detail_view;
-- select to_regprocedure('public.staff_reverse_dva_statement_line_allocation(uuid,text)') as reversal_rpc;
