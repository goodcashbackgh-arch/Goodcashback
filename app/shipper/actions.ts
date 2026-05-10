"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

const EVIDENCE_BUCKET = "invoice-evidence";

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

function safeExt(fileName: string) {
  const ext = fileName.includes(".") ? fileName.split(".").pop() : "bin";
  return (ext ?? "bin").toLowerCase().replace(/[^a-z0-9]/g, "") || "bin";
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
