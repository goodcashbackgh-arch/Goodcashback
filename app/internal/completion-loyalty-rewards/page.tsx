import type { ReactNode } from "react";
import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import {
  approveCompletionLoyaltyRewardAction,
  applyCompletionLoyaltyToOrderAction,
  confirmCompletionLoyaltyRewardFundingAction,
} from "./actions";
import { WorkbenchClientEnhancements } from "./WorkbenchClientEnhancements";

type FilterStatus = "all" | "proposed" | "pending_funding" | "released" | "blocked";
type SearchParams = { success?: string; error?: string; status?: string; order_ref?: string };
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
  approval_id: string | null;
  approval_status: string | null;
  approved_amount_gbp: number | string | null;
  funding_confirmation_id?: string | null;
  funding_status: string | null;
  amount_funded_gbp: number | string | null;
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

type TargetOrder = {
  id: string;
  order_ref: string | null;
  importer_id: string | null;
  status: string | null;
  order_total_gbp_declared: number | string | null;
  created_at: string | null;
  remaining_due_gbp: number;
};

type FundingEventRow = {
  order_id: string | null;
  event_type: string | null;
  amount_gbp: number | string | null;
};

type SummaryCard = {
  label: string;
  count: number;
  detail: string;
  tone: "emerald" | "amber" | "sky" | "rose";
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

function formatInputNumber(value: number | string | null | undefined, fallback = "") {
  const parsed = numeric(value);
  if (parsed <= 0) return fallback;
  return parsed.toFixed(2);
}

function friendly(value: string | null | undefined) {
  if (!value) return "—";
  return value.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase());
}

function hasMeaningfulBlockerValue(value: string | null | undefined) {
  const raw = String(value ?? "").trim().toLowerCase();
  if (!raw) return false;
  return !["—", "-", "none", "null", "ready", "ok", "clear", "no_blocker"].includes(raw);
}

