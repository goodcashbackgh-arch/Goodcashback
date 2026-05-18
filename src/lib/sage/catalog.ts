import "server-only";

import { createClient } from "@/utils/supabase/server";
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

type Row = Record<string, unknown>;

type TokenRow = {
  id: string;
  connection_id: string;
  access_token_encrypted: string;
  refresh_token_encrypted: string;
  expires_at: string;
};

type ConnectionRow = {
  id: string;
  connection_ref: string;
  environment: string;
  status: string;
};

type BusinessRow = {
  id: string;
  sage_business_id: string;
  sage_business_name: string;
  business_country_code: string | null;
  business_currency_code: string | null;
  is_primary: boolean;
};

export type SageCatalogItem = {
  id: string;
  display: string;
  reference: string;
  code: string;
  type: string;
  active: string;
  raw_preview: Row;
};

export type SageCatalogCategory = {
  key: string;
  label: string;
  endpoint: string;
  ok: boolean;
  http_status: number | null;
  count: number;
  items: SageCatalogItem[];
  error: string | null;
};

export type SageCatalogDiscovery = {
  ok: boolean;
  error: string | null;
  connection: ConnectionRow | null;
  business: BusinessRow | null;
  token_refreshed: boolean;
  categories: SageCatalogCategory[];
  ar_requirements: string[];
  ap_requirements: string[];
};

const CATALOG_ENDPOINTS = [
  { key: "contacts", label: "Contacts: customers and suppliers", endpoint: "/contacts?items_per_page=100" },
  { key: "ledger_accounts", label: "Ledger / nominal accounts", endpoint: "/ledger_accounts?items_per_page=100" },
  { key: "tax_rates", label: "VAT / tax rates", endpoint: "/tax_rates?items_per_page=100" },
  { key: "bank_accounts", label: "Bank accounts", endpoint: "/bank_accounts?items_per_page=100" },
  { key: "currencies", label: "Currencies", endpoint: "/currencies?items_per_page=100" },
] as const;

function text(value: unknown) {
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  if (typeof value === "boolean") return value ? "true" : "false";
  if (Array.isArray(value)) return value.map(text).filter(Boolean).join(", ");
  return "";
}

function asObject(value: unknown): Row {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  return value as Row;
}

function unwrapItem(value: unknown) {
  const row = asObject(value);
  return asObject(
    row.contact ??
    row.ledger_account ??
    row.tax_rate ??
    row.bank_account ??
    row.currency ??
    row.payment_method ??
    row.business ??
    row,
  );
}

function collection(raw: unknown) {
  const root = asObject(raw);
  const candidates = [
    root.$items,
    root.items,
    root.data,
    root.contacts,
    root.ledger_accounts,
    root.tax_rates,
    root.bank_accounts,
    root.currencies,
    root.payment_methods,
    raw,
  ];
  const array = candidates.find(Array.isArray) as unknown[] | undefined;
  return (array ?? []).map(unwrapItem);
}

function itemDisplay(row: Row) {
  return text(row.displayed_as) || text(row.name) || text(row.reference) || text(row.id) || "—";
}

function normalizeItems(raw: unknown) {
  return collection(raw).map((row) => ({
    id: text(row.id ?? row.$uuid),
    display: itemDisplay(row),
    reference: text(row.reference ?? row.contact_reference ?? row.code),
    code: text(row.nominal_code ?? row.ledger_account_number ?? row.currency_id ?? row.currency_code),
    type: text(row.contact_type_ids ?? row.contact_type_id ?? row.type ?? row.ledger_account_group ?? row.category ?? row.bank_account_type ?? row.tax_rate_type),
    active: text(row.active ?? row.status ?? row.visible),
    raw_preview: Object.fromEntries(Object.entries(row).slice(0, 12)) as Row,
  }));
}

function categoryHints(category: SageCatalogCategory) {
  const rows = category.items;
  const lowered = (value: string) => value.toLowerCase();
  if (category.key === "tax_rates") {
    return rows.filter((row) => /zero|gb_zero|0%|export|exempt|no vat|tax exempt/i.test(`${row.id} ${row.display} ${row.reference} ${row.type}`));
  }
  if (category.key === "ledger_accounts") {
    return rows.filter((row) => /sales|product|income|4000|purchase|cost|freight|shipping|delivery|expense|5000/i.test(lowered(`${row.display} ${row.reference} ${row.code} ${row.type}`)));
  }
  if (category.key === "bank_accounts") {
    return rows.filter((row) => /bank|cash|current|clearing|1200|2550/i.test(lowered(`${row.display} ${row.reference} ${row.code} ${row.type}`)));
  }
  if (category.key === "contacts") {
    return rows.filter((row) => /customer|supplier|client|vendor|day3|jobyco|goods to ship/i.test(lowered(`${row.display} ${row.reference} ${row.type}`)));
  }
  return [];
}

