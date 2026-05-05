-- dva_workspace_summary_status_v2.sql
-- Status: EXECUTABLE SQL PATCH - RUN IN SUPABASE SQL EDITOR.
--
-- Purpose:
--   Make the existing workspace read model `dva_statement_line_allocation_summary_vw`
--   derive its status/balance truth from `dva_statement_line_allocation_status_vw`.
--
-- Why:
--   /internal/dva-reconciliation/workspace currently reads
--   `dva_statement_line_allocation_summary_vw`. Replacing that view keeps the UI path
--   stable while making used/open/balanced/part-allocated status DB-backed.
--
-- Does not:
--   - change allocation tables;
--   - change funding reconciliation;
--   - post to Sage;
--   - create a duplicate workspace.

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
  coalesce(s.transaction_date, s.statement_date) as statement_date,
  coalesce(nullif(s.description, ''), nullif(s.reference, ''), nullif(ail.raw_text, ''), 'No statement text') as reference_raw,
  s.direction,
  s.amount_local_ccy,
  s.currency as local_ccy,
  ail.fx_rate_applied,
  ail.card_markup_pct_applied,
  s.statement_gbp_amount,
  coalesce(nullif(ail.auth_or_settlement_ref, ''), nullif(s.reference, '')) as auth_id_ref,
  coalesce(nullif(ail.merchant_normalised, ''), nullif(ail.merchant_raw, ''), nullif(s.description, ''), nullif(s.reference, '')) as retailer_name_ref,
  s.allocation_status_bucket as match_status,
  s.confirmed_allocated_gbp,
  s.confirmed_allocated_gbp as open_allocated_gbp,
  coalesce(t.supplier_invoice_allocated_gbp, 0::numeric) as supplier_invoice_allocated_gbp,
  coalesce(t.retailer_refund_allocated_gbp, 0::numeric) as retailer_refund_allocated_gbp,
  coalesce(t.fx_card_or_fee_allocated_gbp, 0::numeric) as fx_card_or_fee_allocated_gbp,
  coalesce(t.exception_or_hold_allocated_gbp, 0::numeric) as exception_or_hold_allocated_gbp,
  s.confirmed_allocation_count as active_allocation_count,
  s.confirmed_unallocated_gbp,
  (s.allocation_status_bucket = 'balanced') as confirmed_balanced_yn,
  s.allocation_status_bucket,
  s.selectable_for_new_allocation_yn,
  s.ready_for_supervisor_review_yn
from public.dva_statement_line_allocation_status_vw s
left join allocation_type_totals t
  on t.dva_statement_line_id = s.dva_statement_line_id
left join active_import_links ail
  on ail.dva_statement_line_id = s.dva_statement_line_id
where coalesce(ail.active_yn, true) = true
  and coalesce(ail.import_batch_status, 'committed') <> 'voided';

comment on view public.dva_statement_line_allocation_summary_vw is
'DB-backed compatibility read model for /internal/dva-reconciliation/workspace. Uses dva_statement_line_allocation_status_vw for statement-line status, used amount, open amount, and balanced/part/unmatched truth.';

grant select on public.dva_statement_line_allocation_summary_vw to authenticated;

commit;

-- Smoke check:
-- select * from public.dva_statement_line_allocation_summary_vw limit 5;
