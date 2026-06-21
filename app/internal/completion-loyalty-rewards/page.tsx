import type { ReactNode } from "react";
import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import {
  approveCompletionLoyaltyRewardAction,
  confirmCompletionLoyaltyRewardFundingAction,
} from "./actions";

type SearchParams = { success?: string; error?: string };
type BlockerDetails = Record<string, unknown>;

type WorkbenchRow = {
  order_id: string | null;
  approval_id: string | null;
  order_ref: string | null;
  proposal_status: string | null;
  completion_blocker: string | null;
  basis_blocker: string | null;
  qualifying_net_spend_gbp: number | string | null;
  suggested_reward_gbp: number | string | null;
  approval_status: string | null;
  approved_amount_gbp: number | string | null;
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

  if (missingCoding > 0) reasons.push(`Missing supplier accounting coding: ${missingCoding} line${missingCoding === 1 ? "" : "s"}`);
  if (defaultN > 0) reasons.push(`Unresolved default-N product treatment: ${defaultN} line${defaultN === 1 ? "" : "s"}`);
  if (adminReview > 0) reasons.push(`Admin review required: ${adminReview} line${adminReview === 1 ? "" : "s"}`);
  if (unresolvedFinancial > 0) reasons.push(`Unresolved financial treatment: ${unresolvedFinancial} line${unresolvedFinancial === 1 ? "" : "s"}`);
  if (openDisputes > 0) reasons.push(`Open dispute: ${openDisputes}`);
  if (activeHolds > 0) reasons.push(`Active hold: ${activeHolds}`);
  if (non20Rate > 0) reasons.push(`Non-20%/unknown tax rate: ${non20Rate} line${non20Rate === 1 ? "" : "s"}`);

  if (reasons.length > 0) return reasons.join(" · ");
  return friendly(row.approval_blocker || row.basis_blocker || row.completion_blocker || row.workbench_status);
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

  return steps.length > 0 ? steps.join(" ") : "Resolve the listed blocker, then refresh this page.";
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

function isProposed(row: WorkbenchRow) {
  return row.workbench_status === "proposed_pending_supervisor_review";
}

function isPendingFunding(row: WorkbenchRow) {
  return row.workbench_status === "approved_pending_funding";
}

function isReleased(row: WorkbenchRow) {
  return row.workbench_status === "dashboard_credit_released" || numeric(row.amount_released_gbp) > 0 || numeric(row.available_dashboard_credit_gbp) > 0;
}

function isBlocked(row: WorkbenchRow) {
  const status = row.workbench_status ?? "";
  return !isProposed(row) && !isPendingFunding(row) && !isReleased(row) && (status.includes("blocked") || status.includes("not_ready") || Boolean(row.completion_blocker) || Boolean(row.basis_blocker));
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

function AmountInput({ name, label, defaultValue, required = true }: { name: string; label: string; defaultValue?: string; required?: boolean }) {
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
  return (
    <form action={approveCompletionLoyaltyRewardAction} className="mt-5 rounded-2xl border border-amber-200 bg-amber-50 p-4">
      <input type="hidden" name="order_id" value={row.order_id ?? ""} />
      <h3 className="text-sm font-semibold text-amber-950">Record approval-in-principle</h3>
      <div className="mt-3 grid gap-3 md:grid-cols-2">
        <AmountInput name="approved_amount_gbp" label="Approved amount GBP" defaultValue={formatInputNumber(row.suggested_reward_gbp)} />
        <AmountInput name="reward_rate_pct" label="Reward rate percent" defaultValue="10.00" />
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

function FundingProofScript() {
  const script = `
    document.addEventListener('submit', function (event) {
      var form = event.target;
      if (!form || !form.matches || !form.matches('[data-funding-proof-form="true"]')) return;
      var dva = form.querySelector('[name="dva_statement_line_id"]');
      var evidence = form.querySelector('[name="funding_evidence_ref"]');
      if (!((dva && dva.value.trim()) || (evidence && evidence.value.trim()))) {
        event.preventDefault();
        if (evidence) evidence.setCustomValidity('Funding proof required: enter a DVA statement line ID or funding evidence reference.');
        if (evidence) evidence.reportValidity();
      } else if (evidence) {
        evidence.setCustomValidity('');
      }
    }, true);
    document.addEventListener('input', function (event) {
      var form = event.target && event.target.closest ? event.target.closest('[data-funding-proof-form="true"]') : null;
      if (!form) return;
      var evidence = form.querySelector('[name="funding_evidence_ref"]');
      if (evidence) evidence.setCustomValidity('');
    }, true);
  `;

  return <script dangerouslySetInnerHTML={{ __html: script }} />;
}

export default async function CompletionLoyaltyRewardsPage({ searchParams }: { searchParams?: Promise<SearchParams> }) {
  const params = searchParams ? await searchParams : {};
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
      count: rows.filter(isPendingFunding).length,
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
      <FundingProofScript />
      <div className="mb-6 flex flex-wrap items-center justify-between gap-3">
        <div>
          <Link href="/internal" className="text-sm font-medium text-slate-600 hover:text-slate-950">← Internal tools</Link>
          <h1 className="mt-3 text-3xl font-bold tracking-tight text-slate-950">Completion loyalty rewards</h1>
          <p className="mt-2 max-w-3xl text-sm text-slate-600">
            Supervisor lane for completion reward proposals, approval-in-principle, customer DVA/account funding proof and dashboard credit released controls.
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

      <section className="mt-8 space-y-5">
        {rows.length === 0 ? (
          <div className="rounded-2xl border border-slate-200 bg-white p-8 text-center text-sm text-slate-600">
            No completion loyalty reward rows are currently in the workbench.
          </div>
        ) : rows.map((row) => (
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
            {isPendingFunding(row) ? <FundingForm row={row} /> : null}
          </article>
        ))}
      </section>
    </main>
  );
}
