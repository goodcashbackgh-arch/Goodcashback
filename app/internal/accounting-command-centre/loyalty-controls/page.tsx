import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import CompletionLoyaltyAppliedAccountingPreviewPanel from "../CompletionLoyaltyAppliedAccountingPreviewPanel";
import LoyaltyAccountingControlPanel from "../LoyaltyAccountingControlPanel";

type Row = Record<string, unknown>;
type SearchParams = Record<string, string | string[] | undefined>;

function text(value: unknown) {
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  if (typeof value === "boolean") return value ? "true" : "false";
  return "";
}

function firstParam(value: string | string[] | undefined) {
  return Array.isArray(value) ? value[0] ?? "" : value ?? "";
}

function cleanParam(value: string | string[] | undefined) {
  return firstParam(value).trim();
}

function allowed(value: string, allowedValues: string[]) {
  return allowedValues.includes(value) ? value : "all";
}

function bool(value: unknown) {
  return value === true || text(value).toLowerCase() === "true";
}

function asObject(value: unknown): Row {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  return value as Row;
}

function accessFromPermissions(value: unknown) {
  const permissions = asObject(value);
  return bool(permissions.accounting_admin_testing) || bool(permissions.admin_testing);
}

export default async function LoyaltyAccountingControlsPage({ searchParams }: { searchParams?: Promise<SearchParams> | SearchParams }) {
  const resolvedSearchParams = searchParams ? await searchParams : {};
  const searchQuery = cleanParam(resolvedSearchParams.q);
  const controlCategory = allowed(cleanParam(resolvedSearchParams.control_category), [
    "all",
    "bank_internal_transfer",
    "non_cash_loyalty_customer_balance_settlement",
    "released_unused_loyalty_control_balance",
  ]);
  const previewStatus = allowed(cleanParam(resolvedSearchParams.preview_status), [
    "all",
    "blocked",
    "debit_mapping_configured",
    "debit_mapping_missing",
  ]);

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) redirect("/login");

  const { data: staff } = await supabase
    .from("staff")
    .select("id, full_name, role_type, permissions_json")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!staff) redirect("/auth/check");

  const canAccess = text(staff.role_type) === "admin" || accessFromPermissions((staff as Row).permissions_json);
  if (!canAccess) redirect("/internal/accounting-command-centre");

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 lg:px-8">
      <div className="mx-auto max-w-[1500px] space-y-5">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div>
              <Link href="/internal/accounting-command-centre" className="text-sm font-semibold text-sky-700">← Accounting Command Centre</Link>
              <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-violet-500">Read-only control lane</p>
              <h1 className="mt-2 text-3xl font-semibold tracking-tight sm:text-4xl">Completion loyalty accounting controls</h1>
              <p className="mt-3 max-w-5xl text-sm leading-6 text-slate-600">
                This page exposes completion-loyalty accounting-control rows without making them selectable for freeze, batch creation, Sage posting, or cash-lane posting. It is evidence and review only.
              </p>
            </div>
            <div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700">
              <div className="font-medium text-slate-950">{text(staff.full_name) || "Staff"}</div>
              <div>{text(staff.role_type)}{accessFromPermissions((staff as Row).permissions_json) ? " · accounting admin testing" : ""}</div>
            </div>
          </div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
          <div className="flex flex-wrap items-center justify-between gap-3">
            <div>
              <p className="text-sm font-medium uppercase tracking-[0.18em] text-slate-500">Review filters</p>
              <h2 className="mt-1 text-xl font-semibold text-slate-950">Find items needing attention</h2>
            </div>
            {(searchQuery || controlCategory !== "all" || previewStatus !== "all") ? (
              <Link href="/internal/accounting-command-centre/loyalty-controls" className="rounded-full border border-slate-200 bg-slate-50 px-3 py-2 text-sm font-semibold text-slate-700 hover:bg-white">
                Clear filters
              </Link>
            ) : null}
          </div>

          <form className="mt-4 grid gap-3 md:grid-cols-[1.3fr_1fr_1fr_auto]" action="/internal/accounting-command-centre/loyalty-controls">
            <label className="text-sm font-semibold text-slate-700">
              Search order / importer / event
              <input
                name="q"
                defaultValue={searchQuery}
                placeholder="ORD ref, importer, amount, event id"
                className="mt-1 w-full rounded-2xl border border-slate-200 bg-white px-3 py-2 text-sm text-slate-950 shadow-sm outline-none focus:border-sky-300 focus:ring-2 focus:ring-sky-100"
              />
            </label>

            <label className="text-sm font-semibold text-slate-700">
              Control category
              <select
                name="control_category"
                defaultValue={controlCategory}
                className="mt-1 w-full rounded-2xl border border-slate-200 bg-white px-3 py-2 text-sm text-slate-950 shadow-sm outline-none focus:border-sky-300 focus:ring-2 focus:ring-sky-100"
              >
                <option value="all">All control rows</option>
                <option value="bank_internal_transfer">Bank internal transfer</option>
                <option value="non_cash_loyalty_customer_balance_settlement">Non-cash settlement</option>
                <option value="released_unused_loyalty_control_balance">Released unused loyalty</option>
              </select>
            </label>

            <label className="text-sm font-semibold text-slate-700">
              Applied/Sage preview status
              <select
                name="preview_status"
                defaultValue={previewStatus}
                className="mt-1 w-full rounded-2xl border border-slate-200 bg-white px-3 py-2 text-sm text-slate-950 shadow-sm outline-none focus:border-sky-300 focus:ring-2 focus:ring-sky-100"
              >
                <option value="all">All preview rows</option>
                <option value="blocked">Blocked from posting</option>
                <option value="debit_mapping_configured">Debit mapping configured</option>
                <option value="debit_mapping_missing">Debit mapping missing</option>
              </select>
            </label>

            <div className="flex items-end">
              <button type="submit" className="w-full rounded-2xl bg-slate-950 px-4 py-2 text-sm font-bold text-white shadow-sm hover:bg-slate-800">
                Apply
              </button>
            </div>
          </form>
        </section>

        <LoyaltyAccountingControlPanel searchQuery={searchQuery} categoryFilter={controlCategory} />

        <CompletionLoyaltyAppliedAccountingPreviewPanel searchQuery={searchQuery} previewStatusFilter={previewStatus} />

        <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm leading-6 text-amber-950">
          <h2 className="font-bold">Control boundary</h2>
          <p className="mt-2">
            Pending loyalty, staged main-bank OUT, and released unused loyalty must not create VAT timing or Sage posting. Only staff-applied loyalty creates the existing <code>credit_applied</code> order-funding event, which the VAT timing engine already understands.
          </p>
        </section>
      </div>
    </main>
  );
}
