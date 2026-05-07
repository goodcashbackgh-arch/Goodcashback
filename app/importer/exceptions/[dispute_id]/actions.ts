"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

const INVOICE_EVIDENCE_BUCKET = "invoice-evidence";

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

function readFile(formData: FormData, key: string) {
  const value = formData.get(key);
  return value instanceof File && value.size > 0 ? value : null;
}

function redirectWithResult(disputeId: string, params: Record<string, string>): never {
  const query = new URLSearchParams(params);
  redirect(`/importer/exceptions/${disputeId}?${query.toString()}`);
}

const OUTCOME_TO_STATUS: Record<string, string> = {
  still_waiting: "retailer_contacted",
  retailer_accepted: "retailer_response_received",
  retailer_disputed: "awaiting_retailer_resolution",
  more_info_requested: "retailer_draft_ready",
};

async function requireActiveOperator() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) return { supabase, ok: false as const, error: "Please sign in again." };

  const { data: operator } = await supabase
    .from("operators")
    .select("id")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!operator) return { supabase, ok: false as const, error: "Active operator account not found." };

  return { supabase, ok: true as const, operatorId: operator.id };
}

async function requireDisputeAccess(supabase: Awaited<ReturnType<typeof createClient>>, operatorId: string, disputeId: string) {
  const { data: dispute, error: disputeError } = await supabase
    .from("disputes")
    .select("id, order_id, desired_outcome, status, refund_approved_at, amount_impact_gbp")
    .eq("id", disputeId)
    .maybeSingle();

  if (disputeError || !dispute) return { ok: false as const, error: "Dispute not found." };

  const { data: order, error: orderError } = await supabase
    .from("orders")
    .select("id, importer_id")
    .eq("id", dispute.order_id)
    .maybeSingle();

  if (orderError || !order?.importer_id) return { ok: false as const, error: "Dispute order importer could not be resolved." };

  const { data: importerAccess, error: importerAccessError } = await supabase
    .from("operator_importers")
    .select("id")
    .eq("operator_id", operatorId)
    .eq("importer_id", order.importer_id)
    .is("revoked_at", null)
    .limit(1)
    .maybeSingle();

  if (importerAccessError || !importerAccess) {
    return { ok: false as const, error: "You are not authorised to update this dispute." };
  }

  return { ok: true as const, dispute, order };
}

function safeFilename(name: string) {
  return name.replace(/[^a-zA-Z0-9._-]+/g, "-").slice(0, 120) || "upload";
}

function parseNumber(value: string) {
  if (!value) return 0;
  const parsed = Number(value.replace(/,/g, ""));
  return Number.isFinite(parsed) ? parsed : 0;
}

function negative(value: string) {
  const parsed = parseNumber(value);
  if (!parsed) return 0;
  return -Math.abs(parsed);
}

async function uploadEvidenceFile(
  supabase: Awaited<ReturnType<typeof createClient>>,
  disputeId: string,
  folder: string,
  file: File | null,
) {
  if (!file) return "";

  const objectPath = `${folder}/${disputeId}/${Date.now()}-${safeFilename(file.name)}`;
  const { error } = await supabase.storage.from(INVOICE_EVIDENCE_BUCKET).upload(objectPath, file, { upsert: false });
  if (error) throw new Error(error.message);

  const { data } = supabase.storage.from(INVOICE_EVIDENCE_BUCKET).getPublicUrl(objectPath);
  return data.publicUrl || objectPath;
}

type RefundLineBuild = {
  lines: string[];
  totalAmountAbs: number;
  totalQtyAbs: number;
};

function buildRefundEvidenceLines(formData: FormData): RefundLineBuild {
  const lines: string[] = [];
  let totalAmountAbs = 0;
  let totalQtyAbs = 0;

  for (let index = 1; index <= 5; index += 1) {
    const description = readString(formData, `line_${index}_description`);
    const qty = negative(readString(formData, `line_${index}_qty`));
    const amount = negative(readString(formData, `line_${index}_amount_gbp`));

    if (!description && qty === 0 && amount === 0) continue;

    totalQtyAbs += Math.abs(qty);
    totalAmountAbs += Math.abs(amount);
    lines.push(`  - ${description || "Refund evidence line"} | qty ${qty} | amount_gbp ${amount.toFixed(2)}`);
  }

  return { lines, totalAmountAbs, totalQtyAbs };
}

