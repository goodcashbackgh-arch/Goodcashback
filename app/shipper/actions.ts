"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

export async function recordPackageReceiptAction(formData: FormData) {
  const supabase = await createClient();
  const trackingSubmissionId = readString(formData, "tracking_submission_id");
  const receiptStatus = readString(formData, "receipt_status");
  const conditionNote = readString(formData, "condition_note");
  const evidenceUrl = readString(formData, "evidence_url");

  if (!trackingSubmissionId) {
    redirect("/shipper?error=Missing%20tracking%20package%20reference.");
  }

  if (!["received_clean", "received_damaged", "held_query", "not_received"].includes(receiptStatus)) {
    redirect("/shipper?error=Choose%20a%20valid%20package%20receipt%20status.");
  }

  const { error } = await (supabase as any).rpc("shipper_record_package_receipt_v1", {
    p_tracking_submission_id: trackingSubmissionId,
    p_receipt_status: receiptStatus,
    p_condition_note: conditionNote || null,
    p_evidence_url: evidenceUrl || null,
  });

  if (error) {
    redirect(`/shipper?error=${encodeURIComponent(error.message)}`);
  }

  revalidatePath("/shipper");
  redirect("/shipper?success=Package%20receipt%20recorded.");
}
