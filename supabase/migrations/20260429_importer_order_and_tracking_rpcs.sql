-- importer transactional RPCs
create or replace function public.importer_create_order_with_lines(
  p_operator_id uuid,
  p_importer_id uuid,
  p_shipper_id uuid,
  p_retailer_id uuid,
  p_destination_hub_id uuid,
  p_sop_version text,
  p_order_type text,
  p_order_ref text,
  p_payment_auth_id text,
  p_screenshot_url text,
  p_lines jsonb
) returns uuid
language plpgsql
security definer
as $$
declare
  v_order_id uuid;
  v_total_qty int := 0;
  v_total_amount numeric := 0;
begin
  select coalesce(sum((line->>'qty')::int),0), coalesce(sum((line->>'amount_inc_vat_gbp')::numeric),0)
    into v_total_qty, v_total_amount
  from jsonb_array_elements(p_lines) as line;

  insert into public.orders (
    order_ref, payment_auth_id, importer_id, operator_id, shipper_id, retailer_id, destination_hub_id,
    order_type, status, sop_version, total_qty_declared, order_total_gbp_declared
  ) values (
    p_order_ref, p_payment_auth_id, p_importer_id, p_operator_id, p_shipper_id, p_retailer_id, p_destination_hub_id,
    p_order_type, 'pending_dva_funding', p_sop_version, v_total_qty, round(v_total_amount, 2)
  ) returning id into v_order_id;

  insert into public.order_category_lines (
    order_id, markup_category_id, qty, amount_inc_vat_gbp, markup_pct_applied, markup_gbp_calculated
  )
  select v_order_id,
         (line->>'markup_category_id')::uuid,
         (line->>'qty')::int,
         round((line->>'amount_inc_vat_gbp')::numeric,2),
         0,
         0
  from jsonb_array_elements(p_lines) as line;

  if p_screenshot_url is not null and length(trim(p_screenshot_url)) > 0 then
    insert into public.order_screenshots (order_id, screenshot_url, uploaded_by_operator_id, display_order, note)
    values (v_order_id, trim(p_screenshot_url), p_operator_id, 1, 'Original order screenshot');
  end if;

  return v_order_id;
end;
$$;

create or replace function public.importer_add_order_tracking_submission(
  p_order_id uuid,
  p_operator_id uuid,
  p_courier_id uuid,
  p_tracking_ref text,
  p_tracking_date date,
  p_tracking_screenshot_url text,
  p_note text,
  p_is_final_delivery_yn boolean default false
) returns uuid
language plpgsql
security definer
as $$
declare
  v_tracking_id uuid;
begin
  insert into public.order_tracking_submissions (
    order_id, courier_id, tracking_ref, tracking_date, tracking_screenshot_url, note, submitted_by_operator_id, is_final_delivery_yn
  ) values (
    p_order_id, p_courier_id, trim(p_tracking_ref), p_tracking_date, nullif(trim(coalesce(p_tracking_screenshot_url,'')),''), nullif(trim(coalesce(p_note,'')),''), p_operator_id, coalesce(p_is_final_delivery_yn, false)
  ) returning id into v_tracking_id;

  if coalesce(p_is_final_delivery_yn, false) then
    update public.orders
      set tracking_locked_at = coalesce(tracking_locked_at, now())
    where id = p_order_id;
  end if;

  return v_tracking_id;
end;
$$;
