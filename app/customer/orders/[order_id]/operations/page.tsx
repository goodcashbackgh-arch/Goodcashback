import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { supabaseAdmin } from "@/lib/supabase/admin";

type ScreenshotRow = { id: string; screenshot_url: string };
type ReviewLinkRow = { customer_review_path: string | null };
type CreditBalanceRow = { available_credit_gbp: number | string | null };
type ShipmentPackageRow = { shipment_batch_id: string | null };
type ShipmentBatchRow = { id: string; dispatched_at?: string | null; shipment_cutoff_at?: string | null; booking_ref?: string | null };
type InvoiceRow = { id: string; amount_gbp?: number | string | null; invoice_type?: string | null; sage_invoice_id?: string | null; sage_invoice_date?: string | null; sage_posted_at?: string | null };
type EvidenceRow = { document_kind?: string | null; review_status?: string | null };
type Tone = "action" | "ready" | "complete" | "review" | "muted";

function money(value: unknown) {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP", minimumFractionDigits: 2 }).format(Number(value ?? 0));
}

function localAmount(value: unknown, code = "Local") {
  return `${code} ${new Intl.NumberFormat("en-GB", { minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(Number(value ?? 0))}`;
}

function friendly(value: string | null | undefined) {
  if (!value) return "-";
  return value.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase());
}

function saleDocumentLabel(value: string | null | undefined) {
  if (value === "supplementary") return "Final sale adjustment";
  if (value === "credit_note") return "Sale credit";
  return "Sale document";
}

function saleDocumentSignedAmount(row: InvoiceRow) {
  const amount = Number(row.amount_gbp ?? 0);
  return row.invoice_type === "credit_note" ? -Math.abs(amount) : amount;
}

function signedMoney(value: number) {
  return value < 0 ? `-${money(Math.abs(value))}` : `+${money(value)}`;
}

function invoiceSortRank(value: string | null | undefined) {
  if (value === "main") return 0;
  if (value === "supplementary") return 1;
  if (value === "credit_note") return 2;
  return 3;
}

function shortOrderTitle(orderRef: string | null | undefined, fallbackId: string) {
  const cleaned = (orderRef || fallbackId).replace(/^ORD-/i, "");
  return `Order ${cleaned.length > 6 ? cleaned.slice(-6) : cleaned}`;
}

function formatDate(value: string | null | undefined) {
  if (!value) return "-";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "-";
  return new Intl.DateTimeFormat("en-GB", { day: "2-digit", month: "short", year: "numeric" }).format(date);
}

function addWeeks(value: string | null | undefined, weeks: number) {
  if (!value) return null;
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return null;
  date.setDate(date.getDate() + weeks * 7);
  return date.toISOString();
}

function deliveryWindow(value: string | null | undefined) {
  const start = addWeeks(value, 5);
  const end = addWeeks(value, 8);
  if (!start || !end) return null;
  return `${formatDate(start)} - ${formatDate(end)}`;
}

function toneCardClass(tone: Tone) {
  if (tone === "action") return "border-amber-200 bg-amber-50 text-amber-950";
  if (tone === "ready") return "border-sky-200 bg-sky-50 text-sky-950";
  if (tone === "complete") return "border-emerald-200 bg-emerald-50 text-emerald-950";
  if (tone === "review") return "border-rose-200 bg-rose-50 text-rose-950";
  return "border-slate-200 bg-white text-slate-950";
}

function tonePillClass(tone: Tone) {
  if (tone === "action") return "bg-amber-100 text-amber-900 ring-amber-200";
  if (tone === "ready") return "bg-sky-100 text-sky-900 ring-sky-200";
  if (tone === "complete") return "bg-emerald-100 text-emerald-800 ring-emerald-200";
  if (tone === "review") return "bg-rose-100 text-rose-900 ring-rose-200";
  return "bg-slate-100 text-slate-700 ring-slate-200";
}

function journeyClass(done: boolean, current: boolean) {
  if (done) return "border-emerald-200 bg-emerald-50 text-emerald-900 ring-emerald-100";
  if (current) return "border-sky-200 bg-sky-50 text-sky-950 ring-sky-100";
  return "border-slate-200 bg-white text-slate-500 ring-slate-100";
}

