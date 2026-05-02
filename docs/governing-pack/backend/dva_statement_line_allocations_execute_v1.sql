-- DVA/Card Statement Line Allocations Execute v1
-- Status: EXECUTABLE SQL PATCH - DO NOT RUN UNTIL USER APPROVES IN CURRENT CHAT.
-- Scope: additive only.
-- Creates:
--   1. public.dva_statement_line_allocations
--   2. indexes and duplicate guards
--   3. staff read-only RLS policy
--   4. public.dva_statement_line_allocation_summary_vw
--
-- Does not:
--   - alter existing tables;
--   - drop or weaken constraints;
--   - change existing DVA/funding RPCs;
--   - add write buttons;
--   - add write RPCs;
--   - post to Sage.
--
-- IMPORTANT BOUNDARY:
-- staff_reconcile_dva_line_to_order(...) remains ORDER-FUNDING ONLY.
-- This patch is for supplier purchase/refund/exception/FX allocation support.

begin;

create table if not exists public.dva_statement_line_allocations (
  id uuid primary key default gen_random_uuid(),
  dva_statement_line_id uuid not null references public.dva_statement_lines(id),

  allocation_type varchar not null check (allocation_type in (
    'supplier_invoice',
    'retailer_refund',
    'exception_hold',
    'not_charged_closure',
    'fx_card_difference',
    'bank_fee',
    'unmatched_hold'
  )),

  supplier_invoice_id uuid null references public.supplier_invoices(id),
  dispute_id uuid null references public.disputes(id),
  order_id uuid null references public.orders(id),

  allocated_gbp_amount numeric not null check (allocated_gbp_amount >= 0),
  allocation_status varchar not null default 'draft' check (allocation_status in (
    'draft',
    'confirmed',
    'reversed',
    'held'
  )),

  fx_rate_id uuid null references public.fx_rates(id),
  fx_rate_applied numeric null,
  card_markup_pct_applied numeric null,
  fx_or_card_diff_gbp numeric null,

  notes text null,
  created_by_staff_id uuid not null references public.staff(id),
  created_at timestamptz not null default now(),
  confirmed_by_staff_id uuid null references public.staff(id),
  confirmed_at timestamptz null,
  reversed_by_staff_id uuid null references public.staff(id),
  reversed_at timestamptz null,
  reversal_reason text null,

  constraint dva_statement_line_allocations_target_check check (
    (
      allocation_type = 'supplier_invoice'
      and supplier_invoice_id is not null
      and dispute_id is null
    )
    or (
      allocation_type in ('retailer_refund', 'exception_hold', 'not_charged_closure')
      and dispute_id is not null
    )
    or (
      allocation_type in ('fx_card_difference', 'bank_fee', 'unmatched_hold')
      and supplier_invoice_id is null
      and dispute_id is null
    )
  ),

  constraint dva_statement_line_allocations_confirmed_check check (
    (allocation_status <> 'confirmed')
    or (confirmed_by_staff_id is not null and confirmed_at is not null)
  ),

  constraint dva_statement_line_allocations_reversed_check check (
    (allocation_status <> 'reversed')
    or (reversed_by_staff_id is not null and reversed_at is not null and reversal_reason is not null)
  )
);

comment on table public.dva_statement_line_allocations is
'Allocation detail for one real DVA/card/bank statement line across supplier invoices, refund disputes, exception holds, FX/card differences, bank fees, or unmatched holds.';

comment on column public.dva_statement_line_allocations.dva_statement_line_id is
'References the real statement line. Do not duplicate statement lines to allocate one charge across multiple invoices.';

comment on column public.dva_statement_line_allocations.allocation_type is
'Classifies the allocation: supplier invoice, retailer refund, exception hold, not charged closure, FX/card difference, bank fee, or unmatched hold.';

comment on column public.dva_statement_line_allocations.allocated_gbp_amount is
'Positive GBP allocation amount. Direction is determined by the parent statement line and allocation type, not by storing negative values here.';

create index if not exists dva_statement_line_allocations_line_idx
  on public.dva_statement_line_allocations(dva_statement_line_id);

create index if not exists dva_statement_line_allocations_supplier_invoice_idx
  on public.dva_statement_line_allocations(supplier_invoice_id)
  where supplier_invoice_id is not null;

create index if not exists dva_statement_line_allocations_dispute_idx
  on public.dva_statement_line_allocations(dispute_id)
  where dispute_id is not null;

create index if not exists dva_statement_line_allocations_order_idx
  on public.dva_statement_line_allocations(order_id)
  where order_id is not null;

