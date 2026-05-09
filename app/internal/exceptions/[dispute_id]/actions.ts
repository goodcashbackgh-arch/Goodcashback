"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

function redirectWithResult(disputeId: string, params: Record<string, string>): never {
  const query = new URLSearchParams(params);
  redirect(`/internal/exceptions/${disputeId}?${query.toString()}`);
}

async function requireActiveStaff() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    return { supabase, ok: false as const, error: "Please sign in again." };
  }

  const { data: staff } = await supabase
    .from("staff")
    .select("id")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!staff) {
    return { supabase, ok: false as const, error: "Active staff account not found." };
  }

  return { supabase, ok: true as const, staffId: staff.id };
}

async function requireRetailerMessageAndAcceptedOutcome(supabase: Awaited<ReturnType<typeof createClient>>, disputeId: string) {
  const { count, error } = await supabase
    .from("dispute_messages")
    .select("id", { count: "exact", head: true })
    .eq("dispute_id", disputeId)
    .eq("message_type", "retailer_reply")
    .eq("counterparty", "retailer");

  if (error) {
    return { ok: false as const, error: error.message };
  }

  if (Number(count ?? 0) < 1) {
    return { ok: false as const, error: "At least one retailer reply is required before accepting final outcome." };
  }

  const { data: lines, error: linesError } = await supabase
    .from("dispute_lines")
    .select("id, conversation_status")
    .eq("dispute_id", disputeId)
    .is("resolved_at", null);

  if (linesError) {
    return { ok: false as const, error: linesError.message };
  }

  if ((lines ?? []).length < 1) {
    return { ok: false as const, error: "No active dispute lines found." };
  }

  const hasAcceptedOutcome = (lines ?? []).every((line) => line.conversation_status === "retailer_response_received");
  if (!hasAcceptedOutcome) {
    return { ok: false as const, error: "Retailer outcome must be marked as accepted before final outcome acceptance." };
  }

  return { ok: true as const };
}

async function transitionDisputeStatus(
  supabase: Awaited<ReturnType<typeof createClient>>,
  disputeId: string,
  fromStatus: string,
  toStatus: string,
) {
  const { data, error } = await supabase
    .from("disputes")
    .update({ status: toStatus })
    .eq("id", disputeId)
    .eq("status", fromStatus)
    .select("id")
    .maybeSingle();

  if (error) {
    return { ok: false as const, error: error.message };
  }

  if (!data) {
    return { ok: false as const, error: `Unable to transition dispute from ${fromStatus} to ${toStatus}.` };
  }

  return { ok: true as const };
}

export async function addDisputeInternalNoteAction(formData: FormData) {
  const disputeId = readString(formData, "dispute_id");
  const body = readString(formData, "body");

  if (!disputeId) redirect("/internal/exceptions");
  if (!body) redirectWithResult(disputeId, { error: "Note body cannot be blank." });

  const guard = await requireActiveStaff();
  if (!guard.ok) redirectWithResult(disputeId, { error: guard.error });

  const { error } = await guard.supabase
    .from("dispute_messages")
    .insert({
      dispute_id: disputeId,
      message_type: "supervisor_note",
      counterparty: "internal",
      body,
      generated_by: "manual",
    });

  if (error) redirectWithResult(disputeId, { error: error.message });

  revalidatePath(`/internal/exceptions/${disputeId}`);
  revalidatePath(`/importer/exceptions/${disputeId}`);
  redirectWithResult(disputeId, { success: "Internal note added." });
}

