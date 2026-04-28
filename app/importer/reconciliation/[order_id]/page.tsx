import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import {
  addManualSupplierInvoiceLineAction,
  bulkMarkSupplierInvoiceLinesProgressedAction,
  deleteManualSupplierInvoiceLineAction,
  markSupplierInvoiceLineProgressedAction,
  updateSupplierInvoiceLineAction,
} from "./actions";

type SupplierInvoiceLine = {
  id: string;
  supplier_invoice_id: string;
  line_order: number;
  line_source: string;
  retailer_sku: string | null;
  description: string;
  qty: number;
  size: string | null;
  amount_inc_vat_gbp: number;
  qty_confirmed: number | null;
  amount_confirmed: number | null;
  eligible_for_invoice_yn: string;
};

type OrderScreenshot = {
  id: string;
  screenshot_url: string;
  uploaded_at: string | null;
  display_order: number | null;
  note: string | null;
};

function formatValue(value: string | number | null | undefined) {
  if (value === null || value === undefined || value === "") return "—";
  return String(value);
}

function gbp(value: number | null | undefined) {
  return new Intl.NumberFormat("en-GB", {
    style: "currency",
    currency: "GBP",
    minimumFractionDigits: 2,
  }).format(Number(value ?? 0));
}

function signedGbp(value: number) {
  if (Math.abs(value) < 0.005) return gbp(0);
  return `${value > 0 ? "+" : ""}${gbp(value)}`;
}

function signedNumber(value: number) {
  if (value === 0) return "0";
  return `${value > 0 ? "+" : ""}${value}`;
}

function isProgressed(line: Pick<SupplierInvoiceLine, "eligible_for_invoice_yn">) {
  return ["y", "yes", "true", "1"].includes(line.eligible_for_invoice_yn.trim().toLowerCase());
}

