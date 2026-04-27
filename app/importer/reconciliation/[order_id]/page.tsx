import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import {
  addManualSupplierInvoiceLineAction,
  deleteManualSupplierInvoiceLineAction,
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

function formatValue(value: string | number | null | undefined) {
  if (value === null || value === undefined || value === "") return "—";
  return String(value);
}

function gbp(value: number | null | undefined) {
  const n = Number(value ?? 0);
  return new Intl.NumberFormat("en-GB", {
    style: "currency",
    currency: "GBP",
    minimumFractionDigits: 2,
  }).format(n);
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

  if (!user) {
    redirect("/login");
  }

  const { data: operator } = await supabase
    .from("operators")
    .select("id, full_name")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!operator) {
    redirect("/auth/check");
  }

  const { data: order, error: orderError } = await supabase
    .from("orders")
    .select("id, importer_id")
    .eq("id", orderId)
    .maybeSingle();

  if (orderError || !order) {
    redirect("/importer");
  }

  const { data: importerAccess, error: importerAccessError } = await supabase
    .from("operator_importers")
    .select("id")
    .eq("operator_id", operator.id)
    .eq("importer_id", order.importer_id)
    .is("revoked_at", null)
    .limit(1)
    .maybeSingle();

  if (importerAccessError || !importerAccess) {
    redirect("/importer");
  }

  const { data: invoice, error: invoiceError } = await supabase
    .from("supplier_invoices")
    .select("id, order_id, invoice_ref, invoice_pdf_url, uploaded_at, ocr_extracted_at")
    .eq("order_id", orderId)
    .order("uploaded_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  const { data: lines, error: linesError } = invoice
    ? await supabase
        .from("supplier_invoice_lines")
        .select(
          "id, supplier_invoice_id, line_order, line_source, retailer_sku, description, qty, size, amount_inc_vat_gbp, qty_confirmed, amount_confirmed, eligible_for_invoice_yn"
        )
        .eq("supplier_invoice_id", invoice.id)
        .order("line_order", { ascending: true })
    : { data: [] as SupplierInvoiceLine[], error: null };

  const totalAmount = (lines ?? []).reduce((sum, line) => sum + Number(line.amount_inc_vat_gbp ?? 0), 0);
  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto flex max-w-7xl flex-col gap-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href="/importer" className="text-sm font-semibold text-sky-600">
            ← Back to importer dashboard
          </Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Invoice reconciliation</p>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight">Order {orderId}</h1>
          <p className="mt-3 text-sm leading-6 text-slate-600">
            Edit OCR and manual invoice lines, add manual lines, and delete manual lines. Progress state is read-only until a backend action exists.
          </p>
          <p className="mt-2 text-sm text-slate-600">Signed in as: {operator.full_name}</p>

          {queryParams.success ? (
            <p className="mt-4 rounded-xl border border-emerald-300 bg-emerald-50 px-3 py-2 text-sm text-emerald-900">
              {queryParams.success}
            </p>
          ) : null}
          {queryParams.error ? (
            <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">
              {queryParams.error}
            </p>
          ) : null}
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold">Supplier invoice header</h2>
          {invoiceError ? (
            <p className="mt-4 text-sm text-rose-700">Failed to load invoice header: {invoiceError.message}</p>
          ) : invoice ? (
            <dl className="mt-4 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
              <div>
                <dt className="text-xs uppercase tracking-wide text-slate-500">invoice_ref</dt>
                <dd className="font-medium">{invoice.invoice_ref}</dd>
              </div>
              <div>
                <dt className="text-xs uppercase tracking-wide text-slate-500">invoice_pdf_url</dt>
                <dd className="break-all text-sm">
                  <a href={invoice.invoice_pdf_url} target="_blank" rel="noreferrer" className="text-sky-700 underline">
                    {invoice.invoice_pdf_url}
                  </a>
                </dd>
              </div>
              <div>
                <dt className="text-xs uppercase tracking-wide text-slate-500">uploaded_at</dt>
                <dd>{formatValue(invoice.uploaded_at)}</dd>
              </div>
              <div>
                <dt className="text-xs uppercase tracking-wide text-slate-500">ocr_extracted_at</dt>
                <dd>{formatValue(invoice.ocr_extracted_at)}</dd>
              </div>
              <div>
                <dt className="text-xs uppercase tracking-wide text-slate-500">line count</dt>
                <dd>{lines?.length ?? 0}</dd>
              </div>
              <div>
                <dt className="text-xs uppercase tracking-wide text-slate-500">line total</dt>
                <dd>{gbp(totalAmount)}</dd>
              </div>
            </dl>
          ) : (
            <p className="mt-4 text-sm text-slate-600">No supplier invoice found for this order yet.</p>
          )}
        </section>

        {invoice ? (
          <>
            <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
              <h2 className="text-xl font-semibold">Add manual line</h2>
              <form action={addManualSupplierInvoiceLineAction} className="mt-4 grid gap-3 md:grid-cols-6">
                <input type="hidden" name="order_id" value={orderId} />
                <input type="hidden" name="supplier_invoice_id" value={invoice.id} />
                <label className="space-y-1 text-sm md:col-span-2">
                  <span className="text-xs uppercase tracking-wide text-slate-500">description</span>
                  <input
                    name="description"
                    required
                    className="w-full rounded-xl border border-slate-300 px-3 py-2"
                    placeholder="Manual line description"
                  />
                </label>
                <label className="space-y-1 text-sm">
                  <span className="text-xs uppercase tracking-wide text-slate-500">qty</span>
                  <input name="qty" required type="number" step="1" min="0" className="w-full rounded-xl border border-slate-300 px-3 py-2" />
                </label>
                <label className="space-y-1 text-sm">
                  <span className="text-xs uppercase tracking-wide text-slate-500">size</span>
                  <input name="size" className="w-full rounded-xl border border-slate-300 px-3 py-2" placeholder="Optional size" />
                </label>
                <label className="space-y-1 text-sm">
                  <span className="text-xs uppercase tracking-wide text-slate-500">retailer_sku</span>
                  <input
                    name="retailer_sku"
                    className="w-full rounded-xl border border-slate-300 px-3 py-2"
                    placeholder="Optional SKU"
                  />
                </label>
                <label className="space-y-1 text-sm">
                  <span className="text-xs uppercase tracking-wide text-slate-500">amount_inc_vat_gbp</span>
                  <input
                    name="amount_inc_vat_gbp"
                    required
                    type="number"
                    step="0.01"
                    min="0"
                    className="w-full rounded-xl border border-slate-300 px-3 py-2"
                  />
                </label>
                <div className="flex items-end md:col-span-6">
                  <button type="submit" className="rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white">
                    Add manual line
                  </button>
                </div>
              </form>
            </section>

            <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
              <div className="flex flex-wrap items-center justify-between gap-3">
                <h2 className="text-xl font-semibold">Supplier invoice lines</h2>
                <p className="text-sm text-slate-600">Progressed status is display-only and does not trigger reconciliation changes yet.</p>
              </div>

              {linesError ? (
                <p className="mt-4 text-sm text-rose-700">Failed to load invoice lines: {linesError.message}</p>
              ) : lines && lines.length > 0 ? (
                <div className="mt-4 space-y-4">
                  {lines.map((line) => {
                    const progressed = isProgressed(line);
                    const canDelete = line.line_source === "manually_added";

                    return (
                      <article
                        key={line.id}
                        className={`rounded-2xl border p-4 ${progressed ? "border-emerald-300 bg-emerald-50/60" : "border-slate-200 bg-white"}`}
                      >
                        <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
                          <div className="text-sm text-slate-600">
                            Line {line.line_order} · {line.line_source}
                          </div>
                          <div className="flex items-center gap-3">
                            <span
                              className={`rounded-full px-2.5 py-1 text-xs font-medium ${
                                progressed ? "bg-emerald-100 text-emerald-800" : "bg-amber-100 text-amber-800"
                              }`}
                            >
                              {progressed ? "Progressed" : "Unresolved"}
                            </span>
                            <span className="text-xs text-slate-500">Mark line progressed is not active yet.</span>
                          </div>
                        </div>

                        <form action={updateSupplierInvoiceLineAction} className="grid gap-3 md:grid-cols-12">
                          <input type="hidden" name="order_id" value={orderId} />
                          <input type="hidden" name="line_id" value={line.id} />

                          <label className="space-y-1 text-sm md:col-span-6">
                            <span className="text-xs uppercase tracking-wide text-slate-500">description</span>
                            <input
                              name="description"
                              defaultValue={line.description}
                              required
                              className="w-full rounded-xl border border-slate-300 px-3 py-2"
                            />
                          </label>

                          <label className="space-y-1 text-sm md:col-span-2">
                            <span className="text-xs uppercase tracking-wide text-slate-500">qty</span>
                            <input
                              name="qty"
                              defaultValue={line.qty}
                              required
                              type="number"
                              step="1"
                              min="0"
                              className="w-full rounded-xl border border-slate-300 px-3 py-2"
                            />
                          </label>

                          <label className="space-y-1 text-sm md:col-span-2">
                            <span className="text-xs uppercase tracking-wide text-slate-500">size</span>
                            <input
                              name="size"
                              defaultValue={line.size ?? ""}
                              className="w-full rounded-xl border border-slate-300 px-3 py-2"
                            />
                          </label>

                          <label className="space-y-1 text-sm md:col-span-2">
                            <span className="text-xs uppercase tracking-wide text-slate-500">retailer_sku</span>
                            <input
                              name="retailer_sku"
                              defaultValue={line.retailer_sku ?? ""}
                              className="w-full rounded-xl border border-slate-300 px-3 py-2"
                            />
                          </label>

                          <label className="space-y-1 text-sm md:col-span-2">
                            <span className="text-xs uppercase tracking-wide text-slate-500">amount_inc_vat_gbp</span>
                            <input
                              name="amount_inc_vat_gbp"
                              defaultValue={line.amount_inc_vat_gbp}
                              required
                              type="number"
                              step="0.01"
                              min="0"
                              className="w-full rounded-xl border border-slate-300 px-3 py-2"
                            />
                          </label>

                          <div className="space-y-1 text-sm md:col-span-2">
                            <span className="text-xs uppercase tracking-wide text-slate-500">eligible_for_invoice_yn</span>
                            <div className="rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-sm">
                              {line.eligible_for_invoice_yn}
                            </div>
                          </div>

                          <div className="md:col-span-12 pt-1">
                            <button
                              type="submit"
                              className="rounded-xl bg-sky-600 px-3 py-2 text-sm font-semibold text-white hover:bg-sky-500"
                            >
                              Save line
                            </button>
                          </div>
                        </form>
                        <div className="mt-3 flex flex-wrap items-center gap-3">
                          {canDelete ? (
                            <form action={deleteManualSupplierInvoiceLineAction}>
                              <input type="hidden" name="order_id" value={orderId} />
                              <input type="hidden" name="line_id" value={line.id} />
                              <button
                                type="submit"
                                className="rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm font-semibold text-rose-800 hover:bg-rose-100"
                              >
                                Delete manual line
                              </button>
                            </form>
                          ) : (
                            <span className="text-xs text-slate-500">OCR lines cannot be deleted.</span>
                          )}

                          <span className="text-xs text-slate-500">
                            qty_confirmed: {formatValue(line.qty_confirmed)} · amount_confirmed: {formatValue(line.amount_confirmed)}
                          </span>
                        </div>
                      </article>
                    );
                  })}
                </div>
              ) : (
                <p className="mt-4 text-sm text-slate-600">No supplier invoice lines found for this invoice.</p>
              )}
            </section>
          </>
        ) : null}
      </div>
    </main>
  );
}
