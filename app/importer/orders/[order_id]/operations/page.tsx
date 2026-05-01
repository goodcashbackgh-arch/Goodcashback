import Link from "next/link";
import { createClient } from "@/utils/supabase/server";
import { addTrackingSubmissionAction, flagSupplierInvoiceForReviewAction, submitInvoiceEvidenceAction } from "./actions";

type ScreenshotRow = { id: string; screenshot_url: string };
type TrackingRow = { id: string; tracking_ref: string; is_final_delivery_yn: boolean | null; couriers: { name: string } | null };
type InvoiceRow = { id: string; invoice_ref: string; review_status: string | null; review_notes: string | null; uploaded_at: string | null };
type InvoiceLineTotalRow = { supplier_invoice_id: string; qty: number; amount_inc_vat_gbp: number };
type InvoiceSummaryRow = { supplier_invoice_id: string; invoice_total_gbp: number };
type AdjustmentRow = { id: string; supplier_invoice_id: string | null; adjustment_type: string; amount_gbp: number; approval_status: string; requires_supervisor_approval: boolean | null };
type ReviewFlagRow = { id: string; supplier_invoice_id: string; flag_type: string; message: string; status: string; created_at: string };

function money(value: number | string | null | undefined, currency = "GBP") {
  const n = Number(value ?? 0);
  return new Intl.NumberFormat("en-GB", {
    style: "currency",
    currency,
    minimumFractionDigits: 2,
  }).format(n);
}

function localAmount(value: number | string | null | undefined, currencyCode?: string | null) {
  const n = Number(value ?? 0);
  return `${currencyCode ?? "Local"} ${new Intl.NumberFormat("en-GB", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  }).format(n)}`;
}

function adjustmentLabel(type: string) {
  if (type === "retailer_delivery") return "Retailer delivery";
  if (type === "retailer_discount") return "Retailer discount";
  return type;
}

function flagLabel(type: string) {
  if (type === "invoice_total_mismatch") return "Invoice total mismatch";
  if (type === "ocr_unclear") return "OCR unclear";
  if (type === "wrong_invoice") return "Wrong invoice";
  if (type === "delivery_discount_query") return "Delivery/discount query";
  if (type === "manual_line_needed") return "Manual line needed";
  return "Other";
}

