import type { ReactNode } from "react";
import { createClient } from "@/utils/supabase/server";

export const dynamic = "force-dynamic";

type SummaryRow = {
  dva_statement_line_id: string;
  importer_id: string | null;
  statement_date: string | null;
  reference_raw: string | null;
  direction: string | null;
  statement_gbp_amount: number | string | null;
  confirmed_allocated_gbp: number | string | null;
  confirmed_unallocated_gbp: number | string | null;
  confirmed_balanced_yn: boolean | string | null;
  active_allocation_count: number | string | null;
  supplier_invoice_allocated_gbp: number | string | null;
  retailer_refund_allocated_gbp: number | string | null;
  fx_card_or_fee_allocated_gbp: number | string | null;
  exception_or_hold_allocated_gbp: number | string | null;
  statement_account_context: string | null;
  statement_account_label: string | null;
  source_bank: string | null;
  control_match_reason: string | null;
  loyalty_credit_funding_allocated_gbp: number | string | null;
  main_bank_loyalty_match_count: number | string | null;
  loyalty_internal_transfer_out_gbp: number | string | null;
  loyalty_internal_transfer_in_gbp: number | string | null;
  loyalty_internal_transfer_in_count: number | string | null;
};

type LegacyLoyaltyRow = {
  id: string;
  dva_statement_line_id: string | null;
  completed_order_id: string | null;
  matched_gbp_amount: number | string | null;
  transfer_pair_status: string | null;
  destination_in_statement_line_id: string | null;
  variance_reason: string | null;
  notes: string | null;
};

const gbpFormatter = new Intl.NumberFormat("en-GB", {
  style: "currency",
  currency: "GBP",
  minimumFractionDigits: 2,
});

function num(value: unknown) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

function text(value: unknown) {
  return typeof value === "string" ? value : value == null ? "" : String(value);
}

function gbp(value: unknown) {
  return gbpFormatter.format(num(value));
}

function bool(value: unknown) {
  return value === true || text(value).toLowerCase() === "true";
}

function pretty(value: unknown) {
  const raw = text(value);
  return raw ? raw.replaceAll("_", " ") : "—";
}

function classifyLine(row: SummaryRow, legacy?: LegacyLoyaltyRow) {
  const direction = text(row.direction).toLowerCase();
  const accountContext = text(row.statement_account_context);
  const controlReason = text(row.control_match_reason);
  const supplier = num(row.supplier_invoice_allocated_gbp);
  const refund = num(row.retailer_refund_allocated_gbp);
  const fxFee = num(row.fx_card_or_fee_allocated_gbp);
  const exceptionHold = num(row.exception_or_hold_allocated_gbp);
  const loyaltyOut = num(row.loyalty_internal_transfer_out_gbp);
  const loyaltyIn = num(row.loyalty_internal_transfer_in_gbp);
  const loyaltyCredit = num(row.loyalty_credit_funding_allocated_gbp);
  const activeCount = num(row.active_allocation_count);
  const open = num(row.confirmed_unallocated_gbp);
  const balanced = bool(row.confirmed_balanced_yn);

  if (legacy?.variance_reason === "documented_legacy_test_out_only_no_destination_in_available") {
    return {
      label: "Documented legacy loyalty exception",
      tone: "border-slate-300 bg-slate-100 text-slate-800",
      boundary: "Control evidence only. Do not pair to unrelated IN lines. No duplicate credit, no order-funding event, no Sage/VAT action.",
      readiness: "Documented exception",
      ready: true,
      open,
    };
  }

  if (controlReason === "loyalty_internal_transfer_out" || loyaltyOut > 0) {
    return {
      label: "Loyalty internal transfer OUT",
      tone: "border-violet-200 bg-violet-50 text-violet-800",
      boundary: "Internal transfer control only. Not customer cash, not supplier AP, not Sage posting from this review pack.",
      readiness: balanced ? "Balanced internal transfer" : "Transfer OUT needs review",
      ready: balanced,
      open,
    };
  }

  if (controlReason === "loyalty_internal_transfer_in" || loyaltyIn > 0 || num(row.loyalty_internal_transfer_in_count) > 0) {
    return {
      label: "Loyalty destination IN",
      tone: "border-violet-200 bg-violet-50 text-violet-800",
      boundary: "Destination side of loyalty activation. Do not classify as ordinary customer funding.",
      readiness: balanced ? "Balanced destination IN" : "Destination IN needs review",
      ready: balanced,
      open,
    };
  }

  if (direction === "in" && accountContext === "importer_dva_card_account" && refund <= 0 && loyaltyCredit <= 0 && activeCount === 0) {
    return {
      label: "Importer funding / top-up",
      tone: "border-emerald-200 bg-emerald-50 text-emerald-800",
      boundary: "Funding proof belongs to funding/order-credit controls, not supplier spend allocation.",
      readiness: balanced ? "Funding controlled" : "Funding/open balance review",
      ready: balanced,
      open,
    };
  }

  if (supplier > 0) {
    return {
      label: "Supplier charge allocation",
      tone: "border-sky-200 bg-sky-50 text-sky-800",
      boundary: "Supplier/AP evidence. Sage readiness still requires mapped supplier invoice and zero/approved residual.",
      readiness: balanced ? "Balanced supplier charge" : "Supplier charge needs residual review",
      ready: balanced && exceptionHold <= 0,
      open,
    };
  }

  if (refund > 0) {
    return {
      label: "Retailer refund allocation",
      tone: "border-emerald-200 bg-emerald-50 text-emerald-800",
      boundary: "Refund evidence. Must remain linked to exception/refund outcome, not ordinary customer funding.",
      readiness: balanced ? "Balanced refund" : "Refund needs review",
      ready: balanced,
      open,
    };
  }

  if (fxFee > 0 && supplier <= 0 && refund <= 0) {
    return {
      label: "FX/card/bank-fee residual",
      tone: "border-amber-200 bg-amber-50 text-amber-800",
      boundary: "Residual classification only. Needs deliberate accounting treatment before Sage payload readiness.",
      readiness: balanced ? "Balanced residual" : "Residual needs review",
      ready: balanced,
      open,
    };
  }

  if (exceptionHold > 0) {
    return {
      label: "Exception / hold allocation",
      tone: "border-amber-200 bg-amber-50 text-amber-800",
      boundary: "Exception control. Do not fake refund or supplier closure until retailer/operator outcome is evidenced.",
      readiness: "Held / exception controlled",
      ready: false,
      open,
    };
  }

  return {
    label: "Unclassified statement line",
    tone: "border-rose-200 bg-rose-50 text-rose-800",
    boundary: "Needs allocation, funding, refund, loyalty, FX/fee, or exception classification before accounting readiness.",
    readiness: "Needs classification",
    ready: false,
    open,
  };
}

