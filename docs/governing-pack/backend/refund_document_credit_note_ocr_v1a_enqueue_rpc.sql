-- =============================================================================
-- refund_document_credit_note_ocr_v1a_enqueue_rpc.sql
-- Add enqueue-state RPC for refund document credit-note OCR.
-- Run after refund_document_credit_note_ocr_v1.sql.
-- =============================================================================

begin;

set local lock_timeout = '15s';
set local statement_timeout = '0';

create or replace function public.staff_start_refund_credit_note_ocr(
  p_refund_evidence_submission_id uuid,
  p_model_id varchar,
  p_mindee_job_id varchar,
  p_mindee_inference_id varchar default null,
  p_http_status integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_staff_id uuid;
  v_submission record;
begin
  select s.id into v_staff_id
  from public.staff s
  where s.auth_user_id = auth.uid()
    and s.active = true
    and s.role_type in ('admin','supervisor')
  limit 1;

  if v_staff_id is null then
    raise exception 'Only active admin/supervisor staff can start credit-note OCR.';
  end if;

  select s.id, s.document_mode, s.credit_note_file_url, s.ocr_status, s.mindee_job_id
    into v_submission
  from public.dispute_refund_evidence_submissions s
  where s.id = p_refund_evidence_submission_id
  for update;

  if v_submission.id is null then
    raise exception 'Refund evidence submission not found: %', p_refund_evidence_submission_id;
  end if;

  if v_submission.document_mode <> 'credit_note' then
    raise exception 'Credit-note OCR can only start for document_mode=credit_note. Current mode: %', v_submission.document_mode;
  end if;

  if nullif(btrim(coalesce(v_submission.credit_note_file_url, '')), '') is null then
    raise exception 'Credit note file URL is missing for submission %', p_refund_evidence_submission_id;
  end if;

  if v_submission.mindee_job_id is not null and v_submission.ocr_status in ('queued','processing','completed') then
    raise exception 'Credit-note OCR already has Mindee job % with status %. Use safe fetch instead of enqueueing again.', v_submission.mindee_job_id, v_submission.ocr_status;
  end if;

  update public.dispute_refund_evidence_submissions s
  set
    ocr_status = 'queued',
    mindee_job_id = nullif(btrim(coalesce(p_mindee_job_id, '')), ''),
    mindee_inference_id = nullif(btrim(coalesce(p_mindee_inference_id, '')), ''),
    mindee_model_id = nullif(btrim(coalesce(p_model_id, '')), ''),
    mindee_last_http_status = p_http_status,
    mindee_error_message = null,
    mindee_enqueued_at = now(),
    supplier_control_status = 'blocked',
    supplier_approval_status = 'blocked',
    evidence_control_status = 'credit_note_ocr_queued',
    supplier_readiness_route = 'supplier_credit_note_ocr_pending'
  where s.id = p_refund_evidence_submission_id;

  return jsonb_build_object(
    'ok', true,
    'refund_evidence_submission_id', p_refund_evidence_submission_id,
    'ocr_status', 'queued',
    'mindee_job_id', p_mindee_job_id,
    'mindee_inference_id', p_mindee_inference_id,
    'model_id', p_model_id
  );
end;
$$;

comment on function public.staff_start_refund_credit_note_ocr(uuid, varchar, varchar, varchar, integer) is
'Stores Mindee enqueue identifiers for a refund-document credit-note OCR job. Staff/admin only. Does not consume a page by itself; the app route calls Mindee enqueue first.';

grant execute on function public.staff_start_refund_credit_note_ocr(uuid, varchar, varchar, varchar, integer) to authenticated;

commit;
