-- Add the same commercial review fields used by supplier invoice lines
-- to refund document lines so the operator refund-document review page can
-- mirror the invoice reconciliation page.

begin;

alter table if exists public.dispute_refund_document_lines
  add column if not exists retailer_sku text null,
  add column if not exists size text null;

-- Some earlier builds used manually_added for operator-created correction rows.
-- Make the check constraint tolerate that value without changing existing rows.
do $$
begin
  if exists (
    select 1
    from pg_constraint
    where conname = 'dispute_refund_document_lines_source_check'
      and conrelid = 'public.dispute_refund_document_lines'::regclass
  ) then
    alter table public.dispute_refund_document_lines
      drop constraint dispute_refund_document_lines_source_check;
  end if;
end $$;

alter table public.dispute_refund_document_lines
  add constraint dispute_refund_document_lines_source_check
  check (line_source in (
    'operator_prefill',
    'ocr_extracted',
    'manual_staff',
    'manually_added',
    'delivery_adjustment',
    'discount_adjustment',
    'rounding_adjustment'
  ));

commit;
