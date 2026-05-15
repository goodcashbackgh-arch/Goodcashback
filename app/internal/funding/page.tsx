import Link from "next/link";
import { createClient } from "@/utils/supabase/server";
import {
  applyImporterCreditAction,
  reconcileDvaLineToOrderAction,
} from "./actions";

type DataRow = Record<string, unknown>;

type PanelResult = {
  title: string;
  description: string;
  source: string;
  role: string;
  rows: DataRow[];
  error: string | null;
};

const panels = [
  {
    title: "DVA review worklist",
    description: "Primary staff worklist for inbound customer/importer funding lines that can be matched to orders.",
    source: "day2_dva_review_worklist_vw",
    role: "Funding match source",
  },
  {
    title: "Order funding positions",
    description: "Orders with funding gaps, funded totals, credit application status, and funded-at signals.",
    source: "order_funding_position_vw",
    role: "Order funding source",
  },
  {
    title: "Importer credit balances",
    description: "Available importer credit that can be applied to order funding gaps.",
    source: "importer_balance_vw",
    role: "Credit source",
  },
  {
    title: "Recent DVA lines",
    description: "Raw DVA statement lines. Diagnostic only; normal matching should use the DVA review worklist.",
    source: "dva_statement_lines",
    role: "Diagnostic only",
  },
  {
    title: "Recent funding events",
    description: "Immutable funding events created by DVA reconciliation, importer credit, or adjustments.",
    source: "order_funding_events",
    role: "Audit trail",
  },
] as const;

const preferredBySource: Record<string, string[]> = {
  day2_dva_review_worklist_vw: [
    "importer_name",
    "company_name",
    "trading_name",
    "order_ref",
    "payment_auth_id",
    "auth_id_ref",
    "reference_raw",
    "match_status",
    "amount_gbp_equivalent",
    "reconciled_gbp_amount",
    "created_at",
    "reconciled_at",
  ],
  order_funding_position_vw: [
    "order_ref",
    "payment_auth_id",
    "status",
    "order_total_gbp_declared",
    "funded_total_gbp",
    "gap_remaining_gbp",
    "available_credit_gbp",
    "threshold_met_yn",
    "already_funded_yn",
    "funded_at",
    "created_at",
  ],
  importer_balance_vw: [
    "importer_id",
    "available_credit_gbp",
    "pending_refund_gbp",
    "active_order_funding_gbp",
    "payout_in_progress_gbp",
    "last_refreshed_at",
  ],
  dva_statement_lines: [
    "statement_date",
    "reference_raw",
    "auth_id_ref",
    "direction",
    "amount_local_ccy",
    "local_ccy",
    "amount_gbp_equivalent",
    "match_status",
    "created_at",
  ],
  order_funding_events: [
    "order_ref",
    "event_type",
    "amount_gbp",
    "resulting_funded_total_gbp",
    "source_table",
    "source_entity_id",
    "notes",
    "created_at",
  ],
};

const gbpFormatter = new Intl.NumberFormat("en-GB", {
  style: "currency",
  currency: "GBP",
  minimumFractionDigits: 2,
});

function formatValue(value: unknown) {
  if (value === null || value === undefined) return "—";
  if (typeof value === "boolean") return value ? "Yes" : "No";
  if (typeof value === "number") return value.toLocaleString("en-GB");
  if (typeof value === "string") {
    if (value.length > 90) return `${value.slice(0, 87)}...`;
    return value;
  }
  return JSON.stringify(value);
}