export function sageCatalogHints(category: SageCatalogCategory) {
  return categoryHints(category).slice(0, 12);
}

async function requireAccountingStaffId() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) throw new Error("Login required.");

  const { data: allowed, error: accessError } = await supabase.rpc("internal_has_accounting_admin_access_v1");
  if (accessError) throw new Error(accessError.message);
  if (!allowed) throw new Error("Accounting admin access required.");

  const { data: staff, error: staffError } = await supabaseAdmin
    .from("staff")
    .select("id")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();
  if (staffError) throw new Error(staffError.message);
  if (!staff?.id) throw new Error("Active staff record required.");
  return String(staff.id);
}

async function activeBusiness(connectionId: string) {
  const primary = await supabaseAdmin
    .from("sage_businesses")
    .select("id, sage_business_id, sage_business_name, business_country_code, business_currency_code, is_primary")
    .eq("connection_id", connectionId)
    .eq("status", "active")
    .eq("is_primary", true)
    .maybeSingle();

  if (primary.data) return primary.data as BusinessRow;

  const first = await supabaseAdmin
    .from("sage_businesses")
    .select("id, sage_business_id, sage_business_name, business_country_code, business_currency_code, is_primary")
    .eq("connection_id", connectionId)
    .eq("status", "active")
    .order("created_at", { ascending: true })
    .limit(1)
    .maybeSingle();

  return (first.data ?? null) as BusinessRow | null;
}

async function getSageContext(staffId: string) {
  const config = assertSageOAuthConfigured();
  const { data: token, error: tokenError } = await supabaseAdmin
    .from("sage_oauth_tokens")
    .select("id, connection_id, access_token_encrypted, refresh_token_encrypted, expires_at")
    .eq("status", "active")
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (tokenError) throw new Error(tokenError.message);
  if (!token) throw new Error("No active Sage token found. Reconnect Sage first.");

  const tokenRow = token as TokenRow;
  const { data: connection, error: connectionError } = await supabaseAdmin
    .from("sage_connections")
    .select("id, connection_ref, environment, status")
    .eq("id", tokenRow.connection_id)
    .maybeSingle();

  if (connectionError) throw new Error(connectionError.message);
  if (!connection || connection.status === "disabled") throw new Error("Sage connection is disabled or missing.");

  let accessToken = "";
  let refreshed = false;

  if (tokenRefreshRequired(tokenRow.expires_at)) {
    const refreshToken = decryptSecret(tokenRow.refresh_token_encrypted);
    const { data: requestLog } = await supabaseAdmin.from("sage_api_request_log").insert({
      connection_id: tokenRow.connection_id,
      connection_event_type: "token_refresh",
      request_kind: "token_refresh",
      http_method: "POST",
      endpoint_path: "/token",
      request_payload_redacted: { grant_type: "refresh_token", purpose: "catalog_discovery" },
      created_by_staff_id: staffId,
    }).select("id").single();

    const result = await exchangeSageToken({
      tokenUrl: config.tokenUrl,
      clientId: config.clientId,
      clientSecret: config.clientSecret,
      grantType: "refresh_token",
      refreshToken,
    });

    if (requestLog?.id) {
      await supabaseAdmin.from("sage_api_response_log").insert({
        request_log_id: requestLog.id,
        connection_id: tokenRow.connection_id,
        http_status: result.response.status,
        success_yn: result.response.ok,
        response_payload_redacted: redactedTokenPayload(result.raw),
        error_code: result.response.ok ? null : String((result.raw as Row).error ?? "token_refresh_failed"),
        error_message: result.response.ok ? null : String((result.raw as Row).error_description ?? (result.raw as Row).message ?? "Sage token refresh failed."),
      });
    }

    if (!result.response.ok || !result.raw.access_token || !result.raw.refresh_token) {
      await supabaseAdmin.from("sage_connections").update({
        status: "refresh_failed",
        last_error_code: "token_refresh_failed",
        last_error_message: JSON.stringify(redactedTokenPayload(result.raw)),
        updated_at: new Date().toISOString(),
      }).eq("id", tokenRow.connection_id);
      throw new Error(`Sage token refresh failed (${result.response.status}).`);
    }

    await supabaseAdmin.from("sage_oauth_tokens").update({
      status: "superseded",
      superseded_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    }).eq("id", tokenRow.id);

    const expiresAt = tokenExpiresAt(result.raw.expires_in);
    await supabaseAdmin.from("sage_oauth_tokens").insert({
      connection_id: tokenRow.connection_id,
      access_token_encrypted: encryptSecret(result.raw.access_token),
      refresh_token_encrypted: encryptSecret(result.raw.refresh_token),
      token_type: result.raw.token_type || "Bearer",
      expires_at: expiresAt,
      scopes: scopesFromToken(result.raw, config.scopes),
      status: "active",
      encryption_key_ref: "SAGE_TOKEN_ENCRYPTION_KEY:v1",
      issued_at: new Date().toISOString(),
      last_refresh_at: new Date().toISOString(),
    });

    await supabaseAdmin.from("sage_connections").update({
      status: "connected",
      last_refresh_at: new Date().toISOString(),
      last_error_code: null,
      last_error_message: null,
      updated_at: new Date().toISOString(),
    }).eq("id", tokenRow.connection_id);

    accessToken = result.raw.access_token;
    refreshed = true;
  } else {
    accessToken = decryptSecret(tokenRow.access_token_encrypted);
  }

  const business = await activeBusiness(tokenRow.connection_id);
  return {
    config,
    accessToken,
    connection: connection as ConnectionRow,
    business,
    refreshed,
  };
}

