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

type BatchRow = {
  id: string;
  batch_id: string;
  snapshot_id: string | null;
  idempotency_key: string | null;
  posting_status: string;
  sage_object_type: string | null;
  request_payload_json: Row;
  payload_validation_status: string;
  source_table: string | null;
  source_id: string | null;
  document_lane: string | null;
  document_type: string | null;
  order_ref: string | null;
  reference_text: string | null;
  counterparty_name: string | null;
  amount_gbp: string | number | null;
  currency_code: string | null;
  attempt_count: number | null;
};

function asObject(value: unknown): Row {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Row : {};
}

function asArray(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
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

function sageObjectId(raw: unknown) {
  return firstText(raw, [["id"], ["purchase_invoice", "id"], ["$items", 0, "id"], ["data", "id"]]);
}

function sageReference(raw: unknown) {
  return firstText(raw, [["reference"], ["displayed_as"], ["purchase_invoice", "reference"], ["purchase_invoice", "displayed_as"]]);
}

function errorMessage(raw: unknown) {
  if (Array.isArray(raw)) {
    const messages = raw
      .map((item) => {
        const row = asObject(item);
        return text(row.$message)
          || text(row.message)
          || text(row.error_description)
          || text(row.error)
          || text(row.detail)
          || "";
      })
      .filter(Boolean);
    if (messages.length > 0) return messages.join(" | ");
  }

  const root = asObject(raw);
  return text(root.message)
    || text(root.error_description)
    || text(root.error)
    || text(root.detail)
    || text(root.errors)
    || "Sage API request failed.";
}

function extractSupplierGoodsApPurchaseInvoicePayload(row: BatchRow) {
  const payload = asObject(row.request_payload_json);
  const header = asObject(payload.sage_header);
  const sourcePayload = asObject(payload.source_payload);
  const sourceHeader = asObject(sourcePayload.sage_header);
  const contactId = firstText(payload, [
    ["supplier_target", "sage_contact_id"],
    ["sage_header", "contact_id"],
    ["sage_header", "sage_contact_id"],
  ]);
  const date = firstText(payload, [
    ["sage_header", "date"],
    ["sage_header", "invoice_date"],
    ["source_payload", "supplier_invoice_date"],
    ["source_payload", "invoice_date"],
    ["source_payload", "document_date"],
    ["commercial_payload", "supplier_invoice_date"],
  ]);
  const reference = text(header.reference)
    || text(sourceHeader.reference)
    || firstText(sourcePayload, [["supplier_invoice_ref"], ["document_ref"]])
    || text(row.reference_text)
    || text(row.order_ref)
    || row.id;
  const notes = text(header.notes) || `Order ${text(row.order_ref)} · Supplier goods AP`;
  const currencyCode = text(header.currency_code) || text(row.currency_code) || "GBP";
  const resolvedLines = asArray(payload.resolved_lines).map(asObject);

  const frozenLedgerAccountId = firstText(payload, [
    ["mapping_snapshot", "SUPPLIER_GOODS_AP_LEDGER", "sage_external_id"],
    ["source_payload", "mapping_snapshot", "SUPPLIER_GOODS_AP_LEDGER", "sage_external_id"],
  ]);
  const frozenTaxRateId = firstText(payload, [
    ["mapping_snapshot", "SUPPLIER_GOODS_AP_TAX_RATE", "sage_external_id"],
    ["source_payload", "mapping_snapshot", "SUPPLIER_GOODS_AP_TAX_RATE", "sage_external_id"],
  ]);

  if (!contactId) throw new Error("Supplier goods AP Sage supplier contact id missing from frozen payload.");
  if (!date) throw new Error("Supplier goods AP invoice date missing from frozen payload.");
  if (resolvedLines.length === 0) throw new Error("Supplier goods AP invoice has no resolved lines.");
  if (!frozenLedgerAccountId) throw new Error("Supplier goods AP frozen ledger mapping is missing.");
  if (!frozenTaxRateId) throw new Error("Supplier goods AP frozen tax-rate mapping is missing.");

  let grossTotal = 0;
  let sageNetTotal = 0;

  const invoiceLines = resolvedLines.map((line, index) => {
    const description = firstText(line, [["description"], ["posting_description"], ["source_description"]]);
    const ledgerAccountId = frozenLedgerAccountId || firstText(line, [["sage_ledger_account_id"], ["resolved_ledger_account_id"]]);
    const taxRateId = frozenTaxRateId || firstText(line, [["sage_tax_rate_id"], ["resolved_tax_rate_id"]]);
    const quantity = num(line.quantity || line.qty || 1) || 1;
    const netAmount = num(line.net_amount_gbp);
    const vatAmount = num(line.vat_amount_gbp);
    const grossAmount = num(line.gross_amount_gbp || line.total_line_amount_gbp || line.amount_gbp || line.unit_price_gbp);

    if (!description) throw new Error(`Supplier goods AP line ${index + 1} missing description.`);
    if (!ledgerAccountId) throw new Error(`Supplier goods AP line ${index + 1} missing ledger account id.`);
    if (!taxRateId) throw new Error(`Supplier goods AP line ${index + 1} missing tax rate id.`);
    if (!grossAmount) throw new Error(`Supplier goods AP line ${index + 1} missing gross amount.`);
    if (!netAmount && vatAmount !== 0) throw new Error(`Supplier goods AP line ${index + 1} missing net amount.`);
    if (Math.abs(round2(netAmount + vatAmount) - round2(grossAmount)) > 0.01) {
      throw new Error(`Supplier goods AP line ${index + 1} net + VAT does not equal approved gross.`);
    }

    grossTotal = round2(grossTotal + grossAmount);
    sageNetTotal = round2(sageNetTotal + netAmount);

    return {
      description,
      ledger_account_id: ledgerAccountId,
      tax_rate_id: taxRateId,
      quantity,
      unit_price: round2(netAmount / quantity),
      currency_tax_amount: round2(vatAmount),
     };
  });

  const headerGross = num(row.amount_gbp || payload.amount_gbp);
  if (headerGross && Math.abs(grossTotal - round2(headerGross)) > 0.01) {
    throw new Error(`Supplier goods AP line gross total ${grossTotal.toFixed(2)} does not match batch amount ${round2(headerGross).toFixed(2)}.`);
  }
  if (!sageNetTotal) throw new Error("Supplier goods AP net total is missing; refusing to send gross as Sage net.");

  return {
    purchase_invoice: {
      contact_id: contactId,
      date,
      due_date: date,
      reference,
      notes,
      currency_code: currencyCode,
      invoice_lines: invoiceLines,
    },
  };
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

function retryableStatus(status: number) {
  return status === 408 || status === 429 || status >= 500;
}

async function updateBatchCounts(batchId: string) {
  const { data: rows } = await supabaseAdmin
    .from("sage_posting_batch_rows")
    .select("posting_status, amount_gbp")
    .eq("batch_id", batchId);
  const allRows = (rows ?? []) as Row[];
  const success = allRows.filter((row) => row.posting_status === "posted").length;
  const failed = allRows.filter((row) => ["failed_retryable", "failed_terminal"].includes(text(row.posting_status))).length;
  const active = allRows.filter((row) => text(row.posting_status) !== "excluded");
  const status = failed > 0 && success > 0 ? "partial_success" : failed > 0 ? "failed" : success === active.length && active.length > 0 ? "posted" : "draft";
  await supabaseAdmin.from("sage_posting_batches").update({
    status,
    batch_status: status === "posted" ? "posted" : status === "partial_success" ? "partially_posted" : "frozen_pending_posting",
    row_count: active.length,
    total_amount_gbp: active.reduce((sum, row) => sum + num(row.amount_gbp), 0),
    success_count: success,
    failed_count: failed,
    blocked_count: allRows.filter((row) => text(row.posting_status) === "excluded").length,
    posting_completed_at: status === "posted" || status === "failed" || status === "partial_success" ? new Date().toISOString() : null,
  }).eq("id", batchId);
}

export async function postSupplierGoodsApBatchToSage(params: {
  batchId: string;
  staffId: string;
  origin: string;
}) {
  if (process.env.SAGE_LIVE_POSTING_ENABLED !== "true") {
    throw new Error("Live Sage posting is disabled. Set SAGE_LIVE_POSTING_ENABLED=true only after supplier-goods AP dry-run is approved.");
  }

  const { data: batch, error: batchError } = await supabaseAdmin
    .from("sage_posting_batches")
    .select("id, batch_ref, status, lane")
    .eq("id", params.batchId)
    .maybeSingle();
  if (batchError) throw new Error(batchError.message);
  if (!batch) throw new Error("Posting batch not found.");
  if (!["draft", "validated", "failed"].includes(text(batch.status))) throw new Error(`Batch status ${batch.status} is not postable.`);

  const { data: rowsRaw, error: rowsError } = await supabaseAdmin
    .from("sage_posting_batch_rows")
    .select("*")
    .eq("batch_id", params.batchId)
    .in("posting_status", ["included", "validated", "failed_retryable", "failed_terminal"]);
  if (rowsError) throw new Error(rowsError.message);
  const rows = (rowsRaw ?? []) as BatchRow[];
  if (rows.length === 0) throw new Error("No postable rows found in this batch.");
  if (rows.some((row) => row.document_lane !== "supplier_goods_ap")) throw new Error("Supplier-goods AP posting only supports a supplier_goods_ap-only batch.");
  if (rows.some((row) => row.payload_validation_status !== "dry_run_validated")) throw new Error("Every supplier goods AP row must be dry-run validated before posting.");
  if (rows.some((row) => text((row as Row).sage_object_id) || row.posting_status === "posted")) throw new Error("One or more supplier goods AP rows already have a Sage object id or posted status.");

  const context = await activeSageContext(params.origin);
  await supabaseAdmin.from("sage_posting_batches").update({
    status: "posting",
    posting_started_at: new Date().toISOString(),
  }).eq("id", params.batchId);

  let posted = 0;
  let failed = 0;

  for (const row of rows) {
    const attemptCount = (row.attempt_count ?? 0) + 1;
    const startedAt = new Date().toISOString();
    const endpointPath = "/purchase_invoices";

    await supabaseAdmin.from("sage_posting_batch_rows").update({
      posting_status: "posting",
      attempt_count: attemptCount,
      last_attempt_at: startedAt,
      error_code: null,
      error_message: null,
    }).eq("id", row.id);

    await supabaseAdmin.from("sage_posting_snapshots").update({
      sage_posting_status: "posting_in_progress",
      posting_attempt_count: attemptCount,
      last_posting_error: null,
    }).eq("id", row.snapshot_id);

    let requestBody: Row;
    try {
      requestBody = extractSupplierGoodsApPurchaseInvoicePayload(row);
    } catch (error) {
      failed += 1;
      const message = error instanceof Error ? error.message : "Could not build supplier goods AP Sage payload.";
      await supabaseAdmin.from("sage_posting_batch_rows").update({
        posting_status: "failed_terminal",
        payload_validation_status: "dry_run_failed",
        error_code: "payload_builder_failed",
        error_message: message,
      }).eq("id", row.id);
      await supabaseAdmin.from("sage_posting_snapshots").update({
        sage_posting_status: "posting_failed",
        last_posting_error: message,
      }).eq("id", row.snapshot_id);
      continue;
    }

    const { data: requestLog } = await supabaseAdmin.from("sage_api_request_log").insert({
      connection_id: context.connectionId,
      sage_business_row_id: context.sageBusinessRowId,
      posting_batch_id: params.batchId,
      posting_batch_row_id: row.id,
      connection_event_type: "posting_batch",
      request_kind: "posting",
      http_method: "POST",
      endpoint_path: endpointPath,
      idempotency_key: row.idempotency_key,
      request_payload_redacted: requestBody,
      request_headers_redacted: { accept: "application/json", content_type: "application/json", x_business: context.sageBusinessId },
      request_payload_hash: bodyHash(requestBody),
      created_by_staff_id: params.staffId,
    }).select("id").single();

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
        body: JSON.stringify(requestBody),
        cache: "no-store",
      });
      raw = await response.json().catch(async () => ({ non_json_body: await response!.text().catch(() => null) }));
    } catch (error) {
      raw = { error: error instanceof Error ? error.message : "Network error calling Sage." };
    }

    const durationMs = Date.now() - fetchStarted;
    const success = Boolean(response?.ok);
    const objectId = success ? sageObjectId(raw) : "";
    const reference = success ? sageReference(raw) || text(requestBody.purchase_invoice?.reference) : "";

    if (requestLog?.id) {
      await supabaseAdmin.from("sage_api_response_log").insert({
        request_log_id: requestLog.id,
        connection_id: context.connectionId,
        sage_business_row_id: context.sageBusinessRowId,
        http_status: response?.status ?? null,
        success_yn: success && Boolean(objectId),
        sage_object_type: "purchase_invoice",
        sage_object_id: objectId || null,
        sage_reference: reference || null,
        response_payload_redacted: raw as Row,
        error_code: success && objectId ? null : (response ? `sage_http_${response.status}` : "sage_network_error"),
        error_message: success && objectId ? null : errorMessage(raw),
        duration_ms: durationMs,
      });
    }

    if (success && objectId) {
      posted += 1;
      const postedAt = new Date().toISOString();
      await supabaseAdmin.from("sage_posting_batch_rows").update({
        posting_status: "posted",
        sage_object_type: "purchase_invoice",
        sage_object_id: objectId,
        sage_reference: reference || text(requestBody.purchase_invoice?.reference),
        response_payload_json: raw as Row,
        posted_at: postedAt,
        error_code: null,
        error_message: null,
      }).eq("id", row.id);
      await supabaseAdmin.from("sage_posting_snapshots").update({
        sage_posting_status: "posted",
        sage_invoice_id: objectId,
        sage_posted_at: postedAt,
        last_posting_error: null,
      }).eq("id", row.snapshot_id);
    } else {
      failed += 1;
      const status = response?.status ?? 0;
      const postingStatus = retryableStatus(status) ? "failed_retryable" : "failed_terminal";
      const message = errorMessage(raw);
      await supabaseAdmin.from("sage_posting_batch_rows").update({
        posting_status: postingStatus,
        response_payload_json: raw as Row,
        error_code: response ? `sage_http_${response.status}` : "sage_network_error",
        error_message: message,
      }).eq("id", row.id);
      await supabaseAdmin.from("sage_posting_snapshots").update({
        sage_posting_status: "posting_failed",
        last_posting_error: message,
      }).eq("id", row.snapshot_id);
    }
  }

  await updateBatchCounts(params.batchId);
  return { posted, failed, total: rows.length };
}
