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

export type ApPostingLane = "supplier_goods_ap" | "shipper_ap";

type BatchRow = {
  id: string;
  batch_id: string;
  snapshot_id: string | null;
  idempotency_key: string | null;
  payload_hash: string | null;
  posting_status: string;
  sage_object_type: string | null;
  sage_object_id: string | null;
  posted_at: string | null;
  request_payload_json: Row;
  response_payload_json: Row | null;
  payload_validation_status: string;
  error_code: string | null;
  error_message: string | null;
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
  last_attempt_at: string | null;
};

type RetrySnapshot = {
  id: string;
  active: boolean | null;
  document_lane: string | null;
  approval_status: string | null;
  revalidation_status: string | null;
  sage_posting_status: string | null;
  sage_invoice_id: string | null;
  sage_posted_at: string | null;
  posting_attempt_count: number | null;
  last_posting_error: string | null;
};

type ApLaneConfig = {
  lane: ApPostingLane;
  label: string;
  notesSuffix: string;
  ledgerMappingCode: string;
  taxRateMappingCode: string;
  requireExplicitNetVatGross: boolean;
  contactPaths: Array<Array<string | number>>;
  datePaths: Array<Array<string | number>>;
  referencePaths: Array<Array<string | number>>;
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

function hasAmount(value: unknown) {
  if (typeof value === "number") return Number.isFinite(value);
  if (typeof value === "string") return value.trim() !== "" && Number.isFinite(Number(value));
  return false;
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

function firstAmount(value: unknown, paths: Array<Array<string | number>>) {
  for (const path of paths) {
    const found = getPath(value, path);
    if (hasAmount(found)) return num(found);
  }
  return 0;
}

function firstPresentAmount(value: unknown, paths: Array<Array<string | number>>) {
  for (const path of paths) {
    const found = getPath(value, path);
    if (hasAmount(found)) return { present: true, amount: num(found) };
  }
  return { present: false, amount: 0 };
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

function apLaneConfig(lane: string | null | undefined): ApLaneConfig {
  if (lane === "supplier_goods_ap") {
    return {
      lane,
      label: "Supplier goods AP",
      notesSuffix: "Supplier goods AP",
      ledgerMappingCode: "SUPPLIER_GOODS_AP_LEDGER",
      taxRateMappingCode: "SUPPLIER_GOODS_AP_TAX_RATE",
      requireExplicitNetVatGross: true,
      contactPaths: [
        ["supplier_target", "sage_contact_id"],
        ["sage_header", "contact_id"],
        ["sage_header", "sage_contact_id"],
        ["source_payload", "supplier_target", "sage_contact_id"],
      ],
      datePaths: [
        ["sage_header", "date"],
        ["sage_header", "invoice_date"],
        ["source_payload", "supplier_invoice_date"],
        ["source_payload", "invoice_date"],
        ["source_payload", "document_date"],
        ["commercial_payload", "supplier_invoice_date"],
      ],
      referencePaths: [
        ["sage_header", "reference"],
        ["source_payload", "sage_header", "reference"],
        ["source_payload", "supplier_invoice_ref"],
        ["source_payload", "document_ref"],
        ["supplier_invoice_ref"],
        ["document_ref"],
      ],
    };
  }

  if (lane === "shipper_ap") {
    return {
      lane,
      label: "Shipper AP",
      notesSuffix: "Shipper AP",
      ledgerMappingCode: "SHIPPER_FREIGHT_COST_LEDGER",
      taxRateMappingCode: "SHIPPER_AP_TAX_RATE_REVIEW",
      requireExplicitNetVatGross: false,
      contactPaths: [
        ["shipper_target", "sage_contact_id"],
        ["supplier_target", "sage_contact_id"],
        ["sage_header", "contact_id"],
        ["sage_header", "sage_contact_id"],
        ["source_payload", "shipper_target", "sage_contact_id"],
        ["source_payload", "supplier_target", "sage_contact_id"],
      ],
      datePaths: [
        ["sage_header", "date"],
        ["sage_header", "invoice_date"],
        ["source_payload", "shipping_document_date"],
        ["source_payload", "document_date"],
        ["source_payload", "invoice_date"],
        ["source_payload", "shipper_invoice_date"],
        ["commercial_payload", "shipping_document_date"],
        ["commercial_payload", "document_date"],
        ["commercial_payload", "shipper_invoice_date"],
      ],
      referencePaths: [
        ["sage_header", "reference"],
        ["source_payload", "sage_header", "reference"],
        ["source_payload", "shipping_document_ref"],
        ["source_payload", "document_ref"],
        ["source_payload", "shipper_invoice_ref"],
        ["shipping_document_ref"],
        ["document_ref"],
      ],
    };
  }

  throw new Error(`Unsupported AP posting lane ${lane || "unknown"}.`);
}

function mappingValue(payload: Row, code: string) {
  return firstText(payload, [
    ["mapping_snapshot", code, "sage_external_id"],
    ["source_payload", "mapping_snapshot", code, "sage_external_id"],
  ]);
}

function extractApPurchaseInvoicePayload(row: BatchRow) {
  const config = apLaneConfig(row.document_lane);
  const payload = asObject(row.request_payload_json);
  const header = asObject(payload.sage_header);
  const contactId = firstText(payload, config.contactPaths);
  const date = firstText(payload, config.datePaths);
  const reference = firstText(payload, config.referencePaths)
    || text(row.reference_text)
    || text(row.order_ref)
    || row.id;
  const notes = text(header.notes) || `Order ${text(row.order_ref)} · ${config.notesSuffix}`;
  const currencyCode = text(header.currency_code) || text(row.currency_code) || "GBP";
  const resolvedLines = asArray(payload.resolved_lines).map(asObject);
  const frozenLedgerAccountId = mappingValue(payload, config.ledgerMappingCode);
  const frozenTaxRateId = mappingValue(payload, config.taxRateMappingCode);

  if (!contactId) throw new Error(`${config.label} Sage supplier contact id missing from frozen payload.`);
  if (!date) throw new Error(`${config.label} invoice date missing from frozen payload.`);
  if (resolvedLines.length === 0) throw new Error(`${config.label} invoice has no resolved lines.`);
  if (!frozenLedgerAccountId) throw new Error(`${config.label} frozen ledger mapping is missing.`);
  if (!frozenTaxRateId) throw new Error(`${config.label} frozen tax-rate mapping is missing.`);

  let sourceTotal = 0;
  let sageNetTotal = 0;

  const invoiceLines = resolvedLines.map((line, index) => {
    const description = firstText(line, [["description"], ["posting_description"], ["source_description"]]);
    const ledgerAccountId = firstText(line, [["sage_ledger_account_id"], ["resolved_ledger_account_id"]]) || frozenLedgerAccountId;
    const taxRateId = frozenTaxRateId || firstText(line, [["sage_tax_rate_id"], ["resolved_tax_rate_id"]]);
    const quantity = num(line.quantity || line.qty || 1) || 1;
    const amountPaths = [["gross_amount_gbp"], ["total_line_amount_gbp"], ["line_total_gbp"], ["amount_gbp"], ["unit_price_gbp"], ["unit_price"]] as Array<Array<string | number>>;
    const supplierGross = config.lane === "supplier_goods_ap" ? firstPresentAmount(line, amountPaths) : null;
    const grossAmount = supplierGross ? supplierGross.amount : firstAmount(line, amountPaths);
    const hasNet = hasAmount(line.net_amount_gbp);
    const hasVat = hasAmount(line.vat_amount_gbp);
    const netAmount = hasNet ? num(line.net_amount_gbp) : grossAmount;
    const vatAmount = hasVat ? num(line.vat_amount_gbp) : 0;

    if (!description) throw new Error(`${config.label} line ${index + 1} missing description.`);
    if (!ledgerAccountId) throw new Error(`${config.label} line ${index + 1} missing ledger account id.`);
    if (!taxRateId) throw new Error(`${config.label} line ${index + 1} missing tax rate id.`);
    if (config.lane === "supplier_goods_ap") {
      if (!supplierGross?.present) throw new Error(`${config.label} line ${index + 1} missing amount.`);
    } else if (!grossAmount) {
      throw new Error(`${config.label} line ${index + 1} missing amount.`);
    }

    if (config.requireExplicitNetVatGross) {
      if (!hasNet) throw new Error(`${config.label} line ${index + 1} missing net amount.`);
      if (!hasVat) throw new Error(`${config.label} line ${index + 1} missing VAT amount.`);
      if (Math.abs(round2(netAmount + vatAmount) - round2(grossAmount)) > 0.01) {
        throw new Error(`${config.label} line ${index + 1} net + VAT does not equal approved gross.`);
      }
    } else if ((hasNet || hasVat) && Math.abs(round2(netAmount + vatAmount) - round2(grossAmount)) > 0.01) {
      throw new Error(`${config.label} line ${index + 1} net + VAT does not equal approved total.`);
    }

    sourceTotal = round2(sourceTotal + grossAmount);
    sageNetTotal = round2(sageNetTotal + netAmount);

    if (
      config.lane === "supplier_goods_ap"
      && round2(grossAmount) === 0
      && round2(netAmount) === 0
      && round2(vatAmount) === 0
    ) {
      return null;
    }

    const invoiceLine: Row = {
      description,
      ledger_account_id: ledgerAccountId,
      tax_rate_id: taxRateId,
      quantity,
      unit_price: round2(netAmount / quantity),
    };

    if (hasVat || config.requireExplicitNetVatGross) {
      const taxAmount = round2(vatAmount);
      invoiceLine.tax_amount = taxAmount;
      invoiceLine.currency_tax_amount = taxAmount;
    }

    return invoiceLine;
  }).filter((line): line is Row => line !== null);

  const headerAmount = num(row.amount_gbp || payload.amount_gbp);
  if (headerAmount && Math.abs(sourceTotal - round2(headerAmount)) > 0.01) {
    throw new Error(`${config.label} line total ${sourceTotal.toFixed(2)} does not match batch amount ${round2(headerAmount).toFixed(2)}.`);
  }
  if (!sageNetTotal) throw new Error(`${config.label} net total is missing.`);
  if (invoiceLines.length === 0) throw new Error(`${config.label} invoice has no non-zero resolved lines.`);

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

async function preflightSupplierGoodsApFailedRowRetry(args: { batch: Row; row: BatchRow }) {
  const { batch, row } = args;
  if (text(batch.status) !== "partial_success" || text(batch.batch_status) !== "partially_posted") {
    throw new Error("Supplier goods AP failed-row retry requires a partially posted batch.");
  }
  if (row.document_lane !== "supplier_goods_ap") {
    throw new Error("Failed-row retry is restricted to Supplier goods AP.");
  }
  if (!["failed_terminal", "failed_retryable"].includes(text(row.posting_status))) {
    throw new Error("Supplier goods AP row is not in a failed posting state.");
  }
  if (text(row.error_code) !== "payload_builder_failed") {
    throw new Error("Supplier goods AP row retry is restricted to a local payload-builder failure.");
  }
  if (text(row.sage_object_id) || text(row.posted_at)) {
    throw new Error("Supplier goods AP row already has Sage posting evidence and cannot be retried.");
  }
  if (row.payload_validation_status !== "dry_run_failed") {
    throw new Error("Supplier goods AP failed-row retry requires the governed dry-run-failed state.");
  }

  const priorValidation = asObject(row.response_payload_json);
  if (
    asArray(priorValidation.validation_errors).length !== 0
    || priorValidation.sage_api_call_made !== false
    || priorValidation.sage_object_created !== false
  ) {
    throw new Error("Prior dry-run evidence does not prove a no-Sage-object local builder failure.");
  }
  if (!row.snapshot_id) {
    throw new Error("Supplier goods AP failed row has no linked posting snapshot.");
  }

  const { data: snapshotRaw, error: snapshotError } = await supabaseAdmin
    .from("sage_posting_snapshots")
    .select("id, active, document_lane, approval_status, revalidation_status, sage_posting_status, sage_invoice_id, sage_posted_at, posting_attempt_count, last_posting_error")
    .eq("id", row.snapshot_id)
    .maybeSingle();
  if (snapshotError) throw new Error(snapshotError.message);
  const snapshot = (snapshotRaw ?? null) as RetrySnapshot | null;
  if (!snapshot) throw new Error("Supplier goods AP posting snapshot not found.");
  if (
    snapshot.active !== true
    || text(snapshot.document_lane) !== "supplier_goods_ap"
    || text(snapshot.approval_status) !== "approved_frozen"
    || text(snapshot.revalidation_status) !== "ok_to_post"
    || text(snapshot.sage_posting_status) !== "posting_failed"
    || text(snapshot.sage_invoice_id)
    || text(snapshot.sage_posted_at)
  ) {
    throw new Error("Supplier goods AP snapshot is not the governed active, approved, unposted posting-failed snapshot.");
  }

  const { data: priorRequests, error: priorRequestsError } = await supabaseAdmin
    .from("sage_api_request_log")
    .select("id")
    .eq("posting_batch_row_id", row.id)
    .eq("request_kind", "posting")
    .limit(1);
  if (priorRequestsError) throw new Error(priorRequestsError.message);
  if ((priorRequests ?? []).length > 0) {
    throw new Error("Supplier goods AP row has prior Sage posting-request evidence and cannot use local-builder retry.");
  }

  return {
    requestBody: extractApPurchaseInvoicePayload(row),
    snapshot,
  };
}

async function restoreSupplierGoodsApRetryClaim(args: { row: BatchRow; snapshot: RetrySnapshot }) {
  const { row, snapshot } = args;
  const restoreErrors: string[] = [];

  const { error: rowRestoreError } = await supabaseAdmin
    .from("sage_posting_batch_rows")
    .update({
      posting_status: row.posting_status,
      payload_validation_status: row.payload_validation_status,
      attempt_count: row.attempt_count,
      last_attempt_at: row.last_attempt_at,
      error_code: row.error_code,
      error_message: row.error_message,
    })
    .eq("id", row.id)
    .eq("batch_id", row.batch_id)
    .eq("posting_status", "posting")
    .is("sage_object_id", null)
    .is("posted_at", null);
  if (rowRestoreError) restoreErrors.push(`row restore failed: ${rowRestoreError.message}`);

  const { error: snapshotRestoreError } = await supabaseAdmin
    .from("sage_posting_snapshots")
    .update({
      sage_posting_status: snapshot.sage_posting_status,
      posting_attempt_count: snapshot.posting_attempt_count,
      last_posting_error: snapshot.last_posting_error,
    })
    .eq("id", snapshot.id)
    .eq("sage_posting_status", "posting_in_progress")
    .is("sage_invoice_id", null)
    .is("sage_posted_at", null);
  if (snapshotRestoreError) restoreErrors.push(`snapshot restore failed: ${snapshotRestoreError.message}`);

  if (restoreErrors.length > 0) {
    throw new Error(`Supplier goods AP retry was blocked but its local claim could not be fully restored: ${restoreErrors.join(" | ")}`);
  }
}

export async function postApPurchaseInvoiceBatchToSage(params: {
  batchId: string;
  staffId: string;
  origin: string;
  documentLane?: ApPostingLane;
  rowId?: string;
}) {
  if (process.env.SAGE_LIVE_POSTING_ENABLED !== "true") {
    throw new Error("Live Sage posting is disabled. Set SAGE_LIVE_POSTING_ENABLED=true only after AP dry-run is approved.");
  }

  const rowRetry = Boolean(params.rowId);
  const { data: batch, error: batchError } = await supabaseAdmin
    .from("sage_posting_batches")
    .select("id, batch_ref, status, batch_status, lane")
    .eq("id", params.batchId)
    .maybeSingle();
  if (batchError) throw new Error(batchError.message);
  if (!batch) throw new Error("Posting batch not found.");
  if (!rowRetry && !["draft", "validated", "failed"].includes(text(batch.status))) {
    throw new Error(`Batch status ${batch.status} is not postable.`);
  }
  if (rowRetry && text(batch.status) !== "partial_success") {
    throw new Error(`Batch status ${batch.status} is not eligible for failed-row retry.`);
  }

  let rowsQuery = supabaseAdmin
    .from("sage_posting_batch_rows")
    .select("*")
    .eq("batch_id", params.batchId);
  rowsQuery = rowRetry
    ? rowsQuery.eq("id", params.rowId as string).in("posting_status", ["failed_retryable", "failed_terminal"])
    : rowsQuery.in("posting_status", ["included", "validated", "failed_retryable", "failed_terminal"]);

  const { data: rowsRaw, error: rowsError } = await rowsQuery;
  if (rowsError) throw new Error(rowsError.message);
  const rows = (rowsRaw ?? []) as BatchRow[];
  if (rows.length === 0) throw new Error(rowRetry ? "Failed Supplier goods AP row was not found in the expected retry state." : "No postable rows found in this batch.");
  if (rowRetry && rows.length !== 1) throw new Error("Failed-row retry must resolve exactly one posting row.");

  const rowLanes = Array.from(new Set(rows.map((row) => text(row.document_lane)).filter(Boolean)));
  if (rowLanes.length !== 1) throw new Error("AP posting requires a single-lane batch.");
  const rowLane = rowLanes[0] as ApPostingLane;
  const config = apLaneConfig(rowLane);
  if (params.documentLane && rowLane !== params.documentLane) throw new Error(`Expected ${params.documentLane} batch but found ${rowLane}.`);
  if (!rows.every((row) => row.document_lane === config.lane)) throw new Error(`${config.label} posting only supports a ${config.lane}-only batch.`);
  if (rowRetry && config.lane !== "supplier_goods_ap") throw new Error("Failed-row retry is restricted to Supplier goods AP.");
  if (!rowRetry && rows.some((row) => row.payload_validation_status !== "dry_run_validated")) {
    throw new Error(`Every ${config.label} row must be dry-run validated before posting.`);
  }
  if (rows.some((row) => text(row.sage_object_id) || row.posting_status === "posted" || text(row.posted_at))) {
    throw new Error(`One or more ${config.label} rows already have Sage posting evidence.`);
  }

  const retryPreflight = rowRetry
    ? await preflightSupplierGoodsApFailedRowRetry({ batch: batch as Row, row: rows[0] })
    : null;
  const retryRequestBody = retryPreflight?.requestBody ?? null;
  const retrySnapshot = retryPreflight?.snapshot ?? null;

  const context = await activeSageContext(params.origin);
  if (!rowRetry) {
    await supabaseAdmin.from("sage_posting_batches").update({
      status: "posting",
      posting_started_at: new Date().toISOString(),
    }).eq("id", params.batchId);
  }

  let posted = 0;
  let failed = 0;

  for (const row of rows) {
    const attemptCount = (row.attempt_count ?? 0) + 1;
    const startedAt = new Date().toISOString();
    const endpointPath = "/purchase_invoices";

    if (rowRetry) {
      if (!retrySnapshot) throw new Error("Supplier goods AP retry snapshot preflight is missing.");

      let rowClaimQuery = supabaseAdmin
        .from("sage_posting_batch_rows")
        .update({
          posting_status: "posting",
          payload_validation_status: "dry_run_validated",
          attempt_count: attemptCount,
          last_attempt_at: startedAt,
          error_code: null,
          error_message: null,
        })
        .eq("id", row.id)
        .eq("batch_id", params.batchId)
        .eq("snapshot_id", row.snapshot_id)
        .eq("document_lane", "supplier_goods_ap")
        .eq("error_code", "payload_builder_failed")
        .eq("payload_validation_status", "dry_run_failed")
        .in("posting_status", ["failed_retryable", "failed_terminal"])
        .is("sage_object_id", null)
        .is("posted_at", null);
      rowClaimQuery = row.payload_hash
        ? rowClaimQuery.eq("payload_hash", row.payload_hash)
        : rowClaimQuery.is("payload_hash", null);
      rowClaimQuery = row.attempt_count == null
        ? rowClaimQuery.is("attempt_count", null)
        : rowClaimQuery.eq("attempt_count", row.attempt_count);
      rowClaimQuery = row.last_attempt_at
        ? rowClaimQuery.eq("last_attempt_at", row.last_attempt_at)
        : rowClaimQuery.is("last_attempt_at", null);

      const { data: claimedRow, error: claimError } = await rowClaimQuery.select("id").maybeSingle();
      if (claimError) throw new Error(claimError.message);
      if (!claimedRow) throw new Error("Supplier goods AP failed row changed state before retry and was not claimed.");

      let snapshotClaimQuery = supabaseAdmin
        .from("sage_posting_snapshots")
        .update({
          sage_posting_status: "posting_in_progress",
          posting_attempt_count: attemptCount,
          last_posting_error: null,
        })
        .eq("id", row.snapshot_id)
        .eq("active", true)
        .eq("document_lane", "supplier_goods_ap")
        .eq("approval_status", "approved_frozen")
        .eq("revalidation_status", "ok_to_post")
        .eq("sage_posting_status", "posting_failed")
        .is("sage_invoice_id", null)
        .is("sage_posted_at", null);
      snapshotClaimQuery = retrySnapshot.posting_attempt_count == null
        ? snapshotClaimQuery.is("posting_attempt_count", null)
        : snapshotClaimQuery.eq("posting_attempt_count", retrySnapshot.posting_attempt_count);
      snapshotClaimQuery = retrySnapshot.last_posting_error
        ? snapshotClaimQuery.eq("last_posting_error", retrySnapshot.last_posting_error)
        : snapshotClaimQuery.is("last_posting_error", null);

      const { data: claimedSnapshot, error: snapshotClaimError } = await snapshotClaimQuery.select("id").maybeSingle();

      if (snapshotClaimError || !claimedSnapshot) {
        await restoreSupplierGoodsApRetryClaim({ row, snapshot: retrySnapshot });
        if (snapshotClaimError) throw new Error(snapshotClaimError.message);
        throw new Error("Supplier goods AP snapshot changed state before retry and was not claimed.");
      }

      const { data: batchRecheck, error: batchRecheckError } = await supabaseAdmin
        .from("sage_posting_batches")
        .select("status, batch_status")
        .eq("id", params.batchId)
        .maybeSingle();
      if (
        batchRecheckError
        || !batchRecheck
        || text(batchRecheck.status) !== "partial_success"
        || text(batchRecheck.batch_status) !== "partially_posted"
      ) {
        await restoreSupplierGoodsApRetryClaim({ row, snapshot: retrySnapshot });
        if (batchRecheckError) throw new Error(batchRecheckError.message);
        throw new Error("Supplier goods AP batch changed state before retry and was restored without a Sage call.");
      }

      const { data: postClaimPriorRequests, error: postClaimPriorRequestsError } = await supabaseAdmin
        .from("sage_api_request_log")
        .select("id")
        .eq("posting_batch_row_id", row.id)
        .eq("request_kind", "posting")
        .limit(1);
      if (postClaimPriorRequestsError || (postClaimPriorRequests ?? []).length > 0) {
        await restoreSupplierGoodsApRetryClaim({ row, snapshot: retrySnapshot });
        if (postClaimPriorRequestsError) throw new Error(postClaimPriorRequestsError.message);
        throw new Error("Supplier goods AP row gained Sage request evidence before retry and was restored without a Sage call.");
      }
    } else {
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
    }

    let requestBody: Row;
    try {
      requestBody = rowRetry ? retryRequestBody as Row : extractApPurchaseInvoicePayload(row);
    } catch (error) {
      failed += 1;
      const message = error instanceof Error ? error.message : `Could not build ${config.label} Sage payload.`;
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

    const { data: requestLog, error: requestLogError } = await supabaseAdmin.from("sage_api_request_log").insert({
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

    if (rowRetry && (requestLogError || !requestLog?.id)) {
      if (!retrySnapshot) throw new Error("Supplier goods AP retry snapshot preflight is missing.");
      await restoreSupplierGoodsApRetryClaim({ row, snapshot: retrySnapshot });
      throw new Error(`Could not create the Supplier goods AP Sage request audit log. No Sage call was made.${requestLogError ? ` ${requestLogError.message}` : ""}`);
    }

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
  return { posted, failed, total: rows.length, documentLane: config.lane, label: config.label };
}

export async function postSupplierGoodsApBatchToSage(params: {
  batchId: string;
  staffId: string;
  origin: string;
}) {
  return postApPurchaseInvoiceBatchToSage({ ...params, documentLane: "supplier_goods_ap" });
}

export async function postShipperApBatchToSage(params: {
  batchId: string;
  staffId: string;
  origin: string;
}) {
  return postApPurchaseInvoiceBatchToSage({ ...params, documentLane: "shipper_ap" });
}