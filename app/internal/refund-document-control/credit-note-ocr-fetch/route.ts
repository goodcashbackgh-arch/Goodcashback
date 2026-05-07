import { NextResponse } from "next/server";
import { createClient } from "@/utils/supabase/server";

const DEFAULT_MINDEE_INVOICE_MODEL_ID = "cd596aec-23b0-4063-bdbe-38c9c8728e84";
const MINDEE_V2_API_BASE = "https://api-v2.mindee.net/v2";

type ParsedLine = { description: string; qty: number; amount_gbp: number; retailer_sku: string | null };
type ReviewFlag = { flag_type: "invoice_total_mismatch" | "ocr_unclear" | "wrong_invoice" | "delivery_discount_query" | "manual_line_needed" | "other"; message: string };

function redirectToSubmission(request: Request, submissionId: string, params: Record<string, string>) {
  const url = new URL(`/internal/refund-document-control/${submissionId}/ocr`, new URL(request.url).origin);
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
  const job = obj.job && typeof obj.job === "object" ? obj.job as Record<string, unknown> : null;
  return recordValue(inference?.id ?? job?.inference_id ?? obj.inference_id ?? obj.id);
}

function extractPagesConsumed(raw: unknown) {
  for (const path of [["inference", "file", "page_count"], ["inference", "file", "pages"], ["file", "page_count"], ["file", "pages"], ["document", "n_pages"]]) {
    const n = numberValue(getByPath(raw, path));
    if (n !== null) return Math.max(0, Math.round(n));
  }
  return null;
}

function normalizeV2CreditNoteLine(line: unknown, lineOrder: number, singleLineHeaderTotal: number | null): ParsedLine | null {
  if (!line || typeof line !== "object") return null;
  const outer = line as Record<string, unknown>;
  const row = outer.fields && typeof outer.fields === "object" ? outer.fields as Record<string, unknown> : outer;
  const description = stringValue(row.description) ?? stringValue(row.name) ?? stringValue(row.label) ?? stringValue(row.product_name) ?? stringValue(row.product_code) ?? `OCR credit note line ${lineOrder}`;
  const qty = Math.max(0, Math.round(numberValue(row.quantity) ?? numberValue(row.qty) ?? 1));
  const explicitLineAmount = numberValue(row.total_amount) ?? numberValue(row.total_price) ?? numberValue(row.amount) ?? numberValue(row.line_total);
  const unitPrice = numberValue(row.unit_price) ?? numberValue(row.price) ?? numberValue(row.unit_amount);
  const unitGross = unitPrice !== null ? Math.round(unitPrice * Math.max(qty, 1) * 100) / 100 : null;
  const singleDiscountedLineGross = singleLineHeaderTotal !== null && (unitGross === null || singleLineHeaderTotal <= unitGross) ? singleLineHeaderTotal : null;
  const amount = explicitLineAmount ?? singleDiscountedLineGross ?? unitGross;
  const sku = stringValue(row.product_code) ?? stringValue(row.sku) ?? stringValue(row.reference);
  if (!description || amount === null || amount < 0) return null;
  return { retailer_sku: sku, description, qty, amount_gbp: amount };
}

function parseMindeeV2CreditNoteResult(raw: unknown) {
  const fields = firstRecordCandidate(raw, [["inference", "result", "fields"], ["inference", "result", "prediction"], ["inference", "result"], ["result", "fields"], ["result"], ["document", "inference", "prediction"]]);
  const ocrCreditNoteRef = firstStringFrom(fields, ["credit_note_number", "credit_note_ref", "invoice_number", "invoice_ref", "invoice_id", "reference", "document_number"]);
  const ocrRetailerName = firstStringFrom(fields, ["supplier_name", "supplier", "vendor_name", "seller_name", "company_name"]);
  const ocrCreditNoteDate = firstDateFrom(fields, ["credit_note_date", "invoice_date", "date", "issued_date", "document_date"]);
  const ocrCreditNoteTotal = firstNumberFrom(fields, ["total_amount", "total", "total_incl", "total_inc_vat", "amount_due", "grand_total"]);
  const lineItems = firstArrayCandidate(raw, [["inference", "result", "fields", "line_items", "items"], ["inference", "result", "fields", "items", "items"], ["inference", "result", "fields", "invoice_lines", "items"], ["inference", "result", "fields", "line_items"], ["inference", "result", "fields", "items"], ["inference", "result", "fields", "invoice_lines"], ["inference", "result", "prediction", "line_items"], ["result", "fields", "line_items"], ["document", "inference", "prediction", "line_items"]]);
  const singleLineHeaderTotal = lineItems.length === 1 ? ocrCreditNoteTotal : null;
  const lines = lineItems.map((line, index) => normalizeV2CreditNoteLine(line, index + 1, singleLineHeaderTotal)).filter((line): line is ParsedLine => Boolean(line));
  const flags: ReviewFlag[] = [];
  const lineTotal = Math.round(lines.reduce((sum, line) => sum + Number(line.amount_gbp ?? 0), 0) * 100) / 100;
  if (!ocrCreditNoteRef) flags.push({ flag_type: "ocr_unclear", message: "Mindee OCR did not extract a credit note reference." });
  if (ocrCreditNoteTotal === null) flags.push({ flag_type: "ocr_unclear", message: "Mindee OCR did not extract a credit note total." });
  if (lines.length === 0) flags.push({ flag_type: "manual_line_needed", message: "Mindee OCR did not extract usable credit note lines." });
  if (ocrCreditNoteTotal !== null && lines.length > 0 && Math.abs(lineTotal - ocrCreditNoteTotal) > 0.01) flags.push({ flag_type: "invoice_total_mismatch", message: `Mindee OCR line total ${lineTotal.toFixed(2)} does not match OCR credit note header total ${ocrCreditNoteTotal.toFixed(2)}.` });
  return { ocrCreditNoteRef, ocrRetailerName, ocrCreditNoteDate, ocrCreditNoteTotal, lines, flags };
}

