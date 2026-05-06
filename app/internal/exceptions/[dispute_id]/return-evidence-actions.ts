"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

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

function safeFilename(name: string) {
  return name.replace(/[^a-zA-Z0-9._-]+/g, "-").slice(0, 120) || "upload";
}

async function uploadEvidenceFile(
  supabase: Awaited<ReturnType<typeof createClient>>,
  disputeId: string,
  folder: string,
  file: File | null,
) {
  if (!file) return "";

  const path = `${folder}/${disputeId}/${Date.now()}-${safeFilename(file.name)}`;
  const bytes = await file.arrayBuffer();
  const { error } = await supabase.storage.from("invoice-evidence").upload(path, bytes, {
    contentType: file.type || "application/octet-stream",
    upsert: false,
  });

  if (error) throw new Error(error.message);

  const { data } = supabase.storage.from("invoice-evidence").getPublicUrl(path);
  return data.publicUrl;
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

export async function recordExceptionEvidenceAction(formData: FormData) {
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

  if (!disputeId) redirect("/internal/exceptions");
  if (!originalOrderId || !originalSupplierInvoiceId) {
    redirectWithResult(disputeId, { error: "Original order and supplier invoice link are required." });
  }
  if (!creditNoteRef) redirectWithResult(disputeId, { error: "Credit note reference is required." });

  const creditNoteFile = readFile(formData, "credit_note_file");
  if (!creditNoteFile) redirectWithResult(disputeId, { error: "Credit note file upload is required." });

  const creditNoteLines = buildCreditNoteLines(formData);
  if (creditNoteLines.length < 1 && deliveryAdjustmentGbp === 0 && discountAdjustmentGbp === 0) {
    redirectWithResult(disputeId, { error: "Add at least one negative credit note line or adjustment." });
  }

  const guard = await requireActiveStaff();
  if (!guard.ok) redirectWithResult(disputeId, { error: guard.error });

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
      `original_order_id: ${originalOrderId}`,
      `original_supplier_invoice_id: ${originalSupplierInvoiceId}`,
      `original_supplier_invoice_ref: ${originalSupplierInvoiceRef || "—"}`,
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
      counterparty: "internal",
      body,
      generated_by: "manual",
    });

    if (error) redirectWithResult(disputeId, { error: error.message });
  } catch (error) {
    redirectWithResult(disputeId, { error: error instanceof Error ? error.message : "Failed to upload credit note evidence." });
  }

  revalidatePath(`/internal/exceptions/${disputeId}`);
  revalidatePath(`/importer/exceptions/${disputeId}`);
  revalidatePath(`/internal/dva-reconciliation/exception-actions`);
  revalidatePath(`/internal/status-control/pre-sage-financial-readiness`);
  redirectWithResult(disputeId, { success: "Credit note evidence uploaded." });
}
