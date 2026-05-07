"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

function bodyValue(body: string | null | undefined, key: string) {
  const line = (body ?? "").split("\n").find((row) => row.startsWith(`${key}:`));
  return line ? line.slice(key.length + 1).trim() : "";
}

function redirectWithResult(evidenceId: string, params: Record<string, string>): never {
  const query = new URLSearchParams(params);
  redirect(`/importer/refund-evidence-review/${evidenceId}?${query.toString()}`);
}

async function requireActiveOperator() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) return { supabase, ok: false as const, operatorId: "", error: "Please sign in again." };

  const { data: operator, error } = await supabase
    .from("operators")
    .select("id")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (error || !operator) return { supabase, ok: false as const, operatorId: "", error: error?.message ?? "Active operator account not found." };
  return { supabase, ok: true as const, operatorId: String(operator.id) };
}

export async function confirmRefundEvidenceOperatorReviewAction(formData: FormData) {
  const evidenceId = readString(formData, "evidence_id");
  const disputeId = readString(formData, "dispute_id");
  const reviewDecision = readString(formData, "review_decision") || "confirmed_clean";
  const notes = readString(formData, "notes");

  if (!evidenceId || !disputeId) redirect("/importer");
  if (!["confirmed_clean", "needs_supervisor_review"].includes(reviewDecision)) {
    redirectWithResult(evidenceId, { error: "Invalid review decision." });
  }

  const guard = await requireActiveOperator();
  if (!guard.ok) redirectWithResult(evidenceId, { error: guard.error });

  const { data: evidence, error: evidenceError } = await guard.supabase
    .from("dispute_messages")
    .select("id, dispute_id, message_type, body")
    .eq("id", evidenceId)
    .eq("dispute_id", disputeId)
    .maybeSingle();

  if (evidenceError || !evidence) redirectWithResult(evidenceId, { error: evidenceError?.message ?? "Refund evidence not found." });
  if (!["credit_note_evidence", "refund_evidence"].includes(String(evidence.message_type))) {
    redirectWithResult(evidenceId, { error: "Only refund or credit-note evidence can be reviewed here." });
  }

  const { data: dispute, error: disputeError } = await guard.supabase
    .from("disputes")
    .select("id, order_id, desired_outcome, status")
    .eq("id", disputeId)
    .maybeSingle();

  if (disputeError || !dispute) redirectWithResult(evidenceId, { error: disputeError?.message ?? "Dispute not found." });
  if (dispute.desired_outcome !== "refund") redirectWithResult(evidenceId, { error: "Refund evidence review only applies to refund exceptions." });

  const { data: order, error: orderError } = await guard.supabase
    .from("orders")
    .select("id, importer_id")
    .eq("id", dispute.order_id)
    .maybeSingle();

  if (orderError || !order?.importer_id) redirectWithResult(evidenceId, { error: orderError?.message ?? "Parent order importer could not be resolved." });

  const { data: access, error: accessError } = await guard.supabase
    .from("operator_importers")
    .select("id")
    .eq("operator_id", guard.operatorId)
    .eq("importer_id", order.importer_id)
    .is("revoked_at", null)
    .limit(1)
    .maybeSingle();

  if (accessError || !access) redirectWithResult(evidenceId, { error: accessError?.message ?? "You are not authorised to review this evidence." });

  const { data: existing } = await guard.supabase
    .from("dispute_messages")
    .select("id, body")
    .eq("dispute_id", disputeId)
    .eq("message_type", "refund_evidence_operator_review")
    .limit(20);

  const alreadyConfirmed = (existing ?? []).some((message) => String(message.body ?? "").includes(`source_evidence_message_id: ${evidenceId}`));
  if (alreadyConfirmed) redirectWithResult(evidenceId, { error: "This evidence has already been operator-reviewed." });

  const body = String(evidence.body ?? "");
  const operatorReviewBody = [
    "[REFUND_EVIDENCE_OPERATOR_REVIEW_V1]",
    `reviewed_by_operator_id: ${guard.operatorId}`,
    `source_evidence_message_id: ${evidenceId}`,
    `dispute_id: ${disputeId}`,
    `review_decision: ${reviewDecision}`,
    `document_mode: ${bodyValue(body, "document_mode") || "—"}`,
    `supplier_readiness_route: ${bodyValue(body, "supplier_readiness_route") || "—"}`,
    `evidence_control_status: ${bodyValue(body, "evidence_control_status") || "—"}`,
    `captured_refund_amount_abs_gbp: ${bodyValue(body, "captured_refund_amount_abs_gbp") || "—"}`,
    `expected_exception_amount_abs_gbp: ${bodyValue(body, "expected_exception_amount_abs_gbp") || "—"}`,
    `variance_abs_gbp: ${bodyValue(body, "variance_abs_gbp") || "—"}`,
    "",
    notes || "Operator confirmed the refund/credit evidence review from the reconciled review page.",
  ].join("\n");

  const { error: insertError } = await guard.supabase.from("dispute_messages").insert({
    dispute_id: disputeId,
    message_type: "refund_evidence_operator_review",
    counterparty: "internal",
    body: operatorReviewBody,
    generated_by: "operator_refund_evidence_review",
  });

  if (insertError) redirectWithResult(evidenceId, { error: insertError.message });

  revalidatePath(`/importer/refund-evidence-review/${evidenceId}`);
  revalidatePath(`/importer/exceptions/${disputeId}`);
  revalidatePath("/internal/supplier-draft-ready");
  redirectWithResult(evidenceId, { success: reviewDecision === "confirmed_clean" ? "Refund evidence confirmed clean and released for supplier current-control review." : "Refund evidence marked for supervisor review." });
}
