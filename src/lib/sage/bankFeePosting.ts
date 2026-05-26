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

function postedObjectId(raw: unknown) {
  return firstText(raw, [
    ["other_payment", "id"],
    ["bank_transaction", "id"],
    ["transaction", "id"],
    ["id"],
    ["$items", 0, "id"],
    ["data", "id"],
  ]);
}

function postedReference(raw: unknown, fallback: string) {
  return firstText(raw, [
    ["other_payment", "reference"],
    ["other_payment", "displayed_as"],
    ["bank_transaction", "reference"],
    ["bank_transaction", "displayed_as"],
    ["reference"],
    ["displayed_as"],
  ]) || fallback;
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

async function sagePost(context: Awaited<ReturnType<typeof activeSageContext>>, endpointPath: string, body: Row) {
  let raw: unknown = {};
  let response: Response | null = null;
  const fetchStarted = Date.now();
  try {
    response = await fetch(`${context.config.apiBaseUrl.replace(/\/$/, "")}${endpointPath}`, {
      method: "POST",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/json",
        Authorization: `Bearer ${context.accessToken}`,
        "X-Business": context.sageBusinessId,
      },
      body: JSON.stringify(body),
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

  return new Map((data ?? []).map((row: Row) => [text(row.id), {
    ...asObject(row.internal_reference_json),
    snapshot_request_payload: asObject(row.request_payload),
  }]));
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

function inferDirection(row: CashRow, refs: Row, allocationContext: Row) {
  const payload = asObject(row.request_payload);
  const direction = text(payload.direction)
    || text(getPath(payload, ["other_payment", "direction"]))
    || text(refs.direction)
    || text(getPath(refs, ["workbench_detail", "direction"]))
    || text(allocationContext.statement_direction);

  if (direction === "out") return "out";
  throw new Error(`Bank fee row ${row.id} must be an OUT transaction before posting to Sage.`);
}

function buildPaymentLine(args: { ledgerAccountId: string; amount: number; reference: string }) {
  const line: Row = {
    ledger_account_id: args.ledgerAccountId,
    details: args.reference,
    total_amount: args.amount,
    net_amount: args.amount,
    tax_amount: 0,
  };

  const taxRateId = process.env.SAGE_BANK_FEE_TAX_RATE_ID || process.env.SAGE_BANK_GL_TAX_RATE_ID || process.env.SAGE_NO_TAX_RATE_ID || "";
  if (taxRateId) line.tax_rate_id = taxRateId;

  return line;
}

function buildBankFeePayload(row: CashRow, refs: Row, allocationContext: Row) {
  if (row.posting_category !== "bank_fee") {
    throw new Error(`Bank fee poster only supports bank_fee rows. Found ${row.posting_category}.`);
  }

  inferDirection(row, refs, allocationContext);

  const payload = asObject(row.request_payload);
  const snapshotPayload = asObject(refs.snapshot_request_payload);
  const root = asObject(payload.other_payment);
  const snapshotRoot = asObject(snapshotPayload.other_payment);
  const legacyRoot = asObject(payload.bank_transaction);
  const legacySnapshotRoot = asObject(snapshotPayload.bank_transaction);
  const rootFinal = Object.keys(root).length > 0 ? root : legacyRoot;
  const snapshotRootFinal = Object.keys(snapshotRoot).length > 0 ? snapshotRoot : legacySnapshotRoot;

  const amount = round2(num(rootFinal.total_amount) || num(snapshotRootFinal.total_amount) || num(row.amount_gbp));
  const bankAccountId = text(rootFinal.bank_account_id)
    || text(snapshotRootFinal.bank_account_id)
    || text(refs.target_sage_bank_account_id)
    || text(getPath(refs, ["workbench_detail", "target_sage_bank_account_id"]));
  const ledgerAccountId = text(getPath(rootFinal, ["payment_lines", 0, "ledger_account_id"]))
    || text(getPath(snapshotRootFinal, ["payment_lines", 0, "ledger_account_id"]))
    || text(getPath(rootFinal, ["details", 0, "ledger_account_id"]))
    || text(getPath(snapshotRootFinal, ["details", 0, "ledger_account_id"]))
    || text(refs.target_sage_ledger_account_id)
    || text(getPath(refs, ["workbench_detail", "target_sage_ledger_account_id"]));
  const date = text(rootFinal.date)
    || text(rootFinal.transaction_date)
    || text(snapshotRootFinal.date)
    || text(snapshotRootFinal.transaction_date)
    || text(allocationContext.statement_date)
    || text(allocationContext.transaction_date)
    || new Date().toISOString().slice(0, 10);
  const reference = text(rootFinal.reference)
    || text(snapshotRootFinal.reference)
    || text(refs.short_reference)
    || text(getPath(refs, ["workbench_detail", "short_reference"]))
    || `GCB-FEE-${row.source_id.slice(0, 12)}`;
  const description = `Bank/card fee${allocationContext.order_ref ? ` · ${allocationContext.order_ref}` : ""}`;

  if (!bankAccountId) throw new Error("Bank fee payload missing Sage bank_account_id. Check DVA_CASH_BANK_ACCOUNT mapping.");
  if (!ledgerAccountId) throw new Error("Bank fee payload missing Sage bank fee ledger_account_id. Check BANK_FEE_LEDGER mapping.");
  if (!(amount > 0)) throw new Error("Bank fee amount must be positive.");
  if (!date) throw new Error("Bank fee date is required.");

  const otherPayment: Row = {
    transaction_type_id: "OTHER_PAYMENT",
    bank_account_id: bankAccountId,
    date,
    reference,
    total_amount: amount,
    description,
    payment_lines: [buildPaymentLine({ ledgerAccountId, amount, reference: description })],
  };

  const paymentMethodId = process.env.SAGE_BANK_FEE_PAYMENT_METHOD_ID || process.env.SAGE_BANK_GL_PAYMENT_METHOD_ID || "";
  if (paymentMethodId) otherPayment.payment_method_id = paymentMethodId;

  return {
    endpointPath: "/other_payments",
    requestKind: "bank_fee_other_payment",
    requestBody: { other_payment: otherPayment },
    amount,
    reference,
    sageObjectType: "other_payment" as const,
  };
}

export async function postBankFeeCashBatchToSage(params: { batchId: string; staffId: string; origin: string }) {
  if (process.env.SAGE_LIVE_BANK_GL_POSTING_ENABLED !== "true" && process.env.SAGE_LIVE_CASH_POSTING_ENABLED !== "true") {
    throw new Error("Live Sage bank fee posting is disabled. Set SAGE_LIVE_BANK_GL_POSTING_ENABLED=true after approving the controlled bank fee test.");
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
    .eq("posting_category", "bank_fee")
    .in("posting_status", ["not_posted", "blocked_endpoint_prove_required", "failed_retryable"]);
  if (rowsError) throw new Error(rowsError.message);
  const rows = (rowsRaw ?? []) as CashRow[];
  if (rows.length === 0) throw new Error("No postable bank fee rows found in this batch.");
  if (rows.some((row) => row.validation_status !== "validated")) throw new Error("Every bank fee row must be validated before posting.");
  if (rows.some((row) => text(row.sage_object_id))) throw new Error("One or more bank fee rows already have a Sage object id.");

  const context = await activeSageContext(params.origin);
  await supabaseAdmin.from("cash_posting_batches").update({
    batch_status: "posting",
    posting_started_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
  }).eq("id", params.batchId);

  let posted = 0;
  let failed = 0;
  const needsReview = 0;
  const refsBySnapshotId = await snapshotReferenceMap(rows);
  const allocationBySourceId = await allocationContextMap(rows);

  for (const row of rows) {
    const startedAt = new Date().toISOString();
    await supabaseAdmin.from("cash_posting_batch_rows").update({
      posting_status: "posting",
      attempt_count: (row.attempt_count ?? 0) + 1,
      last_attempt_at: startedAt,
      error_code: null,
      error_message: null,
      updated_at: startedAt,
    }).eq("id", row.id);
    await supabaseAdmin.from("cash_posting_snapshots").update({
      sage_posting_status: "posting_in_progress",
      updated_at: startedAt,
    }).eq("id", row.snapshot_id);

    let built: ReturnType<typeof buildBankFeePayload>;
    try {
      built = buildBankFeePayload(row, refsBySnapshotId.get(row.snapshot_id) ?? {}, allocationBySourceId.get(row.source_id) ?? {});
    } catch (error) {
      failed += 1;
      const message = error instanceof Error ? error.message : "Could not build bank fee Sage payload.";
      await supabaseAdmin.from("cash_posting_batch_rows").update({
        posting_status: "failed_terminal",
        error_code: "payload_builder_failed",
        error_message: message,
        updated_at: new Date().toISOString(),
      }).eq("id", row.id);
      await supabaseAdmin.from("cash_posting_snapshots").update({
        sage_posting_status: "posting_failed",
        sage_response_payload: { error: message },
        updated_at: new Date().toISOString(),
      }).eq("id", row.snapshot_id);
      continue;
    }

    const { data: requestLog } = await supabaseAdmin.from("sage_api_request_log").insert({
      connection_id: context.connectionId,
      sage_business_row_id: context.sageBusinessRowId,
      posting_batch_id: params.batchId,
      posting_batch_row_id: row.id,
      connection_event_type: "posting_batch",
      request_kind: built.requestKind,
      http_method: "POST",
      endpoint_path: built.endpointPath,
      idempotency_key: row.idempotency_key,
      request_payload_redacted: built.requestBody,
      request_headers_redacted: { accept: "application/json", content_type: "application/json", x_business: context.sageBusinessId },
      request_payload_hash: bodyHash(built.requestBody),
      created_by_staff_id: params.staffId,
    }).select("id").single();

    const result = await sagePost(context, built.endpointPath, built.requestBody);
    const objectId = result.ok ? postedObjectId(result.raw) : "";
    const reference = result.ok ? postedReference(result.raw, built.reference) : "";
    const resultErr = result.ok && !objectId ? "Sage returned success but no other_payment id could be extracted." : errorMessage(result.raw);

    if (requestLog?.id) {
      await supabaseAdmin.from("sage_api_response_log").insert({
        request_log_id: requestLog.id,
        connection_id: context.connectionId,
        sage_business_row_id: context.sageBusinessRowId,
        http_status: result.response?.status ?? null,
        success_yn: result.ok && Boolean(objectId),
        sage_object_type: built.sageObjectType,
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
      await supabaseAdmin.from("cash_posting_batch_rows").update({
        posting_status: "posted",
        sage_object_type: built.sageObjectType,
        sage_object_id: objectId,
        sage_reference: reference || built.reference,
        response_payload: result.raw as Row,
        posted_at: now,
        error_code: null,
        error_message: null,
        updated_at: now,
      }).eq("id", row.id);
      await supabaseAdmin.from("cash_posting_snapshots").update({
        sage_posting_status: "posted",
        sage_object_id: objectId,
        sage_response_payload: result.raw as Row,
        updated_at: now,
      }).eq("id", row.snapshot_id);
    } else {
      failed += 1;
      const statusCode = result.response?.status ?? 0;
      await supabaseAdmin.from("cash_posting_batch_rows").update({
        posting_status: retryableStatus(statusCode) ? "failed_retryable" : "failed_terminal",
        response_payload: result.raw as Row,
        error_code: result.response ? `sage_http_${result.response.status}` : "sage_network_error",
        error_message: resultErr,
        updated_at: now,
      }).eq("id", row.id);
      await supabaseAdmin.from("cash_posting_snapshots").update({
        sage_posting_status: "posting_failed",
        sage_response_payload: result.raw as Row,
        updated_at: now,
      }).eq("id", row.snapshot_id);
    }
  }

  await updateCashBatchCounts(params.batchId);
  return { posted, failed, needsReview, total: rows.length, endpoint: "/other_payments" };
}
