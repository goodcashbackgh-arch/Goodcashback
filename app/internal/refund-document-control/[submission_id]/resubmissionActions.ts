"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

function asString(value: FormDataEntryValue | null) {
  return typeof value === "string" ? value : "";
}

function redirectBack(submissionId: string, params: Record<string, string>): never {
  const query = new URLSearchParams(params);
  redirect(`/internal/refund-document-control/${submissionId}/request-resubmission?${query.toString()}`);
}

export async function requestRefundDocumentResubmissionAction(formData: FormData) {
  const submissionId = asString(formData.get("refund_evidence_submission_id"));
  const reason = asString(formData.get("resubmission_reason"));

  if (!submissionId) redirect("/internal/supplier-draft-ready?error=Missing+refund+evidence+submission");
  if (!reason.trim()) redirectBack(submissionId, { error: "Resubmission reason is required." });

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("staff_request_refund_document_resubmission", {
    p_refund_evidence_submission_id: submissionId,
    p_reason: reason,
  });

  if (error) redirectBack(submissionId, { error: error.message });
  if (!data?.ok) redirectBack(submissionId, { error: "Failed to request refund document resubmission." });

  revalidatePath(`/internal/refund-document-control/${submissionId}`);
  revalidatePath(`/internal/refund-document-control/${submissionId}/request-resubmission`);
  revalidatePath("/internal/supplier-draft-ready");
  revalidatePath("/internal/exceptions");
  if (data.dispute_id) revalidatePath(`/internal/exceptions/${data.dispute_id}`);

  redirect(`/internal/refund-document-control/${submissionId}?success=${encodeURIComponent("Refund document rejected and resubmission requested from operator.")}`);
}
