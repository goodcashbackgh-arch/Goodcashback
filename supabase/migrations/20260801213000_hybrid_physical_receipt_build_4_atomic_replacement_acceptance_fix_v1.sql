-- Hybrid Physical Receipt Build 4 correctness fix:
-- atomic final replacement acceptance with physical exact-line authority
-- and preserved legacy multi-line compatibility.

begin;

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
  v_active_line_count integer;
  v_physical_line_count integer;
  v_non_manual_line_count integer;
  v_invalid_legacy_qty_count integer;
  v_first_line_id uuid;
  v_child_id uuid;
  v_legacy_qty integer;
  v_legacy_amount numeric;
begin
  if auth.uid() is null then
    raise exception 'Unauthenticated user';
  end if;

  if not exists (
    select 1
    from public.staff s
    where s.id = p_staff_id
      and s.auth_user_id = auth.uid()
      and coalesce(s.active, true) = true
  ) then
    raise exception 'Active staff authority not found';
  end if;

  select *
    into v_dispute
  from public.disputes
  where id = p_dispute_id
  for update;

  if not found then
    raise exception 'Dispute % not found', p_dispute_id;
  end if;

  if v_dispute.desired_outcome is distinct from 'replacement' then
    raise exception 'Dispute % is not a replacement dispute', p_dispute_id;
  end if;

  if v_dispute.replacement_child_order_id is not null then
    raise exception 'Replacement child order already exists for dispute %', p_dispute_id;
  end if;

  if v_dispute.status not in ('raised','under_review') then
    raise exception 'Replacement final acceptance requires dispute status raised or under_review. Current status: %', v_dispute.status;
  end if;

  if not exists (
    select 1
    from public.dispute_messages dm
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
    count(*) filter (
      where dl.qty_impact is null
         or abs(dl.qty_impact) <= 0
         or trunc(abs(dl.qty_impact)) <> abs(dl.qty_impact)
    ),
    (array_agg(dl.id order by dl.id))[1],
    coalesce(sum(abs(dl.qty_impact)), 0)::integer,
    coalesce(sum(abs(dl.amount_impact_gbp)), 0)::numeric
  into
    v_active_line_count,
    v_physical_line_count,
    v_non_manual_line_count,
    v_invalid_legacy_qty_count,
    v_first_line_id,
    v_legacy_qty,
    v_legacy_amount
  from public.dispute_lines dl
  join public.supplier_invoice_lines sil
    on sil.id = dl.supplier_invoice_line_id
  where dl.dispute_id = p_dispute_id
    and dl.resolved_at is null
    and dl.conversation_status = 'retailer_response_received';

  if v_active_line_count = 0 then
    raise exception 'No active retailer-accepted replacement dispute lines found';
  end if;

  if exists (
    select 1
    from public.dispute_lines dl
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

  if v_physical_line_count = 0 then
    if v_non_manual_line_count > 0 then
      raise exception 'Legacy replacement child creation requires manual missing-item lines';
    end if;

    if v_invalid_legacy_qty_count > 0 or v_legacy_qty <= 0 then
      raise exception 'Legacy replacement child creation requires positive whole-unit quantities';
    end if;

    if v_legacy_amount <= 0 then
      raise exception 'Legacy replacement child creation requires a positive value';
    end if;
  end if;

  if v_dispute.status = 'raised' then
    update public.disputes
    set status = 'under_review'
    where id = p_dispute_id;
  end if;

  update public.disputes
  set status = 'approved_replacement'
  where id = p_dispute_id;

  v_child_id := public.create_replacement_child_order(
    v_dispute.order_id,
    v_first_line_id,
    p_staff_id,
    p_notes
  );

  if v_physical_line_count = 0 and v_active_line_count > 1 then
    update public.orders
    set total_qty_declared = v_legacy_qty,
        order_total_gbp_declared = v_legacy_amount,
        updated_at = now()
    where id = v_child_id;

    update public.order_category_lines
    set qty = v_legacy_qty,
        amount_inc_vat_gbp = v_legacy_amount
    where order_id = v_child_id;

    update public.dispute_lines
    set resolved_via_child_order_id = v_child_id,
        conversation_status = 'resolved_replacement',
        resolution_method = 'replacement',
        resolved_at = coalesce(resolved_at, now())
    where dispute_id = p_dispute_id
      and resolved_at is null;
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
  'Atomic final replacement acceptance. Uses exact one-line physical remedy provenance when present and preserves legacy multi-line manual replacement aggregation.';

revoke all on function public.staff_accept_replacement_outcome_v1(uuid,uuid,text) from public;
revoke all on function public.staff_accept_replacement_outcome_v1(uuid,uuid,text) from anon;
grant execute on function public.staff_accept_replacement_outcome_v1(uuid,uuid,text) to authenticated;
grant execute on function public.staff_accept_replacement_outcome_v1(uuid,uuid,text) to service_role;

commit;
