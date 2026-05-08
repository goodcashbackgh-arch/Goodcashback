"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { supabaseAdmin } from "@/lib/supabase/admin";
import { createClient } from "@/utils/supabase/server";

function asString(value: FormDataEntryValue | null) {
  return typeof value === "string" ? value.trim() : "";
}

function asNumber(value: FormDataEntryValue | null, fallback = 0) {
  const raw = asString(value);
  if (!raw) return fallback;
  const parsed = Number(raw);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function redirectBack(disputeId: string, submissionId: string, params: Record<string, string>): never {
  const query = new URLSearchParams(params);
  redirect(`/importer/exceptions/${disputeId}/refund-document-review/${submissionId}?${query.toString()}`);
}

async function requireOperatorAccess(disputeId: string, submissionId: string) {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { ok: false as const, supabase, error: "Please sign in again." };

  const { data: operator } = await supabase
    .from("operators")
    .select("id")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!operator) return { ok: false as const, supabase, error: "Active operator account not found." };

  const { data: disputeRaw, error: disputeError } = await supabaseAdmin
    .from("disputes")
    .select("id, order_id")
    .eq("id", disputeId)
    .maybeSingle();

  if (disputeError || !disputeRaw) return { ok: false as const, supabase, error: disputeError?.message ?? "Dispute not found." };
  const dispute = disputeRaw as { id: string; order_id: string };

  const { data: orderRaw, error: orderError } = await supabaseAdmin
    .from("orders")
    .select("id, importer_id")
    .eq("id", dispute.order_id)
    .maybeSingle();

  if (orderError || !orderRaw) return { ok: false as const, supabase, error: orderError?.message ?? "Dispute order not found." };
  const order = orderRaw as { id: string; importer_id: string | null };
  if (!order.importer_id) return { ok: false as const, supabase, error: "Dispute order importer not found." };

  const { data: importerAccess, error: importerAccessError } = await supabaseAdmin
    .from("operator_importers")
    .select("id")
    .eq("operator_id", operator.id)
    .eq("importer_id", order.importer_id)
    .is("revoked_at", null)
    .maybeSingle();

  if (importerAccessError || !importerAccess) return { ok: false as const, supabase, error: importerAccessError?.message ?? "Operator is not assigned to this importer." };

  const { data: submissionRaw, error: submissionError } = await supabaseAdmin
    .from("dispute_refund_evidence_submissions")
    .select("id, dispute_id, supplier_control_status, supplier_approval_status")
    .eq("id", submissionId)
    .eq("dispute_id", disputeId)
    .maybeSingle();

  if (submissionError || !submissionRaw) return { ok: false as const, supabase, error: submissionError?.message ?? "Refund document submission not found." };
  const submission = submissionRaw as { supplier_control_status?: string | null; supplier_approval_status?: string | null };
  if (!["blocked", "not_released", "pending", "pending_ocr", "needs_operator_review", "needs_supervisor_review"].includes(String(submission.supplier_control_status ?? "blocked"))) {
    return { ok: false as const, supabase, error: "This refund document is already in supplier control and cannot be edited by the operator." };
  }
  if (!["blocked", "pending", "not_started", ""].includes(String(submission.supplier_approval_status ?? "blocked"))) {
    return { ok: false as const, supabase, error: "This refund document has moved beyond operator review." };
  }

  return { ok: true as const, supabase, operatorId: operator.id };
}

export async function updateRefundDocumentLineAction(formData: FormData) {
  const disputeId = asString(formData.get("dispute_id"));
  const submissionId = asString(formData.get("refund_evidence_submission_id"));
  const lineId = asString(formData.get("line_id"));

  if (!disputeId) redirect("/importer");
  if (!submissionId || !lineId) redirect(`/importer/exceptions/${disputeId}?error=Missing+refund+document+line`);

  const guard = await requireOperatorAccess(disputeId, submissionId);
  if (!guard.ok) redirectBack(disputeId, submissionId, { error: guard.error });

  const { error } = await supabaseAdmin
    .from("dispute_refund_document_lines")
    .update({
      description: asString(formData.get("description")) || "Refund document line",
      qty: asNumber(formData.get("qty"), 1),
      amount_gbp: asNumber(formData.get("amount_gbp"), 0),
    })
    .eq("id", lineId)
    .eq("refund_evidence_submission_id", submissionId)
    .eq("progressed_to_supplier_control_yn", false);

  if (error) redirectBack(disputeId, submissionId, { error: error.message });

  revalidatePath(`/importer/exceptions/${disputeId}/refund-document-review/${submissionId}`);
  revalidatePath(`/importer/exceptions/${disputeId}`);
  revalidatePath(`/internal/refund-document-control/${submissionId}`);
  redirectBack(disputeId, submissionId, { success: "Refund document line updated." });
}