function hasInferencePayload(raw: unknown) {
  return Boolean(getByPath(raw, ["inference", "result"]));
}

export async function POST(request: Request) {
  const formData = await request.formData();
  const submissionId = String(formData.get("refund_evidence_submission_id") ?? "").trim();
  if (!submissionId) return NextResponse.redirect(new URL("/internal/refund-document-control?error=Missing+refund+evidence+submission", request.url), { status: 303 });

  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return redirectToSubmission(request, submissionId, { error: "Please sign in again." });

  const { data: staff } = await supabase.from("staff").select("id, role_type").eq("auth_user_id", user.id).eq("active", true).maybeSingle();
  if (!staff || !["admin", "supervisor"].includes(String(staff.role_type))) return redirectToSubmission(request, submissionId, { error: "Only admin/supervisor staff can fetch credit-note OCR results." });

  const { data: submission, error: submissionError } = await supabase
    .from("dispute_refund_evidence_submissions")
    .select("id, document_mode, mindee_job_id, mindee_model_id")
    .eq("id", submissionId)
    .maybeSingle();

  if (submissionError || !submission) return redirectToSubmission(request, submissionId, { error: submissionError?.message ?? "Refund evidence submission not found." });
  if (String(submission.document_mode) !== "credit_note") return redirectToSubmission(request, submissionId, { error: "Safe fetch is only for credit-note submissions." });

  const modelId = String(submission.mindee_model_id || process.env.MINDEE_CREDIT_NOTE_MODEL_ID || process.env.MINDEE_INVOICE_MODEL_ID || DEFAULT_MINDEE_INVOICE_MODEL_ID);
  const jobId = typeof submission.mindee_job_id === "string" ? submission.mindee_job_id : "";
  if (!jobId) return redirectToSubmission(request, submissionId, { error: "Mindee job id is missing. Start credit-note OCR first; do not upload again blindly." });

  const apiKey = process.env.MINDEE_V2_API_KEY?.trim() || process.env.MINDEE_API_KEY?.trim() || "";
  if (!apiKey) return redirectToSubmission(request, submissionId, { error: "MINDEE_V2_API_KEY is not configured." });

  const headers = new Headers();
  headers.set("Authori" + "zation", apiKey);
  headers.set("Accept", "application/json");

  const jobResponse = await fetch(`${MINDEE_V2_API_BASE}/jobs/${encodeURIComponent(jobId)}`, { method: "GET", headers, cache: "no-store" });
  const raw = await jobResponse.json().catch(() => null);
  const resolvedInferenceId = extractMindeeInferenceId(raw);

  if (!jobResponse.ok) return redirectToSubmission(request, submissionId, { error: `Mindee job fetch failed (${jobResponse.status}). ${parseMindeeDetail(raw) || "No detail returned."}` });
  if (!raw || !hasInferencePayload(raw)) return redirectToSubmission(request, submissionId, { success: `Mindee job ${jobId} has no completed inference payload yet. Wait briefly, then fetch again. No new OCR page was used.` });

  const parsed = parseMindeeV2CreditNoteResult(raw);
  const { data: saveData, error: saveError } = await supabase.rpc("staff_save_refund_credit_note_ocr_result", {
    p_refund_evidence_submission_id: submissionId,
    p_model_id: modelId,
    p_http_status: jobResponse.status,
    p_mindee_job_id: jobId || extractMindeeJobId(raw),
    p_mindee_inference_id: resolvedInferenceId || extractMindeeInferenceId(raw),
    p_raw_json: raw,
    p_ocr_credit_note_ref: parsed.ocrCreditNoteRef,
    p_ocr_retailer_name: parsed.ocrRetailerName,
    p_ocr_credit_note_date: parsed.ocrCreditNoteDate,
    p_ocr_credit_note_total_gbp: parsed.ocrCreditNoteTotal,
    p_pages_consumed: extractPagesConsumed(raw),
    p_lines: parsed.lines,
    p_flags: parsed.flags,
  });

  if (saveError) return redirectToSubmission(request, submissionId, { error: saveError.message });
  const result = saveData && typeof saveData === "object" ? saveData as Record<string, unknown> : {};
  return redirectToSubmission(request, submissionId, { success: `Credit-note OCR saved. Status: ${String(result.match_status ?? "saved")}. Lines: ${String(result.line_count ?? parsed.lines.length)}.` });
}
