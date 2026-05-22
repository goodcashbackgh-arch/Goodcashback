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
import { buildSageAttachmentJsonAttempts } from "@/lib/sage/apAttachmentAttempts";

type Row = Record<string, any>;

function obj(v: unknown): Row { return v && typeof v === "object" && !Array.isArray(v) ? v as Row : {}; }
function txt(v: unknown) { return typeof v === "string" ? v.trim() : typeof v === "number" && Number.isFinite(v) ? String(v) : ""; }
function get(v: unknown, path: Array<string | number>): unknown {
  let cur = v;
  for (const p of path) {
    if (typeof p === "number") { if (!Array.isArray(cur)) return undefined; cur = cur[p]; }
    else { if (!cur || typeof cur !== "object" || Array.isArray(cur)) return undefined; cur = (cur as Row)[p]; }
  }
  return cur;
}
function first(v: unknown, paths: Array<Array<string | number>>) { for (const p of paths) { const x = txt(get(v, p)); if (x) return x; } return ""; }
function hash(v: unknown) { return crypto.createHash("sha256").update(JSON.stringify(v ?? {})).digest("hex"); }
function err(raw: unknown) {
  if (Array.isArray(raw)) {
    const m = raw.map((x) => txt(obj(x).$message) || txt(obj(x).message) || txt(obj(x).error_description) || txt(obj(x).error) || txt(obj(x).detail)).filter(Boolean);
    if (m.length) return m.join(" | ");
  }
  const r = obj(raw);
  return txt(r.message) || txt(r.error_description) || txt(r.error) || txt(r.detail) || "Sage attachment request failed.";
}
function attachmentId(raw: unknown) { return first(raw, [["id"], ["attachment", "id"], ["data", "id"], ["$items", 0, "id"]]); }
function sourceUrl(snapshot: Row) {
  return txt(snapshot.sage_attachment_source_url) || first(snapshot, [
    ["resolved_payload", "source_evidence", "file_url"],
    ["resolved_payload", "evidence", "credit_note_file_url"],
    ["resolved_payload", "credit_note_file_url"],
    ["resolved_payload", "source_payload", "evidence", "credit_note_file_url"],
    ["resolved_payload", "source_payload", "credit_note_file_url"],
    ["commercial_payload", "source_evidence", "file_url"],
    ["commercial_payload", "evidence", "credit_note_file_url"],
    ["commercial_payload", "credit_note_file_url"],
  ]);
}
function fileName(snapshot: Row) {
  const base = txt(snapshot.reference_text) || txt(snapshot.order_ref) || txt(snapshot.source_id) || "supplier_credit_note";
  return `${base.replace(/[^a-zA-Z0-9._-]+/g, "_")}.pdf`;
}
async function hydrateSourceUrl(snapshot: Row) {
  const existing = sourceUrl(snapshot);
  if (existing) return existing;
  if (txt(snapshot.source_table) !== "dispute_refund_evidence_submissions" || !txt(snapshot.source_id)) return "";
  const { data, error } = await supabaseAdmin.from("dispute_refund_evidence_submissions").select("credit_note_file_url, refund_proof_file_url").eq("id", txt(snapshot.source_id)).maybeSingle();
  if (error) throw new Error(error.message);
  return txt((data as Row | null)?.credit_note_file_url) || txt((data as Row | null)?.refund_proof_file_url);
}
async function sageContext(origin: string) {
  const config = assertSageOAuthConfigured(origin);
  const { data: tokenRows, error: tokenError } = await supabaseAdmin.from("sage_oauth_tokens").select("id, connection_id, access_token_encrypted, refresh_token_encrypted, expires_at, scopes, sage_business_row_id").eq("status", "active").order("expires_at", { ascending: false }).limit(1);
  if (tokenError) throw new Error(tokenError.message);
  const token = (tokenRows?.[0] ?? null) as Row | null;
  if (!token) throw new Error("No active Sage OAuth token found.");
  const { data: connection, error: connectionError } = await supabaseAdmin.from("sage_connections").select("id, status").eq("id", token.connection_id).maybeSingle();
  if (connectionError) throw new Error(connectionError.message);
  if (!connection || connection.status !== "connected") throw new Error("Sage connection is not connected.");

  let accessToken = decryptSecret(txt(token.access_token_encrypted));
  let businessRowId = txt(token.sage_business_row_id);
  if (tokenRefreshRequired(token.expires_at)) {
    const refreshed = await exchangeSageToken({ tokenUrl: config.tokenUrl, clientId: config.clientId, clientSecret: config.clientSecret, grantType: "refresh_token", refreshToken: decryptSecret(txt(token.refresh_token_encrypted)) });
    if (!refreshed.response.ok || !refreshed.raw.access_token || !refreshed.raw.refresh_token) {
      await supabaseAdmin.from("sage_connections").update({ status: "refresh_failed", last_error_code: "token_refresh_failed", last_error_message: JSON.stringify(redactedTokenPayload(refreshed.raw)), updated_at: new Date().toISOString() }).eq("id", token.connection_id);
      throw new Error(`Sage token refresh failed (${refreshed.response.status}).`);
    }
    await supabaseAdmin.from("sage_oauth_tokens").update({ status: "superseded", superseded_at: new Date().toISOString(), updated_at: new Date().toISOString() }).eq("id", token.id);
    const { data: inserted, error: insertError } = await supabaseAdmin.from("sage_oauth_tokens").insert({ connection_id: token.connection_id, sage_business_row_id: token.sage_business_row_id, access_token_encrypted: encryptSecret(refreshed.raw.access_token), refresh_token_encrypted: encryptSecret(refreshed.raw.refresh_token), token_type: refreshed.raw.token_type || "Bearer", expires_at: tokenExpiresAt(refreshed.raw.expires_in), scopes: scopesFromToken(refreshed.raw, config.scopes), status: "active", encryption_key_ref: "SAGE_TOKEN_ENCRYPTION_KEY:v1", issued_at: new Date().toISOString(), last_refresh_at: new Date().toISOString() }).select("id, sage_business_row_id").single();
    if (insertError) throw new Error(insertError.message);
    accessToken = refreshed.raw.access_token;
    businessRowId = txt(inserted?.sage_business_row_id) || businessRowId;
  }

  let q = supabaseAdmin.from("sage_businesses").select("id, sage_business_id").eq("connection_id", token.connection_id).eq("status", "active").order("is_primary", { ascending: false }).limit(1);
  if (businessRowId) q = q.eq("id", businessRowId);
  const { data: businesses, error: businessError } = await q;
  if (businessError) throw new Error(businessError.message);
  const business = (businesses?.[0] ?? null) as Row | null;
  if (!business?.sage_business_id) throw new Error("No active Sage business selected for attachment.");
  return { apiBaseUrl: config.apiBaseUrl.replace(/\/$/, ""), accessToken, connectionId: txt(token.connection_id), sageBusinessRowId: txt(business.id), sageBusinessId: txt(business.sage_business_id) };
}
async function transactionIdForCreditNote(creditNoteId: string) {
  const { data, error } = await supabaseAdmin.from("sage_api_response_log").select("response_payload_redacted, created_at").eq("sage_object_type", "purchase_credit_note").eq("sage_object_id", creditNoteId).order("created_at", { ascending: false }).limit(10);
  if (error) return "";
  for (const row of (data ?? []) as Row[]) {
    const found = first(row.response_payload_redacted, [["transaction", "id"], ["transaction_id"], ["purchase_credit_note", "transaction", "id"], ["purchase_credit_note", "transaction_id"], ["data", "transaction", "id"]]);
    if (found) return found;
  }
  return "";
}
function linked(raw: unknown, creditNoteId: string, transactionId: string) {
  const directTransaction = first(raw, [["transaction", "id"], ["transaction_id"], ["attachment_context", "id"], ["attachment_context_id"]]);
  const directOrigin = first(raw, [["transaction", "origin", "id"], ["attachment_context", "origin", "id"]]);
  const contextType = first(raw, [["attachment_context_type"], ["context_type"]]).toLowerCase();
  return Boolean((transactionId && directTransaction === transactionId) || (creditNoteId && directOrigin === creditNoteId) || (creditNoteId && directTransaction === creditNoteId) || (contextType.includes("transaction") && transactionId) || (contextType.includes("purchase") && creditNoteId));
}