function asNumber(value: unknown) {
  if (typeof value === "number") return value;
  if (typeof value === "string" && value.trim() !== "") {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

function asString(value: unknown) {
  return typeof value === "string" ? value : "";
}

function asBoolean(value: unknown) {
  if (typeof value === "boolean") return value;
  if (typeof value === "string") return value.toLowerCase() === "true";
  return false;
}

function gbp(value: unknown) {
  return gbpFormatter.format(asNumber(value));
}

function allColumns(rows: DataRow[]) {
  return Array.from(new Set(rows.flatMap((row) => Object.keys(row))));
}

function visibleColumns(source: string, rows: DataRow[]) {
  const present = new Set(allColumns(rows));
  const preferred = preferredBySource[source] ?? [];
  const selected = preferred.filter((key) => present.has(key));

  if (selected.length > 0) return selected.slice(0, 10);
  return Object.keys(rows[0] ?? {}).slice(0, 10);
}

async function readPanel(source: string): Promise<Omit<PanelResult, "title" | "description" | "role">> {
  const supabase = await createClient();
  const { data, error } = await supabase.from(source).select("*").limit(10);

  return {
    source,
    rows: (data ?? []) as DataRow[],
    error: error?.message ?? null,
  };
}

function SummaryCard({
  title,
  value,
  hint,
  tone = "slate",
}: {
  title: string;
  value: string;
  hint: string;
  tone?: "slate" | "emerald" | "sky" | "amber" | "rose" | "violet";
}) {
  const toneClass = {
    slate: "bg-slate-50 text-slate-950 ring-slate-200",
    emerald: "bg-emerald-50 text-emerald-950 ring-emerald-200",
    sky: "bg-sky-50 text-sky-950 ring-sky-200",
    amber: "bg-amber-50 text-amber-950 ring-amber-200",
    rose: "bg-rose-50 text-rose-950 ring-rose-200",
    violet: "bg-violet-50 text-violet-950 ring-violet-200",
  }[tone];

  return (
    <div className={`rounded-2xl p-4 ring-1 ${toneClass}`}>
      <p className="text-xs font-bold uppercase tracking-wide opacity-70">{title}</p>
      <p className="mt-2 text-2xl font-semibold">{value}</p>
      <p className="mt-1 text-xs leading-5 opacity-75">{hint}</p>
    </div>
  );
}

function RouteCard({ title, body, href, cta }: { title: string; body: string; href: string; cta: string }) {
  return (
    <Link href={href} className="rounded-2xl border border-slate-200 bg-slate-50 p-4 transition hover:bg-white">
      <h3 className="text-sm font-bold text-slate-950">{title}</h3>
      <p className="mt-2 text-xs leading-5 text-slate-600">{body}</p>
      <p className="mt-3 text-xs font-extrabold uppercase tracking-wide text-sky-700">{cta} →</p>
    </Link>
  );
}

function CreditCandidateCard({ candidate }: { candidate: {
  importerId: string;
  orderId: string;
  orderRef: string;
  paymentAuthId: string;
  status: string;
  gap: number;
  availableCredit: number;
  maxApplyAmount: number;
  alreadyFunded: boolean;
  canApply: boolean;
} }) {
  return (
    <article className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <p className="text-xs font-bold uppercase tracking-wide text-amber-600">Importer credit → order gap</p>
          <h3 className="mt-2 text-lg font-semibold">{candidate.orderRef || "No order ref"}</h3>
          <p className="mt-1 text-xs text-slate-500">Auth: {candidate.paymentAuthId || "—"} · Status: {candidate.status || "—"}</p>
        </div>
        <span className={`rounded-full px-3 py-1 text-xs font-semibold ${candidate.canApply ? "bg-emerald-50 text-emerald-700 ring-1 ring-emerald-200" : "bg-slate-100 text-slate-600 ring-1 ring-slate-200"}`}>
          {candidate.canApply ? "credit available" : "no action"}
        </span>
      </div>

      <div className="mt-4 grid gap-3 sm:grid-cols-3">
        <SummaryCard title="Funding gap" value={gbp(candidate.gap)} hint="Remaining order funding gap." tone={candidate.gap > 0 ? "amber" : "emerald"} />
        <SummaryCard title="Available credit" value={gbp(candidate.availableCredit)} hint="Importer credit available to apply." tone={candidate.availableCredit > 0 ? "sky" : "slate"} />
        <SummaryCard title="Max apply" value={gbp(candidate.maxApplyAmount)} hint="Capped at lower of gap and credit." tone={candidate.maxApplyAmount > 0 ? "emerald" : "slate"} />
      </div>

      <form action={applyImporterCreditAction} className="mt-4 flex flex-wrap items-center gap-2">
        <input type="hidden" name="importer_id" value={candidate.importerId} />
        <input type="hidden" name="order_id" value={candidate.orderId} />
        <input
          name="amount_gbp"
          type="number"
          step="0.01"
          min="0.01"
          max={candidate.maxApplyAmount > 0 ? candidate.maxApplyAmount : undefined}
          defaultValue={candidate.maxApplyAmount > 0 ? candidate.maxApplyAmount.toFixed(2) : ""}
          disabled={!candidate.canApply}
          className="w-32 rounded-xl border border-slate-300 px-3 py-2 text-sm disabled:bg-slate-100"
        />
        <button type="submit" disabled={!candidate.canApply} className="rounded-xl bg-amber-600 px-4 py-2 text-sm font-semibold text-white disabled:cursor-not-allowed disabled:bg-slate-300">
          Apply credit
        </button>
        {!candidate.canApply ? (
          <p className="text-xs text-slate-500">
            {candidate.alreadyFunded ? "No funding gap." : candidate.availableCredit <= 0 ? "No available credit." : "Cannot apply credit."}
          </p>
        ) : null}
      </form>
    </article>
  );
}

function DvaFundingCandidateCard({ candidate }: { candidate: {
  dvaStatementLineId: string;
  orderId: string;
  orderRef: string;
  matchSuggestionId: string;
  amountGbp: number;
  gap: number | null;
  canReconcile: boolean;
  alreadyReconciled: boolean;
} }) {
  return (
    <article className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <p className="text-xs font-bold uppercase tracking-wide text-emerald-600">Customer/importer IN → order funding</p>
          <h3 className="mt-2 text-lg font-semibold">{candidate.orderRef || candidate.orderId || "No suggested order"}</h3>
          <p className="mt-1 break-all text-xs text-slate-500">DVA line: {candidate.dvaStatementLineId}</p>
        </div>
        <span className={`rounded-full px-3 py-1 text-xs font-semibold ${candidate.canReconcile ? "bg-emerald-50 text-emerald-700 ring-1 ring-emerald-200" : "bg-slate-100 text-slate-600 ring-1 ring-slate-200"}`}>
          {candidate.alreadyReconciled ? "already reconciled" : candidate.canReconcile ? "ready to fund" : "needs review"}
        </span>
      </div>

      <div className="mt-4 grid gap-3 sm:grid-cols-3">
        <SummaryCard title="Statement IN" value={gbp(candidate.amountGbp)} hint="GBP value from committed DVA/card line." tone="emerald" />
        <SummaryCard title="Order gap" value={candidate.gap === null ? "—" : gbp(candidate.gap)} hint="Remaining funding gap from order funding view." tone={candidate.gap && candidate.gap > 0 ? "amber" : "slate"} />
        <SummaryCard title="Suggested action" value={candidate.alreadyReconciled ? "Done" : candidate.canReconcile ? "Fund" : "Review"} hint="Uses staff_reconcile_dva_line_to_order." tone={candidate.canReconcile ? "sky" : "slate"} />
      </div>

      {candidate.alreadyReconciled ? (
        <p className="mt-4 rounded-xl bg-slate-50 px-3 py-2 text-xs text-slate-600 ring-1 ring-slate-200">Already reconciled — no action available.</p>
      ) : (
        <form action={reconcileDvaLineToOrderAction} className="mt-4 flex flex-wrap items-center gap-2">
          <input type="hidden" name="dva_statement_line_id" value={candidate.dvaStatementLineId} />
          <input type="hidden" name="order_id" value={candidate.orderId} />
          <input type="hidden" name="match_suggestion_id" value={candidate.matchSuggestionId} />
          <input type="hidden" name="gap_remaining_gbp" value={candidate.gap ?? ""} />
          <input
            name="reconciled_gbp_amount"
            type="number"
            step="0.01"
            min="0.01"
            defaultValue={candidate.amountGbp.toFixed(2)}
            disabled={!candidate.canReconcile}
            className="w-32 rounded-xl border border-slate-300 px-3 py-2 text-sm disabled:bg-slate-100"
          />
          <label className="inline-flex items-center gap-2 text-xs text-slate-700">
            <input type="checkbox" name="confirm_overfunding" value="yes" disabled={!candidate.canReconcile} />
            Allow overfunding if amount exceeds gap
          </label>
          <input name="notes" type="text" placeholder="Notes (optional)" disabled={!candidate.canReconcile} className="w-48 rounded-xl border border-slate-300 px-3 py-2 text-sm disabled:bg-slate-100" />
          <button type="submit" disabled={!candidate.canReconcile} className="rounded-xl bg-emerald-600 px-4 py-2 text-sm font-semibold text-white disabled:cursor-not-allowed disabled:bg-slate-300">
            Apply as funding
          </button>
          {!candidate.canReconcile ? <p className="text-xs text-slate-500">Missing suggested order, positive amount, or funding gap.</p> : null}
        </form>
      )}
    </article>
  );
}

export default async function InternalFundingPage({
  searchParams,
}: {
  searchParams?: Promise<{
    credit_success?: string;
    credit_error?: string;
    dva_success?: string;
    dva_error?: string;
  }>;
}) {
  const params = searchParams ? await searchParams : {};

  const results = await Promise.all(
    panels.map(async (panel) => ({
      ...panel,
      ...(await readPanel(panel.source)),
    }))
  );

  const fundingPosition = results.find((panel) => panel.source === "order_funding_position_vw");
  const fundingPositionColumns = fundingPosition ? allColumns(fundingPosition.rows) : [];
  const missingUsefulFundingColumns = ["order_total_gbp_declared", "gap_remaining_gbp", "requires_admin_review_yn", "funded_at"].filter((column) => !fundingPositionColumns.includes(column));
  const creditBalance = results.find((panel) => panel.source === "importer_balance_vw");
  const creditByImporter = new Map((creditBalance?.rows ?? []).map((row) => [asString(row.importer_id), asNumber(row.available_credit_gbp)]));

  const creditCandidates = (fundingPosition?.rows ?? []).map((row) => {
    const importerId = asString(row.importer_id);
    const orderId = asString(row.order_id);
    const gap = asNumber(row.gap_remaining_gbp);
    const availableCredit = creditByImporter.get(importerId) ?? 0;
    const maxApplyAmount = Math.min(gap, availableCredit);
    const alreadyFunded = asBoolean(row.already_funded_yn) || gap <= 0;

    return {
      importerId,
      orderId,
      orderRef: asString(row.order_ref),
      paymentAuthId: asString(row.payment_auth_id),
      status: asString(row.status),
      gap,
      availableCredit,
      maxApplyAmount,
      alreadyFunded,
      canApply: Boolean(importerId && orderId && maxApplyAmount > 0 && !alreadyFunded),
    };
  });

  const gapByOrder = new Map((fundingPosition?.rows ?? []).map((row) => [asString(row.order_id), asNumber(row.gap_remaining_gbp)]));
  const dvaWorklist = results.find((panel) => panel.source === "day2_dva_review_worklist_vw");
  const dvaReconcileCandidates = (dvaWorklist?.rows ?? [])
    .map((row) => {
      const dvaStatementLineId = asString(row.dva_statement_line_id);
      const orderId = asString(row.suggested_order_id);
      const matchSuggestionId = asString(row.match_suggestion_id);
      const suggestedOrderRef = asString(row.suggested_order_ref);
      const amountGbp = asNumber(row.amount_gbp_equivalent);
      const gap = gapByOrder.get(orderId);
      const alreadyReconciled = Boolean(asString(row.reconciliation_id)) || asString(row.match_status) === "reconciled";

      return {
        dvaStatementLineId,
        orderId,
        orderRef: suggestedOrderRef,
        matchSuggestionId,
        amountGbp,
        gap: typeof gap === "number" ? gap : null,
        canReconcile: Boolean(dvaStatementLineId && orderId && amountGbp > 0 && typeof gap === "number" && !alreadyReconciled),
        alreadyReconciled,
      };
    })
    .filter((candidate) => candidate.dvaStatementLineId);

  const openFundingGap = creditCandidates.reduce((sum, candidate) => sum + Math.max(0, candidate.gap), 0);
  const availableCredit = (creditBalance?.rows ?? []).reduce((sum, row) => sum + asNumber(row.available_credit_gbp), 0);
  const actionableCreditCount = creditCandidates.filter((candidate) => candidate.canApply).length;
  const actionableDvaCount = dvaReconcileCandidates.filter((candidate) => candidate.canReconcile).length;
  const recentEvents = results.find((panel) => panel.source === "order_funding_events")?.rows ?? [];

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto flex max-w-7xl flex-col gap-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <div className="flex flex-wrap items-start justify-between gap-4">
            <div>
              <Link href="/internal/dva-reconciliation" className="text-sm font-semibold text-sky-600">← Back to DVA/card control hub</Link>
              <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-emerald-600">Importer funding control</p>
              <h1 className="mt-2 text-3xl font-semibold tracking-tight">Apply customer/importer IN money to orders or credit</h1>
              <p className="mt-3 max-w-5xl text-sm leading-6 text-slate-600">
                Use this page only for customer/importer inbound funding and importer credit. Supplier purchases, retailer refunds, FX/card residuals, bank fees and exception holds stay in the DVA/card matching workspace.
              </p>
            </div>
            <Link href="/internal/dva-reconciliation/workspace" className="rounded-xl border border-slate-200 bg-white px-4 py-2 text-sm font-semibold text-slate-700 hover:bg-slate-50">
              Open matching workspace →
            </Link>
          </div>
        </section>

        <section className="grid gap-3 md:grid-cols-2 xl:grid-cols-4">
          <SummaryCard title="Open funding gaps" value={gbp(openFundingGap)} hint="Visible order funding gaps from order_funding_position_vw." tone={openFundingGap > 0 ? "amber" : "emerald"} />
          <SummaryCard title="Available credit" value={gbp(availableCredit)} hint="Importer credit available from importer_balance_vw." tone={availableCredit > 0 ? "sky" : "slate"} />
          <SummaryCard title="DVA funding candidates" value={String(actionableDvaCount)} hint="Inbound lines ready to apply through staff_reconcile_dva_line_to_order." tone={actionableDvaCount > 0 ? "emerald" : "slate"} />
          <SummaryCard title="Credit candidates" value={String(actionableCreditCount)} hint="Orders where importer credit can be applied to a gap." tone={actionableCreditCount > 0 ? "violet" : "slate"} />
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
          <p className="text-sm font-medium uppercase tracking-[0.18em] text-sky-500">Funding boundary</p>
          <h2 className="mt-2 text-xl font-semibold">Where each money type belongs</h2>
          <div className="mt-5 grid gap-3 md:grid-cols-2 xl:grid-cols-4">
            <RouteCard title="Customer/importer IN" body="Apply to order funding gaps or importer credit using the funding RPC path." href="/internal/funding" cta="Stay here" />
            <RouteCard title="Supplier OUT" body="Match to supplier invoice in the DVA/card matching workspace." href="/internal/dva-reconciliation/workspace" cta="Open workspace" />
            <RouteCard title="FX/card / bank fee" body="Allocate residuals or fees in the DVA/card matching workspace, not here." href="/internal/dva-reconciliation/workspace" cta="Open workspace" />
            <RouteCard title="Review before Sage" body="Use the review pack and pre-Sage readiness after funding and allocations are complete." href="/internal/dva-reconciliation/review-pack" cta="Open review pack" />
          </div>
        </section>

        {(params.credit_success || params.credit_error || params.dva_success || params.dva_error) && (
          <section className={`rounded-3xl border p-5 text-sm leading-6 ${params.credit_success || params.dva_success ? "border-emerald-200 bg-emerald-50 text-emerald-900" : "border-red-200 bg-red-50 text-red-900"}`}>
            {params.credit_success ?? params.dva_success ?? params.credit_error ?? params.dva_error}
          </section>
        )}

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div>
              <h2 className="text-xl font-semibold">1. Apply inbound statement money to order funding</h2>
              <p className="mt-1 max-w-4xl text-sm leading-6 text-slate-600">
                This uses the staff wrapper RPC <code className="rounded bg-slate-100 px-1 py-0.5">staff_reconcile_dva_line_to_order</code>. It creates/updates funding events and order funding state. It does not create supplier/refund/fee allocations.
              </p>
            </div>
            <span className="rounded-full bg-emerald-50 px-3 py-1 text-sm font-semibold text-emerald-700 ring-1 ring-emerald-200">Customer/importer IN only</span>
          </div>

          <div className="mt-5 grid gap-4">
            {dvaReconcileCandidates.length === 0 ? (
              <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-600">No DVA worklist rows are currently available for order funding reconciliation.</div>
            ) : dvaReconcileCandidates.map((candidate) => <DvaFundingCandidateCard key={candidate.dvaStatementLineId} candidate={candidate} />)}
          </div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div>
              <h2 className="text-xl font-semibold">2. Apply importer credit to order funding gap</h2>
              <p className="mt-1 max-w-4xl text-sm leading-6 text-slate-600">
                This uses the confirmed importer-credit RPC. It does not reconcile DVA/card statement lines and does not explain supplier/refund/fee movements.
              </p>
            </div>
            <span className="rounded-full bg-amber-50 px-3 py-1 text-sm font-semibold text-amber-700 ring-1 ring-amber-200">Credit only</span>
          </div>

          <div className="mt-5 grid gap-4">
            {creditCandidates.length === 0 ? (
              <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-600">No funding rows available for credit application.</div>
            ) : creditCandidates.map((candidate) => <CreditCandidateCard key={candidate.orderId || candidate.orderRef} candidate={candidate} />)}
          </div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold">Recent funding event audit</h2>
          <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">Immutable funding events created by DVA reconciliation, importer credit or adjustments.</p>
          {recentEvents.length === 0 ? (
            <div className="mt-5 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-600">No recent funding events returned.</div>
          ) : (
            <div className="mt-5 grid gap-3">
              {recentEvents.slice(0, 6).map((event, index) => (
                <article key={`${asString(event.source_entity_id)}-${index}`} className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
                  <div className="flex flex-wrap items-start justify-between gap-3">
                    <div>
                      <p className="text-xs font-bold uppercase tracking-wide text-slate-500">{asString(event.event_type) || "Funding event"}</p>
                      <h3 className="mt-1 text-lg font-semibold">{gbp(event.amount_gbp)}</h3>
                      <p className="mt-1 text-xs text-slate-500">Order: {asString(event.order_ref) || "—"} · Source: {asString(event.source_table) || "—"}</p>
                    </div>
                    <p className="text-xs text-slate-500">Resulting funded total: {event.resulting_funded_total_gbp === null || event.resulting_funded_total_gbp === undefined ? "—" : gbp(event.resulting_funded_total_gbp)}</p>
                  </div>
                  {asString(event.notes) ? <p className="mt-2 text-xs leading-5 text-slate-600">{asString(event.notes)}</p> : null}
                </article>
              ))}
            </div>
          )}
        </section>

        <details className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <summary className="cursor-pointer text-xl font-semibold">Advanced funding diagnostics</summary>
          <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">
            Diagnostic tables are collapsed by default. Use these only to verify live view columns, raw returned rows, and backend contracts. Do not use them as the normal supervisor workflow.
          </p>

          {fundingPosition?.error ? (
            <div className="mt-5 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-900">Funding position diagnostics unavailable: {fundingPosition.error}</div>
          ) : (
            <div className="mt-5 grid gap-4 lg:grid-cols-2">
              <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
                <h3 className="font-semibold">Available order funding columns</h3>
                <p className="mt-2 text-sm leading-6 text-slate-600">{fundingPositionColumns.length > 0 ? fundingPositionColumns.join(", ") : "No rows returned, so columns cannot be inferred from the UI response yet."}</p>
              </div>
              <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
                <h3 className="font-semibold">Missing useful action columns</h3>
                <p className="mt-2 text-sm leading-6 text-slate-600">{missingUsefulFundingColumns.length > 0 ? missingUsefulFundingColumns.join(", ") : "None detected from this response."}</p>
              </div>
            </div>
          )}

          <div className="mt-5 grid gap-5">
            {results.map((panel) => {
              const columns = visibleColumns(panel.source, panel.rows);
              const available = allColumns(panel.rows);

              return (
                <section key={panel.source} className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
                  <div className="flex flex-col gap-2 md:flex-row md:items-start md:justify-between">
                    <div>
                      <h3 className="font-semibold">{panel.title}</h3>
                      <p className="mt-1 max-w-3xl text-sm leading-6 text-slate-600">{panel.description}</p>
                      <div className="mt-2 flex flex-wrap gap-2 text-xs text-slate-500"><span>Source: {panel.source}</span><span>•</span><span>{panel.role}</span></div>
                    </div>
                    <span className="rounded-full bg-sky-50 px-3 py-1 text-sm font-semibold text-sky-600">{panel.error ? "Unavailable" : `${panel.rows.length} rows`}</span>
                  </div>

                  {panel.error ? (
                    <div className="mt-5 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm leading-6 text-amber-900">Could not read this source yet: {panel.error}</div>
                  ) : panel.rows.length === 0 ? (
                    <div className="mt-5 rounded-2xl border border-slate-200 bg-white p-4 text-sm text-slate-600">No rows returned. This can be correct if there is no current work in this queue.</div>
                  ) : (
                    <>
                      <div className="mt-5 overflow-x-auto rounded-2xl border border-slate-200 bg-white">
                        <table className="min-w-full divide-y divide-slate-200 text-left text-sm">
                          <thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500">
                            <tr>{columns.map((column) => <th key={column} className="px-4 py-3 font-semibold">{column.replaceAll("_", " ")}</th>)}</tr>
                          </thead>
                          <tbody className="divide-y divide-slate-100 bg-white">
                            {panel.rows.map((row, index) => (
                              <tr key={`${panel.source}-${index}`}>{columns.map((column) => <td key={column} className="max-w-xs px-4 py-3 align-top text-slate-700">{formatValue(row[column])}</td>)}</tr>
                            ))}
                          </tbody>
                        </table>
                      </div>
                      <details className="mt-4 rounded-2xl border border-slate-200 bg-white p-4 text-sm text-slate-600">
                        <summary className="cursor-pointer font-semibold text-slate-900">Show available columns for {panel.source}</summary>
                        <p className="mt-3 leading-6">{available.join(", ")}</p>
                      </details>
                    </>
                  )}
                </section>
              );
            })}
          </div>
        </details>

        <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm leading-6 text-amber-900">
          <h2 className="font-semibold">Funding controls boundary</h2>
          <p className="mt-2">Apply Credit is wired through a confirmed RPC, and DVA funding reconciliation is wired through the confirmed staff wrapper. FX/card residuals, supplier purchases, retailer refunds, bank fees, and exception holds are handled in the DVA/card matching workspace.</p>
        </section>
      </div>
    </main>
  );
}
