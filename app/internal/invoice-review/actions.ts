"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type OcrInvoiceLine = {
  line_order: number;
  retailer_sku: string | null;
  description: string;
  qty: number;
  amount_inc_vat_gbp: number;
  line_source: "ocr_extracted";
  eligible_for_invoice_yn: "N";
};

type NestedOrderRetailer = {
  retailers?: { name?: string | null } | null;
};

type ParsedOcrLine = {
  retailer_sku: string | null;
  description: string;
  qty: number;
  amount_inc_vat_gbp: number;
};

type ReviewFlagDraft = {
  flag_type: "invoice_total_mismatch" | "ocr_unclear" | "wrong_invoice" | "delivery_discount_query" | "manual_line_needed" | "other";
  message: string;
};

const DEFAULT_MINDEE_INVOICE_MODEL_ID = "cd596aec-23b0-4063-bdbe-38c9c8728e84";
const MINDEE_V2_ENQUEUE_URL = "https://api-v2.mindee.net/v2/inferences/enqueue";
const MINDEE_V2_API_BASE = "https://api-v2.mindee.net/v2";

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

function readOptionalMoney(formData: FormData, key: string) {
  const raw = readString(formData, key);
  if (!raw) return null;
  const value = Math.round(Number(raw) * 100) / 100;
  return Number.isFinite(value) && value >= 0 ? value : null;
}

