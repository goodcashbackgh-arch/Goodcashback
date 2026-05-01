import { createClient as createSupabaseClient } from "@supabase/supabase-js";

type OcrResult = {
  ran: boolean;
  insertedLineCount: number;
  message: string;
};

type OcrInvoiceLine = {
  line_order: number;
  retailer_sku: string | null;
  description: string;
  qty: number;
  amount_inc_vat_gbp: number;
  line_source: "ocr_extracted";
  eligible_for_invoice_yn: "N";
};

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

function adminClient() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !serviceKey) return null;
  return createSupabaseClient(url, serviceKey, { auth: { persistSession: false } });
}

async function createReviewFlagIfMissing(params: {
  orderId: string;
  supplierInvoiceId: string;
  flagType: "invoice_total_mismatch" | "ocr_unclear" | "wrong_invoice" | "delivery_discount_query" | "manual_line_needed" | "other";
  message: string;
  raisedByOperatorId: string;
}) {
  const admin = adminClient();
  if (!admin) return;

  const { data: existing } = await admin
    .from("supplier_invoice_review_flags")
    .select("id")
    .eq("supplier_invoice_id", params.supplierInvoiceId)
    .eq("flag_type", params.flagType)
    .in("status", ["open", "under_review"])
    .limit(1)
    .maybeSingle();

  if (existing?.id) return;

  await admin.from("supplier_invoice_review_flags").insert({
    order_id: params.orderId,
    supplier_invoice_id: params.supplierInvoiceId,
    flag_type: params.flagType,
    message: params.message,
    status: "open",
    raised_by_operator_id: params.raisedByOperatorId,
  });
}

export async function runMindeeOcrAfterUpload(params: {
  supplierInvoiceId: string;
  orderId: string;
  invoicePdfUrl: string;
  enteredInvoiceTotal: number;
  operatorId: string;
}): Promise<OcrResult> {
  await createReviewFlagIfMissing({
    orderId: params.orderId,
    supplierInvoiceId: params.supplierInvoiceId,
    flagType: "ocr_unclear",
    message: "Automatic Mindee OCR is intentionally disabled until the V2 enqueue/result flow is fully proven manually. Supervisor manual OCR is required.",
    raisedByOperatorId: params.operatorId,
  });

  return {
    ran: false,
    insertedLineCount: 0,
    message: "Automatic OCR disabled until V2 manual flow is proven",
  };
}
