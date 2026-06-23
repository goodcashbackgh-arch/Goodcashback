import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { rejectCompletionLoyaltyRewardAction } from "../rejectActions";

type SearchParams = { success?: string; error?: string; q?: string };
type BlockerDetails = Record<string, unknown>;

type WorkbenchRow = {
  order_id: string | null;
  order_ref: string | null;
  importer_id: string | null;
  proposal_status: string | null;
  completion_blocker: string | null;
  basis_blocker: string | null;
  qualifying_net_spend_gbp: number | string | null;
  suggested_reward_gbp: number | string | null;
  approval_status: string | null;
  approved_amount_gbp: number | string | null;
  amount_released_gbp: number | string | null;
  available_dashboard_credit_gbp: number | string | null;
  workbench_status: string | null;
  approval_blocker?: string | null;
  final_settlement_state?: string | null;
  potential_credit_pending_review_gbp?: number | string | null;
  blocker_details_json?: BlockerDetails | null;
};

type ProposalRow = {
  order_id: string | null;
  approval_blocker: string | null;
  final_settlement_state: string | null;
  blocker_details_json: BlockerDetails | null;
};

type SettlementRow = {
  order_id: string | null;
  potential_credit_pending_review_gbp: number | string | null;
};

function numeric(value: number | string | null | undefined) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

function money(value: number | string | null | undefined) {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" }).format(numeric(value));
}

function friendly(value: string | null | undefined) {
  if (!value) return "—";
  return value.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase());
}

function text(value: unknown) {
  if (Array.isArray(value)) return text(value[0]);
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return "";
}

