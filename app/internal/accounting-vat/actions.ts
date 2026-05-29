"use server";

import { redirect } from "next/navigation";
import { revalidatePath } from "next/cache";
import { createClient } from "@/utils/supabase/server";
import { sageApiFetch } from "@/lib/sage/server-token";

type StaffRow = { id: string; role_type: string; active: boolean };
type AnyRow = Record<string, unknown>;

type VatRunResult = { vat_return_run_id?: string } | null;

function redirectWithError(message: string) {
  redirect(`/internal/accounting-vat?tab=runs&vatError=${encodeURIComponent(message)}`);
}

function redirectReconstructionWithError(message: string) {
  redirect(`/internal/accounting-vat/sage-reconstruction?vatError=${encodeURIComponent(message)}`);
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

function text(value: unknown): string {
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  if (typeof value === "boolean") return value ? "true" : "false";
  if (Array.isArray(value)) return value.map(text).filter(Boolean).join(", ");
  if (value && typeof value === "object") {
    const row = value as AnyRow;
    return text(row.displayed_as ?? row.name ?? row.description ?? row.id ?? row.code);
  }
  return "";
}

function amount(value: unknown): number {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value.replace(/,/g, ""));
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

function amountFrom(row: AnyRow, fields: string[]) {
  for (const field of fields) {
    const value = row[field];
    const parsed = amount(value);
    if (parsed !== 0 || value === 0 || value === "0" || value === "0.00") return parsed;
  }
  return 0;
}

function money(value: number) {
  return Number(value.toFixed(2));
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

function readTaxScheme(settings: unknown) {
  const root = settings && typeof settings === "object" ? settings as Record<string, unknown> : {};
  return text(root.tax_scheme ?? root.taxScheme ?? root.vat_scheme ?? root.vatScheme).trim();
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

function sageCollection(raw: unknown): AnyRow[] {
  const root = raw && typeof raw === "object" && !Array.isArray(raw) ? raw as AnyRow : {};
  const candidates = [root.$items, root.items, root.data, root.sales_invoices, root.sales_credit_notes, root.purchase_invoices, root.purchase_credit_notes, raw];
  const array = candidates.find(Array.isArray) as unknown[] | undefined;
  return (array ?? []).map((item) => item && typeof item === "object" ? item as AnyRow : {});
}

function sageNextPath(raw: unknown): string | null {
  const root = raw && typeof raw === "object" && !Array.isArray(raw) ? raw as AnyRow : {};
  return text(root.$next ?? root.next ?? root.next_page ?? root.$next_page).trim() || null;
}

async function fetchAllSagePages(path: string) {
  const all: AnyRow[] = [];
  let next: string | null = path;
  let guard = 0;

  while (next && guard < 25) {
    guard += 1;
    const response = await sageApiFetch(next, { method: "GET" });
    const raw = await response.json().catch(async () => ({ non_json_body: await response.text().catch(() => null) }));

    if (!response.ok) {
      const message = raw && typeof raw === "object" && "message" in raw ? String((raw as AnyRow).message) : JSON.stringify(raw).slice(0, 500);
      throw new Error(`Sage GET ${path} failed (${response.status}): ${message}`);
    }

    all.push(...sageCollection(raw));
    next = sageNextPath(raw);
  }

  if (guard >= 25 && next) throw new Error(`Sage pagination limit reached for ${path}.`);
  return all;
}

async function fetchPostedSageVatDocuments(periodStart: string, periodEnd: string) {
  const params = new URLSearchParams({
    from_date: periodStart,
    to_date: periodEnd,
    items_per_page: "200",
    status_id: "POSTED",
  });

  const [salesInvoices, salesCreditNotes, purchaseInvoices, purchaseCreditNotes] = await Promise.all([
    fetchAllSagePages(`/sales_invoices?${params.toString()}`),
    fetchAllSagePages(`/sales_credit_notes?${params.toString()}`),
    fetchAllSagePages(`/purchase_invoices?${params.toString()}`),
    fetchAllSagePages(`/purchase_credit_notes?${params.toString()}`),
  ]);

  return { salesInvoices, salesCreditNotes, purchaseInvoices, purchaseCreditNotes };
}

function sumTax(rows: AnyRow[]) {
  return rows.reduce((total, row) => total + amountFrom(row, ["tax_amount", "total_tax_amount", "tax_total", "total_tax", "vat_amount"]), 0);
}

function sumNet(rows: AnyRow[]) {
  return rows.reduce((total, row) => total + amountFrom(row, ["net_amount", "total_net_amount", "net_total", "total_net", "subtotal", "goods_value"]), 0);
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
    p_return_period_label: `${period.label} — Sage Accounting checked${taxScheme ? ` (${taxScheme})` : ""}`,
  });

  if (error) {
    redirectWithError(error.message || "VAT draft run generation failed.");
  }

  const result = data as VatRunResult;
  const runId = result?.vat_return_run_id;

  revalidatePath("/internal/accounting-vat");
  redirect(`/internal/accounting-vat?tab=runs&vatGenerated=${encodeURIComponent(runId ?? "1")}`);
}

export async function reconstructSageVatDraftForRunAction(formData: FormData) {
  const { supabase, staff } = await requireAdmin();
  const runId = String(formData.get("vat_return_run_id") ?? "").trim();

  if (!runId) redirectReconstructionWithError("Choose a VAT return run first.");

  const { data: run, error: runError } = await supabase
    .from("vat_return_runs")
    .select("id, run_ref, period_start_date, period_end_date")
    .eq("id", runId)
    .maybeSingle();

  if (runError || !run) {
    redirectReconstructionWithError(runError?.message ?? "VAT return run not found.");
  }

  const periodStart = String((run as AnyRow).period_start_date ?? "");
  const periodEnd = String((run as AnyRow).period_end_date ?? "");

  if (!periodStart || !periodEnd) {
    redirectReconstructionWithError("VAT return run is missing a period start/end date.");
  }

  let docs: Awaited<ReturnType<typeof fetchPostedSageVatDocuments>>;
  try {
    docs = await fetchPostedSageVatDocuments(periodStart, periodEnd);
  } catch (error) {
    redirectReconstructionWithError(error instanceof Error ? error.message : "Could not fetch Sage posted VAT documents.");
  }

  const salesTax = sumTax(docs.salesInvoices);
  const salesCreditTax = sumTax(docs.salesCreditNotes);
  const purchaseTax = sumTax(docs.purchaseInvoices);
  const purchaseCreditTax = sumTax(docs.purchaseCreditNotes);
  const salesNet = sumNet(docs.salesInvoices);
  const salesCreditNet = sumNet(docs.salesCreditNotes);
  const purchaseNet = sumNet(docs.purchaseInvoices);
  const purchaseCreditNet = sumNet(docs.purchaseCreditNotes);

  const box1 = money(salesTax - salesCreditTax);
  const box2 = 0;
  const box3 = money(box1 + box2);
  const box4 = money(purchaseTax - purchaseCreditTax);
  const box5 = money(box3 - box4);
  const box6 = money(salesNet - salesCreditNet);
  const box7 = money(purchaseNet - purchaseCreditNet);
  const box8 = 0;
  const box9 = 0;

  const { data: inserted, error: insertError } = await supabase
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
      box8_gbp: box8,
      box9_gbp: box9,
      sales_invoice_count: docs.salesInvoices.length,
      sales_credit_note_count: docs.salesCreditNotes.length,
      purchase_invoice_count: docs.purchaseInvoices.length,
      purchase_credit_note_count: docs.purchaseCreditNotes.length,
      source_counts: {
        sales_invoices: docs.salesInvoices.length,
        sales_credit_notes: docs.salesCreditNotes.length,
        purchase_invoices: docs.purchaseInvoices.length,
        purchase_credit_notes: docs.purchaseCreditNotes.length,
      },
      source_summary: {
        sales_tax,
        sales_credit_tax: salesCreditTax,
        purchase_tax: purchaseTax,
        purchase_credit_tax: purchaseCreditTax,
        sales_net: salesNet,
        sales_credit_net: salesCreditNet,
        purchase_net: purchaseNet,
        purchase_credit_net: purchaseCreditNet,
      },
      warning_notes: "Read-only Sage reconstruction from posted documents only. Manual VAT journals and cash-accounting payment timing are not included in this first pass.",
      created_by_staff_id: staff.id,
    })
    .select("id")
    .single();

  if (insertError) {
    redirectReconstructionWithError(insertError.message || "Could not save Sage VAT reconstruction snapshot.");
  }

  revalidatePath("/internal/accounting-vat");
  revalidatePath("/internal/accounting-vat/sage-reconstruction");
  redirect(`/internal/accounting-vat/sage-reconstruction?vatReconstructed=${encodeURIComponent(String(inserted?.id ?? "1"))}`);
}
