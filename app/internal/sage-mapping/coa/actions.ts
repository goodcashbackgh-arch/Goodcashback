"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
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
import { parseCatalogItemValue, writeSavedCatalogCategory, writeSavedCatalogItems } from "@/lib/accounting/catalog-cache";

type Row = Record<string, unknown>;
type LedgerItem = { id: string; display: string; reference: string; code: string; type: string; active: string; raw_preview: Row };

function text(value: unknown): string {
  if (typeof value === "string") return value.trim();
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  if (typeof value === "boolean") return value ? "true" : "false";
  if (Array.isArray(value)) return value.map(text).filter(Boolean).join(", ");
  return "";
}

function asObject(value: unknown): Row {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Row : {};
}

function unwrapLedger(value: unknown): Row {
  const row = asObject(value);
  return asObject(row.ledger_account ?? row);
}

function collection(raw: unknown): Row[] {
  const root = asObject(raw);
  const candidates = [root.$items, root.items, root.data, root.ledger_accounts, raw];
  const array = candidates.find(Array.isArray) as unknown[] | undefined;
  return (array ?? []).map(unwrapLedger);
}

function nextPath(raw: unknown): string | null {
  const root = asObject(raw);
  return text(root.$next ?? root.next ?? root.next_page ?? root.$next_page) || null;
}

function absoluteSageUrl(baseUrl: string, pathOrUrl: string): string {
  if (/^https?:\/\//i.test(pathOrUrl)) return pathOrUrl;
  const base = baseUrl.replace(/\/$/, "");
  const path = pathOrUrl.startsWith("/") ? pathOrUrl : `/${pathOrUrl}`;
  return `${base}${path}`;
}

function normaliseLedgerAccounts(raw: unknown): LedgerItem[] {
  const seen = new Set<string>();
  const rows: LedgerItem[] = [];
  for (const row of collection(raw)) {
    const item = {
      id: text(row.id ?? row.$uuid),
      display: text(row.displayed_as) || text(row.name) || text(row.reference) || text(row.id) || "—",
      reference: text(row.reference ?? row.code ?? row.ledger_account_number),
      code: text(row.nominal_code ?? row.ledger_account_number ?? row.code),
      type: text(row.ledger_account_group ?? row.category ?? row.type),
      active: text(row.active ?? row.status ?? row.visible),
      raw_preview: Object.fromEntries(Object.entries(row).slice(0, 18)) as Row,
    };
    if (!item.id || seen.has(item.id)) continue;
    seen.add(item.id);
    rows.push(item);
  }
  return rows;
}

async function requireAccountingStaff() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: allowed, error: accessError } = await supabase.rpc("internal_has_accounting_admin_access_v1");
  if (accessError || !allowed) redirect(`/internal/sage-mapping/coa?error=${encodeURIComponent(accessError?.message || "Accounting admin access required")}`);

  const { data: staff, error: staffError } = await supabase
    .from("staff")
    .select("id")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (staffError || !staff?.id) redirect("/auth/check");
  return { supabase, staffId: String(staff.id) };
}

async function activeSageContext() {
  const config = assertSageOAuthConfigured();
  const { data: tokenRaw, error: tokenError } = await supabaseAdmin
    .from("sage_oauth_tokens")
    .select("id, connection_id, access_token_encrypted, refresh_token_encrypted, expires_at, sage_business_row_id")
    .eq("status", "active")
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (tokenError) throw new Error(tokenError.message);
  const token = tokenRaw as Row | null;
  if (!token) throw new Error("No active Sage token found. Reconnect Sage first.");

  const { data: connection, error: connectionError } = await supabaseAdmin
    .from("sage_connections")
    .select("id, status")
    .eq("id", text(token.connection_id))
    .maybeSingle();
  if (connectionError) throw new Error(connectionError.message);
  if (!connection || String((connection as Row).status) === "disabled") throw new Error("Sage connection is disabled or missing.");

  let accessToken = decryptSecret(text(token.access_token_encrypted));

  if (tokenRefreshRequired(text(token.expires_at))) {
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
      }).eq("id", text(token.connection_id));
      throw new Error(`Sage token refresh failed (${refreshed.response.status}).`);
    }

    await supabaseAdmin.from("sage_oauth_tokens").update({
      status: "superseded",
      superseded_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    }).eq("id", text(token.id));

    await supabaseAdmin.from("sage_oauth_tokens").insert({
      connection_id: text(token.connection_id),
      sage_business_row_id: text(token.sage_business_row_id) || null,
      access_token_encrypted: encryptSecret(refreshed.raw.access_token),
      refresh_token_encrypted: encryptSecret(refreshed.raw.refresh_token),
      token_type: refreshed.raw.token_type || "Bearer",
      expires_at: tokenExpiresAt(refreshed.raw.expires_in),
      scopes: scopesFromToken(refreshed.raw, config.scopes),
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
    }).eq("id", text(token.connection_id));

    accessToken = refreshed.raw.access_token;
  }

  let businessQuery = supabaseAdmin
    .from("sage_businesses")
    .select("id, sage_business_id, sage_business_name")
    .eq("connection_id", text(token.connection_id))
    .eq("status", "active")
    .order("is_primary", { ascending: false })
    .limit(1);

  const tokenBusinessRowId = text(token.sage_business_row_id);
  if (tokenBusinessRowId) businessQuery = businessQuery.eq("id", tokenBusinessRowId);
  const { data: businessRows, error: businessError } = await businessQuery;
  if (businessError) throw new Error(businessError.message);
  const business = (businessRows?.[0] ?? null) as Row | null;

  return {
    config,
    accessToken,
    connectionId: text(token.connection_id),
    businessRowId: text(business?.id) || null,
    businessId: text(business?.sage_business_id) || null,
  };
}