function redirectWithResult(params: Record<string, string>): never {
  const query = new URLSearchParams(params);
  redirect(`/internal/invoice-review?${query.toString()}`);
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

function stringField(field: unknown) {
  const value = fieldValue(field);
  return value === null ? null : String(value).trim() || null;
}

function stringValue(value: unknown) {
  const resolved = plainOrFieldValue(value);
  return resolved === null ? null : String(resolved).trim() || null;
}

function numberField(field: unknown) {
  const value = fieldValue(field);
  if (value === null) return null;
  const n = Number(value);
  return Number.isFinite(n) ? Math.round(n * 100) / 100 : null;
}

function numberValue(value: unknown) {
  const resolved = plainOrFieldValue(value);
  if (resolved === null) return null;
  const n = Number(resolved);
  return Number.isFinite(n) ? Math.round(n * 100) / 100 : null;
}

function dateField(field: unknown) {
  const value = stringField(field);
  if (!value) return null;
  return /^\d{4}-\d{2}-\d{2}$/.test(value) ? value : null;
}

function dateValue(value: unknown) {
  const resolved = stringValue(value);
  if (!resolved) return null;
  return /^\d{4}-\d{2}-\d{2}$/.test(resolved) ? resolved : null;
}

function normalizeName(value: string | null | undefined) {
  return String(value ?? "").toLowerCase().replace(/[^a-z0-9]+/g, "");
}

function namesReasonablyMatch(left: string | null | undefined, right: string | null | undefined) {
  const a = normalizeName(left);
  const b = normalizeName(right);
  if (!a || !b) return false;
  return a === b || a.includes(b) || b.includes(a);
}

function normalizeInvoiceLine(line: unknown, lineOrder: number): OcrInvoiceLine | null {
  if (!line || typeof line !== "object") return null;
  const row = line as Record<string, unknown>;
  const description = stringField(row.description) ?? stringField(row.product_code) ?? `OCR line ${lineOrder}`;
  const rawQty = numberField(row.quantity) ?? 1;
  const qty = Math.max(0, Math.round(rawQty));
  const amount = numberField(row.total_amount) ?? numberField(row.total_price) ?? null;
  const sku = stringField(row.product_code);

  if (!description || amount === null || amount < 0) return null;

  return {
    line_order: lineOrder,
    retailer_sku: sku,
    description,
    qty,
    amount_inc_vat_gbp: amount,
    line_source: "ocr_extracted",
    eligible_for_invoice_yn: "N",
  };
}

function normalizeV2InvoiceLine(line: unknown, lineOrder: number): ParsedOcrLine | null {
  if (!line || typeof line !== "object") return null;
  const outer = line as Record<string, unknown>;
  const row = outer.fields && typeof outer.fields === "object" ? outer.fields as Record<string, unknown> : outer;
  const description =
    stringValue(row.description) ??
    stringValue(row.name) ??
    stringValue(row.label) ??
    stringValue(row.product_name) ??
    stringValue(row.product_code) ??
    `OCR line ${lineOrder}`;
  const qty = Math.max(0, Math.round(numberValue(row.quantity) ?? numberValue(row.qty) ?? 1));
  const amount =
    numberValue(row.total_amount) ??
    numberValue(row.total_price) ??
    numberValue(row.amount) ??
    numberValue(row.line_total) ??
    null;
  const sku = stringValue(row.product_code) ?? stringValue(row.sku) ?? stringValue(row.reference);

  if (!description || amount === null || amount < 0) return null;

  return {
    retailer_sku: sku,
    description,
    qty,
    amount_inc_vat_gbp: amount,
  };
}

function getMindeeV2Key() {
  return process.env.MINDEE_V2_API_KEY?.trim() || process.env.MINDEE_API_KEY?.trim() || "";
}

function getMindeeInvoiceModelId() {
  return process.env.MINDEE_INVOICE_MODEL_ID?.trim() || DEFAULT_MINDEE_INVOICE_MODEL_ID;
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
  return recordValue(job?.id ?? obj.job_id);
}

function extractMindeeInferenceId(raw: unknown) {
  if (!raw || typeof raw !== "object") return null;
  const obj = raw as Record<string, unknown>;
  const inference = obj.inference && typeof obj.inference === "object" ? obj.inference as Record<string, unknown> : null;
  const job = obj.job && typeof obj.job === "object" ? obj.job as Record<string, unknown> : null;
  return recordValue(inference?.id ?? job?.inference_id ?? obj.inference_id ?? obj.id);
}

function extractJobStatus(raw: unknown) {
  if (!raw || typeof raw !== "object") return null;
  const obj = raw as Record<string, unknown>;
  const job = obj.job && typeof obj.job === "object" ? obj.job as Record<string, unknown> : null;
  return recordValue(job?.status ?? obj.status);
}

function isCompleteStatus(status: string | null) {
  const normal = (status ?? "").toLowerCase();
  return ["completed", "complete", "processed", "done", "success", "succeeded"].includes(normal);
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

function parseMindeeV2InvoiceResult(raw: unknown, enteredTotal: number | null, expectedRetailer: string | null) {
  const fields = firstRecordCandidate(raw, [
    ["inference", "result", "fields"],
    ["inference", "result", "prediction"],
    ["inference", "result"],
    ["result", "fields"],
    ["result"],
    ["document", "inference", "prediction"],
  ]);

  const ocrInvoiceRef = firstStringFrom(fields, ["invoice_number", "invoice_ref", "invoice_id", "reference", "document_number"]);
  const ocrRetailerName = firstStringFrom(fields, ["supplier_name", "supplier", "vendor_name", "seller_name", "company_name"]);
  const ocrInvoiceDate = firstDateFrom(fields, ["invoice_date", "date", "issued_date", "document_date"]);
  const ocrInvoiceTotal = firstNumberFrom(fields, ["total_amount", "total", "total_incl", "total_inc_vat", "amount_due", "grand_total"]);
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

  const lines = lineItems
    .map((line, index) => normalizeV2InvoiceLine(line, index + 1))
    .filter((line: ParsedOcrLine | null): line is ParsedOcrLine => Boolean(line));
  const flags: ReviewFlagDraft[] = [];
  const today = new Date().toISOString().slice(0, 10);
  const lineTotal = Math.round(lines.reduce((sum, line) => sum + Number(line.amount_inc_vat_gbp ?? 0), 0) * 100) / 100;

  if (!ocrInvoiceRef) flags.push({ flag_type: "ocr_unclear", message: "Mindee OCR did not extract an invoice reference." });
  if (!ocrInvoiceDate) flags.push({ flag_type: "ocr_unclear", message: "Mindee OCR did not extract an invoice date." });
  if (ocrInvoiceDate && ocrInvoiceDate > today) flags.push({ flag_type: "ocr_unclear", message: `Mindee OCR extracted a future invoice date: ${ocrInvoiceDate}.` });
  if (ocrInvoiceTotal === null) flags.push({ flag_type: "ocr_unclear", message: "Mindee OCR did not extract an invoice total." });
  if (lines.length === 0) flags.push({ flag_type: "manual_line_needed", message: "Mindee OCR did not extract usable invoice lines. Manual line review is required." });
  if (ocrInvoiceTotal !== null && lines.length > 0 && Math.abs(lineTotal - ocrInvoiceTotal) > 0.01) {
    flags.push({ flag_type: "invoice_total_mismatch", message: `Mindee OCR line total ${lineTotal.toFixed(2)} does not match OCR header total ${ocrInvoiceTotal.toFixed(2)}.` });
  }
  if (enteredTotal !== null && ocrInvoiceTotal !== null && Math.abs(enteredTotal - ocrInvoiceTotal) > 0.01) {
    flags.push({ flag_type: "invoice_total_mismatch", message: `Operator entered ${enteredTotal.toFixed(2)} but Mindee OCR extracted ${ocrInvoiceTotal.toFixed(2)}.` });
  }
  if (expectedRetailer && ocrRetailerName && !namesReasonablyMatch(expectedRetailer, ocrRetailerName)) {
    flags.push({ flag_type: "wrong_invoice", message: `Order retailer is ${expectedRetailer}, but Mindee OCR detected ${ocrRetailerName}.` });
  }

  return { ocrInvoiceRef, ocrRetailerName, ocrInvoiceDate, ocrInvoiceTotal, lines, flags };
}

async function requireSupervisorOrAdmin() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    return { ok: false as const, supabase, error: "Please sign in again." };
  }

  const { data: staff, error } = await supabase
    .from("staff")
    .select("id, role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (error || !staff) {
    return { ok: false as const, supabase, error: "Active staff user not found." };
  }

  if (!["admin", "supervisor"].includes(String(staff.role_type))) {
    return { ok: false as const, supabase, error: "Only admin or supervisor staff can review invoices." };
  }

  return { ok: true as const, supabase, staff };
}

