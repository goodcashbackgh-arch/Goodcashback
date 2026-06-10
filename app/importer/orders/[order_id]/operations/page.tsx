import Link from "next/link";
import { createClient } from "@/utils/supabase/server";
import { supabaseAdmin } from "@/lib/supabase/admin";
import { addTrackingSubmissionAction, flagSupplierInvoiceForReviewAction, submitInvoiceEvidenceAction } from "./actions";

type ScreenshotRow = { id: string; screenshot_url: string };
type TrackingRow = {
  id: string;
  tracking_ref: string;
  tracking_date: string | null;
  submitted_at: string | null;
  note: string | null;
  is_final_delivery_yn: boolean | null;
  couriers: { name: string } | null;
  tracking_screenshot_url?: string | null;
};
type InvoiceRow = { id: string; invoice_ref: string; review_status: string | null; review_notes: string | null; uploaded_at: string | null };
type InvoiceLineTotalRow = { supplier_invoice_id: string; qty: number; amount_inc_vat_gbp: number; eligible_for_invoice_yn?: string | null };
type InvoiceSummaryRow = { supplier_invoice_id: string; invoice_total_gbp: number };
type AdjustmentRow = { id: string; supplier_invoice_id: string | null; adjustment_type: string; amount_gbp: number; approval_status: string; requires_supervisor_approval: boolean | null };
type ReviewFlagRow = { id: string; supplier_invoice_id: string; flag_type: string; message: string; status: string; created_at: string };
type SaleDocumentRow = { amount_gbp: number | string | null; sage_invoice_id: string | null; invoice_type: string | null };
type AudienceStatusRow = {
  order_id: string;
  accepted_estimate_gbp: number | string | null;
  final_sale_value_gbp: number | string | null;
  canonical_amount_received_gbp: number | string | null;
  canonical_balance_due_gbp: number | string | null;
  potential_credit_pending_review_gbp: number | string | null;
  customer_sales_state: string | null;
  importer_status_label: string | null;
  importer_next_action: string | null;
};

const retiredInvoiceStatuses = new Set(["rejected_resubmit_required", "superseded", "duplicate_blocked"]);
const cardClass = "rounded-2xl border border-slate-200 bg-white p-4 shadow-sm";
const inputClass = "rounded-xl border border-slate-300 bg-white p-3 text-sm shadow-sm";
const secondaryButtonClass = "inline-flex min-h-9 items-center justify-center rounded-full border border-slate-200 bg-white px-3 py-1.5 text-xs font-semibold text-slate-700 shadow-sm hover:border-sky-300 hover:bg-sky-50 hover:text-sky-800";

function money(value: number | string | null | undefined, currency = "GBP") {
  const n = Number(value ?? 0);
  return new Intl.NumberFormat("en-GB", { style: "currency", currency, minimumFractionDigits: 2 }).format(n);
}

function localAmount(value: number | string | null | undefined, currencyCode?: string | null) {
  const n = Number(value ?? 0);
  return `${currencyCode ?? "Local"} ${new Intl.NumberFormat("en-GB", { minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(n)}`;
}

function formatDate(value: string | null | undefined) {
  if (!value) return "—";
  return value.includes("T") ? value.slice(0, 10) : value;
}

function adjustmentLabel(type: string) {
  if (type === "retailer_delivery") return "Final sale delivery adjustment";
  if (type === "retailer_discount") return "Final sale discount";
  return type;
}

function flagLabel(type: string) {
  if (type === "invoice_total_mismatch") return "Evidence total mismatch";
  if (type === "ocr_unclear") return "OCR unclear";
  if (type === "wrong_invoice") return "Wrong evidence";
  if (type === "delivery_discount_query") return "Delivery/discount query";
  if (type === "manual_line_needed") return "Manual line needed";
  return "Other";
}

