"use server";

import { revalidatePath } from "next/cache";
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

type AnyRow = Record<string, unknown>;

type SageTokenRow = {
  id: string;
  connection_id: string;
  access_token_encrypted: string;
  refresh_token_encrypted: string;
  expires_at: string;
  sage_business_row_id?: string | null;
};

type SageReadContext = {
  apiBaseUrl: string;
  connectionId: string;
  accessToken: string;
};

const TAX_FIELDS = ["tax_amount", "total_tax_amount", "tax_total", "total_tax", "vat_amount", "total_vat_amount", "base_currency_tax_amount"];
const NET_FIELDS = ["net_amount", "total_net_amount", "net_total", "total_net", "subtotal", "sub_total", "goods_value", "base_currency_net_amount"];
const GROSS_FIELDS = ["total_amount", "gross_amount", "total", "amount", "amount_gbp", "value", "base_currency_total_amount"];
const LINE_ARRAY_FIELDS = ["line_items", "invoice_lines", "credit_note_lines", "lines", "items", "sales_invoice_lines", "purchase_invoice_lines", "sales_credit_note_lines", "purchase_credit_note_lines"];

function text(value: unknown): string {
  if (typeof value === "string") return value.trim();
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  if (typeof value === "boolean") return value ? "true" : "false";
  if (value && typeof value === "object" && !Array.isArray(value)) {
    const row = value as AnyRow;
    return text(row.displayed_as ?? row.name ?? row.description ?? row.id ?? row.value ?? "");
  }
  return "";
}

function object(value: unknown): AnyRow {
  return value && typeof value === "object" && !Array.isArray(value) ? value as AnyRow : {};
}

function array(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function parseMoneyText(value: string): number {
  const cleaned = value.replace(/,/g, "").replace(/[^0-9.\-]/g, "");
  if (!cleaned || cleaned === "-" || cleaned === ".") return 0;
  const parsed = Number(cleaned);
  return Number.isFinite(parsed) ? parsed : 0;
}

function num(value: unknown): number {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim()) return parseMoneyText(value);
  if (value && typeof value === "object" && !Array.isArray(value)) {
    const row = value as AnyRow;
    for (const key of ["amount", "value", "total", "net_amount", "gross_amount", "displayed_as"]) {
      const found = row[key];
      const parsed = num(found);
      if (parsed !== 0 || found === 0 || found === "0" || found === "0.00") return parsed;
    }
  }
  return 0;
}

function pickAmount(row: AnyRow, fields: string[]) {
  for (const field of fields) {
    const value = row[field];
    const parsed = num(value);
    if (parsed !== 0 || value === 0 || value === "0" || value === "0.00") return parsed;
  }
  return 0;
}

function lineRows(row: AnyRow): AnyRow[] {
  const rows: AnyRow[] = [];
  for (const field of LINE_ARRAY_FIELDS) {
    const value = row[field];
    if (Array.isArray(value)) rows.push(...value.filter((item) => item && typeof item === "object" && !Array.isArray(item)) as AnyRow[]);
  }
  return rows;
}

function sumRows(rows: AnyRow[], fields: string[]) {
  return rows.reduce((sum, row) => sum + pickAmount(row, fields), 0);
}

function documentTax(row: AnyRow) {
  const top = pickAmount(row, TAX_FIELDS);
  if (top !== 0) return top;
  return sumRows(lineRows(row), TAX_FIELDS);
}

function documentGross(row: AnyRow) {
  const top = pickAmount(row, GROSS_FIELDS);
  if (top !== 0) return top;
  return sumRows(lineRows(row), GROSS_FIELDS);
}

function documentNet(row: AnyRow) {
  const top = pickAmount(row, NET_FIELDS);
  if (top !== 0) return top;
  const lineNet = sumRows(lineRows(row), NET_FIELDS);
  if (lineNet !== 0) return lineNet;
  const gross = documentGross(row);
  if (gross !== 0) return gross - documentTax(row);
  return 0;
}

function totalTax(rows: AnyRow[]) {
  return rows.reduce((sum, row) => sum + documentTax(row), 0);
}

function totalNet(rows: AnyRow[]) {
  return rows.reduce((sum, row) => sum + documentNet(row), 0);
}

function money2(value: number) {
  return Number(value.toFixed(2));
}

function keyList(row: AnyRow | undefined) {
  return Object.keys(row ?? {}).sort().slice(0, 80);
}

function lineArrayDiagnostics(row: AnyRow | undefined) {
  return Object.entries(row ?? {})
    .filter(([, value]) => Array.isArray(value))
    .map(([name, value]) => {
      const rows = value as unknown[];
      const first = rows.find((item) => item && typeof item === "object" && !Array.isArray(item)) as AnyRow | undefined;
      return { name, count: rows.length, first_keys: keyList(first).slice(0, 50) };
    })
    .slice(0, 20);
}

