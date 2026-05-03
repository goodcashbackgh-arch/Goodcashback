-- dva_card_statement_import_workbench_v1.sql
-- Status: EXECUTABLE SQL PATCH - RUN ONLY AFTER REVIEW/APPROVAL IN CURRENT CHAT.
-- Scope: additive backend for PDF-first / format-detecting DVA/card statement import.
--
-- Creates:
--   1. public.dva_statement_import_batches
--   2. public.dva_statement_import_rows
--   3. public.dva_statement_line_import_links
--   4. staff RPCs for create batch, stage row, commit clean rows, void batch
--
-- Does not:
--   - alter existing core tables;
--   - widen existing check constraints;
--   - change funding reconciliation;
--   - change supplier invoice allocation;
--   - post to Sage;
--   - create browser direct write policies.
--
-- Boundary:
--   Import/staging happens before active DVA/card statement lines are created.
--   Active allocation still happens through the DVA/card reconciliation workbench.

begin;

set local lock_timeout = '15s';
set local statement_timeout = '0';

create table if not exists public.dva_statement_import_batches (
  id uuid primary key default gen_random_uuid(),
  importer_id uuid not null references public.importers(id),
  source_bank varchar not null check (source_bank in ('gcb', 'firstbank', 'zenith', 'other')),
  statement_period_from date not null,
  statement_period_to date not null,
  local_ccy varchar not null,
  source_file_url varchar not null,
  original_filename varchar null,
  detected_file_type varchar not null check (detected_file_type in ('pdf', 'csv', 'xlsx', 'text', 'unknown')),
  parser_route varchar not null default 'pending' check (parser_route in ('pending', 'pdf_ocr', 'csv_direct', 'xlsx_direct', 'text_direct', 'manual_review')),
  default_card_markup_pct numeric not null default 0,
  fx_source_context text null,
  status varchar not null default 'uploaded' check (status in (
    'uploaded',
    'detecting_format',
    'ocr_or_parsing',
    'parsed_clean',
    'parsed_with_errors',
    'committed',
    'void_requested',
    'voided',
    'failed'
  )),
  row_count integer not null default 0 check (row_count >= 0),
  clean_count integer not null default 0 check (clean_count >= 0),
  error_count integer not null default 0 check (error_count >= 0),
  duplicate_count integer not null default 0 check (duplicate_count >= 0),
  committed_count integer not null default 0 check (committed_count >= 0),
  uploaded_by_staff_id uuid not null references public.staff(id),
  uploaded_at timestamptz not null default now(),
  parsed_at timestamptz null,
  committed_by_staff_id uuid null references public.staff(id),
  committed_at timestamptz null,
  voided_by_staff_id uuid null references public.staff(id),
  voided_at timestamptz null,
  void_reason text null,
  parse_errors_json jsonb null,
  notes text null,

  constraint dva_statement_import_batches_period_check check (statement_period_to >= statement_period_from),
  constraint dva_statement_import_batches_committed_check check (
    (status <> 'committed') or (committed_by_staff_id is not null and committed_at is not null)
  ),
  constraint dva_statement_import_batches_voided_check check (
    (status <> 'voided') or (voided_by_staff_id is not null and voided_at is not null and void_reason is not null)
  )
);

comment on table public.dva_statement_import_batches is
'Upload/import batch header for PDF-first but format-detecting DVA/card/bank statement ingestion. Keeps upload history, parse lifecycle, row counts, commit and void audit.';

