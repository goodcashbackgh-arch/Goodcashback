import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import CompletionLoyaltyActionQueuePanel from "../CompletionLoyaltyActionQueuePanel";
import CompletionLoyaltyAppliedAccountingPreviewPanel from "../CompletionLoyaltyAppliedAccountingPreviewPanel";
import CompletionLoyaltyInternalTransferJournalPanel from "../CompletionLoyaltyInternalTransferJournalPanel";
import CompletionLoyaltySagePostingMaterialisationPanel from "../CompletionLoyaltySagePostingMaterialisationPanel";
import LoyaltyAccountingControlPanel from "../LoyaltyAccountingControlPanel";

type Row = Record<string, unknown>;
type SearchParams = Record<string, string | string[] | undefined>;

const laneOptions = ["action_queue", "applied_settlement", "internal_transfer", "evidence", "all"];
const statusOptions = ["needs_action", "ready_to_materialise", "ready_to_batch", "ready_to_post", "blocked", "batched_or_posted", "all"];

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

function allowedOr(value: string, allowedValues: string[], fallback: string) {
  return allowedValues.includes(value) ? value : fallback;
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

function laneLabel(value: string) {
  if (value === "action_queue") return "Action queue";
  if (value === "applied_settlement") return "Applied settlement";
  if (value === "internal_transfer") return "Internal transfer";
  if (value === "evidence") return "Evidence";
  return "All lanes";
}

function statusLabel(value: string) {
  if (value === "needs_action") return "Needs action";
  if (value === "ready_to_materialise") return "Ready to materialise";
  if (value === "ready_to_batch") return "Ready to batch";
  if (value === "ready_to_post") return "Ready to post";
  if (value === "blocked") return "Blocked";
  if (value === "batched_or_posted") return "Batched / posted";
  return "All statuses";
}

export default async function LoyaltyAccountingControlsPage({ searchParams }: { searchParams?: Promise<SearchParams> | SearchParams }) {
  const resolvedSearchParams = searchParams ? await searchParams : {};
  const searchQuery = cleanParam(resolvedSearchParams.q);
  const success = cleanParam(resolvedSearchParams.success);
  const pageError = cleanParam(resolvedSearchParams.error);
  const lane = allowedOr(cleanParam(resolvedSearchParams.lane), laneOptions, "action_queue");
  const status = allowedOr(cleanParam(resolvedSearchParams.status), statusOptions, "needs_action");
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

  const showActionQueue = lane === "action_queue" || lane === "all";
  const showEvidence = lane === "evidence" || lane === "all";
  const showAppliedSettlement = lane === "applied_settlement" || lane === "all";
  const showInternalTransfer = lane === "internal_transfer" || lane === "all";
  const hasFilters = searchQuery || lane !== "action_queue" || status !== "needs_action" || controlCategory !== "all" || previewStatus !== "all";

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 lg:px-8">
      <div className="mx-auto max-w-[1500px] space-y-4">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div>
              <Link href="/internal/accounting-command-centre" className="text-sm font-semibold text-sky-700">← Accounting Command Centre</Link>
              <p className="mt-4 text-sm font-medium uppercase tracking-[0.2em] text-slate-500">Completion loyalty</p>
              <h1 className="mt-2 text-3xl font-semibold tracking-tight sm:text-4xl">Accounting controls</h1>
              <p className="mt-3 max-w-5xl text-sm leading-6 text-slate-600">
                Action queue first. Applied-loyalty settlement and internal-transfer journals stay separate internally, but only the selected lane is expanded by default.
              </p>
            </div>
            <div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700">
              <div className="font-medium text-slate-950">{text(staff.full_name) || "Staff"}</div>
              <div>{staffAccessLabel(staff as Row)}</div>
            </div>
          </div>
          {success ? <p className="mt-4 rounded-2xl border border-emerald-200 bg-emerald-50 p-3 text-sm font-semibold text-emerald-900">{success}</p> : null}
          {pageError ? <p className="mt-4 rounded-2xl border border-rose-200 bg-rose-50 p-3 text-sm font-semibold text-rose-900">{pageError}</p> : null}
        </section>

        <section className="sticky top-0 z-10 rounded-3xl border border-slate-200 bg-white/95 p-4 shadow-sm backdrop-blur">
          <div className="flex flex-wrap items-center justify-between gap-3">
            <div>
              <p className="text-sm font-medium uppercase tracking-[0.18em] text-slate-500">Filters</p>
              <h2 className="mt-1 text-lg font-semibold text-slate-950">{laneLabel(lane)} · {statusLabel(status)}</h2>
            </div>
            {hasFilters ? (
              <Link href="/internal/accounting-command-centre/loyalty-controls" className="rounded-full border border-slate-200 bg-slate-50 px-3 py-2 text-sm font-semibold text-slate-700 hover:bg-white">
                Clear filters
              </Link>
            ) : null}
          </div>

          <form className="mt-3 grid gap-3 md:grid-cols-[1.4fr_1fr_1fr_auto]" action="/internal/accounting-command-centre/loyalty-controls">
            <label className="text-sm font-semibold text-slate-700">
              Search
              <input
                name="q"
                defaultValue={searchQuery}
                placeholder="Order, importer, amount, event, transfer ref"
                className="mt-1 w-full rounded-2xl border border-slate-200 bg-white px-3 py-2 text-sm text-slate-950 shadow-sm outline-none focus:border-sky-300 focus:ring-2 focus:ring-sky-100"
              />
            </label>

            <label className="text-sm font-semibold text-slate-700">
              Lane
              <select
                name="lane"
                defaultValue={lane}
                className="mt-1 w-full rounded-2xl border border-slate-200 bg-white px-3 py-2 text-sm text-slate-950 shadow-sm outline-none focus:border-sky-300 focus:ring-2 focus:ring-sky-100"
              >
                <option value="action_queue">Action queue</option>
                <option value="applied_settlement">Applied settlement</option>
                <option value="internal_transfer">Internal transfer</option>
                <option value="evidence">Evidence</option>
                <option value="all">All lanes</option>
              </select>
            </label>

            <label className="text-sm font-semibold text-slate-700">
              Status
              <select
                name="status"
                defaultValue={status}
                className="mt-1 w-full rounded-2xl border border-slate-200 bg-white px-3 py-2 text-sm text-slate-950 shadow-sm outline-none focus:border-sky-300 focus:ring-2 focus:ring-sky-100"
              >
                <option value="needs_action">Needs action</option>
                <option value="ready_to_materialise">Ready to materialise</option>
                <option value="ready_to_batch">Ready to batch</option>
                <option value="ready_to_post">Ready to post</option>
                <option value="blocked">Blocked</option>
                <option value="batched_or_posted">Batched / posted</option>
                <option value="all">All statuses</option>
              </select>
            </label>

            <div className="flex items-end">
              <button type="submit" className="w-full rounded-2xl bg-slate-950 px-4 py-2 text-sm font-bold text-white shadow-sm hover:bg-slate-800">
                Apply
              </button>
            </div>
          </form>
        </section>

        {showActionQueue ? (
          <CompletionLoyaltyActionQueuePanel searchQuery={searchQuery} statusFilter={status} />
        ) : null}

        {showAppliedSettlement ? (
          <CompletionLoyaltySagePostingMaterialisationPanel searchQuery={searchQuery} />
        ) : null}

        {showInternalTransfer ? (
          <CompletionLoyaltyInternalTransferJournalPanel searchQuery={searchQuery} />
        ) : null}

        {showEvidence ? (
          <section className="space-y-4">
            <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
              <div className="flex flex-wrap items-center justify-between gap-3">
                <div>
                  <p className="text-sm font-medium uppercase tracking-[0.18em] text-slate-500">Evidence filters</p>
                  <h2 className="mt-1 text-lg font-semibold text-slate-950">Read-only support views</h2>
                </div>
                <p className="text-sm text-slate-500">Evidence remains read-only; Step 3 actions are controlled by the posting lanes.</p>
              </div>
              <form className="mt-3 grid gap-3 md:grid-cols-[1fr_1fr_auto]" action="/internal/accounting-command-centre/loyalty-controls">
                <input type="hidden" name="q" value={searchQuery} />
                <input type="hidden" name="lane" value="evidence" />
                <input type="hidden" name="status" value={status} />
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
                    Apply evidence filters
                  </button>
                </div>
              </form>
            </div>

            <LoyaltyAccountingControlPanel searchQuery={searchQuery} categoryFilter={controlCategory} />
            <CompletionLoyaltyAppliedAccountingPreviewPanel searchQuery={searchQuery} previewStatusFilter={previewStatus} />
          </section>
        ) : null}

        <details className="rounded-3xl border border-amber-200 bg-amber-50 p-4 text-sm leading-6 text-amber-950">
          <summary className="cursor-pointer font-bold">Control boundary</summary>
          <p className="mt-2">
            Pending loyalty, staged main-bank OUT, and released unused loyalty must not create VAT timing or Sage posting. Only staff-applied loyalty creates the existing <code>credit_applied</code> order-funding event, which the VAT timing engine already understands.
          </p>
        </details>
      </div>
    </main>
  );
}
