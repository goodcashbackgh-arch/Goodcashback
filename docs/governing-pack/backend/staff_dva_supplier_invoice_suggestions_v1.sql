-- staff_dva_supplier_invoice_suggestions_v1.sql
-- Status: EXECUTABLE SQL PATCH - RUN ONLY AFTER REVIEW/APPROVAL IN CURRENT CHAT.
-- Scope: generate supplier-invoice match suggestions for OUT DVA/card statement lines.
--
-- Creates:
--   public.staff_generate_supplier_invoice_match_suggestions(...)
--
-- Does not:
--   - allocate money;
--   - post to Sage;
--   - change funding reconciliation;
--   - alter existing tables;
--   - create direct browser write access.
--
-- Boundary:
--   staff_reconcile_dva_line_to_order(...) remains ORDER-FUNDING ONLY.
--   staff_allocate_statement_line_to_supplier_invoice(...) performs allocation after review.

begin;

set local lock_timeout = '15s';
set local statement_timeout = '0';

create or replace function public.staff_generate_supplier_invoice_match_suggestions(
  p_dva_statement_line_id uuid default null,
  p_tolerance_gbp numeric default 5.00,
  p_max_days integer default 14
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_auth_uid uuid := auth.uid();
  v_staff record;
  v_inserted_count integer := 0;
  v_tolerance numeric := round(coalesce(p_tolerance_gbp, 5.00)::numeric, 2);
  v_max_days integer := coalesce(p_max_days, 14);
begin
  if v_auth_uid is null then
    raise exception 'Unauthenticated user: supplier invoice suggestion generation requires auth.uid()';
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
    raise exception 'Only admin or supervisor staff can generate supplier invoice suggestions. Current role: %', v_staff.role_type;
  end if;

  if v_tolerance < 0 then
    raise exception 'Tolerance must be zero or greater. Received: %', v_tolerance;
  end if;

  if v_max_days < 0 then
    raise exception 'Max days must be zero or greater. Received: %', v_max_days;
  end if;

  with invoice_totals as (
    select
      si.id as supplier_invoice_id,
      si.order_id,
      coalesce(
        si.ocr_invoice_total_gbp,
        si.reconciliation_gbp_total,
        sum(coalesce(sil.amount_confirmed, sil.amount_inc_vat_gbp, 0))
      )::numeric as invoice_total_gbp
    from supplier_invoices si
    left join supplier_invoice_lines sil
      on sil.supplier_invoice_id = si.id
    group by
      si.id,
      si.order_id,
      si.ocr_invoice_total_gbp,
      si.reconciliation_gbp_total
  ),
  candidates as (
    select
      s.dva_statement_line_id,
      it.supplier_invoice_id,
      abs(round((s.statement_gbp_amount - it.invoice_total_gbp)::numeric, 2)) as variance_gbp,
      abs(s.statement_date - si.uploaded_at::date) as variance_days,
      case
        when abs(round((s.statement_gbp_amount - it.invoice_total_gbp)::numeric, 2)) <= 1.00
          and abs(s.statement_date - si.uploaded_at::date) <= 3 then 'high'
        when abs(round((s.statement_gbp_amount - it.invoice_total_gbp)::numeric, 2)) <= 5.00
          and abs(s.statement_date - si.uploaded_at::date) <= v_max_days then 'medium'
        else 'low'
      end as confidence
    from public.dva_statement_line_allocation_summary_vw s
    join dva_statement_lines dsl
      on dsl.id = s.dva_statement_line_id
    join invoice_totals it
      on it.invoice_total_gbp is not null
     and it.invoice_total_gbp > 0
    join supplier_invoices si
      on si.id = it.supplier_invoice_id
    join orders o
      on o.id = si.order_id
     and o.importer_id = s.importer_id
    left join retailers r
      on r.id = o.retailer_id
    where s.direction = 'out'
      and coalesce(s.confirmed_balanced_yn, false) = false
      and (p_dva_statement_line_id is null or s.dva_statement_line_id = p_dva_statement_line_id)
      and coalesce(si.blocked_from_sage_yn, false) = false
      and si.review_status in ('approved_current')
      and abs(round((s.statement_gbp_amount - it.invoice_total_gbp)::numeric, 2)) <= v_tolerance
      and abs(s.statement_date - si.uploaded_at::date) <= v_max_days
      and (
        regexp_replace(lower(coalesce(s.retailer_name_ref, '') || ' ' || coalesce(s.reference_raw, '') || ' ' || coalesce(s.auth_id_ref, '')), '[^a-z0-9]+', '', 'g') like
          '%' || left(regexp_replace(lower(coalesce(r.name, '')), '[^a-z0-9]+', '', 'g'), 5) || '%'
        or regexp_replace(lower(coalesce(r.name, '')), '[^a-z0-9]+', '', 'g') like
          '%' || left(regexp_replace(lower(coalesce(s.retailer_name_ref, '')), '[^a-z0-9]+', '', 'g'), 5) || '%'
      )
      and length(left(regexp_replace(lower(coalesce(r.name, '')), '[^a-z0-9]+', '', 'g'), 5)) >= 3
      and not exists (
        select 1
        from match_suggestions ms
        where ms.dva_statement_line_id = s.dva_statement_line_id
          and ms.suggested_match_type = 'supplier_invoice'
          and ms.suggested_match_id = it.supplier_invoice_id
      )
  ),
  ranked as (
    select
      c.*,
      row_number() over (
        partition by c.dva_statement_line_id
        order by c.variance_gbp asc, c.variance_days asc, c.confidence asc
      ) as rn
    from candidates c
  ),
  inserted as (
    insert into match_suggestions (
      dva_statement_line_id,
      suggested_match_type,
      suggested_match_id,
      confidence,
      variance_gbp,
      variance_days
    )
    select
      r.dva_statement_line_id,
      'supplier_invoice',
      r.supplier_invoice_id,
      r.confidence,
      r.variance_gbp,
      r.variance_days
    from ranked r
    where r.rn <= 3
    returning dva_statement_line_id
  )
  select count(*) into v_inserted_count
  from inserted;

  update dva_statement_lines dsl
     set match_status = 'suggested'
  where (p_dva_statement_line_id is null or dsl.id = p_dva_statement_line_id)
    and dsl.direction = 'out'
    and exists (
      select 1
      from match_suggestions ms
      where ms.dva_statement_line_id = dsl.id
        and ms.suggested_match_type = 'supplier_invoice'
    )
    and dsl.match_status <> 'confirmed';

  return jsonb_build_object(
    'ok', true,
    'inserted_count', v_inserted_count,
    'line_scope', p_dva_statement_line_id,
    'tolerance_gbp', v_tolerance,
    'max_days', v_max_days
  );
end;
$$;

comment on function public.staff_generate_supplier_invoice_match_suggestions(uuid, numeric, integer) is
'Staff/supervisor SECURITY DEFINER RPC to suggest supplier invoices for OUT DVA/card statement lines using importer, retailer text, amount tolerance and date tolerance. Does not allocate or post to Sage.';

revoke all on function public.staff_generate_supplier_invoice_match_suggestions(uuid, numeric, integer) from public;
grant execute on function public.staff_generate_supplier_invoice_match_suggestions(uuid, numeric, integer) to authenticated;

commit;

-- Smoke checks after execution:
-- select to_regprocedure('public.staff_generate_supplier_invoice_match_suggestions(uuid,numeric,integer)') as suggestion_rpc;
