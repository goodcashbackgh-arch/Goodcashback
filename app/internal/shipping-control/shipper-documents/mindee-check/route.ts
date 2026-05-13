import { NextResponse } from "next/server";
import { createClient } from "@/utils/supabase/server";

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

function recordValue(value: unknown) {
  if (value === undefined || value === null || value === "") return null;
  return String(value).trim() || null;
}

function fieldValue(field: unknown) {
  if (!field || typeof field !== "object") return null;
  const value = (field as { value?: unknown }).value;
  if (value === undefined || value === null || value === "") return null;
  return value;
}

function plainOrFieldValue(value: unknown) {
  const nested = fieldValue(value);
  if (nested !== null) return nested;
  if (value === undefined || value === null || value === "") return null;
  return value;
}

function stringValue(value: unknown) {
  const resolved = plainOrFieldValue(value);
  return resolved === null ? null : String(resolved).trim() || null;
}

function numberValue(value: unknown) {
  const resolved = plainOrFieldValue(value);
  if (resolved === null) return null;
  const n = Number(resolved);
  return Number.isFinite(n) ? Math.round(n * 100) / 100 : null;
}

function dateValue(value: unknown) {
  const resolved = stringValue(value);
  if (!resolved) return null;
  return /^\d{4}-\d{2}-\d{2}$/.test(resolved) ? resolved : null;
}

function getByPath(root: unknown, path: string[]) {
  let current = root;
  for (const key of path) {
    if (!current || typeof current !== "object") return null;
    current = (current as Record<string, unknown>)[key];
  }
  return current ?? null;
}

function firstRecordCandidate(root: unknown, paths: string[][]) {
  for (const path of paths) {
    const candidate = getByPath(root, path);
    if (candidate && typeof candidate === "object" && !Array.isArray(candidate)) return candidate as Record<string, unknown>;
  }
  return {} as Record<string, unknown>;
}

function firstArrayCandidate(root: unknown, paths: string[][]) {
  for (const path of paths) {
    const candidate = getByPath(root, path);
    if (Array.isArray(candidate)) return candidate;
  }
  return [] as unknown[];
}

function firstStringFrom(record: Record<string, unknown>, keys: string[]) {
  for (const key of keys) {
    const value = stringValue(record[key]);
    if (value) return value;
  }
  return null;
}

function firstNumberFrom(record: Record<string, unknown>, keys: string[]) {
  for (const key of keys) {
    const value = numberValue(record[key]);
    if (value !== null) return value;
  }
  return null;
}

function firstDateFrom(record: Record<string, unknown>, keys: string[]) {
  for (const key of keys) {
    const value = dateValue(record[key]);
    if (value) return value;
  }
  return null;
}

function jobRecord(raw: unknown) {
  if (!raw || typeof raw !== "object") return {} as Record<string, unknown>;
  const root = raw as Record<string, unknown>;
  if (root.job && typeof root.job === "object" && !Array.isArray(root.job)) return root.job as Record<string, unknown>;
  return root;
}

function jobField(raw: unknown, key: string) {
  const job = jobRecord(raw);
  return job[key] ?? (raw && typeof raw === "object" ? (raw as Record<string, unknown>)[key] : null) ?? null;
}

function extractMindeeJobId(raw: unknown) {
  if (!raw || typeof raw !== "object") return null;
  const obj = raw as Record<string, unknown>;
  const inference = obj.inference && typeof obj.inference === "object" ? obj.inference as Record<string, unknown> : null;
  const job = obj.job && typeof obj.job === "object" ? obj.job as Record<string, unknown> : null;
  const inferenceJob = inference?.job && typeof inference.job === "object" ? inference.job as Record<string, unknown> : null;
  return recordValue(job?.id ?? inferenceJob?.id ?? obj.job_id ?? obj.id);
}

function extractMindeeInferenceId(raw: unknown) {
  if (!raw || typeof raw !== "object") return null;
  const obj = raw as Record<string, unknown>;
  const inference = obj.inference && typeof obj.inference === "object" ? obj.inference as Record<string, unknown> : null;
  const job = obj.job && typeof obj.job === "object" ? obj.job as Record<string, unknown> : null;
  return recordValue(inference?.id ?? job?.inference_id ?? obj.inference_id ?? obj.id);
}

