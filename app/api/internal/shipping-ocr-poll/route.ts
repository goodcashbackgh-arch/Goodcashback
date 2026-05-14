import { NextResponse } from "next/server";
import { supabaseAdmin } from "@/lib/supabase/admin";

export const dynamic = "force-dynamic";
export const maxDuration = 60;

const MINDEE_V2_API_BASE = "https://api-v2.mindee.net/v2";

type ParsedLine = {
  description: string;
  quantity: number;
  amount_gbp: number;
};

type ShippingDoc = {
  id: string;
  mindee_model_id: string | null;
  mindee_job_id: string | null;
  mindee_inference_id: string | null;
  ocr_status: string | null;
  review_status: string | null;
};

function cleanText(value: unknown) {
  return String(value ?? "").trim();
}

function recordValue(value: unknown) {
  if (value === undefined || value === null || value === "") return null;
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

function jobRecord(raw: unknown) {
  if (!raw || typeof raw !== "object") return {} as Record<string, unknown>;
  const root = raw as Record<string, unknown>;
  if (root.job && typeof root.job === "object" && !Array.isArray(root.job)) return root.job as Record<string, unknown>;
  return root;
}

function jobField(raw: unknown, key: string) {
  const job = jobRecord(raw);
  return job[key] ?? (raw && typeof raw === "object" ? (raw as Record<string, unknown>)[key] : null) ?? null;
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

function parseMindeeDetail(raw: unknown) {
  if (!raw || typeof raw !== "object") return "";
  const obj = raw as Record<string, unknown>;
  const detail = obj.detail ?? obj.title ?? obj.message ?? obj.error ?? obj.errors;
  if (detail === undefined || detail === null) return "";
  return typeof detail === "string" ? detail.slice(0, 700) : JSON.stringify(detail).slice(0, 700);
}

function hasInferenceResult(raw: unknown) {
  return Boolean(getByPath(raw, ["inference", "result", "fields"]) || getByPath(raw, ["result", "fields"]));
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

function getMindeeKey() {
  return process.env.MINDEE_V2_API_KEY?.trim() || process.env.MINDEE_API_KEY?.trim() || "";
}

async function fetchMindeeApi(pathOrUrl: string, apiKey: string) {
  const url = /^https?:\/\//i.test(pathOrUrl) ? pathOrUrl : `${MINDEE_V2_API_BASE}${pathOrUrl}`;
  const response = await fetch(url, {
    method: "GET",
    headers: { Accept: "application/json", Authorization: apiKey },
    cache: "no-store",
    redirect: "follow",
  });
  const raw = await response.json().catch(async () => ({ non_json_body: await response.text().catch(() => null) }));
  return { response, raw };
}

async function saveMindeeResult({
  doc,
  raw,
  fallbackJobId,
  fallbackInferenceId,
}: {
  doc: ShippingDoc;
  raw: unknown;
  fallbackJobId: string | null;
  fallbackInferenceId: string | null;
}) {
  const parsed = parseMindeeV2InvoiceResult(raw);
  return await (supabaseAdmin as any).rpc("internal_save_shipping_mindee_ocr_result_v1", {
    p_shipping_document_id: doc.id,
    p_model_id: doc.mindee_model_id,
    p_http_status: 200,
    p_mindee_job_id: extractMindeeJobId(raw) ?? fallbackJobId,
    p_mindee_inference_id: extractMindeeInferenceId(raw) ?? fallbackInferenceId,
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

async function checkAndSaveOne(doc: ShippingDoc, apiKey: string) {
  const jobId = cleanText(doc.mindee_job_id);
  const storedInferenceId = cleanText(doc.mindee_inference_id);

  if (!jobId && !storedInferenceId) {
    return { id: doc.id, status: "skipped", reason: "missing_job_and_inference_id" };
  }

  if (jobId) {
    const jobFetch = await fetchMindeeApi(`/jobs/${encodeURIComponent(jobId)}`, apiKey);
    if (!jobFetch.response.ok) {
      if (jobFetch.response.status === 404) {
        return { id: doc.id, status: "not_ready", reason: `Mindee job ${jobId} is not ready or is not available yet (404).` };
      }
      return { id: doc.id, status: "error", reason: `Mindee job fetch failed (${jobFetch.response.status}). ${parseMindeeDetail(jobFetch.raw) || "No detail returned."}` };
    }

    if (hasInferenceResult(jobFetch.raw)) {
      const { data, error } = await saveMindeeResult({
        doc,
        raw: jobFetch.raw,
        fallbackJobId: jobId,
        fallbackInferenceId: storedInferenceId || extractMindeeInferenceId(jobFetch.raw),
      });
      if (error) return { id: doc.id, status: "error", reason: error.message };
      const parsed = parseMindeeV2InvoiceResult(jobFetch.raw);
      const row = Array.isArray(data) ? data[0] : null;
      return {
        id: doc.id,
        status: "saved",
        source: "job_response",
        inserted_line_count: row?.inserted_line_count ?? parsed.lines.length,
        ocr_match_status: row?.ocr_match_status ?? "needs_review",
      };
    }

    const status = cleanText(jobField(jobFetch.raw, "status"));
    const resultUrl = stringValue(jobField(jobFetch.raw, "result_url"));
    if (resultUrl) {
      const resultFetch = await fetchMindeeApi(resultUrl, apiKey);
      if (!resultFetch.response.ok) {
        return { id: doc.id, status: "error", reason: `Mindee result fetch failed (${resultFetch.response.status}). ${parseMindeeDetail(resultFetch.raw) || "No detail returned."}` };
      }
      const { data, error } = await saveMindeeResult({ doc, raw: resultFetch.raw, fallbackJobId: jobId, fallbackInferenceId: storedInferenceId });
      if (error) return { id: doc.id, status: "error", reason: error.message };
      const parsed = parseMindeeV2InvoiceResult(resultFetch.raw);
      const row = Array.isArray(data) ? data[0] : null;
      return {
        id: doc.id,
        status: "saved",
        source: "result_url",
        inserted_line_count: row?.inserted_line_count ?? parsed.lines.length,
        ocr_match_status: row?.ocr_match_status ?? "needs_review",
      };
    }

    const inferenceIdFromJob = extractMindeeInferenceId(jobFetch.raw);
    if (!inferenceIdFromJob && !storedInferenceId) {
      return { id: doc.id, status: "not_ready", reason: `Mindee job ${jobId} is still ${status || "processing"}.` };
    }
  }

  const inferenceId = storedInferenceId || "";
  if (!inferenceId) {
    return { id: doc.id, status: "not_ready", reason: `Mindee job ${jobId || "—"} has no separate inference id yet.` };
  }

  const inferenceFetch = await fetchMindeeApi(`/inferences/${encodeURIComponent(inferenceId)}`, apiKey);
  if (!inferenceFetch.response.ok) {
    if (inferenceFetch.response.status === 404) {
      return { id: doc.id, status: "not_ready", reason: `Mindee inference ${inferenceId} is not ready yet (404).` };
    }
    return { id: doc.id, status: "error", reason: `Mindee inference fetch failed (${inferenceFetch.response.status}). ${parseMindeeDetail(inferenceFetch.raw) || "No detail returned."}` };
  }

  const { data, error } = await saveMindeeResult({ doc, raw: inferenceFetch.raw, fallbackJobId: jobId, fallbackInferenceId: inferenceId });
  if (error) return { id: doc.id, status: "error", reason: error.message };
  const parsed = parseMindeeV2InvoiceResult(inferenceFetch.raw);
  const row = Array.isArray(data) ? data[0] : null;
  return {
    id: doc.id,
    status: "saved",
    source: "inference_response",
    inserted_line_count: row?.inserted_line_count ?? parsed.lines.length,
    ocr_match_status: row?.ocr_match_status ?? "needs_review",
  };
}

function authorized(request: Request) {
  const expected = process.env.CRON_SECRET?.trim();
  if (!expected) return { ok: false, status: 500, error: "CRON_SECRET is not configured." };
  const received = request.headers.get("authorization")?.trim() || "";
  if (received !== `Bearer ${expected}`) return { ok: false, status: 401, error: "Unauthorized." };
  return { ok: true, status: 200, error: null };
}

export async function GET(request: Request) {
  const auth = authorized(request);
  if (!auth.ok) return NextResponse.json({ ok: false, error: auth.error }, { status: auth.status });

  const apiKey = getMindeeKey();
  if (!apiKey) return NextResponse.json({ ok: false, error: "MINDEE_V2_API_KEY is not configured." }, { status: 500 });

  const { data, error } = await supabaseAdmin
    .from("shipping_documents")
    .select("id, mindee_model_id, mindee_job_id, mindee_inference_id, ocr_status, review_status")
    .eq("active", true)
    .in("ocr_status", ["processing"])
    .not("mindee_job_id", "is", null)
    .order("updated_at", { ascending: true })
    .limit(5);

  if (error) return NextResponse.json({ ok: false, error: error.message }, { status: 500 });

  const docs = (data ?? []) as ShippingDoc[];
  const results = [];
  for (const doc of docs) {
    if (doc.review_status === "accepted_current" || doc.review_status === "superseded") {
      results.push({ id: doc.id, status: "skipped", reason: "locked_review_status" });
    } else {
      results.push(await checkAndSaveOne(doc, apiKey));
    }
  }

  const savedCount = results.filter((row) => row.status === "saved").length;
  const errorCount = results.filter((row) => row.status === "error").length;

  return NextResponse.json({
    ok: errorCount === 0,
    route: "shipping_ocr_poll_manual_path",
    polled_count: docs.length,
    saved_count: savedCount,
    not_ready_count: results.filter((row) => row.status === "not_ready").length,
    skipped_count: results.filter((row) => row.status === "skipped").length,
    error_count: errorCount,
    results,
    timestamp: new Date().toISOString(),
  }, { status: errorCount > 0 ? 207 : 200 });
}