async function fetchAllLedgerAccounts(baseUrl: string, accessToken: string, businessId: string | null) {
  const all: LedgerItem[] = [];
  let url: string | null = absoluteSageUrl(baseUrl, "/ledger_accounts?items_per_page=100");
  let pages = 0;
  let lastStatus: number | null = null;

  while (url && pages < 20) {
    pages += 1;
    const response = await fetch(url, {
      method: "GET",
      headers: {
        Accept: "application/json",
        Authorization: `Bearer ${accessToken}`,
        ...(businessId ? { "X-Business": businessId } : {}),
      },
      cache: "no-store",
    });
    lastStatus = response.status;
    const raw = await response.json().catch(async () => ({ non_json_body: await response.text().catch(() => null) }));
    if (!response.ok) throw new Error(JSON.stringify(raw).slice(0, 700));
    all.push(...normaliseLedgerAccounts(raw));
    const next = nextPath(raw);
    url = next ? absoluteSageUrl(baseUrl, next) : null;
  }

  const seen = new Set<string>();
  const deduped = all.filter((item) => {
    if (seen.has(item.id)) return false;
    seen.add(item.id);
    return true;
  });

  return { items: deduped, pages, status: lastStatus };
}

function coaRedirect(message: string, kind: "success" | "error") {
  redirect(`/internal/sage-mapping/coa?${kind}=${encodeURIComponent(message)}`);
}

export async function syncFullSageLedgerAccountsAction() {
  const { staffId } = await requireAccountingStaff();
  let successMessage = "";

  try {
    const context = await activeSageContext();
    const result = await fetchAllLedgerAccounts(context.config.apiBaseUrl, context.accessToken, context.businessId);

    await writeSavedCatalogCategory({
      staffId,
      connectionId: context.connectionId,
      businessRowId: context.businessRowId,
      businessId: context.businessId,
      categoryKey: "ledger_accounts",
      categoryLabel: "Ledger / nominal accounts",
      endpointPath: "/ledger_accounts?items_per_page=100",
      httpStatus: result.status,
      ok: true,
      rowCount: result.items.length,
      lastError: null,
    });

    await writeSavedCatalogItems({
      staffId,
      connectionId: context.connectionId,
      businessRowId: context.businessRowId,
      businessId: context.businessId,
      categoryKey: "ledger_accounts",
      items: result.items,
    });

    revalidatePath("/internal/sage-mapping");
    revalidatePath("/internal/sage-mapping/coa");
    successMessage = `Full Sage ledger sync saved ${result.items.length} account(s) from ${result.pages} page(s).`;
  } catch (error) {
    coaRedirect(error instanceof Error ? error.message : "Full Sage ledger sync failed.", "error");
  }

  coaRedirect(successMessage || "Full Sage ledger sync completed.", "success");
}

export async function saveCoaSageMappingAction(formData: FormData) {
  const mappingCode = String(formData.get("mapping_code") ?? "").trim();
  const picked = parseCatalogItemValue(formData.get("mapping_pick"));
  const manualSageExternalId = String(formData.get("sage_external_id") ?? "").trim();
  const manualSageDisplayName = String(formData.get("sage_display_name") ?? "").trim();
  const sageExternalId = picked?.id || manualSageExternalId;
  const sageDisplayName = picked?.display || manualSageDisplayName;
  const notes = String(formData.get("notes") ?? "").trim();

  if (!mappingCode) coaRedirect("Missing mapping code.", "error");
  if (!sageExternalId) coaRedirect("Choose a Sage ledger account or enter a manual Sage ID.", "error");

  const { supabase } = await requireAccountingStaff();
  const { error } = await (supabase as any).rpc("internal_upsert_sage_mapping_v1", {
    p_mapping_code: mappingCode,
    p_sage_external_id: sageExternalId,
    p_sage_display_name: sageDisplayName || null,
    p_notes: notes || (picked?.id ? "Saved from Sage CoA workbench." : "Manual Sage ID saved from Sage CoA workbench."),
  });

  if (error) coaRedirect(error.message, "error");

  revalidatePath("/internal/sage-mapping");
  revalidatePath("/internal/sage-mapping/coa");
  coaRedirect("Sage mapping saved from CoA workbench.", "success");
}
