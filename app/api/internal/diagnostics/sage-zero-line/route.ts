import { supabaseAdmin } from "@/lib/supabase/admin";
import { assertSageOAuthConfigured, decryptSecret, tokenRefreshRequired } from "@/lib/sage/oauth";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

const EXPECTED_BRANCH = "diagnostic/sage-zero-line-runtime-proof-v1";
const CONFIRMATION = "SAGE_ZERO_LINE_RUNTIME_PROOF";
const TEST_CONTACT_NAME = "Goodcashback API Zero Test";
const TEST_CONTACT_REFERENCE = "GCBZERO";
const CONTROL_DESCRIPTION = "Goodcashback zero-line control";
const ZERO_DESCRIPTION = "Goodcashback zero-line runtime proof";

type Row = Record<string, any>;

function text(value: unknown) {
  return typeof value === "string" ? value.trim() : "";
}

function reply(status: number, body: Row) {
  return Response.json(body, { status });
}

function objectId(raw: unknown) {
  const row = raw && typeof raw === "object" && !Array.isArray(raw) ? raw as Row : {};
  return text(row.id) || text(row.purchase_invoice?.id) || text(row.data?.id) || text(row.$items?.[0]?.id);
}

function findDescription(value: unknown, description: string): Row | null {
  if (Array.isArray(value)) {
    for (const child of value) {
      const found = findDescription(child, description);
      if (found) return found;
    }
    return null;
  }
  if (!value || typeof value !== "object") return null;
  const row = value as Row;
  if (text(row.description) === description) return row;
  for (const child of Object.values(row)) {
    const found = findDescription(child, description);
    if (found) return found;
  }
  return null;
}

async function sageCall(args: {
  apiBaseUrl: string;
  accessToken: string;
  sageBusinessId: string;
  method: "GET" | "POST" | "DELETE";
  path: string;
  body?: unknown;
}) {
  const response = await fetch(`${args.apiBaseUrl.replace(/\/$/, "")}${args.path}`, {
    method: args.method,
    headers: {
      Accept: "application/json",
      Authorization: `Bearer ${args.accessToken}`,
      "X-Business": args.sageBusinessId,
      ...(args.body === undefined ? {} : { "Content-Type": "application/json" }),
    },
    body: args.body === undefined ? undefined : JSON.stringify(args.body),
    cache: "no-store",
  });
  const raw = response.status === 204
    ? null
    : await response.json().catch(async () => ({ non_json_body: await response.text().catch(() => null) }));
  return {
    response,
    raw,
    requestId: response.headers.get("x-request-id") || response.headers.get("x_request_id"),
  };
}