function invoiceStatusLabel(status: string | null | undefined) {
  if (status === "rejected_resubmit_required") return "Rejected — audit only";
  if (status === "approved_current" || status === "ref_corrected_approved") return "Approved current";
  if (status === "duplicate_blocked") return "Duplicate blocked";
  if (status === "superseded") return "Superseded";
  return status ?? "Pending review";
}

function invoiceStatusClass(status: string | null | undefined) {
  if (status === "rejected_resubmit_required" || status === "duplicate_blocked") return "bg-rose-100 text-rose-800";
  if (status === "approved_current" || status === "ref_corrected_approved") return "bg-emerald-100 text-emerald-800";
  if (status === "superseded") return "bg-slate-200 text-slate-700";
  return "bg-amber-100 text-amber-800";
}

function signedMoney(value: number) {
  if (Math.abs(value) < 0.005) return money(0);
  return `${value > 0 ? "+" : ""}${money(value)}`;
}

function friendlyValue(value: string | null | undefined) {
  if (!value) return "—";
  if (value === "partially_progressed") return "Evidence reconciled; tracking open";
  if (value === "pending_dva_funding") return "Payment pending";
  if (value === "reconcilling" || value === "reconciling") return "Reconciling";
  return value.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase());
}

function fundingStatusClass(status: string | null | undefined, thresholdMet: boolean) {
  if (thresholdMet || status === "funded") return "bg-emerald-100 text-emerald-800";
  if (status === "pending_dva_funding" || status === "pending_funding") return "bg-amber-100 text-amber-800";
  return "bg-slate-100 text-slate-700";
}

function isProgressed(value: string | null | undefined) {
  return ["y", "yes", "true", "1"].includes((value ?? "").trim().toLowerCase());
}

function isRetiredInvoice(invoice: InvoiceRow) {
  return retiredInvoiceStatuses.has(invoice.review_status ?? "");
}

function operationalStatusLabel(args: { thresholdMet: boolean; orderHasResubmissionRequired: boolean; liveInvoiceRows: InvoiceRow[]; invoiceLineRows: InvoiceLineTotalRow[]; finalTrackingExists: boolean; finalBalanceDueGbp: number }) {
  if (args.orderHasResubmissionRequired) return "Evidence resubmission required";
  if (!args.thresholdMet) return "Initial payment required";
  if (args.finalBalanceDueGbp > 0.01) return "Final balance due";
  if (args.liveInvoiceRows.length === 0) return "Awaiting order evidence";
  if (args.invoiceLineRows.length > 0 && args.invoiceLineRows.every((line) => isProgressed(line.eligible_for_invoice_yn))) {
    return args.finalTrackingExists ? "Importer reconciliation complete" : "Evidence reconciled; tracking open";
  }
  return "Evidence review / reconciliation open";
}