export async function saveRetailerUpdateAction(formData: FormData) {
  const disputeId = readString(formData, "dispute_id");
  const outcome = readString(formData, "retailer_outcome");
  const response = readString(formData, "retailer_response");

  if (!disputeId) redirect("/importer");
  if (!OUTCOME_TO_STATUS[outcome]) redirectWithResult(disputeId, { error: "Invalid retailer outcome selection." });

  const guard = await requireActiveOperator();
  if (!guard.ok) redirectWithResult(disputeId, { error: guard.error });

  const accessGuard = await requireDisputeAccess(guard.supabase, guard.operatorId, disputeId);
  if (!accessGuard.ok) redirectWithResult(disputeId, { error: accessGuard.error });

  const { data, error } = await guard.supabase.rpc("operator_update_dispute_retailer_update", {
    p_dispute_id: disputeId,
    p_retailer_response: response,
    p_retailer_outcome: outcome,
  });

  if (error) redirectWithResult(disputeId, { error: error.message });
  if (!data?.ok) redirectWithResult(disputeId, { error: "Failed to save retailer update." });

  revalidatePath(`/importer/exceptions/${disputeId}`);
  revalidatePath(`/internal/exceptions/${disputeId}`);
  redirectWithResult(disputeId, { success: "Retailer update saved." });
}

export async function uploadReturnCollectionEvidenceAction(formData: FormData) {
  const disputeId = readString(formData, "dispute_id");
  const returnRequired = readString(formData, "return_required") || "unknown";
  const collectionDate = readString(formData, "collection_date");
  const returnTrackingRef = readString(formData, "return_tracking_ref");
  const notes = readString(formData, "return_notes");
  const returnLabelFile = readFile(formData, "return_label_file");
  const returnProofFile = readFile(formData, "return_proof_file");
  const retailerInstructionsFile = readFile(formData, "retailer_return_instructions_file");

  if (!disputeId) redirect("/importer");
  if (returnRequired === "unknown" && !collectionDate && !returnTrackingRef && !notes && !returnLabelFile && !returnProofFile && !retailerInstructionsFile) {
    redirectWithResult(disputeId, { error: "Add return/collection details, tracking, a file, or notes before saving." });
  }

  const guard = await requireActiveOperator();
  if (!guard.ok) redirectWithResult(disputeId, { error: guard.error });

  const accessGuard = await requireDisputeAccess(guard.supabase, guard.operatorId, disputeId);
  if (!accessGuard.ok) redirectWithResult(disputeId, { error: accessGuard.error });

  if (accessGuard.dispute.desired_outcome !== "refund") {
    redirectWithResult(disputeId, { error: "Return/collection evidence currently belongs to refund exceptions only." });
  }

  if (accessGuard.dispute.status !== "awaiting_refund_credit") {
    redirectWithResult(disputeId, { error: "Supervisor must accept the final retailer refund outcome before return/collection evidence is uploaded." });
  }

  try {
    const returnLabelFileUrl = await uploadEvidenceFile(guard.supabase, disputeId, "exception-return-labels", returnLabelFile);
    const returnProofFileUrl = await uploadEvidenceFile(guard.supabase, disputeId, "exception-return-proofs", returnProofFile);
    const retailerInstructionsFileUrl = await uploadEvidenceFile(
      guard.supabase,
      disputeId,
      "exception-return-instructions",
      retailerInstructionsFile,
    );

    const body = [
      "[RETURN_COLLECTION_EVIDENCE_V1]",
      "uploaded_by: operator",
      `operator_id: ${guard.operatorId}`,
      `dispute_id: ${disputeId}`,
      `return_required: ${returnRequired}`,
      `collection_date: ${collectionDate || "—"}`,
      `return_tracking_ref: ${returnTrackingRef || "—"}`,
      `return_label_file_url: ${returnLabelFileUrl || "—"}`,
      `return_proof_file_url: ${returnProofFileUrl || "—"}`,
      `retailer_return_instructions_file_url: ${retailerInstructionsFileUrl || "—"}`,
      "",
      notes || "No extra notes.",
    ].join("\n");

    const { error } = await guard.supabase.from("dispute_messages").insert({
      dispute_id: disputeId,
      message_type: "return_collection_evidence",
      counterparty: "retailer",
      body,
      generated_by: "operator_upload",
    });

    if (error) redirectWithResult(disputeId, { error: error.message });
  } catch (error) {
    redirectWithResult(disputeId, { error: error instanceof Error ? error.message : "Failed to upload return/collection evidence." });
  }

  revalidatePath(`/importer/exceptions/${disputeId}`);
  revalidatePath(`/internal/exceptions/${disputeId}`);
  redirectWithResult(disputeId, { success: "Return/collection evidence saved. Credit note/refund evidence can be added later." });
}

