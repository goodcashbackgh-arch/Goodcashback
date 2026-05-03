import { NextResponse } from "next/server";
import { createClient } from "@/utils/supabase/server";

const MINDEE_V2_ENQUEUE_URL = "https://api-v2.mindee.net/v2/inferences/enqueue";

type Batch = {
  id: string;
  detected_file_type: string;
  source_file_url: string;
  original_filename: string | null;
  status: string;
};

function redirectToImport(request: Request, params: Record<string, string>) {
  const url = new URL("/internal/dva-statement-import", new URL(request.url).origin);
  Object.entries(params).forEach(([key, value]) => url.searchParams.set(key, value));
  return NextResponse.redirect(url, { status: 303 });
}

function cleanText(value: unknown) {
  return String(value ?? "").trim();
}

function enabled(value: string | undefined) {
  return ["1", "true", "yes", "on"].includes(String(value ?? "").trim().toLowerCase());
}

function isHttpUrl(value: string) {
  return /^https?:\/\//i.test(value);
}

function maxPdfPages() {
  const parsed = Number(process.env.MINDEE_STATEMENT_MAX_PAGES || "2");
  return Number.isFinite(parsed) && parsed > 0 ? Math.floor(parsed) : 2;
}

function estimatePdfPageCount(buffer: ArrayBuffer) {
  const text = new TextDecoder("latin1").decode(buffer);
  const matches = text.match(/\/Type\s*\/Page\b/g);
  return matches?.length ?? null;
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

function getStatementModelId() {
  return process.env.MINDEE_STATEMENT_MODEL_ID?.trim() || process.env.MINDEE_DVA_STATEMENT_MODEL_ID?.trim() || "";
}

function getStatementWebhookId() {
  return process.env.MINDEE_STATEMENT_WEBHOOK_ID?.trim() || "";
}

export async function POST(request: Request) {
  const formData = await request.formData();
  const importBatchId = cleanText(formData.get("import_batch_id"));
  if (!importBatchId) return redirectToImport(request, { import_error: "Missing import batch id for Mindee statement OCR." });

  const apiKey = getMindeeKey();
  if (!apiKey) return redirectToImport(request, { import_error: "MINDEE_V2_API_KEY is not configured." });

  const modelId = getStatementModelId();
  if (!modelId) return redirectToImport(request, { import_error: "MINDEE_STATEMENT_MODEL_ID is not configured. Do not use the invoice model for statements." });

  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return redirectToImport(request, { import_error: "Please sign in again before starting statement OCR." });

  const { data: batch, error: batchError } = await supabase
    .from("dva_statement_import_batches")
    .select("id, detected_file_type, source_file_url, original_filename, status")
    .eq("id", importBatchId)
    .maybeSingle();

  if (batchError || !batch) return redirectToImport(request, { import_error: batchError?.message ?? "Statement import batch not found." });
  const typedBatch = batch as Batch;

  if (typedBatch.detected_file_type !== "pdf") {
    return redirectToImport(request, { import_error: "Mindee statement OCR can only be started for PDF batches." });
  }

  if (["committed", "voided", "failed"].includes(String(typedBatch.status))) {
    return redirectToImport(request, { import_error: `Cannot start Mindee OCR for batch in status ${typedBatch.status}. Upload a fresh real PDF batch first.` });
  }

  if (!isHttpUrl(typedBatch.source_file_url)) {
    return redirectToImport(request, { import_error: "This PDF batch has no real uploaded file URL. It is likely a smoke/test batch. Upload a fresh real PDF statement first." });
  }

  const fileResponse = await fetch(typedBatch.source_file_url, { cache: "no-store" });
  if (!fileResponse.ok) {
    return redirectToImport(request, { import_error: `Could not fetch uploaded PDF for OCR (${fileResponse.status}).` });
  }

  const pdfBuffer = await fileResponse.arrayBuffer();
  const estimatedPages = estimatePdfPageCount(pdfBuffer);
  const maxPages = maxPdfPages();

  if (estimatedPages !== null && estimatedPages > maxPages) {
    return redirectToImport(request, {
      import_error: `Mindee OCR blocked before upload: PDF appears to contain ${estimatedPages} page(s), current safety limit is ${maxPages}. Upload a smaller PDF or raise MINDEE_STATEMENT_MAX_PAGES intentionally.`,
      batch_id: importBatchId,
    });
  }

  const mindeeFormData = new FormData();
  mindeeFormData.set("model_id", modelId);

  const rawTextEnabled = enabled(process.env.MINDEE_STATEMENT_RAW_TEXT_ENABLED);
  if (rawTextEnabled) {
    mindeeFormData.set("raw_text", "true");
  }

  const webhookId = getStatementWebhookId();
  if (webhookId) {
    mindeeFormData.append("webhook_ids", webhookId);
  }

  mindeeFormData.set("file", new Blob([pdfBuffer], { type: "application/pdf" }), typedBatch.original_filename || `statement-${importBatchId}.pdf`);

  const headers = new Headers();
  headers.set("Authori" + "zation", apiKey);
  headers.set("Accept", "application/json");

  const mindeeResponse = await fetch(MINDEE_V2_ENQUEUE_URL, {
    method: "POST",
    headers,
    body: mindeeFormData,
  });

  const raw = await mindeeResponse.json().catch(() => null);
  const jobId = extractMindeeJobId(raw);
  const inferenceId = extractMindeeInferenceId(raw);

  if (!mindeeResponse.ok || !jobId) {
    await supabase.rpc("staff_save_dva_statement_import_mindee_result", {
      p_import_batch_id: importBatchId,
      p_mindee_inference_id: inferenceId,
      p_ocr_status: "failed",
      p_raw_json: raw ?? { empty_response: true },
      p_pages_consumed: null,
      p_http_status: mindeeResponse.status,
      p_error_message: parseMindeeDetail(raw) || "Mindee statement enqueue failed or returned no job id.",
    });
    return redirectToImport(request, { import_error: `Mindee statement enqueue failed (${mindeeResponse.status}). ${parseMindeeDetail(raw) || "No detail returned."}` });
  }

  const { error: markError } = await supabase.rpc("staff_mark_dva_statement_import_mindee_enqueued", {
    p_import_batch_id: importBatchId,
    p_mindee_job_id: jobId,
    p_mindee_inference_id: inferenceId,
    p_mindee_model_id: modelId,
    p_http_status: mindeeResponse.status,
  });

  if (markError) return redirectToImport(request, { import_error: markError.message });

  return redirectToImport(request, {
    import_success: `Mindee statement OCR enqueued${rawTextEnabled ? " with raw text requested" : ""}. Estimated pages: ${estimatedPages ?? "unknown"}. Job: ${jobId}. Wait briefly, then fetch OCR result.`,
    batch_id: importBatchId,
  });
}
