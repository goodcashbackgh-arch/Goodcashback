import { NextResponse } from "next/server";
import { createClient } from "@/utils/supabase/server";

const MINDEE_V2_API_BASE = "https://api-v2.mindee.net/v2";

type Batch = {
  id: string;
  mindee_statement_job_id: string | null;
  mindee_statement_model_id: string | null;
  mindee_statement_raw_json: unknown;
};

function redirectToImport(request: Request, params: Record<string, string>) {
  const url = new URL("/internal/dva-statement-import/mindee-control", new URL(request.url).origin);
  Object.entries(params).forEach(([key, value]) => url.searchParams.set(key, value));
  return NextResponse.redirect(url, { status: 303 });
}

function cleanText(value: unknown) {
  return String(value ?? "").trim();
}

function recordValue(value: unknown) {
  if (value === undefined || value === null || value === "") return null;
  return String(value).trim() || null;
}

function numberValue(value: unknown) {
  if (value === undefined || value === null || value === "") return null;
  const n = Number(value);
  return Number.isFinite(n) ? Math.round(n) : null;
}

function getByPath(root: unknown, path: string[]) {
  let current = root;
  for (const key of path) {
    if (!current || typeof current !== "object") return null;
    current = (current as Record<string, unknown>)[key];
  }
  return current ?? null;
}

function parseMindeeDetail(raw: unknown) {
  if (!raw || typeof raw !== "object") return "";
  const obj = raw as Record<string, unknown>;
  const detail = obj.detail ?? obj.title ?? obj.message ?? obj.error ?? obj.errors;
  if (detail === undefined || detail === null) return "";
  return typeof detail === "string" ? detail.slice(0, 700) : JSON.stringify(detail).slice(0, 700);
}

function extractMindeeInferenceId(raw: unknown) {
  if (!raw || typeof raw !== "object") return null;
  const obj = raw as Record<string, unknown>;
  const inference = obj.inference && typeof obj.inference === "object" ? obj.inference as Record<string, unknown> : null;
  return recordValue(inference?.id ?? obj.inference_id ?? obj.id);
}

function extractJobStatus(raw: unknown) {
  if (!raw || typeof raw !== "object") return null;
  const obj = raw as Record<string, unknown>;
  const job = obj.job && typeof obj.job === "object" ? obj.job as Record<string, unknown> : null;
  return recordValue(job?.status ?? obj.status);
}

function toDbOcrStatus(status: string | null) {
  const normal = String(status ?? "").toLowerCase();
  if (["completed", "complete", "processed", "done", "success", "succeeded"].includes(normal)) return "completed";
  if (["failed", "error", "errored"].includes(normal)) return "failed";
  if (["cancelled", "canceled"].includes(normal)) return "cancelled";
  if (["queued", "created", "waiting"].includes(normal)) return "queued";
  return "processing";
}

function hasInferencePayload(raw: unknown) {
  return Boolean(getByPath(raw, ["inference", "result"]));
}

function extractPagesConsumed(raw: unknown) {
  for (const path of [["inference", "file", "page_count"], ["inference", "file", "pages"], ["file", "page_count"], ["file", "pages"], ["document", "n_pages"]]) {
    const n = numberValue(getByPath(raw, path));
    if (n !== null) return Math.max(0, n);
  }
  return null;
}

function getMindeeKey() {
  return process.env.MINDEE_V2_API_KEY?.trim() || process.env.MINDEE_API_KEY?.trim() || "";
}

export async function POST(request: Request) {
  const formData = await request.formData();
  const importBatchId = cleanText(formData.get("import_batch_id"));
  if (!importBatchId) return redirectToImport(request, { import_error: "Missing import batch id for Mindee fetch." });

  const apiKey = getMindeeKey();
  if (!apiKey) return redirectToImport(request, { import_error: "MINDEE_V2_API_KEY is not configured." });

  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return redirectToImport(request, { import_error: "Please sign in again before fetching statement OCR." });

  const { data: batch, error: batchError } = await supabase
    .from("dva_statement_import_batches")
    .select("id, mindee_statement_job_id, mindee_statement_model_id, mindee_statement_raw_json")
    .eq("id", importBatchId)
    .maybeSingle();

  if (batchError || !batch) return redirectToImport(request, { import_error: batchError?.message ?? "Statement import batch not found." });
  const typedBatch = batch as Batch;
  const jobId = cleanText(typedBatch.mindee_statement_job_id);
  if (!jobId) return redirectToImport(request, { import_error: "Mindee statement job id is missing. Start OCR first." });

  if (hasInferencePayload(typedBatch.mindee_statement_raw_json)) {
    const { error: saveExistingPayloadError } = await supabase.rpc("staff_save_dva_statement_import_mindee_result", {
      p_import_batch_id: importBatchId,
      p_mindee_inference_id: extractMindeeInferenceId(typedBatch.mindee_statement_raw_json),
      p_ocr_status: "completed",
      p_raw_json: typedBatch.mindee_statement_raw_json,
      p_pages_consumed: extractPagesConsumed(typedBatch.mindee_statement_raw_json),
      p_http_status: 200,
      p_error_message: null,
    });

    if (saveExistingPayloadError) return redirectToImport(request, { import_error: saveExistingPayloadError.message });

    return redirectToImport(request, {
      import_success: "Mindee statement OCR result is already saved. Next: parse raw OCR into staged rows.",
      batch_id: importBatchId,
    });
  }

  const headers = new Headers();
  headers.set("Authori" + "zation", apiKey);
  headers.set("Accept", "application/json");

  const jobResponse = await fetch(`${MINDEE_V2_API_BASE}/jobs/${encodeURIComponent(jobId)}`, {
    method: "GET",
    headers,
    cache: "no-store",
  });

  const raw = await jobResponse.json().catch(() => null);
  const status = jobResponse.ok ? toDbOcrStatus(extractJobStatus(raw)) : "failed";
  const inferenceId = extractMindeeInferenceId(raw);
  const hasPayload = hasInferencePayload(raw);

  const { error: saveError } = await supabase.rpc("staff_save_dva_statement_import_mindee_result", {
    p_import_batch_id: importBatchId,
    p_mindee_inference_id: inferenceId,
    p_ocr_status: hasPayload ? "completed" : status,
    p_raw_json: hasPayload ? raw : null,
    p_pages_consumed: extractPagesConsumed(raw),
    p_http_status: jobResponse.status,
    p_error_message: jobResponse.ok ? null : parseMindeeDetail(raw) || "Mindee statement job fetch failed.",
  });

  if (saveError) return redirectToImport(request, { import_error: saveError.message });

  if (!jobResponse.ok) {
    return redirectToImport(request, { import_error: `Mindee statement job fetch failed (${jobResponse.status}). ${parseMindeeDetail(raw) || "No detail returned."}` });
  }

  if (!hasPayload) {
    return redirectToImport(request, { import_success: `Mindee job ${jobId} is ${status}. Wait briefly, then fetch again. No new OCR page was used.`, batch_id: importBatchId });
  }

  return redirectToImport(request, { import_success: `Mindee statement OCR result saved. Next: parse raw OCR into staged rows.`, batch_id: importBatchId });
}