function detailNumber(row: WorkbenchRow, key: string) {
  const value = row.blocker_details_json?.[key];
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

function hasMeaningfulBlockerValue(value: string | null | undefined) {
  const raw = String(value ?? "").trim().toLowerCase();
  if (!raw) return false;
  return !["—", "-", "none", "null", "ready", "ok", "clear", "no_blocker"].includes(raw);
}

function rowIsReleased(row: WorkbenchRow) {
  return row.workbench_status === "dashboard_credit_released" || row.workbench_status === "released_available_dashboard_credit" || numeric(row.amount_released_gbp) > 0 || numeric(row.available_dashboard_credit_gbp) > 0;
}

function rowIsAlreadyRejected(row: WorkbenchRow) {
  return String(row.proposal_status ?? "").toLowerCase().includes("rejected");
}

function blockerSummary(row: WorkbenchRow) {
  const parts: string[] = [];
  if (hasMeaningfulBlockerValue(row.completion_blocker)) parts.push(`Completion: ${friendly(row.completion_blocker)}`);
  if (hasMeaningfulBlockerValue(row.basis_blocker)) parts.push(`Basis: ${friendly(row.basis_blocker)}`);
  if (hasMeaningfulBlockerValue(row.approval_blocker)) parts.push(`Approval: ${friendly(row.approval_blocker)}`);
  if (row.final_settlement_state) parts.push(`Settlement: ${friendly(row.final_settlement_state)}`);
  const pendingCredit = numeric(row.potential_credit_pending_review_gbp);
  if (pendingCredit > 0.01) parts.push(`Pending settlement credit ${money(pendingCredit)}`);
  const openDisputes = detailNumber(row, "open_dispute_count");
  if (openDisputes > 0) parts.push(`Open disputes ${openDisputes}`);
  return parts.length ? Array.from(new Set(parts)).join(" · ") : "No blocker captured in the read model.";
}

function statusClass(value: string | null | undefined) {
  const status = String(value ?? "").toLowerCase();
  if (status.includes("released")) return "bg-emerald-100 text-emerald-800 ring-emerald-200";
  if (status.includes("pending") || status.includes("proposed") || status.includes("approved")) return "bg-amber-100 text-amber-800 ring-amber-200";
  if (status.includes("blocked") || status.includes("not_ready") || status.includes("rejected")) return "bg-rose-100 text-rose-800 ring-rose-200";
  return "bg-slate-100 text-slate-700 ring-slate-200";
}

function RejectionForm({ row }: { row: WorkbenchRow }) {
  return (
    <form action={rejectCompletionLoyaltyRewardAction} className="mt-4 rounded-2xl border border-rose-200 bg-rose-50 p-4">
      <input type="hidden" name="order_id" value={row.order_id ?? ""} />
      <h3 className="text-sm font-semibold text-rose-950">Reject loyalty in principle</h3>
      <p className="mt-1 text-xs leading-5 text-rose-900">
        Use this only before dashboard credit is released. It records an active rejection and prevents customer-facing pending loyalty for this order.
      </p>
      <div className="mt-3 grid gap-3 md:grid-cols-2">
        <label className="block text-sm font-medium text-slate-700">
          Reason
          <select name="rejection_reason_code" required className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-slate-900 focus:outline-none focus:ring-1 focus:ring-slate-900">
            <option value="">Select reason</option>
            <option value="not_commercially_appropriate">Not commercially appropriate</option>
            <option value="customer_not_eligible">Customer not eligible</option>
            <option value="basis_not_clean">Reward basis not clean</option>
            <option value="settlement_credit_pending">Settlement credit pending review</option>
            <option value="manual_supervisor_decision">Manual supervisor decision</option>
          </select>
        </label>
        <label className="block text-sm font-medium text-slate-700 md:col-span-2">
          Notes
          <textarea name="notes" rows={2} className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-slate-900 focus:outline-none focus:ring-1 focus:ring-slate-900" />
        </label>
      </div>
      <button className="mt-4 rounded-lg bg-rose-900 px-4 py-2 text-sm font-semibold text-white hover:bg-rose-800">
        Reject reward in principle
      </button>
    </form>
  );
}

export default async function CompletionLoyaltyRejectionsPage({ searchParams }: { searchParams?: Promise<SearchParams> }) {
  const params = searchParams ? await searchParams : {};
  const q = (params.q ?? "").trim().toLowerCase();
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) redirect("/login");

  const { data: staff } = await supabase
    .from("staff")
    .select("id, full_name, role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!staff) redirect("/auth/check");
  if (!["admin", "supervisor"].includes(String(staff.role_type))) redirect("/internal");

  const [workbenchResult, proposalsResult, settlementResult] = await Promise.all([
    (supabase as any).rpc("internal_completion_loyalty_reward_funding_workbench_v1", { p_order_id: null }),
    (supabase as any).rpc("internal_completion_loyalty_reward_proposals_v1", { p_order_id: null }),
    (supabase as any).rpc("internal_order_final_sale_settlement_v1", { p_order_id: null }),
  ]);

  const proposalByOrderId = new Map<string, ProposalRow>();
  for (const row of (proposalsResult.data ?? []) as ProposalRow[]) {
    if (row.order_id) proposalByOrderId.set(row.order_id, row);
  }

  const settlementByOrderId = new Map<string, SettlementRow>();
  for (const row of (settlementResult.data ?? []) as SettlementRow[]) {
    if (row.order_id) settlementByOrderId.set(row.order_id, row);
  }

  const rows = ((workbenchResult.data ?? []) as WorkbenchRow[])
    .map((row) => {
      const proposal = row.order_id ? proposalByOrderId.get(row.order_id) : null;
      const settlement = row.order_id ? settlementByOrderId.get(row.order_id) : null;
      return {
        ...row,
        approval_blocker: row.approval_blocker ?? proposal?.approval_blocker ?? null,
        final_settlement_state: row.final_settlement_state ?? proposal?.final_settlement_state ?? null,
        potential_credit_pending_review_gbp: row.potential_credit_pending_review_gbp ?? settlement?.potential_credit_pending_review_gbp ?? null,
        blocker_details_json: row.blocker_details_json ?? proposal?.blocker_details_json ?? null,
      };
    })
    .filter((row) => row.order_id)
    .filter((row) => !rowIsReleased(row));

  const filteredRows = rows.filter((row) => {
    if (!q) return true;
    return String(row.order_ref ?? "").toLowerCase().includes(q) || String(row.workbench_status ?? "").toLowerCase().includes(q) || String(row.proposal_status ?? "").toLowerCase().includes(q);
  });

  const error = workbenchResult.error || proposalsResult.error || settlementResult.error;

  return (
    <main className="mx-auto max-w-7xl px-6 py-10">
      <div className="mb-6 flex flex-wrap items-center justify-between gap-3">
        <div>
          <Link href="/internal/completion-loyalty-rewards" className="text-sm font-medium text-slate-600 hover:text-slate-950">← Completion loyalty rewards</Link>
          <h1 className="mt-3 text-3xl font-bold tracking-tight text-slate-950">Reject completion loyalty rewards</h1>
          <p className="mt-2 max-w-3xl text-sm text-slate-600">
            Supervisor control for recording reward rejections before dashboard credit is released. Released credit cannot be rejected here and must be reversed or locked first.
          </p>
          <p className="mt-2 text-sm text-slate-500">Signed in as {staff.full_name ?? "staff"} · {staff.role_type}</p>
        </div>
      </div>

      {params.success ? <div className="mb-5 rounded-2xl border border-emerald-200 bg-emerald-50 p-4 text-sm font-medium text-emerald-900">{params.success}</div> : null}
      {params.error ? <div className="mb-5 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-medium text-rose-900">{params.error}</div> : null}
      {error ? <div className="mb-5 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-medium text-rose-900">{error.message}</div> : null}

      <form method="get" className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm">
        <div className="grid gap-3 md:grid-cols-[1fr_auto] md:items-end">
          <label className="block text-sm font-medium text-slate-700">
            Search
            <input name="q" defaultValue={params.q ?? ""} placeholder="Order ref or status" className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-slate-900 focus:outline-none focus:ring-1 focus:ring-slate-900" />
          </label>
          <button className="rounded-lg bg-slate-950 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800">Apply filter</button>
        </div>
        <p className="mt-3 text-xs text-slate-500">Showing {filteredRows.length} rejectable rows. Released rows are excluded.</p>
      </form>

      <section className="mt-8 space-y-5">
        {filteredRows.length === 0 ? (
          <div className="rounded-2xl border border-slate-200 bg-white p-8 text-center text-sm text-slate-600">
            No non-released completion loyalty rows match this filter.
          </div>
        ) : filteredRows.map((row) => (
          <article key={`${row.order_id ?? row.order_ref}-reject`} className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm">
            <div className="flex flex-wrap items-start justify-between gap-3">
              <div>
                <h2 className="text-lg font-semibold text-slate-950">{row.order_ref ?? "Unknown order"}</h2>
                <div className="mt-2 flex flex-wrap gap-2">
                  <span className={`rounded-full px-2.5 py-1 text-xs font-semibold ring-1 ${statusClass(row.workbench_status)}`}>{friendly(row.workbench_status)}</span>
                  <span className={`rounded-full px-2.5 py-1 text-xs font-semibold ring-1 ${statusClass(row.proposal_status)}`}>Proposal: {friendly(row.proposal_status)}</span>
                  <span className={`rounded-full px-2.5 py-1 text-xs font-semibold ring-1 ${statusClass(row.approval_status)}`}>Approval: {friendly(row.approval_status)}</span>
                </div>
              </div>
              {rowIsAlreadyRejected(row) ? <span className="rounded-full bg-rose-100 px-3 py-1 text-xs font-bold text-rose-800 ring-1 ring-rose-200">Already rejected</span> : null}
            </div>

            <dl className="mt-5 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
              <div><dt className="text-xs font-semibold uppercase tracking-wide text-slate-500">Qualifying net spend</dt><dd className="mt-1 text-sm text-slate-900">{money(row.qualifying_net_spend_gbp)}</dd></div>
              <div><dt className="text-xs font-semibold uppercase tracking-wide text-slate-500">Suggested reward</dt><dd className="mt-1 text-sm text-slate-900">{money(row.suggested_reward_gbp)}</dd></div>
              <div><dt className="text-xs font-semibold uppercase tracking-wide text-slate-500">Approved amount</dt><dd className="mt-1 text-sm text-slate-900">{money(row.approved_amount_gbp)}</dd></div>
              <div><dt className="text-xs font-semibold uppercase tracking-wide text-slate-500">Current blocker</dt><dd className="mt-1 text-sm text-slate-900">{blockerSummary(row)}</dd></div>
            </dl>

            {rowIsAlreadyRejected(row) ? (
              <div className="mt-4 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-950">
                This order already has an active rejection recorded. Re-running the form would update the active rejection reason and notes.
              </div>
            ) : null}

            <RejectionForm row={row} />
          </article>
        ))}
      </section>
    </main>
  );
}
