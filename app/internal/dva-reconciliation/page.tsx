import Link from "next/link";
import { createClient } from "@/utils/supabase/server";
import {
  allocateStatementLineToFxCardOrFeeAction,
  allocateStatementLineToSupplierInvoiceAction,
  generateSupplierInvoiceSuggestionsAction,
} from "./actions";

type Row = Record<string, unknown>;
type ReadError = { source: string; message: string };
type SearchParamsValue = Record<string, string | string[] | undefined>;

const gbpFormatter = new Intl.NumberFormat("en-GB", {
  style: "currency",
  currency: "GBP",
  minimumFractionDigits: 2,
});

function text(value: unknown) {
  return typeof value === "string" ? value : "";
}

function maybeText(value: unknown) {
  const output = text(value).trim();
  return output || null;
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

function addReadError(errors: ReadError[], source: string, error: unknown) {
  if (
    error &&
    typeof error === "object" &&
    "message" in error &&
    typeof (error as { message?: unknown }).message === "string"
  ) {
    errors.push({ source, message: (error as { message: string }).message });
  }
}

function byId(rows: Row[]) {
  const mapped = new Map<string, Row>();
  for (const row of rows) {
    const id = text(row.id);
    if (id) mapped.set(id, row);
  }
  return mapped;
}

function groupBy(rows: Row[], key: string) {
  const grouped = new Map<string, Row[]>();
  for (const row of rows) {
    const id = text(row[key]);
    if (!id) continue;
    grouped.set(id, [...(grouped.get(id) ?? []), row]);
  }
  return grouped;
}

function progressed(line: Row) {
  return ["y", "yes", "true", "1"].includes(text(line.eligible_for_invoice_yn).toLowerCase());
}

function statusClass(row: Row) {
  if (bool(row.confirmed_balanced_yn)) return "bg-emerald-50 text-emerald-700 ring-emerald-200";
  if (num(row.open_allocated_gbp) > 0) return "bg-sky-50 text-sky-700 ring-sky-200";
  if (text(row.direction) === "in") return "bg-indigo-50 text-indigo-700 ring-indigo-200";
  return "bg-amber-50 text-amber-700 ring-amber-200";
}

function statusLabel(row: Row) {
  if (bool(row.confirmed_balanced_yn)) return "balanced";
  if (num(row.open_allocated_gbp) > 0) return "allocation draft/held";
  if (text(row.direction) === "in") return "funding route";
  return "needs allocation";
}

function statusFilter(row: Row) {
  if (bool(row.confirmed_balanced_yn)) return "balanced";
  if (num(row.open_allocated_gbp) > 0) return "draft";
  return "needs";
}

function actionMessage(row: Row) {
  if (bool(row.confirmed_balanced_yn)) return "Balanced — no further action.";
  if (text(row.direction) === "out") return "Use the matching workspace or unmatched OUT triage.";
  if (text(row.direction) === "in") return "Funding route — use Importer Funding Control.";
  return "No action here.";
}

function canAllocateResidual(row: Row) {
  return text(row.direction) === "out" && !bool(row.confirmed_balanced_yn) && num(row.confirmed_unallocated_gbp) > 0;
}

function preferredSuggestion(line: Row, suggestions: Row[]) {
  if (text(line.direction) === "out") {
    return (
      suggestions.find((suggestion) => text(suggestion.suggested_match_type) === "supplier_invoice") ??
      suggestions.find((suggestion) => text(suggestion.suggested_match_type) === "dispute") ??
      suggestions.find((suggestion) => text(suggestion.suggested_match_type) === "order") ??
      suggestions[0]
    );
  }

  return (
    suggestions.find((suggestion) => text(suggestion.suggested_match_type) === "order") ??
    suggestions[0]
  );
}

function filterHref(currentParams: SearchParamsValue, nextStatus: string, nextImporterId?: string) {
  const params = new URLSearchParams();
  for (const [key, value] of Object.entries(currentParams)) {
    if (key === "status" || key === "importer_id") continue;
    const firstValue = Array.isArray(value) ? value[0] : value;
    if (firstValue) params.set(key, firstValue);
  }
  params.set("status", nextStatus);
  if (nextImporterId) params.set("importer_id", nextImporterId);
  return `/internal/dva-reconciliation?${params.toString()}`;
}

function creditSignedAmount(row: Row) {
  const amount = num(row.amount_gbp);
  const direction = text(row.direction).toLowerCase();
  const entryType = text(row.entry_type).toLowerCase();

  if (["debit", "out", "applied", "used"].includes(direction) || entryType.includes("applied")) {
    return -amount;
  }

  if (["credit", "in", "available"].includes(direction) || entryType.includes("credit") || entryType.includes("overfund")) {
    return amount;
  }

  return amount;
}

function SummaryMetric({
  label,
  value,
  hint,
  tone = "slate",
}: {
  label: string;
  value: string;
  hint: string;
  tone?: "slate" | "sky" | "emerald" | "amber" | "rose" | "violet";
}) {
  const toneClass = {
    slate: "bg-slate-50 text-slate-950 ring-slate-200",
    sky: "bg-sky-50 text-sky-950 ring-sky-200",
    emerald: "bg-emerald-50 text-emerald-950 ring-emerald-200",
    amber: "bg-amber-50 text-amber-950 ring-amber-200",
    rose: "bg-rose-50 text-rose-950 ring-rose-200",
    violet: "bg-violet-50 text-violet-950 ring-violet-200",
  }[tone];

  return (
    <div className={`rounded-2xl p-4 ring-1 ${toneClass}`}>
      <p className="text-xs font-semibold uppercase tracking-wide opacity-70">{label}</p>
      <p className="mt-2 text-2xl font-semibold">{value}</p>
      <p className="mt-1 text-xs leading-5 opacity-75">{hint}</p>
    </div>
  );
}

function RouteCard({
  title,
  body,
  href,
  cta,
  tone = "slate",
}: {
  title: string;
  body: string;
  href: string;
  cta: string;
  tone?: "slate" | "sky" | "emerald" | "amber" | "rose" | "violet";
}) {
  const toneClass = {
    slate: "border-slate-200 bg-slate-50 text-slate-950",
    sky: "border-sky-200 bg-sky-50 text-sky-950",
    emerald: "border-emerald-200 bg-emerald-50 text-emerald-950",
    amber: "border-amber-200 bg-amber-50 text-amber-950",
    rose: "border-rose-200 bg-rose-50 text-rose-950",
    violet: "border-violet-200 bg-violet-50 text-violet-950",
  }[tone];

  return (
    <Link href={href} className={`rounded-2xl border p-4 transition hover:bg-white ${toneClass}`}>
      <h3 className="text-sm font-bold">{title}</h3>
      <p className="mt-2 text-xs leading-5 opacity-75">{body}</p>
      <p className="mt-3 text-xs font-extrabold uppercase tracking-wide">{cta} →</p>
    </Link>
  );
}

function SupplierInvoiceAllocationForm({ row, invoiceId, defaultAmount }: { row: Row; invoiceId: string; defaultAmount: string }) {
  return (
    <form action={allocateStatementLineToSupplierInvoiceAction} className="mt-3 rounded-2xl border border-sky-200 bg-sky-50 p-3">
      <input type="hidden" name="dva_statement_line_id" value={text(row.dva_statement_line_id)} />
      <input type="hidden" name="supplier_invoice_id" value={invoiceId} />
      <label className="block text-xs font-semibold text-sky-900">Allocate to suggested invoice</label>
      <input className="mt-2 w-full rounded-xl border border-sky-200 bg-white px-3 py-2 text-sm" name="allocated_gbp_amount" type="number" min="0.01" step="0.01" defaultValue={defaultAmount} />
      <input className="mt-2 w-full rounded-xl border border-sky-200 bg-white px-3 py-2 text-xs" name="notes" placeholder="Optional note" />
      <button className="mt-2 rounded-xl bg-sky-600 px-3 py-2 text-xs font-semibold text-white" type="submit">Allocate</button>
    </form>
  );
}

function ResidualAllocationForm({ row }: { row: Row }) {
  const defaultAmount = Math.max(0, num(row.confirmed_unallocated_gbp)).toFixed(2);

  return (
    <form action={allocateStatementLineToFxCardOrFeeAction} className="mt-3 rounded-2xl border border-violet-200 bg-violet-50 p-3">
      <input type="hidden" name="dva_statement_line_id" value={text(row.dva_statement_line_id)} />
      <label className="block text-xs font-semibold text-violet-950">Allocate residual</label>
      <select className="mt-2 w-full rounded-xl border border-violet-200 bg-white px-3 py-2 text-xs" name="allocation_type" defaultValue="fx_card_difference">
        <option value="fx_card_difference">FX/card difference</option>
        <option value="bank_fee">Bank fee</option>
      </select>
      <input className="mt-2 w-full rounded-xl border border-violet-200 bg-white px-3 py-2 text-sm" name="allocated_gbp_amount" type="number" min="0.01" step="0.01" defaultValue={defaultAmount} />
      <input className="mt-2 w-full rounded-xl border border-violet-200 bg-white px-3 py-2 text-xs" name="notes" placeholder="Optional note" />
      <button className="mt-2 rounded-xl bg-violet-600 px-3 py-2 text-xs font-semibold text-white" type="submit">Allocate residual</button>
    </form>
  );
}

export default async function DvaReconciliationWorkbenchPage({
  searchParams,
}: {
  searchParams?: SearchParamsValue | Promise<SearchParamsValue>;
}) {
  const params = searchParams ? await Promise.resolve(searchParams) : {};
  const allocationSuccess = firstParam(params.allocation_success);
  const allocationError = firstParam(params.allocation_error);
  const selectedStatus = firstParam(params.status) || "needs";
  const selectedImporterId = firstParam(params.importer_id);
  const supabase = await createClient();

  const [
    allocationSummaryResult,
    statementsResult,
    suggestionsResult,
    importersResult,
    ordersResult,
    retailersResult,
    invoicesResult,
    invoiceLinesResult,
    disputesResult,
    creditLedgerResult,
  ] = await Promise.all([
    supabase
      .from("dva_statement_line_allocation_summary_vw")
      .select(
        "dva_statement_line_id, dva_statement_id, importer_id, statement_date, reference_raw, direction, amount_local_ccy, local_ccy, fx_rate_applied, card_markup_pct_applied, statement_gbp_amount, auth_id_ref, retailer_name_ref, match_status, confirmed_allocated_gbp, open_allocated_gbp, supplier_invoice_allocated_gbp, retailer_refund_allocated_gbp, fx_card_or_fee_allocated_gbp, exception_or_hold_allocated_gbp, active_allocation_count, confirmed_unallocated_gbp, confirmed_balanced_yn"
      )
      .order("statement_date", { ascending: false })
      .limit(100),
    supabase
      .from("dva_statements")
      .select("id, importer_id, source_bank, parse_status")
      .limit(100),
    supabase
      .from("match_suggestions")
      .select("id, dva_statement_line_id, suggested_match_type, suggested_match_id, confidence, variance_gbp, variance_days")
      .limit(200),
    supabase
      .from("importers")
      .select("id, company_name, trading_name, gcb_dva_ref, dva_card_last_4")
      .limit(200),
    supabase
      .from("orders")
      .select("id, order_ref, importer_id, retailer_id, order_total_gbp_declared, status, payment_auth_id, order_type")
      .order("created_at", { ascending: false })
      .limit(300),
    supabase.from("retailers").select("id, name").limit(300),
    supabase
      .from("supplier_invoices")
      .select("id, order_id, invoice_ref, invoice_pdf_url, ocr_invoice_ref, ocr_invoice_total_gbp, reconciliation_gbp_total, review_status")
      .order("uploaded_at", { ascending: false })
      .limit(300),
    supabase
      .from("supplier_invoice_lines")
      .select("id, supplier_invoice_id, amount_inc_vat_gbp, amount_confirmed, eligible_for_invoice_yn")
      .limit(1000),
    supabase
      .from("disputes")
      .select("id, order_id, desired_outcome, status, amount_impact_gbp, resolved_at")
      .order("raised_at", { ascending: false })
      .limit(300),
    supabase
      .from("importer_credit_ledger")
      .select("id, importer_id, entry_type, direction, amount_gbp, lock_reason")
      .limit(200),
  ]);

  const readErrors: ReadError[] = [];
  addReadError(readErrors, "dva_statement_line_allocation_summary_vw", allocationSummaryResult.error);
  addReadError(readErrors, "dva_statements", statementsResult.error);
  addReadError(readErrors, "match_suggestions", suggestionsResult.error);
  addReadError(readErrors, "importers", importersResult.error);
  addReadError(readErrors, "orders", ordersResult.error);
  addReadError(readErrors, "retailers", retailersResult.error);
  addReadError(readErrors, "supplier_invoices", invoicesResult.error);
  addReadError(readErrors, "supplier_invoice_lines", invoiceLinesResult.error);
  addReadError(readErrors, "disputes", disputesResult.error);
  addReadError(readErrors, "importer_credit_ledger", creditLedgerResult.error);

  const allocationRows = (allocationSummaryResult.data ?? []) as unknown as Row[];
  const statements = (statementsResult.data ?? []) as unknown as Row[];
  const suggestions = (suggestionsResult.data ?? []) as unknown as Row[];
  const importers = (importersResult.data ?? []) as unknown as Row[];
  const orders = (ordersResult.data ?? []) as unknown as Row[];
  const retailers = (retailersResult.data ?? []) as unknown as Row[];
  const invoices = (invoicesResult.data ?? []) as unknown as Row[];
  const invoiceLines = (invoiceLinesResult.data ?? []) as unknown as Row[];
  const disputes = (disputesResult.data ?? []) as unknown as Row[];
  const creditLedger = (creditLedgerResult.data ?? []) as unknown as Row[];

  const statementsById = byId(statements);
  const importersById = byId(importers);
  const ordersById = byId(orders);
  const retailersById = byId(retailers);
  const invoicesById = byId(invoices);
  const invoicesByOrderId = groupBy(invoices, "order_id");
  const invoiceLinesByInvoiceId = groupBy(invoiceLines, "supplier_invoice_id");
  const suggestionsByLineId = groupBy(suggestions, "dva_statement_line_id");
  const openDisputes = disputes.filter((row) => !maybeText(row.resolved_at));

  const enrichedRows = allocationRows.map((line) => {
    const statement = statementsById.get(text(line.dva_statement_id));
    const importer = importersById.get(text(line.importer_id));
    const lineSuggestions = suggestionsByLineId.get(text(line.dva_statement_line_id)) ?? [];
    const suggestion = preferredSuggestion(line, lineSuggestions);
    const suggestedInvoice = text(suggestion?.suggested_match_type) === "supplier_invoice"
      ? invoicesById.get(text(suggestion?.suggested_match_id))
      : undefined;
    const order = suggestedInvoice
      ? ordersById.get(text(suggestedInvoice.order_id))
      : text(suggestion?.suggested_match_type) === "order"
        ? ordersById.get(text(suggestion?.suggested_match_id))
        : undefined;
    const retailer = order ? retailersById.get(text(order.retailer_id)) : undefined;
    const orderInvoices = order ? invoicesByOrderId.get(text(order.id)) ?? [] : [];
    const invoice = suggestedInvoice ?? orderInvoices[0];
    const relatedLines = orderInvoices.flatMap((invoiceRow) => invoiceLinesByInvoiceId.get(text(invoiceRow.id)) ?? []);
    const progressedTotal = relatedLines
      .filter(progressed)
      .reduce((sum, lineRow) => sum + (num(lineRow.amount_confirmed) || num(lineRow.amount_inc_vat_gbp)), 0);
    const openExceptionTotal = order
      ? openDisputes
          .filter((dispute) => text(dispute.order_id) === text(order.id))
          .reduce((sum, dispute) => sum + num(dispute.amount_impact_gbp), 0)
      : 0;

    return {
      line,
      statement,
      importer,
      suggestion,
      suggestedInvoice,
      order,
      retailer,
      invoice,
      progressedTotal,
      openExceptionTotal,
    };
  });

  const scopedRows = enrichedRows.filter(({ line }) => !selectedImporterId || text(line.importer_id) === selectedImporterId);
  const scopedOrders = orders.filter((order) => !selectedImporterId || text(order.importer_id) === selectedImporterId);
  const scopedOrderIds = new Set(scopedOrders.map((order) => text(order.id)).filter(Boolean));
  const scopedOpenDisputes = openDisputes.filter((dispute) => scopedOrderIds.has(text(dispute.order_id)));
  const scopedCreditLedger = creditLedger.filter((row) => !selectedImporterId || text(row.importer_id) === selectedImporterId);

  const statementInTotal = scopedRows
    .filter(({ line }) => text(line.direction) === "in")
    .reduce((sum, { line }) => sum + num(line.statement_gbp_amount), 0);
  const statementOutTotal = scopedRows
    .filter(({ line }) => text(line.direction) === "out")
    .reduce((sum, { line }) => sum + num(line.statement_gbp_amount), 0);
  const supplierInvoiceAllocated = scopedRows.reduce((sum, { line }) => sum + num(line.supplier_invoice_allocated_gbp), 0);
  const retailerRefundAllocated = scopedRows.reduce((sum, { line }) => sum + num(line.retailer_refund_allocated_gbp), 0);
  const fxCardFeeAllocated = scopedRows.reduce((sum, { line }) => sum + num(line.fx_card_or_fee_allocated_gbp), 0);
  const exceptionOrHoldAllocated = scopedRows.reduce((sum, { line }) => sum + num(line.exception_or_hold_allocated_gbp), 0);
  const creditLedgerBalance = scopedCreditLedger.reduce((sum, row) => sum + creditSignedAmount(row), 0);
  const openExceptionTotalSummary = scopedOpenDisputes.reduce((sum, dispute) => sum + num(dispute.amount_impact_gbp), 0);
  const unmatchedInCount = scopedRows.filter(({ line }) => text(line.direction) === "in" && !bool(line.confirmed_balanced_yn) && num(line.confirmed_allocated_gbp) === 0).length;
  const unmatchedOutCount = scopedRows.filter(({ line }) => text(line.direction) === "out" && !bool(line.confirmed_balanced_yn) && num(line.confirmed_allocated_gbp) === 0).length;
  const indicativeNetPosition = statementInTotal + creditLedgerBalance - statementOutTotal;

  const filteredRows = scopedRows.filter(({ line }) => selectedStatus === "all" || statusFilter(line) === selectedStatus);

  const statusCounts = {
    all: scopedRows.length,
    needs: scopedRows.filter(({ line }) => statusFilter(line) === "needs").length,
    draft: scopedRows.filter(({ line }) => statusFilter(line) === "draft").length,
    balanced: scopedRows.filter(({ line }) => statusFilter(line) === "balanced").length,
  };

  const selectedImporter = selectedImporterId ? importersById.get(selectedImporterId) : undefined;

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-7xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href="/internal" className="text-sm font-semibold text-sky-600">← Back to internal dashboard</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">DVA/card control hub</p>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight">Route committed statement lines to the right control path</h1>
          <p className="mt-3 max-w-5xl text-sm leading-6 text-slate-600">
            This is the traffic-control page after statement rows are committed. It shows which lines need importer funding, supplier/refund/fee/hold matching, allocation reversal, review-pack sign-off, or exception action. It does not replace the governed funding, matching, allocation or Sage-readiness actions.
          </p>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div>
              <p className="text-sm font-medium uppercase tracking-[0.18em] text-sky-500">Where to act</p>
              <h2 className="mt-2 text-xl font-semibold">Choose the route based on the statement line</h2>
              <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">
                IN customer/importer money uses the funding path. Supplier purchases, refunds, FX/card differences, bank fees and holds use the matching/allocation path. Review pack is the confidence checkpoint before pre-Sage readiness.
              </p>
            </div>
          </div>
          <div className="mt-5 grid gap-3 md:grid-cols-2 xl:grid-cols-5">
            <RouteCard title="Customer/importer IN" body="Apply received money to order funding gaps or importer credit." href="/internal/funding" cta="Open funding control" tone="emerald" />
            <RouteCard title="Supplier / refund / fee / hold" body="Match statement lines to supplier invoices, refund exceptions, FX/card residuals, bank fees or holds." href="/internal/dva-reconciliation/workspace" cta="Open workspace" tone="sky" />
            <RouteCard title="Unmatched OUT" body="Investigate OUT lines before treating them as residuals or holds." href="/internal/dva-reconciliation/unmatched" cta="Open triage" tone="amber" />
            <RouteCard title="Active allocations" body="Review or reverse confirmed allocation rows without voiding statement batches." href="/internal/dva-reconciliation/allocations" cta="Open reversals" tone="violet" />
            <RouteCard title="Review pack" body="Prove each statement line is balanced, held or blocked before Sage readiness." href="/internal/dva-reconciliation/review-pack" cta="Open review pack" tone="slate" />
          </div>
        </section>

        {(allocationSuccess || allocationError) ? (
          <section className={`rounded-3xl border p-5 text-sm font-semibold leading-6 ${allocationSuccess ? "border-emerald-200 bg-emerald-50 text-emerald-900" : "border-rose-200 bg-rose-50 text-rose-900"}`}>
            {allocationSuccess || allocationError}
          </section>
        ) : null}

        {readErrors.length ? (
          <section className="rounded-3xl border border-rose-200 bg-rose-50 p-5 text-sm leading-6 text-rose-900">
            <h2 className="font-semibold">Read issues</h2>
            <ul className="mt-2 list-disc pl-5">
              {readErrors.map((error) => <li key={`${error.source}-${error.message}`}>{error.source}: {error.message}</li>)}
            </ul>
          </section>
        ) : null}

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
          <div className="grid gap-4 lg:grid-cols-[280px_1fr] lg:items-end">
            <form className="grid gap-2" action="/internal/dva-reconciliation">
              <input type="hidden" name="status" value={selectedStatus} />
              <label className="text-xs font-semibold uppercase tracking-wide text-slate-500">Importer</label>
              <select className="rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm" name="importer_id" defaultValue={selectedImporterId}>
                <option value="">All importers</option>
                {importers.map((importer) => (
                  <option key={text(importer.id)} value={text(importer.id)}>{text(importer.trading_name) || text(importer.company_name) || text(importer.id)}</option>
                ))}
              </select>
              <button className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white" type="submit">Apply importer filter</button>
            </form>

            <div className="flex flex-wrap gap-2">
              {[
                ["needs", "Needs route/action", statusCounts.needs],
                ["draft", "Part allocated / held", statusCounts.draft],
                ["balanced", "Balanced / completed", statusCounts.balanced],
                ["all", "All", statusCounts.all],
              ].map(([value, label, count]) => (
                <Link
                  key={String(value)}
                  className={`rounded-full px-4 py-2 text-sm font-semibold ring-1 ${selectedStatus === value ? "bg-slate-950 text-white ring-slate-950" : "bg-white text-slate-700 ring-slate-200"}`}
                  href={filterHref(params, String(value), selectedImporterId)}
                >
                  {String(label)} · {String(count)}
                </Link>
              ))}
            </div>
          </div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div>
              <p className="text-sm font-medium uppercase tracking-[0.18em] text-sky-500">Importer control position</p>
              <h2 className="mt-2 text-xl font-semibold">{selectedImporter ? (text(selectedImporter.trading_name) || text(selectedImporter.company_name) || "Selected importer") : "All importers"}</h2>
              <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">
                Use this summary to catch the £500-in / £450-spent / £50-open-position problem. It is a control view, not a replacement for funding or supplier-allocation RPCs.
              </p>
            </div>
            <Link className="rounded-xl bg-emerald-600 px-4 py-2 text-sm font-semibold text-white" href="/internal/funding">
              Open Importer Funding Control →
            </Link>
          </div>

          <div className="mt-5 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            <SummaryMetric label="IN statement lines" value={gbp(statementInTotal)} hint="Visible funding/credit inflows from committed statement lines." tone="emerald" />
            <SummaryMetric label="OUT statement lines" value={gbp(statementOutTotal)} hint="Visible card/supplier/refund/fee outflows from committed statement lines." tone="rose" />
            <SummaryMetric label="Credit ledger balance" value={gbp(creditLedgerBalance)} hint="Importer credit ledger net from existing ledger rows." tone="sky" />
            <SummaryMetric label="Indicative net position" value={gbp(indicativeNetPosition)} hint="IN + credit ledger - OUT. Use as a review signal, not a posting figure." tone="violet" />
            <SummaryMetric label="Supplier allocated" value={gbp(supplierInvoiceAllocated)} hint="Confirmed allocations to supplier invoices." tone="slate" />
            <SummaryMetric label="Refunds / fees / holds" value={gbp(retailerRefundAllocated + fxCardFeeAllocated + exceptionOrHoldAllocated)} hint="Retailer refund, FX/card/fee and exception/hold allocations." tone="amber" />
            <SummaryMetric label="Open exceptions" value={gbp(openExceptionTotalSummary)} hint="Open paper/commercial exception impact for this importer scope." tone="amber" />
            <SummaryMetric label="Unmatched lines" value={`${unmatchedInCount} IN · ${unmatchedOutCount} OUT`} hint="Needs funding route or supplier/refund/fee/exception allocation." tone={unmatchedInCount + unmatchedOutCount > 0 ? "rose" : "emerald"} />
          </div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div>
              <h2 className="text-xl font-semibold">Statement-line control queue</h2>
              <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-600">
                Showing {filteredRows.length} line(s). Default view is Needs route/action so supervisors are not buried in completed lines.
              </p>
            </div>
            <div className="flex flex-wrap gap-2">
              <Link className="rounded-xl bg-sky-600 px-4 py-2 text-sm font-semibold text-white" href="/internal/dva-reconciliation/workspace">
                Open matching workspace →
              </Link>
              <Link className="rounded-xl bg-amber-500 px-4 py-2 text-sm font-semibold text-white" href="/internal/dva-reconciliation/unmatched">
                Open unmatched OUT triage →
              </Link>
            </div>
          </div>

          <div className="mt-5 overflow-x-auto rounded-2xl border border-slate-200">
            <table className="min-w-[1180px] divide-y divide-slate-200 text-left text-sm">
              <thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500">
                <tr>
                  <th className="px-4 py-3">Statement line</th>
                  <th className="px-4 py-3">Route</th>
                  <th className="px-4 py-3">Importer</th>
                  <th className="px-4 py-3">Order / retailer</th>
                  <th className="px-4 py-3">Operational truth</th>
                  <th className="px-4 py-3">Allocations</th>
                  <th className="px-4 py-3">Balance / action</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {filteredRows.length === 0 ? (
                  <tr>
                    <td className="px-4 py-6 text-slate-500" colSpan={7}>No statement lines match this filter.</td>
                  </tr>
                ) : filteredRows.map(({ line, statement, importer, suggestion, suggestedInvoice, order, retailer, invoice, progressedTotal, openExceptionTotal }) => {
                  const lineSuggestions = suggestionsByLineId.get(text(line.dva_statement_line_id)) ?? [];
                  const defaultSupplierAllocation = Math.min(
                    Math.max(0, num(line.confirmed_unallocated_gbp)),
                    Math.max(0, num(invoice?.ocr_invoice_total_gbp) || num(invoice?.reconciliation_gbp_total) || num(line.confirmed_unallocated_gbp))
                  ).toFixed(2);
                  const hasOrderLink = Boolean(order);

                  return (
                    <tr key={text(line.dva_statement_line_id)} className="align-top">
                      <td className="px-4 py-4">
                        <p className="font-semibold">{text(line.statement_date)} · {text(line.direction)}</p>
                        <p>{gbp(line.statement_gbp_amount)} · {num(line.amount_local_ccy).toLocaleString("en-GB")} {text(line.local_ccy)}</p>
                        <p className="mt-2 text-xs text-slate-500">Ref: {text(line.reference_raw) || "—"}</p>
                        <p className="text-xs text-slate-500">Auth: {text(line.auth_id_ref) || "—"}</p>
                        <p className="text-xs text-slate-500">Statement text: {text(line.retailer_name_ref) || "—"}</p>
                        <p className="text-xs text-slate-500">FX: {text(line.fx_rate_applied) || "—"} · markup: {num(line.card_markup_pct_applied)}%</p>
                      </td>
                      <td className="px-4 py-4">
                        <span className={`rounded-full px-3 py-1 text-xs font-semibold ring-1 ${statusClass(line)}`}>{statusLabel(line)}</span>
                        <p className="mt-2 text-xs text-slate-600">Use routed control path</p>
                        <p className="text-xs text-slate-600">Match: {text(line.match_status) || "—"}</p>
                        <p className="text-xs text-slate-600">Suggested: {text(suggestion?.suggested_match_type) || "none"}{text(suggestion?.confidence) ? ` · ${text(suggestion?.confidence)}` : ""}</p>
                        <p className="text-xs text-slate-600">Variance: {gbp(suggestion?.variance_gbp)} · {num(suggestion?.variance_days)} days</p>
                      </td>
                      <td className="px-4 py-4">
                        <p className="font-semibold">{text(importer?.trading_name) || text(importer?.company_name) || "—"}</p>
                        <p className="text-xs text-slate-500">DVA: {text(importer?.gcb_dva_ref) || "—"}</p>
                        <p className="text-xs text-slate-500">Card: {text(importer?.dva_card_last_4) || "—"}</p>
                        <p className="text-xs text-slate-500">Bank: {text(statement?.source_bank) || "—"}</p>
                      </td>
                      <td className="px-4 py-4">
                        <p className="font-semibold">{hasOrderLink ? text(order?.order_ref) : "No order link"}</p>
                        <p>{hasOrderLink ? (text(retailer?.name) || "No retailer on linked order") : "Statement text only"}</p>
                        {hasOrderLink ? (
                          <>
                            <p className="text-xs text-slate-500">Order value: {gbp(order?.order_total_gbp_declared)}</p>
                            <p className="text-xs text-slate-500">Status: {text(order?.status) || "—"}</p>
                            <p className="text-xs text-slate-500">Type: {text(order?.order_type) || "—"}</p>
                            <Link className="mt-2 inline-block text-xs font-semibold text-sky-700" href={`/internal/evidence/${text(order?.id)}`}>Open order →</Link>
                          </>
                        ) : (
                          <p className="mt-2 break-words text-xs text-slate-500 [overflow-wrap:anywhere]">{text(line.retailer_name_ref) || text(line.reference_raw) || "No statement merchant/reference text"}</p>
                        )}
                      </td>
                      <td className="px-4 py-4">
                        <p className="font-semibold">{text(invoice?.invoice_ref) || text(invoice?.ocr_invoice_ref) || "No invoice link"}</p>
                        <p className="text-xs text-slate-500">Invoice/OCR: {gbp(invoice?.ocr_invoice_total_gbp || invoice?.reconciliation_gbp_total)}</p>
                        <p className="text-xs text-slate-500">Progressed: {gbp(progressedTotal)}</p>
                        <p className="text-xs text-slate-500">Open exception: {gbp(openExceptionTotal)}</p>
                      </td>
                      <td className="px-4 py-4">
                        <p className="font-semibold">{gbp(line.confirmed_allocated_gbp)} confirmed</p>
                        <p className="text-xs text-slate-600">Supplier invoices: {gbp(line.supplier_invoice_allocated_gbp)}</p>
                        <p className="text-xs text-slate-600">Retailer refunds: {gbp(line.retailer_refund_allocated_gbp)}</p>
                        <p className="text-xs text-slate-600">FX/card/fees: {gbp(line.fx_card_or_fee_allocated_gbp)}</p>
                        <p className="text-xs text-slate-600">Exception/hold: {gbp(line.exception_or_hold_allocated_gbp)}</p>
                        <p className="text-xs text-slate-600">Draft/held: {gbp(line.open_allocated_gbp)}</p>
                        {suggestedInvoice ? <SupplierInvoiceAllocationForm row={line} invoiceId={text(suggestedInvoice.id)} defaultAmount={defaultSupplierAllocation} /> : null}
                      </td>
                      <td className="px-4 py-4">
                        <p className="font-semibold">{gbp(line.confirmed_unallocated_gbp)}</p>
                        <p className="text-xs text-slate-600">Active allocations: {num(line.active_allocation_count)}</p>
                        <p className="text-xs text-slate-600">Balanced: {bool(line.confirmed_balanced_yn) ? "Yes" : "No"}</p>
                        <p className="mt-2 text-xs italic text-slate-600">{actionMessage(line)}</p>
                        {text(line.direction) === "in" && !bool(line.confirmed_balanced_yn) ? (
                          <Link className="mt-3 inline-block rounded-xl bg-emerald-600 px-3 py-2 text-xs font-semibold text-white" href="/internal/funding">Open Importer Funding Control</Link>
                        ) : null}
                        {text(line.direction) === "out" && lineSuggestions.length === 0 && !bool(line.confirmed_balanced_yn) ? (
                          <form action={generateSupplierInvoiceSuggestionsAction} className="mt-3 rounded-2xl border border-amber-200 bg-amber-50 p-3">
                            <input type="hidden" name="dva_statement_line_id" value={text(line.dva_statement_line_id)} />
                            <label className="block text-xs font-semibold text-amber-950">Generate suggestions</label>
                            <input className="mt-2 w-full rounded-xl border border-amber-200 bg-white px-3 py-2 text-xs" name="tolerance_gbp" type="number" min="0" step="0.01" defaultValue="20" />
                            <input className="mt-2 w-full rounded-xl border border-amber-200 bg-white px-3 py-2 text-xs" name="max_days" type="number" min="0" step="1" defaultValue="21" />
                            <button className="mt-2 rounded-xl bg-amber-500 px-3 py-2 text-xs font-semibold text-white" type="submit">Generate</button>
                          </form>
                        ) : null}
                        {canAllocateResidual(line) ? <ResidualAllocationForm row={line} /> : null}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </section>
      </div>
    </main>
  );
}
