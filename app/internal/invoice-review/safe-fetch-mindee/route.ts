import { NextResponse } from "next/server";
import { createClient } from "@/utils/supabase/server";

const DEFAULT_MINDEE_INVOICE_MODEL_ID = "cd596aec-23b0-4063-bdbe-38c9c8728e84";
const MINDEE_V2_API_BASE = "https://api-v2.mindee.net/v2";

type ParsedLine = { retailer_sku: string | null; description: string; qty: number; amount_inc_vat_gbp: number };
type ReviewFlag = { flag_type: "invoice_total_mismatch" | "ocr_unclear" | "wrong_invoice" | "delivery_discount_query" | "manual_line_needed" | "other"; message: string };

function redirectTo(request: Request, params: Record<string, string>) {
  const url = new URL("/internal/invoice-review", new URL(request.url).origin);
  Object.entries(params).forEach(([key, value]) => url.searchParams.set(key, value));
  return NextResponse.redirect(url, { status: 303 });
}
function fieldValue(field: unknown) {
  if (!field || typeof field !== "object") return null;
  const value = (field as { value?: unknown }).value;
  return value === undefined || value === null || value === "" ? null : value;
}
function plainOrFieldValue(value: unknown) {
  const nested = fieldValue(value);
  if (nested !== null) return nested;
  return value === undefined || value === null || value === "" ? null : value;
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
  return resolved && /^\d{4}-\d{2}-\d{2}$/.test(resolved) ? resolved : null;
}
function recordValue(value: unknown) {
  return value === undefined || value === null || value === "" ? null : String(value).trim() || null;
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
  const inference = obj.inference && typeof obj.inference === "object" ? obj.inference as Record<string, unknown> : null;
  const job = obj.job && typeof obj.job === "object" ? obj.job as Record<string, unknown> : null;
  const inferenceJob = inference?.job && typeof inference.job === "object" ? inference.job as Record<string, unknown> : null;
  return recordValue(job?.id ?? inferenceJob?.id ?? obj.job_id);
}
function extractMindeeInferenceId(raw: unknown) {
  if (!raw || typeof raw !== "object") return null;
  const obj = raw as Record<string, unknown>;
  const inference = obj.inference && typeof obj.inference === "object" ? obj.inference as Record<string, unknown> : null;
  return recordValue(inference?.id ?? obj.inference_id);
}
function extractPagesConsumed(raw: unknown) {
  for (const path of [["inference", "file", "page_count"], ["inference", "file", "pages"], ["file", "page_count"], ["file", "pages"], ["document", "n_pages"]]) {
    const n = numberValue(getByPath(raw, path));
    if (n !== null) return Math.max(0, Math.round(n));
  }
  return null;
}
function normalizeV2InvoiceLine(line: unknown, lineOrder: number, singleLineHeaderTotal: number | null): ParsedLine | null {
  if (!line || typeof line !== "object") return null;
  const outer = line as Record<string, unknown>;
  const row = outer.fields && typeof outer.fields === "object" ? outer.fields as Record<string, unknown> : outer;
  const description = stringValue(row.description) ?? stringValue(row.name) ?? stringValue(row.label) ?? stringValue(row.product_name) ?? stringValue(row.product_code) ?? `OCR line ${lineOrder}`;
  const qty = Math.max(0, Math.round(numberValue(row.quantity) ?? numberValue(row.qty) ?? 1));
  const explicitLineAmount = numberValue(row.total_amount) ?? numberValue(row.total_price) ?? numberValue(row.amount) ?? numberValue(row.line_total);
  const unitPrice = numberValue(row.unit_price) ?? numberValue(row.price) ?? numberValue(row.unit_amount);
  const unitGross = unitPrice !== null ? Math.round(unitPrice * Math.max(qty, 1) * 100) / 100 : null;
  const singleDiscountedLineGross = singleLineHeaderTotal !== null && (unitGross === null || singleLineHeaderTotal <= unitGross) ? singleLineHeaderTotal : null;
  const amount = explicitLineAmount ?? singleDiscountedLineGross ?? unitGross;
  const sku = stringValue(row.product_code) ?? stringValue(row.sku) ?? stringValue(row.reference);
  if (!description || amount === null || amount < 0) return null;
  return { retailer_sku: sku, description, qty, amount_inc_vat_gbp: amount };
}
function parseMindeeV2InvoiceResult(raw: unknown) {
  const fields = firstRecordCandidate(raw, [["inference", "result", "fields"], ["inference", "result", "prediction"], ["inference", "result"], ["result", "fields"], ["result"], ["document", "inference", "prediction"]]);
  const ocrInvoiceRef = firstStringFrom(fields, ["invoice_number", "invoice_ref", "invoice_id", "reference", "document_number"]);
  const ocrRetailerName = firstStringFrom(fields, ["supplier_name", "supplier", "vendor_name", "seller_name", "company_name"]);
  const ocrInvoiceDate = firstDateFrom(fields, ["invoice_date", "date", "issued_date", "document_date"]);
  const ocrInvoiceTotal = firstNumberFrom(fields, ["total_amount", "total", "total_incl", "total_inc_vat", "amount_due", "grand_total"]);
  const lineItems = firstArrayCandidate(raw, [["inference", "result", "fields", "line_items", "items"], ["inference", "result", "fields", "items", "items"], ["inference", "result", "fields", "invoice_lines", "items"], ["inference", "result", "fields", "line_items"], ["inference", "result", "fields", "items"], ["inference", "result", "fields", "invoice_lines"], ["inference", "result", "prediction", "line_items"], ["result", "fields", "line_items"], ["document", "inference", "prediction", "line_items"]]);
  const singleLineHeaderTotal = lineItems.length === 1 ? ocrInvoiceTotal : null;
  const lines = lineItems.map((line, index) => normalizeV2InvoiceLine(line, index + 1, singleLineHeaderTotal)).filter((line): line is ParsedLine => Boolean(line));
  const flags: ReviewFlag[] = [];
  const lineTotal = Math.round(lines.reduce((sum, line) => sum + Number(line.amount_inc_vat_gbp ?? 0), 0) * 100) / 100;
  if (!ocrInvoiceRef) flags.push({ flag_type: "ocr_unclear", message: "Mindee OCR did not extract an invoice reference." });
  if (ocrInvoiceTotal === null) flags.push({ flag_type: "ocr_unclear", message: "Mindee OCR did not extract an invoice total." });
  if (lines.length === 0) flags.push({ flag_type: "manual_line_needed", message: "Mindee OCR did not extract usable invoice lines." });
  if (ocrInvoiceTotal !== null && lines.length > 0 && Math.abs(lineTotal - ocrInvoiceTotal) > 0.01) flags.push({ flag_type: "invoice_total_mismatch", message: `Mindee OCR line total ${lineTotal.toFixed(2)} does not match OCR header total ${ocrInvoiceTotal.toFixed(2)}.` });
  return { ocrInvoiceRef, ocrRetailerName, ocrInvoiceDate, ocrInvoiceTotal, lines, flags };
}
function hasInferencePayload(raw: unknown) {
  return Boolean(getByPath(raw, ["inference", "result"]));
}