create table if not exists public.dva_statement_import_rows (
  id uuid primary key default gen_random_uuid(),
  import_batch_id uuid not null references public.dva_statement_import_batches(id),
  source_row_number integer not null check (source_row_number > 0),
  source_page_number integer null check (source_page_number is null or source_page_number > 0),
  raw_text text not null,
  raw_json jsonb null,

  statement_date date null,
  transaction_date date null,
  direction varchar null check (direction is null or direction in ('in', 'out')),
  transaction_type_candidate varchar not null default 'unmatched_candidate' check (transaction_type_candidate in (
    'supplier_purchase_candidate',
    'retailer_refund_candidate',
    'inbound_funding_candidate',
    'bank_fee_candidate',
    'transfer_candidate',
    'unmatched_candidate'
  )),

  amount_local_ccy numeric null,
  balance_after_local_ccy numeric null,
  local_ccy varchar null,
  fx_rate_applied numeric null,
  card_markup_pct_applied numeric null,
  amount_gbp_equivalent numeric null,

  card_last4 varchar null,
  merchant_raw varchar null,
  merchant_normalised varchar null,
  bank_reference varchar null,
  auth_or_settlement_ref varchar null,
  transaction_family_ref varchar null,

  parser_confidence varchar not null default 'low' check (parser_confidence in ('high', 'medium', 'low')),
  parse_status varchar not null default 'staged' check (parse_status in (
    'staged',
    'clean',
    'error',
    'duplicate_skipped',
    'committed',
    'voided'
  )),
  error_code varchar null,
  error_message text null,

  statement_line_fingerprint_hash varchar not null,
  duplicate_of_statement_line_id uuid null references public.dva_statement_lines(id),
  duplicate_of_import_row_id uuid null references public.dva_statement_import_rows(id),
  committed_dva_statement_line_id uuid null references public.dva_statement_lines(id),
  committed_at timestamptz null,
  created_at timestamptz not null default now(),

  constraint dva_statement_import_rows_unique_source_row unique(import_batch_id, source_row_number),
  constraint dva_statement_import_rows_committed_check check (
    (parse_status <> 'committed') or (committed_dva_statement_line_id is not null and committed_at is not null)
  )
);

comment on table public.dva_statement_import_rows is
'Staged parsed/OCR rows for DVA/card statement imports. Preserves raw text/JSON, parse errors, duplicate fingerprint, and commit linkage before active statement lines are created.';

create table if not exists public.dva_statement_line_import_links (
  id uuid primary key default gen_random_uuid(),
  importer_id uuid not null references public.importers(id),
  source_bank varchar not null,
  import_batch_id uuid not null references public.dva_statement_import_batches(id),
  import_row_id uuid not null references public.dva_statement_import_rows(id),
  dva_statement_id uuid not null references public.dva_statements(id),
  dva_statement_line_id uuid not null references public.dva_statement_lines(id),
  statement_line_fingerprint_hash varchar not null,
  active_yn boolean not null default true,
  linked_at timestamptz not null default now(),

  constraint dva_statement_line_import_links_unique_line unique(dva_statement_line_id),
  constraint dva_statement_line_import_links_unique_fingerprint unique(importer_id, source_bank, statement_line_fingerprint_hash)
);

comment on table public.dva_statement_line_import_links is
'Immutable-ish linkage between import batch/row and committed active DVA/card statement lines. Enforces cross-upload duplicate fingerprint protection.';

create index if not exists dva_statement_import_batches_importer_idx
  on public.dva_statement_import_batches(importer_id, uploaded_at desc);

create index if not exists dva_statement_import_batches_status_idx
  on public.dva_statement_import_batches(status);

create index if not exists dva_statement_import_rows_batch_idx
  on public.dva_statement_import_rows(import_batch_id, source_row_number);

create index if not exists dva_statement_import_rows_status_idx
  on public.dva_statement_import_rows(parse_status);

create index if not exists dva_statement_import_rows_fingerprint_idx
  on public.dva_statement_import_rows(statement_line_fingerprint_hash);

alter table public.dva_statement_import_batches enable row level security;
alter table public.dva_statement_import_rows enable row level security;
alter table public.dva_statement_line_import_links enable row level security;

-- Staff can inspect import history and staged rows. Direct writes remain blocked; write actions use SECURITY DEFINER RPCs.
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'dva_statement_import_batches'
      and policyname = 'staff_select_dva_statement_import_batches'
  ) then
    create policy staff_select_dva_statement_import_batches
      on public.dva_statement_import_batches
      for select
      to authenticated
      using (is_active_staff());
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'dva_statement_import_rows'
      and policyname = 'staff_select_dva_statement_import_rows'
  ) then
    create policy staff_select_dva_statement_import_rows
      on public.dva_statement_import_rows
      for select
      to authenticated
      using (is_active_staff());
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'dva_statement_line_import_links'
      and policyname = 'staff_select_dva_statement_line_import_links'
  ) then
    create policy staff_select_dva_statement_line_import_links
      on public.dva_statement_line_import_links
      for select
      to authenticated
      using (is_active_staff());
  end if;
end $$;

create or replace function public.current_active_staff_record_()
returns table(id uuid, role_type varchar)
language sql
security definer
set search_path = public, pg_temp
as $$
  select s.id, s.role_type
  from staff s
  where s.auth_user_id = auth.uid()
    and coalesce(s.active, true) = true
  limit 1;