function extractPagesConsumed(raw: unknown) {
  const candidates = [
    getByPath(raw, ["inference", "file", "page_count"]),
    getByPath(raw, ["inference", "file", "pages"]),
    getByPath(raw, ["file", "page_count"]),
    getByPath(raw, ["file", "pages"]),
    getByPath(raw, ["document", "n_pages"]),
  ];
  for (const candidate of candidates) {
    const n = numberValue(candidate);
    if (n !== null) return Math.max(0, Math.round(n));
  }
  return null;
}

function normalizeV2InvoiceLine(line: unknown, lineOrder: number) {
  if (!line || typeof line !== "object") return null;
  const outer = line as Record<string, unknown>;
  const row = outer.fields && typeof outer.fields === "object" ? outer.fields as Record<string, unknown> : outer;
  const description = stringValue(row.description) ?? stringValue(row.name) ?? stringValue(row.label) ?? stringValue(row.product_name) ?? stringValue(row.product_code) ?? `OCR line ${lineOrder}`;
  const qty = Math.max(0, Math.round(numberValue(row.quantity) ?? numberValue(row.qty) ?? 1));
  const amount = numberValue(row.total_amount) ?? numberValue(row.total_price) ?? numberValue(row.amount) ?? numberValue(row.line_total) ?? null;
  if (!description || amount === null || amount < 0) return null;
  return { description, quantity: qty, amount_gbp: amount };
}

function parseMindeeV2InvoiceResult(raw: unknown) {
  const fields = firstRecordCandidate(raw, [
    ["inference", "result", "fields"],
    ["inference", "result", "prediction"],
    ["inference", "result"],
    ["result", "fields"],
    ["result"],
    ["document", "inference", "prediction"],
  ]);
  const ocrDocumentRef = firstStringFrom(fields, ["invoice_number", "invoice_ref", "invoice_id", "reference", "document_number"]);
  const ocrShipperName = firstStringFrom(fields, ["supplier_name", "supplier", "vendor_name", "seller_name", "company_name"]);
  const ocrDocumentDate = firstDateFrom(fields, ["invoice_date", "date", "issued_date", "document_date"]);
  const ocrTotalAmount = firstNumberFrom(fields, ["total_amount", "total", "total_incl", "total_inc_vat", "amount_due", "grand_total"]);
  const lineItems = firstArrayCandidate(raw, [
    ["inference", "result", "fields", "line_items", "items"],
    ["inference", "result", "fields", "items", "items"],
    ["inference", "result", "fields", "invoice_lines", "items"],
    ["inference", "result", "fields", "line_items"],
    ["inference", "result", "fields", "items"],
    ["inference", "result", "fields", "invoice_lines"],
    ["inference", "result", "prediction", "line_items"],
    ["result", "fields", "line_items"],
    ["document", "inference", "prediction", "line_items"],
  ]);
  const lines = lineItems.map((line, index) => normalizeV2InvoiceLine(line, index + 1)).filter(Boolean);
  const referenceText = [
    ocrDocumentRef,
    firstStringFrom(fields, ["purchase_order", "po_number", "order_number", "booking_ref", "tracking_number", "reference", "document_number"]),
    stringValue(getByPath(raw, ["inference", "result", "raw_text"])),
    stringValue(getByPath(raw, ["inference", "raw_text"])),
  ].filter(Boolean).join(" ").trim() || null;
  return { ocrShipperName, ocrReferenceText: referenceText, ocrDocumentRef, ocrDocumentDate, ocrTotalAmount, lines };
}

function getMindeeKey() {
  return process.env.MINDEE_V2_API_KEY?.trim() || process.env.MINDEE_API_KEY?.trim() || "";
}

async function fetchMindeeUrl(url: string, apiKey: string) {
  const response = await fetch(url, {
    method: "GET",
    headers: { Accept: "application/json", Authorization: apiKey },
    cache: "no-store",
    redirect: "follow",
  });
  const raw = await response.json().catch(() => null);
  return { response, raw };
}

