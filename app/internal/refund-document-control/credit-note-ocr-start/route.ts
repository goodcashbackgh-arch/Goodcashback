import { NextResponse } from "next/server";
import { createClient } from "@/utils/supabase/server";

const MINDEE_V2_ENQUEUE_URL = "https://api-v2.mindee.net/v2/inferences/enqueue";
const DEFAULT_MINDEE_INVOICE_MODEL_ID = "cd596aec-23b0-4063-bdbe-38c9c8728e84";

type SubmissionRow = {
  id: string;
  document_mode: string | null;
  credit_note_file_url: string | null;
  credit_note_ref: string | null;
  expected_credit_note_total_gbp: string | number | null;
  ocr_status?: string | null;
  mindee_job_id?: string | null;
};

function cleanText(value: unknown) {
  return String(value ?? "").trim();
}

function redirectToSubmission(request: Request, submissionId: string, params: Record<string, string>) {
  const url = new URL(`/internal/refund-document-control/${submissionId}/ocr`, new URL(request.url).origin);
  Object.entries(params).forEach(([key, value]) => url.searchParams.set(key, value));
  return NextResponse.redirect(url, { status: 303 });
}

function isHttpUrl(value: string) {
  return /^https?:\/\//i.test(value);
}

function recordValue(value: unknown) {
  if (value === undefined || value === null || value === "") return null;
  return String(value).trim() || null;
}

function parseMindeeDetail(raw: unknown) {
  if (!raw || typeof raw !== "object") return "";
  const obj = raw as Record<string, unknown>;
  const detail = obj.detail ?? obj.title ?? obj.message ?? obj.error ?? obj.errors;
  if (detail === undefined || detail === null) return "";
  return typeof detail === "string" ? detail.slice(0, 700) : JSON.stringify(detail).slice(0, 700);
}

function extractMindeeJobId(raw: unknown) {
  if (!raw || typeof raw !== "object") return null;
  const obj = raw as Record<string, unknown>;
  const job = obj.job && typeof obj.job === "object" ? obj.job as Record<string, unknown> : null;
  const inference = obj.inference && typeof obj.inference === "object" ? obj.inference as Record<string, unknown> : null;
  const inferenceJob = inference?.job && typeof inference.job === "object" ? inference.job as Record<string, unknown> : null;
  return recordValue(job?.id ?? inferenceJob?.id ?? obj.job_id);
}

function extractMindeeInferenceId(raw: unknown) {
  if (!raw || typeof raw !== "object") return null;
  const obj = raw as Record<string, unknown>;
  const inference = obj.inference && typeof obj.inference === "object" ? obj.inference as Record<string, unknown> : null;
  const job = obj.job && typeof obj.job === "object" ? obj.job as Record<string, unknown> : null;
  return recordValue(inference?.id ?? job?.inference_id ?? obj.inference_id ?? obj.id);
}

function getMindeeKey() {
  return process.env.MINDEE_V2_API_KEY?.trim() || process.env.MINDEE_API_KEY?.trim() || "";
}

function getCreditNoteModelId() {
  return process.env.MINDEE_CREDIT_NOTE_MODEL_ID?.trim() || process.env.MINDEE_INVOICE_MODEL_ID?.trim() || DEFAULT_MINDEE_INVOICE_MODEL_ID;
}

function getCreditNoteWebhookId() {
  return process.env.MINDEE_CREDIT_NOTE_WEBHOOK_ID?.trim() || process.env.MINDEE_INVOICE_WEBHOOK_ID?.trim() || "";
}