async function createReviewFlagIfMissing(params: {
  supabase: Awaited<ReturnType<typeof createClient>>;
  orderId: string;
  supplierInvoiceId: string;
  flagType: "invoice_total_mismatch" | "ocr_unclear" | "wrong_invoice" | "delivery_discount_query" | "manual_line_needed" | "other";
  message: string;
  raisedByOperatorId: string;
}) {
  const { supabase, orderId, supplierInvoiceId, flagType, message, raisedByOperatorId } = params;

  const { data: existing } = await supabase
    .from("supplier_invoice_review_flags")
    .select("id")
    .eq("supplier_invoice_id", supplierInvoiceId)
    .eq("flag_type", flagType)
    .in("status", ["open", "under_review"])
    .limit(1)
    .maybeSingle();

  if (existing?.id) return;

  await supabase.from("supplier_invoice_review_flags").insert({
    order_id: orderId,
    supplier_invoice_id: supplierInvoiceId,
    flag_type: flagType,
    message,
    status: "open",
    raised_by_operator_id: raisedByOperatorId,
  });
}

export async function runMindeeOcrForSupplierInvoiceAction(formData: FormData) {
  const supplierInvoiceId = readString(formData, "supplier_invoice_id");
  if (!supplierInvoiceId) redirectWithResult({ error: "Missing supplier invoice reference." });

  const apiKey = getMindeeV2Key();
  if (!apiKey) redirectWithResult({ error: "MINDEE_V2_API_KEY is not configured." });

  const modelId = getMindeeInvoiceModelId();
  if (!modelId) redirectWithResult({ error: "MINDEE_INVOICE_MODEL_ID is not configured." });

  const guard = await requireSupervisorOrAdmin();
  if (!guard.ok) redirectWithResult({ error: guard.error });

  const { data: startData, error: startError } = await guard.supabase.rpc("staff_start_mindee_invoice_ocr", {
    p_supplier_invoice_id: supplierInvoiceId,
    p_model_id: modelId,
  });

  if (startError) {
    redirectWithResult({
      error: startError.message.includes("function") || startError.message.includes("schema cache")
        ? "Mindee tracking SQL is not installed yet. Run docs/governing-pack/backend/mindee_v2_tracking_v1.sql first."
        : startError.message,
    });
  }

  const startRow = Array.isArray(startData) ? startData[0] : startData;
  const invoicePdfUrl = startRow && typeof startRow === "object" && "invoice_pdf_url" in startRow
    ? String((startRow as { invoice_pdf_url?: unknown }).invoice_pdf_url ?? "")
    : "";
  const orderId = startRow && typeof startRow === "object" && "order_id" in startRow
    ? String((startRow as { order_id?: unknown }).order_id ?? "")
    : "";

  if (!invoicePdfUrl) redirectWithResult({ error: "Invoice PDF URL was not returned by the Mindee OCR guard." });

  const invoiceFileResponse = await fetch(invoicePdfUrl, { cache: "no-store" });
  if (!invoiceFileResponse.ok) {
    await guard.supabase.rpc("staff_record_mindee_enqueue_result", {
      p_supplier_invoice_id: supplierInvoiceId,
      p_model_id: modelId,
      p_http_status: invoiceFileResponse.status,
      p_success_yn: false,
      p_mindee_job_id: null,
      p_mindee_inference_id: null,
      p_response_json: { source: "invoice_file_fetch" },
      p_error_message: `Could not fetch invoice file before Mindee enqueue (${invoiceFileResponse.status}).`,
    });
    redirectWithResult({ error: `Could not fetch invoice file before Mindee enqueue (${invoiceFileResponse.status}). No Mindee page was sent.` });
  }

  const fileBlob = await invoiceFileResponse.blob();
  const mindeeForm = new FormData();
  mindeeForm.append("model_id", modelId);
  mindeeForm.append("file", fileBlob, `supplier-invoice-${supplierInvoiceId}.pdf`);

  const headers = new Headers();
  headers.set("Authori" + "zation", apiKey);
  headers.set("Accept", "application/json");

  const mindeeResponse = await fetch(MINDEE_V2_ENQUEUE_URL, {
    method: "POST",
    headers,
    body: mindeeForm,
    cache: "no-store",
  });

  const raw = await mindeeResponse.json().catch(() => null);
  const jobId = extractMindeeJobId(raw);
  const inferenceId = extractMindeeInferenceId(raw);
  const success = mindeeResponse.ok && Boolean(jobId || inferenceId);
  const detail = parseMindeeDetail(raw);

  const { error: recordError } = await guard.supabase.rpc("staff_record_mindee_enqueue_result", {
    p_supplier_invoice_id: supplierInvoiceId,
    p_model_id: modelId,
    p_http_status: mindeeResponse.status,
    p_success_yn: success,
    p_mindee_job_id: jobId,
    p_mindee_inference_id: inferenceId,
    p_response_json: raw ?? { empty_response: true },
    p_error_message: success ? null : (detail || `Mindee V2 enqueue failed (${mindeeResponse.status}).`),
  });

  if (recordError) {
    redirectWithResult({ error: `Mindee enqueue returned ${mindeeResponse.status}, but recording failed: ${recordError.message}` });
  }

  if (!success) {
    redirectWithResult({ error: `Mindee V2 enqueue failed (${mindeeResponse.status}). ${detail || "No detail returned."}` });
  }

  revalidatePath("/internal/invoice-review");
  if (orderId) {
    revalidatePath(`/internal/evidence/${orderId}`);
    revalidatePath(`/importer/orders/${orderId}/operations`);
    revalidatePath(`/importer/reconciliation/${orderId}`);
  }

  redirectWithResult({
    success: `Mindee OCR enqueued safely. Job ${jobId ?? "—"}. Inference ${inferenceId ?? "pending"}. Do not click again; fetch/save result next.`,
  });
}