export async function uploadOperatorCreditNoteEvidenceAction(formData: FormData) {
  const disputeId = readString(formData, "dispute_id");
  const originalOrderId = readString(formData, "original_order_id");
  const originalSupplierInvoiceId = readString(formData, "original_supplier_invoice_id");
  const originalSupplierInvoiceRef = readString(formData, "original_supplier_invoice_ref");
  const documentMode = readString(formData, "document_mode") || "credit_note";
  const creditNoteRef = readString(formData, "credit_note_ref");
  const creditNoteDate = readString(formData, "credit_note_date");
  const expectedCreditNoteTotalGbp = parseNumber(readString(formData, "expected_credit_note_total_gbp"));
  const deliveryAdjustmentGbp = negative(readString(formData, "delivery_adjustment_gbp"));
  const discountAdjustmentGbp = negative(readString(formData, "discount_adjustment_gbp"));
  const notes = readString(formData, "notes");

  if (!disputeId) redirect("/importer");
  if (!originalOrderId || !originalSupplierInvoiceId) redirectWithResult(disputeId, { error: "Original order and supplier invoice link are required." });
  if (!["credit_note", "refund_proof_no_credit_note", "no_document"].includes(documentMode)) {
    redirectWithResult(disputeId, { error: "Invalid refund document mode." });
  }

  const creditNoteFile = readFile(formData, "credit_note_file");
  const refundProofFile = readFile(formData, "refund_proof_file");

  if (documentMode === "credit_note" && !creditNoteRef) redirectWithResult(disputeId, { error: "Credit note reference is required when a credit note exists." });
  if (documentMode === "credit_note" && expectedCreditNoteTotalGbp <= 0) redirectWithResult(disputeId, { error: "Expected credit note total is required when a credit note exists." });
  if (documentMode === "credit_note" && !creditNoteFile) redirectWithResult(disputeId, { error: "Credit note file upload is required when a credit note exists." });
  if (documentMode === "refund_proof_no_credit_note" && !refundProofFile && !notes) {
    redirectWithResult(disputeId, { error: "Upload refund proof or add notes when no credit note was issued." });
  }
  if (documentMode === "no_document" && !notes) redirectWithResult(disputeId, { error: "Add notes explaining why no document was issued." });

  const refundLines = buildRefundEvidenceLines(formData);
  if (documentMode !== "credit_note" && refundLines.lines.length < 1 && deliveryAdjustmentGbp === 0 && discountAdjustmentGbp === 0) {
    redirectWithResult(disputeId, { error: "Confirm at least one prefilled refund line or adjustment." });
  }

  const guard = await requireActiveOperator();
  if (!guard.ok) redirectWithResult(disputeId, { error: guard.error });

  const accessGuard = await requireDisputeAccess(guard.supabase, guard.operatorId, disputeId);
  if (!accessGuard.ok) redirectWithResult(disputeId, { error: accessGuard.error });

  if (accessGuard.dispute.desired_outcome !== "refund") redirectWithResult(disputeId, { error: "Refund evidence belongs to refund exceptions only." });
  if (accessGuard.dispute.status !== "awaiting_refund_credit") {
    redirectWithResult(disputeId, { error: "Supervisor must accept the final retailer refund outcome before refund evidence is uploaded." });
  }
  if (accessGuard.dispute.order_id !== originalOrderId) redirectWithResult(disputeId, { error: "Original order link does not match this dispute." });

  const { data: invoice, error: invoiceError } = await guard.supabase
    .from("supplier_invoices")
    .select("id, invoice_ref")
    .eq("id", originalSupplierInvoiceId)
    .eq("order_id", originalOrderId)
    .maybeSingle();

  if (invoiceError || !invoice) redirectWithResult(disputeId, { error: invoiceError?.message ?? "Supplier invoice is not linked to this dispute order." });

  const expectedAmountAbs = Math.abs(Number(accessGuard.dispute.amount_impact_gbp ?? 0));
  const capturedAmountAbs =
    documentMode === "credit_note"
      ? expectedCreditNoteTotalGbp + Math.abs(deliveryAdjustmentGbp) + Math.abs(discountAdjustmentGbp)
      : refundLines.totalAmountAbs + Math.abs(deliveryAdjustmentGbp) + Math.abs(discountAdjustmentGbp);
  const varianceAbs = Math.abs(capturedAmountAbs - expectedAmountAbs);
  const amountBalanceStatus = varianceAbs <= 0.01 ? "balanced_to_exception" : "variance_supervisor_review_required";
  const evidenceControlStatus =
    documentMode === "credit_note"
      ? "credit_note_uploaded_pending_ocr_compare"
      : documentMode === "no_document"
        ? "no_document_supervisor_review_required"
        : amountBalanceStatus === "balanced_to_exception"
          ? "refund_adjustment_ready_no_credit_note"
          : "variance_supervisor_review_required";
  const supplierReadinessRoute =
    documentMode === "credit_note"
      ? "supplier_credit_note_readiness_pending_ocr"
      : evidenceControlStatus === "refund_adjustment_ready_no_credit_note"
        ? "supplier_refund_adjustment_ready"
        : "supplier_refund_adjustment_review_required";

  try {
    const creditNoteFileUrl = await uploadEvidenceFile(guard.supabase, disputeId, "exception-credit-notes", documentMode === "credit_note" ? creditNoteFile : null);
    const refundProofFileUrl = await uploadEvidenceFile(guard.supabase, disputeId, "exception-refund-proofs", documentMode === "refund_proof_no_credit_note" ? refundProofFile : null);

    const body = [
      "[REFUND_EVIDENCE_V1]",
      "uploaded_by: operator",
      `operator_id: ${guard.operatorId}`,
      `document_mode: ${documentMode}`,
      `original_order_id: ${originalOrderId}`,
      `original_supplier_invoice_id: ${originalSupplierInvoiceId}`,
      `original_supplier_invoice_ref: ${originalSupplierInvoiceRef || invoice.invoice_ref || "—"}`,
      `dispute_id: ${disputeId}`,
      `credit_note_ref: ${creditNoteRef || "—"}`,
      `credit_note_date: ${creditNoteDate || "—"}`,
      `operator_expected_credit_note_total_gbp: ${expectedCreditNoteTotalGbp.toFixed(2)}`,
      `credit_note_file_url: ${creditNoteFileUrl || "—"}`,
      `refund_proof_file_url: ${refundProofFileUrl || "—"}`,
      `ocr_status: ${documentMode === "credit_note" ? "pending_credit_note_ocr_compare" : "not_applicable"}`,
      "refund_evidence_lines:",
      ...(documentMode === "credit_note" ? ["  - OCR to extract credit note lines"] : refundLines.lines.length ? refundLines.lines : ["  - none"]),
      `delivery_adjustment_gbp: ${deliveryAdjustmentGbp.toFixed(2)}`,
      `discount_adjustment_gbp: ${discountAdjustmentGbp.toFixed(2)}`,
      `expected_exception_amount_abs_gbp: ${expectedAmountAbs.toFixed(2)}`,
      `captured_refund_amount_abs_gbp: ${capturedAmountAbs.toFixed(2)}`,
      `variance_abs_gbp: ${varianceAbs.toFixed(2)}`,
      `amount_balance_status: ${amountBalanceStatus}`,
      `evidence_control_status: ${evidenceControlStatus}`,
      `supplier_readiness_route: ${supplierReadinessRoute}`,
      "",
      notes || "No extra notes.",
    ].join("\n");

    const { error } = await guard.supabase.from("dispute_messages").insert({
      dispute_id: disputeId,
      message_type: documentMode === "credit_note" ? "credit_note_evidence" : "refund_evidence",
      counterparty: "retailer",
      body,
      generated_by: "operator_upload",
    });

    if (error) redirectWithResult(disputeId, { error: error.message });
  } catch (error) {
    redirectWithResult(disputeId, { error: error instanceof Error ? error.message : "Failed to upload refund evidence." });
  }

  revalidatePath(`/importer/exceptions/${disputeId}`);
  revalidatePath(`/internal/exceptions/${disputeId}`);
  revalidatePath(`/internal/supplier-draft-ready`);
  revalidatePath(`/internal/dva-reconciliation/exception-actions`);
  revalidatePath(`/internal/status-control/pre-sage-financial-readiness`);
  redirectWithResult(disputeId, { success: "Refund evidence uploaded and routed to supplier readiness control." });
}
