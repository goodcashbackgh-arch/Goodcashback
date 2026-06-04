import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { supabaseAdmin } from "@/lib/supabase/admin";

type ScreenshotRow = { id: string; screenshot_url: string };
type ReviewLinkRow = { customer_review_path: string | null };
type CreditBalanceRow = { importer_id: string | null; available_credit_gbp: number | string | null };
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

function invoiceTypeLabel(value: string | null | undefined) {
  if (value === "main") return "Main invoice";
  if (value === "supplementary") return "Supplementary invoice";
  if (value === "credit_note") return "Credit note";
  return friendly(value);
}

function shortOrderTitle(orderRef: string | null | undefined, fallbackId: string) {
  const ref = orderRef || fallbackId;
  const cleaned = ref.replace(/^ORD-/i, "");
  const short = cleaned.length > 6 ? cleaned.slice(-6) : cleaned;
  return `Order ${short}`;
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

function customerStatusLabel({ rawStatus, lifecycleStatus, thresholdMet, reviewHref, shipmentArranged, deliveryConfirmed }: { rawStatus: string | null | undefined; lifecycleStatus: string | null | undefined; thresholdMet: boolean; reviewHref: string | null; shipmentArranged: boolean; deliveryConfirmed: boolean }) {
  const status = String(lifecycleStatus ?? rawStatus ?? "").toLowerCase();
  if (reviewHref) return "Ready for your review";
  if (!thresholdMet) return "Payment required";
  if (deliveryConfirmed) return "Completed";
  if (shipmentArranged) return "Shipment arranged";
  if (["pending_dva_funding", "funding_pending", "draft"].includes(status)) return "Payment received; processing";
  if (["reconciling", "partially_progressed", "invoice_reconciled_tracking_open"].includes(status)) return "Order being prepared";
  if (["ready_for_shipment", "shipment_booked"].includes(status)) return "Preparing for shipment";
  if (["shipment_dispatched", "awaiting_importer_receipt"].includes(status)) return "Shipment in progress";
  if (["completed", "archived"].includes(status)) return "Completed";
  if (["discrepancy_open", "awaiting_financial_closure"].includes(status)) return "Under review";
  return friendly(lifecycleStatus ?? rawStatus);
}

function statusTone({ statusLabel, thresholdMet, reviewHref }: { statusLabel: string; thresholdMet: boolean; reviewHref: string | null }): Tone {
  const normalised = statusLabel.toLowerCase();
  if (reviewHref) return "ready";
  if (!thresholdMet || normalised.includes("payment required")) return "action";
  if (normalised.includes("completed")) return "complete";
  if (normalised.includes("review")) return "review";
  return "muted";
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
    (supabaseAdmin as any).from("sales_invoices").select("id, amount_gbp, invoice_type, sage_invoice_id, sage_invoice_date, sage_posted_at").eq("order_id", orderId).eq("sage_status", "posted").not("sage_invoice_id", "is", null).in("invoice_type", ["main", "supplementary"]),
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
    if (a.invoice_type === "main" && b.invoice_type !== "main") return -1;
    if (b.invoice_type === "main" && a.invoice_type !== "main") return 1;
    return String(a.sage_posted_at ?? a.sage_invoice_date ?? "").localeCompare(String(b.sage_posted_at ?? b.sage_invoice_date ?? ""));
  });
  const totalInvoicedGbp = invoices.reduce((sum, row) => sum + Number(row.amount_gbp ?? 0), 0);
  const finalInvoiceIssued = invoices.length > 0;
  const funding = fundingRes.data;
  const screenshots = (screenshotsRes.data ?? []) as ScreenshotRow[];
  const state = stateRes.data;
  const reviewLink = reviewRes.data as ReviewLinkRow | null;
  const reviewHref = reviewLink?.customer_review_path ?? null;
  const thresholdMet = Boolean(funding?.threshold_met_yn);
  const currencyCode = order.importers?.countries?.currencies?.code ?? "Local";
  const rate = Number(fxRes.data?.quote_rate ?? 0);
  const markup = Number(fxRes.data?.quote_card_markup_pct ?? 0);
  const effectiveRate = rate ? rate * (1 + markup / 100) : 0;
  const fxDate = fxRes.data?.rate_date as string | undefined;
  const creditBalanceRows = (creditBalanceRes.data ?? []) as CreditBalanceRow[];
  const availableCreditGbp = creditBalanceRows.reduce((sum, row) => sum + Number(row.available_credit_gbp ?? 0), 0);
  const availableCreditLocal = effectiveRate ? availableCreditGbp * effectiveRate : 0;
  const orderGbp = Number(order.order_total_gbp_declared ?? 0);
  const totalQty = Number(order.total_qty_declared ?? 0);
  const appliedCreditGbp = Number(funding?.applied_credit_gbp ?? 0);
  const confirmedPaymentGbp = Number(funding?.confirmed_dva_funding_gbp ?? 0);
  const gapRemainingGbp = funding?.gap_remaining_gbp !== undefined && funding?.gap_remaining_gbp !== null ? Number(funding.gap_remaining_gbp) : Math.max(orderGbp - appliedCreditGbp - confirmedPaymentGbp, 0);
  const currentNetPayableGbp = Math.max(gapRemainingGbp, 0);
  const currentNetPayableLocal = effectiveRate ? currentNetPayableGbp * effectiveRate : 0;
  const appliedCreditLocal = effectiveRate ? appliedCreditGbp * effectiveRate : 0;
  const fxLabel = fxDate === today ? "today's FX" : fxDate ? `latest FX ${fxDate}` : "no FX available";
  const statusLabel = customerStatusLabel({ rawStatus: order.status, lifecycleStatus: state?.lifecycle_status, thresholdMet, reviewHref, shipmentArranged, deliveryConfirmed });
  const tone = statusTone({ statusLabel, thresholdMet, reviewHref });
  const orderTitle = shortOrderTitle(order.order_ref, orderId);
  const itemLabel = Number.isFinite(totalQty) && totalQty > 0 ? `${totalQty} ${totalQty === 1 ? "item" : "items"}` : "Goods order";
  const nextActionTitle = reviewHref ? "Review items before shipment" : !thresholdMet ? "Payment required" : deliveryConfirmed ? "Delivery confirmed" : shipmentArranged ? "Waiting for delivery confirmation" : "No action needed right now";
  const nextActionBody = reviewHref ? "Check the order before shipment and request a hold if anything should not be sent." : !thresholdMet ? "The remaining amount needs to be paid before this order can continue." : deliveryConfirmed ? "Delivery confirmation has been received." : shipmentArranged ? (estimatedWindow ? `Estimated delivery window: ${estimatedWindow}.` : "Shipping date is pending from the shipper.") : "We are processing this order. You can return here to check progress.";
  const journey = [
    { label: "Order received", done: true },
    { label: "Payment received", done: thresholdMet },
    { label: "Items confirmed", done: shipmentArranged || finalExportAccepted || finalInvoiceIssued },
    { label: "Shipment arranged", done: shipmentArranged },
    { label: "Invoice issued", done: finalInvoiceIssued },
    { label: "Delivery confirmation", done: deliveryConfirmed },
  ];
  const firstPending = journey.findIndex((step) => !step.done);

  return (
    <main className="min-h-screen bg-gradient-to-b from-sky-50 via-white to-slate-50 p-4 pb-24 text-slate-950 xl:p-6 xl:pb-10">
      <Link href="/customer" className="inline-flex items-center rounded-full bg-white/80 px-3 py-2 text-sm font-black text-sky-700 ring-1 ring-sky-100">← Customer dashboard</Link>
      <header className="mt-4 overflow-hidden rounded-[2rem] border border-sky-100 bg-white shadow-sm">
        <div className="bg-gradient-to-r from-sky-500 via-cyan-400 to-emerald-300 px-5 py-2" />
        <div className="p-5 xl:flex xl:items-start xl:justify-between xl:gap-6 xl:p-7">
          <div className="min-w-0"><p className="text-xs font-black uppercase tracking-[0.28em] text-sky-600">Customer order</p><h1 className="mt-2 text-4xl font-black tracking-tight xl:text-5xl">{orderTitle}</h1><p className="mt-2 text-sm font-semibold text-slate-600">{itemLabel} · Ref: {order.order_ref ?? orderId}</p></div>
          <div className="mt-5 xl:mt-0 xl:min-w-72"><div className={`rounded-2xl border p-4 ${toneCardClass(tone)}`}><p className="text-xs font-black uppercase tracking-wide opacity-70">Current status</p><p className="mt-1 text-2xl font-black">{statusLabel}</p><p className="mt-3 text-xs font-black uppercase tracking-wide opacity-70">Next step</p><p className="mt-1 text-sm font-black">{nextActionTitle}</p></div></div>
          {qp.success ? <p className="mt-4 rounded-xl border border-emerald-200 bg-emerald-50 p-3 text-sm font-semibold text-emerald-800 xl:col-span-2">{qp.success}</p> : null}
          {qp.error ? <p className="mt-4 rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm font-semibold text-rose-800 xl:col-span-2">{qp.error}</p> : null}
        </div>
      </header>
      <section className={`mt-5 rounded-[1.75rem] border p-5 shadow-sm ${toneCardClass(tone)}`}><div className="xl:flex xl:items-center xl:justify-between xl:gap-6"><div><p className="text-xs font-black uppercase tracking-[0.2em] opacity-70">Next step</p><h2 className="mt-2 text-2xl font-black">{nextActionTitle}</h2><p className="mt-2 text-sm leading-6 opacity-80">{nextActionBody}</p></div>{reviewHref ? <Link href={reviewHref} className="mt-4 block rounded-2xl bg-slate-950 px-5 py-3 text-center text-sm font-black text-white shadow-sm xl:mt-0">Open review</Link> : null}</div></section>
      <section className="mt-5 overflow-hidden rounded-[1.75rem] border border-slate-200 bg-white p-5 shadow-sm"><h2 className="text-xl font-black">Order journey</h2><p className="mt-1 text-sm text-slate-600">A customer-safe view of the order progress.</p><div className="mt-5 flex gap-3 overflow-x-auto pb-2">{journey.map((step, index) => <div key={step.label} className={`min-w-[9.5rem] rounded-2xl border px-4 py-3 text-sm font-black shadow-sm ring-1 ${journeyClass(step.done, index === firstPending)}`}><span className="mr-2">{step.done ? "✓" : index === firstPending ? "•" : "○"}</span>{step.label}</div>)}</div></section>
      <section className="mt-5 grid grid-cols-2 gap-3 xl:grid-cols-4"><div className="rounded-[1.5rem] border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs font-black uppercase tracking-wide text-slate-500">Order value</p><p className="mt-2 text-2xl font-black">{money(orderGbp)}</p></div><div className="rounded-[1.5rem] border border-amber-100 bg-amber-50/70 p-4 shadow-sm"><p className="text-xs font-black uppercase tracking-wide text-amber-700">Still due</p><p className="mt-2 text-2xl font-black text-amber-950">{money(currentNetPayableGbp)}</p><p className="mt-1 text-xs font-bold text-amber-800">{effectiveRate ? localAmount(currentNetPayableLocal, currencyCode) : "No FX rate"}</p></div><div className="rounded-[1.5rem] border border-cyan-100 bg-cyan-50/70 p-4 shadow-sm"><p className="text-xs font-black uppercase tracking-wide text-cyan-700">Credit used</p><p className="mt-2 text-2xl font-black text-cyan-950">{money(appliedCreditGbp)}</p></div><div className="rounded-[1.5rem] border border-emerald-100 bg-emerald-50/70 p-4 shadow-sm"><p className="text-xs font-black uppercase tracking-wide text-emerald-700">Payment</p><p className="mt-3"><span className={`rounded-full px-3 py-1 text-xs font-bold ring-1 ${tonePillClass(thresholdMet ? "complete" : "action")}`}>{thresholdMet ? "Received" : "Required"}</span></p></div></section>
      <section className="mt-5 grid gap-4 xl:grid-cols-3"><article className="rounded-[1.5rem] border border-slate-200 bg-white p-5 shadow-sm"><p className="text-xs font-black uppercase tracking-wide text-slate-500">Shipping update</p><h3 className="mt-2 text-xl font-black">{shipmentArranged ? "Shipment arranged" : "Shipping date pending"}</h3><div className="mt-3 text-sm leading-6 text-slate-700">{shippingDate ? <><p>Shipping date: <span className="font-black text-slate-950">{formatDate(shippingDate)}</span></p><p>Estimated window: <span className="font-black text-slate-950">{estimatedWindow}</span></p><p className="text-xs font-semibold text-slate-500">Based on a 5-8 week estimate from the shipper shipping date.</p></> : <p>Shipping date pending from shipper.</p>}</div></article><article className="rounded-[1.5rem] border border-slate-200 bg-white p-5 shadow-sm"><p className="text-xs font-black uppercase tracking-wide text-slate-500">Customer invoices</p><h3 className="mt-2 text-xl font-black">{finalInvoiceIssued ? `${invoices.length} ${invoices.length === 1 ? "invoice" : "invoices"} issued` : "Not available yet"}</h3><div className="mt-3 text-sm leading-6 text-slate-700">{finalInvoiceIssued ? <><p>Total invoiced: <span className="font-black text-slate-950">{money(totalInvoicedGbp)}</span></p><div className="mt-3 space-y-2">{invoices.map((invoice, index) => <div key={invoice.id} className="rounded-2xl bg-slate-50 p-3 ring-1 ring-slate-100"><p className="font-black text-slate-950">{invoiceTypeLabel(invoice.invoice_type)} · {money(invoice.amount_gbp)}</p><p className="text-xs font-semibold text-slate-500">Issued {formatDate(invoice.sage_invoice_date ?? invoice.sage_posted_at)} · Invoice {index + 1}</p><a href={`/customer/orders/${orderId}/invoices/${invoice.id}/download`} className="mt-3 inline-flex rounded-xl bg-slate-950 px-3 py-2 text-xs font-black text-white">Download invoice</a></div>)}</div></> : <p>Your customer invoices will appear once issued.</p>}</div></article><article className="rounded-[1.5rem] border border-slate-200 bg-white p-5 shadow-sm"><p className="text-xs font-black uppercase tracking-wide text-slate-500">Delivery confirmation</p><h3 className="mt-2 text-xl font-black">{deliveryConfirmed ? "Received" : "Pending"}</h3><p className="mt-3 text-sm leading-6 text-slate-700">{deliveryConfirmed ? "Delivery confirmation has been received." : "We will update this page once delivery confirmation is received."}</p></article></section>
      <details className="mt-5 rounded-[1.75rem] border border-cyan-100 bg-cyan-50/70 p-5 shadow-sm" open={currentNetPayableGbp > 0.01}><summary className="cursor-pointer list-none text-xl font-black text-cyan-950">Credit and FX details</summary><p className="mt-2 text-sm leading-6 text-slate-700">The order closes in GBP. Local figures are payment-stage guidance using the current/latest FX rate.</p><div className="mt-4 grid gap-3 xl:grid-cols-4"><div className="rounded-2xl bg-white p-4 ring-1 ring-cyan-100"><p className="text-xs font-black uppercase text-cyan-700">Applied credit</p><p className="mt-1 text-xl font-black">{money(appliedCreditGbp)}</p></div><div className="rounded-2xl bg-white p-4 ring-1 ring-cyan-100"><p className="text-xs font-black uppercase text-cyan-700">Applied credit local</p><p className="mt-1 text-xl font-black">{effectiveRate ? localAmount(appliedCreditLocal, currencyCode) : "No FX rate"}</p></div><div className="rounded-2xl bg-white p-4 ring-1 ring-cyan-100"><p className="text-xs font-black uppercase text-cyan-700">Available credit</p><p className="mt-1 text-xl font-black">{money(availableCreditGbp)}</p><p className="mt-1 text-xs font-semibold text-slate-500">{effectiveRate ? localAmount(availableCreditLocal, currencyCode) : "No FX rate"}</p></div><div className="rounded-2xl bg-white p-4 ring-1 ring-cyan-100"><p className="text-xs font-black uppercase text-cyan-700">FX used</p><p className="mt-1 text-xl font-black">{effectiveRate ? effectiveRate.toFixed(4) : "-"}</p><p className="mt-1 text-xs font-semibold text-slate-500">{fxLabel}</p></div></div></details>
      <section className="mt-5 grid gap-4 xl:grid-cols-2"><details className="rounded-[1.75rem] border border-slate-200 bg-white p-5 shadow-sm"><summary className="cursor-pointer list-none text-xl font-black">Payment details</summary><div className="mt-4 grid gap-3 text-sm text-slate-700"><p>Required amount: <span className="font-black text-slate-950">{money(funding?.purchase_funding_threshold_gbp ?? order.order_total_gbp_declared)}</span></p><p>Confirmed payment: <span className="font-black text-slate-950">{money(confirmedPaymentGbp)}</span></p><p>Applied credit: <span className="font-black text-slate-950">{money(appliedCreditGbp)}</span></p><p>Amount still due: <span className="font-black text-slate-950">{money(currentNetPayableGbp)}</span></p></div></details><details className="rounded-[1.75rem] border border-slate-200 bg-white p-5 shadow-sm"><summary className="cursor-pointer list-none text-xl font-black">Order evidence</summary><p className="mt-3 text-sm leading-6 text-slate-600">Original order screenshots are available. Internal procurement and warehouse tracking details are hidden.</p><div className="mt-4 flex flex-wrap gap-2">{screenshots.length === 0 ? <p className="text-sm text-slate-600">No screenshots uploaded.</p> : null}{screenshots.map((row, index) => <a key={row.id} href={row.screenshot_url} target="_blank" rel="noreferrer" className="rounded-xl bg-slate-950 px-3 py-2 text-xs font-black text-white">Open screenshot {index + 1}</a>)}</div></details></section>
    </main>
  );
}
