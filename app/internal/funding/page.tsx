import Link from "next/link";
import { createClient } from "@/utils/supabase/server";
import {
  applyImporterCreditAction,
  reconcileDvaLineToOrderAction,
} from "./actions";

type DataRow = Record<string, unknown>;

type FundingCandidate = {
  dvaStatementLineId: string;
  orderId: string;
  orderRef: string;
  matchSuggestionId: string;
  amountGbp: number;
  gap: number | null;
  alreadyReconciled: boolean;
  canReconcile: boolean;
  reviewReason: string;
  matchSource: "existing_suggestion" | "inferred" | "none";
  matchScore: number;
  matchReasons: string[];
};

type CreditCandidate = {
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
  reviewReason: string;
};

const gbpFormatter = new Intl.NumberFormat("en-GB", {
  style: "currency",
  currency: "GBP",
  minimumFractionDigits: 2,
});

function asNumber(value: unknown) {
  if (typeof value === "number") return Number.isFinite(value) ? value : 0;
  if (typeof value === "string" && value.trim() !== "") {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

function asString(value: unknown) {
  return typeof value === "string" ? value.trim() : "";
}

function asBoolean(value: unknown) {
  if (typeof value === "boolean") return value;
  if (typeof value === "string") return value.toLowerCase() === "true";
  return false;
}

function gbp(value: unknown) {
  return gbpFormatter.format(asNumber(value));
}

function formatValue(value: unknown) {
  if (value === null || value === undefined) return "—";
  if (typeof value === "boolean") return value ? "Yes" : "No";
  if (typeof value === "number") return value.toLocaleString("en-GB");
  if (typeof value === "string") return value.length > 90 ? `${value.slice(0, 87)}...` : value;
  return JSON.stringify(value);
}

function allColumns(rows: DataRow[]) {
  return Array.from(new Set(rows.flatMap((row) => Object.keys(row))));
}

async function readRows(source: string, limit = 10) {
  const supabase = await createClient();
  const { data, error } = await supabase.from(source).select("*").limit(limit);
  return { rows: (data ?? []) as DataRow[], error: error?.message ?? null };
}

function normalise(value: unknown) {
  return asString(value).toLowerCase().replace(/[^a-z0-9]+/g, "");
}

function normaliseMoney(value: number) {
  return Math.round(value * 100) / 100;
}

function inboundLineText(row: DataRow) {
  return [
    row.reference_raw,
    row.auth_id_ref,
    row.payment_auth_id,
    row.bank_reference,
    row.transaction_family_ref,
    row.merchant_raw,
    row.retailer_name_ref,
    row.notes,
  ]
    .map((value) => asString(value))
    .filter(Boolean)
    .join(" ");
}

function inferFundingOrder(row: DataRow, fundingRows: DataRow[]) {
  const explicitOrderId = asString(row.suggested_order_id);
  if (explicitOrderId) {
    const explicitOrder = fundingRows.find((fundingRow) => asString(fundingRow.order_id) === explicitOrderId);
    return {
      order: explicitOrder,
      orderId: explicitOrderId,
      orderRef: asString(row.suggested_order_ref) || asString(explicitOrder?.order_ref),
      matchSuggestionId: asString(row.match_suggestion_id),
      source: "existing_suggestion" as const,
      score: 100,
      reasons: ["Existing order suggestion from review worklist"],
    };
  }

  const textBlob = normalise(inboundLineText(row));
  const importerId = asString(row.importer_id);
  const amount = normaliseMoney(asNumber(row.amount_gbp_equivalent));
  const candidates = fundingRows
    .filter((fundingRow) => asNumber(fundingRow.gap_remaining_gbp) > 0)
    .map((fundingRow) => {
      let score = 0;
      const reasons: string[] = [];
      const orderRef = asString(fundingRow.order_ref);
      const orderRefNorm = normalise(orderRef);
      const paymentAuthId = asString(fundingRow.payment_auth_id);
      const paymentAuthNorm = normalise(paymentAuthId);
      const fundingImporterId = asString(fundingRow.importer_id);
      const gap = normaliseMoney(asNumber(fundingRow.gap_remaining_gbp));
      const orderTotal = normaliseMoney(asNumber(fundingRow.order_total_gbp_declared));

      if (importerId && fundingImporterId && importerId === fundingImporterId) {
        score += 10;
        reasons.push("same importer");
      }

      if (paymentAuthNorm && textBlob.includes(paymentAuthNorm)) {
        score += 80;
        reasons.push("payment/auth reference found in bank text");
      }

      if (orderRefNorm && textBlob.includes(orderRefNorm)) {
        score += 90;
        reasons.push("order reference found in bank text");
      }

      if (amount > 0 && gap > 0 && Math.abs(amount - gap) <= 0.02) {
        score += 15;
        reasons.push("amount equals current order funding gap");
      } else if (amount > 0 && orderTotal > 0 && Math.abs(amount - orderTotal) <= 0.02) {
        score += 10;
        reasons.push("amount equals declared order total");
      }

      return { fundingRow, score, reasons };
    })
    .filter((candidate) => candidate.score >= 80)
    .sort((a, b) => b.score - a.score);

  const best = candidates[0];
  if (!best) {
    return {
      order: undefined,
      orderId: "",
      orderRef: "",
      matchSuggestionId: "",
      source: "none" as const,
      score: 0,
      reasons: [] as string[],
    };
  }

  return {
    order: best.fundingRow,
    orderId: asString(best.fundingRow.order_id),
    orderRef: asString(best.fundingRow.order_ref),
    matchSuggestionId: "",
    source: "inferred" as const,
    score: best.score,
    reasons: best.reasons,
  };
}

function fundingReviewReason(args: {
  orderId: string;
  amountGbp: number;
  gap: number | null;
  alreadyReconciled: boolean;
  matchSource: FundingCandidate["matchSource"];
  matchScore: number;
}) {
  if (args.alreadyReconciled) return "Already reconciled. It belongs in audit, not the action queue.";
  if (!args.orderId) return "No strong order match yet. Needs order ref/payment auth evidence before funding.";
  if (args.matchSource === "inferred" && args.matchScore < 80) return "Inferred match is below the safe action threshold.";
  if (args.amountGbp <= 0) return "No positive inbound amount to apply.";
  if (args.gap === null) return "Order funding gap is unavailable from the funding position view.";
  if (args.gap <= 0) return "Suggested order has no remaining funding gap.";
  return "Ready to apply as funding.";
}

function creditReviewReason(candidate: Omit<CreditCandidate, "canApply" | "reviewReason">) {
  if (candidate.alreadyFunded) return "Order has no remaining funding gap.";
  if (!candidate.importerId || !candidate.orderId) return "Missing importer or order id.";
  if (candidate.availableCredit <= 0) return "No available importer credit.";
  if (candidate.gap <= 0) return "No funding gap.";
  if (candidate.maxApplyAmount <= 0) return "Nothing available to apply.";
  return "Ready to apply importer credit.";
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

function DvaFundingActionCard({ candidate }: { candidate: FundingCandidate }) {
  const showOverfunding = candidate.gap !== null && candidate.amountGbp > candidate.gap;

  return (
    <article className="rounded-2xl border border-emerald-200 bg-white p-4 shadow-sm">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <p className="text-xs font-bold uppercase tracking-wide text-emerald-600">Ready: customer/importer IN → order funding</p>
          <h3 className="mt-2 text-lg font-semibold">{candidate.orderRef || candidate.orderId}</h3>
          <p className="mt-1 break-all text-xs text-slate-500">DVA line: {candidate.dvaStatementLineId}</p>
        </div>
        <span className="rounded-full bg-emerald-50 px-3 py-1 text-xs font-semibold text-emerald-700 ring-1 ring-emerald-200">ready to fund</span>
      </div>

      <div className="mt-4 grid gap-3 sm:grid-cols-4">
        <SummaryCard title="Statement IN" value={gbp(candidate.amountGbp)} hint="GBP value from committed DVA/card line." tone="emerald" />
        <SummaryCard title="Order gap" value={candidate.gap === null ? "—" : gbp(candidate.gap)} hint="Remaining order funding gap." tone="amber" />
        <SummaryCard title="Match source" value={candidate.matchSource === "inferred" ? "Inferred" : "Suggested"} hint={`Score ${candidate.matchScore}. ${candidate.matchReasons.join("; ") || "Worklist suggestion."}`} tone="sky" />
        <SummaryCard title="Suggested action" value="Fund" hint="Uses staff_reconcile_dva_line_to_order." tone="violet" />
      </div>

      <form action={reconcileDvaLineToOrderAction} className="mt-4 flex flex-wrap items-center gap-2">
        <input type="hidden" name="dva_statement_line_id" value={candidate.dvaStatementLineId} />
        <input type="hidden" name="order_id" value={candidate.orderId} />
        <input type="hidden" name="match_suggestion_id" value={candidate.matchSuggestionId} />
        <input type="hidden" name="gap_remaining_gbp" value={candidate.gap ?? ""} />
        <input name="reconciled_gbp_amount" type="number" step="0.01" min="0.01" defaultValue={candidate.amountGbp.toFixed(2)} className="w-32 rounded-xl border border-slate-300 px-3 py-2 text-sm" />
        {showOverfunding ? (
          <label className="inline-flex items-center gap-2 text-xs text-slate-700">
            <input type="checkbox" name="confirm_overfunding" value="yes" />
            Allow overfunding because inbound amount exceeds gap
          </label>
        ) : null}
        <input name="notes" type="text" placeholder="Notes (optional)" className="w-48 rounded-xl border border-slate-300 px-3 py-2 text-sm" defaultValue={candidate.matchSource === "inferred" ? `UI inferred funding match: ${candidate.matchReasons.join("; ")}` : ""} />
        <button type="submit" className="rounded-xl bg-emerald-600 px-4 py-2 text-sm font-semibold text-white">Apply as funding</button>
      </form>
    </article>
  );
}

function CreditActionCard({ candidate }: { candidate: CreditCandidate }) {
  return (
    <article className="rounded-2xl border border-amber-200 bg-white p-4 shadow-sm">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <p className="text-xs font-bold uppercase tracking-wide text-amber-600">Ready: importer credit → order gap</p>
          <h3 className="mt-2 text-lg font-semibold">{candidate.orderRef || "No order ref"}</h3>
          <p className="mt-1 text-xs text-slate-500">Auth: {candidate.paymentAuthId || "—"} · Status: {candidate.status || "—"}</p>
        </div>
        <span className="rounded-full bg-amber-50 px-3 py-1 text-xs font-semibold text-amber-700 ring-1 ring-amber-200">credit available</span>
      </div>

      <div className="mt-4 grid gap-3 sm:grid-cols-3">
        <SummaryCard title="Funding gap" value={gbp(candidate.gap)} hint="Remaining order funding gap." tone="amber" />
        <SummaryCard title="Available credit" value={gbp(candidate.availableCredit)} hint="Importer credit available." tone="sky" />
        <SummaryCard title="Max apply" value={gbp(candidate.maxApplyAmount)} hint="Capped at lower of gap and credit." tone="emerald" />
      </div>

      <form action={applyImporterCreditAction} className="mt-4 flex flex-wrap items-center gap-2">
        <input type="hidden" name="importer_id" value={candidate.importerId} />
        <input type="hidden" name="order_id" value={candidate.orderId} />
        <input name="amount_gbp" type="number" step="0.01" min="0.01" max={candidate.maxApplyAmount} defaultValue={candidate.maxApplyAmount.toFixed(2)} className="w-32 rounded-xl border border-slate-300 px-3 py-2 text-sm" />
        <button type="submit" className="rounded-xl bg-amber-600 px-4 py-2 text-sm font-semibold text-white">Apply credit</button>
      </form>
    </article>
  );
}

function ReviewList({ title, rows }: { title: string; rows: Array<FundingCandidate | CreditCandidate> }) {
  if (rows.length === 0) return null;

  return (
    <details className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
      <summary className="cursor-pointer text-sm font-semibold text-slate-900">{title} · {rows.length}</summary>
      <div className="mt-3 grid gap-2">
        {rows.map((row, index) => (
          <div key={`${title}-${index}`} className="rounded-xl bg-white p-3 text-xs leading-5 text-slate-600 ring-1 ring-slate-200">
            <p className="font-semibold text-slate-900">{"dvaStatementLineId" in row ? row.orderRef || row.orderId || "No strong order match" : row.orderRef || "No order ref"}</p>
            <p>{row.reviewReason}</p>
            {"matchReasons" in row && row.matchReasons.length > 0 ? <p className="mt-1">Signals: {row.matchReasons.join("; ")}</p> : null}
          </div>
        ))}
      </div>
    </details>
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

  const [worklistResult, fundingPositionResult, creditBalanceResult, recentLinesResult, fundingEventsResult] = await Promise.all([
    readRows("day2_dva_review_worklist_vw", 75),
    readRows("order_funding_position_vw", 200),
    readRows("importer_balance_vw", 50),
    readRows("dva_statement_lines", 10),
    readRows("order_funding_events", 10),
  ]);

  const fundingRows = fundingPositionResult.rows;
  const creditRows = creditBalanceResult.rows;
  const worklistRows = worklistResult.rows;
  const recentEvents = fundingEventsResult.rows;
  const fundingPositionColumns = allColumns(fundingRows);
  const missingUsefulFundingColumns = ["order_total_gbp_declared", "gap_remaining_gbp", "requires_admin_review_yn", "funded_at"].filter((column) => !fundingPositionColumns.includes(column));

  const gapByOrder = new Map(fundingRows.map((row) => [asString(row.order_id), asNumber(row.gap_remaining_gbp)]));
  const creditByImporter = new Map(creditRows.map((row) => [asString(row.importer_id), asNumber(row.available_credit_gbp)]));

  const fundingCandidates: FundingCandidate[] = worklistRows
    .map((row) => {
      const inferred = inferFundingOrder(row, fundingRows);
      const dvaStatementLineId = asString(row.dva_statement_line_id);
      const amountGbp = asNumber(row.amount_gbp_equivalent);
      const gap = inferred.orderId ? gapByOrder.get(inferred.orderId) : undefined;
      const alreadyReconciled = Boolean(asString(row.reconciliation_id)) || asString(row.match_status) === "reconciled" || asString(row.match_status) === "confirmed";
      const resolvedGap = typeof gap === "number" ? gap : null;
      const reviewReason = fundingReviewReason({
        orderId: inferred.orderId,
        amountGbp,
        gap: resolvedGap,
        alreadyReconciled,
        matchSource: inferred.source,
        matchScore: inferred.score,
      });

      return {
        dvaStatementLineId,
        orderId: inferred.orderId,
        orderRef: inferred.orderRef,
        matchSuggestionId: inferred.matchSuggestionId,
        amountGbp,
        gap: resolvedGap,
        alreadyReconciled,
        canReconcile: Boolean(dvaStatementLineId && inferred.orderId && amountGbp > 0 && resolvedGap !== null && resolvedGap > 0 && !alreadyReconciled && inferred.score >= 80),
        reviewReason,
        matchSource: inferred.source,
        matchScore: inferred.score,
        matchReasons: inferred.reasons,
      };
    })
    .filter((candidate) => candidate.dvaStatementLineId);

  const creditCandidates: CreditCandidate[] = fundingRows.map((row) => {
    const importerId = asString(row.importer_id);
    const orderId = asString(row.order_id);
    const gap = asNumber(row.gap_remaining_gbp);
    const availableCredit = creditByImporter.get(importerId) ?? 0;
    const maxApplyAmount = Math.min(gap, availableCredit);
    const alreadyFunded = asBoolean(row.already_funded_yn) || gap <= 0;
    const base = {
      importerId,
      orderId,
      orderRef: asString(row.order_ref),
      paymentAuthId: asString(row.payment_auth_id),
      status: asString(row.status),
      gap,
      availableCredit,
      maxApplyAmount,
      alreadyFunded,
    };
    const reviewReason = creditReviewReason(base);

    return {
      ...base,
      canApply: Boolean(importerId && orderId && maxApplyAmount > 0 && !alreadyFunded),
      reviewReason,
    };
  });

  const readyFundingCandidates = fundingCandidates.filter((candidate) => candidate.canReconcile);
  const fundingNeedsReview = fundingCandidates.filter((candidate) => !candidate.canReconcile && !candidate.alreadyReconciled);
  const reconciledFundingAudit = fundingCandidates.filter((candidate) => candidate.alreadyReconciled);
  const readyCreditCandidates = creditCandidates.filter((candidate) => candidate.canApply);
  const creditNeedsReview = creditCandidates.filter((candidate) => !candidate.canApply && !candidate.alreadyFunded);

  const openFundingGap = fundingRows.reduce((sum, row) => sum + Math.max(0, asNumber(row.gap_remaining_gbp)), 0);
  const availableCredit = creditRows.reduce((sum, row) => sum + asNumber(row.available_credit_gbp), 0);
  const needsReviewCount = fundingNeedsReview.length + creditNeedsReview.length;

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto flex max-w-7xl flex-col gap-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <div className="flex flex-wrap items-start justify-between gap-4">
            <div>
              <Link href="/internal/dva-reconciliation" className="text-sm font-semibold text-sky-600">← Back to DVA/card control hub</Link>
              <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-emerald-600">Importer funding control</p>
              <h1 className="mt-2 text-3xl font-semibold tracking-tight">Apply customer/importer IN money to orders or credit</h1>
              <p className="mt-3 max-w-5xl text-sm leading-6 text-slate-600">Use this page only for customer/importer inbound funding and importer credit. Supplier purchases, retailer refunds, FX/card residuals, bank fees and exception holds stay in the DVA/card matching workspace.</p>
            </div>
            <Link href="/internal/dva-reconciliation/workspace" className="rounded-xl border border-slate-200 bg-white px-4 py-2 text-sm font-semibold text-slate-700 hover:bg-slate-50">Open matching workspace →</Link>
          </div>
        </section>

        <section className="grid gap-3 md:grid-cols-2 xl:grid-cols-4">
          <SummaryCard title="Open funding gaps" value={gbp(openFundingGap)} hint="Visible order funding gaps from order_funding_position_vw." tone={openFundingGap > 0 ? "amber" : "emerald"} />
          <SummaryCard title="Available credit" value={gbp(availableCredit)} hint="Importer credit available from importer_balance_vw." tone={availableCredit > 0 ? "sky" : "slate"} />
          <SummaryCard title="Ready funding candidates" value={String(readyFundingCandidates.length)} hint="Inbound lines with strong ref/order evidence and positive gap." tone={readyFundingCandidates.length > 0 ? "emerald" : "slate"} />
          <SummaryCard title="Needs review" value={String(needsReviewCount)} hint="Rows hidden from action forms because a safe match/gap is missing." tone={needsReviewCount > 0 ? "amber" : "slate"} />
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

        {(params.credit_success || params.credit_error || params.dva_success || params.dva_error) ? (
          <section className={`rounded-3xl border p-5 text-sm leading-6 ${params.credit_success || params.dva_success ? "border-emerald-200 bg-emerald-50 text-emerald-900" : "border-red-200 bg-red-50 text-red-900"}`}>{params.credit_success ?? params.dva_success ?? params.credit_error ?? params.dva_error}</section>
        ) : null}

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div>
              <h2 className="text-xl font-semibold">1. Ready inbound statement money</h2>
              <p className="mt-1 max-w-4xl text-sm leading-6 text-slate-600">Only rows with strong order evidence, positive inbound amount, and positive order gap appear here. Amount-only matches stay in review.</p>
            </div>
            <span className="rounded-full bg-emerald-50 px-3 py-1 text-sm font-semibold text-emerald-700 ring-1 ring-emerald-200">Safe action queue</span>
          </div>
          <div className="mt-5 grid gap-4">
            {readyFundingCandidates.length === 0 ? <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-600">No inbound statement rows are currently safe to apply as order funding.</div> : readyFundingCandidates.map((candidate) => <DvaFundingActionCard key={candidate.dvaStatementLineId} candidate={candidate} />)}
          </div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div>
              <h2 className="text-xl font-semibold">2. Ready importer credit</h2>
              <p className="mt-1 max-w-4xl text-sm leading-6 text-slate-600">Only orders with a real funding gap and available importer credit appear here.</p>
            </div>
            <span className="rounded-full bg-amber-50 px-3 py-1 text-sm font-semibold text-amber-700 ring-1 ring-amber-200">Credit only</span>
          </div>
          <div className="mt-5 grid gap-4">
            {readyCreditCandidates.length === 0 ? <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-600">No importer credit rows are currently safe to apply.</div> : readyCreditCandidates.map((candidate) => <CreditActionCard key={candidate.orderId || candidate.orderRef} candidate={candidate} />)}
          </div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold">Rows excluded from action forms</h2>
          <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">These are deliberately not actionable on this page. They need a stronger reference match, gap, or audit review first.</p>
          <div className="mt-5 grid gap-3">
            <ReviewList title="Inbound lines needing stronger order evidence / gap review" rows={fundingNeedsReview} />
            <ReviewList title="Credit rows not currently applicable" rows={creditNeedsReview} />
            <ReviewList title="Already reconciled inbound funding audit" rows={reconciledFundingAudit} />
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
          <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">Diagnostic tables are collapsed by default. Use these only to verify live view columns, raw returned rows, and backend contracts.</p>
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
          <div className="mt-5 grid gap-5">
            {[
              ["DVA review worklist", "day2_dva_review_worklist_vw", worklistRows, worklistResult.error],
              ["Order funding positions", "order_funding_position_vw", fundingRows, fundingPositionResult.error],
              ["Importer credit balances", "importer_balance_vw", creditRows, creditBalanceResult.error],
              ["Recent DVA lines", "dva_statement_lines", recentLinesResult.rows, recentLinesResult.error],
              ["Recent funding events", "order_funding_events", recentEvents, fundingEventsResult.error],
            ].map(([title, source, rows, error]) => {
              const tableRows = rows as DataRow[];
              const columns = allColumns(tableRows).slice(0, 10);
              return (
                <section key={String(source)} className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
                  <div className="flex flex-wrap items-start justify-between gap-3">
                    <div>
                      <h3 className="font-semibold">{String(title)}</h3>
                      <p className="mt-1 text-xs text-slate-500">Source: {String(source)}</p>
                    </div>
                    <span className="rounded-full bg-sky-50 px-3 py-1 text-sm font-semibold text-sky-600">{error ? "Unavailable" : `${tableRows.length} rows`}</span>
                  </div>
                  {error ? <div className="mt-4 rounded-xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">Could not read this source: {String(error)}</div> : tableRows.length === 0 ? <div className="mt-4 rounded-xl border border-slate-200 bg-white p-3 text-sm text-slate-600">No rows returned.</div> : (
                    <div className="mt-4 overflow-x-auto rounded-xl border border-slate-200 bg-white">
                      <table className="min-w-full divide-y divide-slate-200 text-left text-sm">
                        <thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500"><tr>{columns.map((column) => <th key={column} className="px-4 py-3 font-semibold">{column.replaceAll("_", " ")}</th>)}</tr></thead>
                        <tbody className="divide-y divide-slate-100 bg-white">{tableRows.map((row, index) => <tr key={`${String(source)}-${index}`}>{columns.map((column) => <td key={column} className="max-w-xs px-4 py-3 align-top text-slate-700">{formatValue(row[column])}</td>)}</tr>)}</tbody>
                      </table>
                    </div>
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
