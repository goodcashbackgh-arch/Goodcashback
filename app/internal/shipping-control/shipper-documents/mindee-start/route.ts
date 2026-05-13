import { NextResponse } from "next/server";
import { createClient } from "@/utils/supabase/server";

const MINDEE_V2_ENQUEUE_URL = "https://api-v2.mindee.net/v2/inferences/enqueue";

function redirectBack(request: Request, params: Record<string, string>) {
  const fallback = new URL("/internal/shipping-control/shipper-documents", new URL(request.url).origin);
  const referer = request.headers.get("referer");
  const url = referer ? new URL(referer) : fallback;
  Object.entries(params).forEach(([key, value]) => url.searchParams.set(key, value));
  return NextResponse.redirect(url, { status: 303 });
}

function cleanText(value: unknown) {
  return String(value ?? "").trim();
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
  const job = obj.job && typeof obj.job === "object" ? (obj.job as Record<string, unknown>) : null;
  const inference = obj.inference && typeof obj.inference === "object" ? (obj.inference as Record<string, unknown>) : null;
  const inferenceJob = inference?.job && typeof inference.job === "object" ? (inference.job as Record<string, unknown>) : null;
  return recordValue(job?.id ?? inferenceJob?.id ?? obj.job_id);
}

function extractMindeeInferenceId(raw: unknown) {
  if (!raw || typeof raw !== "object") return null;
  const obj = raw as Record<string, unknown>;
  const inference = obj.inference && typeof obj.inference === "object" ? (obj.inference as Record<string, unknown>) : null;
  const job = obj.job && typeof obj.job === "object" ? (obj.job as Record<string, unknown>) : null;
  return recordValue(inference?.id ?? job?.inference_id ?? obj.inference_id ?? obj.id);
}

function getMindeeKey() {
  return process.env.MINDEE_V2_API_KEY?.trim() || process.env.MINDEE_API_KEY?.trim() || "";
}

function getShippingModelId() {
  return process.env.MINDEE_SHIPPING_DOCUMENT_MODEL_ID?.trim() || process.env.MINDEE_INVOICE_MODEL_ID?.trim() || "";
}

function getShippingWebhookId() {
  return process.env.MINDEE_SHIPPING_DOCUMENT_WEBHOOK_ID?.trim() || process.env.MINDEE_INVOICE_WEBHOOK_ID?.trim() || "";
}

function mindeeWebhookIdsFormValue(webhookId: string) {
  // Mindee V2 accepts this multipart field either as a list of UUIDs or as a comma-separated UUID string.
  // In FormData, use the comma-separated string form. For one webhook, that is the raw UUID.
  return webhookId.trim();
}

async function preflightOneDocument({
  supabase,
  shippingDocumentId,
}: {
  supabase: Awaited<ReturnType<typeof createClient>>;
  shippingDocumentId: string;
}) {
  const { data, error } = await (supabase as any).rpc("internal_shipping_document_detail_v1", {
    p_shipping_document_id: shippingDocumentId,
  });
  if (error) return { ok: false, message: error.message };

  const row = Array.isArray(data) ? data[0] : null;
  if (!row) return { ok: false, message: "Shipping document not found." };

  const reviewStatus = cleanText(row.review_status);
  const ocrStatus = cleanText(row.ocr_status);
  if (["accepted_current", "superseded", "rejected_resubmit_required"].includes(reviewStatus)) {
    return { ok: false, message: `Document is ${reviewStatus}; OCR must not run against locked/rejected documents.` };
  }
  if (["queued", "processing", "completed", "failed"].includes(ocrStatus)) {
    return { ok: false, message: `OCR status is ${ocrStatus}; normal start is blocked.` };
  }

  const fileUrl = cleanText(row.file_url);
  if (!fileUrl || !isHttpUrl(fileUrl)) return { ok: false, message: "Document has no real uploaded file URL." };

  const fileResponse = await fetch(fileUrl, { method: "GET", cache: "no-store" });
  if (!fileResponse.ok) return { ok: false, message: `Uploaded file is not fetchable (${fileResponse.status}).` };

  const contentType = fileResponse.headers.get("content-type") || "unknown";
  const bytes = await fileResponse.arrayBuffer().then((buffer) => buffer.byteLength).catch(() => 0);
  if (bytes <= 0) return { ok: false, message: "Uploaded file fetched but appears empty." };

  return {
    ok: true,
    message: `Preflight OK for ${cleanText(row.booking_ref) || shippingDocumentId}: file fetchable, status eligible, ${contentType}, ${bytes} bytes. Mindee was not called.`,
  };
}

