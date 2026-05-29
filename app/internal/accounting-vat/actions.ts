"use server";

import { redirect } from "next/navigation";
import { revalidatePath } from "next/cache";
import { createClient } from "@/utils/supabase/server";
import { getValidSageAccessToken, sageApiFetch } from "@/lib/sage/server-token";

type StaffRow = { id: string; role_type: string; active: boolean };
type AnyRow = Record<string, unknown>;

type VatRunResult = { vat_return_run_id?: string } | null;

function redirectWithError(message: string) {
  redirect(`/internal/accounting-vat?tab=runs&vatError=${encodeURIComponent(message)}`);
}

function isoDate(date: Date) {
  return date.toISOString().slice(0, 10);
}

function firstDayOfMonth(year: number, monthIndex: number) {
  return new Date(Date.UTC(year, monthIndex, 1));
}

function lastDayOfMonth(year: number, monthIndex: number) {
  return new Date(Date.UTC(year, monthIndex + 1, 0));
}

function nextMonthAfter(dateString: string) {
  const end = new Date(`${dateString}T00:00:00.000Z`);
  if (Number.isNaN(end.getTime())) return null;
  return firstDayOfMonth(end.getUTCFullYear(), end.getUTCMonth() + 1);
}

function previousCompletedMonth(today = new Date()) {
  return firstDayOfMonth(today.getUTCFullYear(), today.getUTCMonth() - 1);
}

function periodLabel(start: Date) {
  return new Intl.DateTimeFormat("en-GB", {
    month: "long",
    year: "numeric",
    timeZone: "UTC",
  }).format(start);
}

function periodEndForStart(start: Date) {
  return lastDayOfMonth(start.getUTCFullYear(), start.getUTCMonth());
}

async function requireAdmin() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) redirect("/login");

  const { data: staff, error: staffError } = await supabase
    .from("staff")
    .select("id, role_type, active")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (staffError || !staff || (staff as StaffRow).role_type !== "admin") {
    redirectWithError("Admin-only VAT Return Workbench access required.");
  }

  return { supabase, staff: staff as StaffRow };
}

async function fetchSageFinancialSettings() {
  const response = await sageApiFetch("/financial_settings", { method: "GET" });
  const raw = await response.json().catch(async () => ({ non_json_body: await response.text().catch(() => null) }));

  if (!response.ok) {
    const message = raw && typeof raw === "object" && "message" in raw ? String((raw as Record<string, unknown>).message) : "Sage financial settings could not be fetched.";
    throw new Error(`Sage financial settings check failed (${response.status}): ${message}`);
  }

  return raw;
}

function readSageText(value: unknown): string {
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  if (value && typeof value === "object" && !Array.isArray(value)) {
    const row = value as Record<string, unknown>;
    return readSageText(row.displayed_as ?? row.name ?? row.description ?? row.id ?? row.code ?? "");
  }
  return "";
}

function readTaxScheme(settings: unknown) {
  const root = settings && typeof settings === "object" ? settings as Record<string, unknown> : {};
  return readSageText(root.tax_scheme ?? root.taxScheme ?? root.vat_scheme ?? root.vatScheme).trim();
}

async function detectNextMonthlyVatPeriod(supabase: Awaited<ReturnType<typeof createClient>>) {
  const { data, error } = await supabase
    .from("vat_return_runs")
    .select("period_end_date")
    .order("period_end_date", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (error) throw new Error(`Could not read existing VAT runs: ${error.message}`);

  const latestEnd = typeof data?.period_end_date === "string" ? data.period_end_date : "";
  const start = latestEnd ? nextMonthAfter(latestEnd) : previousCompletedMonth();

  if (!start) throw new Error("Could not derive the next monthly VAT period from existing VAT runs.");

  const end = periodEndForStart(start);
  return {
    startDate: isoDate(start),
    endDate: isoDate(end),
    label: periodLabel(start),
  };
}

async function sageJson(path: string) {
  const response = await sageApiFetch(path, { method: "GET" });
  const raw = await response.json().catch(async () => ({ non_json_body: await response.text().catch(() => null) }));
  if (!response.ok) {
    const message = raw && typeof raw === "object" ? readSageText((raw as AnyRow).message ?? (raw as AnyRow).error) : "";
    throw new Error(`Sage read failed (${response.status}): ${message || path}`);
  }
  return raw;
}

function sageRows(raw: unknown): AnyRow[] {
  const root = raw && typeof raw === "object" && !Array.isArray(raw) ? raw as AnyRow : {};
  const rows = [root.$items, root.items, root.data, raw].find(Array.isArray) as unknown[] | undefined;
  return (rows ?? []).map((row) => row && typeof row === "object" ? row as AnyRow : {});
}

function sageNext(raw: unknown): string | null {
  const root = raw && typeof raw === "object" && !Array.isArray(raw) ? raw as AnyRow : {};
  const next = readSageText(root.$next ?? root.next).trim();
  if (!next) return null;
  if (next.includes("://")) {
    const parsed = new URL(next);
    return `${parsed.pathname}${parsed.search}`;
  }
  return next;
}

async function sageAll(path: string) {
  const all: AnyRow[] = [];
  let next: string | null = path;
  let guard = 0;
  while (next && guard < 25) {
    guard += 1;
    const raw = await sageJson(next);
    all.push(...sageRows(raw));
    next = sageNext(raw);
  }
  if (next) throw new Error(`Sage pagination limit reached for ${path}.`);
  return all;
}

function num(value: unknown) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value.replace(/,/g, ""));
    return Number.isFinite(parsed) ? parsed : 0;
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

