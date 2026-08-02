"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

const EVIDENCE_BUCKET = "invoice-evidence";

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

function readFile(formData: FormData, key: string) {
  const value = formData.get(key);
  return value instanceof File && value.size > 0 ? value : null;
}

function safeFilename(name: string) {
  return name.replace(/[^a-zA-Z0-9._-]+/g, "-").slice(0, 120) || "upload";
}

function normaliseUrl(value: string) {
  const trimmed = value.trim();
  if (!trimmed) return "";
  return /^https?:\/\//i.test(trimmed) ? trimmed : `https://${trimmed}`;
}

function redirectWithResult(disputeId: string, params: Record<string, string>): never {
  const query = new URLSearchParams(params);
  redirect(`/importer/exceptions/${disputeId}?${query.toString()}`);
}

async function uploadEvidenceFile(
  supabase: Awaited<ReturnType<typeof createClient>>,
  disputeId: string,
  folder: string,
  file: File | null,
) {
  if (!file) return "";

  const objectPath = `${folder}/${disputeId}/${Date.now()}-${safeFilename(file.name)}`;
  const { error } = await supabase.storage.from(EVIDENCE_BUCKET).upload(objectPath, file, { upsert: false });
  if (error) throw new Error(error.message);

  const { data } = supabase.storage.from(EVIDENCE_BUCKET).getPublicUrl(objectPath);
  return data.publicUrl || objectPath;
}

export async function uploadReplacementReturnCollectionAction(formData: FormData) {
  const disputeId = readString(formData, "dispute_id");
  const courierId = readString(formData, "courier_id");
  const trackingRef = readString(formData, "tracking_ref");
  const trackingDate = readString(formData, "tracking_date");
  const trackingEvidenceUrl = normaliseUrl(readString(formData, "tracking_evidence_url"));
  const note = readString(formData, "note");
  const isFinalReturn = readString(formData, "is_final_return_yn") === "on";
  const retailerInstructionsFile = readFile(formData, "retailer_return_instructions_file");
  const returnLabelFile = readFile(formData, "return_label_file");
  const returnProofFile = readFile(formData, "return_proof_file");

  if (!disputeId) redirect("/importer");

  const hasActionableInformation = Boolean(
    trackingRef
      || trackingEvidenceUrl
      || note
      || retailerInstructionsFile
      || returnLabelFile,
  );

  if (!hasActionableInformation) {
    redirectWithResult(disputeId, {
      error: "Add retailer instructions, a return label, a tracking reference, a tracking URL, or a meaningful note.",
    });
  }

  if (isFinalReturn && (!courierId || !trackingRef || !trackingDate)) {
    redirectWithResult(disputeId, {
      error: "Final return/collection requires courier, tracking reference and tracking date.",
    });
  }

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) redirectWithResult(disputeId, { error: "Please sign in again." });

  let saveError = "";

  try {
    const retailerInstructionsFileUrl = await uploadEvidenceFile(
      supabase,
      disputeId,
      "exception-replacement-return-instructions",
      retailerInstructionsFile,
    );
    const returnLabelFileUrl = await uploadEvidenceFile(
      supabase,
      disputeId,
      "exception-replacement-return-labels",
      returnLabelFile,
    );
    const returnProofFileUrl = await uploadEvidenceFile(
      supabase,
      disputeId,
      "exception-replacement-return-proofs",
      returnProofFile,
    );

    const { data, error } = await (supabase as any).rpc(
      "operator_submit_replacement_return_collection_tracking_v1",
      {
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
      },
    );

    if (error) saveError = error.message;
    if (!error && !data?.ok) saveError = "Failed to save replacement original-item return instructions.";
  } catch (error) {
    saveError = error instanceof Error
      ? error.message
      : "Failed to upload replacement original-item return instructions.";
  }

  if (saveError) redirectWithResult(disputeId, { error: saveError });

  revalidatePath(`/importer/exceptions/${disputeId}`);
  revalidatePath(`/internal/exceptions/${disputeId}`);
  revalidatePath("/shipper/return-actions");
  redirectWithResult(disputeId, {
    success: "Original-item return/collection instructions saved for the shipper.",
  });
}
