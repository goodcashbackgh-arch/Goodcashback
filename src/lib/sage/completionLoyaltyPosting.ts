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

function contactPaymentId(raw: unknown) {
  return firstText(raw, [["contact_payment", "id"], ["id"], ["$items", 0, "id"], ["data", "id"]]);
}

function paymentOnAccountId(raw: unknown) {
  return firstText(raw, [
    ["payment_on_account", "id"],
    ["contact_payment", "payment_on_account", "id"],
    ["contact_payment", "allocated_artefacts", 0, "artefact_id"],
    ["allocated_artefacts", 0, "artefact_id"],
  ]);
}

function contactPaymentReference(raw: unknown, fallback: string) {
  return firstText(raw, [["contact_payment", "reference"], ["contact_payment", "displayed_as"], ["reference"], ["displayed_as"]]) || fallback;
}

function allocationId(raw: unknown) {
  return firstText(raw, [["contact_allocation", "id"], ["id"], ["$items", 0, "id"], ["data", "id"]]);
}

function journalId(raw: unknown) {
  return firstText(raw, [["journal", "id"], ["id"], ["data", "id"], ["$items", 0, "id"]]);
}

function journalReference(raw: unknown, fallback: string) {
  return firstText(raw, [["journal", "reference"], ["journal", "displayed_as"], ["reference"], ["displayed_as"]]) || fallback;
}

function livePostingEnabled() {
  return process.env.SAGE_LIVE_COMPLETION_LOYALTY_POSTING_ENABLED === "true" || process.env.SAGE_LIVE_CASH_POSTING_ENABLED === "true";
}

function cloneJson(value: unknown): Row {
  return JSON.parse(JSON.stringify(value ?? {}));
}

