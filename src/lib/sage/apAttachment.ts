import crypto from "node:crypto";
import { supabaseAdmin } from "@/lib/supabase/admin";
import { assertSageOAuthConfigured, decryptSecret } from "@/lib/sage/oauth";

type Row = Record<string, any>;

function asObject(value: unknown): Row {
  return value && typeof value === "object" && !Array.isArray(value) ? (value as Row) : {};
}

function text(value: unknown) {
  if (typeof value === "string") return value.trim();
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return "";
}

function getPath(value: unknown, path: Array<string | number>): unknown {
  let current = value;
  for (const part of path) {
    if (typeof part === "number") {
      if (!Array.isArray(current)) return undefined;
      current = current[part];
    } else {
      if (!current || typeof current !== "object" || Array.isArray(current)) return undefined;
      current = (current as Row)[part];
    }
  }
  return current;
}

function firstText(value: unknown, paths: Array<Array<string | number>>) {
  for (const path of paths) {
    const found = text(getPath(value, path));
    if (found) return found;
  }
  return "";
}

function bodyHash(value: unknown) {
  return crypto.createHash("sha256").update(JSON.stringify(value ?? {})).digest("hex");
}

function errorMessage(raw: unknown) {
  if (Array.isArray(raw)) {
    const messages = raw
      .map((item) => {
        const row = asObject(item);
        return text(row.$message) || text(row.message) || text(row.error_description) || text(row.error) || text(row.detail);
      })
      .filter(Boolean);
    if (messages.length) return messages.join(" | ");
  }
  const root = asObject(raw);
  return text(root.message) || text(root.error_description) || text(root.error) || text(root.detail) || "Sage attachment request failed.";
}

function attachmentId(raw: unknown) {
  return firstText(raw, [["id"], ["attachment", "id"], ["data", "id"], ["$items", 0, "id"]]);
}

function sourceUrl(snapshot: Row) {
  return firstText(snapshot, [
    ["sage_attachment_source_url"],
    ["resolved_payload", "source_evidence", "file_url"],
    ["resolved_payload", "source_payload", "supplier_invoice_pdf_url"],
    ["resolved_payload", "source_payload", "invoice_pdf_url"],
    ["commercial_payload", "source_evidence", "file_url"],
    ["commercial_payload", "supplier_invoice_pdf_url"],
    ["commercial_payload", "invoice_pdf_url"],
  ]);
}

function fileName(snapshot: Row) {
  const base = text(snapshot.reference_text) || text(snapshot.order_ref) || text(snapshot.source_id) || "supplier_invoice";
  return `${base.replace(/[^a-zA-Z0-9._-]+/g, "_")}.pdf`;
}

async function sageContext(origin: string) {
  const config = assertSageOAuthConfigured(origin);
  const { data: tokenRows, error: tokenError } = await supabaseAdmin
    .from("sage_oauth_tokens")
    .select("connection_id, access_token_encrypted, expires_at, sage_business_row_id")
    .eq("status", "active")
    .order("expires_at", { ascending: false })
    .limit(1);
  if (tokenError) throw new Error(tokenError.message);
  const token = (tokenRows?.[0] ?? null) as Row | null;
  if (!token) throw new Error("No active Sage OAuth token found.");

  const expiresAt = Date.parse(text(token.expires_at));
  if (Number.isFinite(expiresAt) && expiresAt < Date.now() + 60_000) {
    throw new Error("Sage OAuth token is near expiry. Refresh the Sage connection before attaching evidence.");
  }

  let businessQuery = supabaseAdmin
    .from("sage_businesses")
    .select("id, sage_business_id")
    .eq("connection_id", token.connection_id)
    .eq("status", "active")
    .order("is_primary", { ascending: false })
    .limit(1);
  const businessRowId = text(token.sage_business_row_id);
  if (businessRowId) businessQuery = businessQuery.eq("id", businessRowId);

  const { data: businesses, error: businessError } = await businessQuery;
  if (businessError) throw new Error(businessError.message);
  const business = (businesses?.[0] ?? null) as Row | null;
  if (!business?.sage_business_id) throw new Error("No active Sage business selected for attachment.");

  return {
    apiBaseUrl: config.apiBaseUrl.replace(/\/$/, ""),
    accessToken: decryptSecret(text(token.access_token_encrypted)),
    connectionId: text(token.connection_id),
    sageBusinessRowId: text(business.id),
    sageBusinessId: text(business.sage_business_id),
  };
}