function shapeDiagnostic(rows: AnyRow[]) {
  const first = rows[0];
  return { count: rows.length, top_level_keys: keyList(first), array_fields: lineArrayDiagnostics(first) };
}

function normalizeSagePath(value: unknown): string | null {
  const path = text(value);
  if (!path) return null;
  if (path.includes("://")) {
    const parsed = new URL(path);
    return `${parsed.pathname}${parsed.search}`;
  }
  return path;
}

function sageRows(raw: unknown): AnyRow[] {
  const root = object(raw);
  const rows = [root.$items, root.items, root.data, raw].find(Array.isArray) as unknown[] | undefined;
  return (rows ?? []).map((row) => object(row));
}

async function requireVatAdmin() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) throw new Error("Login required.");
  const { data: staff } = await supabase.from("staff").select("id, role_type").eq("auth_user_id", user.id).eq("active", true).maybeSingle();
  if (!staff || text((staff as AnyRow).role_type) !== "admin") throw new Error("Admin-only VAT reconstruction access required.");
  return { supabase, staff: staff as { id: string } };
}

async function latestActiveToken(): Promise<SageTokenRow> {
  const { data, error } = await supabaseAdmin
    .from("sage_oauth_tokens")
    .select("id, connection_id, access_token_encrypted, refresh_token_encrypted, expires_at, sage_business_row_id")
    .eq("status", "active")
    .order("expires_at", { ascending: false })
    .limit(1);
  if (error) throw new Error(`Sage token lookup failed: ${error.message}`);
  const token = data?.[0] as SageTokenRow | undefined;
  if (!token) throw new Error("No active Sage OAuth token found.");
  return token;
}