function invoiceStatusLabel(status: string | null | undefined) {
  if (status === "rejected_resubmit_required") return "Rejected — resubmission required";
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

export default async function OrderOperationsPage({params,searchParams}:{params: Promise<{order_id:string}>, searchParams: Promise<{success?:string;order_ref?:string;auth_ref?:string;error?:string}>}) {
  const {order_id:orderId} = await params;
  const qp = await searchParams;
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return <main className="p-6">Please sign in.</main>;
  const { data: operator } = await supabase.from("operators").select("id").eq("auth_user_id", user.id).eq("active", true).maybeSingle();
  if (!operator) return <main className="p-6">Operator account required.</main>;

  const [{data:order},{data:screenshots},{data:tracking},{data:funding},{data:invoices},{data:couriers},{data:adjustments},{data:invoiceLines},{data:invoiceSummaries},{data:reviewFlags}] = await Promise.all([
    supabase.from("orders").select("*, importers(countries(currencies(code))), retailers(name)").eq("id",orderId).maybeSingle(),
    supabase.from("order_screenshots").select("*").eq("order_id",orderId).order("display_order"),
    supabase.from("order_tracking_submissions").select("*, couriers(name)").eq("order_id",orderId).order("submitted_at",{ascending:false}),
    supabase.from("order_funding_position_vw").select("*").eq("order_id",orderId).maybeSingle(),
    supabase.from("supplier_invoices").select("id, invoice_ref, review_status, review_notes, uploaded_at").eq("order_id",orderId).order("uploaded_at", { ascending: false }),
    supabase.from("couriers").select("id, name").order("name"),
    supabase.from("order_value_adjustments").select("id, supplier_invoice_id, adjustment_type, amount_gbp, approval_status, requires_supervisor_approval").eq("order_id",orderId).order("created_at", { ascending: false }),
    supabase.from("supplier_invoice_lines").select("supplier_invoice_id, qty, amount_inc_vat_gbp, supplier_invoices!inner(order_id)").eq("supplier_invoices.order_id", orderId),
    supabase.from("supplier_invoice_financial_summary").select("supplier_invoice_id, invoice_total_gbp, supplier_invoices!inner(order_id)").eq("supplier_invoices.order_id", orderId),
    supabase.from("supplier_invoice_review_flags").select("id, supplier_invoice_id, flag_type, message, status, created_at").eq("order_id", orderId).order("created_at", { ascending: false }),
  ]);

  if (!order) return <main className="p-6">Order not found.</main>;
  const finalTrackingExists = ((tracking ?? []) as TrackingRow[]).some((t) => t.is_final_delivery_yn);
  const currencyCode = order.importers?.countries?.currencies?.code ?? null;
  const orderRetailerName = order.retailers?.name ?? "—";
  const adjustmentRows = (adjustments ?? []) as AdjustmentRow[];
  const invoiceRows = (invoices ?? []) as InvoiceRow[];
  const liveInvoiceIds = new Set(invoiceRows.filter((invoice) => invoice.review_status !== "rejected_resubmit_required" && invoice.review_status !== "superseded" && invoice.review_status !== "duplicate_blocked").map((invoice) => invoice.id));
  const activeAdjustmentRows = adjustmentRows.filter((a) => a.approval_status !== "rejected" && (!a.supplier_invoice_id || liveInvoiceIds.has(a.supplier_invoice_id)));
  const rejectedInvoices = invoiceRows.filter((invoice) => invoice.review_status === "rejected_resubmit_required");
  const orderHasResubmissionRequired = rejectedInvoices.length > 0 && !invoiceRows.some((invoice) => {
    if (invoice.review_status === "rejected_resubmit_required") return false;
    const latestRejectedAt = rejectedInvoices[0]?.uploaded_at ? new Date(rejectedInvoices[0].uploaded_at).getTime() : 0;
    const uploadedAt = invoice.uploaded_at ? new Date(invoice.uploaded_at).getTime() : 0;
    return uploadedAt > latestRejectedAt;
  });
  const reviewFlagRows = (reviewFlags ?? []) as ReviewFlagRow[];
  const orderGoodsBaseline = Number(order.order_total_gbp_declared ?? 0);

  const lineTotalsByInvoice = new Map<string, { qty: number; amount: number }>();
  for (const line of (invoiceLines ?? []) as InvoiceLineTotalRow[]) {
    const current = lineTotalsByInvoice.get(line.supplier_invoice_id) ?? { qty: 0, amount: 0 };
    current.qty += Number(line.qty ?? 0);
    current.amount += Number(line.amount_inc_vat_gbp ?? 0);
    lineTotalsByInvoice.set(line.supplier_invoice_id, current);
  }

  const summaryByInvoice = new Map<string, InvoiceSummaryRow>();
  for (const summary of (invoiceSummaries ?? []) as InvoiceSummaryRow[]) {
    summaryByInvoice.set(summary.supplier_invoice_id, summary);
  }

  const reviewFlagsByInvoice = new Map<string, ReviewFlagRow[]>();
  for (const flag of reviewFlagRows) {
    const current = reviewFlagsByInvoice.get(flag.supplier_invoice_id) ?? [];
    current.push(flag);
    reviewFlagsByInvoice.set(flag.supplier_invoice_id, current);
  }

  return <main className="p-6 space-y-6">
    <Link href="/importer" className="text-sky-600">← Back</Link>
    <h1 className="text-2xl font-semibold">Order operations: {order.order_ref ?? orderId}</h1>

    {qp.error && <div className="rounded border border-red-300 bg-red-50 p-3 text-sm text-red-700">{qp.error}</div>}
    {qp.success && <div className="rounded border border-emerald-300 bg-emerald-50 p-3 text-sm">
      <p className="font-semibold">{qp.success}</p>
      <p>This estimate is based on the goods value you submitted. Shipping is not included at this stage.</p>
      <div className="mt-2 grid gap-1 md:grid-cols-4">
        <p><span className="font-medium">Order ref:</span> {order.order_ref ?? qp.order_ref ?? "—"}</p>
        <p><span className="font-medium">Order ID:</span> {order.id}</p>
        <p><span className="font-medium">Auth ref:</span> {order.payment_auth_id ?? qp.auth_ref ?? "—"}</p>
        <p><span className="font-medium">Retailer:</span> {orderRetailerName}</p>
      </div>
    </div>}

    {orderHasResubmissionRequired ? <section className="rounded border border-rose-300 bg-rose-50 p-4 text-sm text-rose-900">
      <h2 className="font-semibold">Invoice rejected — upload corrected invoice</h2>
      <p className="mt-1">Supervisor has rejected the latest invoice evidence for this order. Upload the correct invoice below using the normal invoice upload form.</p>
      {rejectedInvoices[0]?.review_notes ? <p className="mt-2"><span className="font-semibold">Supervisor note:</span> {rejectedInvoices[0].review_notes}</p> : null}
    </section> : null}

    <section className="rounded border p-4">
      <h2 className="font-semibold">Summary</h2>
      <div className="mt-2 grid gap-2 md:grid-cols-5 text-sm">
        <div><div className="text-slate-500">Retailer</div><div className="font-medium">{orderRetailerName}</div></div>
        <div><div className="text-slate-500">Quantity</div><div className="font-medium">{order.total_qty_declared}</div></div>
        <div><div className="text-slate-500">Goods amount</div><div className="font-medium">{money(order.order_total_gbp_declared)}</div></div>
        <div><div className="text-slate-500">Local quote amount</div><div className="font-medium">{localAmount(order.quote_total_ghs, currencyCode)}</div></div>
        <div><div className="text-slate-500">Status</div><div className="font-medium">{order.status}</div></div>
      </div>
    </section>

    <section><h2 className="font-semibold">Funding</h2><pre className="text-xs bg-slate-100 p-2 rounded overflow-x-auto">{JSON.stringify(funding ?? {}, null, 2)}</pre></section>

    <section>
      <h2 className="font-semibold">Screenshots</h2>
      <div className="flex gap-3 flex-wrap">
        {((screenshots??[]) as ScreenshotRow[]).map((s)=> (
          <a key={s.id} href={s.screenshot_url} target="_blank" className="block rounded border bg-white p-1">
            <img src={s.screenshot_url} alt="Screenshot" style={{ width: 160, height: 120, objectFit: "contain" }} />
          </a>
        ))}
      </div>
    </section>

    <section id="tracking" className="space-y-2 rounded border p-4">
      <h2 className="font-semibold">Tracking</h2>
      {finalTrackingExists ? <p className="text-sm text-amber-700">Final delivery has already been marked. Add more tracking only if this was done in error.</p> : null}
      <form action={addTrackingSubmissionAction} className="grid gap-2 md:grid-cols-2">
        <input type="hidden" name="order_id" value={orderId} />
        <select name="courier_id" required className="border p-2">
          <option value="">Courier</option>
          {(couriers??[]).map(c=> <option key={c.id} value={c.id}>{c.name}</option>)}
        </select>
        <input name="tracking_ref" required className="border p-2" placeholder="Tracking ref"/>
        <input name="tracking_date" type="date" required className="border p-2"/>
        <input name="tracking_screenshot_url" className="border p-2" placeholder="Tracking URL / evidence link"/>
        <input name="note" className="border p-2" placeholder="Note"/>
        <label className="text-sm flex items-center gap-2"><input type="checkbox" name="is_final_delivery_yn"/>This completes delivery for this order</label>
        <button className="bg-sky-600 text-white px-4 py-2 rounded w-fit">Add tracking</button>
      </form>
      <ul className="space-y-1 text-sm">
        {((tracking??[]) as TrackingRow[]).map(t=> (
          <li key={t.id} className="rounded bg-slate-50 p-2">{t.couriers?.name ?? "Courier"} — {t.tracking_ref} {t.is_final_delivery_yn ? "(Final delivery)" : ""}</li>
        ))}
      </ul>
    </section>

    <section id="invoice" className="space-y-2 rounded border p-4">
      <h2 className="font-semibold">Invoice / evidence</h2>
      <p className="text-xs text-slate-500">Order retailer expected for invoice matching: <span className="font-semibold text-slate-700">{orderRetailerName}</span></p>
      {orderHasResubmissionRequired ? <p className="rounded border border-rose-200 bg-rose-50 p-2 text-sm text-rose-900">Resubmission required: upload a corrected invoice here. The rejected invoice remains visible below for audit.</p> : null}
      <form action={submitInvoiceEvidenceAction} className="grid gap-2 md:grid-cols-3">
        <input type="hidden" name="order_id" value={orderId} />
        <input name="invoice_ref" placeholder="Invoice ref" className="border p-2" required />
        <input name="invoice_total_gbp" type="number" min="0.01" step="0.01" placeholder="Final invoice total GBP" className="border p-2" required />
        <input name="invoice_file" type="file" accept=".pdf,image/*,.png,.jpg,.jpeg,.webp" className="border p-2" required />
        <input name="retailer_delivery_gbp" type="number" min="0" step="0.01" placeholder="Optional delivery charge GBP" className="border p-2" />
        <input name="retailer_discount_gbp" type="number" min="0" step="0.01" placeholder="Optional discount GBP" className="border p-2" />
        <p className="text-xs text-slate-500 md:col-span-3">Final invoice total is checked against: original order goods amount + delivery - discount. Item lines remain a separate reconciliation check.</p>
        <button className="bg-green-600 text-white px-4 py-2 rounded w-fit">Upload invoice</button>
      </form>

      <div className="space-y-2 text-sm">
        {invoiceRows.map((invoice)=> {
          const goods = lineTotalsByInvoice.get(invoice.id) ?? { qty: 0, amount: 0 };
          const invoiceAdjustments = adjustmentRows.filter((a) => a.supplier_invoice_id === invoice.id);
          const invoiceFlags = reviewFlagsByInvoice.get(invoice.id) ?? [];
          const hasOpenFlag = invoiceFlags.some((flag) => ["open", "under_review"].includes(flag.status));
          const deliveryTotal = invoiceAdjustments.filter((a) => a.adjustment_type === "retailer_delivery" && a.approval_status !== "rejected").reduce((sum, a) => sum + Number(a.amount_gbp ?? 0), 0);
          const discountTotal = invoiceAdjustments.filter((a) => a.adjustment_type === "retailer_discount" && a.approval_status !== "rejected").reduce((sum, a) => sum + Number(a.amount_gbp ?? 0), 0);
          const expectedInvoiceTotal = orderGoodsBaseline + deliveryTotal - discountTotal;
          const summary = summaryByInvoice.get(invoice.id);
          const invoiceTotal = Number(summary?.invoice_total_gbp ?? 0);
          const variance = expectedInvoiceTotal - invoiceTotal;
          const matched = summary && Math.abs(variance) < 0.01;
          const rejected = invoice.review_status === "rejected_resubmit_required";

          return (
            <div key={invoice.id} className={`rounded p-3 ${rejected ? "border border-rose-200 bg-rose-50" : "bg-slate-50"}`}>
              <div className="flex flex-wrap items-center justify-between gap-2">
                <div>
                  {invoice.invoice_ref}
                  {!rejected ? <Link className="ml-2 text-sky-700 underline" href={`/importer/reconciliation/${orderId}`}>Reconcile</Link> : <span className="ml-2 rounded bg-white px-2 py-1 text-xs font-medium text-rose-800">Audit only</span>}
                </div>
                <div className="flex flex-wrap gap-2">
                  <span className={`rounded px-2 py-1 text-xs font-medium ${invoiceStatusClass(invoice.review_status)}`}>{invoiceStatusLabel(invoice.review_status)}</span>
                  {summary ? <span className={`rounded px-2 py-1 text-xs font-medium ${matched ? "bg-emerald-100 text-emerald-800" : "bg-amber-100 text-amber-800"}`}>{matched ? "Invoice total matched" : "Invoice total variance"}</span> : <span className="rounded bg-slate-200 px-2 py-1 text-xs">No invoice total captured</span>}
                  {hasOpenFlag ? <span className="rounded bg-rose-100 px-2 py-1 text-xs font-medium text-rose-800">Flagged for review</span> : null}
                </div>
              </div>
              {rejected ? <p className="mt-2 rounded border border-rose-200 bg-white p-2 text-xs text-rose-900"><span className="font-semibold">Rejected by supervisor.</span> {invoice.review_notes ? `Reason: ${invoice.review_notes}` : "Upload a corrected invoice using the form above."}</p> : null}
              {summary ? <div className="mt-2 grid gap-2 md:grid-cols-7 text-xs">
                <div><span className="text-slate-500">Goods qty</span><div className="font-medium">{goods.qty}</div></div>
                <div><span className="text-slate-500">Item lines</span><div className="font-medium">{money(goods.amount)}</div></div>
                <div><span className="text-slate-500">Order goods baseline</span><div className="font-medium">{money(orderGoodsBaseline)}</div></div>
                <div><span className="text-slate-500">Delivery</span><div className="font-medium">{money(deliveryTotal)}</div></div>
                <div><span className="text-slate-500">Discount</span><div className="font-medium">-{money(discountTotal)}</div></div>
                <div><span className="text-slate-500">Expected final total</span><div className="font-medium">{money(expectedInvoiceTotal)}</div></div>
                <div><span className="text-slate-500">Variance</span><div className="font-medium">{signedMoney(variance)}</div></div>
              </div> : null}

              {invoiceFlags.length > 0 ? <div className="mt-3 space-y-1">
                <h4 className="text-xs font-semibold uppercase tracking-wide text-slate-500">Review flags</h4>
                {invoiceFlags.map((flag) => (
                  <div key={flag.id} className="rounded border border-amber-200 bg-amber-50 p-2 text-xs text-amber-900">
                    <span className="font-semibold">{flagLabel(flag.flag_type)} · {flag.status}</span> — {flag.message}
                  </div>
                ))}
              </div> : null}

              {!rejected ? <form action={flagSupplierInvoiceForReviewAction} className="mt-3 grid gap-2 md:grid-cols-[220px_1fr_auto]">
                <input type="hidden" name="order_id" value={orderId} />
                <input type="hidden" name="supplier_invoice_id" value={invoice.id} />
                <select name="flag_type" className="rounded border border-slate-300 p-2 text-xs" defaultValue="invoice_total_mismatch">
                  <option value="invoice_total_mismatch">Invoice total mismatch</option>
                  <option value="ocr_unclear">OCR unclear</option>
                  <option value="wrong_invoice">Wrong invoice</option>
                  <option value="delivery_discount_query">Delivery/discount query</option>
                  <option value="manual_line_needed">Manual line needed</option>
                  <option value="other">Other</option>
                </select>
                <input name="message" className="rounded border border-slate-300 p-2 text-xs" placeholder="Explain what supervisor should check" required />
                <button className="rounded bg-amber-700 px-3 py-2 text-xs font-semibold text-white">Flag for review</button>
              </form> : null}
            </div>
          );
        })}
      </div>

      {activeAdjustmentRows.length > 0 ? <div className="space-y-1 text-sm">
        <h3 className="font-medium">Active financial adjustments for current invoice</h3>
        {activeAdjustmentRows.map((a)=> (
          <div key={a.id} className="rounded bg-slate-50 p-2">
            {adjustmentLabel(a.adjustment_type)} — {money(a.amount_gbp)} — {a.approval_status}
          </div>
        ))}
      </div> : null}
    </section>
  </main>
}