export async function POST(request: Request) {
  if (process.env.VERCEL_ENV !== "preview" || process.env.VERCEL_GIT_COMMIT_REF !== EXPECTED_BRANCH) {
    return reply(404, { ok: false, code: "preview_branch_only" });
  }

  const input = await request.json().catch(() => ({})) as Row;
  if (input.confirm !== CONFIRMATION) return reply(400, { ok: false, code: "explicit_confirmation_required" });

  const config = assertSageOAuthConfigured(new URL(request.url).origin);

  const { data: tokenRows, error: tokenError } = await supabaseAdmin
    .from("sage_oauth_tokens")
    .select("id, connection_id, access_token_encrypted, expires_at, sage_business_row_id")
    .eq("status", "active")
    .order("expires_at", { ascending: false })
    .limit(1);
  if (tokenError) return reply(500, { ok: false, code: "token_read_failed", message: tokenError.message });
  const token = (tokenRows?.[0] ?? null) as Row | null;
  if (!token) return reply(409, { ok: false, code: "active_token_missing", sage_write_made: false });
  if (tokenRefreshRequired(token.expires_at, 120)) {
    return reply(409, {
      ok: false,
      code: "active_token_too_close_to_expiry",
      sage_write_made: false,
      note: "Probe refuses to refresh or mutate OAuth state.",
    });
  }

  const { data: connection, error: connectionError } = await supabaseAdmin
    .from("sage_connections")
    .select("id, status")
    .eq("id", token.connection_id)
    .maybeSingle();
  if (connectionError || !connection || connection.status !== "connected") {
    return reply(409, { ok: false, code: "sage_connection_not_connected", sage_write_made: false });
  }

  let businessQuery = supabaseAdmin
    .from("sage_businesses")
    .select("id, sage_business_id, sage_business_name")
    .eq("connection_id", token.connection_id)
    .eq("status", "active")
    .order("is_primary", { ascending: false })
    .limit(1);
  const selectedBusinessRowId = text(token.sage_business_row_id);
  if (selectedBusinessRowId) businessQuery = businessQuery.eq("id", selectedBusinessRowId);
  const { data: businesses, error: businessError } = await businessQuery;
  if (businessError) return reply(500, { ok: false, code: "business_read_failed", message: businessError.message });
  const business = (businesses?.[0] ?? null) as Row | null;
  const sageBusinessId = text(business?.sage_business_id);
  const sageBusinessName = text(business?.sage_business_name);
  if (!sageBusinessId) return reply(409, { ok: false, code: "active_sage_business_missing", sage_write_made: false });

  const { data: mappings, error: mappingError } = await supabaseAdmin
    .from("sage_mapping_settings")
    .select("mapping_code, sage_external_id, is_active")
    .in("mapping_code", ["SUPPLIER_GOODS_AP_LEDGER", "SUPPLIER_GOODS_AP_TAX_RATE"])
    .eq("is_active", true);
  if (mappingError) return reply(500, { ok: false, code: "mapping_read_failed", message: mappingError.message });
  const ledgerId = text((mappings ?? []).find((row: Row) => row.mapping_code === "SUPPLIER_GOODS_AP_LEDGER")?.sage_external_id);
  const taxRateId = text((mappings ?? []).find((row: Row) => row.mapping_code === "SUPPLIER_GOODS_AP_TAX_RATE")?.sage_external_id);
  if (!ledgerId || !taxRateId) return reply(409, { ok: false, code: "supplier_goods_ap_mapping_missing", sage_write_made: false });

  const accessToken = decryptSecret(text(token.access_token_encrypted));
  const common = { apiBaseUrl: config.apiBaseUrl, accessToken, sageBusinessId };

  const contacts = await sageCall({
    ...common,
    method: "GET",
    path: `/contacts?search=${encodeURIComponent(TEST_CONTACT_REFERENCE)}&items_per_page=100`,
  });
  if (!contacts.response.ok) {
    return reply(502, {
      ok: false,
      code: "test_contact_search_failed",
      http_status: contacts.response.status,
      sage_request_id: contacts.requestId,
      sage_write_made: false,
    });
  }
  const items = Array.isArray((contacts.raw as Row)?.$items) ? (contacts.raw as Row).$items as Row[] : [];
  const exact = items.filter((row) => text(row.name) === TEST_CONTACT_NAME && text(row.reference) === TEST_CONTACT_REFERENCE);
  if (exact.length !== 1) {
    return reply(409, {
      ok: false,
      code: exact.length === 0 ? "dedicated_test_contact_missing" : "dedicated_test_contact_not_unique",
      required_contact: { name: TEST_CONTACT_NAME, reference: TEST_CONTACT_REFERENCE, type: "VENDOR" },
      exact_match_count: exact.length,
      sage_write_made: false,
    });
  }
  const contact = exact[0];
  const contactTypes = Array.isArray(contact.contact_types) ? contact.contact_types as Row[] : [];
  if (!contactTypes.some((row) => text(row.id) === "VENDOR")) {
    return reply(409, { ok: false, code: "dedicated_test_contact_is_not_vendor", sage_write_made: false });
  }

  const reference = `GCB-ZERO-${Date.now()}`;
  const date = new Date().toISOString().slice(0, 10);
  const body = {
    purchase_invoice: {
      contact_id: text(contact.id),
      date,
      due_date: date,
      reference,
      notes: "Disposable Goodcashback Sage zero-line runtime proof; delete immediately after verification.",
      currency_code: "GBP",
      invoice_lines: [
        { description: CONTROL_DESCRIPTION, ledger_account_id: ledgerId, tax_rate_id: taxRateId, quantity: 1, unit_price: 1 },
        {
          description: ZERO_DESCRIPTION,
          ledger_account_id: ledgerId,
          tax_rate_id: taxRateId,
          quantity: 1,
          unit_price: 0,
          tax_amount: 0,
          currency_tax_amount: 0,
        },
      ],
    },
  };

  let invoiceId = "";
  let createStatus: number | null = null;
  let createRequestId: string | null = null;
  let getStatus: number | null = null;
  let getRequestId: string | null = null;
  let deleteStatus: number | null = null;
  let deleteRequestId: string | null = null;
  let zeroLine: Row | null = null;
  let controlLine: Row | null = null;
  let createRaw: unknown = null;
  let getRaw: unknown = null;

  try {
    const created = await sageCall({ ...common, method: "POST", path: "/purchase_invoices", body });
    createStatus = created.response.status;
    createRequestId = created.requestId;
    createRaw = created.raw;
    invoiceId = objectId(created.raw);
    if (createStatus !== 201 || !invoiceId) {
      return reply(200, {
        ok: false,
        code: "sage_zero_line_create_rejected",
        test_reference: reference,
        create_http_status: createStatus,
        create_sage_request_id: createRequestId,
        sage_write_made: Boolean(invoiceId),
        response: createRaw,
      });
    }

    const fetched = await sageCall({ ...common, method: "GET", path: `/purchase_invoices/${encodeURIComponent(invoiceId)}` });
    getStatus = fetched.response.status;
    getRequestId = fetched.requestId;
    getRaw = fetched.raw;
    if (fetched.response.ok) {
      zeroLine = findDescription(fetched.raw, ZERO_DESCRIPTION);
      controlLine = findDescription(fetched.raw, CONTROL_DESCRIPTION);
    }
  } finally {
    if (invoiceId) {
      const deleted = await sageCall({ ...common, method: "DELETE", path: `/purchase_invoices/${encodeURIComponent(invoiceId)}` });
      deleteStatus = deleted.response.status;
      deleteRequestId = deleted.requestId;
    }
  }

  const zeroUnitPrice = Number(zeroLine?.unit_price);
  const zeroTaxAmount = Number(zeroLine?.tax_amount ?? zeroLine?.currency_tax_amount ?? 0);
  const proven = createStatus === 201
    && getStatus === 200
    && Boolean(controlLine)
    && Boolean(zeroLine)
    && Number.isFinite(zeroUnitPrice)
    && zeroUnitPrice === 0
    && Number.isFinite(zeroTaxAmount)
    && zeroTaxAmount === 0
    && deleteStatus === 204;

  return reply(200, {
    ok: proven,
    code: proven ? "sage_zero_line_runtime_proven" : "sage_zero_line_runtime_not_proven",
    business_name: sageBusinessName,
    test_reference: reference,
    create_http_status: createStatus,
    get_http_status: getStatus,
    delete_http_status: deleteStatus,
    create_sage_request_id: createRequestId,
    get_sage_request_id: getRequestId,
    delete_sage_request_id: deleteRequestId,
    zero_line_retained: Boolean(zeroLine),
    zero_line_unit_price: Number.isFinite(zeroUnitPrice) ? zeroUnitPrice : null,
    zero_line_tax_amount: Number.isFinite(zeroTaxAmount) ? zeroTaxAmount : null,
    control_line_retained: Boolean(controlLine),
    cleanup_complete: deleteStatus === 204,
    note: "Probe performed no database writes and did not use the Goodcashback posting pipeline.",
    ...(proven ? {} : { fetched_response: getRaw }),
  });
}