$$;

create or replace function public.staff_create_dva_statement_import_batch(
  p_importer_id uuid,
  p_source_bank varchar,
  p_statement_period_from date,
  p_statement_period_to date,
  p_local_ccy varchar,
  p_source_file_url varchar,
  p_original_filename varchar default null,
  p_detected_file_type varchar default 'unknown',
  p_default_card_markup_pct numeric default 0,
  p_fx_source_context text default null,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_staff record;
  v_parser_route varchar;
  v_batch_id uuid;
begin
  select * into v_staff from public.current_active_staff_record_();

  if v_staff.id is null then
    raise exception 'Active staff user not found for current auth user';
  end if;

  if v_staff.role_type not in ('admin', 'supervisor') then
    raise exception 'Only admin or supervisor staff can create statement import batches. Current role: %', v_staff.role_type;
  end if;

  if p_detected_file_type not in ('pdf', 'csv', 'xlsx', 'text', 'unknown') then
    raise exception 'Unsupported detected file type: %', p_detected_file_type;
  end if;

  v_parser_route := case p_detected_file_type
    when 'pdf' then 'pdf_ocr'
    when 'csv' then 'csv_direct'
    when 'xlsx' then 'xlsx_direct'
    when 'text' then 'text_direct'
    else 'manual_review'
  end;

  insert into public.dva_statement_import_batches (
    importer_id,
    source_bank,
    statement_period_from,
    statement_period_to,
    local_ccy,
    source_file_url,
    original_filename,
    detected_file_type,
    parser_route,
    default_card_markup_pct,
    fx_source_context,
    status,
    uploaded_by_staff_id,
    notes
  ) values (
    p_importer_id,
    p_source_bank,
    p_statement_period_from,
    p_statement_period_to,
    upper(trim(p_local_ccy)),
    p_source_file_url,
    p_original_filename,
    p_detected_file_type,
    v_parser_route,
    round(coalesce(p_default_card_markup_pct, 0)::numeric, 3),
    p_fx_source_context,
    'uploaded',
    v_staff.id,
    p_notes
  ) returning id into v_batch_id;

  return jsonb_build_object(
    'ok', true,
    'import_batch_id', v_batch_id,
    'detected_file_type', p_detected_file_type,
    'parser_route', v_parser_route
  );
end;
$$;

create or replace function public.staff_stage_dva_statement_import_row(
  p_import_batch_id uuid,
  p_source_row_number integer,
  p_source_page_number integer,
  p_raw_text text,
  p_raw_json jsonb,
  p_statement_date date,
  p_transaction_date date,
  p_direction varchar,
  p_transaction_type_candidate varchar,
  p_amount_local_ccy numeric,
  p_balance_after_local_ccy numeric,
  p_local_ccy varchar,
  p_fx_rate_applied numeric,
  p_card_markup_pct_applied numeric,
  p_amount_gbp_equivalent numeric,
  p_card_last4 varchar,
  p_merchant_raw varchar,
  p_merchant_normalised varchar,
  p_bank_reference varchar,
  p_auth_or_settlement_ref varchar,
  p_transaction_family_ref varchar,
  p_parser_confidence varchar,
  p_error_code varchar,
  p_error_message text,
  p_statement_line_fingerprint_hash varchar
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_staff record;
  v_batch record;
  v_existing_line_id uuid;
  v_existing_row_id uuid;
  v_parse_status varchar;
  v_row_id uuid;
begin
  select * into v_staff from public.current_active_staff_record_();

  if v_staff.id is null then
    raise exception 'Active staff user not found for current auth user';
  end if;

  if v_staff.role_type not in ('admin', 'supervisor') then
    raise exception 'Only admin or supervisor staff can stage statement import rows. Current role: %', v_staff.role_type;
  end if;

  select * into v_batch
  from public.dva_statement_import_batches
  where id = p_import_batch_id
  for update;

  if v_batch.id is null then
    raise exception 'Statement import batch not found: %', p_import_batch_id;
  end if;

  if v_batch.status in ('committed', 'voided') then
    raise exception 'Cannot stage rows for batch % with status %', p_import_batch_id, v_batch.status;
  end if;

  select link.dva_statement_line_id into v_existing_line_id
  from public.dva_statement_line_import_links link
  where link.importer_id = v_batch.importer_id
    and link.source_bank = v_batch.source_bank
    and link.statement_line_fingerprint_hash = p_statement_line_fingerprint_hash
    and link.active_yn = true
  limit 1;

  select row.id into v_existing_row_id
  from public.dva_statement_import_rows row
  join public.dva_statement_import_batches batch on batch.id = row.import_batch_id
  where batch.importer_id = v_batch.importer_id
    and batch.source_bank = v_batch.source_bank
    and row.statement_line_fingerprint_hash = p_statement_line_fingerprint_hash
    and row.import_batch_id <> p_import_batch_id
  limit 1;

  v_parse_status := case
    when v_existing_line_id is not null or v_existing_row_id is not null then 'duplicate_skipped'
    when p_error_code is not null or p_error_message is not null then 'error'
    when p_statement_date is null then 'error'
    when p_direction is null then 'error'
    when coalesce(p_amount_local_ccy, 0) <= 0 then 'error'
    when coalesce(p_amount_gbp_equivalent, 0) <= 0 then 'error'
    else 'clean'
  end;

  insert into public.dva_statement_import_rows (
    import_batch_id,
    source_row_number,
    source_page_number,
    raw_text,
    raw_json,
    statement_date,
    transaction_date,
    direction,
    transaction_type_candidate,
    amount_local_ccy,
    balance_after_local_ccy,
    local_ccy,
    fx_rate_applied,
    card_markup_pct_applied,
    amount_gbp_equivalent,
    card_last4,
    merchant_raw,
    merchant_normalised,
    bank_reference,
    auth_or_settlement_ref,
    transaction_family_ref,
    parser_confidence,
    parse_status,
    error_code,
    error_message,
    statement_line_fingerprint_hash,
    duplicate_of_statement_line_id,
    duplicate_of_import_row_id
  ) values (
    p_import_batch_id,
    p_source_row_number,
    p_source_page_number,
    p_raw_text,
    p_raw_json,
    p_statement_date,
    p_transaction_date,
    p_direction,
    coalesce(p_transaction_type_candidate, 'unmatched_candidate'),
    p_amount_local_ccy,
    p_balance_after_local_ccy,
    upper(coalesce(trim(p_local_ccy), v_batch.local_ccy)),
    p_fx_rate_applied,
    coalesce(p_card_markup_pct_applied, v_batch.default_card_markup_pct),
    p_amount_gbp_equivalent,
    p_card_last4,
    p_merchant_raw,
    p_merchant_normalised,
    p_bank_reference,
    p_auth_or_settlement_ref,
    p_transaction_family_ref,
    coalesce(p_parser_confidence, 'low'),
    v_parse_status,
    case when v_parse_status = 'error' then coalesce(p_error_code, 'parse_error') else p_error_code end,
    case
      when v_parse_status = 'duplicate_skipped' then 'Duplicate statement line skipped by fingerprint.'
      when v_parse_status = 'error' then coalesce(p_error_message, 'Row failed validation before commit.')
      else p_error_message
    end,
    p_statement_line_fingerprint_hash,
    v_existing_line_id,
    v_existing_row_id
  ) returning id into v_row_id;

  update public.dva_statement_import_batches batch
     set row_count = counts.row_count,
         clean_count = counts.clean_count,
         error_count = counts.error_count,
         duplicate_count = counts.duplicate_count,
         status = case
           when counts.error_count > 0 or counts.duplicate_count > 0 then 'parsed_with_errors'
           else 'parsed_clean'
         end,
         parsed_at = now()
  from (
    select
      count(*)::integer as row_count,
      count(*) filter (where parse_status = 'clean')::integer as clean_count,
      count(*) filter (where parse_status = 'error')::integer as error_count,
      count(*) filter (where parse_status = 'duplicate_skipped')::integer as duplicate_count
    from public.dva_statement_import_rows
    where import_batch_id = p_import_batch_id
  ) counts
  where batch.id = p_import_batch_id;

  return jsonb_build_object(
    'ok', true,
    'import_row_id', v_row_id,
    'parse_status', v_parse_status,
    'duplicate_of_statement_line_id', v_existing_line_id,
    'duplicate_of_import_row_id', v_existing_row_id
  );
end;
$$;

create or replace function public.staff_commit_dva_statement_import_batch(
  p_import_batch_id uuid,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_staff record;
  v_batch record;
  v_statement_id uuid;
  v_committed_count integer := 0;
  v_row record;
  v_line_id uuid;
begin
  select * into v_staff from public.current_active_staff_record_();

  if v_staff.id is null then
    raise exception 'Active staff user not found for current auth user';
  end if;

  if v_staff.role_type not in ('admin', 'supervisor') then
    raise exception 'Only admin or supervisor staff can commit statement imports. Current role: %', v_staff.role_type;
  end if;

  select * into v_batch
  from public.dva_statement_import_batches
  where id = p_import_batch_id
  for update;

  if v_batch.id is null then
    raise exception 'Statement import batch not found: %', p_import_batch_id;
  end if;

  if v_batch.status = 'committed' then
    return jsonb_build_object('ok', true, 'already_committed', true, 'committed_count', v_batch.committed_count);
  end if;

  if v_batch.status in ('voided', 'failed') then
    raise exception 'Cannot commit batch % with status %', p_import_batch_id, v_batch.status;
  end if;

  if exists (
    select 1
    from public.dva_statement_import_rows
    where import_batch_id = p_import_batch_id
      and parse_status = 'error'
  ) then
    raise exception 'Cannot commit batch % while row-level parse errors exist', p_import_batch_id;
  end if;

  insert into public.dva_statements (
    importer_id,
    source_bank,
    uploaded_by_staff_id,
    csv_url,
    statement_period_from,
    statement_period_to,
    parse_status,
    parse_errors_json
  ) values (
    v_batch.importer_id,
    v_batch.source_bank,
    v_staff.id,
    v_batch.source_file_url,
    v_batch.statement_period_from,
    v_batch.statement_period_to,
    'parsed',
    null
  ) returning id into v_statement_id;

  for v_row in
    select *
    from public.dva_statement_import_rows
    where import_batch_id = p_import_batch_id
      and parse_status = 'clean'
    order by source_row_number
  loop
    if exists (
      select 1
      from public.dva_statement_line_import_links link
      where link.importer_id = v_batch.importer_id
        and link.source_bank = v_batch.source_bank
        and link.statement_line_fingerprint_hash = v_row.statement_line_fingerprint_hash
        and link.active_yn = true
    ) then
      update public.dva_statement_import_rows
         set parse_status = 'duplicate_skipped',
             error_code = 'duplicate_on_commit',
             error_message = 'Duplicate detected at commit by fingerprint.'
       where id = v_row.id;
      continue;
    end if;

    insert into public.dva_statement_lines (
      dva_statement_id,
      line_order,
      statement_date,
      reference_raw,
      direction,
      amount_local_ccy,
      local_ccy,
      fx_rate_applied,
      card_markup_pct_applied,
      amount_gbp_equivalent,
      auth_id_ref,
      retailer_name_ref,
      match_status
    ) values (
      v_statement_id,
      v_row.source_row_number,
      v_row.statement_date,
      left(coalesce(v_row.raw_text, ''), 255),
      v_row.direction,
      v_row.amount_local_ccy,
      v_row.local_ccy,
      v_row.fx_rate_applied,
      v_row.card_markup_pct_applied,
      v_row.amount_gbp_equivalent,
      coalesce(v_row.auth_or_settlement_ref, v_row.bank_reference),
      v_row.merchant_raw,
      'unmatched'
    ) returning id into v_line_id;

    insert into public.dva_statement_line_import_links (
      importer_id,
      source_bank,
      import_batch_id,
      import_row_id,
      dva_statement_id,
      dva_statement_line_id,
      statement_line_fingerprint_hash,
      active_yn
    ) values (
      v_batch.importer_id,
      v_batch.source_bank,
      p_import_batch_id,
      v_row.id,
      v_statement_id,
      v_line_id,
      v_row.statement_line_fingerprint_hash,
      true
    );

    update public.dva_statement_import_rows
       set parse_status = 'committed',
           committed_dva_statement_line_id = v_line_id,
           committed_at = now()
     where id = v_row.id;

    v_committed_count := v_committed_count + 1;
  end loop;

  update public.dva_statement_import_batches
     set status = 'committed',
         committed_by_staff_id = v_staff.id,
         committed_at = now(),
         committed_count = v_committed_count,
         notes = coalesce(p_notes, notes)
   where id = p_import_batch_id;

  return jsonb_build_object(
    'ok', true,
    'import_batch_id', p_import_batch_id,
    'dva_statement_id', v_statement_id,
    'committed_count', v_committed_count
  );
end;
$$;

create or replace function public.staff_void_dva_statement_import_batch(
  p_import_batch_id uuid,
  p_void_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_staff record;
  v_batch record;
  v_allocation_count integer;
  v_voided_line_count integer;
begin
  select * into v_staff from public.current_active_staff_record_();

  if v_staff.id is null then
    raise exception 'Active staff user not found for current auth user';
  end if;

  if v_staff.role_type not in ('admin', 'supervisor') then
    raise exception 'Only admin or supervisor staff can void statement imports. Current role: %', v_staff.role_type;
  end if;

  if coalesce(trim(p_void_reason), '') = '' then
    raise exception 'Void reason is required';
  end if;

  select * into v_batch
  from public.dva_statement_import_batches
  where id = p_import_batch_id
  for update;

  if v_batch.id is null then
    raise exception 'Statement import batch not found: %', p_import_batch_id;
  end if;

  select count(*)::integer into v_allocation_count
  from public.dva_statement_line_import_links link
  join public.dva_statement_line_allocations alloc
    on alloc.dva_statement_line_id = link.dva_statement_line_id
   and alloc.allocation_status = 'confirmed'
  where link.import_batch_id = p_import_batch_id
    and link.active_yn = true;

  if v_allocation_count > 0 then
    raise exception 'Cannot void import batch %. % committed line(s) have confirmed allocations. Reverse allocations first.',
      p_import_batch_id, v_allocation_count;
  end if;

  update public.dva_statement_line_import_links
     set active_yn = false
   where import_batch_id = p_import_batch_id
     and active_yn = true;

  get diagnostics v_voided_line_count = row_count;

  update public.dva_statement_import_rows
     set parse_status = 'voided'
   where import_batch_id = p_import_batch_id
     and parse_status in ('clean', 'committed', 'duplicate_skipped');

  update public.dva_statement_import_batches
     set status = 'voided',
         voided_by_staff_id = v_staff.id,
         voided_at = now(),
         void_reason = p_void_reason
   where id = p_import_batch_id;

  return jsonb_build_object(
    'ok', true,
    'import_batch_id', p_import_batch_id,
    'voided_line_count', v_voided_line_count
  );
end;
$$;

revoke all on function public.current_active_staff_record_() from public;
revoke all on function public.staff_create_dva_statement_import_batch(uuid, varchar, date, date, varchar, varchar, varchar, varchar, numeric, text, text) from public;
revoke all on function public.staff_stage_dva_statement_import_row(uuid, integer, integer, text, jsonb, date, date, varchar, varchar, numeric, numeric, varchar, numeric, numeric, numeric, varchar, varchar, varchar, varchar, varchar, varchar, varchar, varchar, text, varchar) from public;
revoke all on function public.staff_commit_dva_statement_import_batch(uuid, text) from public;
revoke all on function public.staff_void_dva_statement_import_batch(uuid, text) from public;

grant execute on function public.staff_create_dva_statement_import_batch(uuid, varchar, date, date, varchar, varchar, varchar, varchar, numeric, text, text) to authenticated;
grant execute on function public.staff_stage_dva_statement_import_row(uuid, integer, integer, text, jsonb, date, date, varchar, varchar, numeric, numeric, varchar, numeric, numeric, numeric, varchar, varchar, varchar, varchar, varchar, varchar, varchar, varchar, text, varchar) to authenticated;
grant execute on function public.staff_commit_dva_statement_import_batch(uuid, text) to authenticated;
grant execute on function public.staff_void_dva_statement_import_batch(uuid, text) to authenticated;

commit;

-- Smoke checks after execution:
-- select to_regclass('public.dva_statement_import_batches') as import_batches;
-- select to_regclass('public.dva_statement_import_rows') as import_rows;
-- select to_regclass('public.dva_statement_line_import_links') as import_links;
-- select to_regprocedure('public.staff_create_dva_statement_import_batch(uuid,character varying,date,date,character varying,character varying,character varying,character varying,numeric,text,text)') as create_batch_rpc;
-- select to_regprocedure('public.staff_stage_dva_statement_import_row(uuid,integer,integer,text,jsonb,date,date,character varying,character varying,numeric,numeric,character varying,numeric,numeric,numeric,character varying,character varying,character varying,character varying,character varying,character varying,character varying,character varying,text,character varying)') as stage_row_rpc;
-- select to_regprocedure('public.staff_commit_dva_statement_import_batch(uuid,text)') as commit_batch_rpc;
-- select to_regprocedure('public.staff_void_dva_statement_import_batch(uuid,text)') as void_batch_rpc;
