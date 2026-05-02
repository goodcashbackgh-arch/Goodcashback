import Link from "next/link";
import { createClient } from "@/utils/supabase/server";
import { allocateStatementLineToSupplierInvoiceAction } from "./actions";

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

function actionMessage(row: Row) {
  if (bool(row.confirmed_balanced_yn)) return "Balanced — no further action.";
  if (text(row.direction) === "out") return "No supplier invoice suggestion yet.";
  return "No action here.";
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

export default async function DvaReconciliationWorkbenchPage({
  searchParams,
}: {
  searchParams?: SearchParamsValue | Promise<SearchParamsValue>;
}) {
  const params = searchParams ? await Promise.resolve(searchParams) : {};
  const allocationSuccess = firstParam(params.allocation_success);
  const allocationError = firstParam(params.allocation_error);
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

  const rows = allocationRows.map((line) => {
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
    const invoiceTotal = num(invoice?.ocr_invoice_total_gbp) || num(invoice?.reconciliation_gbp_total);

    return {
      line,
      statement,
      importer,
      suggestion,
      order,
      retailer,
      invoice,
      progressedTotal,
      openExceptionTotal,
      invoiceTotal,
    };
  });

  const fundingRouteCount = allocationRows.filter((row) => text(row.direction) === "in").length;
  const outgoingNeedsAllocationCount = allocationRows.filter(
    (row) => text(row.direction) === "out" && !bool(row.confirmed_balanced_yn)
  ).length;
  const balancedCount = allocationRows.filter((row) => bool(row.confirmed_balanced_yn)).length;
  const confirmedAllocatedTotal = allocationRows.reduce((sum, row) => sum + num(row.confirmed_allocated_gbp), 0);
  const confirmedUnallocatedTotal = allocationRows.reduce((sum, row) => sum + Math.abs(num(row.confirmed_unallocated_gbp)), 0);
  const openExceptionTotalAll = openDisputes.reduce((sum, row) => sum + num(row.amount_impact_gbp), 0);
  const lockedCreditTotal = creditLedger
    .filter((row) => maybeText(row.lock_reason))
    .reduce((sum, row) => sum + num(row.amount_gbp), 0);

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto flex max-w-7xl flex-col gap-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href="/internal" className="text-sm font-semibold text-sky-600">← Back to internal dashboard</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">DVA/card statement reconciliation</p>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight">Supplier charge, refund and exception control workbench</h1>
          <p className="mt-3 max-w-4xl text-sm leading-6 text-slate-600">
            Allocation view for DVA/card statement lines. Inbound lines route back to funding; outbound lines route toward supplier invoice, refund, exception, FX/card difference, or hold allocation. Supplier invoice allocation uses a staff-only RPC.
          </p>
          <div className="mt-4 flex flex-wrap gap-2">
            <span className="rounded-full bg-emerald-50 px-3 py-1 text-sm font-semibold text-emerald-700 ring-1 ring-emerald-200">Controlled RPC writes</span>
            <span className="rounded-full bg-slate-100 px-3 py-1 text-sm font-semibold text-slate-700 ring-1 ring-slate-200">No direct table writes</span>
            <span className="rounded-full bg-sky-50 px-3 py-1 text-sm font-semibold text-sky-700 ring-1 ring-sky-200">Supplier invoice suggestions</span>
          </div>
        </section>

        {allocationSuccess ? (
          <section className="rounded-3xl border border-emerald-200 bg-emerald-50 p-5 text-sm font-semibold text-emerald-800">{allocationSuccess}</section>
        ) : null}
        {allocationError ? (
          <section className="rounded-3xl border border-rose-200 bg-rose-50 p-5 text-sm font-semibold text-rose-900">{allocationError}</section>
        ) : null}

        <section className="grid gap-4 md:grid-cols-5">
          <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><p className="text-xs font-semibold uppercase tracking-wide text-slate-500">Statement lines</p><p className="mt-2 text-3xl font-semibold">{allocationRows.length}</p></div>
          <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><p className="text-xs font-semibold uppercase tracking-wide text-slate-500">Funding route</p><p className="mt-2 text-3xl font-semibold">{fundingRouteCount}</p></div>
          <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><p className="text-xs font-semibold uppercase tracking-wide text-slate-500">Outgoing needs allocation</p><p className="mt-2 text-3xl font-semibold">{outgoingNeedsAllocationCount}</p></div>
          <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><p className="text-xs font-semibold uppercase tracking-wide text-slate-500">Balanced</p><p className="mt-2 text-3xl font-semibold">{balancedCount}</p></div>
          <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><p className="text-xs font-semibold uppercase tracking-wide text-slate-500">Abs unallocated</p><p className="mt-2 text-3xl font-semibold">{gbp(confirmedUnallocatedTotal)}</p></div>
        </section>

        <section className="grid gap-4 md:grid-cols-3">
          <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><p className="text-xs font-semibold uppercase tracking-wide text-slate-500">Confirmed allocated</p><p className="mt-2 text-2xl font-semibold">{gbp(confirmedAllocatedTotal)}</p></div>
          <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><p className="text-xs font-semibold uppercase tracking-wide text-slate-500">Open exception value</p><p className="mt-2 text-2xl font-semibold">{gbp(openExceptionTotalAll)}</p></div>
          <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><p className="text-xs font-semibold uppercase tracking-wide text-slate-500">Locked credit</p><p className="mt-2 text-2xl font-semibold">{gbp(lockedCreditTotal)}</p></div>
        </section>

        <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm leading-6 text-amber-950">
          <h2 className="font-semibold">Control boundary</h2>
          <p className="mt-2">Inbound lines remain Day 2 order-funding items and should be handled through the funding queue. Outbound/refund lines use the allocation layer for supplier invoices, refunds, exception holds, FX/card differences, bank fees, or unmatched holds. This page exposes supplier-invoice allocation only when a supplier-invoice match suggestion exists.</p>
        </section>

        {readErrors.length > 0 ? (
          <section className="rounded-3xl border border-rose-200 bg-rose-50 p-5 text-sm leading-6 text-rose-900">
            <h2 className="font-semibold">Some sources could not be read</h2>
            <ul className="mt-2 list-disc pl-5">{readErrors.map((error) => <li key={error.source}><span className="font-semibold">{error.source}:</span> {error.message}</li>)}</ul>
          </section>
        ) : null}

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold">Statement-line allocation control view</h2>
          <p className="mt-1 max-w-4xl text-sm leading-6 text-slate-600">This page consumes existing order, invoice, OCR, progressed-line and exception work. Supplier-invoice suggestions are treated as the primary candidate for OUT lines.</p>
          {rows.length === 0 ? (
            <div className="mt-5 rounded-2xl border border-slate-200 bg-slate-50 p-5 text-sm text-slate-600">No DVA/card statement allocation summary rows are visible to this staff session.</div>
          ) : (
            <div className="mt-5 overflow-x-auto rounded-2xl border border-slate-200">
              <table className="min-w-full divide-y divide-slate-200 text-left text-sm">
                <thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500">
                  <tr>
                    <th className="px-4 py-3 font-semibold">Statement line</th>
                    <th className="px-4 py-3 font-semibold">Route</th>
                    <th className="px-4 py-3 font-semibold">Importer</th>
                    <th className="px-4 py-3 font-semibold">Order / retailer</th>
                    <th className="px-4 py-3 font-semibold">Operational truth</th>
                    <th className="px-4 py-3 font-semibold">Allocations</th>
                    <th className="px-4 py-3 font-semibold">Balance / action</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-100 bg-white">
                  {rows.map((row) => {
                    const canAllocateToInvoice =
                      text(row.line.direction) === "out" &&
                      text(row.suggestion?.suggested_match_type) === "supplier_invoice" &&
                      !!text(row.invoice?.id) &&
                      !bool(row.line.confirmed_balanced_yn);
                    const defaultAllocationAmount = Math.max(0, num(row.line.confirmed_unallocated_gbp)).toFixed(2);

                    return (
                      <tr key={text(row.line.dva_statement_line_id)}>
                        <td className="min-w-64 px-4 py-4 align-top"><div className="font-medium text-slate-950">{text(row.line.statement_date) || "—"} · {text(row.line.direction) || "—"}</div><div className="mt-1 text-slate-700">{gbp(row.line.statement_gbp_amount)} · {num(row.line.amount_local_ccy).toLocaleString("en-GB")} {text(row.line.local_ccy)}</div><div className="mt-2 max-w-xs text-xs leading-5 text-slate-500">Ref: {text(row.line.reference_raw) || "—"}<br />Auth: {text(row.line.auth_id_ref) || "—"}<br />Card ref: {text(row.line.retailer_name_ref) || "—"}<br />FX: {text(row.line.fx_rate_applied) || "—"} · markup: {text(row.line.card_markup_pct_applied) || "0"}%</div></td>
                        <td className="min-w-44 px-4 py-4 align-top"><span className={`inline-flex rounded-full px-2.5 py-1 text-xs font-semibold ring-1 ${statusClass(row.line)}`}>{statusLabel(row.line)}</span><div className="mt-2 text-xs leading-5 text-slate-500">{text(row.line.direction) === "in" ? "Use funding queue" : "Use allocation workflow"}<br />Match: {text(row.line.match_status) || "—"}<br />Suggested: {text(row.suggestion?.suggested_match_type) || "none"} {text(row.suggestion?.confidence) ? `· ${text(row.suggestion?.confidence)}` : ""}<br />Variance: {gbp(row.suggestion?.variance_gbp)} · {num(row.suggestion?.variance_days)} days</div>{text(row.line.direction) === "in" ? <Link href="/internal/funding" className="mt-2 inline-flex text-xs font-semibold text-sky-600">Open funding →</Link> : null}</td>
                        <td className="min-w-52 px-4 py-4 align-top"><div className="font-medium text-slate-950">{text(row.importer?.trading_name) || text(row.importer?.company_name) || "—"}</div><div className="mt-1 text-xs leading-5 text-slate-500">DVA: {text(row.importer?.gcb_dva_ref) || "—"}<br />Card: {text(row.importer?.dva_card_last_4) || "—"}<br />Bank: {text(row.statement?.source_bank) || "—"}</div></td>
                        <td className="min-w-56 px-4 py-4 align-top"><div className="font-medium text-slate-950">{text(row.order?.order_ref) || "—"}</div><div className="mt-1 text-slate-700">{text(row.retailer?.name) || text(row.line.retailer_name_ref) || "—"}</div><div className="mt-1 text-xs leading-5 text-slate-500">Order value: {gbp(row.order?.order_total_gbp_declared)}<br />Status: {text(row.order?.status) || "—"}<br />Type: {text(row.order?.order_type) || "—"}</div>{text(row.order?.id) ? <Link href={`/internal/evidence/${text(row.order?.id)}`} className="mt-2 inline-flex text-xs font-semibold text-sky-600">Open order →</Link> : null}</td>
                        <td className="min-w-56 px-4 py-4 align-top"><div className="font-medium text-slate-950">{text(row.invoice?.ocr_invoice_ref) || text(row.invoice?.invoice_ref) || "No invoice link"}</div><div className="mt-1 text-xs leading-5 text-slate-500">Invoice/OCR: {gbp(row.invoiceTotal)}<br />Progressed: {gbp(row.progressedTotal)}<br />Open exception: {gbp(row.openExceptionTotal)}</div></td>
                        <td className="min-w-56 px-4 py-4 align-top"><div className="font-semibold text-slate-950">{gbp(row.line.confirmed_allocated_gbp)} confirmed</div><div className="mt-1 text-xs leading-5 text-slate-500">Supplier invoices: {gbp(row.line.supplier_invoice_allocated_gbp)}<br />Retailer refunds: {gbp(row.line.retailer_refund_allocated_gbp)}<br />FX/card/fees: {gbp(row.line.fx_card_or_fee_allocated_gbp)}<br />Exception/hold: {gbp(row.line.exception_or_hold_allocated_gbp)}<br />Draft/held: {gbp(row.line.open_allocated_gbp)}</div></td>
                        <td className="min-w-56 px-4 py-4 align-top"><div className="font-semibold text-slate-950">{gbp(row.line.confirmed_unallocated_gbp)}</div><div className="mt-1 text-xs leading-5 text-slate-500">Active allocations: {num(row.line.active_allocation_count)}<br />Balanced: {bool(row.line.confirmed_balanced_yn) ? "Yes" : "No"}</div>{canAllocateToInvoice ? <form action={allocateStatementLineToSupplierInvoiceAction} className="mt-3 rounded-2xl border border-sky-200 bg-sky-50 p-3"><input type="hidden" name="dva_statement_line_id" value={text(row.line.dva_statement_line_id)} /><input type="hidden" name="supplier_invoice_id" value={text(row.invoice?.id)} /><label className="block text-xs font-semibold text-sky-900">Allocate to suggested invoice</label><input className="mt-2 w-full rounded-xl border border-sky-200 bg-white px-3 py-2 text-sm" name="allocated_gbp_amount" type="number" min="0.01" step="0.01" defaultValue={defaultAllocationAmount} /><input className="mt-2 w-full rounded-xl border border-sky-200 bg-white px-3 py-2 text-xs" name="notes" placeholder="Optional note" /><button className="mt-2 rounded-xl bg-sky-600 px-3 py-2 text-xs font-semibold text-white" type="submit">Allocate</button></form> : <div className="mt-2 text-xs leading-5 text-slate-500">{actionMessage(row.line)}</div>}</td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          )}
        </section>
      </div>
    </main>
  );
}
