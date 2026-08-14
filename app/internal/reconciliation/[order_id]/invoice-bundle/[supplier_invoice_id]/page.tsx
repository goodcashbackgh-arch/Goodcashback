import Link from "next/link";
import { redirect } from "next/navigation";
import BulkLineSelectionControls from "../../../../../importer/reconciliation/[order_id]/BulkLineSelectionControls";
import { createClient } from "@/utils/supabase/server";
import { supplierInvoiceReconciliationHref } from "../../../reconciliationHref";
import {
  approveCurrentSupplierInvoiceFromReconciliationAction,
  supervisorProgressSupplierInvoiceLinesAction,
} from "../../../actions";
import { supervisorResolveSupplierInvoiceLineNonPhysicalAction } from "../../actions";

type Search = { success?: string; error?: string };

type Resolution = {
  supplier_invoice_line_id: string;
  resolution_type: string;
  financial_type: string;
  notes: string | null;
};

function progressed(value: unknown) {
  return ["y", "yes", "true", "1"].includes(String(value ?? "").toLowerCase());
}

function normalisedDescription(value: string | null | undefined) {
  return (value ?? "").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
}

function isDiscountDescription(value: string | null | undefined) {
  return /(^| )(discount|promotion|promotional|promo|voucher|coupon|saving|savings)( |$)/.test(normalisedDescription(value));
}

function isDeliveryDescription(value: string | null | undefined) {
  return /(^| )(delivery|shipping|postage|freight|carriage)( |$)/.test(normalisedDescription(value));
}

function isFeeDescription(value: string | null | undefined) {
  return /(^| )(fee|charge|surcharge)( |$)/.test(normalisedDescription(value));
}

function suggestedFinancialType(line: { description?: string | null }) {
  if (isDiscountDescription(line.description)) return "discount";
  if (isDeliveryDescription(line.description)) return "delivery";
  if (isFeeDescription(line.description)) return "fee";
  return "other_non_physical";
}

function obviousNonPhysical(line: { description?: string | null; amount_inc_vat_gbp?: number | null }) {
  return Number(line.amount_inc_vat_gbp ?? 0) < 0
    || isDiscountDescription(line.description)
    || isDeliveryDescription(line.description)
    || isFeeDescription(line.description);
}

function gbp(value: unknown) {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" }).format(Number(value ?? 0));
}

