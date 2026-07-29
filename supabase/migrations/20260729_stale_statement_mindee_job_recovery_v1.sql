-- Stale statement Mindee job recovery v1
-- Scope is frozen by docs/governing-pack/ui/STALE_STATEMENT_MINDEE_JOB_RECOVERY_ADDENDUM_v1.md.
-- This adds one narrowly guarded recovery operation only.

begin;

set local lock_timeout = '15s';
set local statement_timeout = '0';

create or replace function public.staff_recover_dva_statement_import_missing_mindee_job_v1(
  p_import_batch_id uuid,
  p_expected_mindee_job_id varchar,
  p_http_status integer,
  p_error_message text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_staff record;
  v_batch record;
  v_expected_job_id text := nullif(trim(coalesce(p_expected_mindee_job_id, '')), '');
  v_error_message text := trim(coalesce(p_error_message, ''));
begin
  select * into v_staff from public.current_active_staff_record_();

  if v_staff.id is null then
    raise exception 'Active staff user not found for current auth user';
  end if;

  if v_staff.role_type not in ('admin', 'supervisor') then
    raise exception 'Only admin or supervisor staff can recover stale statement OCR jobs. Current role: %', v_staff.role_type;
  end if;

  if p_http_status <> 404 then
    raise exception 'Stale statement OCR recovery requires HTTP 404. Received: %', p_http_status;
  end if;

  if v_expected_job_id is null then
    raise exception 'Expected Mindee statement job id is required for stale-job recovery.';
  end if;

  if position('job' in lower(v_error_message)) = 0
     or position('not found' in lower(v_error_message)) = 0
     or position(lower(v_expected_job_id) in lower(v_error_message)) = 0 then
    raise exception 'Mindee response does not definitively identify expected job % as not found.', v_expected_job_id;
  end if;

  select * into v_batch
  from public.dva_statement_import_batches
  where id = p_import_batch_id
  for update;

  if v_batch.id is null then
    raise exception 'Statement import batch not found: %', p_import_batch_id;
  end if;

  if v_batch.detected_file_type <> 'pdf' then
    raise exception 'Stale statement OCR recovery is limited to PDF imports. Batch % type is %', p_import_batch_id, v_batch.detected_file_type;
  end if;

  if v_batch.mindee_statement_job_id is distinct from v_expected_job_id then
    raise exception 'Statement OCR job changed before recovery for batch %. Expected %, current %.', p_import_batch_id, v_expected_job_id, v_batch.mindee_statement_job_id;
  end if;

  if v_batch.status in ('committed', 'voided')
     or coalesce(v_batch.committed_count, 0) <> 0
     or v_batch.committed_at is not null then
    raise exception 'Cannot recover stale statement OCR job for committed or voided batch %.', p_import_batch_id;
  end if;

  if v_batch.status not in ('ocr_or_parsing', 'failed') then
    raise exception 'Cannot recover stale statement OCR job for batch % in status %.', p_import_batch_id, v_batch.status;
  end if;

  if coalesce(v_batch.mindee_statement_ocr_status, 'not_started') not in ('queued', 'processing', 'failed') then
    raise exception 'Cannot recover stale statement OCR job for batch % with OCR status %.', p_import_batch_id, v_batch.mindee_statement_ocr_status;
  end if;

  if exists (
    select 1
    from public.dva_statement_import_rows r
    where r.import_batch_id = p_import_batch_id
  ) then
    raise exception 'Cannot recover stale statement OCR job for batch % because staged statement rows exist.', p_import_batch_id;
  end if;

  update public.dva_statement_import_batches
  set
    status = 'uploaded',
    mindee_statement_ocr_status = 'not_started',
    mindee_statement_job_id = null,
    mindee_statement_inference_id = null,
    mindee_statement_enqueued_at = null,
    mindee_statement_completed_at = null,
    mindee_statement_result_saved_at = null,
    mindee_statement_last_http_status = null,
    mindee_statement_pages_consumed = null,
    mindee_statement_error_message = null,
    mindee_statement_raw_json = null,
    parse_errors_json = null
  where id = p_import_batch_id
    and mindee_statement_job_id = v_expected_job_id;

  if not found then
    raise exception 'Statement OCR job changed before recovery update for batch %.', p_import_batch_id;
  end if;

  return jsonb_build_object(
    'ok', true,
    'recovered', true,
    'import_batch_id', p_import_batch_id,
    'status', 'uploaded',
    'mindee_statement_ocr_status', 'not_started'
  );
end;
$$;

commit;
