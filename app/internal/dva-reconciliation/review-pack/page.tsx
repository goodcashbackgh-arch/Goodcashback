import Link from "next/link";
import { createClient } from "@/utils/supabase/server";

type SearchParamsValue = Record<string, string | string[] | undefined>;
type Row = Record<string, unknown>;

type ImporterRow = {
  id: string;
  company_name: string | null;
  trading_name: string | null;
};

type StatementLineRow = {
  dva_statement_line_id: string;
  importer_id: string | null;
  statement_date: string | null;
  reference_raw: string | null;
  retailer_name_ref: string | null;
  auth_id_ref: string | null;
  direction: string | null;
  amount_local_ccy: number | string | null;
  local_ccy: string | null;
  statement_gbp_amount: number | string | null;
  match_status: string | null;
  confirmed_allocated_gbp: number | string | null;
  supplier_invoice_allocated_gbp: number | string | null;
  retailer_refund_allocated_gbp: number | string | null;
  fx_card_or_fee_allocated_gbp: number | string | null;
  exception_or_hold_allocated_gbp: number | string | null;
  active_allocation_count: number | string | null;
  confirmed_unallocated_gbp: number | string | null;
  confirmed_balanced_yn: boolean | string | null;
};

type AllocationRow = {
  allocation_id: string;
  importer_id: string | null;
  dva_statement_line_id: string;
  allocation_type: string | null;
  allocation_status: string | null;
  supplier_invoice_ref: string | null;
  dispute_id: string | null;
  order_ref: string | null;
  allocated_gbp_amount: number | string | null;
  notes: string | null;
  created_at: string | null;
};

type FundingRow = {
  dva_statement_line_id: string;
  importer_id: string | null;
  reconciled_order_id: string | null;
  reconciled_gbp_amount: number | string | null;
  reconciled_at: string | null;
};

type DisputeRow = {
  id: string;
  order_id: string | null;
  desired_outcome: string | null;
  status: string | null;
  amount_impact_gbp: number | string | null;
  resolved_at: string | null;
  raised_at: string | null;
};

type OrderRow = {
  id: string;
  order_ref: string | null;
  importer_id: string | null;
  retailer_id: string | null;
  status: string | null;
};

type RetailerRow = {
  id: string;
  name: string | null;
};

const gbpFormatter = new Intl.NumberFormat("en-GB", {
  style: "currency",
  currency: "GBP",
  minimumFractionDigits: 2,
});

const TERMINAL_EXCEPTION_STATUSES = new Set(["replaced", "awaiting_refund_credit", "refunded", "closed", "resolved"]);

function text(value: unknown) {
  if (Array.isArray(value)) return text(value[0]);
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  if (typeof value === "boolean") return value ? "true" : "false";
  return "";
}

function firstParam(value: unknown) {
  if (Array.isArray(value)) return text(value[0]);
  return text(value);
}

function num(value: unknown) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

function bool(value: unknown) {
  return value === true || text(value).toLowerCase() === "true";
}

function gbp(value: unknown) {
  return gbpFormatter.format(num(value));
}

function pretty(value: unknown) {
  const raw = text(value);
  return raw ? raw.replaceAll("_", " ") : "—";
}

function importerLabel(importer?: ImporterRow) {
  return importer?.trading_name || importer?.company_name || importer?.id || "All importers";
}

function statementText(row: StatementLineRow) {
  return row.reference_raw || row.retailer_name_ref || "No statement text";
}

function groupBy<T>(rows: T[], keyFn: (row: T) => string) {
  const grouped = new Map<string, T[]>();
  for (const row of rows) {
    const key = keyFn(row);
    if (!key) continue;
    grouped.set(key, [...(grouped.get(key) ?? []), row]);
  }
  return grouped;
}

function isTerminalException(dispute: DisputeRow) {
  return Boolean(dispute.resolved_at) || TERMINAL_EXCEPTION_STATUSES.has(text(dispute.status));
}