export async function approveRefundPursuitAction(formData: FormData) {
  const disputeId = readString(formData, "dispute_id");
  if (!disputeId) redirect("/internal/exceptions");

  const guard = await requireActiveStaff();
  if (!guard.ok) redirectWithResult(disputeId, { error: guard.error });

  const { data: dispute, error: disputeError } = await guard.supabase
    .from("disputes")
    .select("id, desired_outcome, refund_approved_at")
    .eq("id", disputeId)
    .maybeSingle();

  if (disputeError || !dispute) redirectWithResult(disputeId, { error: "Dispute not found." });
  if (dispute.desired_outcome !== "refund") redirectWithResult(disputeId, { error: "Refund approval is only available for refund disputes." });
  if (dispute.refund_approved_at) redirectWithResult(disputeId, { error: "Refund pursuit is already approved." });

  const { error } = await guard.supabase
    .from("disputes")
    .update({ refund_approved_by_staff_id: guard.staffId, refund_approved_at: new Date().toISOString() })
    .eq("id", disputeId);

  if (error) redirectWithResult(disputeId, { error: error.message });

  revalidatePath(`/internal/exceptions/${disputeId}`);
  revalidatePath(`/importer/exceptions/${disputeId}`);
  redirectWithResult(disputeId, { success: "Refund pursuit approved." });
}

export async function acceptFinalRefundOutcomeAction(formData: FormData) {
  const disputeId = readString(formData, "dispute_id");
  if (!disputeId) redirect("/internal/exceptions");

  const guard = await requireActiveStaff();
  if (!guard.ok) redirectWithResult(disputeId, { error: guard.error });

  const { data: dispute, error: disputeError } = await guard.supabase
    .from("disputes")
    .select("id, desired_outcome, status")
    .eq("id", disputeId)
    .maybeSingle();

  if (disputeError || !dispute) redirectWithResult(disputeId, { error: "Dispute not found." });
  if (dispute.desired_outcome !== "refund") redirectWithResult(disputeId, { error: "Final refund outcome is only available for refund disputes." });

  const finalOutcomeGuard = await requireRetailerMessageAndAcceptedOutcome(guard.supabase, disputeId);
  if (!finalOutcomeGuard.ok) redirectWithResult(disputeId, { error: finalOutcomeGuard.error });

  let currentStatus = dispute.status;
  if (currentStatus === "raised") {
    const underReviewTransition = await transitionDisputeStatus(guard.supabase, disputeId, "raised", "under_review");
    if (!underReviewTransition.ok) redirectWithResult(disputeId, { error: underReviewTransition.error });
    currentStatus = "under_review";
  }

  if (currentStatus !== "under_review") {
    redirectWithResult(disputeId, { error: `Refund final acceptance requires dispute status raised or under_review. Current status: ${currentStatus}.` });
  }

  const approvedRefundTransition = await transitionDisputeStatus(guard.supabase, disputeId, "under_review", "approved_refund");
  if (!approvedRefundTransition.ok) redirectWithResult(disputeId, { error: approvedRefundTransition.error });

  const awaitingCreditTransition = await transitionDisputeStatus(guard.supabase, disputeId, "approved_refund", "awaiting_refund_credit");
  if (!awaitingCreditTransition.ok) redirectWithResult(disputeId, { error: awaitingCreditTransition.error });

  revalidatePath(`/internal/exceptions/${disputeId}`);
  revalidatePath(`/importer/exceptions/${disputeId}`);
  redirectWithResult(disputeId, { success: "Final refund outcome accepted." });
}

