"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

const EVIDENCE_BUCKET = "invoice-evidence";

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

function readNullableNumber(formData: FormData, key: string) {
  const value = readString(formData, key);
  if (!value) return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function safeExt(fileName: string) {
  const ext = fileName.includes(".") ? fileName.split(".").pop() : "bin";
  return (ext ?? "bin").toLowerCase().replace(/[^a-z0-9]/g, "") || "bin";
}

function returnActionsRedirect(params: { message: string; type: "success" | "error"; status?: string; returnTrackingSubmissionId?: string }) {
  const query = new URLSearchParams();
  if (params.status) query.set("status", params.status);
  query.set(params.type, params.message);
  return `/shipper/return-actions?${query.toString()}${params.returnTrackingSubmissionId ? `#return-action-${params.returnTrackingSubmissionId}` : ""}`;
}

async function uploadReceiptEvidence(params: {
  supabase: Awaited<ReturnType<typeof createClient>>;
  trackingSubmissionId: string;
  file: File;
}) {
  const objectPath = `shipper-receipts/${params.trackingSubmissionId}/${Date.now()}.${safeExt(params.file.name)}`;
  const { error } = await params.supabase.storage
    .from(EVIDENCE_BUCKET)
    .upload(objectPath, params.file, { upsert: false });

  if (error) {
    throw new Error(`Receipt evidence upload failed. Ensure bucket '${EVIDENCE_BUCKET}' exists and is writable. ${error.message}`);
  }

  const { data } = params.supabase.storage.from(EVIDENCE_BUCKET).getPublicUrl(objectPath);
  return data.publicUrl || objectPath;
}

async function uploadShippingDocument(params: {
  supabase: Awaited<ReturnType<typeof createClient>>;
  shipmentBatchId: string;
  documentKind: string;
  file: File;
}) {
  const objectPath = `shipper-shipping-documents/${params.shipmentBatchId}/${params.documentKind}/${Date.now()}.${safeExt(params.file.name)}`;
  const { error } = await params.supabase.storage
    .from(EVIDENCE_BUCKET)
    .upload(objectPath, params.file, { upsert: false });

  if (error) {
    throw new Error(`Shipping document upload failed. Ensure bucket '${EVIDENCE_BUCKET}' exists and is writable. ${error.message}`);
  }

  const { data } = params.supabase.storage.from(EVIDENCE_BUCKET).getPublicUrl(objectPath);
  return data.publicUrl || objectPath;
}

async function uploadReturnTaskProof(params: {
  supabase: Awaited<ReturnType<typeof createClient>>;
  returnTrackingSubmissionId: string;
  file: File;
}) {
  const objectPath = `shipper-return-proofs/${params.returnTrackingSubmissionId}/${Date.now()}.${safeExt(params.file.name)}`;
  const { error } = await params.supabase.storage
    .from(EVIDENCE_BUCKET)
    .upload(objectPath, params.file, { upsert: false });

  if (error) {
    throw new Error(`Return proof upload failed. Ensure bucket '${EVIDENCE_BUCKET}' exists and is writable. ${error.message}`);
  }

  const { data } = params.supabase.storage.from(EVIDENCE_BUCKET).getPublicUrl(objectPath);
  return data.publicUrl || objectPath;
}

export async function recordPackageReceiptAction(formData: FormData) {
  const supabase = await createClient();
  const trackingSubmissionId = readString(formData, "tracking_submission_id");
  const receiptStatus = readString(formData, "receipt_status");
  const conditionNote = readString(formData, "condition_note");
  const evidenceUrlInput = readString(formData, "evidence_url");
  const evidenceFile = formData.get("receipt_evidence_file");

  if (!trackingSubmissionId) {
    redirect("/shipper?error=Missing%20tracking%20package%20reference.");
  }

  if (!["received_clean", "received_damaged", "held_query", "not_received"].includes(receiptStatus)) {
    redirect("/shipper?error=Choose%20a%20valid%20package%20receipt%20status.");
  }

  let evidenceUrl = evidenceUrlInput || null;
  if (evidenceFile instanceof File && evidenceFile.size > 0) {
    try {
      evidenceUrl = await uploadReceiptEvidence({
        supabase,
        trackingSubmissionId,
        file: evidenceFile,
      });
    } catch (error) {
      redirect(`/shipper/package-receipts?tracking=${encodeURIComponent(trackingSubmissionId)}&error=${encodeURIComponent(error instanceof Error ? error.message : "Receipt evidence upload failed")}`);
    }
  }

  const { error } = await (supabase as any).rpc("shipper_record_package_receipt_v1", {
    p_tracking_submission_id: trackingSubmissionId,
    p_receipt_status: receiptStatus,
    p_condition_note: conditionNote || null,
    p_evidence_url: evidenceUrl || null,
  });

  if (error) {
    redirect(`/shipper/package-receipts?tracking=${encodeURIComponent(trackingSubmissionId)}&error=${encodeURIComponent(error.message)}`);
  }

  revalidatePath("/shipper");
  revalidatePath("/shipper/package-receipts");
  redirect("/shipper?success=Package%20receipt%20recorded.");
}

export async function submitReturnTaskConfirmationAction(formData: FormData) {
  const supabase = await createClient();
  const returnTrackingSubmissionId = readString(formData, "return_tracking_submission_id");
  const outcome = readString(formData, "outcome");
  const proofUrlInput = readString(formData, "proof_url");
  const note = readString(formData, "note");
  const proofFile = formData.get("proof_file");

  if (!returnTrackingSubmissionId) {
    redirect(returnActionsRedirect({ type: "error", message: "Missing return task." }));
  }

  if (!["collected", "handed_to_courier", "returned_to_retailer", "unable_to_return", "query"].includes(outcome)) {
    redirect(returnActionsRedirect({ type: "error", message: "Choose a valid return outcome.", returnTrackingSubmissionId }));
  }

  let proofFileUrl = "";
  if (proofFile instanceof File && proofFile.size > 0) {
    try {
      proofFileUrl = await uploadReturnTaskProof({
        supabase,
        returnTrackingSubmissionId,
        file: proofFile,
      });
    } catch (error) {
      redirect(returnActionsRedirect({
        type: "error",
        message: error instanceof Error ? error.message : "Return proof upload failed",
        returnTrackingSubmissionId,
      }));
    }
  }

  const { error } = await (supabase as any).rpc("shipper_submit_return_task_confirmation_v1", {
    p_return_tracking_submission_id: returnTrackingSubmissionId,
    p_outcome: outcome,
    p_proof_file_url: proofFileUrl || null,
    p_proof_url: proofUrlInput || null,
    p_note: note || null,
  });

  if (error) {
    redirect(returnActionsRedirect({
      type: "error",
      message: error.message,
      returnTrackingSubmissionId,
    }));
  }

  revalidatePath("/shipper/return-actions");
  revalidatePath("/shipper/return-tasks");
  revalidatePath("/internal/shipper-return-tasks");
  redirect(returnActionsRedirect({
    type: "success",
    status: "submitted_for_review",
    message: "Return confirmation submitted for supervisor review.",
    returnTrackingSubmissionId,
  }));
}

export async function submitShippingDocumentAction(formData: FormData) {
  const supabase = await createClient();
  const shipmentBatchId = readString(formData, "shipment_batch_id");
  const documentKind = readString(formData, "document_kind");
  const documentRef = readString(formData, "document_ref");
  const documentDate = readString(formData, "document_date") || null;
  const currencyCode = readString(formData, "currency_code") || "GBP";
  const totalAmount = readNullableNumber(formData, "total_amount");
  const notes = readString(formData, "notes") || null;
  const file = formData.get("shipping_document_file");

  if (!shipmentBatchId) redirect("/shipper/shipping-documents/new?error=Choose%20a%20shipment%20batch.");
  if (!["shipper_invoice", "shipper_receipt", "supporting_charge_document"].includes(documentKind)) {
    redirect("/shipper/shipping-documents/new?error=Choose%20a%20valid%20document%20type.");
  }
  if (!(file instanceof File) || file.size === 0) {
    redirect(`/shipper/shipping-documents/new?batch=${encodeURIComponent(shipmentBatchId)}&error=Upload%20the%20shipping%20document%20file.`);
  }

  let fileUrl: string;
  try {
    fileUrl = await uploadShippingDocument({
      supabase,
      shipmentBatchId,
      documentKind,
      file,
    });
  } catch (error) {
    redirect(`/shipper/shipping-documents/new?batch=${encodeURIComponent(shipmentBatchId)}&error=${encodeURIComponent(error instanceof Error ? error.message : "Shipping document upload failed")}`);
  }

  const { error } = await (supabase as any).rpc("shipper_submit_shipping_document_v1", {
    p_shipment_batch_id: shipmentBatchId,
    p_document_kind: documentKind,
    p_document_ref: documentRef || null,
    p_document_date: documentDate,
    p_currency_code: currencyCode,
    p_total_amount: totalAmount,
    p_file_url: fileUrl,
    p_notes: notes,
  });

  if (error) {
    redirect(`/shipper/shipping-documents/new?batch=${encodeURIComponent(shipmentBatchId)}&error=${encodeURIComponent(error.message)}`);
  }

  revalidatePath("/shipper");
  revalidatePath("/shipper/shipping-documents/new");
  revalidatePath("/internal/shipping-control");
  redirect(`/shipper/shipping-documents/new?batch=${encodeURIComponent(shipmentBatchId)}&success=${encodeURIComponent("Shipping document uploaded")}`);
}

export async function requestShippingDocumentResubmissionAction(formData: FormData) {
  const supabase = await createClient();
  const shippingDocumentId = readString(formData, "shipping_document_id");
  const message = readString(formData, "message");

  if (!shippingDocumentId) redirect("/shipper/shipping-documents/new?error=Missing%20shipping%20document.");
  if (!message) redirect("/shipper/shipping-documents/new?error=Enter%20a%20resubmission%20message.");

  const { error } = await (supabase as any).rpc("shipper_request_shipping_document_resubmission_v1", {
    p_shipping_document_id: shippingDocumentId,
    p_message: message,
  });

  if (error) {
    redirect(`/shipper/shipping-documents/new?error=${encodeURIComponent(error.message)}`);
  }

  revalidatePath("/shipper/shipping-documents/new");
  revalidatePath("/internal/shipping-control");
  redirect(`/shipper/shipping-documents/new?success=${encodeURIComponent("Resubmission request sent")}`);
}
