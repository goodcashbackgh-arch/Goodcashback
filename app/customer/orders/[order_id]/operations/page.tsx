import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type ReviewLinkRow = { customer_review_path: string | null };
type ScreenshotRow = { id: string; screenshot_url: string };

function money(value: unknown) {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP", minimumFractionDigits: 2 }).format(Number(value ?? 0));
}

function title(orderRef: string | null | undefined, fallbackId: string) {
  const ref = orderRef || fallbackId;
  const cleaned = ref.replace(/^ORD-/i, "");
  return `Order ${cleaned.length > 6 ? cleaned.slice(-6) : cleaned}`;
}

export default async function CustomerOrderOperationsPage({ params }: { params: Promise<{ order_id: string }> }) {
  const { order_id: orderId } = await params;
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: operator } = await supabase.from("operators").select("id").eq("auth_user_id", user.id).eq("active", true).maybeSingle();
  if (!operator) redirect("/auth/check");

  const { data: order } = await supabase.from("orders").select("id, order_ref, importer_id, order_total_gbp_declared, total_qty_declared, created_at").eq("id", orderId).maybeSingle();
  if (!order) redirect("/customer");

  const { data: access } = await supabase.from("operator_importers").select("id").eq("operator_id", operator.id).eq("importer_id", order.importer_id).is("revoked_at", null).limit(1).maybeSingle();
  if (!access) redirect("/customer");

  const [fundingRes, reviewRes, screenshotsRes, trackingRes, invoiceRes] = await Promise.all([
    supabase.from("order_funding_position_vw").select("*").eq("order_id", orderId).maybeSingle(),
    (supabase as any).rpc("customer_active_order_review_link_v1", { p_order_id: orderId }).maybeSingle(),
    supabase.from("order_screenshots").select("id, screenshot_url").eq("order_id", orderId).order("display_order"),
    supabase.from("order_tracking_submissions").select("id, tracking_ref, is_final_delivery_yn").eq("order_id", orderId).order("submitted_at", { ascending: false }),
    (supabase as any).from("sales_invoices").select("id, amount_gbp, invoice_type, sage_invoice_id").eq("order_id", orderId).eq("sage_status", "posted").not("sage_invoice_id", "is", null).in("invoice_type", ["main", "supplementary"]),
  ]);

  const funding = fundingRes.data;
  const reviewHref = ((reviewRes.data as ReviewLinkRow | null)?.customer_review_path ?? null);
  const screenshots = (screenshotsRes.data ?? []) as ScreenshotRow[];
  const trackingRows = (trackingRes.data ?? []) as Array<{ id: string; tracking_ref?: string | null; is_final_delivery_yn?: boolean | null }>;
  const invoices = (invoiceRes.data ?? []) as Array<{ id: string; amount_gbp?: number | string | null; invoice_type?: string | null; sage_invoice_id?: string | null }>;
  const finalInvoice = invoices.find((row) => row.invoice_type === "main") ?? invoices[0] ?? null;
  const orderGbp = Number(order.order_total_gbp_declared ?? 0);
  const confirmedPaymentGbp = Number(funding?.confirmed_dva_funding_gbp ?? 0);
  const appliedCreditGbp = Number(funding?.applied_credit_gbp ?? 0);
  const dueGbp = Math.max(Number(funding?.gap_remaining_gbp ?? (orderGbp - confirmedPaymentGbp - appliedCreditGbp)), 0);
  const thresholdMet = Boolean(funding?.threshold_met_yn);
  const deliveryConfirmed = trackingRows.some((row) => Boolean(row.is_final_delivery_yn));
  const finalInvoiceIssued = Boolean(finalInvoice?.sage_invoice_id);
  const status = reviewHref ? "Ready for your review" : !thresholdMet ? "Payment required" : deliveryConfirmed ? "Delivered" : finalInvoiceIssued || trackingRows.length > 0 ? "Shipment arranged" : "Order in progress";
  const nextStep = reviewHref ? "Review items before shipment" : !thresholdMet ? "Payment required" : deliveryConfirmed ? "Delivery confirmed" : finalInvoiceIssued ? "Waiting for delivery confirmation" : trackingRows.length > 0 ? "Shipment arranged" : "No action needed right now";
  const card = "rounded-[1.75rem] border border-slate-200 bg-white p-5 shadow-sm";
  const soft = "rounded-2xl bg-slate-50 p-4 font-bold";

  return (
    <main className="min-h-screen bg-gradient-to-b from-sky-50 via-white to-slate-50 p-4 pb-24 text-slate-950 xl:p-6 xl:pb-10">
      <Link href="/customer" className="inline-flex items-center rounded-full bg-white/80 px-3 py-2 text-sm font-black text-sky-700 ring-1 ring-sky-100">← Customer dashboard</Link>

      <header className="mt-4 overflow-hidden rounded-[2rem] border border-sky-100 bg-white shadow-sm">
        <div className="bg-gradient-to-r from-sky-500 via-cyan-400 to-emerald-300 px-5 py-2" />
        <div className="p-5 xl:flex xl:items-start xl:justify-between xl:gap-6 xl:p-7">
          <div className="min-w-0">
            <p className="text-xs font-black uppercase tracking-[0.28em] text-sky-600">Customer order</p>
            <h1 className="mt-2 text-4xl font-black tracking-tight xl:text-5xl">{title(order.order_ref, orderId)}</h1>
            <p className="mt-2 text-sm font-semibold text-slate-600">{Number(order.total_qty_declared ?? 0) || "Goods"} items · Ref: {order.order_ref ?? orderId}</p>
          </div>
          <div className="mt-5 xl:mt-0 xl:min-w-72">
            <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
              <p className="text-xs font-black uppercase tracking-wide text-slate-500">Current status</p>
              <p className="mt-1 text-2xl font-black">{status}</p>
            </div>
          </div>
        </div>
      </header>

      <section className={card + " mt-5"}>
        <p className="text-xs font-black uppercase tracking-[0.2em] text-slate-500">Next step</p>
        <h2 className="mt-2 text-2xl font-black">{nextStep}</h2>
        {reviewHref ? <Link href={reviewHref} className="mt-4 inline-flex rounded-2xl bg-slate-950 px-5 py-3 text-sm font-black text-white">Open review</Link> : null}
      </section>

      <section className={card + " mt-5"}>
        <h2 className="text-xl font-black">Progress</h2>
        <p className="mt-1 text-sm text-slate-600">A simple view of what has happened and what is still pending.</p>
        <div className="mt-4 grid gap-3 xl:grid-cols-2">
          <div className={soft}>✓ Order received</div>
          <div className={soft}>{thresholdMet ? "✓" : "○"} Payment received</div>
          <div className={soft}>{trackingRows.length > 0 || finalInvoiceIssued ? "✓" : "○"} Items confirmed</div>
          <div className={soft}>{trackingRows.length > 0 ? "✓" : "○"} Tracking added</div>
          <div className={soft}>{trackingRows.length > 0 || finalInvoiceIssued ? "✓" : "○"} Shipment arranged</div>
          <div className={soft}>{finalInvoiceIssued ? "✓" : "○"} Final invoice issued</div>
          <div className={soft}>{deliveryConfirmed ? "✓" : "○"} Delivery confirmation</div>
        </div>
      </section>

      <section className="mt-5 grid gap-4 xl:grid-cols-2">
        <section className={card}>
          <h2 className="text-xl font-black">Tracking</h2>
          {trackingRows.length === 0 ? <p className="mt-3 rounded-xl bg-slate-50 p-4 text-sm text-slate-600">Tracking is not available yet.</p> : null}
          {trackingRows.map((row) => <p key={row.id} className="mt-3 rounded-xl bg-slate-50 p-3 text-sm font-semibold">{row.tracking_ref ?? "Tracking update"}</p>)}
        </section>

        <section className={card}>
          <h2 className="text-xl font-black">Final invoice</h2>
          {finalInvoiceIssued ? <div className="mt-3 rounded-xl bg-emerald-50 p-4 text-sm font-semibold text-emerald-900"><p>Issued · {money(finalInvoice?.amount_gbp)}</p><span className="mt-3 inline-flex rounded-xl bg-slate-200 px-4 py-2 text-sm font-black text-slate-700">Invoice download being restored</span></div> : <p className="mt-3 rounded-xl bg-slate-50 p-4 text-sm text-slate-600">Your final invoice is not available yet.</p>}
        </section>
      </section>

      <section className="mt-5 grid gap-4 xl:grid-cols-2">
        <section className={card}>
          <h2 className="text-xl font-black">Delivery status</h2>
          <p className={`mt-3 rounded-xl border p-4 text-sm font-semibold ${deliveryConfirmed ? "border-emerald-200 bg-emerald-50 text-emerald-900" : "border-amber-200 bg-amber-50 text-amber-900"}`}>{deliveryConfirmed ? "Delivery confirmation has been received." : "Delivery confirmation is pending."}</p>
        </section>

        <section className={card}>
          <h2 className="text-xl font-black">Payment summary</h2>
          <div className="mt-4 grid gap-3 text-sm text-slate-700">
            <p>Order value: <span className="font-black text-slate-950">{money(orderGbp)}</span></p>
            <p>Confirmed payment: <span className="font-black text-slate-950">{money(confirmedPaymentGbp)}</span></p>
            <p>Applied credit: <span className="font-black text-slate-950">{money(appliedCreditGbp)}</span></p>
            <p>Amount still due: <span className="font-black text-slate-950">{money(dueGbp)}</span></p>
          </div>
        </section>
      </section>

      <section className={card + " mt-5"}>
        <h2 className="text-xl font-black">Documents</h2>
        <p className="mt-3 text-sm leading-6 text-slate-600">Your order evidence and key documents are available here.</p>
        <div className="mt-4 flex flex-wrap gap-2">
          {screenshots.length === 0 ? <p className="text-sm text-slate-600">No order screenshots uploaded.</p> : null}
          {screenshots.map((row, index) => <a key={row.id} href={row.screenshot_url} target="_blank" rel="noreferrer" className="rounded-xl bg-slate-950 px-3 py-2 text-xs font-black text-white">Open order evidence {index + 1}</a>)}
        </div>
      </section>

      <details className="mt-5 rounded-[1.75rem] border border-cyan-100 bg-cyan-50/70 p-5 shadow-sm" open={dueGbp > 0.01}>
        <summary className="cursor-pointer list-none text-xl font-black text-cyan-950">Payment calculation</summary>
        <p className="mt-2 text-sm leading-6 text-slate-700">The order closes in GBP. Local figures are payment-stage guidance using the current/latest FX rate.</p>
        <div className="mt-4 grid gap-3 xl:grid-cols-4">
          <div className="rounded-2xl bg-white p-4 ring-1 ring-cyan-100"><p className="text-xs font-black uppercase text-cyan-700">Order value</p><p className="mt-1 text-xl font-black">{money(orderGbp)}</p></div>
          <div className="rounded-2xl bg-white p-4 ring-1 ring-cyan-100"><p className="text-xs font-black uppercase text-cyan-700">Confirmed</p><p className="mt-1 text-xl font-black">{money(confirmedPaymentGbp)}</p></div>
          <div className="rounded-2xl bg-white p-4 ring-1 ring-cyan-100"><p className="text-xs font-black uppercase text-cyan-700">Applied credit</p><p className="mt-1 text-xl font-black">{money(appliedCreditGbp)}</p></div>
          <div className="rounded-2xl bg-white p-4 ring-1 ring-cyan-100"><p className="text-xs font-black uppercase text-cyan-700">Due</p><p className="mt-1 text-xl font-black">{money(dueGbp)}</p></div>
        </div>
      </details>
    </main>
  );
}