function replacePlaceholder(value: unknown, replacement: string): unknown {
  if (typeof value === "string") return value === "__PAYMENT_ON_ACCOUNT_ID__" ? replacement : value;
  if (Array.isArray(value)) return value.map((item) => replacePlaceholder(item, replacement));
  if (value && typeof value === "object") return Object.fromEntries(Object.entries(value as Row).map(([key, item]) => [key, replacePlaceholder(item, replacement)]));
  return value;
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

  const { data: connection, error: connectionError } = await supabaseAdmin.from("sage_connections").select("id, status").eq("id", token.connection_id).maybeSingle();
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

  let businessQuery = supabaseAdmin.from("sage_businesses").select("id, sage_business_id, sage_business_name").eq("connection_id", token.connection_id).eq("status", "active").order("is_primary", { ascending: false }).limit(1);
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
    request_kind: "posting",
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

async function responseLog(context: SageContext, requestLogId: string, result: Awaited<ReturnType<typeof sageRequest>>, objectType: string, objectId: string, reference: string, message: string | null) {
  if (!requestLogId) return;
  await supabaseAdmin.from("sage_api_response_log").insert({
    request_log_id: requestLogId,
    connection_id: context.connectionId,
    sage_business_row_id: context.sageBusinessRowId,
    http_status: result.response?.status ?? null,
    success_yn: result.ok && Boolean(objectId),
    sage_object_type: objectType,
    sage_object_id: objectId || null,
    sage_reference: reference || null,
    response_payload_redacted: result.raw as Row,
    error_code: result.ok && objectId ? null : (result.response ? `sage_http_${result.response.status}` : "sage_network_error"),
    error_message: result.ok && objectId ? null : message,
    duration_ms: result.durationMs,
  });
}

async function postStep(params: { context: SageContext; batchId: string; itemId: string; staffId: string; step: Row; body: Row; objectType: string; extractId: (raw: unknown) => string; extractRef: (raw: unknown, fallback: string) => string; fallbackRef: string }) {
  const now = new Date().toISOString();
  await supabaseAdmin.from("completion_loyalty_sage_posting_steps").update({
    status: "posting_to_sage",
    retry_count: num(params.step.retry_count) + 1,
    last_error: null,
    request_payload: params.body,
    request_payload_hash: bodyHash(params.body),
    updated_at: now,
  }).eq("id", params.step.id);

  const logId = await requestLog(params.context, params.batchId, params.itemId, params.step, params.body, params.staffId);
  const result = await sageRequest(params.context, text(params.step.endpoint_path), params.body);
  const objectId = result.ok ? params.extractId(result.raw) : "";
  const reference = result.ok ? params.extractRef(result.raw, params.fallbackRef) : "";
  const message = result.ok && !objectId ? `Sage returned success but no ${params.objectType} id could be extracted.` : errorMessage(result.raw);
  await responseLog(params.context, logId, result, params.objectType, objectId, reference, objectId ? null : message);

  if (result.ok && objectId) {
    await supabaseAdmin.from("completion_loyalty_sage_posting_steps").update({
      status: "posted_to_sage",
      sage_object_type: params.objectType,
      sage_object_id: objectId,
      sage_reference: reference || params.fallbackRef,
      response_payload: result.raw as Row,
      last_error: null,
      posted_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    }).eq("id", params.step.id);
    return { ok: true, objectId, reference, raw: result.raw };
  }

  const status = retryableStatus(result.response?.status ?? 0) ? "failed_retryable" : "failed_terminal";
  await supabaseAdmin.from("completion_loyalty_sage_posting_steps").update({ status, last_error: message, response_payload: result.raw as Row, updated_at: new Date().toISOString() }).eq("id", params.step.id);
  return { ok: false, error: message, status, raw: result.raw };
}

function receiptBody(step: Row, group: Row) {
  if (text(step.endpoint_path) !== "/contact_payments") throw new Error("Loyalty receipt must post to /contact_payments.");
  const payload = asObject(step.request_payload);
  const cp = asObject(payload.contact_payment);
  if (text(cp.transaction_type_id) !== "CUSTOMER_RECEIPT") throw new Error("Loyalty receipt must use CUSTOMER_RECEIPT.");
  if (!text(cp.contact_id) || !text(cp.bank_account_id) || !text(cp.date) || !text(cp.reference)) throw new Error("Loyalty receipt payload is missing a required Sage field.");
  if (Math.abs(num(cp.total_amount) - num(group.amount_gbp)) > 0.01) throw new Error("Loyalty receipt amount does not match group amount.");
  return { contact_payment: { transaction_type_id: text(cp.transaction_type_id), contact_id: text(cp.contact_id), bank_account_id: text(cp.bank_account_id), date: text(cp.date), total_amount: round2(num(cp.total_amount)), reference: text(cp.reference) } };
}

function allocationBody(step: Row, paymentOnAccount: string) {
  if (text(step.endpoint_path) !== "/contact_allocations") throw new Error("Loyalty allocation must post to /contact_allocations.");
  if (!paymentOnAccount) throw new Error("Cannot post loyalty allocation without Sage payment-on-account id from the receipt response.");
  const payload = replacePlaceholder(cloneJson(step.request_payload), paymentOnAccount) as Row;
  const ca = asObject(payload.contact_allocation);
  const artefacts = Array.isArray(ca.allocated_artefacts) ? ca.allocated_artefacts.map(asObject) : [];
  if (text(ca.transaction_type_id) !== "CUSTOMER_ALLOCATION" || !text(ca.contact_id)) throw new Error("Loyalty allocation payload is missing required Sage fields.");
  if (artefacts.length < 2) throw new Error("Loyalty allocation must include target invoice and payment-on-account artefacts.");
  if (artefacts.some((artefact) => text(artefact.artefact_id) === "__PAYMENT_ON_ACCOUNT_ID__")) throw new Error("Loyalty allocation placeholder was not replaced.");
  const net = round2(artefacts.reduce((sum, artefact) => sum + num(artefact.amount), 0));
  if (Math.abs(net) > 0.01) throw new Error(`Loyalty allocation artefacts must net to zero. Net was ${net}.`);
  return payload;
}

function journalBody(step: Row, group: Row) {
  if (text(step.endpoint_path) !== "/journals") throw new Error("Loyalty clearing offset must post to /journals.");
  const payload = asObject(step.request_payload);
  const journal = asObject(payload.journal);
  const lines = Array.isArray(journal.journal_lines) ? journal.journal_lines.map(asObject) : [];
  if (!text(journal.date) || !text(journal.reference)) throw new Error("Loyalty journal payload is missing date or reference.");
  if (lines.length < 2) throw new Error("Loyalty journal must contain at least two lines.");
  for (const line of lines) {
    if (!text(line.ledger_account_id)) throw new Error("Loyalty journal line missing ledger account id.");
    if (line.include_on_tax_return !== false) throw new Error("Loyalty journal must not include tax return lines.");
    if (line.tax_rate_id !== null && text(line.tax_rate_id)) throw new Error("Loyalty journal must not carry a tax rate id.");
  }
  const debits = round2(lines.reduce((sum, line) => sum + num(line.debit), 0));
  const credits = round2(lines.reduce((sum, line) => sum + num(line.credit), 0));
  if (Math.abs(debits - credits) > 0.01) throw new Error("Loyalty journal is not balanced.");
  if (Math.abs(debits - num(group.amount_gbp)) > 0.01) throw new Error("Loyalty journal total does not match group amount.");
  return payload;
}

async function updateBatchStatus(batchId: string) {
  const { data: rows, error } = await supabaseAdmin.from("completion_loyalty_sage_posting_batch_items").select("posting_status, amount_gbp").eq("batch_id", batchId).eq("active", true);
  if (error) throw new Error(error.message);
  const allRows = (rows ?? []) as Row[];
  const posted = allRows.filter((row) => text(row.posting_status) === "posted_to_sage").length;
  const failed = allRows.filter((row) => ["failed_retryable", "failed_terminal"].includes(text(row.posting_status))).length;
  const partial = allRows.filter((row) => text(row.posting_status) === "partially_posted_needs_review").length;
  const terminal = allRows.some((row) => text(row.posting_status) === "failed_terminal");
  const status = posted === allRows.length && allRows.length > 0 ? "posted_to_sage" : (posted > 0 || partial > 0) ? "partially_posted_needs_review" : failed > 0 ? (terminal ? "failed_terminal" : "failed_retryable") : "approved";
  await supabaseAdmin.from("completion_loyalty_sage_posting_batches").update({
    status,
    row_count: allRows.length,
    total_amount_gbp: allRows.reduce((sum, row) => sum + num(row.amount_gbp), 0),
    last_posting_error: failed > 0 || partial > 0 ? "One or more loyalty Sage batch items need review." : null,
    updated_at: new Date().toISOString(),
  }).eq("id", batchId);
}

async function postGroup(params: { batch: Row; item: Row; group: Row; steps: Row[]; context: SageContext; staffId: string }) {
  const receipt = params.steps.find((step) => text(step.step_type) === "loyalty_customer_receipt");
  const allocation = params.steps.find((step) => text(step.step_type) === "loyalty_customer_allocation");
  const clearing = params.steps.find((step) => text(step.step_type) === "loyalty_clearing_offset");
  if (!receipt || !allocation || !clearing) throw new Error("Loyalty group is missing receipt, allocation or clearing step.");

  await supabaseAdmin.from("completion_loyalty_sage_posting_groups").update({ status: "posting_to_sage", updated_at: new Date().toISOString() }).eq("id", params.group.id);
  await supabaseAdmin.from("completion_loyalty_sage_posting_batch_items").update({ item_status: "posting_to_sage", posting_status: "posting_to_sage", updated_at: new Date().toISOString() }).eq("id", params.item.id);

  let paymentOnAccount = paymentOnAccountId(receipt.response_payload);
  if (!text(receipt.sage_object_id)) {
    const body = receiptBody(receipt, params.group);
    const result = await postStep({ context: params.context, batchId: params.batch.id, itemId: params.item.id, staffId: params.staffId, step: receipt, body, objectType: "contact_payment", extractId: contactPaymentId, extractRef: contactPaymentReference, fallbackRef: text(body.contact_payment.reference) });
    if (!result.ok) throw new Error(result.error || "Loyalty customer receipt failed.");
    paymentOnAccount = paymentOnAccountId(result.raw);
    if (!paymentOnAccount) throw new Error("Loyalty receipt posted but no payment-on-account id was extracted. Allocation is blocked for review.");
  }

  if (!text(allocation.sage_object_id)) {
    const body = allocationBody(allocation, paymentOnAccount);
    const result = await postStep({ context: params.context, batchId: params.batch.id, itemId: params.item.id, staffId: params.staffId, step: allocation, body, objectType: "contact_allocation", extractId: allocationId, extractRef: () => text(params.group.posting_group_ref), fallbackRef: text(params.group.posting_group_ref) });
    if (!result.ok) throw new Error(result.error || "Loyalty customer allocation failed.");
  }

  if (!text(clearing.sage_object_id)) {
    const body = journalBody(clearing, params.group);
    const result = await postStep({ context: params.context, batchId: params.batch.id, itemId: params.item.id, staffId: params.staffId, step: clearing, body, objectType: "journal", extractId: journalId, extractRef: journalReference, fallbackRef: text(body.journal?.reference) || text(params.group.posting_group_ref) });
    if (!result.ok) throw new Error(result.error || "Loyalty clearing journal failed.");
  }

  const now = new Date().toISOString();
  await supabaseAdmin.from("completion_loyalty_sage_posting_groups").update({ status: "posted_to_sage", posted_at: now, last_posting_error: null, updated_at: now }).eq("id", params.group.id);
  await supabaseAdmin.from("completion_loyalty_sage_posting_batch_items").update({ item_status: "posted_to_sage", posting_status: "posted_to_sage", updated_at: now }).eq("id", params.item.id);
}

export async function postCompletionLoyaltySageBatchToSage(params: { batchId: string; staffId: string; origin: string }) {
  if (!livePostingEnabled()) {
    throw new Error("Live completion-loyalty Sage posting is disabled. Use the existing SAGE_LIVE_CASH_POSTING_ENABLED=true environment switch, or set SAGE_LIVE_COMPLETION_LOYALTY_POSTING_ENABLED=true for a dedicated loyalty switch.");
  }

  const { data: batchRaw, error: batchError } = await supabaseAdmin.from("completion_loyalty_sage_posting_batches").select("*").eq("id", params.batchId).eq("active", true).maybeSingle();
  if (batchError) throw new Error(batchError.message);
  const batch = batchRaw as Row | null;
  if (!batch) throw new Error("Completion-loyalty Sage batch not found.");
  if (text(batch.batch_type) !== "completion_loyalty_applied_settlement") throw new Error("Only completion-loyalty applied settlement batches are supported.");
  if (text(batch.approval_status) !== "approved") throw new Error("Completion-loyalty Sage batch must be approved before posting.");
  if (!["approved", "failed_retryable", "partially_posted_needs_review"].includes(text(batch.status))) throw new Error(`Completion-loyalty Sage batch status ${batch.status} is not postable.`);

  const { data: itemsRaw, error: itemsError } = await supabaseAdmin.from("completion_loyalty_sage_posting_batch_items").select("*").eq("batch_id", params.batchId).eq("active", true).in("posting_status", ["not_posted", "failed_retryable", "partially_posted_needs_review"]);
  if (itemsError) throw new Error(itemsError.message);
  const items = (itemsRaw ?? []) as Row[];
  if (items.length === 0) throw new Error("No postable completion-loyalty Sage batch items found.");

  const context = await activeSageContext(params.origin);
  await supabaseAdmin.from("completion_loyalty_sage_posting_batches").update({ status: "posting_to_sage", posting_attempt_count: num(batch.posting_attempt_count) + 1, last_posting_error: null, updated_at: new Date().toISOString() }).eq("id", params.batchId);

  let posted = 0;
  let failed = 0;
  let needsReview = 0;

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
      if (!["admin_approved", "partially_posted_needs_review", "failed_retryable"].includes(text(group.status))) throw new Error(`Loyalty group ${group.posting_group_ref} status ${group.status} is not postable.`);
      if (!["ok_to_post", "warning_only"].includes(text(group.validation_status))) throw new Error(`Loyalty group ${group.posting_group_ref} validation status ${group.validation_status} is not postable.`);
      if (text(group.blocker)) throw new Error(`Loyalty group ${group.posting_group_ref} has blocker ${group.blocker}.`);
      const { data: stepsRaw, error: stepsError } = await supabaseAdmin.from("completion_loyalty_sage_posting_steps").select("*").eq("posting_group_id", group.id).eq("active", true);
      if (stepsError) throw new Error(stepsError.message);
      await postGroup({ batch, item, group, steps: (stepsRaw ?? []) as Row[], context, staffId: params.staffId });
      posted += 1;
    } catch (error) {
      failed += 1;
      const message = error instanceof Error ? error.message : "Completion-loyalty Sage item failed.";
      const { data: currentSteps } = await supabaseAdmin.from("completion_loyalty_sage_posting_steps").select("status, sage_object_id, posted_at").eq("posting_group_id", group.id).eq("active", true);
      const hasPostedStep = ((currentSteps ?? []) as Row[]).some((step) => text(step.status) === "posted_to_sage" || text(step.sage_object_id) || text(step.posted_at));
      const status = hasPostedStep ? "partially_posted_needs_review" : "failed_retryable";
      if (hasPostedStep) needsReview += 1;
      await supabaseAdmin.from("completion_loyalty_sage_posting_groups").update({ status, last_posting_error: message, updated_at: new Date().toISOString() }).eq("id", group.id);
      await supabaseAdmin.from("completion_loyalty_sage_posting_batch_items").update({ item_status: status, posting_status: status, updated_at: new Date().toISOString() }).eq("id", item.id);
      await supabaseAdmin.from("completion_loyalty_sage_posting_step_logs").insert({ posting_group_id: group.id, log_type: "posting_error", message, payload: { batch_id: params.batchId, batch_item_id: item.id }, created_by_staff_id: params.staffId });
    }
  }

  await updateBatchStatus(params.batchId);
  return { posted, failed, needsReview, total: items.length, endpoint: "/contact_payments -> /contact_allocations -> /journals" };
}