export async function reviewRefundEvidenceAction(formData: FormData) {
  const disputeId = readString(formData, "dispute_id");
  const reviewDecision = readString(formData, "review_decision");
  const reviewNotes = readString(formData, "review_notes");

  if (!disputeId) redirect("/internal/exceptions");
  if (!["accepted", "hold", "rejected"].includes(reviewDecision)) {
    redirectWithResult(disputeId, { error: "Select a valid refund evidence review decision." });
  }

  const guard = await requireActiveStaff();
  if (!guard.ok) redirectWithResult(disputeId, { error: guard.error });

  const { data: dispute, error: disputeError } = await guard.supabase
    .from("disputes")
    .select("id, desired_outcome, status")
    .eq("id", disputeId)
    .maybeSingle();

  if (disputeError || !dispute) redirectWithResult(disputeId, { error: "Dispute not found." });
  if (dispute.desired_outcome !== "refund") redirectWithResult(disputeId, { error: "Refund evidence review is only available for refund disputes." });
  if (dispute.status !== "awaiting_refund_credit") {
    redirectWithResult(disputeId, { error: `Refund evidence review requires awaiting_refund_credit status. Current status: ${dispute.status}.` });
  }

  const { data: evidenceMessages, error: evidenceError } = await guard.supabase
    .from("dispute_messages")
    .select("id, created_at")
    .eq("dispute_id", disputeId)
    .in("message_type", ["credit_note_evidence", "refund_evidence"])
    .order("created_at", { ascending: false })
    .limit(1);

  if (evidenceError) redirectWithResult(disputeId, { error: evidenceError.message });
  if (!evidenceMessages || evidenceMessages.length < 1) {
    redirectWithResult(disputeId, { error: "Operator refund/credit-note evidence must be uploaded before supervisor review." });
  }

  const body = [
    "[REFUND_EVIDENCE_REVIEW_V1]",
    `reviewed_by_staff_id: ${guard.staffId}`,
    `review_decision: ${reviewDecision}`,
    `source_evidence_message_id: ${evidenceMessages[0].id}`,
    "",
    reviewNotes || "No review notes.",
  ].join("\n");

  const { error } = await guard.supabase.from("dispute_messages").insert({
    dispute_id: disputeId,
    message_type: "refund_evidence_review",
    counterparty: "internal",
    body,
    generated_by: "supervisor_review",
  });

  if (error) redirectWithResult(disputeId, { error: error.message });

  revalidatePath(`/internal/exceptions/${disputeId}`);
  revalidatePath(`/importer/exceptions/${disputeId}`);
  revalidatePath(`/internal/status-control/pre-sage-financial-readiness`);
  redirectWithResult(disputeId, { success: `Refund evidence review saved: ${reviewDecision}.` });
}

export async function reviewReturnCollectionEvidenceAction(formData: FormData) {
  const disputeId = readString(formData, "dispute_id");
  const reviewDecision = readString(formData, "review_decision");
  const reviewNotes = readString(formData, "review_notes");
  const explicitSubmissionId = readString(formData, "return_tracking_submission_id");

  if (!disputeId) redirect("/internal/exceptions");
  if (!["accepted", "hold", "rejected"].includes(reviewDecision)) {
    redirectWithResult(disputeId, { error: "Select a valid return evidence review decision." });
  }

  const guard = await requireActiveStaff();
  if (!guard.ok) redirectWithResult(disputeId, { error: guard.error });

  let submissionId = explicitSubmissionId;

  if (!submissionId) {
    const { data: latestSubmission, error: latestSubmissionError } = await guard.supabase
      .from("dispute_return_tracking_submissions")
      .select("id, submitted_at")
      .eq("dispute_id", disputeId)
      .order("submitted_at", { ascending: false })
      .limit(1)
      .maybeSingle();

    if (latestSubmissionError) redirectWithResult(disputeId, { error: latestSubmissionError.message });
    if (!latestSubmission?.id) {
      redirectWithResult(disputeId, { error: "Operator return/collection evidence must be uploaded before supervisor review." });
    }

    submissionId = latestSubmission.id;
  }

  const { data: rpcData, error: rpcError } = await guard.supabase.rpc("staff_review_return_collection_tracking", {
    p_return_tracking_submission_id: submissionId,
    p_review_decision: reviewDecision,
    p_review_notes: reviewNotes || null,
  });

  if (rpcError) redirectWithResult(disputeId, { error: rpcError.message });
  if (rpcData && typeof rpcData === "object" && "ok" in rpcData && !(rpcData as { ok?: boolean }).ok) {
    redirectWithResult(disputeId, { error: "Failed to save structured return/collection review." });
  }

  revalidatePath(`/internal/exceptions/${disputeId}`);
  revalidatePath(`/importer/exceptions/${disputeId}`);
  redirectWithResult(disputeId, { success: `Return/collection evidence review saved: ${reviewDecision}.` });
}