export async function POST(request: Request) {
  const formData = await request.formData();
  const submissionId = cleanText(formData.get("refund_evidence_submission_id"));
  if (!submissionId) return NextResponse.redirect(new URL("/internal/refund-document-control?error=Missing+refund+evidence+submission", request.url), { status: 303 });

  const apiKey = getMindeeKey();
  if (!apiKey) return redirectToSubmission(request, submissionId, { error: "MINDEE_V2_API_KEY is not configured." });

  const modelId = getCreditNoteModelId();
  if (!modelId) return redirectToSubmission(request, submissionId, { error: "Mindee credit-note/invoice model id is not configured." });

  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return redirectToSubmission(request, submissionId, { error: "Please sign in again before starting credit-note OCR." });

  const { data: staff } = await supabase.from("staff").select("id, role_type").eq("auth_user_id", user.id).eq("active", true).maybeSingle();
  if (!staff || !["admin", "supervisor"].includes(String(staff.role_type))) return redirectToSubmission(request, submissionId, { error: "Only admin/supervisor staff can start credit-note OCR." });

  const { data: submission, error: submissionError } = await supabase
    .from("dispute_refund_evidence_submissions")
    .select("id, document_mode, credit_note_file_url, credit_note_ref, expected_credit_note_total_gbp, ocr_status, mindee_job_id")
    .eq("id", submissionId)
    .maybeSingle();

  if (submissionError || !submission) return redirectToSubmission(request, submissionId, { error: submissionError?.message ?? "Refund evidence submission not found." });
  const typedSubmission = submission as SubmissionRow;

  if (typedSubmission.document_mode !== "credit_note") return redirectToSubmission(request, submissionId, { error: `OCR start is only for credit-note submissions. Current mode: ${typedSubmission.document_mode ?? "unknown"}.` });
  if (!typedSubmission.credit_note_file_url || !isHttpUrl(typedSubmission.credit_note_file_url)) return redirectToSubmission(request, submissionId, { error: "Credit note file URL is missing or is not a real HTTP URL." });
  if (typedSubmission.mindee_job_id && ["queued", "processing", "completed"].includes(String(typedSubmission.ocr_status))) return redirectToSubmission(request, submissionId, { error: "Credit-note OCR already has a Mindee job. Use safe fetch instead of enqueueing again." });

  const fileResponse = await fetch(typedSubmission.credit_note_file_url, { cache: "no-store" });
  if (!fileResponse.ok) return redirectToSubmission(request, submissionId, { error: `Could not fetch uploaded credit note file for OCR (${fileResponse.status}).` });

  const fileBuffer = await fileResponse.arrayBuffer();
  const contentType = fileResponse.headers.get("content-type") || "application/pdf";
  const mindeeFormData = new FormData();
  mindeeFormData.set("model_id", modelId);

  const webhookId = getCreditNoteWebhookId();
  if (webhookId) mindeeFormData.append("webhook_ids", webhookId);

  mindeeFormData.set("file", new Blob([fileBuffer], { type: contentType }), `credit-note-${submissionId}.pdf`);

  const headers = new Headers();
  headers.set("Authori" + "zation", apiKey);
  headers.set("Accept", "application/json");

  const mindeeResponse = await fetch(MINDEE_V2_ENQUEUE_URL, { method: "POST", headers, body: mindeeFormData });
  const raw = await mindeeResponse.json().catch(() => null);
  const jobId = extractMindeeJobId(raw);
  const inferenceId = extractMindeeInferenceId(raw);

  if (!mindeeResponse.ok || !jobId) {
    return redirectToSubmission(request, submissionId, { error: `Mindee credit-note enqueue failed (${mindeeResponse.status}). ${parseMindeeDetail(raw) || "No detail returned."}` });
  }

  const { error: markError } = await supabase.rpc("staff_start_refund_credit_note_ocr", {
    p_refund_evidence_submission_id: submissionId,
    p_model_id: modelId,
    p_mindee_job_id: jobId,
    p_mindee_inference_id: inferenceId,
    p_http_status: mindeeResponse.status,
  });

  if (markError) return redirectToSubmission(request, submissionId, { error: markError.message });

  return redirectToSubmission(request, submissionId, { success: `Mindee credit-note OCR enqueued. Job: ${jobId}. Wait briefly, then safe fetch result.` });
}
