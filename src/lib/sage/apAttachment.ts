import crypto from "node:crypto";
import { supabaseAdmin } from "@/lib/supabase/admin";
import {
  assertSageOAuthConfigured,
  decryptSecret,
  encryptSecret,
  exchangeSageToken,
  redactedTokenPayload,
  scopesFromToken,
  tokenExpiresAt,
  tokenRefreshRequired,
} from "@/lib/sage/oauth";
import {
  buildSageAttachmentJsonAttempts,
  type SageAttachmentJsonAttempt,
} from "@/lib/sage/apAttachmentAttempts";

type Row = Record<string, any>;
type JsonAttempt = SageAttachmentJsonAttempt;

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
    .select("id, connection_id, access_token_encrypted, refresh_token_encrypted, token_type, expires_at, scopes, sage_business_row_id")
    .eq("status", "active")
    .order("expires_at", { ascending: false })
    .limit(1);
  if (tokenError) throw new Error(tokenError.message);
  const token = (tokenRows?.[0] ?? null) as Row | null;
  if (!token) throw new Error("No active Sage OAuth token found.");

  const { data: connection, error: connectionError } = await supabaseAdmin
    .from("sage_connections")
    .select("id, status")
    .eq("id", token.connection_id)
    .maybeSingle();
  if (connectionError) throw new Error(connectionError.message);
  if (!connection || connection.status !== "connected") throw new Error("Sage connection is not connected.");

  let accessToken = decryptSecret(text(token.access_token_encrypted));
  let sageBusinessRowId = text(token.sage_business_row_id);

  if (tokenRefreshRequired(token.expires_at)) {
    const refreshed = await exchangeSageToken({
      tokenUrl: config.tokenUrl,
      clientId: config.clientId,
      clientSecret: config.clientSecret,
      grantType: "refresh_token",
      refreshToken: decryptSecret(text(token.refresh_token_encrypted)),
    });

    if (!refreshed.response.ok || !refreshed.raw.access_token || !refreshed.raw.refresh_token) {
      await supabaseAdmin.from("sage_connections").update({
        status: "refresh_failed",
        last_error_code: "token_refresh_failed",
        last_error_message: JSON.stringify(redactedTokenPayload(refreshed.raw)),
        updated_at: new Date().toISOString(),
      }).eq("id", token.connection_id);
      throw new Error(`Sage token refresh failed (${refreshed.response.status}).`);
    }

    await supabaseAdmin.from("sage_oauth_tokens").update({
      status: "superseded",
      superseded_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    }).eq("id", token.id);

    const expiresAt = tokenExpiresAt(refreshed.raw.expires_in);
    const { data: inserted, error: insertError } = await supabaseAdmin.from("sage_oauth_tokens").insert({
      connection_id: token.connection_id,
      sage_business_row_id: token.sage_business_row_id,
      access_token_encrypted: encryptSecret(refreshed.raw.access_token),
      refresh_token_encrypted: encryptSecret(refreshed.raw.refresh_token),
      token_type: refreshed.raw.token_type || "Bearer",
      expires_at: expiresAt,
      scopes: scopesFromToken(refreshed.raw, config.scopes),
      status: "active",
      encryption_key_ref: "SAGE_TOKEN_ENCRYPTION_KEY:v1",
      issued_at: new Date().toISOString(),
      last_refresh_at: new Date().toISOString(),
    }).select("id, sage_business_row_id").single();
    if (insertError) throw new Error(insertError.message);

    accessToken = refreshed.raw.access_token;
    sageBusinessRowId = text(inserted?.sage_business_row_id) || sageBusinessRowId;
  }

  let businessQuery = supabaseAdmin
    .from("sage_businesses")
    .select("id, sage_business_id")
    .eq("connection_id", token.connection_id)
    .eq("status", "active")
    .order("is_primary", { ascending: false })
    .limit(1);
  if (sageBusinessRowId) businessQuery = businessQuery.eq("id", sageBusinessRowId);

  const { data: businesses, error: businessError } = await businessQuery;
  if (businessError) throw new Error(businessError.message);
  const business = (businesses?.[0] ?? null) as Row | null;
  if (!business?.sage_business_id) throw new Error("No active Sage business selected for attachment.");

  return {
    apiBaseUrl: config.apiBaseUrl.replace(/\/$/, ""),
    accessToken,
    connectionId: text(token.connection_id),
    sageBusinessRowId: text(business.id),
    sageBusinessId: text(business.sage_business_id),
  };
}

