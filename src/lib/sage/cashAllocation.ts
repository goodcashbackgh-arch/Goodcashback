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

function money(value: number) {
  return Math.round((value + Number.EPSILON) * 100) / 100;
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

function sageAllocationId(raw: unknown) {
  return firstText(raw, [["contact_allocation", "id"], ["id"], ["$items", 0, "id"], ["data", "id"]]);
}

async function activeSageContext(origin: string) {
  const config = assertSageOAuthConfigured(origin);
  const { data: tokenRows, error: tokenError } = await supabaseAdmin
    .from("sage_oauth_tokens")
    .select("id, connection_id, access_token_encrypted, refresh_token_encrypted, expires_at, scopes, sage_business_row_id")
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
  if (!business?.sage_business_id) throw new Error("No active Sage business selected for posting.");

  return {
    config,
    connectionId: text(token.connection_id),
    sageBusinessRowId: text(business.id),
    sageBusinessId: text(business.sage_business_id),
    accessToken,
  };
}

async function buildCustomerReceiptAllocation(rowId: string) {
  const { data: rowRaw, error: rowError } = await supabaseAdmin
    .from("cash_posting_batch_rows")
    .select("*")
    .eq("id", rowId)
    .eq("active", true)
    .maybeSingle();
  if (rowError) throw new Error(rowError.message);
  const row = rowRaw as Row | null;
  if (!row) throw new Error("Cash posting row not found.");
  if (text(row.posting_category) !== "customer_receipt_on_account") throw new Error("Only customer receipt rows can be allocated in this phase.");
  if (!["posted", "posted_needs_review"].includes(text(row.posting_status))) throw new Error("Receipt must be posted to Sage before allocation.");
  if (text(row.sage_allocation_status) === "allocated") throw new Error("Receipt row is already allocated.");

  const { data: cashSnapRaw, error: cashSnapError } = await supabaseAdmin
    .from("cash_posting_snapshots")
    .select("*")
    .eq("id", row.snapshot_id)
    .eq("active", true)
    .maybeSingle();
  if (cashSnapError) throw new Error(cashSnapError.message);
  const cashSnap = cashSnapRaw as Row | null;
  if (!cashSnap) throw new Error("Cash posting snapshot not found.");

  const paymentOnAccountId = text(row.sage_payment_on_account_id) || text(cashSnap.sage_payment_on_account_id);
  const receiptObjectId = text(row.sage_object_id) || text(cashSnap.sage_object_id);
  const contactId = text(cashSnap.sage_contact_id);
  if (!receiptObjectId) throw new Error("Receipt Sage contact_payment id missing.");
  if (!paymentOnAccountId) throw new Error("Receipt payment_on_account id missing.");
  if (!contactId) throw new Error("Receipt Sage contact id missing.");

  const { data: targetsRaw, error: targetsError } = await supabaseAdmin
    .from("sage_posting_snapshots")
    .select("id, source_id, sage_invoice_id, resolved_payload, amount_gbp, reference_text, order_ref, order_id")
    .eq("active", true)
    .eq("document_lane", "customer_sales")
    .eq("sage_posting_status", "posted")
    .eq("order_id", cashSnap.order_id);
  if (targetsError) throw new Error(targetsError.message);
  const targets = (targetsRaw ?? []) as Row[];
  if (targets.length === 0) throw new Error("Matched sales invoice has not been posted to Sage.");
  if (targets.length > 1) throw new Error("Multiple posted sales invoices found for this order. Manual target selection is required before allocation.");
  const target = targets[0];

  const targetSageInvoiceId = text(target.sage_invoice_id);
  const targetContactId = firstText(target.resolved_payload, [["sage_header", "contact_id"], ["customer_target", "sage_contact_id"]]);
  if (!targetSageInvoiceId) throw new Error("Target Sage sales invoice id missing.");
  if (!targetContactId) throw new Error("Target sales invoice Sage contact id missing.");
  if (targetContactId !== contactId) throw new Error("Receipt/contact mismatch.");

  const { data: previousRows, error: previousError } = await supabaseAdmin
    .from("cash_posting_batch_rows")
    .select("sage_allocation_amount_gbp")
    .eq("active", true)
    .eq("sage_allocation_status", "allocated")
    .eq("sage_allocation_target_object_id", targetSageInvoiceId);
  if (previousError) throw new Error(previousError.message);
  const alreadyAllocatedToTarget = ((previousRows ?? []) as Row[]).reduce((sum, item) => sum + num(item.sage_allocation_amount_gbp), 0);

  const receiptOpen = Math.max(0, num(row.amount_gbp) - num(row.sage_allocation_amount_gbp));
  const targetOpen = Math.max(0, num(target.amount_gbp) - alreadyAllocatedToTarget);
  const amount = money(Math.min(receiptOpen, targetOpen));
  if (!(amount > 0)) throw new Error("No positive amount is available to allocate.");

  const requestBody = {
    contact_allocation: {
      contact_id: contactId,
      transaction_type_id: "CUSTOMER_ALLOCATION",
      allocated_artefacts: [
        { artefact_id: targetSageInvoiceId, amount },
        { artefact_id: paymentOnAccountId, amount: money(-amount) },
      ],
    },
  };

  return {
    row,
    cashSnap,
    target,
    requestBody,
    amount,
    targetSageInvoiceId,
    paymentOnAccountId,
    receiptObjectId,
    reference: text(row.sage_reference) || text(cashSnap.short_reference),
  };
}

export async function postCustomerReceiptAllocationsToSage(params: { cashBatchRowIds: string[]; staffId: string; origin: string }) {
  if (process.env.SAGE_LIVE_CASH_ALLOCATION_ENABLED !== "true") {
    throw new Error("Live Sage cash allocation is disabled. Set SAGE_LIVE_CASH_ALLOCATION_ENABLED=true only after approving the allocation test.");
  }

  const ids = Array.from(new Set(params.cashBatchRowIds.map((id) => id.trim()).filter(Boolean)));
  if (ids.length === 0) throw new Error("Select at least one ready cash receipt allocation row.");

  const context = await activeSageContext(params.origin);
  let posted = 0;
  let failed = 0;

  for (const rowId of ids) {
    const attemptStartedAt = new Date().toISOString();
    let built: Awaited<ReturnType<typeof buildCustomerReceiptAllocation>> | null = null;

    try {
      built = await buildCustomerReceiptAllocation(rowId);
      await supabaseAdmin.from("cash_posting_batch_rows").update({
        sage_allocation_status: "posting",
        sage_allocation_attempt_count: num(built.row.sage_allocation_attempt_count) + 1,
        sage_allocation_last_attempt_at: attemptStartedAt,
        sage_allocation_request_payload: built.requestBody,
        sage_allocation_error_code: null,
        sage_allocation_error_message: null,
        updated_at: attemptStartedAt,
      }).eq("id", rowId);
      await supabaseAdmin.from("cash_posting_snapshots").update({
        sage_allocation_status: "posting",
        sage_allocation_attempt_count: num(built.cashSnap.sage_allocation_attempt_count) + 1,
        sage_allocation_last_attempt_at: attemptStartedAt,
        sage_allocation_request_payload: built.requestBody,
        sage_allocation_error_code: null,
        sage_allocation_error_message: null,
        updated_at: attemptStartedAt,
      }).eq("id", built.cashSnap.id);
    } catch (error) {
      failed += 1;
      const message = error instanceof Error ? error.message : "Could not build cash allocation payload.";
      await supabaseAdmin.from("cash_posting_batch_rows").update({
        sage_allocation_status: "failed_terminal",
        sage_allocation_error_code: "allocation_payload_failed",
        sage_allocation_error_message: message,
        sage_allocation_last_attempt_at: attemptStartedAt,
        updated_at: attemptStartedAt,
      }).eq("id", rowId);
      continue;
    }

    const endpointPath = "/contact_allocations";
    const { data: requestLog } = await supabaseAdmin.from("sage_api_request_log").insert({
      connection_id: context.connectionId,
      sage_business_row_id: context.sageBusinessRowId,
      posting_batch_id: built.row.batch_id,
      posting_batch_row_id: built.row.id,
      connection_event_type: "posting_batch",
      request_kind: "cash_allocation",
      http_method: "POST",
      endpoint_path: endpointPath,
      idempotency_key: `cash-allocation:${built.row.id}:${built.targetSageInvoiceId}`,
      request_payload_redacted: built.requestBody,
      request_headers_redacted: { accept: "application/json", content_type: "application/json", x_business: context.sageBusinessId },
      request_payload_hash: bodyHash(built.requestBody),
      created_by_staff_id: params.staffId,
    }).select("id").single();

    let raw: unknown = {};
    let response: Response | null = null;
    const started = Date.now();
    try {
      response = await fetch(`${context.config.apiBaseUrl.replace(/\/$/, "")}${endpointPath}`, {
        method: "POST",
        headers: {
          Accept: "application/json",
          "Content-Type": "application/json",
          Authorization: `Bearer ${context.accessToken}`,
          "X-Business": context.sageBusinessId,
        },
        body: JSON.stringify(built.requestBody),
        cache: "no-store",
      });
      raw = await response.json().catch(async () => ({ non_json_body: await response!.text().catch(() => null) }));
    } catch (error) {
      raw = { error: error instanceof Error ? error.message : "Network error calling Sage." };
    }

    const durationMs = Date.now() - started;
    const ok = Boolean(response?.ok);
    const allocationId = ok ? sageAllocationId(raw) : "";
    const err = ok && !allocationId ? "Sage returned success but no contact_allocation id could be extracted." : errorMessage(raw);

    if (requestLog?.id) {
      await supabaseAdmin.from("sage_api_response_log").insert({
        request_log_id: requestLog.id,
        connection_id: context.connectionId,
        sage_business_row_id: context.sageBusinessRowId,
        http_status: response?.status ?? null,
        success_yn: ok && Boolean(allocationId),
        sage_object_type: "contact_allocation",
        sage_object_id: allocationId || null,
        sage_reference: built.reference || null,
        response_payload_redacted: raw as Row,
        error_code: ok && allocationId ? null : (response ? `sage_http_${response.status}` : "sage_network_error"),
        error_message: ok && allocationId ? null : err,
        duration_ms: durationMs,
      });
    }

    const now = new Date().toISOString();
    if (ok && allocationId) {
      posted += 1;
      const patch = {
        sage_allocation_status: "allocated",
        sage_allocation_id: allocationId,
        sage_allocation_amount_gbp: built.amount,
        sage_allocation_target_object_id: built.targetSageInvoiceId,
        sage_allocation_target_snapshot_id: built.target.id,
        sage_allocation_response_payload: raw as Row,
        sage_allocation_error_code: null,
        sage_allocation_error_message: null,
        sage_allocation_posted_at: now,
        updated_at: now,
      };
      await supabaseAdmin.from("cash_posting_batch_rows").update(patch).eq("id", built.row.id);
      await supabaseAdmin.from("cash_posting_snapshots").update(patch).eq("id", built.cashSnap.id);
    } else {
      failed += 1;
      const status = retryableStatus(response?.status ?? 0) ? "failed_retryable" : "failed_terminal";
      const patch = {
        sage_allocation_status: status,
        sage_allocation_response_payload: raw as Row,
        sage_allocation_error_code: response ? `sage_http_${response.status}` : "sage_network_error",
        sage_allocation_error_message: err,
        updated_at: now,
      };
      await supabaseAdmin.from("cash_posting_batch_rows").update(patch).eq("id", built.row.id);
      await supabaseAdmin.from("cash_posting_snapshots").update(patch).eq("id", built.cashSnap.id);
    }
  }

  return { posted, failed, total: ids.length, endpoint: "/contact_allocations" };
}
