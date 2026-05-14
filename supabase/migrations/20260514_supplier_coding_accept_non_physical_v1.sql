-- Allow supplier invoice accounting coding for both progressed product lines
-- and active parked non-physical financial invoice lines.
--
-- This preserves the physical/logistics rule:
--   eligible_for_invoice_yn = Y -> physical/product codable line
--   active non_physical_financial resolution -> accounting codable only, not shipper/tracking
--   N with no resolution -> blocked/unresolved

begin;

set local lock_timeout = '15s';
set local statement_timeout = '0';

create or replace function public.staff_bulk_save_supplier_invoice_line_accounting_codes_v2(
  p_supplier_invoice_id uuid,
  p_lines jsonb
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_staff_id uuid;
  v_submitted_count integer := coalesce(jsonb_array_length(p_lines), 0);
  v_expected_count integer;
  v_bad_count integer;
  v_line jsonb;
  v_line_id uuid;
  v_net numeric;
  v_vat numeric;
  v_gross numeric;
begin
  select s.id
    into v_staff_id
  from staff s
  where s.auth_user_id = auth.uid()
    and coalesce(s.active, true) = true
    and s.role_type in ('admin','supervisor')
  limit 1;

  if v_staff_id is null then
    raise exception 'Only supervisor/admin staff can save supplier invoice accounting codes';
  end if;

  if p_supplier_invoice_id is null then
    raise exception 'Supplier invoice id is required';
  end if;

  if v_submitted_count = 0 then
    raise exception 'No accounting coding lines submitted';
  end if;

  -- Expected codable lines are:
  -- 1) progressed physical/product lines; plus
  -- 2) active parked non-physical financial lines for the same invoice.
  select count(*)
    into v_expected_count
  from supplier_invoice_lines sil
  where sil.supplier_invoice_id = p_supplier_invoice_id
    and (
      sil.eligible_for_invoice_yn = 'Y'
      or exists (
        select 1
        from supplier_invoice_line_resolutions r
        where r.supplier_invoice_line_id = sil.id
          and r.supplier_invoice_id = p_supplier_invoice_id
          and r.resolution_type = 'non_physical_financial'
          and r.active = true
      )
    );

  if v_submitted_count <> v_expected_count then
    raise exception 'All codable supplier invoice lines must be submitted. Expected %, submitted %.', v_expected_count, v_submitted_count;
  end if;

  with submitted as (
    select (x.value->>'supplier_invoice_line_id')::uuid as supplier_invoice_line_id
    from jsonb_array_elements(p_lines) x(value)
  )
  select count(*)
    into v_bad_count
  from submitted s
  left join supplier_invoice_lines sil
    on sil.id = s.supplier_invoice_line_id
   and sil.supplier_invoice_id = p_supplier_invoice_id
  where sil.id is null
     or not (
       sil.eligible_for_invoice_yn = 'Y'
       or exists (
         select 1
         from supplier_invoice_line_resolutions r
         where r.supplier_invoice_line_id = sil.id
           and r.supplier_invoice_id = p_supplier_invoice_id
           and r.resolution_type = 'non_physical_financial'
           and r.active = true
       )
     );

  if v_bad_count > 0 then
    raise exception 'Submitted lines include non-codable, unresolved, or wrong-invoice line(s).';
  end if;

  for v_line in select value from jsonb_array_elements(p_lines)
  loop
    v_line_id := (v_line->>'supplier_invoice_line_id')::uuid;
    v_net := coalesce(nullif(v_line->>'net_amount_gbp','')::numeric, 0);
    v_vat := coalesce(nullif(v_line->>'vat_amount_gbp','')::numeric, 0);
    v_gross := round((v_net + v_vat)::numeric, 2);

    if abs((v_net + v_vat) - v_gross) > 0.01 then
      raise exception 'Line % net/VAT/gross does not reconcile', v_line_id;
    end if;

    insert into supplier_invoice_line_accounting_codes (
      supplier_invoice_line_id,
      description_override,
      sku_override,
      size_override,
      sage_ledger_account_id,
      nominal_code,
      tax_rate_id,
      tax_rate_label,
      vat_rate_percent,
      net_amount_gbp,
      vat_amount_gbp,
      gross_amount_gbp,
      coded_by_staff_id,
      coded_at,
      admin_review_required_yn,
      review_reason,
      updated_at
    )
    values (
      v_line_id,
      nullif(v_line->>'description_override',''),
      nullif(v_line->>'sku_override',''),
      nullif(v_line->>'size_override',''),
      nullif(v_line->>'sage_ledger_account_id',''),
      nullif(v_line->>'nominal_code',''),
      nullif(v_line->>'tax_rate_id',''),
      nullif(v_line->>'tax_rate_label',''),
      coalesce(nullif(v_line->>'vat_rate_percent','')::numeric, 20),
      v_net,
      v_vat,
      v_gross,
      v_staff_id,
      now(),
      coalesce((v_line->>'admin_review_required_yn')::boolean, false),
      nullif(v_line->>'review_reason',''),
      now()
    )
    on conflict (supplier_invoice_line_id) do update set
      description_override = excluded.description_override,
      sku_override = excluded.sku_override,
      size_override = excluded.size_override,
      sage_ledger_account_id = excluded.sage_ledger_account_id,
      nominal_code = excluded.nominal_code,
      tax_rate_id = excluded.tax_rate_id,
      tax_rate_label = excluded.tax_rate_label,
      vat_rate_percent = excluded.vat_rate_percent,
      net_amount_gbp = excluded.net_amount_gbp,
      vat_amount_gbp = excluded.vat_amount_gbp,
      gross_amount_gbp = excluded.gross_amount_gbp,
      coded_by_staff_id = excluded.coded_by_staff_id,
      coded_at = excluded.coded_at,
      admin_review_required_yn = excluded.admin_review_required_yn,
      review_reason = excluded.review_reason,
      updated_at = now();
  end loop;

  return v_submitted_count;
end;
$$;

comment on function public.staff_bulk_save_supplier_invoice_line_accounting_codes_v2(uuid, jsonb)
is 'Bulk-save supplier invoice line accounting codes for progressed physical lines and active parked non-physical financial lines. Does not make non-physical lines shipper/trackable.';

commit;
