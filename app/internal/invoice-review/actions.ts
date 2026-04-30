"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { assertInvoiceReadyForCurrentApproval } from "./readiness";

type OcrInvoiceLine = {
  line_order: number;
  retailer_sku: string | null;
  description: string;
  qty: number;
  amount_inc_vat_gbp: number;
  line_source: "ocr_extracted";
  eligible_for_invoice_yn: "N";
};

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

  return { ok: true as const, supabase };
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

  const apiKey = process.env.MINDEE_API_KEY;
  if (!apiKey) redirectWithResult({ error: "MINDEE_API_KEY is not configured." });

  const endpoint = process.env.MINDEE_INVOICE_API_URL || "https://api.mindee.net/v1/products/mindee/invoices/v4/predict";
  const guard = await requireSupervisorOrAdmin();
  if (!guard.ok) redirectWithResult({ error: guard.error });

  const { data: invoice, error: invoiceError } = await guard.supabase
    .from("supplier_invoices")
    .select("id, order_id, retailer_id, invoice_ref, invoice_pdf_url, uploaded_by_operator_id, orders(order_ref, order_total_gbp_declared, total_qty_declared, retailers(name), importers(id, company_name))")
    .eq("id", supplierInvoiceId)
    .maybeSingle();

  if (invoiceError || !invoice) redirectWithResult({ error: invoiceError?.message ?? "Supplier invoice not found." });
  if (!invoice.invoice_pdf_url) redirectWithResult({ error: "Invoice PDF URL is missing." });

  const invoiceFileResponse = await fetch(invoice.invoice_pdf_url);
  if (!invoiceFileResponse.ok) {
    redirectWithResult({ error: `Could not fetch invoice file for OCR (${invoiceFileResponse.status}).` });
  }

  const fileBlob = await invoiceFileResponse.blob();
  const mindeeForm = new FormData();
  mindeeForm.append("document", fileBlob, `supplier-invoice-${supplierInvoiceId}.pdf`);

  const mindeeResponse = await fetch(endpoint, {
    method: "POST",
    headers: {
      Authorization: `Token ${apiKey}`,
    },
    body: mindeeForm,
  });

  const raw = await mindeeResponse.json().catch(() => null);
  if (!mindeeResponse.ok || !raw) {
    redirectWithResult({ error: `Mindee OCR failed (${mindeeResponse.status}).` });
  }

  const prediction = raw?.document?.inference?.prediction ?? {};
  const ocrInvoiceRef = stringField(prediction.invoice_number);
  const ocrRetailerName = stringField(prediction.supplier_name);
  const ocrInvoiceDate = dateField(prediction.date);
  const ocrTotal = numberField(prediction.total_amount);
  const ocrLinesRaw = Array.isArray(prediction.line_items) ? prediction.line_items : [];
  const ocrLines: OcrInvoiceLine[] = ocrLinesRaw
    .map((line: unknown, index: number) => normalizeInvoiceLine(line, index + 1))
    .filter((line: OcrInvoiceLine | null): line is OcrInvoiceLine => Boolean(line));

  const now = new Date().toISOString();
  const { error: updateError } = await guard.supabase
    .from("supplier_invoices")
    .update({
      ocr_service_used: "mindee",
      ocr_raw_json: raw,
      ocr_extracted_at: now,
      ocr_invoice_ref: ocrInvoiceRef,
      ocr_retailer_name: ocrRetailerName,
      ocr_invoice_date: ocrInvoiceDate,
      ocr_invoice_total_gbp: ocrTotal,
      review_status: "pending_review",
      blocked_from_sage_yn: true,
    })
    .eq("id", supplierInvoiceId);

  if (updateError) redirectWithResult({ error: updateError.message });

  const { data: existingLines, error: existingLinesError } = await guard.supabase
    .from("supplier_invoice_lines")
    .select("id")
    .eq("supplier_invoice_id", supplierInvoiceId)
    .limit(1);

  if (existingLinesError) redirectWithResult({ error: existingLinesError.message });

  let insertedLineCount = 0;
  if ((existingLines ?? []).length === 0 && ocrLines.length > 0) {
    const linesToInsert = ocrLines.map((line: OcrInvoiceLine) => ({
      ...line,
      supplier_invoice_id: supplierInvoiceId,
    }));
    const { data: insertedLines, error: insertLinesError } = await guard.supabase
      .from("supplier_invoice_lines")
      .insert(linesToInsert)
      .select("id");

    if (insertLinesError) redirectWithResult({ error: insertLinesError.message });
    insertedLineCount = insertedLines?.length ?? 0;
  }

  const { data: enteredSummary } = await guard.supabase
    .from("supplier_invoice_financial_summary")
    .select("invoice_total_gbp")
    .eq("supplier_invoice_id", supplierInvoiceId)
    .maybeSingle();

  const enteredTotal = enteredSummary?.invoice_total_gbp === null || enteredSummary?.invoice_total_gbp === undefined
    ? null
    : Number(enteredSummary.invoice_total_gbp);

  const orderRetailer = Array.isArray(invoice.orders) ? invoice.orders[0]?.retailers?.name : invoice.orders?.retailers?.name;
  const raisedByOperatorId = String(invoice.uploaded_by_operator_id);

  if (!ocrInvoiceRef || !ocrRetailerName || ocrTotal === null) {
    await createReviewFlagIfMissing({
      supabase: guard.supabase,
      orderId: invoice.order_id,
      supplierInvoiceId,
      flagType: "ocr_unclear",
      message: "Mindee OCR did not extract a complete invoice reference, supplier name, and total. Supervisor review required.",
      raisedByOperatorId,
    });
  }

  if (enteredTotal !== null && ocrTotal !== null && Math.abs(enteredTotal - ocrTotal) >= 0.01) {
    await createReviewFlagIfMissing({
      supabase: guard.supabase,
      orderId: invoice.order_id,
      supplierInvoiceId,
      flagType: "invoice_total_mismatch",
      message: `Operator entered ${enteredTotal.toFixed(2)} but Mindee OCR extracted ${ocrTotal.toFixed(2)}.`,
      raisedByOperatorId,
    });
  }

  if (orderRetailer && ocrRetailerName && !ocrRetailerName.toLowerCase().includes(String(orderRetailer).toLowerCase())) {
    await createReviewFlagIfMissing({
      supabase: guard.supabase,
      orderId: invoice.order_id,
      supplierInvoiceId,
      flagType: "wrong_invoice",
      message: `Order retailer is ${orderRetailer}, but Mindee OCR detected ${ocrRetailerName}.`,
      raisedByOperatorId,
    });
  }

  if (ocrLines.length === 0) {
    await createReviewFlagIfMissing({
      supabase: guard.supabase,
      orderId: invoice.order_id,
      supplierInvoiceId,
      flagType: "manual_line_needed",
      message: "Mindee OCR did not extract usable invoice lines. Manual/supervisor line review is required.",
      raisedByOperatorId,
    });
  }

  revalidatePath("/internal/invoice-review");
  revalidatePath(`/internal/evidence/${invoice.order_id}`);
  revalidatePath(`/importer/orders/${invoice.order_id}/operations`);
  revalidatePath(`/importer/reconciliation/${invoice.order_id}`);
  redirectWithResult({ success: `Mindee OCR saved. Inserted ${insertedLineCount} OCR line(s).` });
}

export async function approveSupplierInvoiceCurrentAction(formData: FormData) {
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

  const readinessError = await assertInvoiceReadyForCurrentApproval(guard.supabase, supplierInvoiceId);
  if (readinessError) redirectWithResult({ error: readinessError });

  const { data, error } = await guard.supabase.rpc("staff_approve_supplier_invoice_current", {
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
  if (orderId) {
    revalidatePath(`/internal/evidence/${orderId}`);
    revalidatePath(`/importer/orders/${orderId}/operations`);
    revalidatePath(`/importer/reconciliation/${orderId}`);
  }
  redirectWithResult({ success: "Supplier invoice approved as current." });
}

export async function rejectSupplierInvoiceRequireResubmissionAction(formData: FormData) {
  const supplierInvoiceId = readString(formData, "supplier_invoice_id");
  const reviewNotes = readString(formData, "review_notes") || null;

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