export async function POST(request: Request) {
  const formData = await request.formData();
  const shippingDocumentId = cleanText(formData.get("shipping_document_id"));
  if (!shippingDocumentId) return redirectBack(request, { error: "Select one shipping document to check." });

  const apiKey = getMindeeKey();
  if (!apiKey) return redirectBack(request, { error: "MINDEE_V2_API_KEY is not configured." });

  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return redirectBack(request, { error: "Please sign in again before checking OCR." });

  const { data: staff } = await supabase
    .from("staff")
    .select("id, role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!staff || !["admin", "supervisor"].includes(String(staff.role_type))) {
    return redirectBack(request, { error: "Only admin/supervisor staff can check shipper document OCR." });
  }

  const { data: contextData, error: contextError } = await (supabase as any).rpc("internal_shipping_mindee_polling_context_v1", {
    p_shipping_document_id: shippingDocumentId,
  });
  if (contextError) return redirectBack(request, { error: contextError.message });
  const doc = Array.isArray(contextData) ? contextData[0] : null;
  if (!doc) return redirectBack(request, { error: "Active shipping document not found." });
  if (doc.review_status === "accepted_current" || doc.review_status === "superseded") {
    return redirectBack(request, { error: "Accepted/superseded shipping document is locked." });
  }
  if (!doc.mindee_job_id && !doc.mindee_inference_id) return redirectBack(request, { error: "No Mindee job/inference id found for this document." });

  const firstUrl = cleanText(doc.result_url) || cleanText(doc.polling_url);
  if (!firstUrl) {
    return redirectBack(request, { error: "No stored Mindee polling_url/result_url found. Do not resend; inspect ocr_raw_json for this document." });
  }

  const first = await fetchMindeeUrl(firstUrl, apiKey);
  if (first.response.status === 404) {
    return redirectBack(request, { success: "Mindee says the result is not ready yet (404). Not resent." });
  }
  if (!first.response.ok) return redirectBack(request, { error: `Mindee check failed (${first.response.status}).` });

  const status = cleanText(jobField(first.raw, "status")).toLowerCase();
  const liveResultUrl = stringValue(jobField(first.raw, "result_url")) ?? stringValue(getByPath(first.raw, ["inference", "result_url"]));
  const errorMessage = stringValue(getByPath(first.raw, ["job", "error", "message"])) ?? stringValue(jobField(first.raw, "error"));

  if (["processing", "queued", "created"].includes(status)) {
    return redirectBack(request, { success: `Mindee job is still ${status}. Not resent.` });
  }
  if (["failed", "failure", "error"].includes(status)) {
    return redirectBack(request, { error: `Mindee job failed: ${errorMessage ?? "No detail returned."}` });
  }

  const resultRaw = liveResultUrl && liveResultUrl !== firstUrl ? (await fetchMindeeUrl(liveResultUrl, apiKey)).raw : first.raw;
  const parsed = parseMindeeV2InvoiceResult(resultRaw);
  const jobId = extractMindeeJobId(resultRaw) ?? doc.mindee_job_id;
  const inferenceId = extractMindeeInferenceId(resultRaw) ?? doc.mindee_inference_id;

  const { data: saveData, error: saveError } = await (supabase as any).rpc("internal_staff_save_shipping_mindee_ocr_result_v1", {
    p_shipping_document_id: doc.shipping_document_id,
    p_model_id: doc.mindee_model_id,
    p_http_status: 200,
    p_mindee_job_id: jobId,
    p_mindee_inference_id: inferenceId,
    p_raw_json: resultRaw,
    p_ocr_shipper_name: parsed.ocrShipperName,
    p_ocr_reference_text: parsed.ocrReferenceText,
    p_ocr_document_ref: parsed.ocrDocumentRef,
    p_ocr_document_date: parsed.ocrDocumentDate,
    p_ocr_total_amount: parsed.ocrTotalAmount,
    p_pages_consumed: extractPagesConsumed(resultRaw),
    p_lines: parsed.lines,
  });

  if (saveError) return redirectBack(request, { error: saveError.message });
  const row = Array.isArray(saveData) ? saveData[0] : null;
  return redirectBack(request, { success: `Mindee result saved. Match status: ${row?.ocr_match_status ?? "needs review"}.` });
}