export async function fetchAndSaveMindeeOcrResultAction(formData: FormData) {
  const supplierInvoiceId = readString(formData, "supplier_invoice_id");
  if (!supplierInvoiceId) redirectWithResult({ error: "Missing supplier invoice reference." });

  const apiKey = getMindeeV2Key();
  if (!apiKey) redirectWithResult({ error: "MINDEE_V2_API_KEY is not configured." });

  const guard = await requireSupervisorOrAdmin();
  if (!guard.ok) redirectWithResult({ error: guard.error });

  const { data: invoice, error: invoiceError } = await guard.supabase
    .from("supplier_invoices")
    .select("id, order_id, invoice_ref, mindee_job_id, mindee_inference_id, mindee_model_id, mindee_ocr_status, orders(order_ref, retailers(name)), supplier_invoice_financial_summary(invoice_total_gbp)")
    .eq("id", supplierInvoiceId)
    .maybeSingle();

  if (invoiceError || !invoice) redirectWithResult({ error: invoiceError?.message ?? "Supplier invoice not found." });

  const modelId = String(invoice.mindee_model_id || getMindeeInvoiceModelId());
  let jobId = typeof invoice.mindee_job_id === "string" ? invoice.mindee_job_id : "";
  let inferenceId = typeof invoice.mindee_inference_id === "string" ? invoice.mindee_inference_id : "";

  if (!jobId && !inferenceId) {
    redirectWithResult({ error: "This invoice has no Mindee job/inference id to fetch. Do not send it again unless you intend to consume another page." });
  }

  const headers = new Headers();
  headers.set("Authori" + "zation", apiKey);
  headers.set("Accept", "application/json");

  let jobRaw: unknown = null;
  if (jobId) {
    const jobResponse = await fetch(`${MINDEE_V2_API_BASE}/jobs/${encodeURIComponent(jobId)}`, {
      method: "GET",
      headers,
      cache: "no-store",
    });
    jobRaw = await jobResponse.json().catch(() => null);
    const status = extractJobStatus(jobRaw);
    const newInferenceId = extractMindeeInferenceId(jobRaw);
    if (newInferenceId) inferenceId = newInferenceId;

    const { error: pollError } = await guard.supabase.rpc("staff_record_mindee_job_poll", {
      p_supplier_invoice_id: supplierInvoiceId,
      p_model_id: modelId,
      p_http_status: jobResponse.status,
      p_success_yn: jobResponse.ok,
      p_mindee_job_id: jobId,
      p_mindee_inference_id: inferenceId || null,
      p_job_status: status,
      p_response_json: jobRaw ?? { empty_response: true },
      p_error_message: jobResponse.ok ? null : (parseMindeeDetail(jobRaw) || `Mindee job fetch failed (${jobResponse.status}).`),
    });

    if (pollError) {
      redirectWithResult({
        error: pollError.message.includes("function") || pollError.message.includes("schema cache")
          ? "Mindee result SQL is not installed yet. Run docs/governing-pack/backend/mindee_v2_result_v1.sql first."
          : pollError.message,
      });
    }

    if (!jobResponse.ok && !inferenceId) {
      redirectWithResult({ error: `Mindee job fetch failed (${jobResponse.status}). ${parseMindeeDetail(jobRaw) || "No detail returned."}` });
    }

    if (jobResponse.ok && !isCompleteStatus(status) && !inferenceId) {
      redirectWithResult({ success: `Mindee job ${jobId} is still ${status ?? "processing"}. Wait briefly, then click Fetch/save result again. No new page was sent.` });
    }
  }

  if (!inferenceId) {
    redirectWithResult({ success: `Mindee job ${jobId} has no inference id yet. Wait briefly, then click Fetch/save result again. No new page was sent.` });
  }

  const inferenceResponse = await fetch(`${MINDEE_V2_API_BASE}/inferences/${encodeURIComponent(inferenceId)}`, {
    method: "GET",
    headers,
    cache: "no-store",
  });
  const inferenceRaw = await inferenceResponse.json().catch(() => null);

  if (!inferenceResponse.ok) {
    redirectWithResult({ error: `Mindee inference fetch failed (${inferenceResponse.status}). ${parseMindeeDetail(inferenceRaw) || "No detail returned."}` });
  }

  const orders = Array.isArray(invoice.orders) ? invoice.orders[0] : invoice.orders;
  const retailers = orders && typeof orders === "object" && "retailers" in orders ? (orders as { retailers?: unknown }).retailers : null;
  const retailerRow = Array.isArray(retailers) ? retailers[0] : retailers;
  const expectedRetailer = retailerRow && typeof retailerRow === "object" && "name" in retailerRow ? String((retailerRow as { name?: unknown }).name ?? "") : "";
  const financialSummary = Array.isArray(invoice.supplier_invoice_financial_summary) ? invoice.supplier_invoice_financial_summary[0] : invoice.supplier_invoice_financial_summary;
  const enteredTotal = financialSummary && typeof financialSummary === "object" && "invoice_total_gbp" in financialSummary
    ? numberValue((financialSummary as { invoice_total_gbp?: unknown }).invoice_total_gbp)
    : null;

  const parsed = parseMindeeV2InvoiceResult(inferenceRaw, enteredTotal, expectedRetailer || null);
  const pagesConsumed = extractPagesConsumed(inferenceRaw);

  const { data: saveData, error: saveError } = await guard.supabase.rpc("staff_save_mindee_invoice_ocr_result", {
    p_supplier_invoice_id: supplierInvoiceId,
    p_model_id: modelId,
    p_http_status: inferenceResponse.status,
    p_mindee_job_id: jobId || null,
    p_mindee_inference_id: inferenceId,
    p_raw_json: inferenceRaw ?? { empty_response: true },
    p_ocr_invoice_ref: parsed.ocrInvoiceRef,
    p_ocr_retailer_name: parsed.ocrRetailerName,
    p_ocr_invoice_date: parsed.ocrInvoiceDate,
    p_ocr_invoice_total_gbp: parsed.ocrInvoiceTotal,
    p_pages_consumed: pagesConsumed,
    p_lines: parsed.lines,
    p_flags: parsed.flags,
  });

  if (saveError) {
    redirectWithResult({
      error: saveError.message.includes("function") || saveError.message.includes("schema cache")
        ? "Mindee result SQL is not installed yet. Run docs/governing-pack/backend/mindee_v2_result_v1.sql first."
        : saveError.message,
    });
  }

  const resultRow = Array.isArray(saveData) ? saveData[0] : null;
  const orderId = resultRow?.order_id ? String(resultRow.order_id) : String(invoice.order_id);
  const insertedLines = resultRow?.inserted_line_count ?? parsed.lines.length;
  const insertedFlags = resultRow?.inserted_flag_count ?? parsed.flags.length;

  revalidatePath("/internal/invoice-review");
  revalidatePath("/internal/supplier-draft-ready");
  if (orderId) {
    revalidatePath(`/internal/evidence/${orderId}`);
    revalidatePath(`/importer/orders/${orderId}/operations`);
    revalidatePath(`/importer/reconciliation/${orderId}`);
  }

  redirectWithResult({
    success: `Mindee OCR result saved. Inserted ${insertedLines} OCR line(s), raised ${insertedFlags} flag(s). Pages reported: ${pagesConsumed ?? "unknown"}.`,
  });
}