export async function attachSupplierCreditNoteSourcePdfToSage(params: { snapshotId: string; staffId: string; origin: string }) {
  if (process.env.SAGE_LIVE_POSTING_ENABLED !== "true") throw new Error("Live Sage posting is disabled. Attachment calls are disabled too.");
  const { data: snapshotRaw, error: snapshotError } = await supabaseAdmin.from("sage_posting_snapshots").select("*").eq("id", params.snapshotId).maybeSingle();
  if (snapshotError) throw new Error(snapshotError.message);
  const snapshot = (snapshotRaw ?? null) as Row | null;
  if (!snapshot) throw new Error("Sage posting snapshot not found.");
  if (txt(snapshot.document_lane) !== "supplier_credit_note") throw new Error("Only supplier credit note attachments are supported here.");
  if (txt(snapshot.sage_posting_status) !== "posted" || !txt(snapshot.sage_invoice_id)) throw new Error("Supplier credit note must be posted before attaching evidence.");
  if (txt(snapshot.sage_attachment_status) === "attached") return { attached: 0, failed: 0, skipped: 1, endpoint: "", fieldName: "already_attached", objectId: txt(snapshot.sage_attachment_object_id) };

  const url = await hydrateSourceUrl(snapshot);
  if (!url) throw new Error("No credit note source PDF URL found on this posted supplier credit note snapshot.");
  const creditNoteId = txt(snapshot.sage_invoice_id);
  const transactionId = await transactionIdForCreditNote(creditNoteId);
  if (!transactionId) throw new Error("Could not resolve Sage transaction id for the posted purchase credit note. Cannot prove document-level attachment.");

  const ctx = await sageContext(params.origin);
  const pdf = await fetch(url, { cache: "no-store" });
  if (!pdf.ok) throw new Error(`Could not fetch credit note source PDF (${pdf.status}).`);
  const bytes = Buffer.from(await pdf.arrayBuffer());
  const contentType = pdf.headers.get("content-type") || "application/pdf";
  const name = fileName(snapshot);
  const attempts = buildSageAttachmentJsonAttempts({ configuredEndpointTemplate: process.env.SAGE_PURCHASE_INVOICE_ATTACHMENT_ENDPOINT_TEMPLATE, sageInvoiceId: creditNoteId, sageTransactionId: transactionId, sourceUrl: url, fileName: name, mimeType: contentType, encodedFile: bytes.toString("base64"), byteLength: bytes.byteLength });

  await supabaseAdmin.from("sage_posting_snapshots").update({ sage_attachment_status: "pending", sage_attachment_attempt_count: Number(snapshot.sage_attachment_attempt_count ?? 0) + 1, sage_attachment_source_url: url, sage_attachment_file_name: name, sage_attachment_error_code: null, sage_attachment_error_message: null, sage_attachment_attempted_at: new Date().toISOString() }).eq("id", params.snapshotId);

  let finalError = "Sage JSON attachment request failed.";
  let finalStatus = 0;
  let lastObjectId = "";
  for (const attempt of attempts) {
    const { data: requestLog, error: requestError } = await supabaseAdmin.from("sage_api_request_log").insert({ connection_id: ctx.connectionId, sage_business_row_id: ctx.sageBusinessRowId, posting_batch_id: snapshot.batch_id || null, connection_event_type: "posting_batch", request_kind: "other", http_method: "POST", endpoint_path: attempt.endpoint, idempotency_key: `attachment:${snapshot.id}:${attempt.endpoint}:${attempt.label}:${Date.now()}`, request_payload_redacted: { request_kind_actual: "attachment", attachment_attempt_label: attempt.label, ...attempt.auditPayload }, request_headers_redacted: { accept: "application/json", content_type: "application/json", x_business: ctx.sageBusinessId }, request_payload_hash: hash(attempt.auditPayload), created_by_staff_id: params.staffId }).select("id").single();
    if (requestError) throw new Error(`Could not log Sage credit note attachment request: ${requestError.message}`);

    let response: Response | null = null;
    let raw: unknown = {};
    const started = Date.now();
    try {
      response = await fetch(`${ctx.apiBaseUrl}${attempt.endpoint}`, { method: "POST", headers: { Accept: "application/json", Authorization: `Bearer ${ctx.accessToken}`, "X-Business": ctx.sageBusinessId, "Content-Type": "application/json" }, body: JSON.stringify(attempt.payload), cache: "no-store" });
      raw = await response.json().catch(async () => ({ non_json_body: await response!.text().catch(() => null) }));
    } catch (e) { raw = { error: e instanceof Error ? e.message : "Network error calling Sage attachment endpoint." }; }

    const ok = Boolean(response?.ok);
    const objectId = ok ? attachmentId(raw) : "";
    const isLinked = ok && linked(raw, creditNoteId, transactionId);
    finalStatus = response?.status ?? 0;
    finalError = err(raw);
    await supabaseAdmin.from("sage_api_response_log").insert({ request_log_id: requestLog?.id, connection_id: ctx.connectionId, sage_business_row_id: ctx.sageBusinessRowId, http_status: response?.status ?? null, success_yn: ok, sage_object_type: "purchase_credit_note_attachment", sage_object_id: objectId || null, sage_reference: txt(snapshot.reference_text) || null, response_payload_redacted: raw as Row, error_code: ok && isLinked ? null : ok ? "sage_attachment_created_unlinked" : (response ? `sage_http_${response.status}` : "sage_network_error"), error_message: ok && isLinked ? null : ok ? "Sage created an attachment object but returned no transaction/context linkage." : finalError, duration_ms: Date.now() - started });

    if (ok && isLinked) {
      await supabaseAdmin.from("sage_posting_snapshots").update({ sage_attachment_status: "attached", sage_attachment_object_id: objectId || null, sage_attachment_attached_at: new Date().toISOString(), sage_attachment_error_code: null, sage_attachment_error_message: null }).eq("id", params.snapshotId);
      return { attached: 1, failed: 0, skipped: 0, endpoint: attempt.endpoint, fieldName: attempt.label, objectId };
    }
    if (ok && !isLinked) { lastObjectId = objectId; finalError = "Sage created an attachment object but returned no transaction/context linkage."; }
  }

  const terminal = finalStatus === 400 || finalStatus === 401 || finalStatus === 403 || finalStatus === 404 || finalStatus === 405 || finalStatus === 415 || finalStatus === 422;
  await supabaseAdmin.from("sage_posting_snapshots").update({ sage_attachment_status: lastObjectId ? "failed_retryable" : terminal ? "failed_terminal" : "failed_retryable", sage_attachment_object_id: lastObjectId || null, sage_attachment_error_code: lastObjectId ? "sage_attachment_created_unlinked" : finalStatus ? `sage_http_${finalStatus}` : "sage_attachment_json_attempts_failed", sage_attachment_error_message: finalError }).eq("id", params.snapshotId);
  throw new Error(finalError);
}