export async function acceptReplacementOutcomeAction(formData: FormData) {
  const disputeId = readString(formData, "dispute_id");
  if (!disputeId) redirect("/internal/exceptions");

  const guard = await requireActiveStaff();
  if (!guard.ok) redirectWithResult(disputeId, { error: guard.error });

  const { data: dispute, error: disputeError } = await guard.supabase
    .from("disputes")
    .select("id, order_id, desired_outcome, replacement_child_order_id, status")
    .eq("id", disputeId)
    .maybeSingle();

  if (disputeError || !dispute) redirectWithResult(disputeId, { error: "Dispute not found." });
  if (dispute.desired_outcome !== "replacement") redirectWithResult(disputeId, { error: "Replacement outcome is only available for replacement disputes." });
  if (dispute.replacement_child_order_id) redirectWithResult(disputeId, { error: "Replacement child order already exists." });

  const finalOutcomeGuard = await requireRetailerMessageAndAcceptedOutcome(guard.supabase, disputeId);
  if (!finalOutcomeGuard.ok) redirectWithResult(disputeId, { error: finalOutcomeGuard.error });

  const { data: parentOrder, error: parentOrderError } = await guard.supabase
    .from("orders")
    .select("id, order_ref, importer_id, operator_id, shipper_id, retailer_id, destination_hub_id, sop_version")
    .eq("id", dispute.order_id)
    .maybeSingle();

  if (parentOrderError || !parentOrder) redirectWithResult(disputeId, { error: "Parent order not found." });

  const { data: replacementLinesRaw, error: replacementLinesError } = await guard.supabase
    .from("dispute_lines")
    .select("id, qty_impact, amount_impact_gbp, supplier_invoice_lines(id, line_source, description)")
    .eq("dispute_id", disputeId)
    .is("resolved_at", null);

  if (replacementLinesError) redirectWithResult(disputeId, { error: replacementLinesError.message });

  const replacementLines = (replacementLinesRaw ?? []) as Array<{
    id: string;
    qty_impact: number | string | null;
    amount_impact_gbp: number | string | null;
    supplier_invoice_lines:
      | { id?: string | null; line_source?: string | null; description?: string | null }
      | { id?: string | null; line_source?: string | null; description?: string | null }[]
      | null;
  }>;

  if (replacementLines.length < 1) {
    redirectWithResult(disputeId, { error: "No active replacement dispute lines found." });
  }

  const sourceLineFor = (line: (typeof replacementLines)[number]) => {
    const source = line.supplier_invoice_lines;
    return Array.isArray(source) ? source[0] ?? null : source;
  };

  const nonManualLine = replacementLines.find((line) => sourceLineFor(line)?.line_source !== "manually_added");
  if (nonManualLine) {
    redirectWithResult(disputeId, { error: "Replacement child creation requires manual missing-item lines. Use the refund path for OCR/supplier-issued lines." });
  }

  const replacementQty = replacementLines.reduce((sum, line) => {
    const value = Number(line.qty_impact ?? 0);
    return sum + (Number.isFinite(value) ? Math.abs(value) : 0);
  }, 0);

  const replacementValue = Math.round(replacementLines.reduce((sum, line) => {
    const value = Number(line.amount_impact_gbp ?? 0);
    return sum + (Number.isFinite(value) ? Math.abs(value) : 0);
  }, 0) * 100) / 100;

  if (!Number.isFinite(replacementQty) || replacementQty <= 0) {
    redirectWithResult(disputeId, { error: "Replacement child creation requires a positive manual missing-item quantity." });
  }

  if (!Number.isFinite(replacementValue) || replacementValue <= 0) {
    redirectWithResult(disputeId, { error: "Replacement child creation requires a positive manual missing-item value." });
  }

  const { count: childCount, error: childCountError } = await guard.supabase
    .from("orders")
    .select("id", { count: "exact", head: true })
    .eq("parent_order_id", parentOrder.id);

  if (childCountError) redirectWithResult(disputeId, { error: childCountError.message });

  let sequence = Number(childCount ?? 0) + 1;
  let childOrderRef = `${parentOrder.order_ref}-R${sequence}`;

  while (true) {
    const { data: existingRef, error: existingRefError } = await guard.supabase
      .from("orders")
      .select("id")
      .eq("order_ref", childOrderRef)
      .limit(1)
      .maybeSingle();

    if (existingRefError) redirectWithResult(disputeId, { error: existingRefError.message });
    if (!existingRef) break;

    sequence += 1;
    childOrderRef = `${parentOrder.order_ref}-R${sequence}`;
  }

  const { data: childOrder, error: childInsertError } = await guard.supabase
    .from("orders")
    .insert({
      order_ref: childOrderRef,
      importer_id: parentOrder.importer_id,
      operator_id: parentOrder.operator_id,
      shipper_id: parentOrder.shipper_id,
      retailer_id: parentOrder.retailer_id,
      destination_hub_id: parentOrder.destination_hub_id,
      parent_order_id: parentOrder.id,
      order_type: "replacement_child",
      order_total_gbp_declared: replacementValue,
      total_qty_declared: replacementQty,
      status: "evidence_collecting",
      sop_version: parentOrder.sop_version,
    })
    .select("id")
    .single();

  if (childInsertError || !childOrder) redirectWithResult(disputeId, { error: childInsertError?.message ?? "Failed to create replacement child order." });

  let currentStatus = dispute.status;
  if (currentStatus === "raised") {
    const underReviewTransition = await transitionDisputeStatus(guard.supabase, disputeId, "raised", "under_review");
    if (!underReviewTransition.ok) redirectWithResult(disputeId, { error: underReviewTransition.error });
    currentStatus = "under_review";
  }

  if (currentStatus !== "under_review") {
    redirectWithResult(disputeId, { error: `Replacement final acceptance requires dispute status raised or under_review. Current status: ${currentStatus}.` });
  }

  const approvedReplacementTransition = await transitionDisputeStatus(guard.supabase, disputeId, "under_review", "approved_replacement");
  if (!approvedReplacementTransition.ok) redirectWithResult(disputeId, { error: approvedReplacementTransition.error });

  const { error: childLinkError } = await guard.supabase
    .from("disputes")
    .update({ replacement_child_order_id: childOrder.id })
    .eq("id", disputeId);

  if (childLinkError) redirectWithResult(disputeId, { error: childLinkError.message });

  const replacedTransition = await transitionDisputeStatus(guard.supabase, disputeId, "approved_replacement", "replaced");
  if (!replacedTransition.ok) redirectWithResult(disputeId, { error: replacedTransition.error });

  const now = new Date().toISOString();

  const { error: resolveLinesError } = await guard.supabase
    .from("dispute_lines")
    .update({
      resolved_via_child_order_id: childOrder.id,
      conversation_status: "resolved_replacement",
      resolution_method: "replacement",
      resolved_at: now,
    })
    .eq("dispute_id", disputeId)
    .is("resolved_at", null);

  if (resolveLinesError) redirectWithResult(disputeId, { error: resolveLinesError.message });

  revalidatePath(`/internal/exceptions/${disputeId}`);
  revalidatePath(`/importer/exceptions/${disputeId}`);
  revalidatePath(`/importer/orders/${childOrder.id}/operations`);
  revalidatePath("/importer");
  redirectWithResult(disputeId, { success: `Replacement outcome accepted and child order created with qty ${replacementQty} / value £${replacementValue.toFixed(2)}.` });
}