function total(rows: AnyRow[], fields: string[]) {
  return rows.reduce((sum, row) => sum + pickAmount(row, fields), 0);
}

function money2(value: number) {
  return Number(value.toFixed(2));
}

async function fetchSageVatDocs(periodStart: string, periodEnd: string) {
  const params = new URLSearchParams({ from_date: periodStart, to_date: periodEnd, items_per_page: "200", status_id: "POSTED" });
  const [si, scn, pi, pcn] = await Promise.all([
    sageAll(`/sales_invoices?${params.toString()}`),
    sageAll(`/sales_credit_notes?${params.toString()}`),
    sageAll(`/purchase_invoices?${params.toString()}`),
    sageAll(`/purchase_credit_notes?${params.toString()}`),
  ]);
  return { si, scn, pi, pcn };
}

export async function generateNextSageVatDraftRunAction() {
  const { supabase } = await requireAdmin();

  let financialSettings: unknown;
  try {
    financialSettings = await fetchSageFinancialSettings();
  } catch (error) {
    redirectWithError(error instanceof Error ? error.message : "Could not verify Sage VAT settings.");
  }

  const taxScheme = readTaxScheme(financialSettings);
  const period = await detectNextMonthlyVatPeriod(supabase);

  const { data, error } = await supabase.rpc("generate_vat_return_draft_run_v1", {
    p_period_start_date: period.startDate,
    p_period_end_date: period.endDate,
    p_return_period_label: `${period.label} — Sage checked${taxScheme ? ` (${taxScheme})` : ""}`,
  });

  if (error) {
    redirectWithError(error.message || "VAT draft run generation failed.");
  }

  const result = data as VatRunResult;
  const runId = result?.vat_return_run_id;

  revalidatePath("/internal/accounting-vat");
  redirect(`/internal/accounting-vat?tab=runs&vatGenerated=${encodeURIComponent(runId ?? "1")}`);
}

export async function reconstructSageVatDraftBackendCheckAction(vatReturnRunId: string) {
  const runId = String(vatReturnRunId ?? "").trim();
  if (!runId) throw new Error("VAT return run id is required.");

  const { supabase, staff } = await requireAdmin();
  const { data: run, error } = await supabase
    .from("vat_return_runs")
    .select("id, period_start_date, period_end_date")
    .eq("id", runId)
    .maybeSingle();

  if (error || !run) throw new Error(error?.message ?? "VAT return run not found.");

  const periodStart = readSageText((run as AnyRow).period_start_date);
  const periodEnd = readSageText((run as AnyRow).period_end_date);

  await getValidSageAccessToken({ forceRefresh: true });
  const docs = await fetchSageVatDocs(periodStart, periodEnd);

  const salesTax = total(docs.si, ["tax_amount", "total_tax_amount", "tax_total", "total_tax", "vat_amount"]);
  const salesCreditTax = total(docs.scn, ["tax_amount", "total_tax_amount", "tax_total", "total_tax", "vat_amount"]);
  const purchaseTax = total(docs.pi, ["tax_amount", "total_tax_amount", "tax_total", "total_tax", "vat_amount"]);
  const purchaseCreditTax = total(docs.pcn, ["tax_amount", "total_tax_amount", "tax_total", "total_tax", "vat_amount"]);
  const salesNet = total(docs.si, ["net_amount", "total_net_amount", "net_total", "total_net", "subtotal"]);
  const salesCreditNet = total(docs.scn, ["net_amount", "total_net_amount", "net_total", "total_net", "subtotal"]);
  const purchaseNet = total(docs.pi, ["net_amount", "total_net_amount", "net_total", "total_net", "subtotal"]);
  const purchaseCreditNet = total(docs.pcn, ["net_amount", "total_net_amount", "net_total", "total_net", "subtotal"]);

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
      source_basis: "sage_posted_documents",
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
      source_summary: { sales_tax: money2(salesTax), sales_credit_tax: money2(salesCreditTax), purchase_tax: money2(purchaseTax), purchase_credit_tax: money2(purchaseCreditTax), sales_net: money2(salesNet), sales_credit_net: money2(salesCreditNet), purchase_net: money2(purchaseNet), purchase_credit_net: money2(purchaseCreditNet) },
      warning_notes: "Read-only Sage reconstruction from posted invoices and credit notes only. Manual VAT journals and cash-accounting payment timing are not included in this backend pass.",
      created_by_staff_id: staff.id,
    })
    .select("id")
    .single();

  if (insertError) throw new Error(insertError.message || "Could not save Sage VAT reconstruction snapshot.");

  revalidatePath("/internal/accounting-vat");
  return { snapshotId: String(snapshot?.id ?? ""), boxes: { box1, box2, box3, box4, box5, box6, box7, box8: 0, box9: 0 } };
}