function detailText(row: WorkbenchRow, key: string) {
  const value = row.blocker_details_json?.[key];
  return typeof value === "string" ? value : "";
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

function blockerReason(row: WorkbenchRow) {
  const reasons: string[] = [];
  const settlementState = row.final_settlement_state || detailText(row, "final_settlement_state");
  const pendingCredit = numeric(row.potential_credit_pending_review_gbp);
  const missingCoding = detailNumber(row, "missing_accounting_coding_count");
  const defaultN = detailNumber(row, "unresolved_default_n_count");
  const adminReview = detailNumber(row, "admin_review_required_count");
  const unresolvedFinancial = detailNumber(row, "unresolved_financial_treatment_count");
  const openDisputes = detailNumber(row, "open_dispute_count");
  const activeHolds = detailNumber(row, "active_hold_count");
  const non20Rate = detailNumber(row, "non_20_rate_count");

  if (settlementState === "potential_credit_pending_review") {
    reasons.push(`Settlement surplus credit pending review${pendingCredit > 0 ? `: ${money(pendingCredit)}` : ""}`);
  } else if (settlementState && !["settled_nil", "credit_added_to_account"].includes(settlementState)) {
    reasons.push(`Final settlement state: ${friendly(settlementState)}`);
  }

  if (hasMeaningfulBlockerValue(row.completion_blocker)) reasons.push(`Completion blocker: ${friendly(row.completion_blocker)}`);
  if (hasMeaningfulBlockerValue(row.basis_blocker)) reasons.push(`Basis blocker: ${friendly(row.basis_blocker)}`);
  if (hasMeaningfulBlockerValue(row.approval_blocker)) reasons.push(`Approval blocker: ${friendly(row.approval_blocker)}`);
  if (missingCoding > 0) reasons.push(`Missing supplier accounting coding: ${missingCoding} line${missingCoding === 1 ? "" : "s"}`);
  if (defaultN > 0) reasons.push(`Unresolved default-N product treatment: ${defaultN} line${defaultN === 1 ? "" : "s"}`);
  if (adminReview > 0) reasons.push(`Admin review required: ${adminReview} line${adminReview === 1 ? "" : "s"}`);
  if (unresolvedFinancial > 0) reasons.push(`Unresolved financial treatment: ${unresolvedFinancial} line${unresolvedFinancial === 1 ? "" : "s"}`);
  if (openDisputes > 0) reasons.push(`Open dispute: ${openDisputes}`);
  if (activeHolds > 0) reasons.push(`Active hold: ${activeHolds}`);
  if (non20Rate > 0) reasons.push(`Non-20%/unknown tax rate: ${non20Rate} line${non20Rate === 1 ? "" : "s"}`);

  if (reasons.length > 0) return Array.from(new Set(reasons)).join(" · ");
  return friendly(row.workbench_status);
}

function blockerNextStep(row: WorkbenchRow) {
  const steps: string[] = [];
  const settlementState = row.final_settlement_state || detailText(row, "final_settlement_state");
  const missingCoding = detailNumber(row, "missing_accounting_coding_count");

  if (settlementState === "potential_credit_pending_review") {
    steps.push("Clear the surplus/settlement credit review first.");
  }
  if (missingCoding > 0) {
    steps.push("Complete supplier accounting coding on the reconciliation page.");
  }
  if (hasMeaningfulBlockerValue(row.completion_blocker)) {
    steps.push("Complete the order lifecycle requirement before funding/release.");
  }
  if (hasMeaningfulBlockerValue(row.basis_blocker)) {
    steps.push("Resolve the reward-basis blocker before funding/release.");
  }

  return steps.length > 0 ? steps.join(" ") : "Resolve the listed blocker, then refresh this page.";
}

function hasCurrentBasisBlocker(row: WorkbenchRow) {
  const settlementState = row.final_settlement_state || detailText(row, "final_settlement_state");
  const pendingCredit = numeric(row.potential_credit_pending_review_gbp);
  const settlementBlocked = Boolean(settlementState && !["settled_nil", "credit_added_to_account"].includes(settlementState));
  const countBlocked = [
    "missing_accounting_coding_count",
    "unresolved_default_n_count",
    "admin_review_required_count",
    "unresolved_financial_treatment_count",
    "open_dispute_count",
    "active_hold_count",
    "non_20_rate_count",
  ].some((key) => detailNumber(row, key) > 0);

  return Boolean(
    hasMeaningfulBlockerValue(row.completion_blocker) ||
    hasMeaningfulBlockerValue(row.basis_blocker) ||
    hasMeaningfulBlockerValue(row.approval_blocker) ||
    settlementBlocked ||
    pendingCredit > 0.01 ||
    countBlocked
  );
}

function statusClass(value: string | null | undefined) {
  const status = value ?? "";
  if (status.includes("released") || status.includes("funded") || status.includes("approved")) return "bg-emerald-100 text-emerald-800 ring-emerald-200";
  if (status.includes("pending") || status.includes("proposed")) return "bg-amber-100 text-amber-800 ring-amber-200";
  if (status.includes("blocked") || status.includes("not_ready") || status.includes("rejected")) return "bg-rose-100 text-rose-800 ring-rose-200";
  return "bg-slate-100 text-slate-700 ring-slate-200";
}

function summaryClass(tone: SummaryCard["tone"]) {
  if (tone === "emerald") return "border-emerald-200 bg-emerald-50 text-emerald-950";
  if (tone === "sky") return "border-sky-200 bg-sky-50 text-sky-950";
  if (tone === "rose") return "border-rose-200 bg-rose-50 text-rose-950";
  return "border-amber-200 bg-amber-50 text-amber-950";
}

function normalizeFilterStatus(value: string | null | undefined): FilterStatus {
  if (value === "proposed" || value === "pending_funding" || value === "released" || value === "blocked") return value;
  return "all";
}

function isProposed(row: WorkbenchRow) {
  return row.workbench_status === "proposed_pending_supervisor_review";
}

function isPendingFunding(row: WorkbenchRow) {
  return row.workbench_status === "approved_pending_funding";
}

function isReleased(row: WorkbenchRow) {
  return row.workbench_status === "dashboard_credit_released" || row.workbench_status === "released_available_dashboard_credit" || numeric(row.amount_released_gbp) > 0 || numeric(row.available_dashboard_credit_gbp) > 0;
}

function canConfirmFunding(row: WorkbenchRow) {
  return isPendingFunding(row) && !hasCurrentBasisBlocker(row);
}

function isBlocked(row: WorkbenchRow) {
  const status = row.workbench_status ?? "";
  return !isReleased(row) && (hasCurrentBasisBlocker(row) || status.includes("blocked") || status.includes("not_ready"));
}

function rowMatchesStatus(row: WorkbenchRow, status: FilterStatus) {
  if (status === "proposed") return isProposed(row);
  if (status === "pending_funding") return canConfirmFunding(row);
  if (status === "released") return isReleased(row);
  if (status === "blocked") return isBlocked(row);
  return true;
}

function rowMatchesOrderRef(row: WorkbenchRow, query: string) {
  const trimmed = query.trim().toLowerCase();
  if (!trimmed) return true;
  return String(row.order_ref ?? "").toLowerCase().includes(trimmed);
}

function field(label: string, value: ReactNode) {
  return (
    <div>
      <dt className="text-xs font-semibold uppercase tracking-wide text-slate-500">{label}</dt>
      <dd className="mt-1 text-sm text-slate-900">{value}</dd>
    </div>
  );
}

function TextInput({ name, label, defaultValue, required, placeholder }: { name: string; label: string; defaultValue?: string; required?: boolean; placeholder?: string }) {
  return (
    <label className="block text-sm font-medium text-slate-700">
      {label}
      <input
        name={name}
        defaultValue={defaultValue}
        required={required}
        placeholder={placeholder}
        className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-slate-900 focus:outline-none focus:ring-1 focus:ring-slate-900"
      />
    </label>
  );
}

function AmountInput({
  name,
  label,
  defaultValue,
  required = true,
  loyaltyField,
}: {
  name: string;
  label: string;
  defaultValue?: string;
  required?: boolean;
  loyaltyField?: "approved_amount" | "reward_rate";
}) {
  return (
    <label className="block text-sm font-medium text-slate-700">
      {label}
      <input
        type="number"
        name={name}
        min="0.01"
        step="0.01"
        defaultValue={defaultValue}
        required={required}
        data-loyalty-field={loyaltyField}
        className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-slate-900 focus:outline-none focus:ring-1 focus:ring-slate-900"
      />
    </label>
  );
}

function NotesInput() {
  return (
    <label className="block text-sm font-medium text-slate-700 md:col-span-2">
      Notes
      <textarea
        name="notes"
        rows={2}
        className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-slate-900 focus:outline-none focus:ring-1 focus:ring-slate-900"
      />
    </label>
  );
}

function ApprovalForm({ row }: { row: WorkbenchRow }) {
  const qualifyingNetSpend = numeric(row.qualifying_net_spend_gbp);

  return (
    <form
      action={approveCompletionLoyaltyRewardAction}
      data-loyalty-approval-form="true"
      data-qualifying-net-spend={qualifyingNetSpend.toFixed(2)}
      className="mt-5 rounded-2xl border border-amber-200 bg-amber-50 p-4"
    >
      <input type="hidden" name="order_id" value={row.order_id ?? ""} />
      <h3 className="text-sm font-semibold text-amber-950">Record approval-in-principle</h3>
      <p className="mt-1 text-xs text-amber-900">
        Amount and rate are linked to qualifying net spend ({money(row.qualifying_net_spend_gbp)}). Edit either field and the other recalculates before approval.
      </p>
      <div className="mt-3 grid gap-3 md:grid-cols-2">
        <AmountInput name="approved_amount_gbp" label="Approved amount GBP" defaultValue={formatInputNumber(row.suggested_reward_gbp)} loyaltyField="approved_amount" />
        <AmountInput name="reward_rate_pct" label="Reward rate percent" defaultValue="10.00" loyaltyField="reward_rate" />
        <NotesInput />
      </div>
      <button className="mt-4 rounded-lg bg-amber-900 px-4 py-2 text-sm font-semibold text-white hover:bg-amber-800">
        Approve in principle
      </button>
    </form>
  );
}

function FundingForm({ row }: { row: WorkbenchRow }) {
  return (
    <form action={confirmCompletionLoyaltyRewardFundingAction} data-funding-proof-form="true" className="mt-5 rounded-2xl border border-sky-200 bg-sky-50 p-4">
      <input type="hidden" name="approval_id" value={row.approval_id ?? ""} />
      <h3 className="text-sm font-semibold text-sky-950">Confirm customer DVA/account top-up</h3>
      <p className="mt-1 text-xs text-sky-900">Funding proof required before dashboard credit released.</p>
      <div className="mt-3 grid gap-3 md:grid-cols-2">
        <AmountInput name="amount_funded_gbp" label="Funded amount GBP" defaultValue={formatInputNumber(row.approved_amount_gbp)} />
        <AmountInput name="amount_released_gbp" label="Released amount GBP" defaultValue={formatInputNumber(row.approved_amount_gbp)} />
        <TextInput name="dva_statement_line_id" label="DVA statement line ID" placeholder="Optional when evidence reference is supplied" />
        <TextInput name="funding_evidence_ref" label="Funding evidence reference" placeholder="Optional when DVA statement line ID is supplied" />
        <NotesInput />
      </div>
      <button className="mt-4 rounded-lg bg-sky-900 px-4 py-2 text-sm font-semibold text-white hover:bg-sky-800">
        Confirm funding proof and release dashboard credit
      </button>
    </form>
  );
}

function ApplyLoyaltyForm({ row, targetOrders }: { row: WorkbenchRow; targetOrders: TargetOrder[] }) {
  const available = numeric(row.available_dashboard_credit_gbp);
  const options = targetOrders.filter((order) => order.importer_id === row.importer_id && order.id !== row.order_id && order.remaining_due_gbp > 0.01);

  if (available <= 0.01) return null;

  return (
    <form action={applyCompletionLoyaltyToOrderAction} className="mt-5 rounded-2xl border border-emerald-200 bg-emerald-50 p-4">
      <h3 className="text-sm font-semibold text-emerald-950">Apply loyalty to an order</h3>
      <p className="mt-1 text-xs text-emerald-900">
        This is a staff-only action. It applies released loyalty to the selected order and creates the proper credit-applied funding event.
      </p>
      <div className="mt-3 grid gap-3 md:grid-cols-2">
        <label className="block text-sm font-medium text-slate-700">
          Order to receive loyalty
          <select
            name="target_order_id"
            required
            className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-slate-900 focus:outline-none focus:ring-1 focus:ring-slate-900"
            defaultValue=""
          >
            <option value="">Select order</option>
            {options.map((order) => (
              <option key={order.id} value={order.id}>
                {order.order_ref ?? order.id} · due {money(order.remaining_due_gbp)}
              </option>
            ))}
          </select>
        </label>
        <AmountInput name="amount_gbp" label="Loyalty amount GBP" defaultValue={Math.min(available, options[0]?.remaining_due_gbp ?? available).toFixed(2)} />
        <NotesInput />
      </div>
      {options.length === 0 ? (
        <p className="mt-3 rounded-lg border border-amber-200 bg-amber-50 p-3 text-xs font-semibold text-amber-900">
          No open same-customer order balance is available for this loyalty reward.
        </p>
      ) : null}
      <button disabled={options.length === 0} className="mt-4 rounded-lg bg-emerald-900 px-4 py-2 text-sm font-semibold text-white hover:bg-emerald-800 disabled:bg-slate-200 disabled:text-slate-500">
        Apply loyalty to selected order
      </button>
    </form>
  );
}

function FundingBlockedNotice({ row }: { row: WorkbenchRow }) {
  return (
    <div className="mt-5 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-950">
      <p className="text-xs font-bold uppercase tracking-wide text-rose-700">Funding release blocked</p>
      <p className="mt-1 font-semibold">Approved earlier, but the current reward basis is now blocked.</p>
      <p className="mt-2 text-xs leading-5">{blockerReason(row)}</p>
      <p className="mt-2 text-xs leading-5">Next step: {blockerNextStep(row)}</p>
    </div>
  );
}

function ReleasedWithBlockerNotice({ row }: { row: WorkbenchRow }) {
  if (!hasCurrentBasisBlocker(row)) return null;
  return (
    <div className="mt-5 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-950">
      <p className="text-xs font-bold uppercase tracking-wide text-amber-700">Existing released loyalty credit</p>
      <p className="mt-1 font-semibold">This credit already exists, but the current reward basis still shows blockers. Apply only if you intend to consume this already-released credit.</p>
      <p className="mt-2 text-xs leading-5">Current blocker: {blockerReason(row)}</p>
    </div>
  );
}

export default async function CompletionLoyaltyRewardsPage({ searchParams }: { searchParams?: Promise<SearchParams> }) {
  const params = searchParams ? await searchParams : {};
  const filterStatus = normalizeFilterStatus(params.status);
  const orderRefQuery = (params.order_ref ?? "").trim();
  const filterActive = filterStatus !== "all" || orderRefQuery.length > 0;
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
    (supabase as any).rpc("internal_completion_loyalty_reward_funding_workbench_v1", {
      p_order_id: null,
    }),
    (supabase as any).rpc("internal_completion_loyalty_reward_proposals_v1", {
      p_order_id: null,
    }),
    (supabase as any).rpc("internal_order_final_sale_settlement_v1", {
      p_order_id: null,
    }),
  ]);

  const proposalByOrderId = new Map<string, ProposalRow>();
  for (const row of (proposalsResult.data ?? []) as ProposalRow[]) {
    if (row.order_id) proposalByOrderId.set(row.order_id, row);
  }

  const settlementByOrderId = new Map<string, SettlementRow>();
  for (const row of (settlementResult.data ?? []) as SettlementRow[]) {
    if (row.order_id) settlementByOrderId.set(row.order_id, row);
  }

  const rows = ((workbenchResult.data ?? []) as WorkbenchRow[]).map((row) => {
    const proposal = row.order_id ? proposalByOrderId.get(row.order_id) : null;
    const settlement = row.order_id ? settlementByOrderId.get(row.order_id) : null;
    return {
      ...row,
      approval_blocker: row.approval_blocker ?? proposal?.approval_blocker ?? null,
      final_settlement_state: row.final_settlement_state ?? proposal?.final_settlement_state ?? null,
      potential_credit_pending_review_gbp: row.potential_credit_pending_review_gbp ?? settlement?.potential_credit_pending_review_gbp ?? null,
      blocker_details_json: row.blocker_details_json ?? proposal?.blocker_details_json ?? null,
    };
  });

  const importerIds = Array.from(new Set(rows.map((row) => row.importer_id).filter(Boolean))) as string[];
  const { data: targetOrderRows } = importerIds.length
    ? await supabase
        .from("orders")
        .select("id, order_ref, importer_id, status, order_total_gbp_declared, created_at")
        .in("importer_id", importerIds)
        .order("created_at", { ascending: false })
    : { data: [] };

  const targetOrderIds = ((targetOrderRows ?? []) as TargetOrder[]).map((order) => order.id);
  const { data: targetFundingEvents } = targetOrderIds.length
    ? await supabase
        .from("order_funding_events")
        .select("order_id, event_type, amount_gbp")
        .in("order_id", targetOrderIds)
        .in("event_type", ["funding_contribution", "credit_applied", "manual_adjustment", "funding_reversed"])
    : { data: [] };

  const targetFundingByOrder = new Map<string, number>();
  for (const event of (targetFundingEvents ?? []) as FundingEventRow[]) {
    const orderId = event.order_id ?? "";
    if (!orderId) continue;
    const amount = numeric(event.amount_gbp);
    const current = targetFundingByOrder.get(orderId) ?? 0;
    if (event.event_type === "funding_reversed") targetFundingByOrder.set(orderId, current - Math.abs(amount));
    else targetFundingByOrder.set(orderId, current + Math.abs(amount));
  }

  const targetOrders: TargetOrder[] = ((targetOrderRows ?? []) as TargetOrder[])
    .map((order) => {
      const declared = numeric(order.order_total_gbp_declared);
      const funded = targetFundingByOrder.get(order.id) ?? 0;
      return { ...order, remaining_due_gbp: Math.max(declared - funded, 0) };
    })
    .filter((order) => order.remaining_due_gbp > 0.01 && !String(order.status ?? "").toLowerCase().includes("cancelled"));

  const filteredRows = rows.filter((row) => rowMatchesStatus(row, filterStatus) && rowMatchesOrderRef(row, orderRefQuery));

  const error = workbenchResult.error;
  const detailError = proposalsResult.error || settlementResult.error;

  const cards: SummaryCard[] = [
    {
      label: "Reward-ready proposals",
      count: rows.filter(isProposed).length,
      detail: "Awaiting supervisor approval-in-principle.",
      tone: "amber",
    },
    {
      label: "Approved pending funding",
      count: rows.filter(canConfirmFunding).length,
      detail: "Funding proof required for customer DVA/account top-up.",
      tone: "sky",
    },
    {
      label: "Released dashboard credit",
      count: rows.filter(isReleased).length,
      detail: `${money(rows.reduce((total, row) => total + numeric(row.amount_released_gbp), 0))} released to dashboard credit.`,
      tone: "emerald",
    },
    {
      label: "Blocked / not ready",
      count: rows.filter(isBlocked).length,
      detail: "Completion or reward basis blocker needs review.",
      tone: "rose",
    },
  ];

  return (
    <main className="mx-auto max-w-7xl px-6 py-10">
      <WorkbenchClientEnhancements />
      <div className="mb-6 flex flex-wrap items-center justify-between gap-3">
        <div>
          <Link href="/internal" className="text-sm font-medium text-slate-600 hover:text-slate-950">← Internal tools</Link>
          <h1 className="mt-3 text-3xl font-bold tracking-tight text-slate-950">Completion loyalty rewards</h1>
          <p className="mt-2 max-w-3xl text-sm text-slate-600">
            Supervisor lane for completion reward proposals, approval-in-principle, DVA/account funding proof, released dashboard credit, and staff-only application to an order balance.
          </p>
          <p className="mt-2 text-sm text-slate-500">Signed in as {staff.full_name ?? "staff"} · {staff.role_type}</p>
        </div>
      </div>

      {params.success ? <div className="mb-5 rounded-2xl border border-emerald-200 bg-emerald-50 p-4 text-sm font-medium text-emerald-900">{params.success}</div> : null}
      {params.error ? <div className="mb-5 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-medium text-rose-900">{params.error}</div> : null}
      {error ? <div className="mb-5 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-medium text-rose-900">{error.message}</div> : null}
      {detailError ? <div className="mb-5 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm font-medium text-amber-900">Detailed blocker read unavailable: {detailError.message}</div> : null}

      <section className="grid gap-4 md:grid-cols-4">
        {cards.map((card) => (
          <div key={card.label} className={`rounded-2xl border p-5 ${summaryClass(card.tone)}`}>
            <p className="text-sm font-medium">{card.label}</p>
            <p className="mt-2 text-3xl font-bold">{card.count}</p>
            <p className="mt-2 text-xs opacity-80">{card.detail}</p>
          </div>
        ))}
      </section>

      <form method="get" className="mt-6 rounded-2xl border border-slate-200 bg-white p-4 shadow-sm">
        <div className="grid gap-3 md:grid-cols-[220px_1fr_auto_auto] md:items-end">
          <label className="block text-sm font-medium text-slate-700">
            Status
            <select
              name="status"
              defaultValue={filterStatus}
              className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-slate-900 focus:outline-none focus:ring-1 focus:ring-slate-900"
            >
              <option value="all">All statuses</option>
              <option value="proposed">Reward-ready proposals</option>
              <option value="pending_funding">Approved pending funding</option>
              <option value="released">Released dashboard credit</option>
              <option value="blocked">Blocked / not ready</option>
            </select>
          </label>
          <label className="block text-sm font-medium text-slate-700">
            Order reference
            <input
              name="order_ref"
              defaultValue={orderRefQuery}
              placeholder="e.g. ORD-1777620991295"
              className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-slate-900 focus:outline-none focus:ring-1 focus:ring-slate-900"
            />
          </label>
          <button className="rounded-lg bg-slate-950 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800">Apply filter</button>
          {filterActive ? (
            <Link href="/internal/completion-loyalty-rewards" className="rounded-lg border border-slate-300 px-4 py-2 text-center text-sm font-semibold text-slate-700 hover:bg-slate-50">
              Clear
            </Link>
          ) : null}
        </div>
        <p className="mt-3 text-xs text-slate-500">
          Showing {filteredRows.length} of {rows.length} loyalty reward rows.
        </p>
      </form>

      <section className="mt-8 space-y-5">
        {filteredRows.length === 0 ? (
          <div className="rounded-2xl border border-slate-200 bg-white p-8 text-center text-sm text-slate-600">
            {rows.length === 0 ? "No completion loyalty reward rows are currently in the workbench." : "No completion loyalty reward rows match this filter."}
          </div>
        ) : filteredRows.map((row) => {
          const currentBasisBlocked = hasCurrentBasisBlocker(row);
          return (
          <article key={`${row.order_id ?? row.order_ref}-${row.approval_id ?? "proposal"}`} className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm">
            <div className="flex flex-wrap items-start justify-between gap-3">
              <div>
                <h2 className="text-lg font-semibold text-slate-950">{row.order_ref ?? "Unknown order"}</h2>
                <div className="mt-2 flex flex-wrap gap-2">
                  <span className={`rounded-full px-2.5 py-1 text-xs font-semibold ring-1 ${statusClass(row.workbench_status)}`}>{friendly(row.workbench_status)}</span>
                  <span className={`rounded-full px-2.5 py-1 text-xs font-semibold ring-1 ${statusClass(row.proposal_status)}`}>Proposal: {friendly(row.proposal_status)}</span>
                  <span className={`rounded-full px-2.5 py-1 text-xs font-semibold ring-1 ${statusClass(row.approval_status)}`}>Approval: {friendly(row.approval_status)}</span>
                  <span className={`rounded-full px-2.5 py-1 text-xs font-semibold ring-1 ${statusClass(row.funding_status)}`}>Funding: {friendly(row.funding_status)}</span>
                </div>
              </div>
            </div>

            {isBlocked(row) ? (
              <div className="mt-4 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-950">
                <p className="text-xs font-bold uppercase tracking-wide text-rose-700">Why blocked</p>
                <p className="mt-1 font-semibold">{blockerReason(row)}</p>
                <p className="mt-2 text-xs leading-5 text-rose-900">Next step: {blockerNextStep(row)}</p>
              </div>
            ) : null}

            <dl className="mt-5 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
              {field("Completion blocker", row.completion_blocker ?? "—")}
              {field("Basis blocker", row.basis_blocker ?? "—")}
              {field("Settlement state", friendly(row.final_settlement_state))}
              {field("Pending settlement credit", money(row.potential_credit_pending_review_gbp))}
              {field("Qualifying net spend", money(row.qualifying_net_spend_gbp))}
              {field("Suggested reward", money(row.suggested_reward_gbp))}
              {field("Approved amount", money(row.approved_amount_gbp))}
              {field("Funded amount", money(row.amount_funded_gbp))}
              {field("Released amount", money(row.amount_released_gbp))}
              {field("Available dashboard credit", money(row.available_dashboard_credit_gbp))}
            </dl>

            {isProposed(row) ? <ApprovalForm row={row} /> : null}
            {isPendingFunding(row) && currentBasisBlocked ? <FundingBlockedNotice row={row} /> : null}
            {canConfirmFunding(row) ? <FundingForm row={row} /> : null}
            {isReleased(row) ? <ReleasedWithBlockerNotice row={row} /> : null}
            {isReleased(row) ? <ApplyLoyaltyForm row={row} targetOrders={targetOrders} /> : null}
          </article>
        );
        })}
      </section>
    </main>
  );
}
