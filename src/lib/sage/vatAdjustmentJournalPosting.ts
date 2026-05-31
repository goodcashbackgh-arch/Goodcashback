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

type VatJournalRow = {
  id: string;
  vat_return_run_id: string;
  vat_return_run_line_id: string | null;
  adjustment_type: string;
  target_box: number;
  direction: "increase" | "decrease";
  amount_gbp: string | number | null;
  status: string;
  idempotency_key: string | null;
  endpoint_path: string;
  method: string;
  sage_business_id: string | null;
  payload_hash: string | null;
  request_payload: Row | null;
  response_payload: Row | null;
  last_error: string | null;
  retry_count: number | null;
  sage_journal_id: string | null;
  sage_journal_ref: string | null;
  posted_at: string | null;
  approved_at: string | null;
};

type VatRunRow = {
  id: string;
  run_ref: string | null;
  status: string;
  locked_at: string | null;
  period_start_date: string | null;
  period_end_date: string | null;
  return_period_label: string | null;
};

type VatJournalLineRow = {
  id: string;
  line_no: number;
  line_role: "vat_box_line" | "balancing_line";
  account_role: string;
  sage_ledger_account_id: string | null;
  sage_ledger_account_display: string | null;
  debit_amount_gbp: string | number | null;
  credit_amount_gbp: string | number | null;
  include_on_tax_return: boolean | null;
  target_box: number | null;
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

async function sageRequest(context: Awaited<ReturnType<typeof activeSageContext>>, method: "POST", endpointPath: string, body: Row) {
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
      body: JSON.stringify(body),
      cache: "no-store",
    });
    raw = await response.json().catch(async () => ({ non_json_body: await response!.text().catch(() => null) }));
  } catch (error) {
    raw = { error: error instanceof Error ? error.message : "Network error calling Sage." };
  }
  return { raw, response, durationMs: Date.now() - fetchStarted, ok: Boolean(response?.ok) };
}

function journalReference(run: VatRunRow, journal: VatJournalRow) {
  const runPart = text(run.run_ref) || journal.vat_return_run_id.slice(0, 8).toUpperCase();
  return `GCB-VAT-${runPart}-B${journal.target_box}-${journal.direction.toUpperCase()}-${journal.id.slice(0, 8)}`.slice(0, 60);
}

function buildVatJournalPayload(run: VatRunRow, journal: VatJournalRow, lines: VatJournalLineRow[]) {
  const reference = journalReference(run, journal);
  const date = text(run.period_end_date) || new Date().toISOString().slice(0, 10);
  const description = `Goodcashback VAT Box ${journal.target_box} ${journal.direction} adjustment - ${journal.adjustment_type}`;

  return {
    endpointPath: "/journals",
    reference,
    requestBody: {
      journal: {
        date,
        reference,
        description,
        show_payments_allocations: false,
        journal_lines: lines
          .slice()
          .sort((a, b) => Number(a.line_no) - Number(b.line_no))
          .map((line) => ({
            ledger_account_id: text(line.sage_ledger_account_id),
            details: `${line.line_role === "vat_box_line" ? `Box ${journal.target_box}` : "VAT adjustment balance"} · ${line.account_role}`,
            debit: round2(num(line.debit_amount_gbp)),
            credit: round2(num(line.credit_amount_gbp)),
            tax_rate_id: null,
            include_on_tax_return: line.include_on_tax_return === true,
          })),
      },
    },
  };
}

async function assertNoOpenBlockers(runId: string) {
  const { count, error } = await supabaseAdmin
    .from("vat_return_blockers")
    .select("id", { count: "exact", head: true })
    .eq("vat_return_run_id", runId)
    .eq("status", "open")
    .eq("severity", "blocker");
  if (error) throw new Error(error.message);
  if ((count ?? 0) > 0) throw new Error(`Open VAT blocker(s) exist for this return: ${count}.`);
}

async function maybeMarkRunPosted(runId: string) {
  const { count, error } = await supabaseAdmin
    .from("vat_return_adjustment_journals")
    .select("id", { count: "exact", head: true })
    .eq("vat_return_run_id", runId)
    .in("status", ["admin_approved", "posting_to_sage", "failed_retryable", "failed_terminal"]);
  if (error) throw new Error(error.message);
  if ((count ?? 0) === 0) {
    await supabaseAdmin.from("vat_return_runs").update({
      status: "sage_adjustment_journals_posted",
      updated_at: new Date().toISOString(),
    }).eq("id", runId).eq("status", "admin_approved");
  }
}