async function getCategory(params: {
  staffId: string;
  connectionId: string;
  businessRowId: string | null;
  baseUrl: string;
  accessToken: string;
  category: typeof CATALOG_ENDPOINTS[number];
}) {
  const started = Date.now();
  const { data: requestLog } = await supabaseAdmin.from("sage_api_request_log").insert({
    connection_id: params.connectionId,
    sage_business_row_id: params.businessRowId,
    connection_event_type: "test_connection",
    request_kind: "test_connection",
    http_method: "GET",
    endpoint_path: params.category.endpoint.split("?")[0],
    request_payload_redacted: { query: params.category.endpoint.includes("?") ? params.category.endpoint.split("?")[1] : "" },
    created_by_staff_id: params.staffId,
  }).select("id").single();

  const url = `${params.baseUrl.replace(/\/$/, "")}${params.category.endpoint}`;
  let response: Response | null = null;
  let raw: unknown = null;
  let errorMessage: string | null = null;

  try {
    response = await fetch(url, {
      method: "GET",
      headers: {
        Accept: "application/json",
        Authorization: `Bearer ${params.accessToken}`,
      },
      cache: "no-store",
    });
    raw = await response.json().catch(async () => ({ non_json_body: await response?.text().catch(() => null) }));
    if (!response.ok) errorMessage = JSON.stringify(raw).slice(0, 700);
  } catch (error) {
    errorMessage = error instanceof Error ? error.message : "Sage catalog request failed.";
  }

  const items = response?.ok ? normalizeItems(raw) : [];

  if (requestLog?.id) {
    await supabaseAdmin.from("sage_api_response_log").insert({
      request_log_id: requestLog.id,
      connection_id: params.connectionId,
      sage_business_row_id: params.businessRowId,
      http_status: response?.status ?? null,
      success_yn: Boolean(response?.ok),
      response_payload_redacted: { category: params.category.key, count: items.length },
      error_code: response?.ok ? null : "catalog_discovery_failed",
      error_message: response?.ok ? null : errorMessage,
      duration_ms: Date.now() - started,
    });
  }

  return {
    key: params.category.key,
    label: params.category.label,
    endpoint: params.category.endpoint,
    ok: Boolean(response?.ok),
    http_status: response?.status ?? null,
    count: items.length,
    items: items.slice(0, 60),
    error: response?.ok ? null : errorMessage,
  } satisfies SageCatalogCategory;
}

export async function discoverSageCatalog(): Promise<SageCatalogDiscovery> {
  try {
    const staffId = await requireAccountingStaffId();
    const context = await getSageContext(staffId);
    const categories: SageCatalogCategory[] = [];

    for (const category of CATALOG_ENDPOINTS) {
      categories.push(await getCategory({
        staffId,
        connectionId: context.connection.id,
        businessRowId: context.business?.id ?? null,
        baseUrl: context.config.apiBaseUrl,
        accessToken: context.accessToken,
        category,
      }));
    }

    return {
      ok: true,
      error: null,
      connection: context.connection,
      business: context.business,
      token_refreshed: context.refreshed,
      categories,
      ar_requirements: [
        "Sage customer contact id for the importer/customer",
        "Sales income ledger/nominal account id",
        "VAT/tax rate id for the customer sales invoice line",
        "Currency and invoice reference/idempotency rule",
        "Later: receipt/bank account id for money allocation",
      ],
      ap_requirements: [
        "Sage supplier contact id for the shipper/AP counterparty",
        "AP expense/COGS/freight ledger/nominal account id",
        "VAT/tax rate id for AP line treatment",
        "Supplier invoice reference/idempotency rule",
        "Later: bank/control account id for payment settlement",
      ],
    };
  } catch (error) {
    return {
      ok: false,
      error: error instanceof Error ? error.message : "Sage catalog discovery failed.",
      connection: null,
      business: null,
      token_refreshed: false,
      categories: [],
      ar_requirements: [],
      ap_requirements: [],
    };
  }
}