function readiness(row: StatementLineRow, allocations: AllocationRow[], funding?: FundingRow) {
  const direction = text(row.direction);
  const fundedAmount = num(funding?.reconciled_gbp_amount);
  const statementAmount = num(row.statement_gbp_amount);
  const hasFunding =
    direction === "in" &&
    fundedAmount > 0 &&
    Boolean(text(funding?.reconciled_order_id));

  if (hasFunding) {
    const open = Math.max(0, Math.round((statementAmount - fundedAmount) * 100) / 100);
    const balanced = open <= 0.009;

    return {
      ready: balanced,
      balanced,
      open: balanced ? 0 : open,
      supplier: 0,
      refund: 0,
      fxOrFee: 0,
      exceptionOrHold: 0,
      allocationCount: 0,
      fundingAmount: fundedAmount,
      fundingOrderId: text(funding?.reconciled_order_id),
      fundingAt: text(funding?.reconciled_at),
      explanation: balanced
        ? `Order funding applied: ${gbp(fundedAmount)}.`
        : `${gbp(open)} still open after order funding.`,
    };
  }

  const balanced = bool(row.confirmed_balanced_yn);
  const open = num(row.confirmed_unallocated_gbp);
  const supplier = num(row.supplier_invoice_allocated_gbp);
  const refund = num(row.retailer_refund_allocated_gbp);
  const fxOrFee = num(row.fx_card_or_fee_allocated_gbp);
  const exceptionOrHold = num(row.exception_or_hold_allocated_gbp);
  const held = allocations.some((allocation) => text(allocation.allocation_status) === "held");
  const allocationCount = num(row.active_allocation_count);
  const blockers: string[] = [];

  if (!balanced) blockers.push(open > 0 ? `${gbp(open)} still open` : "line is not balanced");
  if (held) blockers.push("held allocation exists");
  if (exceptionOrHold > 0) blockers.push(`${gbp(exceptionOrHold)} allocated to exception/hold`);
  if (allocationCount === 0) blockers.push("no active allocation");

  const ready = balanced && !held && exceptionOrHold === 0 && allocationCount > 0;
  return {
    ready,
    balanced,
    open,
    supplier,
    refund,
    fxOrFee,
    exceptionOrHold,
    allocationCount,
    fundingAmount: 0,
    fundingOrderId: "",
    fundingAt: "",
    explanation: ready
      ? "Ready for accounting review. Statement value is fully explained without active holds."
      : blockers.join(" · ") || "Review required",
  };
}

function readinessTone(ready: boolean, balanced: boolean) {
  if (ready) return "border-emerald-200 bg-emerald-50 text-emerald-800";
  if (balanced) return "border-sky-200 bg-sky-50 text-sky-800";
  return "border-amber-200 bg-amber-50 text-amber-800";
}

function allocationTarget(row: AllocationRow) {
  const type = text(row.allocation_type);
  if (type === "supplier_invoice") return row.supplier_invoice_ref || "Supplier invoice";
  if (type === "retailer_refund") return "Retailer refund";
  if (type === "fx_card_difference") return "FX/card difference";
  if (type === "bank_fee") return "Bank/card fee";
  if (type === "exception_hold") return "Exception hold";
  if (type === "not_charged_closure") return "Not charged closure";
  if (type === "unmatched_hold") return "Unmatched hold";
  return pretty(type);
}

function statusHref(params: SearchParamsValue, status: string) {
  const query = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) {
    if (key === "status") continue;
    const first = Array.isArray(value) ? value[0] : value;
    if (first) query.set(key, first);
  }
  query.set("status", status);
  return `/internal/dva-reconciliation/review-pack?${query.toString()}`;
}

function exceptionActionsHref(importerId: string) {
  const query = new URLSearchParams();
  if (importerId) query.set("importer_id", importerId);
  query.set("status", "open");
  const suffix = query.toString();
  return `/internal/dva-reconciliation/exception-actions${suffix ? `?${suffix}` : ""}`;
}

