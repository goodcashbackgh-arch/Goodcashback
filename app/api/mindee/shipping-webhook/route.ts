import { NextResponse } from "next/server";
import { supabaseAdmin } from "@/lib/supabase/admin";

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

export async function GET() {
  return NextResponse.json({
    ok: true,
    route: "mindee_shipping_webhook",
    method: "GET",
    message: "Shipping Mindee webhook endpoint is reachable. Real Mindee results must be POSTed here.",
    timestamp: new Date().toISOString(),
  });
}

export async function POST(request: Request) {
  const url = new URL(request.url);
  if (url.searchParams.get("ping") === "1") {
    return NextResponse.json({
      ok: true,
      route: "mindee_shipping_webhook",
      method: "POST",
      ping: true,
      message: "Shipping Mindee webhook POST ping received. No OCR result was processed.",
      timestamp: new Date().toISOString(),
    });
  }

  const secret = process.env.MINDEE_SHIPPING_WEBHOOK_SECRET?.trim() || process.env.MINDEE_WEBHOOK_SECRET?.trim();
  if (secret) {
    const supplied = request.headers.get("x-goodcashback-webhook-secret")?.trim();
    if (supplied !== secret) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  }

  const raw = await request.json().catch(() => null);
  if (!raw || typeof raw !== "object") return NextResponse.json({ error: "invalid json" }, { status: 400 });

  const jobId = extractMindeeJobId(raw);
  const inferenceId = extractMindeeInferenceId(raw);
  if (!jobId && !inferenceId) return NextResponse.json({ error: "missing job/inference id" }, { status: 400 });

  const filters = [jobId ? `mindee_job_id.eq.${jobId}` : "", inferenceId ? `mindee_inference_id.eq.${inferenceId}` : ""].filter(Boolean).join(",");
  const { data: shippingDoc, error } = await supabaseAdmin
    .from("shipping_documents")
    .select("id, mindee_model_id")
    .or(filters)
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (error) return NextResponse.json({ error: error.message }, { status: 500 });
  if (!shippingDoc) return NextResponse.json({ error: "no matching shipping document found for Mindee webhook" }, { status: 404 });

  const parsed = parseMindeeV2InvoiceResult(raw);
  const { data: saveData, error: saveError } = await (supabaseAdmin as any).rpc("internal_save_shipping_mindee_ocr_result_v1", {
    p_shipping_document_id: shippingDoc.id,
    p_model_id: shippingDoc.mindee_model_id,
    p_http_status: 200,
    p_mindee_job_id: jobId,
    p_mindee_inference_id: inferenceId,
    p_raw_json: raw,
    p_ocr_shipper_name: parsed.ocrShipperName,
    p_ocr_reference_text: parsed.ocrReferenceText,
    p_ocr_document_ref: parsed.ocrDocumentRef,
    p_ocr_document_date: parsed.ocrDocumentDate,
    p_ocr_total_amount: parsed.ocrTotalAmount,
    p_pages_consumed: extractPagesConsumed(raw),
    p_lines: parsed.lines,
  });

  if (saveError) return NextResponse.json({ error: saveError.message }, { status: 500 });
  const row = Array.isArray(saveData) ? saveData[0] : null;
  return NextResponse.json({ ok: true, shipping_document_id: shippingDoc.id, ocr_match_status: row?.ocr_match_status ?? null });
}
