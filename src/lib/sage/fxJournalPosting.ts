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

type CashRow = {
  id: string;
  batch_id: string;
  snapshot_id: string;
  source_id: string;
  posting_category: string;
  idempotency_key: string | null;
  amount_gbp: string | number | null;
  validation_status: string;
  posting_status: string;
  request_payload: Row | null;
  response_payload: Row | null;
  sage_object_id: string | null;
  attempt_count: number | null;
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

function bodyHash(value: unknown) {
  return crypto.createHash("sha256").update(JSON.stringify(value ?? {})).digest("hex");
}

function retryableStatus(status: number) {
  return status === 408 || status === 429 || status >= 500;
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

function postedJournalId(raw: unknown) {
  return firstText(raw, [["journal", "id"], ["id"], ["data", "id"], ["$items", 0, "id"]]);
}

function postedJournalReference(raw: unknown, fallback: string) {
  return firstText(raw, [["journal", "reference"], ["journal", "displayed_as"], ["reference"], ["displayed_as"]]) || fallback;
}

async function activeSageContext(origin: string) {
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

  return {
    config,
    connectionId: text(token.connection_id),
    sageBusinessRowId: text(business.id),
    sageBusinessId: text(business.sage_business_id),
    accessToken,
  };
}

async function sageRequest(context: Awaited<ReturnType<typeof activeSageContext>>, method: "GET" | "POST", endpointPath: string, body?: Row) {
  let raw: unknown = {};
  let response: Response | null = null;
  const fetchStarted = Date.now();
  try {
    response = await fetch(`${context.config.apiBaseUrl.replace(/\/$/, "")}${endpointPath}`, {
      method,
      headers: {
        Accept: "application/json",
        "Content-Type": "application/json",
        Authorization: `Bearer ${context.accessToken}`,
        "X-Business": context.sageBusinessId,
      },
      body: method === "POST" ? JSON.stringify(body ?? {}) : undefined,
      cache: "no-store",
    });
    raw = await response.json().catch(async () => ({ non_json_body: await response!.text().catch(() => null) }));
  } catch (error) {
    raw = { error: error instanceof Error ? error.message : "Network error calling Sage." };
  }
  return { raw, response, durationMs: Date.now() - fetchStarted, ok: Boolean(response?.ok) };
}

async function updateCashBatchCounts(batchId: string) {
  const { data: rows, error } = await supabaseAdmin
    .from("cash_posting_batch_rows")
    .select("posting_status, amount_gbp")
    .eq("batch_id", batchId)
    .eq("active", true);
  if (error) throw new Error(error.message);
  const allRows = (rows ?? []) as Row[];
  const posted = allRows.filter((row) => ["posted", "posted_needs_review"].includes(text(row.posting_status))).length;
  const failed = allRows.filter((row) => text(row.posting_status).startsWith("failed")).length;
  const status = failed > 0 && posted > 0
    ? "partially_posted"
    : failed > 0
      ? "failed"
      : posted === allRows.length && allRows.length > 0
        ? "posted"
        : "validated";
  await supabaseAdmin.from("cash_posting_batches").update({
    batch_status: status,
    row_count: allRows.length,
    total_amount_gbp: allRows.reduce((sum, row) => sum + num(row.amount_gbp), 0),
    success_count: posted,
    failed_count: failed,
    posting_completed_at: ["posted", "failed", "partially_posted"].includes(status) ? new Date().toISOString() : null,
    updated_at: new Date().toISOString(),
  }).eq("id", batchId);
}

async function snapshotReferenceMap(rows: CashRow[]) {
  const snapshotIds = Array.from(new Set(rows.map((row) => row.snapshot_id).filter(Boolean)));
  if (snapshotIds.length === 0) return new Map<string, Row>();
  const { data, error } = await supabaseAdmin
    .from("cash_posting_snapshots")
    .select("id, internal_reference_json, request_payload")
    .in("id", snapshotIds);
  if (error) throw new Error(error.message);
  return new Map((data ?? []).map((row: Row) => [text(row.id), { ...asObject(row.internal_reference_json), snapshot_request_payload: asObject(row.request_payload) }]));
}

async function allocationContextMap(rows: CashRow[]) {
  const sourceIds = Array.from(new Set(rows.map((row) => row.source_id).filter(Boolean)));
  if (sourceIds.length === 0) return new Map<string, Row>();
  const { data, error } = await supabaseAdmin
    .from("dva_statement_line_allocation_detail_vw")
    .select("allocation_id, allocation_type, statement_direction, statement_date, transaction_date, statement_reference, order_ref")
    .in("allocation_id", sourceIds);
  if (error) throw new Error(error.message);
  return new Map((data ?? []).map((row: Row) => [text(row.allocation_id), row]));
}

async function mappedBankLedgerAccountId() {
  const { data, error } = await supabaseAdmin
    .from("sage_mapping_settings")
    .select("mapping_code, sage_external_id")
    .in("mapping_code", ["DVA_CASH_BANK_LEDGER", "DVA_CASH_BANK_LEDGER_ACCOUNT", "DVA_CASH_CLEARING_LEDGER", "BANK_CLEARING_LEDGER"])
    .eq("is_active", true);
  if (error) return "";
  return text(((data ?? []) as Row[]).find((row) => text(row.sage_external_id))?.sage_external_id);
}

async function resolveBankLedgerAccountId(context: Awaited<ReturnType<typeof activeSageContext>>, bankAccountId: string, refs: Row) {
  const existing = text(refs.target_sage_bank_ledger_account_id)
    || text(refs.target_sage_bank_ledger_id)
    || text(getPath(refs, ["workbench_detail", "target_sage_bank_ledger_account_id"]))
    || text(getPath(refs, ["workbench_detail", "target_sage_bank_ledger_id"]))
    || text(process.env.SAGE_DVA_CASH_BANK_LEDGER_ACCOUNT_ID)
    || await mappedBankLedgerAccountId();
  if (existing) return existing;

  const detail = bankAccountId ? await sageRequest(context, "GET", `/bank_accounts/${encodeURIComponent(bankAccountId)}`) : null;
  if (!detail?.ok) return "";
  return firstText(detail.raw, [
    ["bank_account", "ledger_account", "id"],
    ["bank_account", "ledger_account_id"],
    ["ledger_account", "id"],
    ["ledger_account_id"],
  ]);
}

function inferDirection(row: CashRow, refs: Row, allocationContext: Row): "in" | "out" {
  const payload = asObject(row.request_payload);
  const direction = text(payload.direction)
    || text(getPath(payload, ["journal", "direction"]))
    || text(refs.direction)
    || text(getPath(refs, ["workbench_detail", "direction"]))
    || text(allocationContext.statement_direction);
  if (direction === "in" || direction === "out") return direction;
  throw new Error(`Cannot determine IN/OUT direction for FX row ${row.id}. Re-freeze the row or confirm allocation detail is available.`);
}

function journalLine(args: { ledgerAccountId: string; details: string; debit: number; credit: number }) {
  return {
    ledger_account_id: args.ledgerAccountId,
    details: args.details,
    debit: round2(args.debit),
    credit: round2(args.credit),
    tax_rate_id: null,
  };
}

async function buildFxJournal(row: CashRow, refs: Row, allocationContext: Row, context: Awaited<ReturnType<typeof activeSageContext>>) {
  const direction = inferDirection(row, refs, allocationContext);
  const amount = round2(num(row.amount_gbp));
  const bankAccountId = text(refs.target_sage_bank_account_id) || text(getPath(refs, ["workbench_detail", "target_sage_bank_account_id"]));
  const fxLedgerAccountId = text(refs.target_sage_ledger_account_id) || text(getPath(refs, ["workbench_detail", "target_sage_ledger_account_id"]));
  const bankLedgerAccountId = await resolveBankLedgerAccountId(context, bankAccountId, refs);
  const date = text(allocationContext.statement_date) || text(allocationContext.transaction_date) || new Date().toISOString().slice(0, 10);
  const reference = text(refs.short_reference) || text(getPath(refs, ["workbench_detail", "short_reference"])) || `GCB-FX-${row.source_id.slice(0, 12)}`;
  if (!(amount > 0)) throw new Error("FX journal amount must be positive.");
  if (!fxLedgerAccountId) throw new Error("FX journal missing mapped Sage FX ledger account id.");
  if (!bankLedgerAccountId) throw new Error("FX journal missing Sage ledger account id for the DVA bank/clearing account. Add/provide the bank ledger account id before posting.");
  const details = `${direction === "in" ? "FX gain" : "FX/card loss"}${allocationContext.order_ref ? ` · ${allocationContext.order_ref}` : ""}`;
  const bankDetails = `DVA bank settlement offset${allocationContext.order_ref ? ` · ${allocationContext.order_ref}` : ""}`;
  return {
    endpointPath: "/journals",
    requestBody: {
      journal: {
        date,
        reference,
        description: details,
        show_payments_allocations: false,
        journal_lines: direction === "in"
          ? [
              journalLine({ ledgerAccountId: fxLedgerAccountId, details, debit: 0, credit: amount }),
              journalLine({ ledgerAccountId: bankLedgerAccountId, details: bankDetails, debit: amount, credit: 0 }),
            ]
          : [
              journalLine({ ledgerAccountId: fxLedgerAccountId, details, debit: amount, credit: 0 }),
              journalLine({ ledgerAccountId: bankLedgerAccountId, details: bankDetails, debit: 0, credit: amount }),
            ],
      },
    },
    reference,
  };
}

export async function postFxJournalCashBatchToSage(params: { batchId: string; staffId: string; origin: string }) {
  if (process.env.SAGE_LIVE_BANK_GL_POSTING_ENABLED !== "true" && process.env.SAGE_LIVE_CASH_POSTING_ENABLED !== "true") {
    throw new Error("Live Sage FX journal posting is disabled. Set SAGE_LIVE_BANK_GL_POSTING_ENABLED=true after approving the controlled FX journal test.");
  }
  const { data: batch, error: batchError } = await supabaseAdmin
    .from("cash_posting_batches")
    .select("id, batch_ref, posting_category, batch_status")
    .eq("id", params.batchId)
    .eq("active", true)
    .maybeSingle();
  if (batchError) throw new Error(batchError.message);
  if (!batch) throw new Error("Cash posting batch not found.");
  if (!["validated", "failed", "partially_posted"].includes(text(batch.batch_status))) throw new Error(`Cash batch status ${batch.batch_status} is not postable.`);

  const { data: rowsRaw, error: rowsError } = await supabaseAdmin
    .from("cash_posting_batch_rows")
    .select("*")
    .eq("batch_id", params.batchId)
    .eq("active", true)
    .eq("posting_category", "fx_card_difference")
    .in("posting_status", ["not_posted", "blocked_endpoint_prove_required", "failed_retryable"]);
  if (rowsError) throw new Error(rowsError.message);
  const rows = (rowsRaw ?? []) as CashRow[];
  if (rows.length === 0) throw new Error("No postable FX journal cash rows found in this batch.");
  if (rows.some((row) => row.validation_status !== "validated")) throw new Error("Every FX journal row must be validated before posting.");
  if (rows.some((row) => text(row.sage_object_id))) throw new Error("One or more FX journal rows already have a Sage object id.");

  const context = await activeSageContext(params.origin);
  await supabaseAdmin.from("cash_posting_batches").update({ batch_status: "posting", posting_started_at: new Date().toISOString(), updated_at: new Date().toISOString() }).eq("id", params.batchId);

  let posted = 0;
  let failed = 0;
  const needsReview = 0;
  const refsBySnapshotId = await snapshotReferenceMap(rows);
  const allocationBySourceId = await allocationContextMap(rows);

  for (const row of rows) {
    const startedAt = new Date().toISOString();
    await supabaseAdmin.from("cash_posting_batch_rows").update({ posting_status: "posting", attempt_count: (row.attempt_count ?? 0) + 1, last_attempt_at: startedAt, error_code: null, error_message: null, updated_at: startedAt }).eq("id", row.id);
    await supabaseAdmin.from("cash_posting_snapshots").update({ sage_posting_status: "posting_in_progress", updated_at: startedAt }).eq("id", row.snapshot_id);

    let built: Awaited<ReturnType<typeof buildFxJournal>>;
    try {
      built = await buildFxJournal(row, refsBySnapshotId.get(row.snapshot_id) ?? {}, allocationBySourceId.get(row.source_id) ?? {}, context);
    } catch (error) {
      failed += 1;
      const message = error instanceof Error ? error.message : "Could not build FX journal payload.";
      await supabaseAdmin.from("cash_posting_batch_rows").update({ posting_status: "failed_terminal", error_code: "payload_builder_failed", error_message: message, updated_at: new Date().toISOString() }).eq("id", row.id);
      await supabaseAdmin.from("cash_posting_snapshots").update({ sage_posting_status: "posting_failed", sage_response_payload: { error: message }, updated_at: new Date().toISOString() }).eq("id", row.snapshot_id);
      continue;
    }

    const { data: requestLog } = await supabaseAdmin.from("sage_api_request_log").insert({
      connection_id: context.connectionId,
      sage_business_row_id: context.sageBusinessRowId,
      posting_batch_id: params.batchId,
      posting_batch_row_id: row.id,
      connection_event_type: "posting_batch",
      request_kind: "bank_gl_fx_journal",
      http_method: "POST",
      endpoint_path: built.endpointPath,
      idempotency_key: row.idempotency_key,
      request_payload_redacted: built.requestBody,
      request_headers_redacted: { accept: "application/json", content_type: "application/json", x_business: context.sageBusinessId },
      request_payload_hash: bodyHash(built.requestBody),
      created_by_staff_id: params.staffId,
    }).select("id").single();

    const result = await sageRequest(context, "POST", built.endpointPath, built.requestBody);
    const objectId = result.ok ? postedJournalId(result.raw) : "";
    const reference = result.ok ? postedJournalReference(result.raw, built.reference) : "";
    const resultErr = result.ok && !objectId ? "Sage returned success but no journal id could be extracted." : errorMessage(result.raw);

    if (requestLog?.id) {
      await supabaseAdmin.from("sage_api_response_log").insert({
        request_log_id: requestLog.id,
        connection_id: context.connectionId,
        sage_business_row_id: context.sageBusinessRowId,
        http_status: result.response?.status ?? null,
        success_yn: result.ok && Boolean(objectId),
        sage_object_type: "journal",
        sage_object_id: objectId || null,
        sage_reference: reference || null,
        response_payload_redacted: result.raw as Row,
        error_code: result.ok && objectId ? null : (result.response ? `sage_http_${result.response.status}` : "sage_network_error"),
        error_message: result.ok && objectId ? null : resultErr,
        duration_ms: result.durationMs,
      });
    }

    const now = new Date().toISOString();
    if (result.ok && objectId) {
      posted += 1;
      await supabaseAdmin.from("cash_posting_batch_rows").update({ posting_status: "posted", sage_object_type: "journal", sage_object_id: objectId, sage_reference: reference || built.reference, response_payload: result.raw as Row, posted_at: now, error_code: null, error_message: null, updated_at: now }).eq("id", row.id);
      await supabaseAdmin.from("cash_posting_snapshots").update({ sage_posting_status: "posted", sage_object_id: objectId, sage_response_payload: result.raw as Row, updated_at: now }).eq("id", row.snapshot_id);
    } else {
      failed += 1;
      const statusCode = result.response?.status ?? 0;
      await supabaseAdmin.from("cash_posting_batch_rows").update({ posting_status: retryableStatus(statusCode) ? "failed_retryable" : "failed_terminal", response_payload: result.raw as Row, error_code: result.response ? `sage_http_${result.response.status}` : "sage_network_error", error_message: resultErr, updated_at: now }).eq("id", row.id);
      await supabaseAdmin.from("cash_posting_snapshots").update({ sage_posting_status: "posting_failed", sage_response_payload: result.raw as Row, updated_at: now }).eq("id", row.snapshot_id);
    }
  }

  await updateCashBatchCounts(params.batchId);
  return { posted, failed, needsReview, total: rows.length, endpoint: "/journals" };
}