function jsonAttempts(args: {
  sageInvoiceId: string;
  sourceUrl: string;
  fileName: string;
  contentType: string;
  base64: string;
  byteLength: number;
}): JsonAttempt[] {
  return buildSageAttachmentJsonAttempts({
    configuredEndpointTemplate: process.env.SAGE_PURCHASE_INVOICE_ATTACHMENT_ENDPOINT_TEMPLATE,
    sageInvoiceId: args.sageInvoiceId,
    sourceUrl: args.sourceUrl,
    fileName: args.fileName,
    mimeType: args.contentType,
    encodedFile: args.base64,
    byteLength: args.byteLength,
  });
}

async function logRequest(args: {
  ctx: Awaited<ReturnType<typeof sageContext>>;
  snapshot: Row;
  staffId: string;
  endpoint: string;
  auditPayload: Row;
  label: string;
}) {
  const { data, error } = await supabaseAdmin.from("sage_api_request_log").insert({
    connection_id: args.ctx.connectionId,
    sage_business_row_id: args.ctx.sageBusinessRowId,
    posting_batch_id: args.snapshot.batch_id || null,
    connection_event_type: "posting_batch",
    request_kind: "other",
    http_method: "POST",
    endpoint_path: args.endpoint,
    idempotency_key: `attachment:${args.snapshot.id}:${args.endpoint}:${args.label}`,
    request_payload_redacted: {
      request_kind_actual: "attachment",
      attachment_attempt_label: args.label,
      ...args.auditPayload,
    },
    request_headers_redacted: { accept: "application/json", content_type: "application/json", x_business: args.ctx.sageBusinessId },
    request_payload_hash: bodyHash(args.auditPayload),
    created_by_staff_id: args.staffId,
  }).select("id").single();

  if (error) throw new Error(`Could not log Sage attachment request: ${error.message}`);
  return text(data?.id);
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
  const bytes = Buffer.from(await pdf.arrayBuffer());
  const base64 = bytes.toString("base64");
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

  let finalError = "Sage JSON attachment request failed.";
  let finalStatus = 0;

  for (const attempt of jsonAttempts({
    sageInvoiceId: text(snapshot.sage_invoice_id),
    sourceUrl: url,
    fileName: name,
    contentType,
    base64,
    byteLength: bytes.byteLength,
  })) {
    const requestLogId = await logRequest({
      ctx,
      snapshot,
      staffId: params.staffId,
      endpoint: attempt.endpoint,
      auditPayload: attempt.auditPayload,
      label: attempt.label,
    });

    let response: Response | null = null;
    let raw: unknown = {};
    const started = Date.now();
    try {
      response = await fetch(`${ctx.apiBaseUrl}${attempt.endpoint}`, {
        method: "POST",
        headers: {
          Accept: "application/json",
          Authorization: `Bearer ${ctx.accessToken}`,
          "X-Business": ctx.sageBusinessId,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(attempt.payload),
        cache: "no-store",
      });
      raw = await response.json().catch(async () => ({ non_json_body: await response!.text().catch(() => null) }));
    } catch (error) {
      raw = { error: error instanceof Error ? error.message : "Network error calling Sage attachment endpoint." };
    }

    const ok = Boolean(response?.ok);
    const objectId = ok ? attachmentId(raw) : "";
    finalStatus = response?.status ?? 0;
    finalError = errorMessage(raw);

    await supabaseAdmin.from("sage_api_response_log").insert({
      request_log_id: requestLogId,
      connection_id: ctx.connectionId,
      sage_business_row_id: ctx.sageBusinessRowId,
      http_status: response?.status ?? null,
      success_yn: ok,
      sage_object_type: "purchase_invoice_attachment",
      sage_object_id: objectId || null,
      sage_reference: text(snapshot.reference_text) || null,
      response_payload_redacted: raw as Row,
      error_code: ok ? null : (response ? `sage_http_${response.status}` : "sage_network_error"),
      error_message: ok ? null : finalError,
      duration_ms: Date.now() - started,
    });

    if (ok) {
      await supabaseAdmin.from("sage_posting_snapshots").update({
        sage_attachment_status: "attached",
        sage_attachment_object_id: objectId || null,
        sage_attachment_attached_at: new Date().toISOString(),
        sage_attachment_error_code: null,
        sage_attachment_error_message: null,
      }).eq("id", params.snapshotId);
      return { attached: 1, failed: 0, endpoint: attempt.endpoint, fieldName: attempt.label, objectId };
    }
  }

  const terminal = finalStatus === 400 || finalStatus === 401 || finalStatus === 403 || finalStatus === 404 || finalStatus === 405 || finalStatus === 415 || finalStatus === 422;
  await supabaseAdmin.from("sage_posting_snapshots").update({
    sage_attachment_status: terminal ? "failed_terminal" : "failed_retryable",
    sage_attachment_error_code: finalStatus ? `sage_http_${finalStatus}` : "sage_attachment_json_attempts_failed",
    sage_attachment_error_message: finalError,
  }).eq("id", params.snapshotId);

  throw new Error(finalError);
}
