import Link from "next/link";
import { createClient } from "@/utils/supabase/server";

type Row = Record<string, unknown>;
type ReadError = { source: string; message: string };

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

function num(value: unknown) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
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
  return new Map(rows.map((row) => [text(row.id), row]).filter(([id]) => id));
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

export default async function DvaReconciliationWorkbenchPage() {
  const supabase = await createClient();

  const [
    statementLinesResult,
    statementsResult,
    reconciliationsResult,
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
      .from("dva_statement_lines")
      .select("id, dva_statement_id, statement_date, reference_raw, direction, amount_local_ccy, local_ccy, amount_gbp_equivalent, auth_id_ref, retailer_name_ref, match_status")
      .order("statement_date", { ascending: false })
      .limit(100),
    supabase
      .from("dva_statements")
      .select("id, importer_id, source_bank, parse_status")
      .limit(100),
    supabase
      .from("dva_reconciliation")
      .select("id, dva_statement_line_id, reconciliation_type, order_id, supplier_invoice_id, dispute_id, reconciled_gbp_amount")
      .limit(200),
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
  addReadError(readErrors, "dva_statement_lines", statementLinesResult.error);
  addReadError(readErrors, "dva_statements", statementsResult.error);
  addReadError(readErrors, "dva_reconciliation", reconciliationsResult.error);
  addReadError(readErrors, "match_suggestions", suggestionsResult.error);
  addReadError(readErrors, "importers", importersResult.error);
  addReadError(readErrors, "orders", ordersResult.error);
  addReadError(readErrors, "retailers", retailersResult.error);
  addReadError(readErrors, "supplier_invoices", invoicesResult.error);
  addReadError(readErrors, "supplier_invoice_lines", invoiceLinesResult.error);
  addReadError(readErrors, "disputes", disputesResult.error);
  addReadError(readErrors, "importer_credit_ledger", creditLedgerResult.error);

  const statementLines = (statementLinesResult.data ?? []) as unknown as Row[];
  const statements = (statementsResult.data ?? []) as unknown as Row[];
  const reconciliations = (reconciliationsResult.data ?? []) as unknown as Row[];
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
  const invoicesByOrderId = groupBy(invoices, "order_id");
  const invoiceLinesByInvoiceId = groupBy(invoiceLines, "supplier_invoice_id");
  const suggestionsByLineId = groupBy(suggestions, "dva_statement_line_id");
  const reconciledLineIds = new Set(reconciliations.map((row) => text(row.dva_statement_line_id)).filter(Boolean));
  const openDisputes = disputes.filter((row) => !maybeText(row.resolved_at));

  const rows = statementLines.map((line) => {
    const statement = statementsById.get(text(line.dva_statement_id));
    const importer = statement ? importersById.get(text(statement.importer_id)) : undefined;
    const suggestion = suggestionsByLineId.get(text(line.id))?.[0];
    const order = text(suggestion?.suggested_match_type) === "order"
      ? ordersById.get(text(suggestion?.suggested_match_id))
      : undefined;
    const retailer = order ? retailersById.get(text(order.retailer_id)) : undefined;
    const orderInvoices = order ? invoicesByOrderId.get(text(order.id)) ?? [] : [];
    const invoice = orderInvoices[0];
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
    const comparisonBase = invoiceTotal || progressedTotal || openExceptionTotal;

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
      variance: comparisonBase ? num(line.amount_gbp_equivalent) - comparisonBase : 0,
      reconciled: reconciledLineIds.has(text(line.id)),
    };
  });

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
            Read-only v2 visibility for DVA/card statement lines, importer context, order references, supplier invoice totals, progressed lines, open exceptions and credit context. No write actions are exposed here.
          </p>
          <div className="mt-4 flex flex-wrap gap-2">
            <span className="rounded-full bg-emerald-50 px-3 py-1 text-sm font-semibold text-emerald-700 ring-1 ring-emerald-200">Read-only</span>
            <span className="rounded-full bg-slate-100 px-3 py-1 text-sm font-semibold text-slate-700 ring-1 ring-slate-200">No buttons</span>
          </div>
        </section>

        <section className="grid gap-4 md:grid-cols-5">
          <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><p className="text-xs font-semibold uppercase tracking-wide text-slate-500">Statement lines</p><p className="mt-2 text-3xl font-semibold">{statementLines.length}</p></div>
          <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><p className="text-xs font-semibold uppercase tracking-wide text-slate-500">Unmatched</p><p className="mt-2 text-3xl font-semibold">{statementLines.filter((line) => !reconciledLineIds.has(text(line.id))).length}</p></div>
          <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><p className="text-xs font-semibold uppercase tracking-wide text-slate-500">Suggested</p><p className="mt-2 text-3xl font-semibold">{statementLines.filter((line) => text(line.match_status) === "suggested").length}</p></div>
          <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><p className="text-xs font-semibold uppercase tracking-wide text-slate-500">Open exception value</p><p className="mt-2 text-3xl font-semibold">{gbp(openExceptionTotalAll)}</p></div>
          <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><p className="text-xs font-semibold uppercase tracking-wide text-slate-500">Locked credit</p><p className="mt-2 text-3xl font-semibold">{gbp(lockedCreditTotal)}</p></div>
        </section>

        <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm leading-6 text-amber-950">
          <h2 className="font-semibold">Control boundary confirmed from live schema</h2>
          <p className="mt-2">DVA statement lines are limited to one reconciliation row by the live unique constraint. Live reconciliation types are order funding, retailer purchase, refund credit and exception hold. Non-funding write actions remain disabled until dedicated staff/supervisor RPCs are designed and tested.</p>
        </section>

        {readErrors.length > 0 ? (
          <section className="rounded-3xl border border-rose-200 bg-rose-50 p-5 text-sm leading-6 text-rose-900">
            <h2 className="font-semibold">Some sources could not be read</h2>
            <ul className="mt-2 list-disc pl-5">{readErrors.map((error) => <li key={error.source}><span className="font-semibold">{error.source}:</span> {error.message}</li>)}</ul>
          </section>
        ) : null}

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold">Statement-line control view</h2>
          <p className="mt-1 max-w-4xl text-sm leading-6 text-slate-600">Visibility first. Use this to test whether statement lines, charges, refunds, invoices and open exceptions are telling the same story before adding supervisor actions.</p>
          {rows.length === 0 ? (
            <div className="mt-5 rounded-2xl border border-slate-200 bg-slate-50 p-5 text-sm text-slate-600">No DVA/card statement lines are visible to this staff session.</div>
          ) : (
            <div className="mt-5 overflow-x-auto rounded-2xl border border-slate-200">
              <table className="min-w-full divide-y divide-slate-200 text-left text-sm">
                <thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500"><tr><th className="px-4 py-3 font-semibold">Statement line</th><th className="px-4 py-3 font-semibold">Importer</th><th className="px-4 py-3 font-semibold">Order / retailer</th><th className="px-4 py-3 font-semibold">Invoice / progressed / exception</th><th className="px-4 py-3 font-semibold">Match state</th><th className="px-4 py-3 font-semibold">Variance cue</th></tr></thead>
                <tbody className="divide-y divide-slate-100 bg-white">
                  {rows.map((row) => (
                    <tr key={text(row.line.id)}>
                      <td className="min-w-64 px-4 py-4 align-top"><div className="font-medium text-slate-950">{text(row.line.statement_date) || "—"} · {text(row.line.direction) || "—"}</div><div className="mt-1 text-slate-700">{gbp(row.line.amount_gbp_equivalent)} · {num(row.line.amount_local_ccy).toLocaleString("en-GB")} {text(row.line.local_ccy)}</div><div className="mt-2 max-w-xs text-xs leading-5 text-slate-500">Ref: {text(row.line.reference_raw) || "—"}<br />Auth: {text(row.line.auth_id_ref) || "—"}<br />Card ref: {text(row.line.retailer_name_ref) || "—"}</div></td>
                      <td className="min-w-52 px-4 py-4 align-top"><div className="font-medium text-slate-950">{text(row.importer?.trading_name) || text(row.importer?.company_name) || "—"}</div><div className="mt-1 text-xs leading-5 text-slate-500">DVA: {text(row.importer?.gcb_dva_ref) || "—"}<br />Card: {text(row.importer?.dva_card_last_4) || "—"}<br />Bank: {text(row.statement?.source_bank) || "—"}</div></td>
                      <td className="min-w-56 px-4 py-4 align-top"><div className="font-medium text-slate-950">{text(row.order?.order_ref) || "—"}</div><div className="mt-1 text-slate-700">{text(row.retailer?.name) || "—"}</div><div className="mt-1 text-xs leading-5 text-slate-500">Order value: {gbp(row.order?.order_total_gbp_declared)}<br />Status: {text(row.order?.status) || "—"}<br />Type: {text(row.order?.order_type) || "—"}</div></td>
                      <td className="min-w-56 px-4 py-4 align-top"><div className="font-medium text-slate-950">{text(row.invoice?.ocr_invoice_ref) || text(row.invoice?.invoice_ref) || "—"}</div><div className="mt-1 text-xs leading-5 text-slate-500">Invoice/OCR: {gbp(row.invoiceTotal)}<br />Progressed: {gbp(row.progressedTotal)}<br />Open exception: {gbp(row.openExceptionTotal)}</div></td>
                      <td className="min-w-44 px-4 py-4 align-top"><span className="inline-flex rounded-full bg-sky-50 px-2.5 py-1 text-xs font-semibold text-sky-700 ring-1 ring-sky-200">{row.reconciled ? "reconciled" : text(row.line.match_status) || "unmatched"}</span><div className="mt-2 text-xs leading-5 text-slate-500">Suggested: {text(row.suggestion?.suggested_match_type) || "—"}<br />Confidence: {text(row.suggestion?.confidence) || "—"}</div></td>
                      <td className="min-w-44 px-4 py-4 align-top"><div className="font-semibold text-slate-950">{row.variance > 0 ? "+" : row.variance < 0 ? "-" : ""}{gbp(Math.abs(row.variance))}</div><div className="mt-1 text-xs leading-5 text-slate-500">Visibility cue only, not accounting decision.</div></td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </section>
      </div>
    </main>
  );
}
