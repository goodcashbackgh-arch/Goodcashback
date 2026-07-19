import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import {
  approveCurrentSupplierInvoiceFromReconciliationAction,
  supervisorProgressSupplierInvoiceLinesAction,
} from "../../../actions";

function progressed(value: unknown) {
  return ["y", "yes", "true", "1"].includes(String(value ?? "").toLowerCase());
}

function gbp(value: unknown) {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" }).format(Number(value ?? 0));
}

export default async function ExactSupplierInvoiceSupervisorPage({
  params,
}: {
  params: Promise<{ order_id: string; supplier_invoice_id: string }>;
}) {
  const { order_id: orderId, supplier_invoice_id: invoiceId } = await params;
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff } = await supabase
    .from("staff")
    .select("id, full_name, role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();
  if (!staff || !["admin", "supervisor"].includes(String(staff.role_type))) redirect("/internal");

  const [{ data: order }, { data: invoice }] = await Promise.all([
    supabase.from("orders").select("id, order_ref, total_qty_declared, order_total_gbp_declared").eq("id", orderId).maybeSingle(),
    supabase
      .from("supplier_invoices")
      .select("id, order_id, invoice_ref, ocr_invoice_ref, invoice_pdf_url, review_status, uploaded_at, ocr_invoice_total_gbp, blocked_from_sage_yn")
      .eq("id", invoiceId)
      .eq("order_id", orderId)
      .maybeSingle(),
  ]);
  if (!order || !invoice) redirect(`/internal/reconciliation/${orderId}/invoice-bundle`);

  const { data: lines } = await supabase
    .from("supplier_invoice_lines")
    .select("id, line_order, line_source, retailer_sku, description, qty, size, amount_inc_vat_gbp, eligible_for_invoice_yn")
    .eq("supplier_invoice_id", invoiceId)
    .order("line_order", { ascending: true });
  const lineIds = (lines ?? []).map((line) => line.id);

  const [{ data: resolutions }, { data: codingTotals }] = await Promise.all([
    lineIds.length
      ? supabase
          .from("supplier_invoice_line_resolutions")
          .select("supplier_invoice_line_id")
          .eq("supplier_invoice_id", invoiceId)
          .eq("resolution_type", "non_physical_financial")
          .eq("active", true)
          .in("supplier_invoice_line_id", lineIds)
      : Promise.resolve({ data: [] as Array<{ supplier_invoice_line_id: string }> }),
    supabase
      .from("supplier_invoice_accounting_coding_totals_vw")
      .select("all_progressed_lines_coded_yn, net_reconciled_to_invoice_yn, vat_reconciled_to_invoice_yn, gross_reconciled_to_invoice_yn")
      .eq("supplier_invoice_id", invoiceId)
      .maybeSingle(),
  ]);

  const nonPhysical = new Set((resolutions ?? []).map((row) => row.supplier_invoice_line_id));
  const physicalCandidates = (lines ?? []).filter((line) => !progressed(line.eligible_for_invoice_yn) && !nonPhysical.has(line.id));
  const approved = ["approved_current", "ref_corrected_approved"].includes(String(invoice.review_status ?? ""));
  const codingReady = Boolean(
    codingTotals?.all_progressed_lines_coded_yn &&
    codingTotals?.net_reconciled_to_invoice_yn &&
    codingTotals?.vat_reconciled_to_invoice_yn &&
    codingTotals?.gross_reconciled_to_invoice_yn,
  );

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-5xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href={`/internal/reconciliation/${orderId}/invoice-bundle`} className="text-sm font-semibold text-sky-700">← Back to order invoice bundle</Link>
          <p className="mt-6 text-sm font-semibold uppercase tracking-[0.2em] text-sky-600">Exact supplier invoice</p>
          <h1 className="mt-2 text-3xl font-semibold">{invoice.ocr_invoice_ref || invoice.invoice_ref}</h1>
          <p className="mt-2 text-sm text-slate-600">Order {order.order_ref ?? orderId} · status {invoice.review_status ?? "pending_review"}</p>
          <p className="mt-1 text-sm text-slate-500">{staff.full_name} · {staff.role_type}</p>
          <div className="mt-4 flex flex-wrap gap-2">
            <a href={invoice.invoice_pdf_url} target="_blank" rel="noreferrer" className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white">Open invoice</a>
            <Link href="/internal/invoice-review" className="rounded-xl border border-slate-300 px-4 py-2 text-sm font-semibold text-slate-800">Document review queue</Link>
            <Link href={`/internal/reconciliation/${orderId}`} className="rounded-xl border border-slate-300 px-4 py-2 text-sm font-semibold text-slate-800">Accounting workspace</Link>
          </div>
        </section>

        <section className="grid gap-4 md:grid-cols-4">
          <div className="rounded-2xl border bg-white p-4"><p className="text-xs uppercase text-slate-500">Invoice total</p><p className="mt-1 text-xl font-semibold">{gbp(invoice.ocr_invoice_total_gbp)}</p></div>
          <div className="rounded-2xl border bg-white p-4"><p className="text-xs uppercase text-slate-500">Invoice lines</p><p className="mt-1 text-xl font-semibold">{lines?.length ?? 0}</p></div>
          <div className="rounded-2xl border bg-white p-4"><p className="text-xs uppercase text-slate-500">Unprogressed physical</p><p className="mt-1 text-xl font-semibold">{physicalCandidates.length}</p></div>
          <div className={`rounded-2xl border p-4 ${codingReady ? "border-emerald-200 bg-emerald-50" : "border-amber-200 bg-amber-50"}`}><p className="text-xs uppercase text-slate-500">Accounting coding</p><p className="mt-1 text-xl font-semibold">{codingReady ? "Ready" : "Open"}</p></div>
        </section>

        {!approved && physicalCandidates.length > 0 ? (
          <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 shadow-sm">
            <h2 className="text-xl font-semibold text-amber-950">Progress clean physical lines on this invoice</h2>
            <p className="mt-2 text-sm text-amber-900">Only the selected supplier invoice is affected. Other invoice references remain unchanged.</p>
            <form action={supervisorProgressSupplierInvoiceLinesAction} className="mt-5 space-y-3">
              <input type="hidden" name="order_id" value={orderId} />
              <input type="hidden" name="supplier_invoice_id" value={invoiceId} />
              {physicalCandidates.map((line) => (
                <label key={line.id} className="flex gap-3 rounded-2xl border border-amber-200 bg-white p-4 text-sm">
                  <input type="checkbox" name="line_ids" value={line.id} className="mt-1" />
                  <span>
                    <span className="block font-semibold">Line {line.line_order ?? "—"} · {line.description || "No description"}</span>
                    <span className="mt-1 block text-slate-600">Qty {Number(line.qty ?? 0)} · {gbp(line.amount_inc_vat_gbp)}{line.retailer_sku ? ` · SKU ${line.retailer_sku}` : ""}</span>
                  </span>
                </label>
              ))}
              <textarea name="progress_notes" rows={3} className="w-full rounded-xl border border-amber-300 px-3 py-2 text-sm" placeholder="Supervisor progression note" />
              <button className="rounded-xl bg-amber-800 px-4 py-2 text-sm font-semibold text-white">Progress selected lines</button>
            </form>
          </section>
        ) : null}

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
          <h2 className="text-xl font-semibold">Approval checkpoint</h2>
          {approved ? <p className="mt-3 rounded-xl border border-emerald-200 bg-emerald-50 p-3 text-sm text-emerald-800">This invoice is approved. Sibling supplier invoices remain independently active.</p> : null}
          {!approved && !codingReady ? <p className="mt-3 rounded-xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">Complete and reconcile accounting coding for this invoice before approval.</p> : null}
          {!approved && codingReady ? (
            <form action={approveCurrentSupplierInvoiceFromReconciliationAction} className="mt-4">
              <input type="hidden" name="order_id" value={orderId} />
              <input type="hidden" name="supplier_invoice_id" value={invoiceId} />
              <button className="rounded-xl bg-emerald-700 px-4 py-2 text-sm font-semibold text-white">Approve this supplier invoice</button>
            </form>
          ) : null}
        </section>
      </div>
    </main>
  );
}