export default async function ImporterReconciliationOrderPage({
  params,
  searchParams,
}: {
  params: Promise<{ order_id: string }>;
  searchParams?: Promise<{ success?: string; error?: string }>;
}) {
  const { order_id: orderId } = await params;
  const queryParams = searchParams ? await searchParams : {};
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) redirect("/login");

  const { data: operator } = await supabase
    .from("operators")
    .select("id, full_name")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!operator) redirect("/auth/check");

  const { data: order, error: orderError } = await supabase
    .from("orders")
    .select("id, importer_id, order_ref, total_qty_declared, order_total_gbp_declared, screenshot_url")
    .eq("id", orderId)
    .maybeSingle();

  if (orderError || !order) redirect("/importer");

  const { data: importerAccess, error: importerAccessError } = await supabase
    .from("operator_importers")
    .select("id")
    .eq("operator_id", operator.id)
    .eq("importer_id", order.importer_id)
    .is("revoked_at", null)
    .limit(1)
    .maybeSingle();

  if (importerAccessError || !importerAccess) redirect("/importer");

  const { data: invoice, error: invoiceError } = await supabase
    .from("supplier_invoices")
    .select("id, order_id, invoice_ref, invoice_pdf_url, uploaded_at, ocr_extracted_at")
    .eq("order_id", orderId)
    .order("uploaded_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  const { data: screenshots, error: screenshotsError } = await supabase
    .from("order_screenshots")
    .select("id, screenshot_url, uploaded_at, display_order, note")
    .eq("order_id", orderId)
    .order("display_order", { ascending: true })
    .order("uploaded_at", { ascending: true });

  const { data: lines, error: linesError } = invoice
    ? await supabase
        .from("supplier_invoice_lines")
        .select(
          "id, supplier_invoice_id, line_order, line_source, retailer_sku, description, qty, size, amount_inc_vat_gbp, qty_confirmed, amount_confirmed, eligible_for_invoice_yn"
        )
        .eq("supplier_invoice_id", invoice.id)
        .order("line_order", { ascending: true })
    : { data: [] as SupplierInvoiceLine[], error: null };

  const invoiceLines = (lines ?? []) as SupplierInvoiceLine[];
  const selectableLines = invoiceLines.filter((line) => !isProgressed(line));
  const orderScreenshots = (screenshots ?? []) as OrderScreenshot[];
  const legacyScreenshotUrl = typeof order.screenshot_url === "string" && order.screenshot_url.trim().length > 0 ? order.screenshot_url.trim() : null;

  const lineQtyTotal = invoiceLines.reduce((sum, line) => sum + Number(line.qty ?? 0), 0);
  const lineAmountTotal = invoiceLines.reduce((sum, line) => sum + Number(line.amount_inc_vat_gbp ?? 0), 0);
  const declaredQty = Number(order.total_qty_declared ?? 0);
  const declaredAmount = Number(order.order_total_gbp_declared ?? 0);
  const qtyVariance = lineQtyTotal - declaredQty;
  const amountVariance = lineAmountTotal - declaredAmount;
  const qtyMatched = qtyVariance === 0;
  const amountMatched = Math.abs(amountVariance) < 0.01;
  const lineSetBalanced = qtyMatched && amountMatched;

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto flex max-w-7xl flex-col gap-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <Link href="/importer" className="text-sm font-semibold text-sky-600">← Back to importer dashboard</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Invoice reconciliation</p>
          <h1 className="mt-2 text-2xl font-semibold tracking-tight sm:text-3xl">Order {order.order_ref ?? orderId}</h1>
          <p className="mt-3 text-sm leading-6 text-slate-600">
            Compare the uploaded invoice against the original order screenshots and declared totals. This stage proves the parent baseline is accounted for; it does not complete the order while exceptions, funding, shipping, POD, or accounting/VAT gates remain open.
          </p>
          <p className="mt-2 text-sm text-slate-600">Signed in as: {operator.full_name}</p>
          {queryParams.success ? <p className="mt-4 rounded-xl border border-emerald-300 bg-emerald-50 px-3 py-2 text-sm text-emerald-900">{queryParams.success}</p> : null}
          {queryParams.error ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">{queryParams.error}</p> : null}
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
            <div>
              <p className="text-sm font-medium uppercase tracking-[0.16em] text-slate-500">Baseline check</p>
              <h2 className="mt-1 text-xl font-semibold">Original order vs invoice lines</h2>
            </div>
            <span className={`w-fit rounded-full px-3 py-1 text-xs font-semibold ${lineSetBalanced ? "bg-emerald-100 text-emerald-800" : "bg-amber-100 text-amber-800"}`}>
              {lineSetBalanced ? "Qty/value accounted for" : "Variance needs review"}
            </span>
          </div>
          <div className="mt-5 grid gap-3 md:grid-cols-3">
            <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4"><p className="text-xs uppercase tracking-wide text-slate-500">Original declared qty</p><p className="mt-1 text-2xl font-semibold">{declaredQty}</p></div>
            <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4"><p className="text-xs uppercase tracking-wide text-slate-500">Current invoice-line qty</p><p className="mt-1 text-2xl font-semibold">{lineQtyTotal}</p></div>
            <div className={`rounded-2xl border p-4 ${qtyMatched ? "border-emerald-200 bg-emerald-50" : "border-amber-200 bg-amber-50"}`}><p className="text-xs uppercase tracking-wide text-slate-500">Qty variance</p><p className="mt-1 text-2xl font-semibold">{signedNumber(qtyVariance)}</p></div>
            <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4"><p className="text-xs uppercase tracking-wide text-slate-500">Original declared value</p><p className="mt-1 text-2xl font-semibold">{gbp(declaredAmount)}</p></div>
            <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4"><p className="text-xs uppercase tracking-wide text-slate-500">Current invoice-line value</p><p className="mt-1 text-2xl font-semibold">{gbp(lineAmountTotal)}</p></div>
            <div className={`rounded-2xl border p-4 ${amountMatched ? "border-emerald-200 bg-emerald-50" : "border-amber-200 bg-amber-50"}`}><p className="text-xs uppercase tracking-wide text-slate-500">Value variance</p><p className="mt-1 text-2xl font-semibold">{signedGbp(amountVariance)}</p></div>
          </div>
          <p className="mt-4 rounded-2xl border border-slate-200 bg-white px-4 py-3 text-sm leading-6 text-slate-700">
            A matched qty/value set means the original parent order baseline is accounted for. The parent order still cannot fully clear until progressed lines, child exceptions, funding, shipment evidence, POD, and final accounting/VAT release gates are complete.
          </p>
        </section>

        <section className="grid gap-6 lg:grid-cols-2">
          <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
            <h2 className="text-xl font-semibold">Uploaded supplier invoice</h2>
            {invoiceError ? <p className="mt-4 text-sm text-rose-700">Failed to load invoice header: {invoiceError.message}</p> : invoice ? (
              <div className="mt-4 space-y-4">
                <dl className="grid gap-4 sm:grid-cols-2">
                  <div><dt className="text-xs uppercase tracking-wide text-slate-500">invoice_ref</dt><dd className="font-medium">{invoice.invoice_ref}</dd></div>
                  <div><dt className="text-xs uppercase tracking-wide text-slate-500">uploaded_at</dt><dd>{formatValue(invoice.uploaded_at)}</dd></div>
                  <div><dt className="text-xs uppercase tracking-wide text-slate-500">ocr_extracted_at</dt><dd>{formatValue(invoice.ocr_extracted_at)}</dd></div>
                  <div><dt className="text-xs uppercase tracking-wide text-slate-500">line count</dt><dd>{invoiceLines.length}</dd></div>
                </dl>
                <div className="flex flex-wrap gap-3">
                  <a href={invoice.invoice_pdf_url} target="_blank" rel="noreferrer" className="rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white">Open invoice</a>
                  <a href={invoice.invoice_pdf_url} target="_blank" rel="noreferrer" download className="rounded-xl border border-slate-300 px-4 py-2 text-sm font-semibold text-slate-800">Download invoice</a>
                </div>
              </div>
            ) : <p className="mt-4 text-sm text-slate-600">No supplier invoice found for this order yet.</p>}
          </div>

          <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
            <h2 className="text-xl font-semibold">Original order screenshots</h2>
            <p className="mt-2 text-sm text-slate-600">Use these to compare the retailer basket/order evidence against the invoice lines.</p>
            {screenshotsError ? <p className="mt-4 text-sm text-rose-700">Failed to load screenshots: {screenshotsError.message}</p> : orderScreenshots.length > 0 || legacyScreenshotUrl ? (
              <div className="mt-4 space-y-3">
                {orderScreenshots.map((screenshot, index) => (
                  <details key={screenshot.id} className="rounded-2xl border border-slate-200 bg-slate-50 p-3">
                    <summary className="cursor-pointer text-sm font-semibold text-slate-800">Screenshot {screenshot.display_order ?? index + 1}</summary>
                    <div className="mt-3 space-y-3">
                      {screenshot.note ? <p className="text-sm text-slate-600">{screenshot.note}</p> : null}
                      <img src={screenshot.screenshot_url} alt={`Order screenshot ${screenshot.display_order ?? index + 1}`} className="max-h-[70vh] w-full rounded-xl border border-slate-200 object-contain" />
                      <div className="flex flex-wrap gap-3">
                        <a href={screenshot.screenshot_url} target="_blank" rel="noreferrer" className="text-sm font-semibold text-sky-700 underline">Open full size</a>
                        <a href={screenshot.screenshot_url} target="_blank" rel="noreferrer" download className="text-sm font-semibold text-slate-700 underline">Download</a>
                      </div>
                    </div>
                  </details>
                ))}
                {legacyScreenshotUrl ? (
                  <details className="rounded-2xl border border-slate-200 bg-slate-50 p-3">
                    <summary className="cursor-pointer text-sm font-semibold text-slate-800">Legacy screenshot</summary>
                    <div className="mt-3 space-y-3">
                      <img src={legacyScreenshotUrl} alt="Legacy order screenshot" className="max-h-[70vh] w-full rounded-xl border border-slate-200 object-contain" />
                      <div className="flex flex-wrap gap-3">
                        <a href={legacyScreenshotUrl} target="_blank" rel="noreferrer" className="text-sm font-semibold text-sky-700 underline">Open full size</a>
                        <a href={legacyScreenshotUrl} target="_blank" rel="noreferrer" download className="text-sm font-semibold text-slate-700 underline">Download</a>
                      </div>
                    </div>
                  </details>
                ) : null}
              </div>
            ) : <p className="mt-4 text-sm text-slate-600">No original screenshots are attached to this order.</p>}
          </div>
        </section>

        {invoice ? (
          <>
            <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
              <h2 className="text-xl font-semibold">Add manual line</h2>
              <form action={addManualSupplierInvoiceLineAction} className="mt-4 grid gap-3 md:grid-cols-6">
                <input type="hidden" name="order_id" value={orderId} />
                <input type="hidden" name="supplier_invoice_id" value={invoice.id} />
                <label className="space-y-1 text-sm md:col-span-2"><span className="text-xs uppercase tracking-wide text-slate-500">description</span><input name="description" required className="w-full rounded-xl border border-slate-300 px-3 py-2" placeholder="Manual line description" /></label>
                <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-slate-500">qty</span><input name="qty" required type="number" step="1" min="0" className="w-full rounded-xl border border-slate-300 px-3 py-2" /></label>
                <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-slate-500">size</span><input name="size" className="w-full rounded-xl border border-slate-300 px-3 py-2" placeholder="Optional size" /></label>
                <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-slate-500">retailer_sku</span><input name="retailer_sku" className="w-full rounded-xl border border-slate-300 px-3 py-2" placeholder="Optional SKU" /></label>
                <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-slate-500">amount_inc_vat_gbp</span><input name="amount_inc_vat_gbp" required type="number" step="0.01" min="0" className="w-full rounded-xl border border-slate-300 px-3 py-2" /></label>
                <div className="flex items-end md:col-span-6"><button type="submit" className="rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white">Add manual line</button></div>
              </form>
            </section>

            <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
              <div className="flex flex-wrap items-center justify-between gap-3">
                <div>
                  <h2 className="text-xl font-semibold">Supplier invoice lines</h2>
                  <p className="mt-1 text-sm text-slate-600">Progressed status updates only the clean invoiceable subset. It does not complete the order.</p>
                </div>
              </div>

              {linesError ? <p className="mt-4 text-sm text-rose-700">Failed to load invoice lines: {linesError.message}</p> : invoiceLines.length > 0 ? (
                <form action={bulkMarkSupplierInvoiceLinesProgressedAction} className="mt-4 space-y-4">
                  <input type="hidden" name="order_id" value={orderId} />
                  {selectableLines.length > 0 ? (
                    <div className="rounded-2xl border border-emerald-200 bg-emerald-50 p-4">
                      <p className="text-sm font-semibold text-emerald-900">Select clean lines to progress in bulk.</p>
                      <p className="mt-1 text-xs text-emerald-800">Only unresolved lines are selectable. Progressed lines remain visible but disabled.</p>
                      <button type="submit" className="mt-3 rounded-xl bg-emerald-700 px-4 py-2 text-sm font-semibold text-white hover:bg-emerald-600">Mark selected as progressed</button>
                    </div>
                  ) : (
                    <p className="rounded-2xl border border-emerald-200 bg-emerald-50 p-4 text-sm font-medium text-emerald-800">All visible lines are already progressed.</p>
                  )}

                  <div className="space-y-4">
                    {invoiceLines.map((line) => {
                      const progressed = isProgressed(line);
                      const canDelete = line.line_source === "manually_added";
                      const isOcrLine = line.line_source === "ocr_extracted";

                      return (
                        <article key={line.id} className={`rounded-2xl border p-4 ${progressed ? "border-emerald-300 bg-emerald-50/60" : "border-slate-200 bg-white"}`}>
                          <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
                            <label className={`flex items-center gap-3 text-sm font-semibold ${progressed ? "text-slate-500" : "text-slate-900"}`}>
                              <input type="checkbox" name="line_ids" value={line.id} disabled={progressed} className="h-4 w-4 rounded border-slate-300" />
                              <span>Line {line.line_order} · {line.line_source}</span>
                            </label>
                            <span className={`rounded-full px-2.5 py-1 text-xs font-medium ${progressed ? "bg-emerald-100 text-emerald-800" : "bg-amber-100 text-amber-800"}`}>{progressed ? "Progressed" : "Unresolved"}</span>
                          </div>

                          <div className="grid gap-3 md:grid-cols-12">
                            <label className="space-y-1 text-sm md:col-span-6"><span className="text-xs uppercase tracking-wide text-slate-500">description</span><input form={`update-line-${line.id}`} name="description" defaultValue={line.description} required readOnly={isOcrLine} title={isOcrLine ? "OCR description is source evidence and cannot be changed." : undefined} className={`w-full rounded-xl border border-slate-300 px-3 py-2 ${isOcrLine ? "bg-slate-100 text-slate-600" : ""}`} />{isOcrLine ? <span className="text-xs text-slate-500">OCR source description is preserved for audit.</span> : null}</label>
                            <label className="space-y-1 text-sm md:col-span-2"><span className="text-xs uppercase tracking-wide text-slate-500">qty</span><input form={`update-line-${line.id}`} name="qty" defaultValue={line.qty} required type="number" step="1" min="0" className="w-full rounded-xl border border-slate-300 px-3 py-2" /></label>
                            <label className="space-y-1 text-sm md:col-span-2"><span className="text-xs uppercase tracking-wide text-slate-500">size</span><input form={`update-line-${line.id}`} name="size" defaultValue={line.size ?? ""} className="w-full rounded-xl border border-slate-300 px-3 py-2" /></label>
                            <label className="space-y-1 text-sm md:col-span-2"><span className="text-xs uppercase tracking-wide text-slate-500">retailer_sku</span><input form={`update-line-${line.id}`} name="retailer_sku" defaultValue={line.retailer_sku ?? ""} className="w-full rounded-xl border border-slate-300 px-3 py-2" /></label>
                            <label className="space-y-1 text-sm md:col-span-2"><span className="text-xs uppercase tracking-wide text-slate-500">amount_inc_vat_gbp</span><input form={`update-line-${line.id}`} name="amount_inc_vat_gbp" defaultValue={line.amount_inc_vat_gbp} required type="number" step="0.01" min="0" className="w-full rounded-xl border border-slate-300 px-3 py-2" /></label>
                            <div className="space-y-1 text-sm md:col-span-2"><span className="text-xs uppercase tracking-wide text-slate-500">eligible_for_invoice_yn</span><div className="rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-sm">{line.eligible_for_invoice_yn}</div></div>
                          </div>

                          <div className="mt-3 flex flex-wrap items-center gap-3">
                            <button form={`update-line-${line.id}`} type="submit" className="rounded-xl bg-sky-600 px-3 py-2 text-sm font-semibold text-white hover:bg-sky-500">Save line</button>
                            {!progressed ? (
                              <form action={markSupplierInvoiceLineProgressedAction}>
                                <input type="hidden" name="order_id" value={orderId} />
                                <input type="hidden" name="line_id" value={line.id} />
                                <button type="submit" className="rounded-xl border border-emerald-300 bg-emerald-50 px-3 py-2 text-sm font-semibold text-emerald-800 hover:bg-emerald-100">Mark progressed</button>
                              </form>
                            ) : <span className="text-xs font-medium text-emerald-700">Included in progressed subset.</span>}
                            {canDelete ? (
                              <form action={deleteManualSupplierInvoiceLineAction}>
                                <input type="hidden" name="order_id" value={orderId} />
                                <input type="hidden" name="line_id" value={line.id} />
                                <button type="submit" className="rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm font-semibold text-rose-800 hover:bg-rose-100">Delete manual line</button>
                              </form>
                            ) : <span className="text-xs text-slate-500">OCR lines cannot be deleted.</span>}
                            <span className="text-xs text-slate-500">qty_confirmed: {formatValue(line.qty_confirmed)} · amount_confirmed: {formatValue(line.amount_confirmed)}</span>
                          </div>
                        </article>
                      );
                    })}
                  </div>
                </form>
              ) : <p className="mt-4 text-sm text-slate-600">No supplier invoice lines found for this invoice.</p>}
            </section>

            {invoiceLines.map((line) => (
              <form key={`update-line-form-${line.id}`} id={`update-line-${line.id}`} action={updateSupplierInvoiceLineAction}>
                <input type="hidden" name="order_id" value={orderId} />
                <input type="hidden" name="line_id" value={line.id} />
              </form>
            ))}
          </>
        ) : null}
      </div>
    </main>
  );
}
