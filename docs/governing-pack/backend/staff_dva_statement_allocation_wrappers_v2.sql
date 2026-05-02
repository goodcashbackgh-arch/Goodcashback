-- staff_dva_statement_allocation_wrappers_v2.sql
-- Status: EXECUTABLE SQL PATCH - RUN ONLY AFTER REVIEW/APPROVAL IN CURRENT CHAT.
-- Scope: replace public.staff_allocate_statement_line_to_supplier_invoice(...) with an added
-- supplier-invoice over-allocation guard.
--
-- Adds protection:
--   - still blocks statement-line over-allocation;
--   - now also blocks supplier-invoice over-allocation across all confirmed supplier-invoice allocations.
--
-- Does not:
--   - alter tables;
--   - change existing DVA/funding RPCs;
--   - post to Sage;
--   - add UI buttons;
--   - create direct browser table writes.

begin;

set local lock_timeout = '15s';
set local statement_timeout = '0';

create or replace function public.staff_allocate_statement_line_to_supplier_invoice(
  p_dva_statement_line_id uuid,
  p_supplier_invoice_id uuid,
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
  v_invoice record;
  v_order record;
  v_existing_active_allocation_id uuid;
  v_confirmed_total_before numeric(12,2);
  v_confirmed_total_after numeric(12,2);
  v_unallocated_after numeric(12,2);
  v_invoice_total_gbp numeric(12,2);
  v_supplier_confirmed_before numeric(12,2);
  v_supplier_confirmed_after numeric(12,2);
  v_supplier_unallocated_after numeric(12,2);
  v_amount numeric(12,2);
  v_allocation_id uuid;
begin
  -- Staff identity is derived from auth.uid(); browser must not pass staff id.
  if v_auth_uid is null then
    raise exception 'Unauthenticated user: staff allocation requires auth.uid()';
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
    raise exception 'Only admin or supervisor staff can allocate DVA/card statement lines. Current role: %', v_staff.role_type;
  end if;

  v_amount := round(coalesce(p_allocated_gbp_amount, 0)::numeric, 2);

  if v_amount <= 0 then
    raise exception 'Allocated GBP amount must be greater than zero. Received: %', v_amount;
  end if;

  -- Lock and validate the real statement line.
  select
    dsl.id,
    dsl.direction,
    dsl.amount_gbp_equivalent,
    dsl.match_status,
    dsl.auth_id_ref,
    dsl.reference_raw,
    dsl.retailer_name_ref,
    dsl.statement_date,
    dsl.local_ccy,
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
    raise exception 'Supplier invoice allocation requires an OUT statement line. Line % has direction %', p_dva_statement_line_id, v_line.direction;
  end if;

  if coalesce(v_line.amount_gbp_equivalent, 0) <= 0 then
    raise exception 'Statement line % has invalid GBP equivalent %', p_dva_statement_line_id, v_line.amount_gbp_equivalent;
  end if;

  -- Lock and validate supplier invoice/order/importer consistency.
  select
    si.id,
    si.order_id,
    si.invoice_ref,
    si.ocr_invoice_ref,
    si.ocr_invoice_total_gbp,
    si.reconciliation_gbp_total,
    si.review_status
  into v_invoice
  from supplier_invoices si
  where si.id = p_supplier_invoice_id
  for update;

  if v_invoice.id is null then
    raise exception 'Supplier invoice not found: %', p_supplier_invoice_id;
  end if;

  select
    round(
      coalesce(
        v_invoice.ocr_invoice_total_gbp,
        v_invoice.reconciliation_gbp_total,
        sum(coalesce(sil.amount_confirmed, sil.amount_inc_vat_gbp, 0))
      )::numeric,
      2
    )
    into v_invoice_total_gbp
  from supplier_invoice_lines sil
  where sil.supplier_invoice_id = p_supplier_invoice_id;

  if coalesce(v_invoice_total_gbp, 0) <= 0 then
    raise exception 'Supplier invoice % has no positive invoice total available for allocation', p_supplier_invoice_id;
  end if;

  select
    o.id,
    o.order_ref,
    o.importer_id,
    o.retailer_id,
    o.status,
    coalesce(o.order_type, 'original') as order_type
  into v_order
  from orders o
  where o.id = v_invoice.order_id
  for update;

  if v_order.id is null then
    raise exception 'Order not found for supplier invoice %', p_supplier_invoice_id;
  end if;

  if v_order.importer_id is distinct from v_line.importer_id then
    raise exception 'Importer mismatch: statement line importer % cannot allocate to invoice % / order % importer %',
      v_line.importer_id, p_supplier_invoice_id, v_order.id, v_order.importer_id;
  end if;

  if v_order.status in ('archived', 'cancelled') then
    raise exception 'Cannot allocate statement line to supplier invoice on order % with status %', v_order.id, v_order.status;
  end if;

  -- Prevent duplicate active allocation from the same statement line to the same invoice.
  select a.id
    into v_existing_active_allocation_id
  from dva_statement_line_allocations a
  where a.dva_statement_line_id = p_dva_statement_line_id
    and a.supplier_invoice_id = p_supplier_invoice_id
    and a.allocation_type = 'supplier_invoice'
    and a.allocation_status <> 'reversed'
  limit 1;

  if v_existing_active_allocation_id is not null then
    raise exception 'Active allocation already exists for statement line % and supplier invoice %: %',
      p_dva_statement_line_id, p_supplier_invoice_id, v_existing_active_allocation_id;
  end if;

  -- Guard 1: do not over-allocate the statement line.
  select round(coalesce(sum(a.allocated_gbp_amount), 0)::numeric, 2)
    into v_confirmed_total_before
  from dva_statement_line_allocations a
  where a.dva_statement_line_id = p_dva_statement_line_id
    and a.allocation_status = 'confirmed';

  if v_confirmed_total_before + v_amount > round(v_line.amount_gbp_equivalent::numeric, 2) + 0.01 then
    raise exception 'Allocation would over-allocate statement line %. Statement GBP %, already confirmed %, proposed %',
      p_dva_statement_line_id, round(v_line.amount_gbp_equivalent::numeric, 2), v_confirmed_total_before, v_amount;
  end if;

  -- Guard 2: do not over-allocate the supplier invoice across all statement lines.
  select round(coalesce(sum(a.allocated_gbp_amount), 0)::numeric, 2)
    into v_supplier_confirmed_before
  from dva_statement_line_allocations a
  where a.supplier_invoice_id = p_supplier_invoice_id
    and a.allocation_type = 'supplier_invoice'
    and a.allocation_status = 'confirmed';

  if v_supplier_confirmed_before + v_amount > v_invoice_total_gbp + 0.01 then
    raise exception 'Allocation would over-allocate supplier invoice %. Invoice GBP %, already confirmed %, proposed %',
      p_supplier_invoice_id, v_invoice_total_gbp, v_supplier_confirmed_before, v_amount;
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
    notes,
    created_by_staff_id,
    created_at,
    confirmed_by_staff_id,
    confirmed_at
  )
  values (
    p_dva_statement_line_id,
    'supplier_invoice',
    p_supplier_invoice_id,
    null,
    v_order.id,
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
  from dva_statement_line_allocations a
  where a.dva_statement_line_id = p_dva_statement_line_id
    and a.allocation_status = 'confirmed';

  select round(coalesce(sum(a.allocated_gbp_amount), 0)::numeric, 2)
    into v_supplier_confirmed_after
  from dva_statement_line_allocations a
  where a.supplier_invoice_id = p_supplier_invoice_id
    and a.allocation_type = 'supplier_invoice'
    and a.allocation_status = 'confirmed';

  v_unallocated_after := round(v_line.amount_gbp_equivalent::numeric - v_confirmed_total_after, 2);
  v_supplier_unallocated_after := round(v_invoice_total_gbp - v_supplier_confirmed_after, 2);

  return jsonb_build_object(
    'ok', true,
    'allocation_id', v_allocation_id,
    'dva_statement_line_id', p_dva_statement_line_id,
    'supplier_invoice_id', p_supplier_invoice_id,
    'order_id', v_order.id,
    'order_ref', v_order.order_ref,
    'importer_id', v_order.importer_id,
    'allocated_gbp_amount', v_amount,
    'statement_gbp_amount', round(v_line.amount_gbp_equivalent::numeric, 2),
    'confirmed_allocated_before_gbp', v_confirmed_total_before,
    'confirmed_allocated_after_gbp', v_confirmed_total_after,
    'confirmed_unallocated_after_gbp', v_unallocated_after,
    'balanced_yn', abs(v_unallocated_after) < 0.01,
    'needs_fx_or_additional_allocation_yn', abs(v_unallocated_after) >= 0.01,
    'invoice_ref', coalesce(v_invoice.ocr_invoice_ref, v_invoice.invoice_ref),
    'invoice_total_gbp', v_invoice_total_gbp,
    'supplier_invoice_confirmed_before_gbp', v_supplier_confirmed_before,
    'supplier_invoice_confirmed_after_gbp', v_supplier_confirmed_after,
    'supplier_invoice_unallocated_after_gbp', v_supplier_unallocated_after,
    'supplier_invoice_fully_allocated_yn', abs(v_supplier_unallocated_after) < 0.01
  );
end;
$$;

comment on function public.staff_allocate_statement_line_to_supplier_invoice(uuid, uuid, numeric, text) is
'Staff/supervisor SECURITY DEFINER RPC to allocate one OUT DVA/card statement line to one supplier invoice. v2 blocks statement-line and supplier-invoice over-allocation. Does not post to Sage and does not reuse order-funding reconciliation.';

revoke all on function public.staff_allocate_statement_line_to_supplier_invoice(uuid, uuid, numeric, text) from public;
grant execute on function public.staff_allocate_statement_line_to_supplier_invoice(uuid, uuid, numeric, text) to authenticated;

commit;

-- Smoke checks after execution:
-- select to_regprocedure('public.staff_allocate_statement_line_to_supplier_invoice(uuid,uuid,numeric,text)') as allocation_rpc;
-- select obj_description('public.staff_allocate_statement_line_to_supplier_invoice(uuid,uuid,numeric,text)'::regprocedure, 'pg_proc') as rpc_comment;
