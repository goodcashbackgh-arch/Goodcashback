-- dva_statement_import_mindee_pdf_v1.sql
-- Status: EXECUTABLE SQL PATCH - RUN ONLY AFTER REVIEW/APPROVAL IN CURRENT CHAT.
-- Scope: additive Mindee PDF OCR tracking for DVA/card statement import batches.
--
-- Does not:
--   - alter active DVA/card statement line semantics;
--   - change funding reconciliation;
--   - change supplier invoice allocation;
--   - change operator invoice/OCR reconciliation;
--   - post to Sage.
--
-- Purpose:
--   PDF statement imports need OCR job/inference tracking before extracted rows are staged.
--   CSV/text can continue to parse directly.

begin;

set local lock_timeout = '15s';
set local statement_timeout = '0';

alter table public.dva_statement_import_batches
  add column if not exists mindee_statement_job_id varchar null,
  add column if not exists mindee_statement_inference_id varchar null,
  add column if not exists mindee_statement_model_id varchar null,
  add column if not exists mindee_statement_ocr_status varchar not null default 'not_started',
  add column if not exists mindee_statement_enqueued_at timestamptz null,
  add column if not exists mindee_statement_completed_at timestamptz null,
  add column if not exists mindee_statement_result_saved_at timestamptz null,
  add column if not exists mindee_statement_last_http_status integer null,
  add column if not exists mindee_statement_pages_consumed integer null,
  add column if not exists mindee_statement_error_message text null,
  add column if not exists mindee_statement_raw_json jsonb null;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'dva_statement_import_batches_mindee_statement_status_check'
      and conrelid = 'public.dva_statement_import_batches'::regclass
  ) then
    alter table public.dva_statement_import_batches
      add constraint dva_statement_import_batches_mindee_statement_status_check
      check (mindee_statement_ocr_status in (
        'not_started',
        'enqueueing',
        'queued',
        'processing',
        'completed',
        'failed',
        'cancelled'
      ));
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'dva_statement_import_batches_mindee_pages_check'
      and conrelid = 'public.dva_statement_import_batches'::regclass
  ) then
    alter table public.dva_statement_import_batches
      add constraint dva_statement_import_batches_mindee_pages_check
      check (mindee_statement_pages_consumed is null or mindee_statement_pages_consumed >= 0);
  end if;
end $$;

create index if not exists dva_statement_import_batches_mindee_job_idx
  on public.dva_statement_import_batches(mindee_statement_job_id)
  where mindee_statement_job_id is not null;

create or replace function public.staff_mark_dva_statement_import_mindee_enqueued(
  p_import_batch_id uuid,
  p_mindee_job_id varchar,
  p_mindee_inference_id varchar default null,
  p_mindee_model_id varchar default null,
  p_http_status integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_staff record;
  v_batch record;
begin
  select * into v_staff from public.current_active_staff_record_();

  if v_staff.id is null then
    raise exception 'Active staff user not found for current auth user';
  end if;

  if v_staff.role_type not in ('admin', 'supervisor') then
    raise exception 'Only admin or supervisor staff can start statement OCR. Current role: %', v_staff.role_type;
  end if;

  select * into v_batch
  from public.dva_statement_import_batches
  where id = p_import_batch_id
  for update;

  if v_batch.id is null then
    raise exception 'Statement import batch not found: %', p_import_batch_id;
  end if;

  if v_batch.detected_file_type <> 'pdf' then
    raise exception 'Mindee statement OCR can only be started for PDF imports. Batch % type is %', p_import_batch_id, v_batch.detected_file_type;
  end if;

  if v_batch.status in ('committed', 'voided') then
    raise exception 'Cannot start OCR for batch % in status %', p_import_batch_id, v_batch.status;
  end if;

  if coalesce(v_batch.mindee_statement_ocr_status, 'not_started') in ('queued', 'processing', 'completed') then
    raise exception 'Statement OCR already started for batch %. Current OCR status: %', p_import_batch_id, v_batch.mindee_statement_ocr_status;
  end if;

  update public.dva_statement_import_batches
  set
    status = 'ocr_or_parsing',
    mindee_statement_job_id = p_mindee_job_id,
    mindee_statement_inference_id = p_mindee_inference_id,
    mindee_statement_model_id = p_mindee_model_id,
    mindee_statement_ocr_status = 'queued',
    mindee_statement_enqueued_at = now(),
    mindee_statement_last_http_status = p_http_status,
    mindee_statement_error_message = null,
    notes = concat_ws(E'\n', notes, 'Mindee statement OCR enqueued by staff ' || v_staff.id::text || ' at ' || now()::text)
  where id = p_import_batch_id;

  return jsonb_build_object(
    'ok', true,
    'import_batch_id', p_import_batch_id,
    'mindee_statement_job_id', p_mindee_job_id,
    'mindee_statement_ocr_status', 'queued'
  );
end;
$$;

create or replace function public.staff_save_dva_statement_import_mindee_result(
  p_import_batch_id uuid,
  p_mindee_inference_id varchar default null,
  p_ocr_status varchar default 'completed',
  p_raw_json jsonb default null,
  p_pages_consumed integer default null,
  p_http_status integer default null,
  p_error_message text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_staff record;
  v_batch record;
  v_final_status varchar;
begin
  select * into v_staff from public.current_active_staff_record_();

  if v_staff.id is null then
    raise exception 'Active staff user not found for current auth user';
  end if;

  if v_staff.role_type not in ('admin', 'supervisor') then
    raise exception 'Only admin or supervisor staff can save statement OCR results. Current role: %', v_staff.role_type;
  end if;

  if p_ocr_status not in ('not_started','enqueueing','queued','processing','completed','failed','cancelled') then
    raise exception 'Unsupported Mindee statement OCR status: %', p_ocr_status;
  end if;

  select * into v_batch
  from public.dva_statement_import_batches
  where id = p_import_batch_id
  for update;

  if v_batch.id is null then
    raise exception 'Statement import batch not found: %', p_import_batch_id;
  end if;

  v_final_status := case
    when p_ocr_status = 'completed' then 'ocr_or_parsing'
    when p_ocr_status in ('failed', 'cancelled') then 'failed'
    else coalesce(v_batch.status, 'ocr_or_parsing')
  end;

  update public.dva_statement_import_batches
  set
    status = v_final_status,
    mindee_statement_inference_id = coalesce(p_mindee_inference_id, mindee_statement_inference_id),
    mindee_statement_ocr_status = p_ocr_status,
    mindee_statement_completed_at = case when p_ocr_status in ('completed', 'failed', 'cancelled') then now() else mindee_statement_completed_at end,
    mindee_statement_result_saved_at = case when p_raw_json is not null then now() else mindee_statement_result_saved_at end,
    mindee_statement_last_http_status = coalesce(p_http_status, mindee_statement_last_http_status),
    mindee_statement_pages_consumed = coalesce(p_pages_consumed, mindee_statement_pages_consumed),
    mindee_statement_error_message = p_error_message,
    mindee_statement_raw_json = coalesce(p_raw_json, mindee_statement_raw_json),
    parse_errors_json = case
      when p_error_message is not null then jsonb_build_object('mindee_statement_error', p_error_message, 'saved_at', now())
      else parse_errors_json
    end
  where id = p_import_batch_id;

  return jsonb_build_object(
    'ok', true,
    'import_batch_id', p_import_batch_id,
    'mindee_statement_ocr_status', p_ocr_status,
    'status', v_final_status
  );
end;
$$;

commit;
