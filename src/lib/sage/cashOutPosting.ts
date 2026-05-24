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
import { postCustomerReceiptCashBatchToSage } from "@/lib/sage/cashPosting";

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
  request_payload: Row;
  response_payload: Row | null;
  sage_object_id: string | null;
  sage_payment_on_account_id: string | null;
  attempt_count: number | null;
};

type BuiltCashOutRow = {
  row: CashRow;
  refs: Row;
  contactId: string;
  bankAccountId: string;
  date: string;
  amount: number;
  reference: string;
  targetSageObjectId: string;
  groupKey: string;
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

function contactPaymentId(raw: unknown) {
  return firstText(raw, [
    ["contact_payment", "id"],
    ["purchase_payment", "id"],
    ["payment", "id"],
    ["id"],
    ["$items", 0, "id"],
    ["data", "id"],
  ]);
}

function contactPaymentReference(raw: unknown, fallback: string) {
  return firstText(raw, [
    ["contact_payment", "reference"],
    ["contact_payment", "displayed_as"],
    ["purchase_payment", "reference"],
    ["purchase_payment", "displayed_as"],
    ["payment", "reference"],
    ["reference"],
    ["displayed_as"],
  ]) || fallback;
}

function extractPurchasePaymentPayload(row: CashRow) {
  const payload = asObject(row.request_payload);
  const purchasePayment = asObject(payload.purchase_payment);
  const contactPayment = asObject(payload.contact_payment);
  const paymentSource = Object.keys(contactPayment).length > 0 ? contactPayment : purchasePayment;
  const allocationTarget = asObject(payload.allocation_target);
  const endpoint = text(payload.endpoint) || "/contact_payments";
  const method = text(payload.method).toUpperCase() || "POST";
  const contactId = text(paymentSource.contact_id);
  const bankAccountId = text(paymentSource.bank_account_id);
  const date = text(paymentSource.date);
  const totalAmount = num(paymentSource.total_amount);
  const reference = text(paymentSource.reference);
  const allocatedArtefacts = Array.isArray(contactPayment.allocated_artefacts) ? contactPayment.allocated_artefacts : [];
  const targetSageObjectId = text(allocationTarget.purchase_invoice_id) || text(allocationTarget.target_sage_object_id) || firstText(allocatedArtefacts, [[0, "artefact_id"]]);
  const allocationAmount = num(allocationTarget.amount) || num(getPath(allocatedArtefacts, [0, "amount"])) || totalAmount;

  if (!["/contact_payments", "/purchase_payments"].includes(endpoint)) throw new Error(`Unexpected cash OUT endpoint ${endpoint}.`);
  if (method !== "POST") throw new Error(`Unexpected cash OUT method ${method}.`);
  if (!["supplier_invoice_payment", "shipper_invoice_payment"].includes(row.posting_category)) throw new Error("Cash OUT payload must be supplier or shipper payment category.");
  if (!contactId) throw new Error("Cash OUT payload missing Sage supplier contact_id.");
  if (!bankAccountId) throw new Error("Cash OUT payload missing Sage bank_account_id.");
  if (!date) throw new Error("Cash OUT payload missing posting date.");
  if (!(totalAmount > 0)) throw new Error("Cash OUT payment amount must be positive.");
  if (!reference) throw new Error("Cash OUT payload missing short Sage reference.");
  if (!targetSageObjectId) throw new Error("Cash OUT allocation target Sage purchase invoice id is missing.");
  if (Math.abs(totalAmount - num(row.amount_gbp)) > 0.01) throw new Error("Cash OUT payload amount does not match frozen allocation-row amount.");
  if (Math.abs(allocationAmount - totalAmount) > 0.01) throw new Error("Cash OUT allocation amount does not match allocation-row payment amount.");

  return {
    contactId,
    bankAccountId,
    date,
    targetSageObjectId,
    amount: totalAmount,
    reference,
  };
}

function statementGroupKey(row: CashRow, built: ReturnType<typeof extractPurchasePaymentPayload>, refs: Row) {
  const statementLineId = text(refs.statement_line_id) || text(refs.statementLineId) || `snapshot:${row.snapshot_id}`;
  return ["vendor_payment", built.contactId, built.bankAccountId, built.date, statementLineId].join("|");
}

function groupedReference(group: BuiltCashOutRow[]) {
  if (group.length === 1) return group[0].reference;
  const refs = group[0].refs;
  const raw = text(refs.reference_raw) || text(refs.auth_ref) || text(refs.statement_line_id) || group[0].reference;
  const cleaned = raw.replace(/[^A-Za-z0-9_-]/g, "").slice(0, 24);
  return `GCB-OUT-${cleaned || group[0].reference.slice(0, 18)}`;
}

function groupedPaymentRequestBody(group: BuiltCashOutRow[]) {
  const first = group[0];
  const totalAmount = round2(group.reduce((sum, item) => sum + item.amount, 0));
  return {
    contact_payment: {
      transaction_type_id: "VENDOR_PAYMENT",
      contact_id: first.contactId,
      bank_account_id: first.bankAccountId,
      date: first.date,
      total_amount: totalAmount,
      reference: groupedReference(group),
      allocated_artefacts: group.map((item) => ({
        artefact_id: item.targetSageObjectId,
        amount: item.amount,
      })),
    },
  };
}

async function snapshotReferenceMap(rows: CashRow[]) {
  const snapshotIds = Array.from(new Set(rows.map((row) => row.snapshot_id).filter(Boolean)));
  if (snapshotIds.length === 0) return new Map<string, Row>();

  const { data, error } = await supabaseAdmin
    .from("cash_posting_snapshots")
    .select("id, internal_reference_json")
    .in("id", snapshotIds);
  if (error) throw new Error(error.message);

  return new Map((data ?? []).map((row: Row) => [text(row.id), asObject(row.internal_reference_json)]));
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

export async function postSupplierOrShipperPaymentCashBatchToSage(params: { batchId: string; staffId: string; origin: string }) {
  if (process.env.SAGE_LIVE_CASH_OUT_POSTING_ENABLED !== "true") {
    throw new Error("Live Sage cash OUT posting is disabled. Set SAGE_LIVE_CASH_OUT_POSTING_ENABLED=true only after approving the first controlled supplier/shipper OUT test.");
  }

  const { data: batch, error: batchError } = await supabaseAdmin
    .from("cash_posting_batches")
    .select("id, batch_ref, posting_category, batch_status")
    .eq("id", params.batchId)
    .eq("active", true)
    .maybeSingle();
  if (batchError) throw new Error(batchError.message);
  if (!batch) throw new Error("Cash posting batch not found.");
  if (!["supplier_invoice_payment", "shipper_invoice_payment", "out_purchase_payment"].includes(text(batch.posting_category))) {
    throw new Error("Only supplier/shipper OUT cash batches are supported by this poster.");
  }
  if (!["validated", "failed", "partially_posted"].includes(text(batch.batch_status))) throw new Error(`Cash batch status ${batch.batch_status} is not postable.`);

  const { data: rowsRaw, error: rowsError } = await supabaseAdmin
    .from("cash_posting_batch_rows")
    .select("*")
    .eq("batch_id", params.batchId)
    .eq("active", true)
    .in("posting_status", ["not_posted", "failed_retryable"]);
  if (rowsError) throw new Error(rowsError.message);
  const rows = (rowsRaw ?? []) as CashRow[];
  if (rows.length === 0) throw new Error("No postable supplier/shipper OUT cash rows found in this batch.");
  if (rows.some((row) => !["supplier_invoice_payment", "shipper_invoice_payment"].includes(row.posting_category))) throw new Error("Cash posting batch contains a non-OUT-payment row.");
  if (rows.some((row) => row.validation_status !== "validated")) throw new Error("Every cash OUT row must be validated before posting.");
  if (rows.some((row) => text(row.sage_object_id))) throw new Error("One or more cash OUT rows already have a Sage payment object id.");

  const context = await activeSageContext(params.origin);
  await supabaseAdmin.from("cash_posting_batches").update({
    batch_status: "posting",
    posting_started_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
  }).eq("id", params.batchId);

  let posted = 0;
  let failed = 0;
  let needsReview = 0;
  const refsBySnapshotId = await snapshotReferenceMap(rows);
  const preparedRows: BuiltCashOutRow[] = [];

  for (const row of rows) {
    const attemptCount = (row.attempt_count ?? 0) + 1;
    const startedAt = new Date().toISOString();

    await supabaseAdmin.from("cash_posting_batch_rows").update({
      posting_status: "posting",
      attempt_count: attemptCount,
      last_attempt_at: startedAt,
      error_code: null,
      error_message: null,
      updated_at: startedAt,
    }).eq("id", row.id);

    await supabaseAdmin.from("cash_posting_snapshots").update({
      sage_posting_status: "posting_in_progress",
      updated_at: startedAt,
    }).eq("id", row.snapshot_id);

    try {
      const built = extractPurchasePaymentPayload(row);
      const refs = refsBySnapshotId.get(row.snapshot_id) ?? {};
      preparedRows.push({
        row,
        refs,
        ...built,
        groupKey: statementGroupKey(row, built, refs),
      });
    } catch (error) {
      failed += 1;
      const message = error instanceof Error ? error.message : "Could not build cash OUT Sage payload.";
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
    }
  }

  const groups = new Map<string, BuiltCashOutRow[]>();
  for (const item of preparedRows) groups.set(item.groupKey, [...(groups.get(item.groupKey) ?? []), item]);

  for (const group of groups.values()) {
    const paymentEndpointPath = "/contact_payments";
    const paymentRequestBody = groupedPaymentRequestBody(group);
    const groupTotal = num(getPath(paymentRequestBody, ["contact_payment", "total_amount"]));
    const groupReference = text(getPath(paymentRequestBody, ["contact_payment", "reference"]));
    const first = group[0];
    const rowIds = group.map((item) => item.row.id);
    const snapshotIds = group.map((item) => item.row.snapshot_id);

    const { data: paymentRequestLog } = await supabaseAdmin.from("sage_api_request_log").insert({
      connection_id: context.connectionId,
      sage_business_row_id: context.sageBusinessRowId,
      posting_batch_id: params.batchId,
      posting_batch_row_id: first.row.id,
      connection_event_type: "posting_batch",
      request_kind: "cash_out_contact_payment_group",
      http_method: "POST",
      endpoint_path: paymentEndpointPath,
      idempotency_key: `cash-out-group:${params.batchId}:${first.groupKey}`,
      request_payload_redacted: paymentRequestBody,
      request_headers_redacted: { accept: "application/json", content_type: "application/json", x_business: context.sageBusinessId },
      request_payload_hash: bodyHash(paymentRequestBody),
      created_by_staff_id: params.staffId,
    }).select("id").single();

    const paymentResult = await sagePost(context, paymentEndpointPath, paymentRequestBody);
    const paymentId = paymentResult.ok ? contactPaymentId(paymentResult.raw) : "";
    const reference = paymentResult.ok ? contactPaymentReference(paymentResult.raw, groupReference) : "";
    const paymentErr = paymentResult.ok && !paymentId ? "Sage returned success but no contact_payment id could be extracted." : errorMessage(paymentResult.raw);

    if (paymentRequestLog?.id) {
      await supabaseAdmin.from("sage_api_response_log").insert({
        request_log_id: paymentRequestLog.id,
        connection_id: context.connectionId,
        sage_business_row_id: context.sageBusinessRowId,
        http_status: paymentResult.response?.status ?? null,
        success_yn: paymentResult.ok && Boolean(paymentId),
        sage_object_type: "contact_payment",
        sage_object_id: paymentId || null,
        sage_reference: reference || null,
        response_payload_redacted: paymentResult.raw as Row,
        error_code: paymentResult.ok && paymentId ? null : (paymentResult.response ? `sage_http_${paymentResult.response.status}` : "sage_network_error"),
        error_message: paymentResult.ok && paymentId ? null : paymentErr,
        duration_ms: paymentResult.durationMs,
      });
    }

    const now = new Date().toISOString();
    if (paymentResult.ok && paymentId) {
      posted += group.length;
      for (const item of group) {
        await supabaseAdmin.from("cash_posting_batch_rows").update({
          posting_status: "posted",
          sage_object_type: "contact_payment",
          sage_object_id: paymentId,
          sage_reference: reference || groupReference,
          response_payload: { contact_payment: paymentResult.raw, grouped_rows: rowIds, group_total_gbp: groupTotal } as Row,
          posted_at: now,
          error_code: null,
          error_message: null,
          sage_allocation_status: "allocated_in_contact_payment",
          sage_allocation_id: paymentId,
          sage_allocation_amount_gbp: item.amount,
          sage_allocation_target_object_id: item.targetSageObjectId,
          sage_allocation_request_payload: paymentRequestBody,
          sage_allocation_response_payload: paymentResult.raw as Row,
          sage_allocation_error_code: null,
          sage_allocation_error_message: null,
          sage_allocation_posted_at: now,
          updated_at: now,
        }).eq("id", item.row.id);
      }
      for (const item of group) {
        await supabaseAdmin.from("cash_posting_snapshots").update({
          sage_posting_status: "posted",
          sage_object_id: paymentId,
          sage_response_payload: { contact_payment: paymentResult.raw, grouped_rows: rowIds, group_total_gbp: groupTotal } as Row,
          sage_allocation_status: "allocated_in_contact_payment",
          sage_allocation_id: paymentId,
          sage_allocation_amount_gbp: item.amount,
          sage_allocation_target_object_id: item.targetSageObjectId,
          sage_allocation_request_payload: paymentRequestBody,
          sage_allocation_response_payload: paymentResult.raw as Row,
          sage_allocation_error_code: null,
          sage_allocation_error_message: null,
          sage_allocation_posted_at: now,
          updated_at: now,
        }).eq("id", item.row.snapshot_id);
      }
    } else {
      failed += group.length;
      const statusCode = paymentResult.response?.status ?? 0;
      const postingStatus = retryableStatus(statusCode) ? "failed_retryable" : "failed_terminal";
      await supabaseAdmin.from("cash_posting_batch_rows").update({
        posting_status: postingStatus,
        response_payload: { contact_payment: paymentResult.raw, grouped_rows: rowIds, group_total_gbp: groupTotal } as Row,
        error_code: paymentResult.response ? `sage_http_${paymentResult.response.status}` : "sage_network_error",
        error_message: paymentErr,
        updated_at: now,
      }).in("id", rowIds);
      await supabaseAdmin.from("cash_posting_snapshots").update({
        sage_posting_status: "posting_failed",
        sage_response_payload: { contact_payment: paymentResult.raw, grouped_rows: rowIds, group_total_gbp: groupTotal } as Row,
        updated_at: now,
      }).in("id", snapshotIds);
    }
  }

  await updateCashBatchCounts(params.batchId);
  return { posted, failed, needsReview, total: rows.length, endpoint: "/contact_payments", groupedPayments: groups.size };
}

export async function postCashBatchToSage(params: { batchId: string; staffId: string; origin: string }) {
  const { data: batch, error: batchError } = await supabaseAdmin
    .from("cash_posting_batches")
    .select("posting_category")
    .eq("id", params.batchId)
    .eq("active", true)
    .maybeSingle();
  if (batchError) throw new Error(batchError.message);
  const category = text(batch?.posting_category);

  if (category === "customer_receipt_on_account") {
    return postCustomerReceiptCashBatchToSage(params);
  }
  return postSupplierOrShipperPaymentCashBatchToSage(params);
}
