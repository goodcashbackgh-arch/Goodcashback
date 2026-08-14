CREATE OR REPLACE FUNCTION public.staff_progress_supplier_invoice_lines(p_order_id uuid, p_supplier_invoice_id uuid, p_line_ids uuid[], p_progress_notes text DEFAULT NULL::text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_staff_id uuid;
  v_staff_role text;
  v_invoice record;
  v_order record;
  v_selected_count integer;
  v_open_exception_count integer;
  v_selected_nonphysical_count integer;
  v_current_progressed_qty numeric := 0;
  v_current_progressed_amount numeric := 0;
  v_current_resolved_financial_amount numeric := 0;
  v_selected_unprogressed_qty numeric := 0;
  v_selected_unprogressed_amount numeric := 0;
  v_unresolved_financial_offset numeric := 0;
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

  select count(*)
    into v_selected_nonphysical_count
  from public.supplier_invoice_lines sil
  where sil.supplier_invoice_id = p_supplier_invoice_id
    and sil.id = any(p_line_ids)
    and (
      exists (
        select 1
        from public.supplier_invoice_line_resolutions r
        where r.supplier_invoice_line_id = sil.id
          and r.resolution_type = 'non_physical_financial'
          and r.active = true
      )
      or coalesce(sil.amount_inc_vat_gbp, 0) < 0
      or btrim(regexp_replace(lower(coalesce(sil.description, '')), '[^a-z0-9]+', ' ', 'g'))
           ~ '(^| )(discount|promotion|promotional|promo|voucher|coupon|saving|savings)( |$)'
      or btrim(regexp_replace(lower(coalesce(sil.description, '')), '[^a-z0-9]+', ' ', 'g'))
           ~ '(^| )(delivery|shipping|postage|freight|carriage)( |$)'
      or btrim(regexp_replace(lower(coalesce(sil.description, '')), '[^a-z0-9]+', ' ', 'g'))
           ~ '(^| )(fee|charge|surcharge)( |$)'
    );

  if v_selected_nonphysical_count > 0 then
    raise exception 'Non-physical financial lines cannot be progressed as physical goods.';
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
    and not exists (
      select 1
      from public.supplier_invoice_line_resolutions r
      where r.supplier_invoice_line_id = sil.id
        and r.resolution_type = 'non_physical_financial'
        and r.active = true
    );

  select coalesce(sum(
    case
      when r.financial_type = 'discount' then -abs(coalesce(sil.amount_inc_vat_gbp, r.amount_gbp, 0))
      when r.financial_type in ('delivery', 'fee') then abs(coalesce(sil.amount_inc_vat_gbp, r.amount_gbp, 0))
      when r.financial_type = 'zero_value_delivery' then 0
      else coalesce(sil.amount_inc_vat_gbp, r.amount_gbp, 0)
    end
  ), 0)
    into v_current_resolved_financial_amount
  from public.supplier_invoice_line_resolutions r
  join public.supplier_invoice_lines sil on sil.id = r.supplier_invoice_line_id
  join public.supplier_invoices si on si.id = sil.supplier_invoice_id
  where si.order_id = p_order_id
    and coalesce(si.review_status, '') not in ('rejected_resubmit_required', 'superseded', 'duplicate_blocked')
    and r.resolution_type = 'non_physical_financial'
    and r.active = true;

  select
    coalesce(sum(coalesce(sil.qty_confirmed, sil.qty, 0)), 0),
    coalesce(sum(coalesce(sil.amount_confirmed, sil.amount_inc_vat_gbp, 0)), 0)
    into v_selected_unprogressed_qty, v_selected_unprogressed_amount
  from public.supplier_invoice_lines sil
  where sil.supplier_invoice_id = p_supplier_invoice_id
    and sil.id = any(p_line_ids)
    and coalesce(lower(sil.eligible_for_invoice_yn), '') not in ('y', 'yes', 'true', '1');

  with participating_invoices as (
    select p_supplier_invoice_id as supplier_invoice_id
    union
    select distinct sil.supplier_invoice_id
    from public.supplier_invoice_lines sil
    join public.supplier_invoices si on si.id = sil.supplier_invoice_id
    where si.order_id = p_order_id
      and coalesce(si.review_status, '') not in ('rejected_resubmit_required', 'superseded', 'duplicate_blocked')
      and coalesce(lower(sil.eligible_for_invoice_yn), '') in ('y', 'yes', 'true', '1')
      and not exists (
        select 1
        from public.supplier_invoice_line_resolutions r
        where r.supplier_invoice_line_id = sil.id
          and r.resolution_type = 'non_physical_financial'
          and r.active = true
      )
  ), unresolved_financial_rows as (
    select
      sil.supplier_invoice_id,
      case
        when coalesce(sil.amount_inc_vat_gbp, 0) < 0
          and btrim(regexp_replace(lower(coalesce(sil.description, '')), '[^a-z0-9]+', ' ', 'g'))
              ~ '(^| )(discount|promotion|promotional|promo|voucher|coupon|saving|savings)( |$)'
          then 'discount'
        when coalesce(sil.amount_inc_vat_gbp, 0) > 0
          and btrim(regexp_replace(lower(coalesce(sil.description, '')), '[^a-z0-9]+', ' ', 'g'))
              ~ '(^| )(delivery|shipping|postage|freight|carriage)( |$)'
          then 'delivery'
        else null
      end as financial_kind,
      coalesce(sil.amount_inc_vat_gbp, 0) as extracted_amount
    from public.supplier_invoice_lines sil
    join public.supplier_invoices si on si.id = sil.supplier_invoice_id
    join participating_invoices pi on pi.supplier_invoice_id = sil.supplier_invoice_id
    where si.order_id = p_order_id
      and coalesce(si.review_status, '') not in ('rejected_resubmit_required', 'superseded', 'duplicate_blocked')
      and coalesce(lower(sil.eligible_for_invoice_yn), '') not in ('y', 'yes', 'true', '1')
      and lower(coalesce(sil.line_source, '')) = 'ocr_extracted'
      and not exists (
        select 1
        from public.supplier_invoice_line_resolutions r
        where r.supplier_invoice_line_id = sil.id
          and r.resolution_type = 'non_physical_financial'
          and r.active = true
      )
      and not exists (
        select 1
        from public.dispute_lines dl
        where dl.supplier_invoice_line_id = sil.id
          and dl.resolved_at is null
      )
  ), extracted as (
    select
      supplier_invoice_id,
      financial_kind,
      sum(extracted_amount) as extracted_amount
    from unresolved_financial_rows
    where financial_kind is not null
    group by supplier_invoice_id, financial_kind
  ), adjustment as (
    select
      ova.supplier_invoice_id,
      case
        when ova.adjustment_type = 'retailer_discount' then 'discount'
        when ova.adjustment_type = 'retailer_delivery' then 'delivery'
        else null
      end as financial_kind,
      sum(ova.amount_gbp) as adjustment_amount
    from public.order_value_adjustments ova
    join participating_invoices pi on pi.supplier_invoice_id = ova.supplier_invoice_id
    where ova.order_id = p_order_id
      and ova.adjustment_type in ('retailer_discount', 'retailer_delivery')
      and coalesce(ova.approval_status, '') <> 'rejected'
    group by ova.supplier_invoice_id,
      case
        when ova.adjustment_type = 'retailer_discount' then 'discount'
        when ova.adjustment_type = 'retailer_delivery' then 'delivery'
        else null
      end
  )
  select coalesce(sum(e.extracted_amount), 0)
    into v_unresolved_financial_offset
  from extracted e
  join adjustment a
    on a.supplier_invoice_id = e.supplier_invoice_id
   and a.financial_kind = e.financial_kind
  where e.extracted_amount <> 0
    and abs(abs(e.extracted_amount) - abs(a.adjustment_amount)) <= 0.01;

  if v_current_progressed_qty + v_selected_unprogressed_qty > coalesce(v_order.total_qty_declared, 0) then
    raise exception 'Cannot progress selected lines because they exceed the original order quantity baseline. Move excess or mismatched items into the exception path.';
  end if;

  if v_current_progressed_amount
       + v_current_resolved_financial_amount
       + v_selected_unprogressed_amount
       + v_unresolved_financial_offset
       > coalesce(v_order.order_total_gbp_declared, 0) + 0.01 then
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
$function$;

grant execute on function public.staff_progress_supplier_invoice_lines(uuid, uuid, uuid[], text) to authenticated;
