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

  if (!user) {
    return { supabase, ok: false as const, error: "Please sign in again." };
  }

  const { data: operator } = await supabase
    .from("operators")
    .select("id")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!operator) {
    return { supabase, ok: false as const, error: "Active operator account not found." };
  }

  return { supabase, ok: true as const, operatorId: operator.id };
}

async function requireDisputeAccess(supabase: Awaited<ReturnType<typeof createClient>>, operatorId: string, disputeId: string) {
  const { data: dispute, error: disputeError } = await supabase
    .from("disputes")
    .select("id, order_id, desired_outcome, status, refund_approved_at")
    .eq("id", disputeId)
    .maybeSingle();

  if (disputeError || !dispute) {
    return { ok: false as const, error: "Dispute not found." };
  }

  const { data: order, error: orderError } = await supabase
    .from("orders")
    .select("id, importer_id")
    .eq("id", dispute.order_id)
    .maybeSingle();

  if (orderError || !order?.importer_id) {
    return { ok: false as const, error: "Dispute order importer could not be resolved." };
  }

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

function optionalLine(label: string, value: string) {
  return value ? `${label}: ${value}` : `${label}: —`;
}

async function uploadEvidenceFile(
  supabase: Awaited<ReturnType<typeof createClient>>,
  disputeId: string,
  folder: string,
  file: File | null,
) {
  if (!file) return "";

  const objectPath = `${folder}/${disputeId}/${Date.now()}-${safeFilename(file.name)}`;
  const { error } = await supabase.storage
    .from(INVOICE_EVIDENCE_BUCKET)
    .upload(objectPath, file, { upsert: false });

  if (error) throw new Error(error.message);

  const { data } = supabase.storage.from(INVOICE_EVIDENCE_BUCKET).getPublicUrl(objectPath);
  return data.publicUrl || objectPath;
}

function buildCreditNoteLines(formData: FormData) {
  const lines: string[] = [];

  for (let index = 1; index <= 5; index += 1) {
    const description = readString(formData, `line_${index}_description`);
    const qty = negative(readString(formData, `line_${index}_qty`));
    const amount = negative(readString(formData, `line_${index}_amount_gbp`));

    if (!description && qty === 0 && amount === 0) continue;

    lines.push(`  - ${description || "Credit note line"} | qty ${qty} | amount_gbp ${amount.toFixed(2)}`);
  }

  return lines;
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

export async function uploadOperatorCreditNoteEvidenceAction(formData: FormData) {
  const disputeId = readString(formData, "dispute_id");
  const originalOrderId = readString(formData, "original_order_id");
  const originalSupplierInvoiceId = readString(formData, "original_supplier_invoice_id");
  const originalSupplierInvoiceRef = readString(formData, "original_supplier_invoice_ref");
  const creditNoteRef = readString(formData, "credit_note_ref");
  const creditNoteDate = readString(formData, "credit_note_date");
  const returnRequired = readString(formData, "return_required") || "unknown";
  const collectionDate = readString(formData, "collection_date");
  const returnTrackingRef = readString(formData, "return_tracking_ref");
  const deliveryAdjustmentGbp = negative(readString(formData, "delivery_adjustment_gbp"));
  const discountAdjustmentGbp = negative(readString(formData, "discount_adjustment_gbp"));
  const notes = readString(formData, "notes");

  if (!disputeId) redirect("/importer");
  if (!originalOrderId || !originalSupplierInvoiceId) redirectWithResult(disputeId, { error: "Original order and supplier invoice link are required." });
  if (!creditNoteRef) redirectWithResult(disputeId, { error: "Credit note reference is required." });

  const creditNoteFile = readFile(formData, "credit_note_file");
  if (!creditNoteFile) redirectWithResult(disputeId, { error: "Credit note file upload is required." });

  const creditNoteLines = buildCreditNoteLines(formData);
  if (creditNoteLines.length < 1 && deliveryAdjustmentGbp === 0 && discountAdjustmentGbp === 0) {
    redirectWithResult(disputeId, { error: "Add at least one credit-note line or adjustment." });
  }

  const guard = await requireActiveOperator();
  if (!guard.ok) redirectWithResult(disputeId, { error: guard.error });

  const accessGuard = await requireDisputeAccess(guard.supabase, guard.operatorId, disputeId);
  if (!accessGuard.ok) redirectWithResult(disputeId, { error: accessGuard.error });

  if (accessGuard.dispute.desired_outcome !== "refund") {
    redirectWithResult(disputeId, { error: "Credit-note evidence belongs to refund exceptions only." });
  }

  if (!accessGuard.dispute.refund_approved_at && accessGuard.dispute.status !== "awaiting_refund_credit") {
    redirectWithResult(disputeId, { error: "Supervisor approval/push is required before uploading credit-note evidence." });
  }

  if (accessGuard.dispute.order_id !== originalOrderId) {
    redirectWithResult(disputeId, { error: "Original order link does not match this dispute." });
  }

  const { data: invoice, error: invoiceError } = await guard.supabase
    .from("supplier_invoices")
    .select("id, invoice_ref")
    .eq("id", originalSupplierInvoiceId)
    .eq("order_id", originalOrderId)
    .maybeSingle();

  if (invoiceError || !invoice) {
    redirectWithResult(disputeId, { error: invoiceError?.message ?? "Supplier invoice is not linked to this dispute order." });
  }

  try {
    const creditNoteFileUrl = await uploadEvidenceFile(guard.supabase, disputeId, "exception-credit-notes", creditNoteFile);
    const returnLabelFileUrl = await uploadEvidenceFile(
      guard.supabase,
      disputeId,
      "exception-return-labels",
      readFile(formData, "return_label_file"),
    );
    const returnProofFileUrl = await uploadEvidenceFile(
      guard.supabase,
      disputeId,
      "exception-return-proofs",
      readFile(formData, "return_proof_file"),
    );

    const body = [
      "[CREDIT_NOTE_EVIDENCE_V1]",
      "uploaded_by: operator",
      `operator_id: ${guard.operatorId}`,
      `original_order_id: ${originalOrderId}`,
      `original_supplier_invoice_id: ${originalSupplierInvoiceId}`,
      `original_supplier_invoice_ref: ${originalSupplierInvoiceRef || invoice.invoice_ref || "—"}`,
      `dispute_id: ${disputeId}`,
      `credit_note_ref: ${creditNoteRef}`,
      `credit_note_date: ${creditNoteDate || "—"}`,
      `credit_note_file_url: ${creditNoteFileUrl}`,
      "credit_note_lines:",
      ...(creditNoteLines.length ? creditNoteLines : ["  - none"]),
      `delivery_adjustment_gbp: ${deliveryAdjustmentGbp.toFixed(2)}`,
      `discount_adjustment_gbp: ${discountAdjustmentGbp.toFixed(2)}`,
      `return_required: ${returnRequired}`,
      optionalLine("collection_date", collectionDate),
      optionalLine("return_tracking_ref", returnTrackingRef),
      optionalLine("return_label_file_url", returnLabelFileUrl),
      optionalLine("return_proof_file_url", returnProofFileUrl),
      "",
      notes || "No extra notes.",
    ].join("\n");

    const { error } = await guard.supabase.from("dispute_messages").insert({
      dispute_id: disputeId,
      message_type: "credit_note_evidence",
      counterparty: "retailer",
      body,
      generated_by: "operator_upload",
    });

    if (error) redirectWithResult(disputeId, { error: error.message });
  } catch (error) {
    redirectWithResult(disputeId, { error: error instanceof Error ? error.message : "Failed to upload credit-note evidence." });
  }

  revalidatePath(`/importer/exceptions/${disputeId}`);
  revalidatePath(`/internal/exceptions/${disputeId}`);
  revalidatePath(`/internal/dva-reconciliation/exception-actions`);
  revalidatePath(`/internal/status-control/pre-sage-financial-readiness`);
  redirectWithResult(disputeId, { success: "Credit-note evidence uploaded for supervisor review." });
}
