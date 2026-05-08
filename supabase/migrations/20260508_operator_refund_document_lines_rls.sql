-- Allow assigned operators to review and correct refund-document child lines
-- through the same access chain used by the operator invoice reconciliation flow.
--
-- This keeps the supplier credit/control/coding lane unchanged. It only lets an
-- assigned operator see and correct commercial refund-document lines before
-- those lines are released to supplier control.

alter table if exists public.dispute_refund_document_lines enable row level security;

drop policy if exists dispute_refund_document_lines_operator_select on public.dispute_refund_document_lines;
drop policy if exists dispute_refund_document_lines_operator_update_unreleased on public.dispute_refund_document_lines;
drop policy if exists dispute_refund_document_lines_operator_insert on public.dispute_refund_document_lines;
drop policy if exists dispute_refund_document_lines_operator_delete_manual_unreleased on public.dispute_refund_document_lines;

create policy dispute_refund_document_lines_operator_select
on public.dispute_refund_document_lines
for select
to authenticated
using (
  exists (
    select 1
    from public.dispute_refund_evidence_submissions s
    join public.disputes d on d.id = s.dispute_id
    join public.orders o on o.id = d.order_id
    join public.operators op on op.auth_user_id = auth.uid() and op.active = true
    join public.operator_importers oi on oi.operator_id = op.id and oi.importer_id = o.importer_id and oi.revoked_at is null
    where s.id = dispute_refund_document_lines.refund_evidence_submission_id
  )
);

create policy dispute_refund_document_lines_operator_update_unreleased
on public.dispute_refund_document_lines
for update
to authenticated
using (
  coalesce(progressed_to_supplier_control_yn, false) = false
  and exists (
    select 1
    from public.dispute_refund_evidence_submissions s
    join public.disputes d on d.id = s.dispute_id
    join public.orders o on o.id = d.order_id
    join public.operators op on op.auth_user_id = auth.uid() and op.active = true
    join public.operator_importers oi on oi.operator_id = op.id and oi.importer_id = o.importer_id and oi.revoked_at is null
    where s.id = dispute_refund_document_lines.refund_evidence_submission_id
      and coalesce(s.supplier_control_status, 'blocked') in ('blocked', 'not_released', 'pending', 'pending_ocr', 'needs_operator_review', 'needs_supervisor_review')
      and coalesce(s.supplier_approval_status, 'blocked') in ('blocked', 'pending', 'not_started')
  )
)
with check (
  coalesce(progressed_to_supplier_control_yn, false) = false
  and exists (
    select 1
    from public.dispute_refund_evidence_submissions s
    join public.disputes d on d.id = s.dispute_id
    join public.orders o on o.id = d.order_id
    join public.operators op on op.auth_user_id = auth.uid() and op.active = true
    join public.operator_importers oi on oi.operator_id = op.id and oi.importer_id = o.importer_id and oi.revoked_at is null
    where s.id = dispute_refund_document_lines.refund_evidence_submission_id
      and coalesce(s.supplier_control_status, 'blocked') in ('blocked', 'not_released', 'pending', 'pending_ocr', 'needs_operator_review', 'needs_supervisor_review')
      and coalesce(s.supplier_approval_status, 'blocked') in ('blocked', 'pending', 'not_started')
  )
);

create policy dispute_refund_document_lines_operator_insert
on public.dispute_refund_document_lines
for insert
to authenticated
with check (
  line_source = 'manually_added'
  and coalesce(progressed_to_supplier_control_yn, false) = false
  and exists (
    select 1
    from public.dispute_refund_evidence_submissions s
    join public.disputes d on d.id = s.dispute_id
    join public.orders o on o.id = d.order_id
    join public.operators op on op.auth_user_id = auth.uid() and op.active = true
    join public.operator_importers oi on oi.operator_id = op.id and oi.importer_id = o.importer_id and oi.revoked_at is null
    where s.id = dispute_refund_document_lines.refund_evidence_submission_id
      and coalesce(s.supplier_control_status, 'blocked') in ('blocked', 'not_released', 'pending', 'pending_ocr', 'needs_operator_review', 'needs_supervisor_review')
      and coalesce(s.supplier_approval_status, 'blocked') in ('blocked', 'pending', 'not_started')
  )
);

create policy dispute_refund_document_lines_operator_delete_manual_unreleased
on public.dispute_refund_document_lines
for delete
to authenticated
using (
  line_source = 'manually_added'
  and coalesce(progressed_to_supplier_control_yn, false) = false
  and exists (
    select 1
    from public.dispute_refund_evidence_submissions s
    join public.disputes d on d.id = s.dispute_id
    join public.orders o on o.id = d.order_id
    join public.operators op on op.auth_user_id = auth.uid() and op.active = true
    join public.operator_importers oi on oi.operator_id = op.id and oi.importer_id = o.importer_id and oi.revoked_at is null
    where s.id = dispute_refund_document_lines.refund_evidence_submission_id
      and coalesce(s.supplier_control_status, 'blocked') in ('blocked', 'not_released', 'pending', 'pending_ocr', 'needs_operator_review', 'needs_supervisor_review')
      and coalesce(s.supplier_approval_status, 'blocked') in ('blocked', 'pending', 'not_started')
  )
);