function candidateAttempts(sageInvoiceId: string, name: string) {
  const id = encodeURIComponent(sageInvoiceId);
  const configured = text(process.env.SAGE_PURCHASE_INVOICE_ATTACHMENT_ENDPOINT_TEMPLATE);
  const endpoints = configured
    ? [configured.replaceAll("{purchase_invoice_id}", id).replaceAll("{id}", id).replaceAll("{sage_object_id}", id)]
    : [`/purchase_invoices/${id}/attachments`, "/attachments"];

  const attempts: Array<{ endpoint: string; fieldName: string; meta: Record<string, string> }> = [];
  for (const endpoint of endpoints) {
    attempts.push({ endpoint, fieldName: text(process.env.SAGE_ATTACHMENT_FILE_FIELD_NAME) || "file", meta: {} });
    attempts.push({ endpoint, fieldName: "attachment[file]", meta: {} });
    if (endpoint === "/attachments") {
      attempts.push({ endpoint, fieldName: "file", meta: { context_type: "purchase_invoice", context_id: sageInvoiceId, description: name } });
      attempts.push({ endpoint, fieldName: "attachment[file]", meta: { "attachment[context_type]": "purchase_invoice", "attachment[context_id]": sageInvoiceId, "attachment[description]": name } });
    }
  }
  return attempts;
}

