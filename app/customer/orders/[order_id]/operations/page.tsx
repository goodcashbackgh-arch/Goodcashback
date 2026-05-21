import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type ScreenshotRow = { id: string; screenshot_url: string };
type TrackingRow = { id: string; tracking_ref: string; tracking_date: string | null; is_final_delivery_yn: boolean | null; tracking_screenshot_url: string | null; couriers: { name: string | null } | null };
type InvoiceRow = { id: string; invoice_ref: string; review_status: string | null; uploaded_at: string | null };
type InvoiceLineRow = { eligible_for_invoice_yn: string | null; supplier_invoices: { order_id: string }[] | { order_id: string } | null };
type AdjustmentRow = { adjustment_type: string | null; amount_gbp: number | string | null; approval_status: string | null; requires_supervisor_approval: boolean | null };
type SalesInvoiceRow = { id: string; invoice_type: string | null; amount_gbp: number | string | null; sage_status: string | null; sage_invoice_id: string | null; created_at: string | null };

function money(value: unknown) {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP", minimumFractionDigits: 2 }).format(Number(value ?? 0));
}

function localAmount(value: unknown, code = "Local") {
  return `${code} ${new Intl.NumberFormat("en-GB", { minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(Number(value ?? 0))}`;
}

function friendly(value: string | null | undefined) {
  if (!value) return "—";
  return value.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase());
}

function yesNo(value: boolean) {
  return value ? "Yes" : "No";
}

function chip(ok: boolean) {
  return ok ? "rounded-full bg-emerald-100 px-2 py-1 text-xs font-semibold text-emerald-800" : "rounded-full bg-amber-100 px-2 py-1 text-xs font-semibold text-amber-800";
}

function isProgressed(value: string | null | undefined) {
  return ["y", "yes", "true", "1"].includes((value ?? "").trim().toLowerCase());
}

