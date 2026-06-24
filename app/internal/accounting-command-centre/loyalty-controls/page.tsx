import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import CompletionLoyaltyAppliedAccountingPreviewPanel from "../CompletionLoyaltyAppliedAccountingPreviewPanel";
import CompletionLoyaltySagePostingMaterialisationPanel from "../CompletionLoyaltySagePostingMaterialisationPanel";
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

function staffAccessLabel(staff: Row) {
  if (text(staff.role_type) === "admin") return "Admin · Accounting controls";
  if (accessFromPermissions(staff.permissions_json)) return "Accounting controls";
  return text(staff.role_type) || "Staff";
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
              <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-violet-500">Three-step Sage control flow</p>
              <h1 className="mt-2 text-3xl font-semibold tracking-tight sm:text-4xl">Completion loyalty accounting controls</h1>
              <p className="mt-3 max-w-5xl text-sm leading-6 text-slate-600">
                This page is split into three steps: evidence first, eligibility second, and lifecycle actions last. Step 3 creates local Sage posting groups and approved batches. Only the approved Step 3 batch post action calls Sage; Step 1 and Step 2 remain read-only control evidence.
              </p>
            </div>
            <div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700">
              <div className="font-medium text-slate-950">{text(staff.full_name) || "Staff"}</div>
              <div>{staffAccessLabel(staff as Row)}</div>
            </div>
          </div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
          <p className="text-sm font-medium uppercase tracking-[0.18em] text-slate-500">Page map</p>
          <h2 className="mt-1 text-xl font-semibold text-slate-950">Use this page in order</h2>
          <div className="mt-4 grid gap-3 md:grid-cols-3">
            <a href="#step-1-evidence" className="rounded-2xl border border-violet-200 bg-violet-50 p-4 text-violet-950 hover:bg-violet-100">
              <p className="text-xs font-bold uppercase tracking-wide opacity-70">Step 1</p>
              <p className="mt-1 font-bold">Accounting control evidence</p>
              <p className="mt-1 text-xs leading-5 opacity-80">Shows the accounting meaning of loyalty activity from main-bank, DVA/card, and applied-loyalty control rows. No action here.</p>
            </a>
            <a href="#step-2-eligibility" className="rounded-2xl border border-sky-200 bg-sky-50 p-4 text-sky-950 hover:bg-sky-100">
              <p className="text-xs font-bold uppercase tracking-wide opacity-70">Step 2</p>
              <p className="mt-1 font-bold">Applied-loyalty eligibility preview</p>
              <p className="mt-1 text-xs leading-5 opacity-80">Shows which credit_applied loyalty rows can move into Step 3. Still read-only.</p>
            </a>
            <a href="#step-3-lifecycle" className="rounded-2xl border border-emerald-200 bg-emerald-50 p-4 text-emerald-950 hover:bg-emerald-100">
              <p className="text-xs font-bold uppercase tracking-wide opacity-70">Step 3</p>
              <p className="mt-1 font-bold">Sage posting lifecycle actions</p>
              <p className="mt-1 text-xs leading-5 opacity-80">Materialise/freeze, batch, approve, post, review responses, and retry failed steps only.</p>
            </a>
          </div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
          <div className="flex flex-wrap items-center justify-between gap-3">
            <div>
              <p className="text-sm font-medium uppercase tracking-[0.18em] text-slate-500">Shared filters</p>
              <h2 className="mt-1 text-xl font-semibold text-slate-950">Find items needing attention</h2>
              <p className="mt-1 text-sm text-slate-500">Search applies across all three steps. Category affects Step 1; preview status affects Step 2.</p>
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
              Step 1 category
              <select
                name="control_category"
                defaultValue={controlCategory}
                className="mt-1 w-full rounded-2xl border border-slate-200 bg-white px-3 py-2 text-sm text-slate-950 shadow-sm outline-none focus:border-sky-300 focus:ring-2 focus:ring-sky-100"
              >
                <option value="all">All Step 1 evidence</option>
                <option value="bank_internal_transfer">Bank internal transfer</option>
                <option value="non_cash_loyalty_customer_balance_settlement">Non-cash settlement</option>
                <option value="released_unused_loyalty_control_balance">Released unused loyalty</option>
              </select>
            </label>

            <label className="text-sm font-semibold text-slate-700">
              Step 2 readiness
              <select
                name="preview_status"
                defaultValue={previewStatus}
                className="mt-1 w-full rounded-2xl border border-slate-200 bg-white px-3 py-2 text-sm text-slate-950 shadow-sm outline-none focus:border-sky-300 focus:ring-2 focus:ring-sky-100"
              >
                <option value="all">All Step 2 preview rows</option>
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

        <CompletionLoyaltySagePostingMaterialisationPanel searchQuery={searchQuery} />

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