export async function attachSupplierGoodsApSourcePdfToSage(params: { snapshotId: string; staffId: string; origin: string }) {
  if (process.env.SAGE_LIVE_POSTING_ENABLED !== "true") throw new Error("Live Sage posting is disabled. Attachment calls are disabled too.");

  const { data: snapshotRaw, error: snapshotError } = await supabaseAdmin
    .from("sage_posting_snapshots")
    .select("*")
    .eq("id", params.snapshotId)
    .maybeSingle();
  if (snapshotError) throw new Error(snapshotError.message);
  const snapshot = (snapshotRaw ?? null) as Row | null;
  if (!snapshot) throw new Error("Sage posting snapshot not found.");
  if (text(snapshot.document_lane) !== "supplier_goods_ap") throw new Error("Only supplier goods AP attachments are supported here.");
  if (text(snapshot.sage_posting_status) !== "posted" || !text(snapshot.sage_invoice_id)) throw new Error("Supplier AP must be posted before attaching evidence.");
  if (text(snapshot.sage_attachment_status) === "attached") throw new Error("Source PDF is already marked attached.");

  const url = sourceUrl(snapshot);
  if (!url) throw new Error("No source PDF URL found on this posted supplier AP snapshot.");

  const ctx = await sageContext(params.origin);
  const pdf = await fetch(url, { cache: "no-store" });
  if (!pdf.ok) throw new Error(`Could not fetch source PDF (${pdf.status}).`);
  const contentType = pdf.headers.get("content-type") || "application/pdf";
  const bytes = await pdf.arrayBuffer();
  const name = fileName(snapshot);

  await supabaseAdmin.from("sage_posting_snapshots").update({
    sage_attachment_status: "pending",
    sage_attachment_attempt_count: Number(snapshot.sage_attachment_attempt_count ?? 0) + 1,
    sage_attachment_source_url: url,
    sage_attachment_file_name: name,
    sage_attachment_error_code: null,
    sage_attachment_error_message: null,
    sage_attachment_attempted_at: new Date().toISOString(),
  }).eq("id", params.snapshotId);

  let finalError = "Sage attachment request failed.";
  for (const attempt of candidateAttempts(text(snapshot.sage_invoice_id), name)) {
    const form = new FormData();
    form.append(attempt.fieldName, new Blob([bytes], { type: contentType }), name);
    for (const [key, value] of Object.entries(attempt.meta)) form.append(key, value);

    const auditPayload = {
      sage_purchase_invoice_id: text(snapshot.sage_invoice_id),
      source_table: text(snapshot.source_table),
      source_id: text(snapshot.source_id),
      endpoint: attempt.endpoint,
      file_field_name: attempt.fieldName,
      meta_keys: Object.keys(attempt.meta),
      file_name: name,
      size_bytes: bytes.byteLength,
      content_type: contentType,
    };

    const { data: requestLog } = await supabaseAdmin.from("sage_api_request_log").insert({
      connection_id: ctx.connectionId,
      sage_business_row_id: ctx.sageBusinessRowId,
      posting_batch_id: snapshot.batch_id || null,
      connection_event_type: "posting_batch",
      request_kind: "attachment",
      http_method: "POST",
      endpoint_path: attempt.endpoint,
      idempotency_key: `attach:${params.snapshotId}:${attempt.endpoint}:${attempt.fieldName}`,
      request_payload_redacted: auditPayload,
      request_headers_redacted: { accept: "application/json", content_type: "multipart/form-data", x_business: ctx.sageBusinessId },
      request_payload_hash: bodyHash(auditPayload),
      created_by_staff_id: params.staffId,
    }).select("id").single();

    let response: Response | null = null;
    let raw: unknown = {};
    const started = Date.now();
    try {
      response = await fetch(`${ctx.apiBaseUrl}${attempt.endpoint}`, {
        method: "POST",
        headers: { Accept: "application/json", Authorization: `Bearer ${ctx.accessToken}`, "X-Business": ctx.sageBusinessId },
        body: form,
        cache: "no-store",
      });
      raw = await response.json().catch(async () => ({ non_json_body: await response!.text().catch(() => null) }));
    } catch (error) {
      raw = { error: error instanceof Error ? error.message : "Network error calling Sage attachment endpoint." };
    }

    const ok = Boolean(response?.ok);
    const objectId = ok ? attachmentId(raw) : "";
    if (requestLog?.id) {
      await supabaseAdmin.from("sage_api_response_log").insert({
        request_log_id: requestLog.id,
        connection_id: ctx.connectionId,
        sage_business_row_id: ctx.sageBusinessRowId,
        http_status: response?.status ?? null,
        success_yn: ok,
        sage_object_type: "purchase_invoice_attachment",
        sage_object_id: objectId || null,
        sage_reference: text(snapshot.reference_text) || null,
        response_payload_redacted: raw as Row,
        error_code: ok ? null : (response ? `sage_http_${response.status}` : "sage_network_error"),
        error_message: ok ? null : errorMessage(raw),
        duration_ms: Date.now() - started,
      });
    }

    if (ok) {
      await supabaseAdmin.from("sage_posting_snapshots").update({
        sage_attachment_status: "attached",
        sage_attachment_object_id: objectId || null,
        sage_attachment_attached_at: new Date().toISOString(),
        sage_attachment_error_code: null,
        sage_attachment_error_message: null,
      }).eq("id", params.snapshotId);
      return { attached: 1, failed: 0, endpoint: attempt.endpoint, fieldName: attempt.fieldName, objectId };
    }

    finalError = errorMessage(raw);
  }

  await supabaseAdmin.from("sage_posting_snapshots").update({
    sage_attachment_status: "failed_terminal",
    sage_attachment_error_code: "sage_attachment_all_attempts_failed",
    sage_attachment_error_message: finalError,
  }).eq("id", params.snapshotId);
  throw new Error(finalError);
}