function validateJournalBeforePost(run: VatRunRow, journal: VatJournalRow, lines: VatJournalLineRow[]) {
  if (run.locked_at || run.status === "matched_to_sage_locked") throw new Error("Locked VAT returns cannot be posted to Sage.");
  if (run.status !== "admin_approved") throw new Error(`VAT return status ${run.status} is not postable.`);
  if (journal.status !== "admin_approved") throw new Error(`VAT journal status ${journal.status} is not postable. Expected admin_approved.`);
  if (journal.endpoint_path !== "/journals" || journal.method !== "POST") throw new Error("VAT journal must post with POST /journals.");
  if (text(journal.sage_journal_id)) throw new Error("VAT journal already has a Sage journal id.");
  if (!text(journal.payload_hash)) throw new Error("VAT journal payload_hash missing; dry-run validation must run before posting.");
  if (!text(journal.idempotency_key)) throw new Error("VAT journal idempotency_key missing.");
  if (lines.length !== 2) throw new Error("VAT journal must have exactly two lines.");
  const vatLine = lines.find((line) => line.line_role === "vat_box_line");
  const balanceLine = lines.find((line) => line.line_role === "balancing_line");
  if (!vatLine || vatLine.include_on_tax_return !== true || vatLine.target_box !== journal.target_box) throw new Error("VAT-box line is invalid for posting.");
  if (!balanceLine || balanceLine.include_on_tax_return !== false || balanceLine.target_box !== null) throw new Error("Balancing line is invalid for posting.");
  for (const line of lines) {
    if (!text(line.sage_ledger_account_id)) throw new Error(`VAT journal line ${line.line_no} is missing Sage ledger account id.`);
  }
  const debits = round2(lines.reduce((sum, line) => sum + num(line.debit_amount_gbp), 0));
  const credits = round2(lines.reduce((sum, line) => sum + num(line.credit_amount_gbp), 0));
  if (debits !== credits) throw new Error(`VAT journal is unbalanced: debits ${debits}, credits ${credits}.`);
  if (debits !== round2(num(journal.amount_gbp))) throw new Error("VAT journal total does not match approved amount.");
}

export async function postVatAdjustmentJournalToSage(params: { journalId: string; staffId: string; origin: string }) {
  if (process.env.SAGE_LIVE_VAT_JOURNAL_POSTING_ENABLED !== "true") {
    throw new Error("Live Sage VAT journal posting is disabled. Set SAGE_LIVE_VAT_JOURNAL_POSTING_ENABLED=true only after approving the controlled VAT journal test.");
  }

  const { data: journalRaw, error: journalError } = await supabaseAdmin
    .from("vat_return_adjustment_journals")
    .select("*")
    .eq("id", params.journalId)
    .maybeSingle();
  if (journalError) throw new Error(journalError.message);
  const journal = (journalRaw ?? null) as VatJournalRow | null;
  if (!journal) throw new Error("VAT adjustment journal not found.");

  const { data: runRaw, error: runError } = await supabaseAdmin
    .from("vat_return_runs")
    .select("id, run_ref, status, locked_at, period_start_date, period_end_date, return_period_label")
    .eq("id", journal.vat_return_run_id)
    .maybeSingle();
  if (runError) throw new Error(runError.message);
  const run = (runRaw ?? null) as VatRunRow | null;
  if (!run) throw new Error("VAT return run not found for journal.");

  const { data: linesRaw, error: linesError } = await supabaseAdmin
    .from("vat_return_adjustment_journal_lines")
    .select("*")
    .eq("vat_return_adjustment_journal_id", journal.id)
    .order("line_no", { ascending: true });
  if (linesError) throw new Error(linesError.message);
  const lines = (linesRaw ?? []) as VatJournalLineRow[];

  validateJournalBeforePost(run, journal, lines);
  await assertNoOpenBlockers(run.id);

  const context = await activeSageContext(params.origin);
  const built = buildVatJournalPayload(run, journal, lines);
  const requestPayloadHash = bodyHash(built.requestBody);
  const startedAt = new Date().toISOString();

  await supabaseAdmin.from("vat_return_adjustment_journals").update({
    status: "posting_to_sage",
    retry_count: (journal.retry_count ?? 0) + 1,
    last_error: null,
    request_payload: asObject(journal.request_payload) || {},
    updated_at: startedAt,
  }).eq("id", journal.id).eq("status", "admin_approved");

  const { data: requestLog } = await supabaseAdmin.from("sage_api_request_log").insert({
    connection_id: context.connectionId,
    sage_business_row_id: context.sageBusinessRowId,
    connection_event_type: "other",
    request_kind: "posting",
    http_method: "POST",
    endpoint_path: built.endpointPath,
    idempotency_key: journal.idempotency_key,
    request_payload_redacted: built.requestBody,
    request_headers_redacted: { accept: "application/json", content_type: "application/json", x_business: context.sageBusinessId },
    request_payload_hash: requestPayloadHash,
    created_by_staff_id: params.staffId,
  }).select("id").single();

  const result = await sageRequest(context, "POST", built.endpointPath, built.requestBody);
  const objectId = result.ok ? postedJournalId(result.raw) : "";
  const reference = result.ok ? postedJournalReference(result.raw, built.reference) : "";
  const resultError = result.ok && !objectId ? "Sage returned success but no journal id could be extracted." : errorMessage(result.raw);

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
      error_message: result.ok && objectId ? null : resultError,
      duration_ms: result.durationMs,
    });
  }

  const now = new Date().toISOString();
  if (result.ok && objectId) {
    await supabaseAdmin.from("vat_return_adjustment_journals").update({
      status: "posted_to_sage",
      sage_business_id: context.sageBusinessId,
      sage_journal_id: objectId,
      sage_journal_ref: reference || built.reference,
      posted_at: now,
      response_payload: result.raw as Row,
      last_error: null,
      updated_at: now,
    }).eq("id", journal.id);

    await maybeMarkRunPosted(run.id);
    return { posted: 1, failed: 0, journalId: journal.id, sageJournalId: objectId, sageReference: reference || built.reference, endpoint: built.endpointPath };
  }

  const statusCode = result.response?.status ?? 0;
  const postingStatus = retryableStatus(statusCode) ? "failed_retryable" : "failed_terminal";
  await supabaseAdmin.from("vat_return_adjustment_journals").update({
    status: postingStatus,
    response_payload: result.raw as Row,
    last_error: resultError,
    updated_at: now,
  }).eq("id", journal.id);

  return { posted: 0, failed: 1, journalId: journal.id, error: resultError, endpoint: built.endpointPath };
}