export default async function ExactSupplierInvoiceSupervisorPage({
  params,
  searchParams,
}: {
  params: Promise<{ order_id: string; supplier_invoice_id: string }>;
  searchParams?: Promise<Search>;
}) {
  const { order_id: orderId, supplier_invoice_id: invoiceId } = await params;
  const qp = searchParams ? await searchParams : {};
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
  const invoiceLines = lines ?? [];
  const lineIds = invoiceLines.map((line) => line.id);

  const [{ data: resolutionRows }, { data: disputeRows }, { data: codingTotals }] = await Promise.all([
    lineIds.length
      ? supabase
          .from("supplier_invoice_line_resolutions")
          .select("supplier_invoice_line_id, resolution_type, financial_type, notes")
          .eq("supplier_invoice_id", invoiceId)
          .eq("resolution_type", "non_physical_financial")
          .eq("active", true)
          .in("supplier_invoice_line_id", lineIds)
      : Promise.resolve({ data: [] as Resolution[] }),
    lineIds.length
      ? supabase
          .from("dispute_lines")
          .select("supplier_invoice_line_id, disputes!inner(id, desired_outcome, resolved_at)")
          .in("supplier_invoice_line_id", lineIds)
          .is("resolved_at", null)
      : Promise.resolve({ data: [] as Array<{ supplier_invoice_line_id: string; disputes: unknown }> }),
    supabase
      .from("supplier_invoice_accounting_coding_totals_vw")
      .select("all_progressed_lines_coded_yn, net_reconciled_to_invoice_yn, vat_reconciled_to_invoice_yn, gross_reconciled_to_invoice_yn")
      .eq("supplier_invoice_id", invoiceId)
      .maybeSingle(),
  ]);

  const resolutions = new Map(((resolutionRows ?? []) as Resolution[]).map((resolution) => [resolution.supplier_invoice_line_id, resolution]));
  const disputes = new Map<string, string>();
  for (const row of disputeRows ?? []) {
    const joined = row.disputes as { desired_outcome?: string | null; resolved_at?: string | null } | Array<{ desired_outcome?: string | null; resolved_at?: string | null }> | null;
    const dispute = Array.isArray(joined) ? joined[0] : joined;
    if (dispute && !dispute.resolved_at) disputes.set(row.supplier_invoice_line_id, dispute.desired_outcome ?? "Exception");
  }

  const physicalCandidates = invoiceLines.filter(
    (line) => !progressed(line.eligible_for_invoice_yn)
      && !resolutions.has(line.id)
      && !disputes.has(line.id)
      && !obviousNonPhysical(line),
  );
  const physicalCandidateIds = new Set(physicalCandidates.map((line) => line.id));
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
            <Link href={supplierInvoiceReconciliationHref(orderId, invoiceId)} className="rounded-xl border border-slate-300 px-4 py-2 text-sm font-semibold text-slate-800">Accounting workspace</Link>
          </div>
          {qp.success ? <p className="mt-4 rounded-xl border border-emerald-300 bg-emerald-50 px-3 py-2 text-sm text-emerald-900">{qp.success}</p> : null}
          {qp.error ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">{qp.error}</p> : null}
        </section>

        <section className="grid gap-4 md:grid-cols-4">
          <div className="rounded-2xl border bg-white p-4"><p className="text-xs uppercase text-slate-500">Invoice total</p><p className="mt-1 text-xl font-semibold">{gbp(invoice.ocr_invoice_total_gbp)}</p></div>
          <div className="rounded-2xl border bg-white p-4"><p className="text-xs uppercase text-slate-500">Invoice lines</p><p className="mt-1 text-xl font-semibold">{invoiceLines.length}</p></div>
          <div className="rounded-2xl border bg-white p-4"><p className="text-xs uppercase text-slate-500">Unprogressed physical</p><p className="mt-1 text-xl font-semibold">{physicalCandidates.length}</p></div>
          <div className={`rounded-2xl border p-4 ${codingReady ? "border-emerald-200 bg-emerald-50" : "border-amber-200 bg-amber-50"}`}><p className="text-xs uppercase text-slate-500">Accounting coding</p><p className="mt-1 text-xl font-semibold">{codingReady ? "Ready" : "Open"}</p></div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
          <h2 className="text-xl font-semibold">Invoice line review</h2>
          <p className="mt-2 text-sm text-slate-600">All lines on this exact supplier invoice remain visible. Only unresolved physical rows can enter physical progression.</p>

          <form id="bulk-progress-form" action={supervisorProgressSupplierInvoiceLinesAction}>
            <input type="hidden" name="order_id" value={orderId} />
            <input type="hidden" name="supplier_invoice_id" value={invoiceId} />
          </form>

          {!approved && physicalCandidates.length > 0 ? (
            <BulkLineSelectionControls selectableCount={physicalCandidates.length} />
          ) : null}

          <div className="mt-5 space-y-3">
            {invoiceLines.map((line) => {
              const done = progressed(line.eligible_for_invoice_yn);
              const resolution = resolutions.get(line.id);
              const dispute = disputes.get(line.id);
              const locked = Boolean(dispute || resolution);
              const canProgress = !approved && physicalCandidateIds.has(line.id);
              const classificationOnly = obviousNonPhysical(line);
              const suggestedType = suggestedFinancialType(line);
              const status = done
                ? "Progressed"
                : resolution
                  ? `Parked: ${resolution.financial_type}`
                  : dispute
                    ? `Exception: ${dispute}`
                    : classificationOnly
                      ? "Non-physical classification required"
                      : "Unresolved";
              const cardClass = done
                ? "border-emerald-200 bg-emerald-50"
                : locked
                  ? "border-amber-200 bg-amber-50"
                  : classificationOnly
                    ? "border-sky-200 bg-sky-50"
                    : "border-slate-200 bg-white";

              return (
                <article key={line.id} className={`rounded-2xl border p-4 ${cardClass}`}>
                  <div className="flex flex-wrap items-start justify-between gap-3">
                    <label className="font-semibold">
                      <input
                        type="checkbox"
                        name="line_ids"
                        value={line.id}
                        form="bulk-progress-form"
                        disabled={!canProgress}
                        className="mr-2"
                      />
                      Line {line.line_order ?? "—"} · {line.description || "No description"}
                    </label>
                    <span className="text-xs font-semibold">{status}</span>
                  </div>

                  {classificationOnly && !locked && !done ? (
                    <p className="mt-3 rounded-xl border border-sky-200 bg-white p-3 text-sm text-sky-900">
                      OCR financial row: keep the signed amount and classify it below. It cannot enter physical progression, tracking or shipment.
                    </p>
                  ) : null}

                  <p className="mt-3 text-sm text-slate-600">
                    Qty {Number(line.qty ?? 0)} · {gbp(line.amount_inc_vat_gbp)}{line.retailer_sku ? ` · SKU ${line.retailer_sku}` : ""}
                  </p>

                  {classificationOnly && !done && !locked ? (
                    <form action={supervisorResolveSupplierInvoiceLineNonPhysicalAction} className="mt-3 flex flex-wrap gap-2">
                      <input type="hidden" name="order_id" value={orderId} />
                      <input type="hidden" name="supplier_invoice_id" value={invoiceId} />
                      <input type="hidden" name="line_id" value={line.id} />
                      <select name="financial_type" defaultValue={suggestedType} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm">
                        <option value="delivery">delivery</option>
                        <option value="discount">discount</option>
                        <option value="fee">fee</option>
                        <option value="zero_value_delivery">zero_value_delivery</option>
                        <option value="rounding">rounding</option>
                        <option value="other_non_physical">other_non_physical</option>
                      </select>
                      <button className="rounded-xl border border-sky-300 bg-sky-50 px-3 py-2 text-sm font-semibold text-sky-800">Park</button>
                    </form>
                  ) : null}
                </article>
              );
            })}
            {invoiceLines.length === 0 ? <p className="text-sm text-slate-500">No supplier invoice lines found.</p> : null}
          </div>

          {!approved && physicalCandidates.length > 0 ? (
            <div className="mt-5 space-y-3 rounded-2xl border border-amber-200 bg-amber-50 p-4">
              <h3 className="font-semibold text-amber-950">Progress clean physical lines on this invoice</h3>
              <p className="text-sm text-amber-900">Only the selected supplier invoice is affected. Other invoice references remain unchanged.</p>
              <textarea form="bulk-progress-form" name="progress_notes" rows={3} className="w-full rounded-xl border border-amber-300 px-3 py-2 text-sm" placeholder="Supervisor progression note" />
              <button form="bulk-progress-form" className="rounded-xl bg-amber-800 px-4 py-2 text-sm font-semibold text-white">Progress selected lines</button>
            </div>
          ) : null}
        </section>

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