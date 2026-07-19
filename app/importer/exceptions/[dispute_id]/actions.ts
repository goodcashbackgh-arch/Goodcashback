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

type RefundEvidenceLine = {
  description: string;
  qty: number;
  amount_gbp: number;
};

type RefundLineBuild = {
  lines: RefundEvidenceLine[];
  totalAmountAbs: number;
  totalQtyAbs: number;
};

function buildRefundEvidenceLines(formData: FormData): RefundLineBuild {
  const lines: RefundEvidenceLine[] = [];
  let totalAmountAbs = 0;
  let totalQtyAbs = 0;

  for (let index = 1; index <= 5; index += 1) {
    const description = readString(formData, `line_${index}_description`);
    const qtyAbs = Math.abs(parseNumber(readString(formData, `line_${index}_qty`)));
    const amountAbs = Math.abs(parseNumber(readString(formData, `line_${index}_amount_gbp`)));

    if (!description && qtyAbs === 0 && amountAbs === 0) continue;

    totalQtyAbs += qtyAbs;
    totalAmountAbs += amountAbs;
    lines.push({
      description: description || "Refund evidence line",
      qty: qtyAbs,
      amount_gbp: amountAbs,
    });
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
  const courierId = readString(formData, "courier_id");
  const trackingRef = readString(formData, "tracking_ref");
  const trackingDate = readString(formData, "tracking_date");
  const trackingEvidenceUrl = readString(formData, "tracking_evidence_url");
  const note = readString(formData, "note");
  const isFinalReturn = readString(formData, "is_final_return_yn") === "on";
  const retailerInstructionsFile = readFile(formData, "retailer_return_instructions_file");
  const returnLabelFile = readFile(formData, "return_label_file");
  const returnProofFile = readFile(formData, "return_proof_file");

  if (!disputeId) redirect("/importer");
  if (!courierId && !trackingRef && !trackingDate && !trackingEvidenceUrl && !note && !retailerInstructionsFile && !returnLabelFile && !returnProofFile) {
    redirectWithResult(disputeId, { error: "Add tracking details, a URL, a file, or a note before saving return evidence." });
  }

  if (isFinalReturn && (!courierId || !trackingRef || !trackingDate)) {
    redirectWithResult(disputeId, { error: "Final return/collection requires courier, tracking ref and tracking date." });
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

  let saveError = "";

  try {
    const retailerInstructionsFileUrl = await uploadEvidenceFile(guard.supabase, disputeId, "exception-return-instructions", retailerInstructionsFile);
    const returnLabelFileUrl = await uploadEvidenceFile(guard.supabase, disputeId, "exception-return-labels", returnLabelFile);
    const returnProofFileUrl = await uploadEvidenceFile(guard.supabase, disputeId, "exception-return-proofs", returnProofFile);

    const { data, error } = await guard.supabase.rpc("operator_submit_return_collection_tracking", {
      p_dispute_id: disputeId,
      p_courier_id: courierId || null,
      p_tracking_ref: trackingRef || null,
      p_tracking_date: trackingDate || null,
      p_tracking_evidence_url: trackingEvidenceUrl || null,
      p_is_final_return_yn: isFinalReturn,
      p_retailer_return_instructions_file_url: retailerInstructionsFileUrl || null,
      p_return_label_file_url: returnLabelFileUrl || null,
      p_return_proof_file_url: returnProofFileUrl || null,
      p_note: note || null,
    });

    if (error) saveError = error.message;
    if (!error && !data?.ok) saveError = "Failed to save return/collection tracking.";
  } catch (error) {
    saveError = error instanceof Error ? error.message : "Failed to upload return/collection tracking.";
  }

  if (saveError) {
    redirectWithResult(disputeId, { error: saveError });
  }

  revalidatePath(`/importer/exceptions/${disputeId}`);
  revalidatePath(`/internal/exceptions/${disputeId}`);
  redirectWithResult(disputeId, { success: "Return/collection evidence saved. Credit note/refund evidence can be added later." });
}

export async function uploadOperatorCreditNoteEvidenceAction(formData: FormData) {
  const disputeId = readString(formData, "dispute_id");
  const originalOrderId = readString(formData, "original_order_id");
  const originalSupplierInvoiceId = readString(formData, "original_supplier_invoice_id");
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
  if (documentMode === "credit_note" && !creditNoteDate) redirectWithResult(disputeId, { error: "Credit note date is required when a credit note exists." });
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

  let saveError = "";

  try {
    const creditNoteFileUrl = await uploadEvidenceFile(guard.supabase, disputeId, "exception-credit-notes", documentMode === "credit_note" ? creditNoteFile : null);
    const refundProofFileUrl = await uploadEvidenceFile(guard.supabase, disputeId, "exception-refund-proofs", documentMode === "refund_proof_no_credit_note" ? refundProofFile : null);

    const { data, error } = await guard.supabase.rpc("operator_submit_refund_document_evidence", {
      p_dispute_id: disputeId,
      p_original_order_id: originalOrderId,
      p_original_supplier_invoice_id: originalSupplierInvoiceId,
      p_document_mode: documentMode,
      p_credit_note_ref: creditNoteRef || null,
      p_credit_note_date: creditNoteDate || null,
      p_expected_credit_note_total_gbp: documentMode === "credit_note" ? expectedCreditNoteTotalGbp : null,
      p_credit_note_file_url: creditNoteFileUrl || null,
      p_refund_proof_file_url: refundProofFileUrl || null,
      p_refund_lines: refundLines.lines,
      p_delivery_adjustment_gbp: deliveryAdjustmentGbp,
      p_discount_adjustment_gbp: discountAdjustmentGbp,
      p_notes: notes || null,
    });

    if (error) saveError = error.message;
    if (!error && !data?.ok) saveError = "Failed to save refund document evidence.";
  } catch (error) {
    saveError = error instanceof Error ? error.message : "Failed to upload refund document evidence.";
  }

  if (saveError) {
    redirectWithResult(disputeId, { error: saveError });
  }

  revalidatePath(`/importer/exceptions/${disputeId}`);
  revalidatePath(`/internal/exceptions/${disputeId}`);
  revalidatePath("/internal/refund-document-control");
  revalidatePath("/internal/supplier-draft-ready");
  revalidatePath("/internal/dva-reconciliation/exception-actions");
  revalidatePath("/internal/status-control/pre-sage-financial-readiness");
  redirectWithResult(disputeId, { success: "Refund document evidence saved and routed to supplier credit control." });
}