async function ReviewPackV2Summary() {
  const supabase = await createClient();

  const [summaryResult, legacyResult] = await Promise.all([
    supabase
      .from("dva_statement_line_allocation_summary_vw")
      .select("dva_statement_line_id, importer_id, statement_date, reference_raw, direction, statement_gbp_amount, confirmed_allocated_gbp, confirmed_unallocated_gbp, confirmed_balanced_yn, active_allocation_count, supplier_invoice_allocated_gbp, retailer_refund_allocated_gbp, fx_card_or_fee_allocated_gbp, exception_or_hold_allocated_gbp, statement_account_context, statement_account_label, source_bank, control_match_reason, loyalty_credit_funding_allocated_gbp, main_bank_loyalty_match_count, loyalty_internal_transfer_out_gbp, loyalty_internal_transfer_in_gbp, loyalty_internal_transfer_in_count")
      .order("statement_date", { ascending: false })
      .limit(120),
    supabase
      .from("main_bank_completion_loyalty_funding_matches")
      .select("id, dva_statement_line_id, completed_order_id, matched_gbp_amount, transfer_pair_status, destination_in_statement_line_id, variance_reason, notes")
      .eq("match_status", "released_available_dashboard_credit")
      .eq("transfer_pair_status", "legacy_released_out_only")
      .is("destination_in_statement_line_id", null)
      .limit(50),
  ]);

  const rows = (summaryResult.data ?? []) as unknown as SummaryRow[];
  const legacyRows = (legacyResult.data ?? []) as unknown as LegacyLoyaltyRow[];
  const legacyBySourceLine = new Map(legacyRows.filter((row) => row.dva_statement_line_id).map((row) => [row.dva_statement_line_id as string, row]));

  const classified = rows.map((row) => {
    const classification = classifyLine(row, legacyBySourceLine.get(row.dva_statement_line_id));
    return { row, classification };
  });

  const totalOpen = classified.reduce((sum, item) => sum + num(item.row.confirmed_unallocated_gbp), 0);
  const readyCount = classified.filter((item) => item.classification.ready).length;
  const loyaltyCount = classified.filter((item) => item.classification.label.toLowerCase().includes("loyalty")).length;
  const exceptionCount = classified.filter((item) => item.classification.label.toLowerCase().includes("exception") || item.classification.label.toLowerCase().includes("hold")).length;

  return (
    <section className="border-b border-slate-200 bg-gradient-to-br from-slate-950 via-slate-900 to-slate-800 px-4 py-6 text-white sm:px-6 lg:px-8">
      <div className="mx-auto max-w-7xl space-y-5">
        <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_auto] lg:items-start">
          <div>
            <p className="text-xs font-bold uppercase tracking-[0.22em] text-sky-300">DVA/card review pack v2</p>
            <h2 className="mt-2 text-2xl font-extrabold tracking-tight sm:text-3xl">Grouped statement-line proof summary</h2>
            <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-300">
              Read-only supervisor proof layer. Each statement line is classified before Sage readiness: customer funding, supplier charge, refund, FX/fee, exception/hold, loyalty internal transfer, or documented legacy exception.
            </p>
          </div>
          <div className="rounded-2xl border border-white/10 bg-white/10 p-4 text-sm text-slate-100 shadow-sm">
            <p className="font-bold text-white">Posting boundary</p>
            <p className="mt-1 max-w-sm text-slate-300">No freeze, no batch, no Sage posting, no credit creation, and no allocation writes happen in this proof view.</p>
          </div>
        </div>

        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <div className="rounded-2xl border border-white/10 bg-white/10 p-4"><p className="text-xs font-bold uppercase tracking-wide text-slate-300">Rows sampled</p><p className="mt-2 text-2xl font-extrabold">{classified.length}</p></div>
          <div className="rounded-2xl border border-emerald-300/30 bg-emerald-400/10 p-4"><p className="text-xs font-bold uppercase tracking-wide text-emerald-200">Ready/controlled</p><p className="mt-2 text-2xl font-extrabold">{readyCount}</p></div>
          <div className="rounded-2xl border border-violet-300/30 bg-violet-400/10 p-4"><p className="text-xs font-bold uppercase tracking-wide text-violet-200">Loyalty controls</p><p className="mt-2 text-2xl font-extrabold">{loyaltyCount}</p></div>
          <div className="rounded-2xl border border-amber-300/30 bg-amber-400/10 p-4"><p className="text-xs font-bold uppercase tracking-wide text-amber-200">Open amount</p><p className="mt-2 text-2xl font-extrabold">{gbp(totalOpen)}</p><p className="mt-1 text-xs text-amber-100">Exception/hold rows: {exceptionCount}</p></div>
        </div>

        {summaryResult.error ? (
          <div className="rounded-2xl border border-rose-300/40 bg-rose-500/10 p-4 text-sm font-semibold text-rose-100">{summaryResult.error.message}</div>
        ) : null}

        <div className="grid gap-3 lg:grid-cols-3">
          {classified.slice(0, 18).map(({ row, classification }) => {
            const controlSummary = `${row.statement_date || "No date"} ${text(row.direction).toUpperCase() || "—"} ${gbp(row.statement_gbp_amount)} · ${classification.label} · open ${gbp(row.confirmed_unallocated_gbp)}`;
            return (
              <article key={row.dva_statement_line_id} className="rounded-2xl border border-white/10 bg-white p-4 text-slate-950 shadow-sm">
                <div className="flex flex-wrap items-start justify-between gap-3">
                  <div className="min-w-0">
                    <p className="text-sm font-extrabold">{row.statement_date || "No date"} · {text(row.direction).toUpperCase() || "—"} · {gbp(row.statement_gbp_amount)}</p>
                    <p className="mt-1 break-words text-xs text-slate-600">{row.reference_raw || "No statement text"}</p>
                  </div>
                  <span className={`rounded-full border px-2 py-1 text-[11px] font-bold ${classification.tone}`}>{classification.label}</span>
                </div>
                <div className="mt-3 grid grid-cols-2 gap-2 text-xs">
                  <div className="rounded-xl bg-slate-50 p-2 ring-1 ring-slate-200"><p className="font-bold uppercase text-slate-500">Allocated</p><p className="mt-1 font-extrabold">{gbp(row.confirmed_allocated_gbp)}</p></div>
                  <div className="rounded-xl bg-slate-50 p-2 ring-1 ring-slate-200"><p className="font-bold uppercase text-slate-500">Open</p><p className="mt-1 font-extrabold">{gbp(row.confirmed_unallocated_gbp)}</p></div>
                  <div className="rounded-xl bg-slate-50 p-2 ring-1 ring-slate-200"><p className="font-bold uppercase text-slate-500">Account</p><p className="mt-1 font-semibold">{pretty(row.statement_account_context)}</p></div>
                  <div className="rounded-xl bg-slate-50 p-2 ring-1 ring-slate-200"><p className="font-bold uppercase text-slate-500">Readiness</p><p className="mt-1 font-semibold">{classification.readiness}</p></div>
                </div>
                <div className="mt-3 rounded-xl bg-slate-50 p-3 text-xs text-slate-600 ring-1 ring-slate-200">
                  <p className="font-bold text-slate-900">Boundary</p>
                  <p className="mt-1">{classification.boundary}</p>
                </div>
                <code className="mt-3 block rounded-xl bg-slate-950 p-3 text-[11px] leading-5 text-slate-100">{controlSummary}</code>
              </article>
            );
          })}
        </div>
      </div>
    </section>
  );
}

export default function DvaReviewPackLayout({ children }: { children: ReactNode }) {
  return (
    <>
      <ReviewPackV2Summary />
      {children}
    </>
  );
}
