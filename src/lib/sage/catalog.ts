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

type CatalogEndpoint = {
  key: string;
  label: string;
  endpoint: string;
  optional?: boolean;
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
  { key: "currencies", label: "Currencies (optional; some Sage businesses block this endpoint)", endpoint: "/currencies?items_per_page=100", optional: true },
] satisfies readonly CatalogEndpoint[];

const MAX_CATALOG_PAGES = 5;
const MAX_DISPLAY_ROWS = 80;

function text(value: unknown): string {
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

function unwrapItem(value: unknown): Row {
  const row = asObject(value);
  return asObject(row.contact ?? row.ledger_account ?? row.tax_rate ?? row.bank_account ?? row.currency ?? row.payment_method ?? row.business ?? row);
}

function collection(raw: unknown): Row[] {
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

function nextPath(raw: unknown): string | null {
  const root = asObject(raw);
  const next = text(root.$next ?? root.next ?? root.next_page ?? root.$next_page);
  return next || null;
}

function absoluteSageUrl(baseUrl: string, pathOrUrl: string): string {
  if (/^https?:\/\//i.test(pathOrUrl)) return pathOrUrl;
  const base = baseUrl.replace(/\/$/, "");
  const path = pathOrUrl.startsWith("/") ? pathOrUrl : `/${pathOrUrl}`;
  return `${base}${path}`;
}

function itemDisplay(row: Row): string {
  return text(row.displayed_as) || text(row.name) || text(row.reference) || text(row.id) || "—";
}

function normalizeItems(raw: unknown): SageCatalogItem[] {
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

function dedupeItems(items: SageCatalogItem[]): SageCatalogItem[] {
  const seen = new Set<string>();
  const out: SageCatalogItem[] = [];
  for (const item of items) {
    const key = item.id || `${item.display}|${item.reference}|${item.code}`;
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(item);
  }
  return out;
}

function categoryHints(category: SageCatalogCategory): SageCatalogItem[] {
  const rows = category.items;
  const lowered = (value: string) => value.toLowerCase();
  if (category.key === "tax_rates") {
    return rows.filter((row) => /zero|gb_zero|0%|export|exempt|no vat|tax exempt/i.test(`${row.id} ${row.display} ${row.reference} ${row.type}`));
  }
  if (category.key === "ledger_accounts") {
    return rows.filter((row) => /sales|product|income|4000|purchase|cost|freight|shipping|delivery|expense|5000|5030|5100|4910/i.test(lowered(`${row.display} ${row.reference} ${row.code} ${row.type}`)));
  }
  if (category.key === "bank_accounts") {
    return rows.filter((row) => /bank|cash|current|clearing|1200|2550/i.test(lowered(`${row.display} ${row.reference} ${row.code} ${row.type}`)));
  }
  if (category.key === "contacts") {
    return rows.filter((row) => /customer|supplier|client|vendor|day3|jobyco|goods to ship/i.test(lowered(`${row.display} ${row.reference} ${row.type}`)));
  }
  return [];
}

export function sageCatalogHints(category: SageCatalogCategory): SageCatalogItem[] {
  return categoryHints(category).slice(0, 12);
}

async function requireAccountingStaffId(): Promise<string> {
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

async function activeBusiness(connectionId: string): Promise<BusinessRow | null> {
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

async function getSageContext(staffId: string): Promise<{
  config: ReturnType<typeof assertSageOAuthConfigured>;
  accessToken: string;
  connection: ConnectionRow;
  business: BusinessRow | null;
  refreshed: boolean;
}> {
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
  return { config, accessToken, connection: connection as ConnectionRow, business, refreshed };
}

async function fetchPagedCatalog(params: {
  baseUrl: string;
  accessToken: string;
  endpoint: string;
}): Promise<{
  ok: boolean;
  status: number | null;
  items: SageCatalogItem[];
  error: string | null;
  pages: number;
}> {
  const items: SageCatalogItem[] = [];
  let url: string | null = absoluteSageUrl(params.baseUrl, params.endpoint);
  let status: number | null = null;
  let error: string | null = null;
  let pages = 0;

  while (url && pages < MAX_CATALOG_PAGES) {
    pages += 1;
    let response: Response;
    let raw: unknown;
    try {
      response = await fetch(url, {
        method: "GET",
        headers: { Accept: "application/json", Authorization: `Bearer ${params.accessToken}` },
        cache: "no-store",
      });
      status = response.status;
      raw = await response.json().catch(async () => ({ non_json_body: await response.text().catch(() => null) }));
    } catch (fetchError) {
      error = fetchError instanceof Error ? fetchError.message : "Sage catalog request failed.";
      return { ok: false, status, items: dedupeItems(items), error, pages };
    }

    if (!response.ok) {
      error = JSON.stringify(raw).slice(0, 700);
      return { ok: false, status, items: dedupeItems(items), error, pages };
    }

    items.push(...normalizeItems(raw));
    const next = nextPath(raw);
    url = next ? absoluteSageUrl(params.baseUrl, next) : null;
  }

  return { ok: true, status, items: dedupeItems(items), error, pages };
}

async function getCategory(params: {
  staffId: string;
  connectionId: string;
  businessRowId: string | null;
  baseUrl: string;
  accessToken: string;
  category: CatalogEndpoint;
}): Promise<SageCatalogCategory> {
  const started = Date.now();
  const { data: requestLog } = await supabaseAdmin.from("sage_api_request_log").insert({
    connection_id: params.connectionId,
    sage_business_row_id: params.businessRowId,
    connection_event_type: "test_connection",
    request_kind: "test_connection",
    http_method: "GET",
    endpoint_path: params.category.endpoint.split("?")[0],
    request_payload_redacted: { query: params.category.endpoint.includes("?") ? params.category.endpoint.split("?")[1] : "", max_pages: MAX_CATALOG_PAGES },
    created_by_staff_id: params.staffId,
  }).select("id").single();

  const result = await fetchPagedCatalog({
    baseUrl: params.baseUrl,
    accessToken: params.accessToken,
    endpoint: params.category.endpoint,
  });

  const optionalFailure = Boolean(params.category.optional && !result.ok);
  const errorMessage = optionalFailure
    ? `${result.error || "Endpoint restricted"} — optional for first GBP AR/AP posting; use the connected business currency instead.`
    : result.error;

  if (requestLog?.id) {
    await supabaseAdmin.from("sage_api_response_log").insert({
      request_log_id: requestLog.id,
      connection_id: params.connectionId,
      sage_business_row_id: params.businessRowId,
      http_status: result.status,
      success_yn: result.ok || optionalFailure,
      response_payload_redacted: { category: params.category.key, count: result.items.length, pages: result.pages, optional_failure: optionalFailure },
      error_code: result.ok || optionalFailure ? null : "catalog_discovery_failed",
      error_message: result.ok || optionalFailure ? null : errorMessage,
      duration_ms: Date.now() - started,
    });
  }

  return {
    key: params.category.key,
    label: params.category.label,
    endpoint: params.category.endpoint,
    ok: result.ok,
    http_status: result.status,
    count: result.items.length,
    items: result.items.slice(0, MAX_DISPLAY_ROWS),
    error: errorMessage,
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
        "VAT/tax rate id for the customer sales invoice line — not the VAT control ledger",
        `Currency from connected business record${context.business?.business_currency_code ? ` (${context.business.business_currency_code})` : ""}; /currencies is optional`,
        "Later: receipt/bank account id for money allocation",
      ],
      ap_requirements: [
        "Sage supplier contact id for supplier goods AP and shipper AP counterparties",
        "Goods AP/COGS and freight/delivery ledger account ids",
        "VAT/tax rate id for AP line treatment — not the VAT control ledger",
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
