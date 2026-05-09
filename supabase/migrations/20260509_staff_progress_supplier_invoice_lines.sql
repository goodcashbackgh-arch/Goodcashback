create or replace function public.staff_progress_supplier_invoice_lines(
  p_order_id uuid,
  p_supplier_invoice_id uuid,
  p_line_ids uuid[],
  p_progress_notes text default null
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff_id uuid;
  v_staff_role text;
  v_invoice record;
  v_order record;
  v_selected_count integer;
  v_open_exception_count integer;
  v_current_progressed_qty numeric := 0;
  v_current_progressed_amount numeric := 0;
  v_selected_unprogressed_qty numeric := 0;
  v_selected_unprogressed_amount numeric := 0;
  v_updated_count integer := 0;
begin
  select s.id, s.role_type
    into v_staff_id, v_staff_role
  from public.staff s
  where s.auth_user_id = auth.uid()
    and s.active = true
  limit 1;

  if v_staff_id is null or v_staff_role not in ('admin', 'supervisor') then
    raise exception 'Only active admin or supervisor staff can progress supplier invoice lines.';
  end if;

  if p_order_id is null or p_supplier_invoice_id is null then
    raise exception 'Order and supplier invoice are required.';
  end if;

  if p_line_ids is null or array_length(p_line_ids, 1) is null then
    raise exception 'Select at least one supplier invoice line to progress.';
  end if;

  select si.id, si.order_id, si.review_status, si.is_current_for_order
    into v_invoice
  from public.supplier_invoices si
  where si.id = p_supplier_invoice_id
    and si.order_id = p_order_id;

  if v_invoice.id is null then
    raise exception 'Supplier invoice does not belong to this order.';
  end if;

  if coalesce(v_invoice.review_status, '') in ('rejected_resubmit_required', 'superseded', 'duplicate_blocked') then
    raise exception 'Cannot progress lines on a rejected, superseded, or duplicate-blocked invoice.';
  end if;

  if coalesce(v_invoice.is_current_for_order, false) then
    raise exception 'Cannot progress lines after supplier invoice is already approved current.';
  end if;

  select o.id, o.total_qty_declared, o.order_total_gbp_declared
    into v_order
  from public.orders o
  where o.id = p_order_id;

  if v_order.id is null then
    raise exception 'Order not found.';
  end if;

  select count(*)
    into v_selected_count
  from public.supplier_invoice_lines sil
  where sil.supplier_invoice_id = p_supplier_invoice_id
    and sil.id = any(p_line_ids);

  if v_selected_count <> array_length(p_line_ids, 1) then
    raise exception 'One or more selected lines do not belong to this supplier invoice.';
  end if;

  select count(*)
    into v_open_exception_count
  from public.dispute_lines dl
  where dl.supplier_invoice_line_id = any(p_line_ids)
    and dl.resolved_at is null;

  if v_open_exception_count > 0 then
    raise exception 'Exception-linked lines cannot be progressed by supervisor takeover.';
  end if;

  select
    coalesce(sum(coalesce(sil.qty_confirmed, sil.qty, 0)), 0),
    coalesce(sum(coalesce(sil.amount_confirmed, sil.amount_inc_vat_gbp, 0)), 0)
    into v_current_progressed_qty, v_current_progressed_amount
  from public.supplier_invoice_lines sil
  join public.supplier_invoices si on si.id = sil.supplier_invoice_id
  where si.order_id = p_order_id
    and coalesce(si.review_status, '') not in ('rejected_resubmit_required', 'superseded', 'duplicate_blocked')
    and coalesce(lower(sil.eligible_for_invoice_yn), '') in ('y', 'yes', 'true', '1')
    and not (sil.id = any(p_line_ids));

  select
    coalesce(sum(coalesce(sil.qty_confirmed, sil.qty, 0)), 0),
    coalesce(sum(coalesce(sil.amount_confirmed, sil.amount_inc_vat_gbp, 0)), 0)
    into v_selected_unprogressed_qty, v_selected_unprogressed_amount
  from public.supplier_invoice_lines sil
  where sil.supplier_invoice_id = p_supplier_invoice_id
    and sil.id = any(p_line_ids)
    and coalesce(lower(sil.eligible_for_invoice_yn), '') not in ('y', 'yes', 'true', '1');

  if v_current_progressed_qty + v_selected_unprogressed_qty > coalesce(v_order.total_qty_declared, 0) then
    raise exception 'Cannot progress selected lines because they exceed the original order quantity baseline. Move excess or mismatched items into the exception path.';
  end if;

  if v_current_progressed_amount + v_selected_unprogressed_amount > coalesce(v_order.order_total_gbp_declared, 0) + 0.01 then
    raise exception 'Cannot progress selected lines because they exceed the original order value baseline. Move excess or mismatched items into the exception path.';
  end if;

  update public.supplier_invoice_lines sil
     set eligible_for_invoice_yn = 'Y',
         qty_confirmed = coalesce(sil.qty_confirmed, sil.qty),
         amount_confirmed = coalesce(sil.amount_confirmed, sil.amount_inc_vat_gbp)
   where sil.supplier_invoice_id = p_supplier_invoice_id
     and sil.id = any(p_line_ids)
     and coalesce(lower(sil.eligible_for_invoice_yn), '') not in ('y', 'yes', 'true', '1');

  get diagnostics v_updated_count = row_count;

  return v_updated_count;
end;
$$;

grant execute on function public.staff_progress_supplier_invoice_lines(uuid, uuid, uuid[], text) to authenticated;