export default async function CustomerOrderOperationsPage({ params, searchParams }: { params: Promise<{ order_id: string }>; searchParams?: Promise<{ success?: string; error?: string }> }) {
  const { order_id: orderId } = await params;
  const qp = searchParams ? await searchParams : {};
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: operator } = await supabase.from("operators").select("id, full_name").eq("auth_user_id", user.id).eq("active", true).maybeSingle();
  if (!operator) redirect("/auth/check");

  const { data: order } = await supabase.from("orders").select("*, importers(id, company_name, trading_name, country_id, countries(currencies(code)))").eq("id", orderId).maybeSingle();
  if (!order) redirect("/customer");

  const { data: access } = await supabase.from("operator_importers").select("id").eq("operator_id", operator.id).eq("importer_id", order.importer_id).is("revoked_at", null).limit(1).maybeSingle();
  if (!access) redirect("/customer");

  const today = new Date().toISOString().slice(0, 10);
  const [fundingRes, screenshotsRes, stateRes, reviewRes, creditBalanceRes, fxRes, shipmentPackageRes, invoiceRes] = await Promise.all([
    supabase.from("order_funding_position_vw").select("*").eq("order_id", orderId).maybeSingle(),
    supabase.from("order_screenshots").select("id, screenshot_url").eq("order_id", orderId).order("display_order"),
    supabase.from("order_state_vw").select("lifecycle_status").eq("id", orderId).maybeSingle(),
    (supabase as any).rpc("customer_active_order_review_link_v1", { p_order_id: orderId }).maybeSingle(),
    supabase.rpc("customer_importer_credit_balance_v1"),
    supabase.from("fx_rates").select("quote_rate, quote_card_markup_pct, rate_date").eq("country_id", order.importers?.country_id).lte("rate_date", today).order("rate_date", { ascending: false }).limit(1).maybeSingle(),
    (supabaseAdmin as any).from("shipper_shipment_batch_packages").select("shipment_batch_id").eq("order_id", orderId).eq("active", true),
    (supabaseAdmin as any).from("sales_invoices").select("id, amount_gbp, invoice_type, sage_invoice_id, sage_invoice_date, sage_posted_at").eq("order_id", orderId).eq("sage_status", "posted").not("sage_invoice_id", "is", null).in("invoice_type", ["main", "supplementary", "credit_note"]),
  ]);

  const shipmentPackages = (shipmentPackageRes.data ?? []) as ShipmentPackageRow[];
  const shipmentBatchIds = Array.from(new Set(shipmentPackages.map((row) => row.shipment_batch_id).filter(Boolean) as string[]));
  const [{ data: shipmentBatchData }, { data: evidenceData }] = await Promise.all([
    shipmentBatchIds.length > 0 ? (supabaseAdmin as any).from("shipper_shipment_batches").select("id, booking_ref, dispatched_at, shipment_cutoff_at").in("id", shipmentBatchIds).order("dispatched_at", { ascending: false }) : Promise.resolve({ data: [] }),
    shipmentBatchIds.length > 0 ? (supabaseAdmin as any).from("shipper_final_export_evidence_documents").select("document_kind, review_status").in("shipment_batch_id", shipmentBatchIds) : Promise.resolve({ data: [] }),
  ]);

  const shipmentBatches = (shipmentBatchData ?? []) as ShipmentBatchRow[];
  const shipmentBatch = shipmentBatches[0] ?? null;
  const shippingDate = shipmentBatch?.dispatched_at ?? null;
  const estimatedWindow = deliveryWindow(shippingDate);
  const shipmentArranged = Boolean(shippingDate || shipmentBatch?.booking_ref || shipmentBatchIds.length > 0);
  const evidenceRows = (evidenceData ?? []) as EvidenceRow[];
  const deliveryConfirmed = evidenceRows.some((row) => row.document_kind === "pod_delivery_evidence" && row.review_status === "accepted_current");
  const finalExportAccepted = evidenceRows.some((row) => row.document_kind !== "pod_delivery_evidence" && row.review_status === "accepted_current");
  const invoices = ((invoiceRes.data ?? []) as InvoiceRow[]).sort((a, b) => {
    const rank = invoiceSortRank(a.invoice_type) - invoiceSortRank(b.invoice_type);
    if (rank !== 0) return rank;
    return String(a.sage_posted_at ?? a.sage_invoice_date ?? "").localeCompare(String(b.sage_posted_at ?? b.sage_invoice_date ?? ""));
  });

  const funding = fundingRes.data;
  const state = stateRes.data;
  const screenshots = (screenshotsRes.data ?? []) as ScreenshotRow[];
  const reviewLink = reviewRes.data as ReviewLinkRow | null;
  const reviewHref = reviewLink?.customer_review_path ?? null;
  const thresholdMet = Boolean(funding?.threshold_met_yn);
  const acceptedEstimateGbp = Number(order.order_total_gbp_declared ?? 0);
  const totalQty = Number(order.total_qty_declared ?? 0);
  const appliedCreditGbp = Number(funding?.applied_credit_gbp ?? 0);
  const confirmedPaymentGbp = Number(funding?.confirmed_dva_funding_gbp ?? 0);
  const amountReceivedGbp = confirmedPaymentGbp + appliedCreditGbp;
  const initialCashDueGbp = Math.max(acceptedEstimateGbp - amountReceivedGbp, 0);
  const finalSaleValueConfirmed = invoices.length > 0;
  const finalSaleValueGbp = finalSaleValueConfirmed ? invoices.reduce((sum, row) => sum + saleDocumentSignedAmount(row), 0) : acceptedEstimateGbp;
  const finalBalanceDueGbp = finalSaleValueConfirmed ? Math.max(finalSaleValueGbp - amountReceivedGbp, 0) : 0;
  const visibleCashDueGbp = finalSaleValueConfirmed ? finalBalanceDueGbp : initialCashDueGbp;
  const pendingCreditGbp = finalSaleValueConfirmed ? Math.max(amountReceivedGbp - finalSaleValueGbp, 0) : 0;
  const hasAmountReceived = amountReceivedGbp > 0.01;

  const rate = Number(fxRes.data?.quote_rate ?? 0);
  const markup = Number(fxRes.data?.quote_card_markup_pct ?? 0);
  const effectiveRate = rate ? rate * (1 + markup / 100) : 0;
  const fxDate = fxRes.data?.rate_date as string | undefined;
  const fxLabel = fxDate === today ? "today's FX" : fxDate ? `latest FX ${fxDate}` : "no FX available";
  const importerRelation = order.importers as any;
  const currencyCode = importerRelation?.countries?.currencies?.code ?? "Local";
  const visibleCashDueLocal = effectiveRate ? visibleCashDueGbp * effectiveRate : 0;
  const finalBalanceDueLocal = effectiveRate ? finalBalanceDueGbp * effectiveRate : 0;
  const appliedCreditLocal = effectiveRate ? appliedCreditGbp * effectiveRate : 0;
  const creditBalanceRows = (creditBalanceRes.data ?? []) as CreditBalanceRow[];
  const availableCreditGbp = creditBalanceRows.reduce((sum, row) => sum + Number(row.available_credit_gbp ?? 0), 0);
  const availableCreditLocal = effectiveRate ? availableCreditGbp * effectiveRate : 0;

  const statusRaw = String(state?.lifecycle_status ?? order.status ?? "").toLowerCase();
  const statusLabel = reviewHref ? "Ready for your review" : !thresholdMet ? "Payment required" : finalBalanceDueGbp > 0.01 ? "Final balance due" : deliveryConfirmed ? "Completed" : shipmentArranged ? "Shipment arranged" : ["pending_dva_funding", "funding_pending", "draft"].includes(statusRaw) ? "Payment received; processing" : ["reconciling", "partially_progressed", "invoice_reconciled_tracking_open"].includes(statusRaw) ? "Order being prepared" : ["ready_for_shipment", "shipment_booked"].includes(statusRaw) ? "Preparing for shipment" : ["shipment_dispatched", "awaiting_importer_receipt"].includes(statusRaw) ? "Shipment in progress" : ["completed", "archived"].includes(statusRaw) ? "Completed" : ["discrepancy_open", "awaiting_financial_closure"].includes(statusRaw) ? "Under review" : friendly(state?.lifecycle_status ?? order.status);
  const tone: Tone = reviewHref ? "ready" : !thresholdMet || finalBalanceDueGbp > 0.01 ? "action" : statusLabel.toLowerCase().includes("completed") ? "complete" : statusLabel.toLowerCase().includes("review") ? "review" : "muted";
  const nextActionTitle = reviewHref ? "Review items before shipment" : !thresholdMet ? "Payment required" : finalBalanceDueGbp > 0.01 ? "Final balance due" : deliveryConfirmed ? "Delivery confirmed" : shipmentArranged ? "Waiting for delivery confirmation" : "No action needed right now";
  const nextActionBody = reviewHref
    ? "Check the order before shipment and request a hold if anything should not be sent."
    : !thresholdMet && appliedCreditGbp > 0.01
      ? `Account credit of ${money(appliedCreditGbp)} has been applied. ${money(initialCashDueGbp)} remains due before this order can continue${effectiveRate ? ` (${localAmount(visibleCashDueLocal, currencyCode)} using ${fxLabel}).` : "."}`
      : !thresholdMet
        ? "The accepted estimate needs to be paid before this order can continue."
        : finalBalanceDueGbp > 0.01
          ? `The final sale value is now confirmed. Balance due: ${money(finalBalanceDueGbp)}${effectiveRate ? ` (${localAmount(finalBalanceDueLocal, currencyCode)} using ${fxLabel}).` : "."}`
          : deliveryConfirmed
            ? "Delivery confirmation has been received."
            : shipmentArranged
              ? (estimatedWindow ? `Estimated delivery window: ${estimatedWindow}.` : "Shipping date is pending from the shipper.")
              : "We are processing this order. You can return here to check progress.";
  const journey = [
    { label: "Order received", done: true },
    ...(appliedCreditGbp > 0.01 ? [{ label: "Account credit applied", done: true }] : []),
    { label: thresholdMet ? "Payment received" : "Payment remaining", done: thresholdMet },
    { label: "Items confirmed", done: thresholdMet && (shipmentArranged || finalExportAccepted || finalSaleValueConfirmed) },
    { label: "Shipment arranged", done: shipmentArranged },
    { label: "Sale value confirmed", done: finalSaleValueConfirmed },
    { label: "Delivery confirmation", done: deliveryConfirmed },
  ];
  const firstPending = journey.findIndex((step) => !step.done);
  const orderTitle = shortOrderTitle(order.order_ref, orderId);
  const itemLabel = Number.isFinite(totalQty) && totalQty > 0 ? `${totalQty} ${totalQty === 1 ? "item" : "items"}` : "Goods order";
  const paymentPillLabel = thresholdMet ? "Payment received" : appliedCreditGbp > 0.01 ? "Part-paid" : "Required";

  return (
    <main className="min-h-screen bg-gradient-to-b from-sky-50 via-white to-slate-50 p-4 pb-24 text-slate-950 xl:p-6 xl:pb-10">
      <Link href="/customer" className="inline-flex items-center rounded-full bg-white/80 px-3 py-2 text-sm font-black text-sky-700 ring-1 ring-sky-100">← Customer dashboard</Link>
      <header className="mt-4 overflow-hidden rounded-[2rem] border border-sky-100 bg-white shadow-sm">
        <div className="bg-gradient-to-r from-sky-500 via-cyan-400 to-emerald-300 px-5 py-2" />
        <div className="p-5 xl:flex xl:items-start xl:justify-between xl:gap-6 xl:p-7">
          <div className="min-w-0"><p className="text-xs font-black uppercase tracking-[0.28em] text-sky-600">Customer order</p><h1 className="mt-2 text-4xl font-black tracking-tight xl:text-5xl">{orderTitle}</h1><p className="mt-2 text-sm font-semibold text-slate-600">{itemLabel} · Ref: {order.order_ref ?? orderId}</p><p className="mt-1 text-xs font-black uppercase tracking-wide text-slate-500">Authorisation ref: {order.payment_auth_id ?? "Not assigned"}</p></div>
          <div className="mt-5 xl:mt-0 xl:min-w-72"><div className={`rounded-2xl border p-4 ${toneCardClass(tone)}`}><p className="text-xs font-black uppercase tracking-wide opacity-70">Current status</p><p className="mt-1 text-2xl font-black">{statusLabel}</p><p className="mt-3 text-xs font-black uppercase tracking-wide opacity-70">Next step</p><p className="mt-1 text-sm font-black">{nextActionTitle}</p>{appliedCreditGbp > 0.01 && !thresholdMet ? <p className="mt-3 text-xs font-bold opacity-80">Account credit applied: {money(appliedCreditGbp)} · Cash due: {money(initialCashDueGbp)}</p> : null}</div></div>
          {qp.success ? <p className="mt-4 rounded-xl border border-emerald-200 bg-emerald-50 p-3 text-sm font-semibold text-emerald-800 xl:col-span-2">{qp.success}</p> : null}
          {qp.error ? <p className="mt-4 rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm font-semibold text-rose-800 xl:col-span-2">{qp.error}</p> : null}
        </div>
      </header>

      <section className={`mt-5 rounded-[1.75rem] border p-5 shadow-sm ${toneCardClass(tone)}`}><div className="xl:flex xl:items-center xl:justify-between xl:gap-6"><div><p className="text-xs font-black uppercase tracking-[0.2em] opacity-70">Next step</p><h2 className="mt-2 text-2xl font-black">{nextActionTitle}</h2><p className="mt-2 text-sm leading-6 opacity-80">{nextActionBody}</p></div>{reviewHref ? <Link href={reviewHref} className="mt-4 block rounded-2xl bg-slate-950 px-5 py-3 text-center text-sm font-black text-white shadow-sm xl:mt-0">Open review</Link> : null}</div></section>
      <section className="mt-5 overflow-hidden rounded-[1.75rem] border border-slate-200 bg-white p-5 shadow-sm"><h2 className="text-xl font-black">Order journey</h2><p className="mt-1 text-sm text-slate-600">A customer-safe view of the order progress.</p><div className="mt-5 flex gap-3 overflow-x-auto pb-2">{journey.map((step, index) => <div key={step.label} className={`min-w-[9.5rem] rounded-2xl border px-4 py-3 text-sm font-black shadow-sm ring-1 ${journeyClass(step.done, index === firstPending)}`}><span className="mr-2">{step.done ? "✓" : index === firstPending ? "•" : "○"}</span>{step.label}</div>)}</div></section>

      <section className="mt-5 grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-4">
        <div className="rounded-[1.5rem] border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs font-black uppercase tracking-wide text-slate-500">Accepted estimate</p><p className="mt-2 text-2xl font-black">{money(acceptedEstimateGbp)}</p><p className="mt-1 text-xs font-bold text-slate-500">Authorisation ref: {order.payment_auth_id ?? "Not assigned"}</p></div>
        {hasAmountReceived ? <div className="rounded-[1.5rem] border border-cyan-100 bg-cyan-50/70 p-4 shadow-sm"><p className="text-xs font-black uppercase tracking-wide text-cyan-700">Amount received</p><p className="mt-2 text-2xl font-black text-cyan-950">{money(amountReceivedGbp)}</p>{appliedCreditGbp > 0.01 ? <p className="mt-1 text-xs font-bold text-cyan-800">Account credit applied: {money(appliedCreditGbp)}</p> : null}</div> : null}
        {!thresholdMet && visibleCashDueGbp > 0.01 ? <div className="rounded-[1.5rem] border border-amber-100 bg-amber-50/70 p-4 shadow-sm"><p className="text-xs font-black uppercase tracking-wide text-amber-700">Cash due</p><p className="mt-2 text-2xl font-black text-amber-950">{money(visibleCashDueGbp)}</p><p className="mt-1 text-xs font-bold text-amber-800">{effectiveRate ? localAmount(visibleCashDueLocal, currencyCode) : "No FX rate"}</p><p className="mt-1 text-[11px] font-semibold text-amber-700">{fxLabel}</p></div> : null}
        {finalSaleValueConfirmed ? <div className="rounded-[1.5rem] border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs font-black uppercase tracking-wide text-slate-500">Final sale value</p><p className="mt-2 text-2xl font-black">{money(finalSaleValueGbp)}</p><p className="mt-1 text-xs font-bold text-slate-500">After sale documents and credits</p></div> : null}
        {thresholdMet && finalBalanceDueGbp > 0.01 ? <div className="rounded-[1.5rem] border border-amber-100 bg-amber-50/70 p-4 shadow-sm"><p className="text-xs font-black uppercase tracking-wide text-amber-700">Balance due</p><p className="mt-2 text-2xl font-black text-amber-950">{money(finalBalanceDueGbp)}</p><p className="mt-1 text-xs font-bold text-amber-800">{effectiveRate ? localAmount(finalBalanceDueLocal, currencyCode) : "No FX rate"}</p><p className="mt-1 text-[11px] font-semibold text-amber-700">{fxLabel}</p></div> : null}
        {pendingCreditGbp > 0.01 ? <div className="rounded-[1.5rem] border border-emerald-100 bg-emerald-50/70 p-4 shadow-sm"><p className="text-xs font-black uppercase tracking-wide text-emerald-700">Potential credit pending final review</p><p className="mt-2 text-2xl font-black text-emerald-950">{money(pendingCreditGbp)}</p><p className="mt-1 text-xs font-bold text-emerald-800">Not available until supervisor approval</p></div> : null}
        <div className={`rounded-[1.5rem] border p-4 shadow-sm ${thresholdMet ? "border-emerald-100 bg-emerald-50/70" : "border-amber-100 bg-amber-50/70"}`}><p className={`text-xs font-black uppercase tracking-wide ${thresholdMet ? "text-emerald-700" : "text-amber-700"}`}>Payment</p><p className="mt-3"><span className={`rounded-full px-3 py-1 text-xs font-bold ring-1 ${tonePillClass(thresholdMet ? "complete" : "action")}`}>{paymentPillLabel}</span></p></div>
      </section>

      <section className="mt-5 grid gap-4 xl:grid-cols-3">
        <article className="rounded-[1.5rem] border border-slate-200 bg-white p-5 shadow-sm"><p className="text-xs font-black uppercase tracking-wide text-slate-500">Shipping update</p><h3 className="mt-2 text-xl font-black">{shipmentArranged ? "Shipment arranged" : "Shipping date pending"}</h3><div className="mt-3 text-sm leading-6 text-slate-700">{shippingDate ? <><p>Shipping date: <span className="font-black text-slate-950">{formatDate(shippingDate)}</span></p><p>Estimated window: <span className="font-black text-slate-950">{estimatedWindow}</span></p><p className="text-xs font-semibold text-slate-500">Based on a 5-8 week estimate from the shipper shipping date.</p></> : <p>Shipping date pending from shipper.</p>}</div></article>
        <article className="rounded-[1.5rem] border border-slate-200 bg-white p-5 shadow-sm"><p className="text-xs font-black uppercase tracking-wide text-slate-500">Sale documents</p><h3 className="mt-2 text-xl font-black">{finalSaleValueConfirmed ? `${invoices.length} ${invoices.length === 1 ? "document" : "documents"} issued` : "Not available yet"}</h3><div className="mt-3 text-sm leading-6 text-slate-700">{finalSaleValueConfirmed ? <><p>Final sale value: <span className="font-black text-slate-950">{money(finalSaleValueGbp)}</span></p><p className="text-xs font-semibold text-slate-500">Authorisation ref: {order.payment_auth_id ?? "Not assigned"}</p><div className="mt-3 space-y-2">{invoices.map((invoice, index) => <div key={invoice.id} className="rounded-2xl bg-slate-50 p-3 ring-1 ring-slate-100"><p className="font-black text-slate-950">{saleDocumentLabel(invoice.invoice_type)} · {signedMoney(saleDocumentSignedAmount(invoice))}</p><p className="text-xs font-semibold text-slate-500">Issued {formatDate(invoice.sage_invoice_date ?? invoice.sage_posted_at)} · Document {index + 1}</p><a href={`/customer/orders/${orderId}/invoice-pdf/${invoice.id}`} className="mt-3 inline-flex rounded-xl bg-slate-950 px-3 py-2 text-xs font-black text-white">Download sale document</a></div>)}</div></> : <p>Your sale documents will appear once issued.</p>}</div></article>
        <article className="rounded-[1.5rem] border border-slate-200 bg-white p-5 shadow-sm"><p className="text-xs font-black uppercase tracking-wide text-slate-500">Delivery confirmation</p><h3 className="mt-2 text-xl font-black">{deliveryConfirmed ? "Received" : "Pending"}</h3><p className="mt-3 text-sm leading-6 text-slate-700">{deliveryConfirmed ? "Delivery confirmation has been received." : "We will update this page once delivery confirmation is received."}</p></article>
      </section>

      {visibleCashDueGbp > 0.01 || pendingCreditGbp > 0.01 || appliedCreditGbp > 0.01 || availableCreditGbp > 0.01 ? <details className="mt-5 rounded-[1.75rem] border border-cyan-100 bg-cyan-50/70 p-5 shadow-sm" open={visibleCashDueGbp > 0.01}><summary className="cursor-pointer list-none text-xl font-black text-cyan-950">Credit and FX details</summary><p className="mt-2 text-sm leading-6 text-slate-700">The order closes in GBP. Local figures for any remaining cash due use the latest available FX rate.</p><div className="mt-4 grid gap-3 xl:grid-cols-4">{appliedCreditGbp > 0.01 ? <div className="rounded-2xl bg-white p-4 ring-1 ring-cyan-100"><p className="text-xs font-black uppercase text-cyan-700">Account credit applied</p><p className="mt-1 text-xl font-black">{money(appliedCreditGbp)}</p></div> : null}{appliedCreditGbp > 0.01 ? <div className="rounded-2xl bg-white p-4 ring-1 ring-cyan-100"><p className="text-xs font-black uppercase text-cyan-700">Account credit local guide</p><p className="mt-1 text-xl font-black">{effectiveRate ? localAmount(appliedCreditLocal, currencyCode) : "No FX rate"}</p></div> : null}{visibleCashDueGbp > 0.01 ? <div className="rounded-2xl bg-white p-4 ring-1 ring-amber-100"><p className="text-xs font-black uppercase text-amber-700">Cash due</p><p className="mt-1 text-xl font-black">{money(visibleCashDueGbp)}</p><p className="mt-1 text-xs font-semibold text-slate-500">{effectiveRate ? localAmount(visibleCashDueLocal, currencyCode) : "No FX rate"}</p></div> : null}{availableCreditGbp > 0.01 ? <div className="rounded-2xl bg-white p-4 ring-1 ring-cyan-100"><p className="text-xs font-black uppercase text-cyan-700">Available account credit</p><p className="mt-1 text-xl font-black">{money(availableCreditGbp)}</p><p className="mt-1 text-xs font-semibold text-slate-500">{effectiveRate ? localAmount(availableCreditLocal, currencyCode) : "No FX rate"}</p></div> : null}<div className="rounded-2xl bg-white p-4 ring-1 ring-cyan-100"><p className="text-xs font-black uppercase text-cyan-700">Latest FX</p><p className="mt-1 text-xl font-black">{effectiveRate ? effectiveRate.toFixed(4) : "-"}</p><p className="mt-1 text-xs font-semibold text-slate-500">{fxLabel}</p></div></div></details> : null}

      <section className="mt-5 grid gap-4 xl:grid-cols-2">
        <details className="rounded-[1.75rem] border border-slate-200 bg-white p-5 shadow-sm"><summary className="cursor-pointer list-none text-xl font-black">Payment details</summary><div className="mt-4 grid gap-3 text-sm text-slate-700"><p>Authorisation ref: <span className="font-black text-slate-950">{order.payment_auth_id ?? "Not assigned"}</span></p><p>Accepted estimate: <span className="font-black text-slate-950">{money(acceptedEstimateGbp)}</span></p>{finalSaleValueConfirmed ? <p>Final sale value: <span className="font-black text-slate-950">{money(finalSaleValueGbp)}</span></p> : null}{confirmedPaymentGbp > 0.01 ? <p>Confirmed payment: <span className="font-black text-slate-950">{money(confirmedPaymentGbp)}</span></p> : null}{appliedCreditGbp > 0.01 ? <p>Account credit applied: <span className="font-black text-slate-950">{money(appliedCreditGbp)}</span></p> : null}{hasAmountReceived ? <p>Amount received: <span className="font-black text-slate-950">{money(amountReceivedGbp)}</span></p> : null}{visibleCashDueGbp > 0.01 ? <p>Cash due: <span className="font-black text-slate-950">{money(visibleCashDueGbp)}</span></p> : null}{pendingCreditGbp > 0.01 ? <p>Potential credit pending final review: <span className="font-black text-slate-950">{money(pendingCreditGbp)}</span></p> : null}</div></details>
        <details className="rounded-[1.75rem] border border-slate-200 bg-white p-5 shadow-sm"><summary className="cursor-pointer list-none text-xl font-black">Order evidence</summary><p className="mt-3 text-sm leading-6 text-slate-600">Original order screenshots are available. Internal procurement and warehouse tracking details are hidden.</p><div className="mt-4 flex flex-wrap gap-2">{screenshots.length === 0 ? <p className="text-sm text-slate-600">No screenshots uploaded.</p> : null}{screenshots.map((row, index) => <a key={row.id} href={row.screenshot_url} target="_blank" rel="noreferrer" className="rounded-xl bg-slate-950 px-3 py-2 text-xs font-black text-white">Open screenshot {index + 1}</a>)}</div></details>
      </section>
    </main>
  );
}