export default async function CustomerOrderOperationsPage({ params, searchParams }: { params: Promise<{ order_id: string }>; searchParams?: Promise<{ success?: string; error?: string }> }) {
  const { order_id: orderId } = await params;
  const qp = searchParams ? await searchParams : {};
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: operator } = await supabase.from("operators").select("id, full_name").eq("auth_user_id", user.id).eq("active", true).maybeSingle();
  if (!operator) redirect("/auth/check");

  const { data: order } = await supabase
    .from("orders")
    .select("*, importers(id, company_name, trading_name, countries(currencies(code))), retailers(name)")
    .eq("id", orderId)
    .maybeSingle();
  if (!order) redirect("/customer");

  const { data: access } = await supabase
    .from("operator_importers")
    .select("id")
    .eq("operator_id", operator.id)
    .eq("importer_id", order.importer_id)
    .is("revoked_at", null)
    .limit(1)
    .maybeSingle();
  if (!access) redirect("/customer");

  const [{ data: funding }, { data: screenshots }, { data: tracking }, { data: invoices }, { data: invoiceLines }, { data: adjustments }, { data: salesInvoices }, { data: state }] = await Promise.all([
    supabase.from("order_funding_position_vw").select("*").eq("order_id", orderId).maybeSingle(),
    supabase.from("order_screenshots").select("id, screenshot_url").eq("order_id", orderId).order("display_order"),
    supabase.from("order_tracking_submissions").select("id, tracking_ref, tracking_date, is_final_delivery_yn, tracking_screenshot_url, couriers(name)").eq("order_id", orderId).order("submitted_at", { ascending: false }),
    supabase.from("supplier_invoices").select("id, invoice_ref, review_status, uploaded_at").eq("order_id", orderId).order("uploaded_at", { ascending: false }),
    supabase.from("supplier_invoice_lines").select("eligible_for_invoice_yn, supplier_invoices!inner(order_id)").eq("supplier_invoices.order_id", orderId),
    supabase.from("order_value_adjustments").select("adjustment_type, amount_gbp, approval_status, requires_supervisor_approval").eq("order_id", orderId),
    supabase.from("sales_invoices").select("id, invoice_type, amount_gbp, sage_status, sage_invoice_id, created_at").eq("order_id", orderId).order("created_at", { ascending: false }),
    supabase.from("order_state_vw").select("lifecycle_status").eq("id", orderId).maybeSingle(),
  ]);

  const trackingRows = (tracking ?? []) as TrackingRow[];
  const invoiceRows = (invoices ?? []) as InvoiceRow[];
  const lineRows = (invoiceLines ?? []) as InvoiceLineRow[];
  const adjustmentRows = (adjustments ?? []) as AdjustmentRow[];
  const salesRows = (salesInvoices ?? []) as SalesInvoiceRow[];

  const thresholdMet = Boolean(funding?.threshold_met_yn);
  const finalDelivery = trackingRows.some((row) => row.is_final_delivery_yn);
  const invoiceUploaded = invoiceRows.length > 0;
  const allInvoiceLinesProgressed = lineRows.length > 0 && lineRows.every((line) => isProgressed(line.eligible_for_invoice_yn));
  const pendingAdjustments = adjustmentRows.filter((row) => row.approval_status === "pending_supervisor").length;
  const finalInvoiceExists = salesRows.some((row) => row.invoice_type === "main" && ["draft", "posted"].includes(row.sage_status ?? ""));
  const finalInvoiceReady = thresholdMet && finalDelivery && invoiceUploaded && allInvoiceLinesProgressed && pendingAdjustments === 0;
  const currencyCode = order.importers?.countries?.currencies?.code ?? "Local";

  return (
    <main className="min-h-screen bg-slate-50 p-6 text-slate-950">
      <Link href="/customer" className="font-semibold text-sky-700">← Customer dashboard</Link>
      <header className="mt-4 rounded-2xl border bg-white p-5">
        <p className="text-xs font-bold uppercase tracking-[0.2em] text-sky-600">Customer order</p>
        <h1 className="mt-1 text-3xl font-semibold">{order.order_ref ?? orderId}</h1>
        <p className="mt-1 text-sm text-slate-600">{order.retailers?.name ?? "Retailer"} · {order.importers?.trading_name ?? order.importers?.company_name ?? "Customer"}</p>
        {qp.success ? <p className="mt-3 rounded border border-emerald-300 bg-emerald-50 p-3 text-sm text-emerald-900">{qp.success}</p> : null}
        {qp.error ? <p className="mt-3 rounded border border-rose-300 bg-rose-50 p-3 text-sm text-rose-900">{qp.error}</p> : null}
      </header>

      <section className="mt-6 grid gap-4 md:grid-cols-5">
        <div className="rounded-2xl border bg-white p-4"><div className="text-sm text-slate-500">Status</div><div className="mt-2 font-semibold">{friendly(state?.lifecycle_status ?? order.status)}</div></div>
        <div className="rounded-2xl border bg-white p-4"><div className="text-sm text-slate-500">Funding</div><div className="mt-2 font-semibold">{thresholdMet ? "Funded" : friendly(funding?.status)}</div></div>
        <div className="rounded-2xl border bg-white p-4"><div className="text-sm text-slate-500">Goods GBP</div><div className="mt-2 font-semibold">{money(order.order_total_gbp_declared)}</div></div>
        <div className="rounded-2xl border bg-white p-4"><div className="text-sm text-slate-500">Pro forma local</div><div className="mt-2 font-semibold">{localAmount(order.quote_total_ghs, currencyCode)}</div></div>
        <div className="rounded-2xl border bg-white p-4"><div className="text-sm text-slate-500">Auth ref</div><div className="mt-2 break-words font-semibold">{order.payment_auth_id ?? "—"}</div></div>
      </section>

      <section className="mt-6 rounded-2xl border bg-white p-5">
        <h2 className="text-lg font-semibold">Final invoice readiness checks</h2>
        <p className="mt-1 text-sm text-slate-600">These are the checks before the final customer invoice can be released.</p>
        <div className="mt-4 grid gap-3 md:grid-cols-3">
          <div><span className={chip(thresholdMet)}>Funding threshold reached: {yesNo(thresholdMet)}</span></div>
          <div><span className={chip(invoiceUploaded)}>Retailer invoice uploaded: {yesNo(invoiceUploaded)}</span></div>
          <div><span className={chip(allInvoiceLinesProgressed)}>Invoice reconciliation complete: {yesNo(allInvoiceLinesProgressed)}</span></div>
          <div><span className={chip(finalDelivery)}>Final delivery evidence: {yesNo(finalDelivery)}</span></div>
          <div><span className={chip(pendingAdjustments === 0)}>Adjustment approvals clear: {yesNo(pendingAdjustments === 0)}</span></div>
          <div><span className={chip(finalInvoiceReady || finalInvoiceExists)}>Final invoice ready/drafted: {yesNo(finalInvoiceReady || finalInvoiceExists)}</span></div>
        </div>
        <p className="mt-4 rounded-xl bg-slate-50 p-3 text-sm text-slate-700">{finalInvoiceExists ? "Final customer invoice has been drafted or posted." : finalInvoiceReady ? "Ready for staff to create the final customer invoice draft." : "Not ready yet. The open checks above explain why."}</p>
      </section>

      <section className="mt-6 grid gap-4 lg:grid-cols-2">
        <div className="rounded-2xl border bg-white p-5">
          <h2 className="text-lg font-semibold">Funding details</h2>
          <div className="mt-3 grid gap-2 text-sm md:grid-cols-2">
            <p>Threshold: <span className="font-semibold">{money(funding?.purchase_funding_threshold_gbp ?? order.order_total_gbp_declared)}</span></p>
            <p>Confirmed DVA: <span className="font-semibold">{money(funding?.confirmed_dva_funding_gbp)}</span></p>
            <p>Applied credit: <span className="font-semibold">{money(funding?.applied_credit_gbp)}</span></p>
            <p>Gap: <span className="font-semibold">{money(funding?.gap_remaining_gbp)}</span></p>
          </div>
        </div>
        <div className="rounded-2xl border bg-white p-5">
          <h2 className="text-lg font-semibold">Final invoice records</h2>
          {salesRows.length === 0 ? <p className="mt-3 text-sm text-slate-600">No customer invoice draft yet.</p> : salesRows.map((invoice) => <div key={invoice.id} className="mt-3 rounded bg-slate-50 p-3 text-sm"><p className="font-semibold">{friendly(invoice.invoice_type)} · {money(invoice.amount_gbp)}</p><p className="text-slate-600">Sage: {friendly(invoice.sage_status)} · {invoice.sage_invoice_id ?? "not posted"}</p></div>)}
        </div>
      </section>

      <section className="mt-6 rounded-2xl border bg-white p-5">
        <h2 className="text-lg font-semibold">Order evidence and activity</h2>
        <div className="mt-4 grid gap-4 lg:grid-cols-3">
          <div><h3 className="font-semibold">Screenshots</h3><p className="text-sm text-slate-600">{(screenshots ?? []).length} uploaded</p><div className="mt-2 flex flex-wrap gap-2">{((screenshots ?? []) as ScreenshotRow[]).map((row) => <a key={row.id} href={row.screenshot_url} target="_blank" className="text-sm font-semibold text-sky-700 underline">Open</a>)}</div></div>
          <div><h3 className="font-semibold">Tracking</h3><div className="mt-2 space-y-2 text-sm">{trackingRows.length === 0 ? "No tracking yet." : trackingRows.map((row) => <p key={row.id}>{row.couriers?.name ?? "Courier"} · {row.tracking_ref} · {row.tracking_date ?? "—"}{row.is_final_delivery_yn ? " · Final" : ""}</p>)}</div></div>
          <div><h3 className="font-semibold">Retailer invoices</h3><div className="mt-2 space-y-2 text-sm">{invoiceRows.length === 0 ? "No invoice yet." : invoiceRows.map((row) => <p key={row.id}>{row.invoice_ref} · {friendly(row.review_status)}</p>)}</div></div>
        </div>
      </section>
    </main>
  );
}