export default async function OrderOperationsPage({ params, searchParams }: { params: Promise<{ order_id: string }>; searchParams: Promise<{ success?: string; order_ref?: string; auth_ref?: string; error?: string }> }) {
  const { order_id: orderId } = await params;
  const qp = await searchParams;
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return <main className="p-6">Please sign in.</main>;
  const { data: operator } = await supabase.from("operators").select("id").eq("auth_user_id", user.id).eq("active", true).maybeSingle();
  if (!operator) return <main className="p-6">Operator account required.</main>;

  const [{ data: order }, { data: screenshots }, { data: tracking }, { data: funding }, { data: invoices }, { data: couriers }, { data: adjustments }, { data: invoiceLines }, { data: invoiceSummaries }, { data: reviewFlags }, { data: saleDocuments }, { data: audienceStatus, error: audienceStatusError }] = await Promise.all([
    supabase.from("orders").select("*, importers(countries(currencies(code))), retailers(name)").eq("id", orderId).maybeSingle(),
    supabase.from("order_screenshots").select("*").eq("order_id", orderId).order("display_order"),
    supabase.from("order_tracking_submissions").select("*, couriers(name)").eq("order_id", orderId).order("submitted_at", { ascending: false }),
    supabase.from("order_funding_position_vw").select("*").eq("order_id", orderId).maybeSingle(),
    supabase.from("supplier_invoices").select("id, invoice_ref, review_status, review_notes, uploaded_at").eq("order_id", orderId).order("uploaded_at", { ascending: false }),
    supabase.from("couriers").select("id, name").order("name"),
    supabase.from("order_value_adjustments").select("id, supplier_invoice_id, adjustment_type, amount_gbp, approval_status, requires_supervisor_approval").eq("order_id", orderId).order("created_at", { ascending: false }),
    supabase.from("supplier_invoice_lines").select("supplier_invoice_id, qty, amount_inc_vat_gbp, eligible_for_invoice_yn, supplier_invoices!inner(order_id)").eq("supplier_invoices.order_id", orderId),
    supabase.from("supplier_invoice_financial_summary").select("supplier_invoice_id, invoice_total_gbp, supplier_invoices!inner(order_id)").eq("supplier_invoices.order_id", orderId),
    supabase.from("supplier_invoice_review_flags").select("id, supplier_invoice_id, flag_type, message, status, created_at").eq("order_id", orderId).order("created_at", { ascending: false }),
    (supabaseAdmin as any).from("sales_invoices").select("amount_gbp, sage_invoice_id, invoice_type").eq("order_id", orderId).eq("sage_status", "posted").not("sage_invoice_id", "is", null).in("invoice_type", ["main", "supplementary"]),
    (supabase as any).rpc("order_audience_status_v1", { p_order_id: orderId }).maybeSingle(),
  ]);

  if (audienceStatusError) throw audienceStatusError;
  if (!order) return <main className="p-6">Order not found.</main>;
  if (!audienceStatus) return <main className="p-6">Canonical order status unavailable. This page is blocked to avoid showing a stale balance.</main>;

  const canonicalAudienceStatus = audienceStatus as AudienceStatusRow;
  const trackingRows = (tracking ?? []) as TrackingRow[];
  const finalTrackingExists = trackingRows.some((t) => t.is_final_delivery_yn);
  const currencyCode = order.importers?.countries?.currencies?.code ?? null;
  const orderRetailerName = order.retailers?.name ?? "—";
  const adjustmentRows = (adjustments ?? []) as AdjustmentRow[];
  const invoiceRows = (invoices ?? []) as InvoiceRow[];
  const invoiceLineRows = (invoiceLines ?? []) as InvoiceLineTotalRow[];
  const liveInvoiceRows = invoiceRows.filter((invoice) => !isRetiredInvoice(invoice));
  const liveInvoiceIds = new Set(liveInvoiceRows.map((invoice) => invoice.id));
  const activeAdjustmentRows = adjustmentRows.filter((a) => a.approval_status !== "rejected" && (!a.supplier_invoice_id || liveInvoiceIds.has(a.supplier_invoice_id)));
  const rejectedInvoices = invoiceRows.filter((invoice) => invoice.review_status === "rejected_resubmit_required");
  const orderHasResubmissionRequired = rejectedInvoices.length > 0 && liveInvoiceRows.length === 0;
  const showInvoiceUploadForm = liveInvoiceRows.length === 0;
  const reviewFlagRows = (reviewFlags ?? []) as ReviewFlagRow[];
  const acceptedEstimateGbp = Number(canonicalAudienceStatus.accepted_estimate_gbp ?? order.order_total_gbp_declared ?? 0);
  const saleDocumentRows = (saleDocuments ?? []) as SaleDocumentRow[];
  const finalSaleValueConfirmed = canonicalAudienceStatus.customer_sales_state === "posted" || saleDocumentRows.some((row) => Boolean(row.sage_invoice_id));
  const finalSaleValueGbp = Number(canonicalAudienceStatus.final_sale_value_gbp ?? acceptedEstimateGbp);
  const amountReceivedGbp = Number(canonicalAudienceStatus.canonical_amount_received_gbp ?? 0);
  const finalBalanceDueGbp = Number(canonicalAudienceStatus.canonical_balance_due_gbp ?? 0);
  const creditDueGbp = Number(canonicalAudienceStatus.potential_credit_pending_review_gbp ?? 0);
  const orderGoodsBaseline = acceptedEstimateGbp;
  const fundingStatus = funding?.status as string | null | undefined;
  const thresholdMet = Boolean(funding?.threshold_met_yn);
  const fallbackOperationalStatus = operationalStatusLabel({ thresholdMet, orderHasResubmissionRequired, liveInvoiceRows, invoiceLineRows, finalTrackingExists, finalBalanceDueGbp });
  const operationalStatus = canonicalAudienceStatus.importer_status_label ?? fallbackOperationalStatus;

  const lineTotalsByInvoice = new Map<string, { qty: number; amount: number }>();
  for (const line of invoiceLineRows) {
    const current = lineTotalsByInvoice.get(line.supplier_invoice_id) ?? { qty: 0, amount: 0 };
    current.qty += Number(line.qty ?? 0);
    current.amount += Number(line.amount_inc_vat_gbp ?? 0);
    lineTotalsByInvoice.set(line.supplier_invoice_id, current);
  }

  const summaryByInvoice = new Map<string, InvoiceSummaryRow>();
  for (const summary of (invoiceSummaries ?? []) as InvoiceSummaryRow[]) summaryByInvoice.set(summary.supplier_invoice_id, summary);

  const reviewFlagsByInvoice = new Map<string, ReviewFlagRow[]>();
  for (const flag of reviewFlagRows) {
    const current = reviewFlagsByInvoice.get(flag.supplier_invoice_id) ?? [];
    current.push(flag);
    reviewFlagsByInvoice.set(flag.supplier_invoice_id, current);
  }

  return <main className="min-h-screen space-y-6 bg-slate-50 p-4 md:p-6">
    <header className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm md:p-6">
      <Link href="/importer" className="text-sm font-semibold text-sky-700 hover:underline">← Back to importer dashboard</Link>
      <div className="mt-4 flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
        <div>
          <p className="text-xs font-semibold uppercase tracking-[0.22em] text-sky-700">Order operations</p>
          <h1 className="mt-2 break-words text-2xl font-semibold tracking-tight text-slate-950 md:text-3xl">{order.order_ref ?? orderId}</h1>
          <p className="mt-1 break-all text-sm text-slate-500">{order.id}</p>
        </div>
        <span className={`w-fit rounded-full px-3 py-1 text-xs font-semibold ${orderHasResubmissionRequired ? "bg-rose-100 text-rose-800" : finalBalanceDueGbp > 0.01 ? "bg-amber-100 text-amber-800" : "bg-slate-100 text-slate-700"}`}>{operationalStatus}</span>
      </div>
    </header>

    {qp.error ? <div className="rounded-2xl border border-red-300 bg-red-50 p-3 text-sm text-red-700">{qp.error}</div> : null}
    {qp.success ? <div className="rounded-2xl border border-emerald-300 bg-emerald-50 p-3 text-sm text-emerald-900"><p className="font-semibold">{qp.success}</p><p>This estimate is based on the accepted order value. Final sale value updates once sale documents are posted.</p></div> : null}

    {orderHasResubmissionRequired ? <section className="rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-900 shadow-sm">
      <h2 className="font-semibold">Evidence rejected — upload corrected evidence</h2>
      <p className="mt-1">There is no current order evidence for this order. Upload the corrected evidence below.</p>
      {rejectedInvoices[0]?.review_notes ? <p className="mt-2"><span className="font-semibold">Supervisor note:</span> {rejectedInvoices[0].review_notes}</p> : null}
    </section> : rejectedInvoices.length > 0 ? <section className="rounded-2xl border border-slate-200 bg-white p-4 text-sm text-slate-700 shadow-sm">
      <h2 className="font-semibold text-slate-950">Rejected evidence kept for audit</h2>
      <p className="mt-1">A previous evidence upload was rejected, but a current evidence record is already present. Continue review/reconciliation on the current evidence.</p>
    </section> : null}

    <section className={cardClass}>
      <h2 className="text-lg font-semibold text-slate-950">Summary</h2>
      <div className="mt-4 grid gap-3 text-sm md:grid-cols-6">
        <div className="rounded-xl bg-slate-50 p-3"><div className="text-xs text-slate-500">Retailer</div><div className="font-semibold text-slate-950">{orderRetailerName}</div></div>
        <div className="rounded-xl bg-slate-50 p-3"><div className="text-xs text-slate-500">Quantity</div><div className="font-semibold text-slate-950">{order.total_qty_declared}</div></div>
        <div className="rounded-xl bg-slate-50 p-3"><div className="text-xs text-slate-500">Accepted estimate</div><div className="font-semibold text-slate-950">{money(acceptedEstimateGbp)}</div></div>
        <div className="rounded-xl bg-slate-50 p-3"><div className="text-xs text-slate-500">{finalSaleValueConfirmed ? "Final sale value" : "Estimated sale value"}</div><div className="font-semibold text-slate-950">{money(finalSaleValueGbp)}</div></div>
        <div className="rounded-xl bg-slate-50 p-3"><div className="text-xs text-slate-500">Balance due</div><div className={`font-semibold ${finalBalanceDueGbp > 0.01 ? "text-amber-900" : "text-slate-950"}`}>{money(finalBalanceDueGbp)}</div>{creditDueGbp > 0.01 ? <div className="mt-1 text-[11px] text-emerald-700">Credit due {money(creditDueGbp)}</div> : null}</div>
        <div className="rounded-xl bg-slate-50 p-3"><div className="text-xs text-slate-500">System</div><div className="font-semibold text-slate-950">{operationalStatus}</div></div>
      </div>
    </section>

    <section className={cardClass}>
      <div className="flex flex-col gap-2 md:flex-row md:items-start md:justify-between">
        <div><h2 className="text-lg font-semibold text-slate-950">Initial payment</h2><p className="mt-1 text-xs text-slate-500">Accepted-estimate threshold unlocks fulfilment. Any final balance or credit is shown once the final sale value is confirmed.</p></div>
        <span className={`w-fit rounded-full px-3 py-1 text-xs font-semibold ${fundingStatusClass(fundingStatus, thresholdMet)}`}>{thresholdMet ? "Initial payment received" : friendlyValue(fundingStatus)}</span>
      </div>
      <div className="mt-4 grid gap-3 text-sm md:grid-cols-3 lg:grid-cols-6">
        <div className="rounded-xl bg-slate-50 p-3"><div className="text-xs uppercase tracking-wide text-slate-500">Accepted estimate</div><div className="mt-1 font-semibold">{money(funding?.purchase_funding_threshold_gbp ?? acceptedEstimateGbp)}</div></div>
        <div className="rounded-xl bg-slate-50 p-3"><div className="text-xs uppercase tracking-wide text-slate-500">Confirmed DVA</div><div className="mt-1 font-semibold">{money(funding?.confirmed_dva_funding_gbp)}</div></div>
        <div className="rounded-xl bg-slate-50 p-3"><div className="text-xs uppercase tracking-wide text-slate-500">Applied credit</div><div className="mt-1 font-semibold">{money(funding?.applied_credit_gbp)}</div></div>
        <div className="rounded-xl bg-slate-50 p-3"><div className="text-xs uppercase tracking-wide text-slate-500">Amount received</div><div className="mt-1 font-semibold">{money(amountReceivedGbp)}</div></div>
        <div className="rounded-xl bg-slate-50 p-3"><div className="text-xs uppercase tracking-wide text-slate-500">Final balance</div><div className="mt-1 font-semibold">{money(finalBalanceDueGbp)}</div></div>
        <div className="rounded-xl bg-slate-50 p-3"><div className="text-xs uppercase tracking-wide text-slate-500">Auth ref</div><div className="mt-1 break-words font-semibold">{funding?.payment_auth_id ?? order.payment_auth_id ?? "—"}</div></div>
      </div>
    </section>

    <section className={cardClass}>
      <h2 className="text-lg font-semibold text-slate-950">Screenshots</h2>
      <div className="mt-3 flex flex-wrap gap-3">{((screenshots ?? []) as ScreenshotRow[]).map((s) => <a key={s.id} href={s.screenshot_url} target="_blank" className="block rounded-xl border bg-white p-1 shadow-sm"><img src={s.screenshot_url} alt="Screenshot" style={{ width: 160, height: 120, objectFit: "contain" }} /></a>)}</div>
    </section>

    <section id="tracking" className={cardClass}>
      <h2 className="text-lg font-semibold text-slate-950">Tracking</h2>
      {finalTrackingExists ? <p className="mt-2 text-sm text-amber-700">Final delivery has already been marked. Add more tracking only if this was done in error.</p> : null}
      <form action={addTrackingSubmissionAction} className="mt-4 grid gap-3 md:grid-cols-2">
        <input type="hidden" name="order_id" value={orderId} />
        <select name="courier_id" required className={inputClass}><option value="">Courier</option>{(couriers ?? []).map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</select>
        <input name="tracking_ref" required className={inputClass} placeholder="Tracking ref" />
        <input name="tracking_date" type="date" required className={inputClass} />
        <input name="tracking_screenshot_url" className={inputClass} placeholder="Tracking URL / courier tracking link" />
        <input name="tracking_evidence_file" type="file" accept=".pdf,image/*,.png,.jpg,.jpeg,.webp" className={inputClass} />
        <input name="note" className={inputClass} placeholder="Note" />
        <label className="flex items-center gap-2 text-sm"><input type="checkbox" name="is_final_delivery_yn" />This completes delivery for this order</label>
        <p className="text-xs text-slate-500 md:col-span-2">Use the retailer/courier tracking URL as the main live tracking source. Upload a dispatch screenshot, PDF, or delivery note as supporting evidence where useful.</p>
        <button className="w-fit rounded-full bg-sky-600 px-4 py-2 text-sm font-semibold text-white shadow-sm">Add tracking</button>
      </form>
      {trackingRows.length === 0 ? <p className="mt-4 rounded-xl bg-slate-50 p-3 text-sm text-slate-600">No tracking submitted yet.</p> : <div className="mt-4 space-y-2 text-sm">{trackingRows.map((t) => <details key={t.id} className="rounded-xl border border-slate-200 bg-slate-50 p-3"><summary className="cursor-pointer list-none"><div className="flex flex-col gap-2 md:flex-row md:items-center md:justify-between"><div className="flex flex-wrap items-center gap-2"><span className="font-semibold">{t.couriers?.name ?? "Courier"} · {t.tracking_ref}</span><span className="text-slate-500">·</span><span>{formatDate(t.tracking_date)}</span>{t.is_final_delivery_yn ? <span className="rounded-full bg-emerald-100 px-2 py-1 text-xs font-semibold text-emerald-800">Final delivery</span> : null}</div><span className="font-semibold text-sky-700 underline">View details</span></div></summary>{t.note ? <p className="mt-3 rounded bg-white p-2 text-xs text-slate-700"><span className="font-medium">Note:</span> {t.note}</p> : null}</details>)}</div>}
    </section>

    <section id="invoice" className={cardClass}>
      <h2 className="text-lg font-semibold text-slate-950">Order evidence</h2>
      <p className="mt-1 text-xs text-slate-500">Expected retailer for evidence matching: <span className="font-semibold text-slate-700">{orderRetailerName}</span></p>
      {showInvoiceUploadForm ? <div className="mt-4 rounded-2xl border border-slate-200 bg-slate-50 p-4"><p className={orderHasResubmissionRequired ? "mb-3 rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm text-rose-900" : "mb-3 text-sm text-slate-600"}>{orderHasResubmissionRequired ? "Upload corrected order evidence here. Rejected evidence remains visible below for audit only." : "No order evidence has been uploaded for this order yet."}</p><form action={submitInvoiceEvidenceAction} className="grid gap-3 md:grid-cols-3"><input type="hidden" name="order_id" value={orderId} /><input name="invoice_ref" placeholder="Evidence ref" className={inputClass} required /><input name="invoice_total_gbp" type="number" min="0.01" step="0.01" placeholder="Evidence total GBP" className={inputClass} required /><input name="invoice_file" type="file" accept=".pdf,image/*,.png,.jpg,.jpeg,.webp" className={inputClass} required /><input name="retailer_delivery_gbp" type="number" min="0" step="0.01" placeholder="Optional delivery charge GBP" className={inputClass} /><input name="retailer_discount_gbp" type="number" min="0" step="0.01" placeholder="Optional discount GBP" className={inputClass} /><p className="text-xs text-slate-500 md:col-span-3">Evidence total is checked against: accepted estimate + delivery - discount. Item lines remain a separate reconciliation check.</p><button className="w-fit rounded-full bg-emerald-700 px-4 py-2 text-sm font-semibold text-white shadow-sm">{orderHasResubmissionRequired ? "Upload corrected evidence" : "Upload evidence"}</button></form></div> : <p className="mt-4 rounded-2xl border border-emerald-200 bg-emerald-50 p-3 text-sm text-emerald-900">A current order evidence record is already present. Continue review/reconciliation below instead of uploading another one.</p>}

      <div className="mt-4 space-y-3 text-sm">
        {invoiceRows.map((invoice) => {
          const goods = lineTotalsByInvoice.get(invoice.id) ?? { qty: 0, amount: 0 };
          const invoiceAdjustments = adjustmentRows.filter((a) => a.supplier_invoice_id === invoice.id);
          const invoiceFlags = reviewFlagsByInvoice.get(invoice.id) ?? [];
          const activeFlags = invoiceFlags.filter((flag) => ["open", "under_review"].includes(flag.status));
          const auditFlags = invoiceFlags.filter((flag) => !["open", "under_review"].includes(flag.status));
          const deliveryTotal = invoiceAdjustments.filter((a) => a.adjustment_type === "retailer_delivery" && a.approval_status !== "rejected").reduce((sum, a) => sum + Number(a.amount_gbp ?? 0), 0);
          const discountTotal = invoiceAdjustments.filter((a) => a.adjustment_type === "retailer_discount" && a.approval_status !== "rejected").reduce((sum, a) => sum + Number(a.amount_gbp ?? 0), 0);
          const expectedInvoiceTotal = orderGoodsBaseline + deliveryTotal - discountTotal;
          const summary = summaryByInvoice.get(invoice.id);
          const invoiceTotal = Number(summary?.invoice_total_gbp ?? 0);
          const variance = expectedInvoiceTotal - invoiceTotal;
          const matched = summary && Math.abs(variance) < 0.01;
          const retired = isRetiredInvoice(invoice);

          return <div key={invoice.id} className={`rounded-2xl border p-4 ${retired ? "border-rose-100 bg-rose-50/70" : "border-slate-200 bg-slate-50"}`}>
            <div className="flex flex-wrap items-center justify-between gap-2"><div className="flex flex-wrap items-center gap-2"><span className="text-base font-semibold text-slate-950">{invoice.invoice_ref}</span>{!retired ? <Link className={secondaryButtonClass} href={`/importer/reconciliation/${orderId}`}>Reconcile</Link> : <span className="rounded-full bg-white px-2.5 py-1 text-xs font-semibold text-rose-800">Audit only</span>}</div><div className="flex flex-wrap gap-2"><span className={`rounded-full px-2.5 py-1 text-xs font-semibold ${invoiceStatusClass(invoice.review_status)}`}>{invoiceStatusLabel(invoice.review_status)}</span>{!retired && summary ? <span className={`rounded-full px-2.5 py-1 text-xs font-semibold ${matched ? "bg-emerald-100 text-emerald-800" : "bg-amber-100 text-amber-800"}`}>{matched ? "Evidence total matched" : "Evidence total variance"}</span> : null}{!retired && activeFlags.length > 0 ? <span className="rounded-full bg-rose-100 px-2.5 py-1 text-xs font-semibold text-rose-800">Flagged for review</span> : null}</div></div>
            {retired ? <div className="mt-3 rounded-xl border border-rose-100 bg-white p-3 text-xs text-rose-900"><span className="font-semibold">Rejected/retired from current workflow.</span> {invoice.review_notes ? `Reason: ${invoice.review_notes}` : "Kept for audit only."}</div> : summary ? <div className="mt-3 grid gap-2 text-xs md:grid-cols-7"><div><span className="text-slate-500">Goods qty</span><div className="font-medium">{goods.qty}</div></div><div><span className="text-slate-500">Item lines</span><div className="font-medium">{money(goods.amount)}</div></div><div><span className="text-slate-500">Accepted estimate</span><div className="font-medium">{money(orderGoodsBaseline)}</div></div><div><span className="text-slate-500">Delivery</span><div className="font-medium">{money(deliveryTotal)}</div></div><div><span className="text-slate-500">Discount</span><div className="font-medium">-{money(discountTotal)}</div></div><div><span className="text-slate-500">Expected total</span><div className="font-medium">{money(expectedInvoiceTotal)}</div></div><div><span className="text-slate-500">Variance</span><div className="font-medium">{signedMoney(variance)}</div></div></div> : null}
            {!retired && activeFlags.length > 0 ? <div className="mt-3 space-y-1"><h4 className="text-xs font-semibold uppercase tracking-wide text-slate-500">Open review flags</h4>{activeFlags.map((flag) => <div key={flag.id} className="rounded-xl border border-amber-200 bg-amber-50 p-2 text-xs text-amber-900"><span className="font-semibold">{flagLabel(flag.flag_type)} · {flag.status}</span> — {flag.message}</div>)}</div> : null}
            {auditFlags.length > 0 ? <details className="mt-3 rounded-xl border border-slate-200 bg-white p-3"><summary className="cursor-pointer text-xs font-semibold text-slate-600">Show resolved/audit flags</summary><div className="mt-2 space-y-1">{auditFlags.map((flag) => <div key={flag.id} className="rounded-lg bg-slate-50 p-2 text-xs text-slate-600"><span className="font-semibold">{flagLabel(flag.flag_type)} · {flag.status}</span> — {flag.message}</div>)}</div></details> : null}
            {!retired ? <form action={flagSupplierInvoiceForReviewAction} className="mt-3 grid gap-2 md:grid-cols-[220px_1fr_auto]"><input type="hidden" name="order_id" value={orderId} /><input type="hidden" name="supplier_invoice_id" value={invoice.id} /><select name="flag_type" className={inputClass} defaultValue="invoice_total_mismatch"><option value="invoice_total_mismatch">Evidence total mismatch</option><option value="ocr_unclear">OCR unclear</option><option value="wrong_invoice">Wrong evidence</option><option value="delivery_discount_query">Delivery/discount query</option><option value="manual_line_needed">Manual line needed</option><option value="other">Other</option></select><input name="message" className={inputClass} placeholder="Explain what supervisor should check" required /><button className="rounded-full bg-amber-700 px-3 py-2 text-xs font-semibold text-white shadow-sm">Flag for review</button></form> : null}
          </div>;
        })}
      </div>

      {activeAdjustmentRows.length > 0 ? <div className="mt-4 space-y-1 text-sm"><h3 className="font-medium">Active final sale adjustments for current evidence</h3>{activeAdjustmentRows.map((a) => <div key={a.id} className="rounded-xl bg-slate-50 p-2">{adjustmentLabel(a.adjustment_type)} — {money(a.amount_gbp)} — {a.approval_status}</div>)}</div> : null}
    </section>
  </main>;
}