create index if not exists dva_statement_line_allocations_status_idx
  on public.dva_statement_line_allocations(allocation_status);

-- Duplicate guards for active allocations.
-- These do not enforce full balance; balance remains an RPC/view responsibility.
create unique index if not exists dva_statement_line_allocations_active_invoice_once
  on public.dva_statement_line_allocations(dva_statement_line_id, supplier_invoice_id)
  where allocation_type = 'supplier_invoice'
    and supplier_invoice_id is not null
    and allocation_status <> 'reversed';

create unique index if not exists dva_statement_line_allocations_active_dispute_once
  on public.dva_statement_line_allocations(dva_statement_line_id, dispute_id, allocation_type)
  where dispute_id is not null
    and allocation_status <> 'reversed';

alter table public.dva_statement_line_allocations enable row level security;

-- Staff can inspect allocations. Direct writes remain blocked because no INSERT/UPDATE/DELETE policies are created.
do $$
begin
  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'dva_statement_line_allocations'
      and policyname = 'staff_select_dva_statement_line_allocations'
  ) then
    create policy staff_select_dva_statement_line_allocations
      on public.dva_statement_line_allocations
      for select
      to authenticated
      using (is_active_staff());
  end if;
end $$;

create or replace view public.dva_statement_line_allocation_summary_vw as
select
  l.id as dva_statement_line_id,
  l.dva_statement_id,
  s.importer_id,
  l.statement_date,
  l.reference_raw,
  l.direction,
  l.amount_local_ccy,
  l.local_ccy,
  l.fx_rate_applied,
  l.card_markup_pct_applied,
  l.amount_gbp_equivalent as statement_gbp_amount,
  l.auth_id_ref,
  l.retailer_name_ref,
  l.match_status,
  coalesce(sum(a.allocated_gbp_amount) filter (
    where a.allocation_status = 'confirmed'
  ), 0) as confirmed_allocated_gbp,
  coalesce(sum(a.allocated_gbp_amount) filter (
    where a.allocation_status in ('draft', 'held')
  ), 0) as open_allocated_gbp,
  coalesce(sum(a.allocated_gbp_amount) filter (
    where a.allocation_status = 'confirmed'
      and a.allocation_type = 'supplier_invoice'
  ), 0) as supplier_invoice_allocated_gbp,
  coalesce(sum(a.allocated_gbp_amount) filter (
    where a.allocation_status = 'confirmed'
      and a.allocation_type = 'retailer_refund'
  ), 0) as retailer_refund_allocated_gbp,
  coalesce(sum(a.allocated_gbp_amount) filter (
    where a.allocation_status = 'confirmed'
      and a.allocation_type in ('fx_card_difference', 'bank_fee')
  ), 0) as fx_card_or_fee_allocated_gbp,
  coalesce(sum(a.allocated_gbp_amount) filter (
    where a.allocation_status = 'confirmed'
      and a.allocation_type in ('exception_hold', 'not_charged_closure', 'unmatched_hold')
  ), 0) as exception_or_hold_allocated_gbp,
  count(a.id) filter (where a.allocation_status <> 'reversed') as active_allocation_count,
  (
    l.amount_gbp_equivalent
    - coalesce(sum(a.allocated_gbp_amount) filter (where a.allocation_status = 'confirmed'), 0)
  ) as confirmed_unallocated_gbp,
  (
    abs(
      l.amount_gbp_equivalent
      - coalesce(sum(a.allocated_gbp_amount) filter (where a.allocation_status = 'confirmed'), 0)
    ) < 0.01
  ) as confirmed_balanced_yn
from public.dva_statement_lines l
join public.dva_statements s
  on s.id = l.dva_statement_id
left join public.dva_statement_line_allocations a
  on a.dva_statement_line_id = l.id
group by
  l.id,
  l.dva_statement_id,
  s.importer_id,
  l.statement_date,
  l.reference_raw,
  l.direction,
  l.amount_local_ccy,
  l.local_ccy,
  l.fx_rate_applied,
  l.card_markup_pct_applied,
  l.amount_gbp_equivalent,
  l.auth_id_ref,
  l.retailer_name_ref,
  l.match_status;

comment on view public.dva_statement_line_allocation_summary_vw is
'Read model showing allocation totals and remaining balance for each DVA/card statement line. Use for staff control visibility before Sage payload preparation.';

commit;

-- Post-run smoke checks:
-- select to_regclass('public.dva_statement_line_allocations') as allocation_table;
-- select to_regclass('public.dva_statement_line_allocation_summary_vw') as allocation_summary_view;
-- select * from public.dva_statement_line_allocation_summary_vw limit 5;
