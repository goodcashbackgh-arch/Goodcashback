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
  const apiKey = process.env.MINDEE_API_KEY;
  const admin = adminClient();

  if (!apiKey || !admin) {
    await createReviewFlagIfMissing({
      orderId: params.orderId,
      supplierInvoiceId: params.supplierInvoiceId,
      flagType: "ocr_unclear",
      message: !apiKey
        ? "Mindee OCR did not run because MINDEE_API_KEY is not configured."
        : "Mindee OCR did not run because service role configuration is missing.",
      raisedByOperatorId: params.operatorId,
    });
    return { ran: false, insertedLineCount: 0, message: "OCR not configured" };
  }

  const endpoint = process.env.MINDEE_INVOICE_API_URL || "https://api.mindee.net/v1/products/mindee/invoices/v4/predict";

  try {
    const invoiceFileResponse = await fetch(params.invoicePdfUrl);
    if (!invoiceFileResponse.ok) {
      await createReviewFlagIfMissing({
        orderId: params.orderId,
        supplierInvoiceId: params.supplierInvoiceId,
        flagType: "ocr_unclear",
        message: `Mindee OCR could not fetch invoice file (${invoiceFileResponse.status}).`,
        raisedByOperatorId: params.operatorId,
      });
      return { ran: false, insertedLineCount: 0, message: "Could not fetch invoice file" };
    }

    const fileBlob = await invoiceFileResponse.blob();
    const mindeeForm = new FormData();
    mindeeForm.append("document", fileBlob, `supplier-invoice-${params.supplierInvoiceId}.pdf`);

    const mindeeResponse = await fetch(endpoint, {
      method: "POST",
      headers: { Authorization: `Token ${apiKey}` },
      body: mindeeForm,
    });

    const raw = await mindeeResponse.json().catch(() => null);
    if (!mindeeResponse.ok || !raw) {
      await createReviewFlagIfMissing({
        orderId: params.orderId,
        supplierInvoiceId: params.supplierInvoiceId,
        flagType: "ocr_unclear",
        message: `Mindee OCR failed (${mindeeResponse.status}).`,
        raisedByOperatorId: params.operatorId,
      });
      return { ran: false, insertedLineCount: 0, message: "Mindee failed" };
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

    await admin
      .from("supplier_invoices")
      .update({
        ocr_service_used: "mindee",
        ocr_raw_json: raw,
        ocr_extracted_at: new Date().toISOString(),
        ocr_invoice_ref: ocrInvoiceRef,
        ocr_retailer_name: ocrRetailerName,
        ocr_invoice_date: ocrInvoiceDate,
        ocr_invoice_total_gbp: ocrTotal,
        review_status: "pending_review",
        blocked_from_sage_yn: true,
      })
      .eq("id", params.supplierInvoiceId);

    const { data: existingLines } = await admin
      .from("supplier_invoice_lines")
      .select("id")
      .eq("supplier_invoice_id", params.supplierInvoiceId)
      .limit(1);

    let insertedLineCount = 0;
    if ((existingLines ?? []).length === 0 && ocrLines.length > 0) {
      const linesToInsert = ocrLines.map((line: OcrInvoiceLine) => ({
        ...line,
        supplier_invoice_id: params.supplierInvoiceId,
      }));
      const { data: insertedLines } = await admin
        .from("supplier_invoice_lines")
        .insert(linesToInsert)
        .select("id");
      insertedLineCount = insertedLines?.length ?? 0;
    }

    if (!ocrInvoiceRef || !ocrRetailerName || ocrTotal === null) {
      await createReviewFlagIfMissing({
        orderId: params.orderId,
        supplierInvoiceId: params.supplierInvoiceId,
        flagType: "ocr_unclear",
        message: "Mindee OCR did not extract a complete invoice reference, supplier name, and total. Supervisor review required.",
        raisedByOperatorId: params.operatorId,
      });
    }

    if (ocrTotal !== null && Math.abs(params.enteredInvoiceTotal - ocrTotal) >= 0.01) {
      await createReviewFlagIfMissing({
        orderId: params.orderId,
        supplierInvoiceId: params.supplierInvoiceId,
        flagType: "invoice_total_mismatch",
        message: `Operator entered ${params.enteredInvoiceTotal.toFixed(2)} but Mindee OCR extracted ${ocrTotal.toFixed(2)}.`,
        raisedByOperatorId: params.operatorId,
      });
    }

    if (ocrLines.length === 0) {
      await createReviewFlagIfMissing({
        orderId: params.orderId,
        supplierInvoiceId: params.supplierInvoiceId,
        flagType: "manual_line_needed",
        message: "Mindee OCR did not extract usable invoice lines. Manual/supervisor line review is required.",
        raisedByOperatorId: params.operatorId,
      });
    }

    return { ran: true, insertedLineCount, message: "OCR saved" };
  } catch (error) {
    await createReviewFlagIfMissing({
      orderId: params.orderId,
      supplierInvoiceId: params.supplierInvoiceId,
      flagType: "ocr_unclear",
      message: `Mindee OCR failed: ${error instanceof Error ? error.message : "Unknown error"}.`,
      raisedByOperatorId: params.operatorId,
    });
    return { ran: false, insertedLineCount: 0, message: "OCR failed" };
  }
}