export async function saveSupplierInvoiceHeaderReviewAction(formData: FormData) {
  const supplierInvoiceId = readString(formData, "supplier_invoice_id");
  const correctedInvoiceRef = readString(formData, "corrected_invoice_ref") || null;
  const ocrInvoiceRef = readString(formData, "ocr_invoice_ref") || null;
  const ocrRetailerName = readString(formData, "ocr_retailer_name") || null;
  const ocrInvoiceDate = readString(formData, "ocr_invoice_date") || null;
  const ocrInvoiceTotal = readOptionalMoney(formData, "ocr_invoice_total_gbp");
  const reviewNotes = readString(formData, "review_notes") || null;

  if (!supplierInvoiceId) redirectWithResult({ error: "Missing supplier invoice reference." });

  const guard = await requireSupervisorOrAdmin();
  if (!guard.ok) redirectWithResult({ error: guard.error });

  const { data, error } = await guard.supabase.rpc("staff_save_supplier_invoice_header_review", {
    p_supplier_invoice_id: supplierInvoiceId,
    p_corrected_invoice_ref: correctedInvoiceRef,
    p_ocr_invoice_ref: ocrInvoiceRef,
    p_ocr_retailer_name: ocrRetailerName,
    p_ocr_invoice_date: ocrInvoiceDate,
    p_ocr_invoice_total_gbp: ocrInvoiceTotal,
    p_review_notes: reviewNotes,
  });

  if (error) redirectWithResult({ error: error.message });

  const orderId = Array.isArray(data) && data[0]?.order_id ? String(data[0].order_id) : null;

  revalidatePath("/internal/invoice-review");
  revalidatePath("/internal/supplier-draft-ready");
  if (orderId) {
    revalidatePath(`/internal/evidence/${orderId}`);
    revalidatePath(`/importer/orders/${orderId}/operations`);
    revalidatePath(`/importer/reconciliation/${orderId}`);
  }
  redirectWithResult({ success: "Supplier invoice header review saved. Clean invoices move to Supplier draft ready for approval." });
}

export async function rejectSupplierInvoiceRequireResubmissionAction(formData: FormData) {
  const supplierInvoiceId = readString(formData, "supplier_invoice_id");
  const reviewNotes = readString(formData, "review_notes") || "Rejected. Operator must resubmit the correct invoice evidence.";

  if (!supplierInvoiceId) redirectWithResult({ error: "Missing supplier invoice reference." });

  const guard = await requireSupervisorOrAdmin();
  if (!guard.ok) redirectWithResult({ error: guard.error });

  const { data, error } = await guard.supabase.rpc("staff_reject_supplier_invoice_resubmission", {
    p_supplier_invoice_id: supplierInvoiceId,
    p_review_notes: reviewNotes,
  });

  if (error) redirectWithResult({ error: error.message });

  const orderId = Array.isArray(data) && data[0]?.order_id ? String(data[0].order_id) : null;

  revalidatePath("/internal/invoice-review");
  if (orderId) {
    revalidatePath(`/internal/evidence/${orderId}`);
    revalidatePath(`/importer/orders/${orderId}/operations`);
    revalidatePath(`/importer/reconciliation/${orderId}`);
  }
  redirectWithResult({ success: "Supplier invoice rejected. Resubmission required." });
}