async function buildSageReadContext(): Promise<SageReadContext> {
  const config = assertSageOAuthConfigured();
  const token = await latestActiveToken();

  const { data: connection, error: connectionError } = await supabaseAdmin
    .from("sage_connections")
    .select("id, status")
    .eq("id", token.connection_id)
    .maybeSingle();
  if (connectionError) throw new Error(connectionError.message);
  if (!connection || text((connection as AnyRow).status) !== "connected") throw new Error("Sage connection is not connected.");

  let accessToken = decryptSecret(token.access_token_encrypted);
  if (tokenRefreshRequired(token.expires_at)) {
    const refreshed = await exchangeSageToken({
      tokenUrl: config.tokenUrl,
      clientId: config.clientId,
      clientSecret: config.clientSecret,
      grantType: "refresh_token",
      refreshToken: decryptSecret(token.refresh_token_encrypted),
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
    await supabaseAdmin.from("sage_oauth_tokens").insert({
      connection_id: token.connection_id,
      sage_business_row_id: token.sage_business_row_id ?? null,
      access_token_encrypted: encryptSecret(refreshed.raw.access_token),
      refresh_token_encrypted: encryptSecret(refreshed.raw.refresh_token),
      token_type: refreshed.raw.token_type || "Bearer",
      expires_at: expiresAt,
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
    }).eq("id", token.connection_id);

    accessToken = refreshed.raw.access_token;
  }

  return { apiBaseUrl: config.apiBaseUrl, connectionId: token.connection_id, accessToken };
}

async function sageJson(context: SageReadContext, path: string) {
  const url = `${context.apiBaseUrl.replace(/\/$/, "")}${path.startsWith("/") ? path : `/${path}`}`;
  const response = await fetch(url, {
    method: "GET",
    headers: { Accept: "application/json", Authorization: `Bearer ${context.accessToken}` },
    cache: "no-store",
  });
  const raw = await response.json().catch(async () => ({ non_json_body: await response.text().catch(() => null) }));
  if (!response.ok) {
    const message = text(object(raw).message ?? object(raw).error) || path;
    throw new Error(`Sage read failed (${response.status}): ${message}`);
  }
  return raw;
}

function sageNext(raw: unknown): string | null {
  const root = object(raw);
  return normalizeSagePath(root.$next ?? root.next);
}

async function sageAll(context: SageReadContext, path: string) {
  const all: AnyRow[] = [];
  let next: string | null = path;
  let guard = 0;
  while (next && guard < 25) {
    guard += 1;
    const raw = await sageJson(context, next);
    all.push(...sageRows(raw));
    next = sageNext(raw);
  }
  if (next) throw new Error(`Sage pagination limit reached for ${path}.`);
  return all;
}

async function hydrateSageRows(context: SageReadContext, rows: AnyRow[]) {
  return Promise.all(rows.map(async (row) => {
    const detailPath = normalizeSagePath(row.$path ?? row.path ?? row.href ?? row.url);
    if (!detailPath) return row;
    const raw = await sageJson(context, detailPath);
    if (raw && typeof raw === "object" && !Array.isArray(raw)) return raw as AnyRow;
    return sageRows(raw)[0] ?? row;
  }));
}

async function fetchSageVatDocs(context: SageReadContext, periodStart: string, periodEnd: string) {
  const params = new URLSearchParams({ from_date: periodStart, to_date: periodEnd, items_per_page: "200" });
  const [siRefs, scnRefs, piRefs, pcnRefs] = await Promise.all([
    sageAll(context, `/sales_invoices?${params.toString()}`),
    sageAll(context, `/sales_credit_notes?${params.toString()}`),
    sageAll(context, `/purchase_invoices?${params.toString()}`),
    sageAll(context, `/purchase_credit_notes?${params.toString()}`),
  ]);
  const [si, scn, pi, pcn] = await Promise.all([
    hydrateSageRows(context, siRefs),
    hydrateSageRows(context, scnRefs),
    hydrateSageRows(context, piRefs),
    hydrateSageRows(context, pcnRefs),
  ]);
  return { si, scn, pi, pcn };
}

export async function reconstructSageVatDraftWithSingleContextAction(vatReturnRunId: string) {
  const runId = String(vatReturnRunId ?? "").trim();
  if (!runId) throw new Error("VAT return run id is required.");

  const { supabase, staff } = await requireVatAdmin();
  const { data: run, error } = await supabase
    .from("vat_return_runs")
    .select("id, period_start_date, period_end_date")
    .eq("id", runId)
    .maybeSingle();
  if (error || !run) throw new Error(error?.message ?? "VAT return run not found.");

  const periodStart = text((run as AnyRow).period_start_date);
  const periodEnd = text((run as AnyRow).period_end_date);
  const context = await buildSageReadContext();
  const docs = await fetchSageVatDocs(context, periodStart, periodEnd);

  const salesTax = totalTax(docs.si);
  const salesCreditTax = totalTax(docs.scn);
  const purchaseTax = totalTax(docs.pi);
  const purchaseCreditTax = totalTax(docs.pcn);
  const salesNet = totalNet(docs.si);
  const salesCreditNet = totalNet(docs.scn);
  const purchaseNet = totalNet(docs.pi);
  const purchaseCreditNet = totalNet(docs.pcn);

  const box1 = money2(salesTax - salesCreditTax);
  const box2 = 0;
  const box3 = money2(box1 + box2);
  const box4 = money2(purchaseTax - purchaseCreditTax);
  const box5 = money2(box3 - box4);
  const box6 = money2(salesNet - salesCreditNet);
  const box7 = money2(purchaseNet - purchaseCreditNet);

  const { data: snapshot, error: insertError } = await supabase
    .from("vat_return_sage_reconstruction_snapshots")
    .insert({
      vat_return_run_id: runId,
      period_start_date: periodStart,
      period_end_date: periodEnd,
      status: "reconstructed",
      source_basis: "sage_single_context_hydrated_documents",
      box1_gbp: box1,
      box2_gbp: box2,
      box3_gbp: box3,
      box4_gbp: box4,
      box5_gbp: box5,
      box6_gbp: box6,
      box7_gbp: box7,
      box8_gbp: 0,
      box9_gbp: 0,
      sales_invoice_count: docs.si.length,
      sales_credit_note_count: docs.scn.length,
      purchase_invoice_count: docs.pi.length,
      purchase_credit_note_count: docs.pcn.length,
      source_counts: { sales_invoices: docs.si.length, sales_credit_notes: docs.scn.length, purchase_invoices: docs.pi.length, purchase_credit_notes: docs.pcn.length },
      source_summary: {
        sales_tax: money2(salesTax),
        sales_credit_tax: money2(salesCreditTax),
        purchase_tax: money2(purchaseTax),
        purchase_credit_tax: money2(purchaseCreditTax),
        sales_net: money2(salesNet),
        sales_credit_net: money2(salesCreditNet),
        purchase_net: money2(purchaseNet),
        purchase_credit_net: money2(purchaseCreditNet),
        sage_shape_diagnostic: {
          sales_invoice: shapeDiagnostic(docs.si),
          sales_credit_note: shapeDiagnostic(docs.scn),
          purchase_invoice: shapeDiagnostic(docs.pi),
          purchase_credit_note: shapeDiagnostic(docs.pcn),
        },
      },
      warning_notes: "Read-only Sage reconstruction using one operation-level Sage token context. Sage documents are hydrated before parsing. Manual VAT journals, cash-accounting timing, void/deleted document exclusion, and platform VAT timing overlays remain separate controls.",
      created_by_staff_id: staff.id,
    })
    .select("id")
    .single();

  if (insertError) throw new Error(insertError.message || "Could not save Sage VAT reconstruction snapshot.");

  revalidatePath("/internal/accounting-vat");
  revalidatePath("/internal/accounting-vat/sage-diagnostics");
  return { snapshotId: String(snapshot?.id ?? ""), boxes: { box1, box2, box3, box4, box5, box6, box7, box8: 0, box9: 0 } };
}
