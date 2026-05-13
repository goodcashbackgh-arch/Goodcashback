import { NextResponse } from "next/server";
import { createClient } from "@/utils/supabase/server";

const MINDEE_V2_API_BASE = "https://api-v2.mindee.net/v2";

type ParsedLine = {
  description: string;
  quantity: number;
  amount_gbp: number;
};

function cleanText(value: unknown) {
  return String(value ?? "").trim();
}

function getMindeeKey() {
  return process.env.MINDEE_V2_API_KEY?.trim() || process.env.MINDEE_API_KEY?.trim() || "";
}

function getByPath(root: unknown, path: string[]) {
  let current = root;
  for (const key of path) {
    if (!current || typeof current !== "object") return null;
    current = (current as Record<string, unknown>)[key];
  }
  return current ?? null;
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
  return stringValue(job?.id ?? inferenceJob?.id ?? obj.job_id ?? obj.id);
}

function extractMindeeInferenceId(raw: unknown) {
  if (!raw || typeof raw !== "object") return null;
  const obj = raw as Record<string, unknown>;
  const inference = obj.inference && typeof obj.inference === "object" ? obj.inference as Record<string, unknown> : null;
  const job = obj.job && typeof obj.job === "object" ? obj.job as Record<string, unknown> : null;
  return stringValue(inference?.id ?? job?.inference_id ?? obj.inference_id ?? obj.id);
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
  const quantity = Math.max(0, Math.round(numberValue(row.quantity) ?? numberValue(row.qty) ?? 1));
  const amount_gbp =
    numberValue(row.total_amount) ??
    numberValue(row.total_price) ??
    numberValue(row.amount) ??
    numberValue(row.line_total) ??
    numberValue(row.unit_price) ??
    null;
  if (!description || amount_gbp === null || amount_gbp < 0) return null;
  return { description, quantity, amount_gbp };
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
  const lines = lineItems
    .map((line, index) => normalizeV2InvoiceLine(line, index + 1))
    .filter((line): line is ParsedLine => Boolean(line));
  const referenceText = [
    ocrDocumentRef,
    firstStringFrom(fields, ["purchase_order", "po_number", "order_number", "booking_ref", "tracking_number", "reference", "document_number"]),
    stringValue(getByPath(raw, ["inference", "result", "raw_text"])),
    stringValue(getByPath(raw, ["inference", "raw_text"])),
  ].filter(Boolean).join(" ").trim() || null;
  return { ocrShipperName, ocrReferenceText: referenceText, ocrDocumentRef, ocrDocumentDate, ocrTotalAmount, lines };
}

async function fetchMindee(path: string, apiKey: string) {
  const response = await fetch(`${MINDEE_V2_API_BASE}${path}`, {
    method: "GET",
    headers: { Accept: "application/json", Authorization: apiKey },
    cache: "no-store",
  });
  const raw = await response.json().catch(async () => ({ non_json_body: await response.text().catch(() => null) }));
  return {
    url: `${MINDEE_V2_API_BASE}${path}`,
    status: response.status,
    ok: response.ok,
    raw,
  };
}

async function saveFetchedResult({ supabase, doc, raw }: { supabase: Awaited<ReturnType<typeof createClient>>; doc: any; raw: unknown }) {
  const parsed = parseMindeeV2InvoiceResult(raw);
  return await (supabase as any).rpc("internal_staff_save_shipping_mindee_ocr_result_v1", {
    p_shipping_document_id: doc.shipping_document_id,
    p_model_id: doc.mindee_model_id,
    p_http_status: 200,
    p_mindee_job_id: extractMindeeJobId(raw) ?? doc.mindee_job_id,
    p_mindee_inference_id: extractMindeeInferenceId(raw) ?? doc.mindee_inference_id,
    p_raw_json: raw,
    p_ocr_shipper_name: parsed.ocrShipperName,
    p_ocr_reference_text: parsed.ocrReferenceText,
    p_ocr_document_ref: parsed.ocrDocumentRef,
    p_ocr_document_date: parsed.ocrDocumentDate,
    p_ocr_total_amount: parsed.ocrTotalAmount,
    p_pages_consumed: extractPagesConsumed(raw),
    p_lines: parsed.lines,
  });
}

export async function GET(request: Request) {
  const url = new URL(request.url);
  const shippingDocumentId = cleanText(url.searchParams.get("shipping_document_id"));
  const save = url.searchParams.get("save") === "1";

  if (!shippingDocumentId) {
    return NextResponse.json({ error: "shipping_document_id query parameter is required" }, { status: 400 });
  }

  const apiKey = getMindeeKey();
  if (!apiKey) {
    return NextResponse.json({ error: "MINDEE_V2_API_KEY is not configured" }, { status: 500 });
  }

  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: "not authenticated" }, { status: 401 });

  const { data: staff } = await supabase
    .from("staff")
    .select("id, role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!staff || !["admin", "supervisor"].includes(String(staff.role_type))) {
    return NextResponse.json({ error: "admin/supervisor staff required" }, { status: 403 });
  }

  const { data: contextData, error: contextError } = await (supabase as any).rpc("internal_shipping_mindee_polling_context_v1", {
    p_shipping_document_id: shippingDocumentId,
  });

  if (contextError) return NextResponse.json({ error: contextError.message }, { status: 500 });
  const doc = Array.isArray(contextData) ? contextData[0] : null;
  if (!doc) return NextResponse.json({ error: "shipping document not found" }, { status: 404 });

  const jobId = cleanText(doc.mindee_job_id);
  const inferenceId = cleanText(doc.mindee_inference_id);
  const output: Record<string, unknown> = {
    ok: true,
    route: "shipping_mindee_raw_debug",
    note: "This endpoint does not send the document to Mindee. It only reads stored ids and fetches raw Mindee job/inference responses for debugging. Add &save=1 to persist a fetched result that contains inference.result.fields.",
    shipping_document: {
      shipping_document_id: doc.shipping_document_id,
      ocr_status: doc.ocr_status,
      review_status: doc.review_status,
      mindee_model_id: doc.mindee_model_id,
      mindee_job_id: doc.mindee_job_id,
      mindee_inference_id: doc.mindee_inference_id,
      polling_url: doc.polling_url,
      result_url: doc.result_url,
    },
    mindee: {},
  };

  const mindee: Record<string, unknown> = {};
  const fetchedResults: unknown[] = [];

  if (jobId) {
    const job = await fetchMindee(`/jobs/${encodeURIComponent(jobId)}`, apiKey);
    mindee.job = job;
    if (job.ok && hasInferenceResult(job.raw)) fetchedResults.push(job.raw);
  }
  if (inferenceId) {
    const inference = await fetchMindee(`/inferences/${encodeURIComponent(inferenceId)}`, apiKey);
    mindee.inference = inference;
    if (inference.ok && hasInferenceResult(inference.raw)) fetchedResults.push(inference.raw);
  }
  output.mindee = mindee;

  if (save) {
    if (fetchedResults.length === 0) {
      output.save = { attempted: true, saved: false, reason: "No fetched Mindee response contained inference.result.fields." };
    } else {
      const { data: saveData, error: saveError } = await saveFetchedResult({ supabase, doc, raw: fetchedResults[0] });
      if (saveError) {
        output.save = { attempted: true, saved: false, error: saveError.message };
      } else {
        const row = Array.isArray(saveData) ? saveData[0] : null;
        output.save = { attempted: true, saved: true, inserted_line_count: row?.inserted_line_count ?? null, ocr_match_status: row?.ocr_match_status ?? null };
      }
    }
  }

  return NextResponse.json(output, { status: 200 });
}
