"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

function asString(value: FormDataEntryValue | null) {
  return typeof value === "string" ? value.trim() : "";
}

function asPositiveNumber(value: FormDataEntryValue | null) {
  const parsed = Number(asString(value));
  return Number.isFinite(parsed) && parsed > 0 ? parsed : null;
}

function redirectBack(submissionId: string, params: Record<string, string>): never {
  const query = new URLSearchParams(params);
  redirect(`/internal/refund-document-control/${submissionId}/ocr?${query.toString()}`);
}

export async function correctRefundCreditNoteHeaderAction(formData: FormData) {
  const submissionId = asString(formData.get("refund_evidence_submission_id"));
  const creditNoteRef = asString(formData.get("credit_note_ref"));
  const creditNoteDate = asString(formData.get("credit_note_date"));
  const expectedTotal = asPositiveNumber(formData.get("expected_credit_note_total_gbp"));
  const ocrCreditNoteRef = asString(formData.get("ocr_credit_note_ref"));
  const ocrRetailerName = asString(formData.get("ocr_retailer_name"));
  const ocrCreditNoteDate = asString(formData.get("ocr_credit_note_date"));
  const ocrTotal = asPositiveNumber(formData.get("ocr_credit_note_total_gbp"));
  const reason = asString(formData.get("correction_reason"));

  if (!submissionId) redirect("/internal/refund-document-control?error=Missing+refund+evidence+submission");
  if (!creditNoteRef) redirectBack(submissionId, { error: "Submitted credit-note reference is required." });
  if (!creditNoteDate) redirectBack(submissionId, { error: "Submitted credit-note date is required." });
  if (expectedTotal === null) redirectBack(submissionId, { error: "Expected credit-note total must be above zero." });
  if (!ocrCreditNoteRef) redirectBack(submissionId, { error: "OCR credit-note reference is required." });
  if (!ocrRetailerName) redirectBack(submissionId, { error: "OCR retailer name is required." });
  if (!ocrCreditNoteDate) redirectBack(submissionId, { error: "OCR credit-note date is required." });
  if (ocrTotal === null) redirectBack(submissionId, { error: "OCR credit-note total must be above zero." });
  if (!reason) redirectBack(submissionId, { error: "A correction reason is required." });

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("staff_correct_refund_credit_note_header_v1", {
    p_refund_evidence_submission_id: submissionId,
    p_credit_note_ref: creditNoteRef,
    p_credit_note_date: creditNoteDate,
    p_expected_credit_note_total_gbp: expectedTotal,
    p_ocr_credit_note_ref: ocrCreditNoteRef,
    p_ocr_retailer_name: ocrRetailerName,
    p_ocr_credit_note_date: ocrCreditNoteDate,
    p_ocr_credit_note_total_gbp: ocrTotal,
    p_reason: reason,
  });

  if (error) redirectBack(submissionId, { error: error.message });
  if (!data?.ok) redirectBack(submissionId, { error: "Credit-note header correction failed." });

  revalidatePath(`/internal/refund-document-control/${submissionId}/ocr`);
  revalidatePath(`/internal/refund-document-control/${submissionId}`);
  revalidatePath("/internal/refund-document-control");
  revalidatePath("/internal/supplier-draft-ready");
  revalidatePath("/internal/status-control/pre-sage-financial-readiness");

  const resultStatus = typeof data.match_status === "string" ? data.match_status : "recalculated";
  redirectBack(submissionId, { success: `Credit-note header corrected. Match status: ${resultStatus}.` });
}
