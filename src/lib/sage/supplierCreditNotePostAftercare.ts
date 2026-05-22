import crypto from "node:crypto";
import { Buffer } from "node:buffer";
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

type Row = Record<string, any>;

type PostedCreditNoteRow = {
  id: string;
  batch_id: string;
  snapshot_id: string | null;
  source_id: string | null;
  source_table: string | null;
  reference_text: string | null;
  order_ref: string | null;
  sage_object_id: string | null;
  sage_reference: string | null;
  request_payload_json: Row;
  response_payload_json: Row;
};

function asObject(value: unknown): Row {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Row : {};
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
    const messages = raw.map((item) => {
      const row = asObject(item);
      return text(row.$message) || text(row.message) || text(row.error_description) || text(row.error) || text(row.detail);
    }).filter(Boolean);
    if (messages.length) return messages.join(" | ");
  }
  const root = asObject(raw);
  return text(root.message) || text(root.error_description) || text(root.error) || text(root.detail) || "Sage attachment request failed.";
}

function attachmentId(raw: unknown) {
  return firstText(raw, [["id"], ["attachment", "id"], ["data", "id"], ["$items", 0, "id"]]);
}

function sourceUrl(payload: Row) {
  return firstText(payload, [
    ["evidence", "credit_note_file_url"],
    ["evidence", "refund_proof_file_url"],
    ["evidence", "file_url"],
    ["credit_note_file_url"],
    ["refund_proof_file_url"],
    ["source_payload", "evidence", "credit_note_file_url"],
    ["source_payload", "evidence", "refund_proof_file_url"],
    ["source_payload", "evidence", "file_url"],
    ["source_payload", "credit_note_file_url"],
    ["source_payload", "refund_proof_file_url"],
  ]);
}

function fileName(row: PostedCreditNoteRow) {
  const base = text(row.reference_text) || text(row.sage_reference) || text(row.order_ref) || text(row.source_id) || "supplier_credit_note";
  return `${base.replace(/[^a-zA-Z0-9._-]+/g, "_")}.pdf`;
}

function transactionIdFromPayload(value: unknown) {
  return firstText(value, [
    ["transaction", "id"],
    ["transaction_id"],
    ["purchase_credit_note", "transaction", "id"],
    ["purchase_credit_note", "transaction_id"],
    ["data", "transaction", "id"],
    ["$items", 0, "transaction", "id"],
  ]);
}

