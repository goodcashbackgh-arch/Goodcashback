-- dva_workspace_summary_status_v3.sql
-- Status: EXECUTABLE SQL PATCH - RUN IN SUPABASE SQL EDITOR.
--
-- Fixes v2 failure:
--   ERROR 42P16: cannot change data type of view column "reference_raw"
--
-- Cause:
--   CREATE OR REPLACE VIEW cannot change an existing view column type. The old
--   workspace summary view exposed some text-like columns as varchar. v2 returned
--   plain text expressions for reference_raw and related columns.
--
-- Purpose:
--   Keep the existing workspace view contract stable while deriving status/balance
--   truth from `dva_statement_line_allocation_status_vw`.
--
-- Does not:
--   - drop the existing view;
--   - change allocation tables;
--   - change funding reconciliation;
--   - create a duplicate workspace;
--   - post to Sage.

begin;

set local lock_timeout = '15s';
set local statement_timeout = '0';

create or replace view public.dva_statement_line_allocation_summary_vw as
with allocation_type_totals as (
  select
    a.dva_statement_line_id,
    round(coalesce(sum(a.allocated_gbp_amount) filter (where a.allocation_status = 'confirmed' and a.allocation_type = 'supplier_invoice'), 0)::numeric, 2) as supplier_invoice_allocated_gbp,
    round(coalesce(sum(a.allocated_gbp_amount) filter (where a.allocation_status = 'confirmed' and a.allocation_type = 'retailer_refund'), 0)::numeric, 2) as retailer_refund_allocated_gbp,
    round(coalesce(sum(a.allocated_gbp_amount) filter (where a.allocation_status = 'confirmed' and a.allocation_type in ('fx_card_difference', 'bank_fee')), 0)::numeric, 2) as fx_card_or_fee_allocated_gbp,
    round(coalesce(sum(a.allocated_gbp_amount) filter (where a.allocation_status = 'confirmed' and a.allocation_type in ('exception_hold', 'not_charged_closure', 'unmatched_hold')), 0)::numeric, 2) as exception_or_hold_allocated_gbp
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
    dir.card_last4,
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
  s.dva_statement_line_id,
  s.dva_statement_id,
  s.importer_id,
  coalesce(s.transaction_date, s.statement_date)::date as statement_date,
  coalesce(nullif(s.description, ''), nullif(s.reference, ''), nullif(ail.raw_text, ''), 'No statement text')::varchar as reference_raw,
  s.direction::varchar as direction,
  s.amount_local_ccy::numeric as amount_local_ccy,
  s.currency::varchar as local_ccy,
  ail.fx_rate_applied::numeric as fx_rate_applied,
  ail.card_markup_pct_applied::numeric as card_markup_pct_applied,
  s.statement_gbp_amount::numeric as statement_gbp_amount,
  coalesce(nullif(ail.auth_or_settlement_ref, ''), nullif(s.reference, ''))::varchar as auth_id_ref,
  coalesce(nullif(ail.merchant_normalised, ''), nullif(ail.merchant_raw, ''), nullif(s.description, ''), nullif(s.reference, ''))::varchar as retailer_name_ref,
  s.allocation_status_bucket::varchar as match_status,
  s.confirmed_allocated_gbp::numeric as confirmed_allocated_gbp,
  s.confirmed_allocated_gbp::numeric as open_allocated_gbp,
  coalesce(t.supplier_invoice_allocated_gbp, 0::numeric)::numeric as supplier_invoice_allocated_gbp,
  coalesce(t.retailer_refund_allocated_gbp, 0::numeric)::numeric as retailer_refund_allocated_gbp,
  coalesce(t.fx_card_or_fee_allocated_gbp, 0::numeric)::numeric as fx_card_or_fee_allocated_gbp,
  coalesce(t.exception_or_hold_allocated_gbp, 0::numeric)::numeric as exception_or_hold_allocated_gbp,
  s.confirmed_allocation_count::bigint as active_allocation_count,
  s.confirmed_unallocated_gbp::numeric as confirmed_unallocated_gbp,
  (s.allocation_status_bucket = 'balanced')::boolean as confirmed_balanced_yn,
  s.allocation_status_bucket::varchar as allocation_status_bucket,
  s.selectable_for_new_allocation_yn::boolean as selectable_for_new_allocation_yn,
  s.ready_for_supervisor_review_yn::boolean as ready_for_supervisor_review_yn
from public.dva_statement_line_allocation_status_vw s
left join allocation_type_totals t
  on t.dva_statement_line_id = s.dva_statement_line_id
left join active_import_links ail
  on ail.dva_statement_line_id = s.dva_statement_line_id
where coalesce(ail.active_yn, true) = true
  and coalesce(ail.import_batch_status, 'committed') <> 'voided';

comment on view public.dva_statement_line_allocation_summary_vw is
'DB-backed compatibility read model for /internal/dva-reconciliation/workspace. Uses dva_statement_line_allocation_status_vw for statement-line status, used amount, open amount, and balanced/part/unmatched truth while preserving existing view column types.';

grant select on public.dva_statement_line_allocation_summary_vw to authenticated;

commit;

-- Smoke check:
-- select * from public.dva_statement_line_allocation_summary_vw limit 5;
