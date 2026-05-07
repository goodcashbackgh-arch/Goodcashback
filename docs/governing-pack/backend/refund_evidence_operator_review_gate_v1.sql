-- Refund evidence operator review gate v1
-- Purpose:
--   Insert an operator final-check gate between refund/credit evidence upload and
--   supplier-draft-ready current approval.
--
-- Pattern:
--   dispute_messages remains the legacy/audit source for uploaded evidence.
--   trg_gcb_sync_exception_evidence_message already syncs that into
--   dispute_refund_evidence_submissions.
--   This patch stores operator review state on the structured table and exposes
--   a SECURITY DEFINER RPC for linked operators.

begin;

alter table public.dispute_refund_evidence_submissions
  add column if not exists operator_review_status text not null default 'pending_review',
  add column if not exists operator_reviewed_by_operator_id uuid null references public.operators(id),
  add column if not exists operator_reviewed_at timestamptz null,
  add column if not exists operator_review_notes text null;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'dispute_refund_evidence_submissions_operator_review_status_check'
      and conrelid = 'public.dispute_refund_evidence_submissions'::regclass
  ) then
    alter table public.dispute_refund_evidence_submissions
      add constraint dispute_refund_evidence_submissions_operator_review_status_check
      check (operator_review_status in ('pending_review','confirmed_clean','needs_supervisor_review'));
  end if;
end $$;

create or replace function public.operator_confirm_refund_evidence_review(
  p_source_dispute_message_id uuid,
  p_review_decision text,
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
  v_importer_id uuid;
begin
  if v_auth_uid is null then
    raise exception 'Unauthenticated user.';
  end if;

  if p_review_decision not in ('confirmed_clean','needs_supervisor_review') then
    raise exception 'Invalid refund evidence review decision.';
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

  select *
    into v_submission
  from public.dispute_refund_evidence_submissions s
  where s.source_dispute_message_id = p_source_dispute_message_id
  limit 1;

  if v_submission.id is null then
    raise exception 'Refund evidence submission not found.';
  end if;

  select o.importer_id
    into v_importer_id
  from public.disputes d
  join public.orders o on o.id = d.order_id
  where d.id = v_submission.dispute_id
    and d.desired_outcome = 'refund'
    and d.status = 'awaiting_refund_credit'
  limit 1;

  if v_importer_id is null then
    raise exception 'Refund dispute is not in a reviewable state.';
  end if;

  if not exists (
    select 1
    from public.operator_importers oi
    where oi.operator_id = v_operator_id
      and oi.importer_id = v_importer_id
      and oi.revoked_at is null
  ) then
    raise exception 'Operator is not authorised to review this refund evidence.';
  end if;

  if v_submission.supplier_approval_status = 'approved_current' then
    raise exception 'Refund evidence has already been supplier-approved current.';
  end if;

  update public.dispute_refund_evidence_submissions s
  set operator_review_status = p_review_decision,
      operator_reviewed_by_operator_id = v_operator_id,
      operator_reviewed_at = now(),
      operator_review_notes = nullif(btrim(coalesce(p_notes, '')), '')
  where s.id = v_submission.id;

  return jsonb_build_object(
    'ok', true,
    'refund_evidence_submission_id', v_submission.id,
    'source_dispute_message_id', p_source_dispute_message_id,
    'operator_review_status', p_review_decision
  );
end;
$$;

grant execute on function public.operator_confirm_refund_evidence_review(uuid, text, text) to authenticated;

commit;
