import "server-only";

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
import { postCompletionLoyaltySageBatchToSage as postAppliedCompletionLoyaltySageBatchToSage } from "./completionLoyaltyPosting";

type Row = Record<string, any>;

type SageContext = {
  config: ReturnType<typeof assertSageOAuthConfigured>;
  connectionId: string;
  sageBusinessRowId: string;
  sageBusinessId: string;
  accessToken: string;
};

function asObject(value: unknown): Row {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Row : {};
}

function text(value: unknown) {
  if (typeof value === "string") return value.trim();
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return "";
}

function num(value: unknown) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

function round2(value: number) {
  return Math.round((value + Number.EPSILON) * 100) / 100;
}

function bodyHash(value: unknown) {
  return crypto.createHash("sha256").update(JSON.stringify(value ?? {})).digest("hex");
}

function retryableStatus(status: number) {
  return status === 408 || status === 429 || status >= 500;
}

function getPath(value: unknown, path: Array<string | number>) {
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

function errorMessage(raw: unknown) {
  if (Array.isArray(raw)) {
    const messages = raw.map((item) => {
      const row = asObject(item);
      return text(row.$message) || text(row.message) || text(row.error_description) || text(row.error) || text(row.detail);
    }).filter(Boolean);
    if (messages.length > 0) return messages.join(" | ");
  }
  const root = asObject(raw);
  return text(root.message) || text(root.error_description) || text(root.error) || text(root.detail) || text(root.errors) || "Sage API request failed.";
}

function journalId(raw: unknown) {
  return firstText(raw, [["journal", "id"], ["id"], ["data", "id"], ["$items", 0, "id"]]);
}

function journalReference(raw: unknown, fallback: string) {
  return firstText(raw, [["journal", "reference"], ["journal", "displayed_as"], ["reference"], ["displayed_as"]]) || fallback;
}

function internalTransferLivePostingEnabled() {
  return process.env.SAGE_LIVE_COMPLETION_LOYALTY_INTERNAL_TRANSFER_POSTING_ENABLED === "true"
    || process.env.SAGE_LIVE_COMPLETION_LOYALTY_POSTING_ENABLED === "true"
    || process.env.SAGE_LIVE_CASH_POSTING_ENABLED === "true";
}

async function activeSageContext(origin: string): Promise<SageContext> {
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
    await supabaseAdmin.from("sage_oauth_tokens").update({ status: "superseded", superseded_at: new Date().toISOString(), updated_at: new Date().toISOString() }).eq("id", token.id);
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
    .select("id, sage_business_id, sage_business_name")
    .eq("connection_id", token.connection_id)
    .eq("status", "active")
    .order("is_primary", { ascending: false })
    .limit(1);
  if (sageBusinessRowId) businessQuery = businessQuery.eq("id", sageBusinessRowId);
  const { data: businesses, error: businessError } = await businessQuery;
  if (businessError) throw new Error(businessError.message);
  const business = (businesses?.[0] ?? null) as Row | null;
  if (!business?.sage_business_id) throw new Error("No active Sage business selected for posting.");

  return { config, connectionId: text(token.connection_id), sageBusinessRowId: text(business.id), sageBusinessId: text(business.sage_business_id), accessToken };
}

async function sageRequest(context: SageContext, endpointPath: string, body: Row) {
  let raw: unknown = {};
  let response: Response | null = null;
  const started = Date.now();
  try {
    response = await fetch(`${context.config.apiBaseUrl.replace(/\/$/, "")}${endpointPath}`, {
      method: "POST",
      headers: { Accept: "application/json", "Content-Type": "application/json", Authorization: `Bearer ${context.accessToken}`, "X-Business": context.sageBusinessId },
      body: JSON.stringify(body),
      cache: "no-store",
    });
    raw = await response.json().catch(async () => ({ non_json_body: await response!.text().catch(() => null) }));
  } catch (error) {
    raw = { error: error instanceof Error ? error.message : "Network error calling Sage." };
  }
  return { raw, response, durationMs: Date.now() - started, ok: Boolean(response?.ok) };
}

async function requestLog(context: SageContext, batchId: string, itemId: string, step: Row, body: Row, staffId: string) {
  const { data } = await supabaseAdmin.from("sage_api_request_log").insert({
    connection_id: context.connectionId,
    sage_business_row_id: context.sageBusinessRowId,
    posting_batch_id: batchId,
    posting_batch_row_id: itemId,
    connection_event_type: "posting_batch",
    request_kind: "completion_loyalty_internal_transfer_journal",
    http_method: "POST",
    endpoint_path: step.endpoint_path,
    idempotency_key: step.idempotency_key,
    request_payload_redacted: body,
    request_headers_redacted: { accept: "application/json", content_type: "application/json", x_business: context.sageBusinessId },
    request_payload_hash: bodyHash(body),
    created_by_staff_id: staffId,
  }).select("id").single();
  return text(data?.id);
}

async function responseLog(context: SageContext, requestLogId: string, result: Awaited<ReturnType<typeof sageRequest>>, objectId: string, reference: string, message: string | null) {
  if (!requestLogId) return;
  await supabaseAdmin.from("sage_api_response_log").insert({
    request_log_id: requestLogId,
    connection_id: context.connectionId,
    sage_business_row_id: context.sageBusinessRowId,
    http_status: result.response?.status ?? null,
    success_yn: result.ok && Boolean(objectId),
    sage_object_type: "journal",
    sage_object_id: objectId || null,
    sage_reference: reference || null,
    response_payload_redacted: result.raw as Row,
    error_code: result.ok && objectId ? null : (result.response ? `sage_http_${result.response.status}` : "sage_network_error"),
    error_message: result.ok && objectId ? null : message,
    duration_ms: result.durationMs,
  });
}

function journalBody(step: Row, group: Row) {
  if (text(step.step_type) !== "loyalty_internal_transfer_journal") throw new Error("Internal-transfer posting can only post loyalty_internal_transfer_journal steps.");
  if (text(step.endpoint_path) !== "/journals") throw new Error("Internal-transfer journal must post to /journals.");
  const payload = asObject(step.request_payload);
  const journal = asObject(payload.journal);
  const lines = Array.isArray(journal.journal_lines) ? journal.journal_lines.map(asObject) : [];
  if (!text(journal.date) || !text(journal.reference)) throw new Error("Internal-transfer journal payload is missing date or reference.");
  if (lines.length !== 2) throw new Error("Internal-transfer journal must contain exactly two lines.");
  for (const line of lines) {
    if (!text(line.ledger_account_id)) throw new Error("Internal-transfer journal line missing Sage long ledger account id.");
    if (line.include_on_tax_return !== false) throw new Error("Internal-transfer journal must not include tax return lines.");
    if (line.tax_rate_id !== null && text(line.tax_rate_id)) throw new Error("Internal-transfer journal must not carry a tax rate id.");
  }
  const debits = round2(lines.reduce((sum, line) => sum + num(line.debit), 0));
  const credits = round2(lines.reduce((sum, line) => sum + num(line.credit), 0));
  if (Math.abs(debits - credits) > 0.01) throw new Error("Internal-transfer journal is not balanced.");
  if (Math.abs(debits - num(group.amount_gbp)) > 0.01) throw new Error("Internal-transfer journal total does not match group amount.");
  return payload;
}

async function postJournalStep(params: { context: SageContext; batchId: string; itemId: string; staffId: string; step: Row; group: Row }) {
  const body = journalBody(params.step, params.group);
  const now = new Date().toISOString();
  await supabaseAdmin.from("completion_loyalty_sage_posting_steps").update({
    status: "posting_to_sage",
    retry_count: num(params.step.retry_count) + 1,
    last_error: null,
    request_payload: body,
    request_payload_hash: bodyHash(body),
    updated_at: now,
  }).eq("id", params.step.id);

  const logId = await requestLog(params.context, params.batchId, params.itemId, params.step, body, params.staffId);
  const result = await sageRequest(params.context, text(params.step.endpoint_path), body);
  const objectId = result.ok ? journalId(result.raw) : "";
  const reference = result.ok ? journalReference(result.raw, text(body.journal?.reference) || text(params.group.posting_group_ref)) : "";
  const message = result.ok && !objectId ? "Sage returned success but no journal id could be extracted." : errorMessage(result.raw);
  await responseLog(params.context, logId, result, objectId, reference, objectId ? null : message);

  if (result.ok && objectId) {
    await supabaseAdmin.from("completion_loyalty_sage_posting_steps").update({
      status: "posted_to_sage",
      sage_object_type: "journal",
      sage_object_id: objectId,
      sage_reference: reference || text(body.journal?.reference) || text(params.group.posting_group_ref),
      response_payload: result.raw as Row,
      last_error: null,
      posted_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    }).eq("id", params.step.id);
    return { ok: true, objectId };
  }

  const status = retryableStatus(result.response?.status ?? 0) ? "failed_retryable" : "failed_terminal";
  await supabaseAdmin.from("completion_loyalty_sage_posting_steps").update({ status, last_error: message, response_payload: result.raw as Row, updated_at: new Date().toISOString() }).eq("id", params.step.id);
  return { ok: false, error: message, status };
}

async function updateBatchStatus(batchId: string) {
  const { data: rows, error } = await supabaseAdmin.from("completion_loyalty_sage_posting_batch_items").select("posting_status, amount_gbp").eq("batch_id", batchId).eq("active", true);
  if (error) throw new Error(error.message);
  const allRows = (rows ?? []) as Row[];
  const posted = allRows.filter((row) => text(row.posting_status) === "posted_to_sage").length;
  const failed = allRows.filter((row) => ["failed_retryable", "failed_terminal"].includes(text(row.posting_status))).length;
  const terminal = allRows.some((row) => text(row.posting_status) === "failed_terminal");
  const status = posted === allRows.length && allRows.length > 0 ? "posted_to_sage" : posted > 0 ? "partially_posted_needs_review" : failed > 0 ? (terminal ? "failed_terminal" : "failed_retryable") : "approved";
  await supabaseAdmin.from("completion_loyalty_sage_posting_batches").update({
    status,
    row_count: allRows.length,
    total_amount_gbp: allRows.reduce((sum, row) => sum + num(row.amount_gbp), 0),
    last_posting_error: failed > 0 ? "One or more completion-loyalty internal-transfer journal items failed." : null,
    updated_at: new Date().toISOString(),
  }).eq("id", batchId);
}

async function postInternalTransferBatchToSage(params: { batchId: string; staffId: string; origin: string }) {
  if (!internalTransferLivePostingEnabled()) {
    throw new Error("Live completion-loyalty internal-transfer posting is disabled. Set SAGE_LIVE_COMPLETION_LOYALTY_INTERNAL_TRANSFER_POSTING_ENABLED=true after approving the controlled journal test.");
  }

  const { data: batchRaw, error: batchError } = await supabaseAdmin.from("completion_loyalty_sage_posting_batches").select("*").eq("id", params.batchId).eq("active", true).maybeSingle();
  if (batchError) throw new Error(batchError.message);
  const batch = batchRaw as Row | null;
  if (!batch) throw new Error("Completion-loyalty Sage batch not found.");
  if (text(batch.batch_type) !== "completion_loyalty_internal_transfer_journal") throw new Error("Only completion-loyalty internal-transfer journal batches are supported by this poster.");
  if (text(batch.approval_status) !== "approved") throw new Error("Completion-loyalty internal-transfer batch must be approved before posting.");
  if (!["approved", "failed_retryable", "partially_posted_needs_review"].includes(text(batch.status))) throw new Error(`Completion-loyalty internal-transfer batch status ${batch.status} is not postable.`);

  const { data: itemsRaw, error: itemsError } = await supabaseAdmin.from("completion_loyalty_sage_posting_batch_items").select("*").eq("batch_id", params.batchId).eq("active", true).in("posting_status", ["not_posted", "failed_retryable", "partially_posted_needs_review"]);
  if (itemsError) throw new Error(itemsError.message);
  const items = (itemsRaw ?? []) as Row[];
  if (items.length === 0) throw new Error("No postable completion-loyalty internal-transfer batch items found.");

  const context = await activeSageContext(params.origin);
  await supabaseAdmin.from("completion_loyalty_sage_posting_batches").update({ status: "posting_to_sage", posting_attempt_count: num(batch.posting_attempt_count) + 1, last_posting_error: null, updated_at: new Date().toISOString() }).eq("id", params.batchId);

  let posted = 0;
  let failed = 0;
  const needsReview = 0;

  for (const item of items) {
    const { data: groupRaw, error: groupError } = await supabaseAdmin.from("completion_loyalty_sage_posting_groups").select("*").eq("id", item.posting_group_id).eq("active", true).maybeSingle();
    if (groupError) throw new Error(groupError.message);
    const group = groupRaw as Row | null;
    if (!group) {
      failed += 1;
      await supabaseAdmin.from("completion_loyalty_sage_posting_batch_items").update({ item_status: "failed_terminal", posting_status: "failed_terminal", updated_at: new Date().toISOString() }).eq("id", item.id);
      continue;
    }

    try {
      if (text(group.posting_group_type) !== "completion_loyalty_internal_transfer_journal") throw new Error(`Group ${group.posting_group_ref} is not an internal-transfer journal group.`);
      if (!["admin_approved", "partially_posted_needs_review", "failed_retryable"].includes(text(group.status))) throw new Error(`Group ${group.posting_group_ref} status ${group.status} is not postable.`);
      if (!["ok_to_post", "warning_only"].includes(text(group.validation_status))) throw new Error(`Group ${group.posting_group_ref} validation status ${group.validation_status} is not postable.`);
      if (text(group.blocker)) throw new Error(`Group ${group.posting_group_ref} has blocker ${group.blocker}.`);

      const { data: stepsRaw, error: stepsError } = await supabaseAdmin.from("completion_loyalty_sage_posting_steps").select("*").eq("posting_group_id", group.id).eq("active", true).eq("step_type", "loyalty_internal_transfer_journal");
      if (stepsError) throw new Error(stepsError.message);
      const step = ((stepsRaw ?? []) as Row[])[0];
      if (!step) throw new Error(`Group ${group.posting_group_ref} is missing its internal-transfer journal step.`);
      if (!text(step.sage_object_id)) {
        await supabaseAdmin.from("completion_loyalty_sage_posting_groups").update({ status: "posting_to_sage", updated_at: new Date().toISOString() }).eq("id", group.id);
        await supabaseAdmin.from("completion_loyalty_sage_posting_batch_items").update({ item_status: "posting_to_sage", posting_status: "posting_to_sage", updated_at: new Date().toISOString() }).eq("id", item.id);
        const result = await postJournalStep({ context, batchId: params.batchId, itemId: item.id, staffId: params.staffId, step, group });
        if (!result.ok) throw new Error(result.error || "Internal-transfer journal failed.");
      }

      const now = new Date().toISOString();
      await supabaseAdmin.from("completion_loyalty_sage_posting_groups").update({ status: "posted_to_sage", posted_at: now, last_posting_error: null, updated_at: now }).eq("id", group.id);
      await supabaseAdmin.from("completion_loyalty_sage_posting_batch_items").update({ item_status: "posted_to_sage", posting_status: "posted_to_sage", updated_at: now }).eq("id", item.id);
      posted += 1;
    } catch (error) {
      failed += 1;
      const message = error instanceof Error ? error.message : "Completion-loyalty internal-transfer item failed.";
      const status = "failed_retryable";
      await supabaseAdmin.from("completion_loyalty_sage_posting_groups").update({ status, last_posting_error: message, updated_at: new Date().toISOString() }).eq("id", group.id);
      await supabaseAdmin.from("completion_loyalty_sage_posting_batch_items").update({ item_status: status, posting_status: status, updated_at: new Date().toISOString() }).eq("id", item.id);
      await supabaseAdmin.from("completion_loyalty_sage_posting_step_logs").insert({ posting_group_id: group.id, log_type: "posting_error", message, payload: { batch_id: params.batchId, batch_item_id: item.id }, created_by_staff_id: params.staffId });
    }
  }

  await updateBatchStatus(params.batchId);
  return { posted, failed, needsReview, total: items.length, endpoint: "/journals" };
}

export async function postCompletionLoyaltySageBatchToSage(params: { batchId: string; staffId: string; origin: string }) {
  const { data: batch, error } = await supabaseAdmin
    .from("completion_loyalty_sage_posting_batches")
    .select("id, batch_type")
    .eq("id", params.batchId)
    .eq("active", true)
    .maybeSingle();
  if (error) throw new Error(error.message);
  if (!batch) throw new Error("Completion-loyalty Sage batch not found.");

  if (text(batch.batch_type) === "completion_loyalty_internal_transfer_journal") {
    return postInternalTransferBatchToSage(params);
  }

  return postAppliedCompletionLoyaltySageBatchToSage(params);
}
