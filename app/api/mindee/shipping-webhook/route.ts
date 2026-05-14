import { NextResponse } from "next/server";
import { supabaseAdmin } from "@/lib/supabase/admin";

type ParsedLine = {
  description: string;
  quantity: number;
  amount_gbp: number;
};

function recordValue(value: unknown) {
  if (value === undefined || value === null || value === "") return null;
  if (typeof value === "object") return null;
  return String(value).trim() || null;
}

function getByPath(root: unknown, path: string[]) {
  let current = root;
  for (const key of path) {
    if (!current || typeof current !== "object") return null;
    current = (current as Record<string, unknown>)[key];
  }
  return current ?? null;
}

function primitiveValue(value: unknown): string | number | boolean | null {
  if (value === undefined || value === null || value === "") return null;
  if (["string", "number", "boolean"].includes(typeof value)) return value as string | number | boolean;
  return null;
}

function fieldPrimitive(field: unknown): string | number | boolean | null {
  const direct = primitiveValue(field);
  if (direct !== null) return direct;

  if (!field || typeof field !== "object") return null;
  const obj = field as Record<string, unknown>;

  const value = primitiveValue(obj.value);
  if (value !== null) return value;

  const items = obj.items;
  if (Array.isArray(items)) {
    for (const item of items) {
      const itemValue = fieldPrimitive(item);
      if (itemValue !== null) return itemValue;
    }
  }

  return null;
}

function stringValue(value: unknown) {
  const resolved = fieldPrimitive(value);
  if (resolved === null) return null;
  return String(resolved).trim() || null;
}

function numberValue(value: unknown) {
  const resolved = fieldPrimitive(value);
  if (resolved === null) return null;
  const n = Number(resolved);
  return Number.isFinite(n) ? Math.round(n * 100) / 100 : null;
}

function dateValue(value: unknown) {
  const resolved = stringValue(value);
  if (!resolved) return null;
  return /^\d{4}-\d{2}-\d{2}$/.test(resolved) ? resolved : null;
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

function hasInferenceResult(raw: unknown) {
  return Boolean(getByPath(raw, ["inference", "result", "fields"]) || getByPath(raw, ["result", "fields"]));
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

function normalizeV2InvoiceLine(line: unknown, lineOrder: number): ParsedLine | null {
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
    numberValue(row.unit_price) ??
    null;
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

  const ocrDocumentRef = firstStringFrom(fields, [
    "invoice_number",
    "invoice_ref",
    "invoice_id",
    "reference_numbers",
    "reference",
    "document_number",
    "po_number",
  ]);
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
  const lines = lineItems.map((line, index) => normalizeV2InvoiceLine(line, index + 1)).filter((line): line is ParsedLine => Boolean(line));

  const referenceParts = [
    ocrDocumentRef,
    firstStringFrom(fields, ["purchase_order", "order_number", "booking_ref", "tracking_number"]),
    stringValue(getByPath(raw, ["inference", "result", "raw_text"])),
    stringValue(getByPath(raw, ["inference", "raw_text"])),
  ].filter((part): part is string => Boolean(part));

  return {
    ocrShipperName,
    ocrReferenceText: Array.from(new Set(referenceParts)).join(" ") || null,
    ocrDocumentRef,
    ocrDocumentDate,
    ocrTotalAmount,
    lines,
  };
}

function errorPayload(error: unknown) {
  return {
    ok: false,
    route: "mindee_shipping_webhook",
    error: error instanceof Error ? error.message : String(error),
    error_name: error instanceof Error ? error.name : typeof error,
  };
}

function requireWebhookToken(url: URL) {
  const expected = process.env.MINDEE_SHIPPING_WEBHOOK_TOKEN?.trim();
  if (!expected) {
    return NextResponse.json({
      ok: false,
      route: "mindee_shipping_webhook",
      error: "MINDEE_SHIPPING_WEBHOOK_TOKEN is required for real shipping OCR webhook POSTs.",
    }, { status: 500 });
  }
  const received = url.searchParams.get("token")?.trim() || "";
  if (received !== expected) {
    return NextResponse.json({
      ok: false,
      route: "mindee_shipping_webhook",
      error: "Invalid or missing shipping webhook token.",
    }, { status: 401 });
  }
  return null;
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

async function handlePost(request: Request) {
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

  const tokenFailure = requireWebhookToken(url);
  if (tokenFailure) return tokenFailure;

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
  if (!shippingDoc) return NextResponse.json({ error: "no matching shipping document found for Mindee webhook", job_id: jobId, inference_id: inferenceId }, { status: 404 });

  if (!hasInferenceResult(raw)) {
    return NextResponse.json({
      ok: true,
      processed: false,
      reason: "Webhook payload did not contain inference.result.fields yet.",
      shipping_document_id: shippingDoc.id,
      job_id: jobId,
      inference_id: inferenceId,
    });
  }

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
  return NextResponse.json({
    ok: true,
    processed: true,
    shipping_document_id: shippingDoc.id,
    ocr_match_status: row?.ocr_match_status ?? null,
    inserted_line_count: row?.inserted_line_count ?? parsed.lines.length,
  });
}

export async function POST(request: Request) {
  try {
    return await handlePost(request);
  } catch (error) {
    return NextResponse.json(errorPayload(error), { status: 500 });
  }
}
