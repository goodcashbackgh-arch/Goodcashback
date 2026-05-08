-- Operator decisions for refund document review.
-- This keeps the existing shared refund-document control lane:
-- correct upload => ready for staff control queue
-- wrong upload => staff rejection/resubmission requested

begin;

set local lock_timeout = '15s';
set local statement_timeout = '0';

create or replace function public.operator_progress_refund_document_submission_to_staff_control(
  p_refund_evidence_submission_id uuid,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_auth_uid uuid := auth.uid();
  v_operator_id uuid;
  v_submission public.dispute_refund_evidence_submissions%rowtype;
  v_line_count int;
  v_line_total numeric(12,2);
  v_accepted_total numeric(12,2);
begin
  if v_auth_uid is null then
    raise exception 'Unauthenticated user.';
  end if;

  select op.id
    into v_operator_id
  from public.operators op
  where op.auth_user_id = v_auth_uid
    and op.active = true
  limit 1;

  if v_operator_id is null then
    raise exception 'Active operator account not found.';
  end if;

  select s.*
    into v_submission
  from public.dispute_refund_evidence_submissions s
  join public.disputes d on d.id = s.dispute_id
  join public.orders o on o.id = d.order_id
  join public.operator_importers oi on oi.operator_id = v_operator_id
    and oi.importer_id = o.importer_id
    and oi.revoked_at is null
  where s.id = p_refund_evidence_submission_id
  limit 1;

  if v_submission.id is null then
    raise exception 'Refund document submission not found or not assigned to this operator.';
  end if;

  if coalesce(v_submission.supplier_control_status, 'not_released') not in ('not_released','blocked') then
    raise exception 'This refund document has already moved into supplier control.';
  end if;

  if coalesce(v_submission.supplier_approval_status, 'blocked') not in ('blocked','pending','not_started') then
    raise exception 'This refund document has moved beyond operator review.';
  end if;

  select count(*)::int, coalesce(sum(abs(coalesce(amount_gbp, 0))), 0)::numeric(12,2)
    into v_line_count, v_line_total
  from public.dispute_refund_document_lines
  where refund_evidence_submission_id = p_refund_evidence_submission_id;

  if coalesce(v_line_count, 0) = 0 then
    raise exception 'Add or OCR-fetch at least one refund document line before progressing.';
  end if;

  v_accepted_total := coalesce(
    v_submission.ocr_credit_note_total_gbp,
    v_submission.expected_credit_note_total_gbp,
    v_submission.captured_refund_amount_abs_gbp,
    v_submission.expected_exception_amount_abs_gbp,
    0
  )::numeric(12,2);

  if abs(v_line_total - v_accepted_total) > 0.01 then
    raise exception 'Refund document lines do not match the expected document value. Expected %, got %.', v_accepted_total, v_line_total;
  end if;

  update public.dispute_refund_evidence_submissions s
  set match_status = 'matched_ready_to_release',
      amount_balance_status = 'balanced',
      supplier_control_status = 'not_released',
      supplier_approval_status = case when coalesce(s.supplier_approval_status, 'blocked') = 'blocked' then 'pending' else s.supplier_approval_status end,
      supervisor_review_status = 'not_required',
      evidence_control_status = 'operator_confirmed_ready_for_staff_control',
      supplier_readiness_route = case
        when s.document_mode = 'credit_note' then 'supplier_credit_note_readiness_ready'
        else 'supplier_refund_adjustment_ready'
      end,
      notes = nullif(btrim(coalesce(s.notes, '') || case when nullif(btrim(coalesce(p_notes, '')), '') is null then '' else E'\nOperator confirmation: ' || btrim(p_notes) end), '')
  where s.id = p_refund_evidence_submission_id;

  insert into public.dispute_messages (
    dispute_id,
    message_type,
    counterparty,
    body,
    generated_by
  ) values (
    v_submission.dispute_id,
    'refund_document_operator_progressed',
    'internal',
    array_to_string(array[
      '[REFUND_DOCUMENT_OPERATOR_PROGRESSED_V1]',
      'operator_id: ' || v_operator_id::text,
      'refund_evidence_submission_id: ' || p_refund_evidence_submission_id::text,
      'decision: correct_upload_progress_to_staff_control',
      '',
      coalesce(nullif(btrim(coalesce(p_notes, '')), ''), 'No notes.')
    ], E'\n'),
    'operator_review'
  );

  return jsonb_build_object('ok', true, 'refund_evidence_submission_id', p_refund_evidence_submission_id, 'decision', 'progressed_to_staff_control');
end;
$$;

create or replace function public.operator_request_refund_document_rejection(
  p_refund_evidence_submission_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_auth_uid uuid := auth.uid();
  v_operator_id uuid;
  v_submission public.dispute_refund_evidence_submissions%rowtype;
begin
  if v_auth_uid is null then
    raise exception 'Unauthenticated user.';
  end if;

  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'Explain why the refund document should be rejected/resubmitted.';
  end if;

  select op.id
    into v_operator_id
  from public.operators op
  where op.auth_user_id = v_auth_uid
    and op.active = true
  limit 1;

  if v_operator_id is null then
    raise exception 'Active operator account not found.';
  end if;

  select s.*
    into v_submission
  from public.dispute_refund_evidence_submissions s
  join public.disputes d on d.id = s.dispute_id
  join public.orders o on o.id = d.order_id
  join public.operator_importers oi on oi.operator_id = v_operator_id
    and oi.importer_id = o.importer_id
    and oi.revoked_at is null
  where s.id = p_refund_evidence_submission_id
  limit 1;

  if v_submission.id is null then
    raise exception 'Refund document submission not found or not assigned to this operator.';
  end if;

  if coalesce(v_submission.supplier_control_status, 'not_released') not in ('not_released','blocked') then
    raise exception 'This refund document has already moved into supplier control.';
  end if;

  update public.dispute_refund_evidence_submissions s
  set match_status = 'needs_supervisor_review',
      supplier_control_status = 'blocked',
      supplier_approval_status = 'blocked',
      supervisor_review_status = 'pending_review',
      evidence_control_status = 'operator_rejection_requested_wrong_upload',
      supplier_readiness_route = 'supplier_refund_adjustment_review_required',
      notes = nullif(btrim(coalesce(s.notes, '') || E'\nOperator rejection request: ' || btrim(p_reason)), '')
  where s.id = p_refund_evidence_submission_id;

  insert into public.dispute_messages (
    dispute_id,
    message_type,
    counterparty,
    body,
    generated_by
  ) values (
    v_submission.dispute_id,
    'refund_document_operator_rejection_requested',
    'internal',
    array_to_string(array[
      '[REFUND_DOCUMENT_OPERATOR_REJECTION_REQUESTED_V1]',
      'operator_id: ' || v_operator_id::text,
      'refund_evidence_submission_id: ' || p_refund_evidence_submission_id::text,
      'decision: wrong_upload_reject_or_request_resubmission',
      '',
      btrim(p_reason)
    ], E'\n'),
    'operator_review'
  );

  return jsonb_build_object('ok', true, 'refund_evidence_submission_id', p_refund_evidence_submission_id, 'decision', 'rejection_requested');
end;
$$;

grant execute on function public.operator_progress_refund_document_submission_to_staff_control(uuid, text) to authenticated;
grant execute on function public.operator_request_refund_document_rejection(uuid, text) to authenticated;

commit;
