-- dva_workspace_summary_status_v5.sql
-- Status: EXECUTABLE SQL PATCH - RUN IN SUPABASE SQL EDITOR.
--
-- Purpose:
--   Preserve the exact live column signature of
--   public.dva_statement_line_allocation_summary_vw while fixing the human
--   statement text priority used by the DVA/card matching workspace.
--
-- Problem fixed:
--   v4 exposed retailer_name_ref from merchant_normalised before merchant_raw.
--   merchant_normalised is a machine/search value such as
--   corporatecardissuancefeeqzjaiwuq. The workspace displays retailer_name_ref,
--   so staff saw compressed text even though Mindee/staged/committed rows held
--   readable statement text.
--
-- Rule:
--   Human display fields must prefer readable text first. Normalised machine
--   values are a last-resort fallback only.
--
-- Existing live signature preserved:
--   1  dva_statement_line_id uuid
--   2  dva_statement_id uuid
--   3  importer_id uuid
--   4  statement_date date
--   5  reference_raw varchar
--   6  direction varchar
--   7  amount_local_ccy numeric(18,2)
--   8  local_ccy varchar(3)
--   9  fx_rate_applied numeric(18,8)
--   10 card_markup_pct_applied numeric(6,3)
--   11 statement_gbp_amount numeric(12,2)
--   12 auth_id_ref varchar
--   13 retailer_name_ref varchar
--   14 match_status varchar
--   15 confirmed_allocated_gbp numeric
--   16 open_allocated_gbp numeric
--   17 supplier_invoice_allocated_gbp numeric
--   18 retailer_refund_allocated_gbp numeric
--   19 fx_card_or_fee_allocated_gbp numeric
--   20 exception_or_hold_allocated_gbp numeric
--   21 active_allocation_count bigint
--   22 confirmed_unallocated_gbp numeric
--   23 confirmed_balanced_yn boolean

begin;

set local lock_timeout = '15s';
set local statement_timeout = '0';

create or replace view public.dva_statement_line_allocation_summary_vw as
with allocation_type_totals as (
  select
    a.dva_statement_line_id,
    coalesce(sum(a.allocated_gbp_amount) filter (where a.allocation_status = 'confirmed' and a.allocation_type = 'supplier_invoice'), 0::numeric) as supplier_invoice_allocated_gbp,
    coalesce(sum(a.allocated_gbp_amount) filter (where a.allocation_status = 'confirmed' and a.allocation_type = 'retailer_refund'), 0::numeric) as retailer_refund_allocated_gbp,
    coalesce(sum(a.allocated_gbp_amount) filter (where a.allocation_status = 'confirmed' and a.allocation_type in ('fx_card_difference', 'bank_fee')), 0::numeric) as fx_card_or_fee_allocated_gbp,
    coalesce(sum(a.allocated_gbp_amount) filter (where a.allocation_status = 'confirmed' and a.allocation_type in ('exception_hold', 'not_charged_closure', 'unmatched_hold')), 0::numeric) as exception_or_hold_allocated_gbp
  from public.dva_statement_line_allocations a
  group by a.dva_statement_line_id
),
active_import_links as (
  select
    dlil.dva_statement_line_id,
    dlil.active_yn,
    dib.status as import_batch_status,
    dir.merchant_raw,
    dir.merchant_normalised,
    dir.bank_reference,
    dir.auth_or_settlement_ref,
    dir.fx_rate_applied,
    dir.card_markup_pct_applied,
    dir.raw_text
  from public.dva_statement_line_import_links dlil
  join public.dva_statement_import_batches dib
    on dib.id = dlil.import_batch_id
  left join public.dva_statement_import_rows dir
    on dir.id = dlil.import_row_id
)
select
  s.dva_statement_line_id::uuid as dva_statement_line_id,
  s.dva_statement_id::uuid as dva_statement_id,
  s.importer_id::uuid as importer_id,
  coalesce(s.transaction_date, s.statement_date)::date as statement_date,
  coalesce(nullif(s.description, ''), nullif(s.reference, ''), nullif(ail.raw_text, ''), 'No statement text')::varchar as reference_raw,
  s.direction::varchar as direction,
  s.amount_local_ccy::numeric(18,2) as amount_local_ccy,
  s.currency::varchar(3) as local_ccy,
  ail.fx_rate_applied::numeric(18,8) as fx_rate_applied,
  ail.card_markup_pct_applied::numeric(6,3) as card_markup_pct_applied,
  s.statement_gbp_amount::numeric(12,2) as statement_gbp_amount,
  coalesce(nullif(ail.auth_or_settlement_ref, ''), nullif(s.reference, ''))::varchar as auth_id_ref,
  coalesce(nullif(ail.merchant_raw, ''), nullif(s.description, ''), nullif(ail.raw_text, ''), nullif(s.reference, ''), nullif(ail.merchant_normalised, ''))::varchar as retailer_name_ref,
  s.allocation_status_bucket::varchar as match_status,
  s.confirmed_allocated_gbp::numeric as confirmed_allocated_gbp,
  s.confirmed_allocated_gbp::numeric as open_allocated_gbp,
  coalesce(t.supplier_invoice_allocated_gbp, 0::numeric)::numeric as supplier_invoice_allocated_gbp,
  coalesce(t.retailer_refund_allocated_gbp, 0::numeric)::numeric as retailer_refund_allocated_gbp,
  coalesce(t.fx_card_or_fee_allocated_gbp, 0::numeric)::numeric as fx_card_or_fee_allocated_gbp,
  coalesce(t.exception_or_hold_allocated_gbp, 0::numeric)::numeric as exception_or_hold_allocated_gbp,
  s.confirmed_allocation_count::bigint as active_allocation_count,
  s.confirmed_unallocated_gbp::numeric as confirmed_unallocated_gbp,
  (s.allocation_status_bucket = 'balanced')::boolean as confirmed_balanced_yn
from public.dva_statement_line_allocation_status_vw s
left join allocation_type_totals t
  on t.dva_statement_line_id = s.dva_statement_line_id
left join active_import_links ail
  on ail.dva_statement_line_id = s.dva_statement_line_id
where coalesce(ail.active_yn, true) = true
  and coalesce(ail.import_batch_status, 'committed') <> 'voided';

comment on view public.dva_statement_line_allocation_summary_vw is
'DB-backed compatibility read model for /internal/dva-reconciliation/workspace. Exact existing column signature preserved. Uses readable statement text before merchant_normalised for human display while retaining allocation status, used amount, open amount, and balanced/part/unmatched truth.';

grant select on public.dva_statement_line_allocation_summary_vw to authenticated;

commit;

-- Smoke check:
-- select
--   dva_statement_line_id,
--   reference_raw,
--   retailer_name_ref,
--   auth_id_ref
-- from public.dva_statement_line_allocation_summary_vw
-- where dva_statement_line_id in (
--   '16280b94-6c87-4f3c-a47a-d6fffc5d3ea1',
--   'fc6e53f0-236d-470c-b3d5-6058ef82cb2b',
--   '4e62ae2b-9a09-4e3e-be2f-4d9d962a68b0',
--   '2c7b650c-eb2a-4c68-8504-e6ea5800c6df'
-- );