function attachmentLinkedToSource(args: { raw: unknown; sageObjectId: string; sageTransactionId: string }) {
  const directTransaction = firstText(args.raw, [["transaction", "id"], ["transaction_id"], ["attachment_context", "id"], ["attachment_context_id"]]);
  const directOrigin = firstText(args.raw, [["transaction", "origin", "id"], ["attachment_context", "origin", "id"]]);
  const contextType = firstText(args.raw, [["attachment_context_type"], ["context_type"]]).toLowerCase();

  if (args.sageTransactionId && directTransaction === args.sageTransactionId) return true;
  if (args.sageObjectId && directOrigin === args.sageObjectId) return true;
  if (args.sageObjectId && directTransaction === args.sageObjectId) return true;
  if (contextType.includes("transaction") && args.sageTransactionId) return true;
  if (contextType.includes("purchase") && args.sageObjectId) return true;
  return false;
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

    const { data: inserted, error: insertError } = await supabaseAdmin.from("sage_oauth_tokens").insert({
      connection_id: token.connection_id,
      sage_business_row_id: token.sage_business_row_id,
      access_token_encrypted: encryptSecret(refreshed.raw.access_token),
      refresh_token_encrypted: encryptSecret(refreshed.raw.refresh_token),
      token_type: refreshed.raw.token_type || "Bearer",
      expires_at: tokenExpiresAt(refreshed.raw.expires_in),
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
  if (!business?.sage_business_id) throw new Error("No active Sage business selected for supplier credit note attachment.");

  return {
    apiBaseUrl: config.apiBaseUrl.replace(/\/$/, ""),
    accessToken,
    connectionId: text(token.connection_id),
    sageBusinessRowId: text(business.id),
    sageBusinessId: text(business.sage_business_id),
  };
}

async function transactionIdForCreditNote(row: PostedCreditNoteRow) {
  const fromRow = transactionIdFromPayload(row.response_payload_json);
  if (fromRow) return fromRow;
  if (!row.sage_object_id) return "";

  const { data, error } = await supabaseAdmin
    .from("sage_api_response_log")
    .select("response_payload_redacted, created_at")
    .eq("sage_object_type", "purchase_credit_note")
    .eq("sage_object_id", row.sage_object_id)
    .order("created_at", { ascending: false })
    .limit(10);
  if (error) return "";

  for (const logged of (data ?? []) as Row[]) {
    const found = transactionIdFromPayload(logged.response_payload_redacted);
    if (found) return found;
  }
  return "";
}

async function restoreRowsFromSnapshots(batchId: string) {
  const { data, error } = await supabaseAdmin
    .from("sage_posting_batch_rows")
    .select("id, request_payload_json, snapshot:sage_posting_snapshots(resolved_payload)")
    .eq("batch_id", batchId)
    .eq("document_lane", "supplier_credit_note")
    .eq("posting_status", "posted");
  if (error) throw new Error(error.message);

  let restored = 0;
  for (const row of (data ?? []) as Row[]) {
    const payload = asObject(row.request_payload_json);
    const snapshotPayload = asObject(asObject(row.snapshot).resolved_payload);
    if (Object.keys(snapshotPayload).length > 0 && payload.purchase_credit_note) {
      await supabaseAdmin
        .from("sage_posting_batch_rows")
        .update({ request_payload_json: snapshotPayload })
        .eq("id", row.id);
      restored += 1;
    }
  }
  return restored;
}

async function attachOne(row: PostedCreditNoteRow, ctx: Awaited<ReturnType<typeof sageContext>>, staffId: string) {
  const { data: snapshotRaw, error: snapshotError } = await supabaseAdmin
    .from("sage_posting_snapshots")
    .select("*")
    .eq("id", row.snapshot_id)
    .maybeSingle();
  if (snapshotError) throw new Error(snapshotError.message);
  const snapshot = asObject(snapshotRaw);
  if (!snapshot.id) throw new Error("Sage posting snapshot not found for supplier credit note attachment.");

  if (text(snapshot.sage_attachment_status) === "attached") return { attached: 0, skipped: 1, failed: 0, message: "already attached" };
  const url = sourceUrl(asObject(snapshot.resolved_payload)) || sourceUrl(row.request_payload_json);
  if (!url) throw new Error("No credit note source file URL found for attachment.");
  if (!row.sage_object_id) throw new Error("Posted supplier credit note is missing Sage object id.");

  const sageTransactionId = await transactionIdForCreditNote(row);
  if (!sageTransactionId) throw new Error("Could not resolve Sage transaction id for posted supplier credit note. Cannot attach evidence safely.");

  const pdf = await fetch(url, { cache: "no-store" });
  if (!pdf.ok) throw new Error(`Could not fetch credit note source file (${pdf.status}).`);
  const contentType = pdf.headers.get("content-type") || "application/pdf";
  const bytes = Buffer.from(await pdf.arrayBuffer());
  const base64 = bytes.toString("base64");
  const name = fileName(row);
  const endpoint = "/attachments";
  const redactedFile = `[encoded PDF redacted; ${bytes.byteLength} bytes]`;
  const payload = {
    attachment: {
      file: base64,
      mime_type: contentType,
      file_name: name,
      transaction_id: sageTransactionId,
    },
  };
  const auditPayload = {
    attachment: {
      file: redactedFile,
      mime_type: contentType,
      file_name: name,
      transaction_id: sageTransactionId,
      source_url: url,
    },
  };

  await supabaseAdmin.from("sage_posting_snapshots").update({
    sage_attachment_status: "pending",
    sage_attachment_attempt_count: Number(snapshot.sage_attachment_attempt_count ?? 0) + 1,
    sage_attachment_source_url: url,
    sage_attachment_file_name: name,
    sage_attachment_error_code: null,
    sage_attachment_error_message: null,
    sage_attachment_attempted_at: new Date().toISOString(),
  }).eq("id", snapshot.id);

  const { data: requestLog, error: requestLogError } = await supabaseAdmin.from("sage_api_request_log").insert({
    connection_id: ctx.connectionId,
    sage_business_row_id: ctx.sageBusinessRowId,
    posting_batch_id: row.batch_id,
    posting_batch_row_id: row.id,
    connection_event_type: "posting_batch",
    request_kind: "other",
    http_method: "POST",
    endpoint_path: endpoint,
    idempotency_key: `attachment:${row.snapshot_id}:${endpoint}:supplier_credit_note:${Date.now()}`,
    request_payload_redacted: {
      request_kind_actual: "attachment",
      attachment_attempt_label: "supplier_credit_note_transaction_id",
      ...auditPayload,
    },
    request_headers_redacted: { accept: "application/json", content_type: "application/json", x_business: ctx.sageBusinessId },
    request_payload_hash: bodyHash(auditPayload),
    created_by_staff_id: staffId,
  }).select("id").single();
  if (requestLogError) throw new Error(`Could not log Sage supplier credit note attachment request: ${requestLogError.message}`);

  let response: Response | null = null;
  let raw: unknown = {};
  const started = Date.now();
  try {
    response = await fetch(`${ctx.apiBaseUrl}${endpoint}`, {
      method: "POST",
      headers: {
        Accept: "application/json",
        Authorization: `Bearer ${ctx.accessToken}`,
        "X-Business": ctx.sageBusinessId,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(payload),
      cache: "no-store",
    });
    raw = await response.json().catch(async () => ({ non_json_body: await response!.text().catch(() => null) }));
  } catch (error) {
    raw = { error: error instanceof Error ? error.message : "Network error calling Sage attachment endpoint." };
  }

  const ok = Boolean(response?.ok);
  const objectId = ok ? attachmentId(raw) : "";
  const linked = ok && attachmentLinkedToSource({ raw, sageObjectId: row.sage_object_id, sageTransactionId });
  const finalError = errorMessage(raw);
  await supabaseAdmin.from("sage_api_response_log").insert({
    request_log_id: requestLog.id,
    connection_id: ctx.connectionId,
    sage_business_row_id: ctx.sageBusinessRowId,
    http_status: response?.status ?? null,
    success_yn: ok,
    sage_object_type: "purchase_credit_note_attachment",
    sage_object_id: objectId || null,
    sage_reference: text(row.sage_reference) || text(row.reference_text) || null,
    response_payload_redacted: raw as Row,
    error_code: ok && linked ? null : ok ? "sage_attachment_created_unlinked" : (response ? `sage_http_${response.status}` : "sage_network_error"),
    error_message: ok && linked ? null : ok ? "Sage created an attachment object but returned no transaction/context linkage." : finalError,
    duration_ms: Date.now() - started,
  });

  if (ok && linked) {
    await supabaseAdmin.from("sage_posting_snapshots").update({
      sage_attachment_status: "attached",
      sage_attachment_object_id: objectId || null,
      sage_attachment_attached_at: new Date().toISOString(),
      sage_attachment_error_code: null,
      sage_attachment_error_message: null,
    }).eq("id", snapshot.id);
    return { attached: 1, skipped: 0, failed: 0, message: "attached" };
  }

  const status = response?.status ?? 0;
  const terminal = status === 400 || status === 401 || status === 403 || status === 404 || status === 405 || status === 415 || status === 422;
  await supabaseAdmin.from("sage_posting_snapshots").update({
    sage_attachment_status: ok ? "failed_retryable" : terminal ? "failed_terminal" : "failed_retryable",
    sage_attachment_object_id: objectId || null,
    sage_attachment_error_code: ok ? "sage_attachment_created_unlinked" : status ? `sage_http_${status}` : "sage_attachment_json_attempt_failed",
    sage_attachment_error_message: ok ? "Sage created an attachment object but returned no transaction/context linkage." : finalError,
  }).eq("id", snapshot.id);

  throw new Error(ok ? "Sage created an attachment object but returned no transaction/context linkage." : finalError);
}

export async function afterSupplierCreditNotePost(params: { batchId: string; staffId: string; origin: string }) {
  const restored = await restoreRowsFromSnapshots(params.batchId);

  const { data: rowsRaw, error: rowsError } = await supabaseAdmin
    .from("sage_posting_batch_rows")
    .select("id, batch_id, snapshot_id, source_id, source_table, reference_text, order_ref, sage_object_id, sage_reference, request_payload_json, response_payload_json")
    .eq("batch_id", params.batchId)
    .eq("document_lane", "supplier_credit_note")
    .eq("posting_status", "posted");
  if (rowsError) throw new Error(rowsError.message);

  const rows = (rowsRaw ?? []) as PostedCreditNoteRow[];
  if (rows.length === 0) return { restored, attached: 0, skipped: 0, failed: 0, errors: [] as string[] };

  const ctx = await sageContext(params.origin);
  let attached = 0;
  let skipped = 0;
  let failed = 0;
  const errors: string[] = [];

  for (const row of rows) {
    try {
      const result = await attachOne(row, ctx, params.staffId);
      attached += result.attached;
      skipped += result.skipped;
    } catch (error) {
      failed += 1;
      errors.push(error instanceof Error ? error.message : "Supplier credit note attachment failed.");
    }
  }

  return { restored, attached, skipped, failed, errors };
}
