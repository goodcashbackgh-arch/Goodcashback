"use server";

import { redirect } from "next/navigation";
import { revalidatePath } from "next/cache";
import { createClient } from "@/utils/supabase/server";
import { sageApiFetch } from "@/lib/sage/server-token";

type StaffRow = { id: string; role_type: string; active: boolean };

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

function readTaxScheme(settings: unknown) {
  const root = settings && typeof settings === "object" ? settings as Record<string, unknown> : {};
  return String(root.tax_scheme ?? root.taxScheme ?? root.vat_scheme ?? root.vatScheme ?? "").trim();
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
