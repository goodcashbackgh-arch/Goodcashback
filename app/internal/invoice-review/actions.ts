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

const DEFAULT_MINDEE_INVOICE_MODEL_ID = "cd596aec-23b0-4063-bdbe-38c9c8728e84";
const MINDEE_V2_ENQUEUE_URL = "https://api-v2.mindee.net/v2/inferences/enqueue";

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

function stringField(field: unknown) {
  const value = fieldValue(field);
  return value === null ? null : String(value).trim() || null;
}

function numberField(field: unknown) {
  const value = fieldValue(field);
  if (value === null) return null;
  const n = Number(value);
  return Number.isFinite(n) ? Math.round(n * 100) / 100 : null;
}

function dateField(field: unknown) {
  const value = stringField(field);
  if (!value) return null;
  return /^\d{4}-\d{2}-\d{2}$/.test(value) ? value : null;
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
  return recordValue(job?.id ?? obj.job_id ?? obj.id);
}

function extractMindeeInferenceId(raw: unknown) {
  if (!raw || typeof raw !== "object") return null;
  const obj = raw as Record<string, unknown>;
  const inference = obj.inference && typeof obj.inference === "object" ? obj.inference as Record<string, unknown> : null;
  const job = obj.job && typeof obj.job === "object" ? obj.job as Record<string, unknown> : null;
  return recordValue(inference?.id ?? job?.inference_id ?? obj.inference_id);
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
