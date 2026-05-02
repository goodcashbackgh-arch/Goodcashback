import Link from "next/link";
import { createClient } from "@/utils/supabase/server";
import { allocateStatementLineToSupplierInvoiceAction } from "../actions";

const TEST_LINE_ID = "fe9eb93d-573a-4a4e-b62e-812bf26afd23";

const gbpFormatter = new Intl.NumberFormat("en-GB", {
  style: "currency",
  currency: "GBP",
  minimumFractionDigits: 2,
});

function gbp(value: unknown) {
  const amount = typeof value === "number" ? value : Number(value ?? 0);
  return gbpFormatter.format(Number.isFinite(amount) ? amount : 0);
}

function text(value: unknown) {
  return typeof value === "string" ? value : "";
}

export default async function FocusedDvaSupplierSuggestionTestPage() {
  const supabase = await createClient();

  const { data: line, error: lineError } = await supabase
    .from("dva_statement_line_allocation_summary_vw")
    .select("*")
    .eq("dva_statement_line_id", TEST_LINE_ID)
    .single();

  const { data: suggestions, error: suggestionError } = await supabase
    .from("match_suggestions")
    .select("id, dva_statement_line_id, suggested_match_type, suggested_match_id, confidence, variance_gbp, variance_days")
    .eq("dva_statement_line_id", TEST_LINE_ID)
    .eq("suggested_match_type", "supplier_invoice")
    .limit(5);

  const suggestion = suggestions?.[0] ?? null;

  const { data: invoice, error: invoiceError } = suggestion?.suggested_match_id
    ? await supabase
        .from("supplier_invoices")
        .select("id, order_id, invoice_ref, ocr_invoice_ref, ocr_invoice_total_gbp, reconciliation_gbp_total, review_status")
        .eq("id", suggestion.suggested_match_id)
        .single()
    : { data: null, error: null };

  const { data: order, error: orderError } = invoice?.order_id
    ? await supabase
        .from("orders")
        .select("id, order_ref, importer_id, retailer_id, status, order_type")
        .eq("id", invoice.order_id)
        .single()
    : { data: null, error: null };

  const defaultAmount = Math.max(0, Number(line?.confirmed_unallocated_gbp ?? 0)).toFixed(2);
  const canAllocate = Boolean(line && suggestion && invoice && text(line.direction) === "out" && !line.confirmed_balanced_yn);

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto max-w-4xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href="/internal/dva-reconciliation" className="text-sm font-semibold text-sky-600">← Back to DVA workbench</Link>
          <h1 className="mt-4 text-3xl font-semibold tracking-tight">Focused supplier suggestion test</h1>
          <p className="mt-2 text-sm leading-6 text-slate-600">
            This proves the focused query model: one visible statement line → its supplier-invoice suggestion → allocation RPC button.
          </p>
        </section>

        {[lineError, suggestionError, invoiceError, orderError].filter(Boolean).length > 0 ? (
          <section className="rounded-3xl border border-rose-200 bg-rose-50 p-5 text-sm text-rose-900">
            <p className="font-semibold">Read error</p>
            <pre className="mt-2 whitespace-pre-wrap text-xs">{JSON.stringify({ lineError, suggestionError, invoiceError, orderError }, null, 2)}</pre>
          </section>
        ) : null}

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold">Statement line</h2>
          <dl className="mt-4 grid gap-3 text-sm sm:grid-cols-2">
            <div><dt className="font-semibold text-slate-500">Line ID</dt><dd>{TEST_LINE_ID}</dd></div>
            <div><dt className="font-semibold text-slate-500">Direction</dt><dd>{text(line?.direction) || "—"}</dd></div>
            <div><dt className="font-semibold text-slate-500">Reference</dt><dd>{text(line?.reference_raw) || "—"}</dd></div>
            <div><dt className="font-semibold text-slate-500">Retailer/card ref</dt><dd>{text(line?.retailer_name_ref) || "—"}</dd></div>
            <div><dt className="font-semibold text-slate-500">Statement amount</dt><dd>{gbp(line?.statement_gbp_amount)}</dd></div>
            <div><dt className="font-semibold text-slate-500">Unallocated</dt><dd>{gbp(line?.confirmed_unallocated_gbp)}</dd></div>
          </dl>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold">Supplier invoice suggestion</h2>
          {suggestion && invoice ? (
            <dl className="mt-4 grid gap-3 text-sm sm:grid-cols-2">
              <div><dt className="font-semibold text-slate-500">Suggestion</dt><dd>{text(suggestion.suggested_match_type)} · {text(suggestion.confidence)}</dd></div>
              <div><dt className="font-semibold text-slate-500">Variance</dt><dd>{gbp(suggestion.variance_gbp)} · {suggestion.variance_days ?? 0} days</dd></div>
              <div><dt className="font-semibold text-slate-500">Invoice ref</dt><dd>{text(invoice.ocr_invoice_ref) || text(invoice.invoice_ref) || "—"}</dd></div>
              <div><dt className="font-semibold text-slate-500">Invoice amount</dt><dd>{gbp(invoice.ocr_invoice_total_gbp ?? invoice.reconciliation_gbp_total)}</dd></div>
              <div><dt className="font-semibold text-slate-500">Order</dt><dd>{text(order?.order_ref) || "—"}</dd></div>
              <div><dt className="font-semibold text-slate-500">Status</dt><dd>{text(order?.status) || "—"}</dd></div>
            </dl>
          ) : (
            <p className="mt-4 text-sm text-slate-600">No supplier-invoice suggestion found for this test line.</p>
          )}
        </section>

        <section className="rounded-3xl border border-sky-200 bg-sky-50 p-6 shadow-sm">
          <h2 className="text-xl font-semibold text-sky-950">Allocation action</h2>
          {canAllocate ? (
            <form action={allocateStatementLineToSupplierInvoiceAction} className="mt-4 max-w-sm space-y-3">
              <input type="hidden" name="dva_statement_line_id" value={TEST_LINE_ID} />
              <input type="hidden" name="supplier_invoice_id" value={text(invoice?.id)} />
              <label className="block text-sm font-semibold text-sky-950">Amount to allocate</label>
              <input className="w-full rounded-xl border border-sky-200 bg-white px-3 py-2 text-sm" name="allocated_gbp_amount" type="number" min="0.01" step="0.01" defaultValue={defaultAmount} />
              <input className="w-full rounded-xl border border-sky-200 bg-white px-3 py-2 text-sm" name="notes" placeholder="Optional note" />
              <button className="rounded-xl bg-sky-600 px-4 py-2 text-sm font-semibold text-white" type="submit">Allocate to suggested invoice</button>
            </form>
          ) : (
            <p className="mt-4 text-sm text-slate-700">Button hidden because the line is not allocatable, already balanced, or no invoice suggestion exists.</p>
          )}
        </section>
      </div>
    </main>
  );
}
