"use server";

import { redirect } from "next/navigation";
import { revalidatePath } from "next/cache";
import { createClient } from "@/utils/supabase/server";
import { sageApiFetch } from "@/lib/sage/server-token";

type StaffRow = { id: string; role_type: string; active: boolean };
type AnyRow = Record<string, unknown>;
type VatRunResult = { vat_return_run_id?: string } | null;

const ACTIVE_VAT_RUN_STATUSES = [
  "draft",
  "calculated",
  "admin_review_required",
  "blocked",
  "admin_approved",
  "sage_adjustment_journals_pending",
  "sage_adjustment_journals_posted",
  "sage_return_review_required",
  "sage_return_submitted",
  "mismatch_needs_admin_review",
  "reopened_for_correction",
];

function redirectWithError(message: string): never {
  redirect(`/internal/accounting-vat?vatError=${encodeURIComponent(message)}`);
}

function text(value: unknown): string {
  if (typeof value === "string") return value.trim();
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  if (value && typeof value === "object" && !Array.isArray(value)) {
    const row = value as AnyRow;
    return text(row.displayed_as ?? row.name ?? row.description ?? row.amount ?? row.value ?? row.id ?? row.code ?? "");
  }
  return "";
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

function periodEndForStart(start: Date) {
  return lastDayOfMonth(start.getUTCFullYear(), start.getUTCMonth());
}

function periodLabel(start: Date) {
  return new Intl.DateTimeFormat("en-GB", {
    month: "long",
    year: "numeric",
    timeZone: "UTC",
  }).format(start);
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
  const root = settings && typeof settings === "object" ? settings as AnyRow : {};
  return text(root.tax_scheme ?? root.taxScheme ?? root.vat_scheme ?? root.vatScheme);
}

function formatRunLabel(row: AnyRow) {
  return text(row.return_period_label) || `${text(row.period_start_date)} to ${text(row.period_end_date)}` || text(row.id);
}

async function detectNextEligibleMonthlyVatPeriod(supabase: Awaited<ReturnType<typeof createClient>>) {
  const { data: openRun, error: openRunError } = await supabase
    .from("vat_return_runs")
    .select("id, return_period_label, period_start_date, period_end_date, status, created_at")
    .in("status", ACTIVE_VAT_RUN_STATUSES)
    .order("period_start_date", { ascending: true })
    .order("created_at", { ascending: true })
    .limit(1)
    .maybeSingle();

  if (openRunError) throw new Error(`Could not check open VAT runs: ${openRunError.message}`);

  if (openRun) {
    throw new Error(`Prior VAT return pack is still open (${formatRunLabel(openRun as AnyRow)}). Open and finish the current draft before generating another period.`);
  }

  const { data: latestLocked, error: latestLockedError } = await supabase
    .from("vat_return_runs")
    .select("period_end_date")
    .eq("status", "matched_to_sage_locked")
    .order("period_end_date", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (latestLockedError) throw new Error(`Could not read locked VAT runs: ${latestLockedError.message}`);

  const latestLockedEnd = text((latestLocked as AnyRow | null)?.period_end_date);
  const start = latestLockedEnd ? nextMonthAfter(latestLockedEnd) : previousCompletedMonth();
  if (!start) throw new Error("Could not derive the next monthly VAT period from locked return history.");

  const latestAllowedStart = previousCompletedMonth();
  if (start.getTime() > latestAllowedStart.getTime()) {
    throw new Error(`No completed VAT period is available to generate yet. Latest eligible period starts ${isoDate(latestAllowedStart)}.`);
  }

  const end = periodEndForStart(start);
  return {
    startDate: isoDate(start),
    endDate: isoDate(end),
    label: periodLabel(start),
  };
}

export async function generateNextSageVatDraftRunAction() {
  const { supabase } = await requireAdmin();

  let financialSettings: unknown;
  try {
    financialSettings = await fetchSageFinancialSettings();
  } catch (error) {
    redirectWithError(error instanceof Error ? error.message : "Could not verify Sage VAT settings.");
  }

  let period: { startDate: string; endDate: string; label: string };
  try {
    period = await detectNextEligibleMonthlyVatPeriod(supabase);
  } catch (error) {
    redirectWithError(error instanceof Error ? error.message : "VAT period generation is blocked.");
  }

  const taxScheme = readTaxScheme(financialSettings);
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
  if (!runId) redirectWithError("VAT draft run generation did not return a run id.");

  revalidatePath("/internal/accounting-vat");
  revalidatePath(`/internal/accounting-vat/returns/${runId}`);
  redirect(`/internal/accounting-vat/returns/${runId}`);
}

export async function reconstructSageVatDraftBackendCheckAction() {
  throw new Error("Use the VAT return pack read-only Sage reconstruction action from the return detail page.");
}