export default async function DvaAccountingReviewPackPage({
  searchParams,
}: {
  searchParams?: SearchParamsValue | Promise<SearchParamsValue>;
}) {
  const params = searchParams ? await Promise.resolve(searchParams) : {};
  const requestedImporterId = firstParam(params.importer_id);
  const status = firstParam(params.status) || "needs";
  const supabase = await createClient();

  let statementQuery = supabase
    .from("dva_statement_line_allocation_summary_vw")
    .select("dva_statement_line_id, importer_id, statement_date, reference_raw, retailer_name_ref, auth_id_ref, direction, amount_local_ccy, local_ccy, statement_gbp_amount, match_status, confirmed_allocated_gbp, supplier_invoice_allocated_gbp, retailer_refund_allocated_gbp, fx_card_or_fee_allocated_gbp, exception_or_hold_allocated_gbp, active_allocation_count, confirmed_unallocated_gbp, confirmed_balanced_yn")
    .order("statement_date", { ascending: false })
    .limit(250);

  if (requestedImporterId) statementQuery = statementQuery.eq("importer_id", requestedImporterId);

  let fundingQuery = supabase
    .from("day2_dva_review_worklist_vw")
    .select("dva_statement_line_id, importer_id, reconciled_order_id, reconciled_gbp_amount, reconciled_at")
    .eq("reconciliation_type", "order_funding")
    .not("reconciled_order_id", "is", null)
    .gt("reconciled_gbp_amount", 0)
    .limit(750);

  if (requestedImporterId) fundingQuery = fundingQuery.eq("importer_id", requestedImporterId);

  const [statementResult, importersResult, allocationResult, fundingResult, retailersResult] = await Promise.all([
    statementQuery,
    supabase.from("importers").select("id, company_name, trading_name").order("company_name", { ascending: true }).limit(200),
    supabase
      .from("dva_statement_line_allocation_detail_vw")
      .select("allocation_id, importer_id, dva_statement_line_id, allocation_type, allocation_status, supplier_invoice_ref, dispute_id, order_ref, allocated_gbp_amount, notes, created_at")
      .in("allocation_status", ["confirmed", "held"])
      .order("created_at", { ascending: false })
      .limit(750),
    fundingQuery,
    supabase.from("retailers").select("id, name").limit(500),
  ]);

  const statementLines = (statementResult.data ?? []) as unknown as StatementLineRow[];
  const importers = (importersResult.data ?? []) as unknown as ImporterRow[];
  const selectedImporter = importers.find((importer) => importer.id === requestedImporterId);
  const allocationRows = ((allocationResult.data ?? []) as unknown as AllocationRow[]).filter((allocation) => {
    return !requestedImporterId || allocation.importer_id === requestedImporterId;
  });
  const allocationsByLineId = groupBy(allocationRows, (allocation) => allocation.dva_statement_line_id);

  const fundingRows = ((fundingResult.data ?? []) as unknown as FundingRow[]).filter((funding) => {
    return !requestedImporterId || funding.importer_id === requestedImporterId;
  });
  const fundingByLineId = groupBy(fundingRows, (funding) => funding.dva_statement_line_id);

  let ordersQuery = supabase
    .from("orders")
    .select("id, order_ref, importer_id, retailer_id, status")
    .order("created_at", { ascending: false })
    .limit(500);
  if (requestedImporterId) ordersQuery = ordersQuery.eq("importer_id", requestedImporterId);

  const { data: orderData } = await ordersQuery;
  const orders = (orderData ?? []) as unknown as OrderRow[];
  const ordersById = new Map(orders.map((order) => [order.id, order]));
  const retailersById = new Map(((retailersResult.data ?? []) as unknown as RetailerRow[]).map((retailer) => [retailer.id, retailer]));

  const { data: disputeData, error: disputeError } = await supabase
    .from("disputes")
    .select("id, order_id, desired_outcome, status, amount_impact_gbp, resolved_at, raised_at")
    .order("raised_at", { ascending: false })
    .limit(500);

  const openDisputes = ((disputeData ?? []) as unknown as DisputeRow[]).filter((dispute) => {
    const order = dispute.order_id ? ordersById.get(dispute.order_id) : undefined;
    const importerOk = !requestedImporterId || Boolean(order && order.importer_id === requestedImporterId);
    return importerOk && !isTerminalException(dispute);
  });

  const enrichedLines = statementLines.map((line) => {
    const allocations = allocationsByLineId.get(line.dva_statement_line_id) ?? [];
    const funding = fundingByLineId.get(line.dva_statement_line_id)?.[0];
    const state = readiness(line, allocations, funding);
    return { line, allocations, state };
  });

  const visibleLines = enrichedLines.filter(({ state }) => {
    if (status === "ready") return state.ready;
    if (status === "balanced") return state.balanced && !state.ready;
    if (status === "all") return true;
    return !state.ready;
  });

  const readyCount = enrichedLines.filter((item) => item.state.ready).length;
  const balancedReviewCount = enrichedLines.filter((item) => item.state.balanced && !item.state.ready).length;
  const needsCount = enrichedLines.filter((item) => !item.state.ready).length;
  const openAmount = enrichedLines.reduce((sum, item) => sum + item.state.open, 0);

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 lg:px-8">
      <div className="mx-auto max-w-7xl space-y-5">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <Link href="/internal/dva-reconciliation/workspace" className="text-sm font-semibold text-sky-600">← Back to matching workspace</Link>
          <div className="mt-5 grid gap-5 lg:grid-cols-[minmax(0,1fr)_auto] lg:items-start">
            <div className="min-w-0">
              <p className="text-xs font-bold uppercase tracking-[0.22em] text-sky-600">DVA/card accounting review pack</p>
              <h1 className="mt-2 max-w-3xl text-3xl font-bold tracking-tight sm:text-4xl lg:text-5xl">Statement-line control pack</h1>
              <p className="mt-3 max-w-3xl text-sm leading-6 text-slate-600 sm:text-base">
                Read-only pack showing statement lines with supplier invoice, refund, FX/card, fee, exception and order-funding explanations before accounting handoff. No posting and no financial state changes happen here.
              </p>
            </div>
            <div className="grid w-full gap-2 sm:flex sm:w-auto sm:flex-wrap sm:justify-start lg:justify-end">
              <Link href="/internal/dva-reconciliation/allocations" className="rounded-xl border border-slate-200 bg-white px-4 py-2 text-center text-sm font-semibold text-slate-700 shadow-sm hover:bg-slate-50">
                Active allocations
              </Link>
              <Link href={exceptionActionsHref(requestedImporterId)} className="rounded-xl bg-slate-950 px-4 py-2 text-center text-sm font-semibold text-white shadow-sm hover:bg-slate-800">
                Exception actions
              </Link>
            </div>
          </div>
        </section>

        <section className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <div className="rounded-2xl border border-emerald-200 bg-emerald-50 p-4">
            <p className="text-xs font-bold uppercase tracking-wide text-emerald-700">Ready lines</p>
            <p className="mt-2 text-2xl font-extrabold text-emerald-950">{readyCount}</p>
          </div>
          <div className="rounded-2xl border border-sky-200 bg-sky-50 p-4">
            <p className="text-xs font-bold uppercase tracking-wide text-sky-700">Balanced but review</p>
            <p className="mt-2 text-2xl font-extrabold text-sky-950">{balancedReviewCount}</p>
          </div>
          <div className="rounded-2xl border border-amber-200 bg-amber-50 p-4">
            <p className="text-xs font-bold uppercase tracking-wide text-amber-700">Needs control work</p>
            <p className="mt-2 text-2xl font-extrabold text-amber-950">{needsCount}</p>
          </div>
          <div className="rounded-2xl border border-slate-200 bg-white p-4">
            <p className="text-xs font-bold uppercase tracking-wide text-slate-500">Total open</p>
            <p className="mt-2 text-2xl font-extrabold text-slate-950">{gbp(openAmount)}</p>
          </div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
          <form className="grid gap-3 md:grid-cols-[1fr_auto_auto] md:items-end" action="/internal/dva-reconciliation/review-pack">
            <label className="grid gap-1 text-xs font-semibold text-slate-600">
              Importer
              <select name="importer_id" defaultValue={requestedImporterId} className="rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm text-slate-900">
                <option value="">All importers</option>
                {importers.map((importer) => (
                  <option key={importer.id} value={importer.id}>{importerLabel(importer)}</option>
                ))}
              </select>
            </label>
            <label className="grid gap-1 text-xs font-semibold text-slate-600">
              Status
              <select name="status" defaultValue={status} className="rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm text-slate-900">
                <option value="needs">Needs control work</option>
                <option value="ready">Ready for accounting review</option>
                <option value="balanced">Balanced but still review</option>
                <option value="all">All</option>
              </select>
            </label>
            <button className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white" type="submit">Apply</button>
          </form>
          <div className="mt-3 flex flex-wrap gap-2 text-xs font-semibold">
            <Link className="rounded-full bg-amber-50 px-3 py-1 text-amber-800 ring-1 ring-amber-200" href={statusHref(params, "needs")}>Needs</Link>
            <Link className="rounded-full bg-emerald-50 px-3 py-1 text-emerald-800 ring-1 ring-emerald-200" href={statusHref(params, "ready")}>Ready</Link>
            <Link className="rounded-full bg-sky-50 px-3 py-1 text-sky-800 ring-1 ring-sky-200" href={statusHref(params, "balanced")}>Balanced review</Link>
            <Link className="rounded-full bg-slate-100 px-3 py-1 text-slate-700 ring-1 ring-slate-200" href={statusHref(params, "all")}>All</Link>
          </div>
        </section>

        {statementResult.error ? <section className="rounded-3xl border border-rose-200 bg-rose-50 p-5 text-sm font-semibold text-rose-800">{statementResult.error.message}</section> : null}
        {allocationResult.error ? <section className="rounded-3xl border border-rose-200 bg-rose-50 p-5 text-sm font-semibold text-rose-800">{allocationResult.error.message}</section> : null}
        {fundingResult.error ? <section className="rounded-3xl border border-rose-200 bg-rose-50 p-5 text-sm font-semibold text-rose-800">{fundingResult.error.message}</section> : null}
        {disputeError ? <section className="rounded-3xl border border-rose-200 bg-rose-50 p-5 text-sm font-semibold text-rose-800">{disputeError.message}</section> : null}

        <section className="rounded-3xl border border-slate-200 bg-white shadow-sm">
          <div className="border-b border-slate-100 px-4 py-3 text-sm font-semibold text-slate-700">
            Showing {visibleLines.length} statement line(s) for {importerLabel(selectedImporter)}
          </div>
          {visibleLines.length === 0 ? (
            <div className="p-8 text-center text-sm text-slate-500">No statement lines match this filter.</div>
          ) : (
            <div className="divide-y divide-slate-100">
              {visibleLines.map(({ line, allocations, state }) => {
                const fundedOrder = state.fundingOrderId ? ordersById.get(state.fundingOrderId) : undefined;
                return (
                  <article key={line.dva_statement_line_id} className="p-4">
                    <div className="grid gap-4 lg:grid-cols-[1.25fr_1fr]">
                      <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm">
                        <div className="flex flex-wrap items-start justify-between gap-3">
                          <div>
                            <p className="text-lg font-bold text-slate-950">{line.statement_date || "No date"} · {text(line.direction).toUpperCase() || "—"} · {gbp(line.statement_gbp_amount)}</p>
                            <p className="mt-1 break-words text-sm text-slate-600">{statementText(line)}</p>
                            <p className="mt-1 text-xs text-slate-500">Auth/ref {line.auth_id_ref || "—"} · Local {gbp(line.amount_local_ccy)} {line.local_ccy || ""}</p>
                          </div>
                          <span className={`rounded-full border px-3 py-1 text-xs font-bold ${readinessTone(state.ready, state.balanced)}`}>
                            {state.ready ? "Ready" : state.balanced ? "Balanced review" : "Needs work"}
                          </span>
                        </div>

                        <div className="mt-4 grid gap-3 sm:grid-cols-5">
                          <div className="rounded-xl bg-slate-50 p-3 ring-1 ring-slate-200">
                            <p className="text-[11px] font-bold uppercase tracking-wide text-slate-500">{state.fundingAmount > 0 ? "Funding" : "Supplier"}</p>
                            <p className="mt-1 font-extrabold text-slate-950">{gbp(state.fundingAmount > 0 ? state.fundingAmount : state.supplier)}</p>
                          </div>
                          <div className="rounded-xl bg-slate-50 p-3 ring-1 ring-slate-200"><p className="text-[11px] font-bold uppercase tracking-wide text-slate-500">Refund</p><p className="mt-1 font-extrabold text-slate-950">{gbp(state.refund)}</p></div>
                          <div className="rounded-xl bg-slate-50 p-3 ring-1 ring-slate-200"><p className="text-[11px] font-bold uppercase tracking-wide text-slate-500">FX/fee</p><p className="mt-1 font-extrabold text-slate-950">{gbp(state.fxOrFee)}</p></div>
                          <div className="rounded-xl bg-slate-50 p-3 ring-1 ring-slate-200"><p className="text-[11px] font-bold uppercase tracking-wide text-slate-500">Exception/hold</p><p className="mt-1 font-extrabold text-slate-950">{gbp(state.exceptionOrHold)}</p></div>
                          <div className="rounded-xl bg-amber-50 p-3 ring-1 ring-amber-200"><p className="text-[11px] font-bold uppercase tracking-wide text-amber-700">Open</p><p className="mt-1 font-extrabold text-amber-950">{gbp(state.open)}</p></div>
                        </div>

                        <div className="mt-3 rounded-xl bg-slate-50 p-3 text-sm text-slate-600">
                          <p className="font-semibold text-slate-900">Accounting review status</p>
                          <p className="mt-1">{state.explanation}</p>
                        </div>
                      </div>

                      <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
                        <div className="flex items-center justify-between gap-3">
                          <h2 className="text-sm font-bold text-slate-950">{state.fundingAmount > 0 ? "Funding trail" : "Allocation trail"}</h2>
                          <span className="rounded-full bg-white px-2 py-1 text-xs font-bold text-slate-700 ring-1 ring-slate-200">{state.fundingAmount > 0 ? 1 : allocations.length} row(s)</span>
                        </div>
                        {state.fundingAmount > 0 ? (
                          <div className="mt-4 rounded-xl bg-white p-3 text-sm ring-1 ring-slate-200">
                            <div className="flex flex-wrap items-center justify-between gap-2">
                              <p className="font-bold text-slate-950">{gbp(state.fundingAmount)} → Order funding</p>
                              <span className="rounded-full bg-emerald-50 px-2 py-1 text-[11px] font-bold text-emerald-700 ring-1 ring-emerald-200">reconciled</span>
                            </div>
                            <p className="mt-1 text-xs text-slate-500">
                              Order {fundedOrder?.order_ref || state.fundingOrderId || "—"} · Reconciled {state.fundingAt || "—"}
                            </p>
                          </div>
                        ) : allocations.length === 0 ? (
                          <p className="mt-4 text-sm text-slate-500">No active confirmed or held allocations for this statement line.</p>
                        ) : (
                          <div className="mt-4 space-y-2">
                            {allocations.map((allocation) => (
                              <div key={allocation.allocation_id} className="rounded-xl bg-white p-3 text-sm ring-1 ring-slate-200">
                                <div className="flex flex-wrap items-center justify-between gap-2">
                                  <p className="font-bold text-slate-950">{gbp(allocation.allocated_gbp_amount)} → {allocationTarget(allocation)}</p>
                                  <span className="rounded-full bg-slate-100 px-2 py-1 text-[11px] font-bold text-slate-700">{pretty(allocation.allocation_status)}</span>
                                </div>
                                <p className="mt-1 text-xs text-slate-500">Type {pretty(allocation.allocation_type)} · Order {allocation.order_ref || "—"} · Dispute {allocation.dispute_id || "—"}</p>
                                {allocation.notes ? <p className="mt-2 text-xs text-slate-600">{allocation.notes}</p> : null}
                              </div>
                            ))}
                          </div>
                        )}
                      </div>
                    </div>
                  </article>
                );
              })}
            </div>
          )}
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
          <div className="flex flex-wrap items-center justify-between gap-3">
            <div>
              <h2 className="text-lg font-bold text-slate-950">Open exception action cases</h2>
              <p className="mt-1 text-sm text-slate-600">Unresolved refund/replacement cases for the selected importer. Use the action centre to approve refund pursuit or accept final retailer outcomes once the gates are met.</p>
            </div>
            <div className="flex flex-wrap items-center gap-2">
              <span className="rounded-full bg-amber-50 px-3 py-1 text-xs font-bold text-amber-800 ring-1 ring-amber-200">{openDisputes.length} open</span>
              <Link href={exceptionActionsHref(requestedImporterId)} className="rounded-full bg-slate-950 px-3 py-1 text-xs font-bold text-white">Open action centre</Link>
            </div>
          </div>

          {openDisputes.length === 0 ? (
            <p className="mt-4 text-sm text-slate-500">No open exception action cases found for this filter.</p>
          ) : (
            <div className="mt-4 grid gap-3 lg:grid-cols-2">
              {openDisputes.slice(0, 20).map((dispute) => {
                const order = dispute.order_id ? ordersById.get(dispute.order_id) : undefined;
                const retailer = order?.retailer_id ? retailersById.get(order.retailer_id) : undefined;
                return (
                  <div key={dispute.id} className="rounded-2xl border border-amber-200 bg-amber-50 p-4">
                    <p className="text-sm font-bold text-amber-950">{pretty(dispute.desired_outcome)} · {pretty(dispute.status)}</p>
                    <p className="mt-1 text-sm text-amber-900">Impact {gbp(dispute.amount_impact_gbp)} · Order {order?.order_ref || "—"} · {retailer?.name || "No retailer"}</p>
                    <div className="mt-3 flex flex-wrap gap-2">
                      <Link href={`/internal/exceptions/${dispute.id}`} className="rounded-xl bg-white px-3 py-2 text-xs font-bold text-amber-900 ring-1 ring-amber-200">Open supervisor review</Link>
                      <Link href={exceptionActionsHref(requestedImporterId)} className="rounded-xl bg-amber-700 px-3 py-2 text-xs font-bold text-white">Action centre</Link>
                    </div>
                  </div>
                );
              })}
            </div>
          )}
        </section>
      </div>
    </main>
  );
}
