"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

export async function reviewPodEvidenceDocumentAction(formData: FormData) {
  const supabase = await createClient();
  const shipmentBatchId = readString(formData, "shipment_batch_id");
  const documentId = readString(formData, "document_id");
  const reviewStatus = readString(formData, "review_status");
  const reviewNotes = readString(formData, "review_notes") || null;

  if (!shipmentBatchId) redirect("/internal/shipping-control?error=Missing%20shipment%20batch%20id.");
  if (!documentId) redirect(`/internal/export-evidence/pod/${shipmentBatchId}?error=${encodeURIComponent("Missing POD / delivery evidence document.")}`);

  const { error } = await (supabase as any).rpc("internal_review_final_export_evidence_document_v1", {
    p_document_id: documentId,
    p_review_status: reviewStatus,
    p_review_notes: reviewNotes,
  });

  if (error) {
    redirect(`/internal/export-evidence/pod/${shipmentBatchId}?error=${encodeURIComponent(error.message)}`);
  }

  revalidatePath(`/internal/export-evidence/pod/${shipmentBatchId}`);
  revalidatePath(`/internal/export-evidence/final/${shipmentBatchId}`);
  revalidatePath(`/internal/export-evidence/draft/${shipmentBatchId}`);
  revalidatePath("/internal/shipping-control");
  redirect(`/internal/export-evidence/pod/${shipmentBatchId}?success=${encodeURIComponent("POD / delivery evidence reviewed")}`);
}
