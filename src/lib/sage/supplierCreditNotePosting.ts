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
import {
  postSupplierCreditNoteToSage,
  type SupplierCreditNoteSource,
} from "@/lib/accounting/sage/supplier-credit-note.adapter";

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

function bodyHash(value: unknown) {
  return crypto.createHash("sha256").update(JSON.stringify(value ?? {})).digest("hex");
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

function sageObjectId(raw: unknown) {
  return firstText(raw, [["id"], ["purchase_credit_note", "id"], ["$items", 0, "id"], ["data", "id"]]);
}

function sageReference(raw: unknown) {
  return firstText(raw, [["reference"], ["displayed_as"], ["purchase_credit_note", "reference"], ["purchase_credit_note", "displayed_as"]]);
}

function retryableStatus(status: number) {
  return status === 408 || status === 429 || status >= 500;
}

function extractSupplierCreditNoteSource(row: BatchRow): SupplierCreditNoteSource {
  const payload = asObject(row.request_payload_json);
  const controls = asObject(payload.controls);
  const header = asObject(payload.sage_header);
  const supplierTarget = asObject(payload.supplier_target);
  const lines = asArray(payload.resolved_lines).map(asObject);
  const sourcePayload = asObject(payload.source_payload);

  const contactId = firstText(payload, [
    ["supplier_target", "sage_contact_id"],
    ["sage_header", "contact_id"],
    ["sage_header", "sage_contact_id"],
    ["source_payload", "supplier_target", "sage_contact_id"],
  ]);
  const documentDate = firstText(payload, [
    ["sage_header", "date"],
    ["document_date"],
    ["source_payload", "sage_header", "date"],
    ["source_payload", "document_date"],
  ]);
  const reference = firstText(payload, [
    ["sage_header", "reference"],
    ["credit_note_ref"],
    ["source_payload", "sage_header", "reference"],
    ["source_payload", "credit_note_ref"],
  ]) || text(row.reference_text) || text(row.order_ref) || row.id;

  const sourceLines = lines.map((line, index) => {
    const description = firstText(line, [["description"], ["posting_description"], ["source_description"]]);
    const ledgerAccountId = firstText(line, [["sage_ledger_account_id"], ["resolved_ledger_account_id"]]);
    const taxRateId = firstText(line, [["sage_tax_rate_id"], ["tax_rate_id"], ["resolved_tax_rate_id"]]);
    const quantity = num(line.quantity || line.qty || 1) || 1;
    const netAmount = firstAmount(line, [["net_credit_gbp"], ["net_amount_gbp"], ["net_line_amount_gbp"]]);
    const vatAmount = firstAmount(line, [["vat_credit_gbp"], ["vat_amount_gbp"], ["tax_amount_gbp"]]);
    const grossAmount = firstAmount(line, [["gross_credit_gbp"], ["gross_amount_gbp"], ["total_line_amount_gbp"], ["line_total_gbp"], ["amount_gbp"], ["unit_price_gbp"], ["unit_price"]]);

    if (!description) throw new Error(`Supplier credit note line ${index + 1} missing description.`);
    if (!ledgerAccountId) throw new Error(`Supplier credit note line ${index + 1} missing ledger account id.`);
    if (!taxRateId) throw new Error(`Supplier credit note line ${index + 1} missing tax rate id.`);
    if (!grossAmount) throw new Error(`Supplier credit note line ${index + 1} missing amount.`);

    const netForSage = netAmount > 0 ? netAmount : grossAmount;
    if (netAmount > 0 && vatAmount >= 0 && Math.abs(round2(netAmount + vatAmount) - round2(grossAmount)) > 0.01) {
      throw new Error(`Supplier credit note line ${index + 1} net + VAT does not equal approved gross.`);
    }

    return {
      description,
      ledger_account_id: ledgerAccountId,
      quantity,
      unit_price: round2(netForSage / quantity),
      tax_rate_id: taxRateId,
      ...(vatAmount > 0 ? { tax_amount: round2(vatAmount), currency_tax_amount: round2(vatAmount) } : {}),
    };
  });

  return {
    posting_intent: "supplier_credit_note",
    refund_evidence_submission_id: text(payload.refund_evidence_submission_id) || text(row.source_id),
    original_supplier_invoice_id: text(payload.original_supplier_invoice_id),
    sage_retailer_supplier_contact_id: contactId || text(supplierTarget.sage_contact_id),
    document_date: documentDate,
    credit_note_ref: reference,
    notes: text(header.notes) || `Order ${text(row.order_ref)} · Supplier credit note`,
    supplier_approval_status: text(controls.supplier_approval_status) || text(sourcePayload.supplier_approval_status) || "approved_current",
    supplier_control_status: text(controls.supplier_control_status) || text(sourcePayload.supplier_control_status) || "approved_current",
    gross_reconciled_to_document_yn: controls.gross_reconciled_to_document_yn === true,
    all_progressed_lines_coded_yn: controls.all_progressed_lines_coded_yn === true,
    refund_in_allocation_covers_approved_amount: controls.refund_in_allocation_covers_approved_amount === true,
    frozen_payload_yn: true,
    already_posted_yn: Boolean(text(row as Row && (row as Row).sage_object_id)) || row.posting_status === "posted",
    lines: sourceLines,
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

export async function postSupplierCreditNoteBatchToSage(params: {
  batchId: string;
  staffId: string;
  origin: string;
}) {
  if (process.env.SAGE_LIVE_POSTING_ENABLED !== "true") {
    throw new Error("Live Sage posting is disabled. Set SAGE_LIVE_POSTING_ENABLED=true only after supplier credit note dry-run is approved.");
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
  if (rows.length === 0) throw new Error("No postable supplier credit note rows found in this batch.");
  if (rows.some((row) => row.document_lane !== "supplier_credit_note")) throw new Error("Supplier credit note posting only supports a supplier_credit_note-only batch.");
  if (rows.some((row) => row.payload_validation_status !== "dry_run_validated")) throw new Error("Every supplier credit note row must be dry-run validated before posting.");
  if (rows.some((row) => text((row as Row).sage_object_id) || row.posting_status === "posted")) throw new Error("One or more supplier credit note rows already have a Sage object id or posted status.");

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
    const endpointPath = "/purchase_credit_notes";

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

    let source: SupplierCreditNoteSource;
    try {
      source = extractSupplierCreditNoteSource(row);
    } catch (error) {
      failed += 1;
      const message = error instanceof Error ? error.message : "Could not build supplier credit note Sage payload.";
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

    let requestBody: unknown = null;
    const sagePost = async (path: string, body: unknown) => {
      requestBody = body;
      const { data: requestLog } = await supabaseAdmin.from("sage_api_request_log").insert({
        connection_id: context.connectionId,
        sage_business_row_id: context.sageBusinessRowId,
        posting_batch_id: params.batchId,
        posting_batch_row_id: row.id,
        connection_event_type: "posting_batch",
        request_kind: "posting",
        http_method: "POST",
        endpoint_path: path,
        idempotency_key: row.idempotency_key,
        request_payload_redacted: body as Row,
        request_headers_redacted: { accept: "application/json", content_type: "application/json", x_business: context.sageBusinessId },
        request_payload_hash: bodyHash(body),
        created_by_staff_id: params.staffId,
      }).select("id").single();

      let raw: unknown = {};
      let response: Response | null = null;
      const fetchStarted = Date.now();
      try {
        response = await fetch(`${context.config.apiBaseUrl.replace(/\/$/, "")}${path}`, {
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

      const durationMs = Date.now() - fetchStarted;
      const success = Boolean(response?.ok);
      const objectId = success ? sageObjectId(raw) : "";
      const reference = success ? sageReference(raw) || text((body as Row).purchase_credit_note?.reference) : "";

      if (requestLog?.id) {
        await supabaseAdmin.from("sage_api_response_log").insert({
          request_log_id: requestLog.id,
          connection_id: context.connectionId,
          sage_business_row_id: context.sageBusinessRowId,
          http_status: response?.status ?? null,
          success_yn: success && Boolean(objectId),
          sage_object_type: "purchase_credit_note",
          sage_object_id: objectId || null,
          sage_reference: reference || null,
          response_payload_redacted: raw as Row,
          error_code: success && objectId ? null : (response ? `sage_http_${response.status}` : "sage_network_error"),
          error_message: success && objectId ? null : errorMessage(raw),
          duration_ms: durationMs,
        });
      }

      if (!success || !objectId) {
        const status = response?.status ?? 0;
        throw Object.assign(new Error(errorMessage(raw)), {
          retryable: retryableStatus(status),
          responsePayload: raw,
          status,
        });
      }

      return raw;
    };

    try {
      const result = await postSupplierCreditNoteToSage(source, sagePost);
      posted += 1;
      const postedAt = new Date().toISOString();
      await supabaseAdmin.from("sage_posting_batch_rows").update({
        posting_status: "posted",
        sage_object_type: "purchase_credit_note",
        sage_object_id: result.sage_purchase_credit_note_id,
        sage_reference: result.sage_reference || source.credit_note_ref,
        request_payload_json: requestBody as Row,
        response_payload_json: result.raw as Row,
        posted_at: postedAt,
        error_code: null,
        error_message: null,
      }).eq("id", row.id);
      await supabaseAdmin.from("sage_posting_snapshots").update({
        sage_posting_status: "posted",
        sage_invoice_id: result.sage_purchase_credit_note_id,
        sage_posted_at: postedAt,
        last_posting_error: null,
      }).eq("id", row.snapshot_id);
    } catch (error) {
      failed += 1;
      const err = error as Error & { retryable?: boolean; responsePayload?: unknown; status?: number };
      const postingStatus = err.retryable ? "failed_retryable" : "failed_terminal";
      const message = err instanceof Error ? err.message : "Sage supplier credit note posting failed.";
      await supabaseAdmin.from("sage_posting_batch_rows").update({
        posting_status: postingStatus,
        response_payload_json: asObject(err.responsePayload),
        error_code: err.status ? `sage_http_${err.status}` : "sage_posting_error",
        error_message: message,
      }).eq("id", row.id);
      await supabaseAdmin.from("sage_posting_snapshots").update({
        sage_posting_status: "posting_failed",
        last_posting_error: message,
      }).eq("id", row.snapshot_id);
    }
  }

  await updateBatchCounts(params.batchId);
  return { posted, failed, total: rows.length, documentLane: "supplier_credit_note", label: "Supplier credit note" };
}