export async function addManualRefundDocumentLineAction(formData: FormData) {
  const disputeId = asString(formData.get("dispute_id"));
  const submissionId = asString(formData.get("refund_evidence_submission_id"));

  if (!disputeId) redirect("/importer");
  if (!submissionId) redirect(`/importer/exceptions/${disputeId}?error=Missing+refund+document+submission`);

  const guard = await requireOperatorAccess(disputeId, submissionId);
  if (!guard.ok) redirectBack(disputeId, submissionId, { error: guard.error });

  const description = asString(formData.get("description"));
  const amount = asNumber(formData.get("amount_gbp"), 0);
  if (!description) redirectBack(disputeId, submissionId, { error: "Manual line description is required." });
  if (amount <= 0) redirectBack(disputeId, submissionId, { error: "Manual line amount must be above zero." });

  const { data: existingLinesRaw } = await supabaseAdmin
    .from("dispute_refund_document_lines")
    .select("line_order")
    .eq("refund_evidence_submission_id", submissionId)
    .order("line_order", { ascending: false })
    .limit(1);

  const existingLines = (existingLinesRaw ?? []) as Array<{ line_order: number | string | null }>;
  const nextOrder = Number(existingLines[0]?.line_order ?? 0) + 1;
  const { error } = await supabaseAdmin
    .from("dispute_refund_document_lines")
    .insert({
      refund_evidence_submission_id: submissionId,
      line_order: nextOrder,
      line_source: "manually_added",
      description,
      qty: asNumber(formData.get("qty"), 1),
      amount_gbp: amount,
      progressed_to_supplier_control_yn: false,
    });

  if (error) redirectBack(disputeId, submissionId, { error: error.message });

  revalidatePath(`/importer/exceptions/${disputeId}/refund-document-review/${submissionId}`);
  revalidatePath(`/internal/refund-document-control/${submissionId}`);
  redirectBack(disputeId, submissionId, { success: "Manual refund document line added." });
}

export async function deleteManualRefundDocumentLineAction(formData: FormData) {
  const disputeId = asString(formData.get("dispute_id"));
  const submissionId = asString(formData.get("refund_evidence_submission_id"));
  const lineId = asString(formData.get("line_id"));

  if (!disputeId) redirect("/importer");
  if (!submissionId || !lineId) redirect(`/importer/exceptions/${disputeId}?error=Missing+manual+line`);

  const guard = await requireOperatorAccess(disputeId, submissionId);
  if (!guard.ok) redirectBack(disputeId, submissionId, { error: guard.error });

  const { error } = await supabaseAdmin
    .from("dispute_refund_document_lines")
    .delete()
    .eq("id", lineId)
    .eq("refund_evidence_submission_id", submissionId)
    .eq("line_source", "manually_added")
    .eq("progressed_to_supplier_control_yn", false);

  if (error) redirectBack(disputeId, submissionId, { error: error.message });

  revalidatePath(`/importer/exceptions/${disputeId}/refund-document-review/${submissionId}`);
  revalidatePath(`/internal/refund-document-control/${submissionId}`);
  redirectBack(disputeId, submissionId, { success: "Manual refund document line deleted." });
}

export async function requestSupervisorRefundDocumentResubmissionAction(formData: FormData) {
  const disputeId = asString(formData.get("dispute_id"));
  const submissionId = asString(formData.get("refund_evidence_submission_id"));
  const reason = asString(formData.get("reason"));

  if (!disputeId) redirect("/importer");
  if (!submissionId) redirect(`/importer/exceptions/${disputeId}?error=Missing+refund+document+submission`);
  if (!reason) redirectBack(disputeId, submissionId, { error: "Explain why supervisor review/resubmission is needed." });

  const guard = await requireOperatorAccess(disputeId, submissionId);
  if (!guard.ok) redirectBack(disputeId, submissionId, { error: guard.error });

  const body = [
    "[REFUND_DOCUMENT_OPERATOR_REVIEW_REQUEST_V1]",
    `operator_id: ${guard.operatorId}`,
    `refund_evidence_submission_id: ${submissionId}`,
    "request_type: resubmission_or_supervisor_decision",
    "",
    reason,
  ].join("\n");

  const { error } = await guard.supabase.from("dispute_messages").insert({
    dispute_id: disputeId,
    message_type: "refund_document_operator_review_request",
    counterparty: "internal",
    body,
    generated_by: "operator_review",
  });

  if (error) redirectBack(disputeId, submissionId, { error: error.message });

  revalidatePath(`/importer/exceptions/${disputeId}/refund-document-review/${submissionId}`);
  revalidatePath(`/internal/exceptions/${disputeId}`);
  redirectBack(disputeId, submissionId, { success: "Supervisor review/resubmission request sent." });
}

export async function confirmRefundDocumentLinesAction(formData: FormData) {
  const disputeId = asString(formData.get("dispute_id"));
  const submissionId = asString(formData.get("refund_evidence_submission_id"));
  const notes = asString(formData.get("notes"));

  if (!disputeId) redirect("/importer");
  if (!submissionId) redirect(`/importer/exceptions/${disputeId}?error=Missing+refund+document+submission`);

  const guard = await requireOperatorAccess(disputeId, submissionId);
  if (!guard.ok) redirectBack(disputeId, submissionId, { error: guard.error });

  const body = [
    "[REFUND_DOCUMENT_OPERATOR_CONFIRMATION_V1]",
    `operator_id: ${guard.operatorId}`,
    `refund_evidence_submission_id: ${submissionId}`,
    "confirmation: commercial_lines_confirmed_for_supplier_credit_control",
    "",
    notes || "No notes.",
  ].join("\n");

  const { error } = await guard.supabase.from("dispute_messages").insert({
    dispute_id: disputeId,
    message_type: "refund_document_operator_confirmed",
    counterparty: "internal",
    body,
    generated_by: "operator_review",
  });

  if (error) redirectBack(disputeId, submissionId, { error: error.message });

  revalidatePath(`/importer/exceptions/${disputeId}/refund-document-review/${submissionId}`);
  revalidatePath(`/importer/exceptions/${disputeId}`);
  revalidatePath(`/internal/exceptions/${disputeId}`);
  revalidatePath(`/internal/refund-document-control/${submissionId}`);
  redirectBack(disputeId, submissionId, { success: "Refund document lines confirmed. Supervisor can now continue the supplier credit control lane." });
}