export async function POST(request: Request) {
  const formData = await request.formData();
  const supplierInvoiceId = String(formData.get("supplier_invoice_id") ?? "").trim();
  if (!supplierInvoiceId) return redirectTo(request, { error: "Missing supplier invoice reference." });

  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return redirectTo(request, { error: "Please sign in again." });

  const { data: staff } = await supabase.from("staff").select("id, role_type").eq("auth_user_id", user.id).eq("active", true).maybeSingle();
  if (!staff || !["admin", "supervisor"].includes(String(staff.role_type))) return redirectTo(request, { error: "Only admin/supervisor staff can fetch Mindee results." });

  const { data: invoice, error: invoiceError } = await supabase.from("supplier_invoices").select("id, order_id, mindee_job_id, mindee_model_id").eq("id", supplierInvoiceId).maybeSingle();
  if (invoiceError || !invoice) return redirectTo(request, { error: invoiceError?.message ?? "Supplier invoice not found." });

  const modelId = String(invoice.mindee_model_id || DEFAULT_MINDEE_INVOICE_MODEL_ID);
  const jobId = typeof invoice.mindee_job_id === "string" ? invoice.mindee_job_id : "";
  if (!jobId) return redirectTo(request, { error: "Mindee job id is missing. Do not re-send OCR; inspect the invoice record first." });

  let raw: unknown = null;
  let httpStatus = 200;
  let resolvedInferenceId: string | null = null;

  const { data: cached } = await supabase.from("mindee_api_calls").select("response_json, http_status, mindee_job_id, mindee_inference_id").eq("supplier_invoice_id", supplierInvoiceId).eq("action_type", "get_job").eq("success_yn", true).order("request_started_at", { ascending: false }).limit(3);
  for (const row of cached ?? []) {
    if (hasInferencePayload(row.response_json)) {
      raw = row.response_json;
      httpStatus = Number(row.http_status ?? 200);
      resolvedInferenceId = extractMindeeInferenceId(raw);
      break;
    }
  }

  if (!raw) {
    const apiKey = process.env.MINDEE_V2_API_KEY?.trim() || process.env.MINDEE_API_KEY?.trim() || "";
    if (!apiKey) return redirectTo(request, { error: "MINDEE_V2_API_KEY is not configured." });
    const headers = new Headers();
    headers.set("Authori" + "zation", apiKey);
    headers.set("Accept", "application/json");
    const jobResponse = await fetch(`${MINDEE_V2_API_BASE}/jobs/${encodeURIComponent(jobId)}`, { method: "GET", headers, cache: "no-store" });
    raw = await jobResponse.json().catch(() => null);
    httpStatus = jobResponse.status;
    resolvedInferenceId = extractMindeeInferenceId(raw);
    await supabase.from("mindee_api_calls").insert({ supplier_invoice_id: supplierInvoiceId, order_id: invoice.order_id, actor_staff_id: staff.id, action_type: "get_job", mindee_model_id: modelId, http_status: jobResponse.status, success_yn: jobResponse.ok, mindee_job_id: jobId, mindee_inference_id: resolvedInferenceId, response_json: raw ?? { empty_response: true }, error_message: jobResponse.ok ? null : parseMindeeDetail(raw), request_completed_at: new Date().toISOString() });
    if (!jobResponse.ok) return redirectTo(request, { error: `Mindee job fetch failed (${jobResponse.status}). ${parseMindeeDetail(raw) || "No detail returned."}` });
  }

  if (!raw || !hasInferencePayload(raw)) return redirectTo(request, { success: `Mindee job ${jobId} has no completed inference payload yet. Wait briefly, then fetch again. No new OCR page was used.` });

  const parsed = parseMindeeV2InvoiceResult(raw);
  const { data: saveData, error: saveError } = await supabase.rpc("staff_save_mindee_invoice_ocr_result", { p_supplier_invoice_id: supplierInvoiceId, p_model_id: modelId, p_http_status: httpStatus, p_mindee_job_id: jobId || extractMindeeJobId(raw), p_mindee_inference_id: resolvedInferenceId || extractMindeeInferenceId(raw), p_raw_json: raw, p_ocr_invoice_ref: parsed.ocrInvoiceRef, p_ocr_retailer_name: parsed.ocrRetailerName, p_ocr_invoice_date: parsed.ocrInvoiceDate, p_ocr_invoice_total_gbp: parsed.ocrInvoiceTotal, p_pages_consumed: extractPagesConsumed(raw), p_lines: parsed.lines, p_flags: parsed.flags });
  if (saveError) return redirectTo(request, { error: saveError.message });
  const resultRow = Array.isArray(saveData) ? saveData[0] : null;
  return redirectTo(request, { success: `Mindee OCR result saved from job response. Inserted ${resultRow?.inserted_line_count ?? parsed.lines.length} OCR line(s), raised ${resultRow?.inserted_flag_count ?? parsed.flags.length} flag(s).` });
}