async function enqueueOneDocument({
  request,
  supabase,
  shippingDocumentId,
  modelId,
  webhookId,
  apiKey,
}: {
  request: Request;
  supabase: Awaited<ReturnType<typeof createClient>>;
  shippingDocumentId: string;
  modelId: string;
  webhookId: string;
  apiKey: string;
}) {
  const { data: startData, error: startError } = await (supabase as any).rpc("internal_start_mindee_shipping_document_ocr_v1", {
    p_shipping_document_id: shippingDocumentId,
    p_model_id: modelId,
  });

  if (startError) return { ok: false, message: startError.message };

  const row = Array.isArray(startData) ? startData[0] : null;
  const fileUrl = cleanText(row?.file_url);
  if (!fileUrl || !isHttpUrl(fileUrl)) {
    return { ok: false, message: "Shipping document has no real uploaded file URL." };
  }

  const fileResponse = await fetch(fileUrl, { cache: "no-store" });
  if (!fileResponse.ok) {
    await (supabase as any).rpc("internal_record_shipping_mindee_enqueue_result_v1", {
      p_shipping_document_id: shippingDocumentId,
      p_model_id: modelId,
      p_http_status: fileResponse.status,
      p_success_yn: false,
      p_mindee_job_id: null,
      p_mindee_inference_id: null,
      p_response_json: { file_fetch_failed: true, status: fileResponse.status },
      p_error_message: `Could not fetch uploaded document for OCR (${fileResponse.status}).`,
    });
    return { ok: false, message: `Could not fetch uploaded document (${fileResponse.status}).` };
  }

  const fileBuffer = await fileResponse.arrayBuffer();
  const contentType = fileResponse.headers.get("content-type") || "application/octet-stream";
  const filename = `${cleanText(row?.document_ref) || shippingDocumentId}.pdf`;

  const mindeeFormData = new FormData();
  mindeeFormData.set("model_id", modelId);
  mindeeFormData.set("webhook_ids", mindeeWebhookIdsFormValue(webhookId));
  mindeeFormData.set("file", new Blob([fileBuffer], { type: contentType }), filename);

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

  await (supabase as any).rpc("internal_record_shipping_mindee_enqueue_result_v1", {
    p_shipping_document_id: shippingDocumentId,
    p_model_id: modelId,
    p_http_status: mindeeResponse.status,
    p_success_yn: mindeeResponse.ok && Boolean(jobId),
    p_mindee_job_id: jobId,
    p_mindee_inference_id: inferenceId,
    p_response_json: raw ?? { empty_response: true },
    p_error_message: mindeeResponse.ok && jobId ? null : parseMindeeDetail(raw) || "Mindee enqueue failed or returned no job id.",
  });

  if (!mindeeResponse.ok || !jobId) {
    return { ok: false, message: `Mindee enqueue failed (${mindeeResponse.status}). ${parseMindeeDetail(raw) || "No detail returned."}` };
  }

  return { ok: true, message: `Queued ${jobId}.` };
}

export async function POST(request: Request) {
  const formData = await request.formData();
  const ids = formData
    .getAll("shipping_document_id")
    .map((value) => cleanText(value))
    .filter(Boolean);
  const dryRun = cleanText(formData.get("dry_run")) === "1";

  if (ids.length === 0) return redirectBack(request, { error: "Select at least one shipping document for OCR." });

  const apiKey = getMindeeKey();
  if (!apiKey) return redirectBack(request, { error: "MINDEE_V2_API_KEY is not configured." });

  const modelId = getShippingModelId();
  if (!modelId) return redirectBack(request, { error: "MINDEE_SHIPPING_DOCUMENT_MODEL_ID or MINDEE_INVOICE_MODEL_ID is not configured." });

  const webhookId = getShippingWebhookId();
  if (!webhookId) {
    return redirectBack(request, {
      error: "MINDEE_SHIPPING_DOCUMENT_WEBHOOK_ID or MINDEE_INVOICE_WEBHOOK_ID is not configured. Configure the webhook first so OCR completes automatically without a fetch button.",
    });
  }

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return redirectBack(request, { error: "Please sign in again before starting OCR." });

  const { data: staff } = await supabase
    .from("staff")
    .select("id, role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!staff || !["admin", "supervisor"].includes(String(staff.role_type))) {
    return redirectBack(request, { error: "Only admin/supervisor staff can start shipper document OCR." });
  }

  if (dryRun) {
    let okCount = 0;
    const failures: string[] = [];
    for (const id of ids) {
      const result = await preflightOneDocument({ supabase, shippingDocumentId: id });
      if (result.ok) okCount += 1;
      else failures.push(result.message);
    }
    if (okCount === 0) return redirectBack(request, { error: failures[0] || "Preflight failed. Mindee was not called." });
    const suffix = failures.length > 0 ? ` ${failures.length} failed: ${failures[0]}` : "";
    return redirectBack(request, { success: `Preflight passed for ${okCount} document(s). Mindee was not called.${suffix}` });
  }

  let queued = 0;
  const failures: string[] = [];

  for (const id of ids) {
    const result = await enqueueOneDocument({ request, supabase, shippingDocumentId: id, modelId, webhookId, apiKey });
    if (result.ok) queued += 1;
    else failures.push(result.message);
  }

  if (queued === 0) {
    return redirectBack(request, { error: failures[0] || "No documents were queued for OCR." });
  }

  const suffix = failures.length > 0 ? ` ${failures.length} failed: ${failures[0]}` : "";
  return redirectBack(request, { success: `Queued ${queued} shipping document(s) for OCR. Results will appear automatically when Mindee returns them.${suffix}` });
}
