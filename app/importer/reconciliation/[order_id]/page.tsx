import Link from "next/link";
import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import FlashQueryParamCleaner from "@/app/_components/FlashQueryParamCleaner";
import { createClient } from "@/utils/supabase/server";
import BulkLineSelectionControls from "./BulkLineSelectionControls";
import SelectedInvoiceCookie from "./SelectedInvoiceCookie";
import {
  addManualSupplierInvoiceLineAction,
  bulkMarkSupplierInvoiceLinesProgressedAction,
  createExceptionCaseAction,
  deleteManualSupplierInvoiceLineAction,
  markSupplierInvoiceLineProgressedAction,
  updateSupplierInvoiceLineAction,
} from "./actions";
import { resolveSupplierInvoiceLineNonPhysicalAction } from "./nonPhysicalActions";

type Invoice = {
  id: string;
  invoice_ref: string;
  invoice_pdf_url: string;
  uploaded_at: string | null;
  ocr_extracted_at: string | null;
  review_status: string | null;
};

type Line = {
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

type Resolution = {
  supplier_invoice_line_id: string;
  resolution_type: string;
  financial_type: string;
  notes: string | null;
};

type OrderValueAdjustment = {
  supplier_invoice_id: string | null;
  adjustment_type: string;
  amount_gbp: number;
  approval_status: string | null;
};

type Search = { success?: string; error?: string; supplier_invoice_id?: string };

const retired = new Set(["rejected_resubmit_required", "duplicate_blocked", "superseded"]);
const progressed = (line: Pick<Line, "eligible_for_invoice_yn">) => ["y", "yes", "true", "1"].includes((line.eligible_for_invoice_yn || "").trim().toLowerCase());
const gbp = (value: unknown) => new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" }).format(Number(value ?? 0));
const signed = (value: number) => Math.abs(value) < 0.005 ? gbp(0) : `${value > 0 ? "+" : ""}${gbp(value)}`;
const input = "w-full rounded-xl border border-slate-300 px-3 py-2 text-sm";

function normalisedDescription(value: string) {
  return value.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
}

function isDiscountDescription(value: string) {
  return /(^| )(discount|promotion|promotional|promo|voucher|coupon|saving|savings)( |$)/.test(normalisedDescription(value));
}

function isDeliveryDescription(value: string) {
  return /(^| )(delivery|shipping|postage|freight|carriage)( |$)/.test(normalisedDescription(value));
}

function isFeeDescription(value: string) {
  return /(^| )(fee|charge|surcharge)( |$)/.test(normalisedDescription(value));
}

function suggestedFinancialType(line: Line) {
  if (isDiscountDescription(line.description)) return "discount";
  if (isDeliveryDescription(line.description)) return "delivery";
  if (isFeeDescription(line.description)) return "fee";
  return "other_non_physical";
}

function obviousNonPhysical(line: Line) {
  return Number(line.amount_inc_vat_gbp) < 0
    || isDiscountDescription(line.description)
    || isDeliveryDescription(line.description)
    || isFeeDescription(line.description);
}

function resolvedSignedAmount(line: Line, resolution: Resolution | undefined) {
  const amount = Number(line.amount_inc_vat_gbp ?? 0);
  if (!resolution) return amount;
  if (resolution.financial_type === "discount") return -Math.abs(amount);
  if (["delivery", "fee"].includes(resolution.financial_type)) return Math.abs(amount);
  if (resolution.financial_type === "zero_value_delivery") return 0;
  return amount;
}

function unresolvedFinancialKind(line: Line) {
  const amount = Number(line.amount_inc_vat_gbp ?? 0);
  if (amount < 0 && isDiscountDescription(line.description)) return "discount" as const;
  if (amount > 0 && isDeliveryDescription(line.description)) return "delivery" as const;
  return null;
}

function provedUnresolvedFinancialOffset(params: {
  supplierInvoiceId: string;
  lines: Line[];
  accountedLineIds: Set<string>;
  resolvedLineIds: Set<string>;
  adjustments: OrderValueAdjustment[];
}) {
  const { supplierInvoiceId, lines, accountedLineIds, resolvedLineIds, adjustments } = params;
  const unresolvedLines = lines.filter((line) => line.supplier_invoice_id === supplierInvoiceId && !accountedLineIds.has(line.id) && !resolvedLineIds.has(line.id));
  const invoiceAdjustments = adjustments.filter((adjustment) => adjustment.supplier_invoice_id === supplierInvoiceId && adjustment.approval_status !== "rejected");

  return (["discount", "delivery"] as const).reduce((offset, kind) => {
    const extractedAmount = unresolvedLines
      .filter((line) => unresolvedFinancialKind(line) === kind)
      .reduce((sum, line) => sum + Number(line.amount_inc_vat_gbp ?? 0), 0);
    const adjustmentAmount = invoiceAdjustments
      .filter((adjustment) => adjustment.adjustment_type === `retailer_${kind}`)
      .reduce((sum, adjustment) => sum + Number(adjustment.amount_gbp ?? 0), 0);
    return extractedAmount !== 0 && Math.abs(Math.abs(extractedAmount) - Math.abs(adjustmentAmount)) <= 0.01
      ? offset + extractedAmount
      : offset;
  }, 0);
}

export default async function Page({
  params,
  searchParams,
}: {
  params: Promise<{ order_id: string }>;
  searchParams?: Promise<Search>;
}) {
  const { order_id: orderId } = await params;
  const qp = searchParams ? await searchParams : {};
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: operator } = await supabase
    .from("operators")
    .select("id, full_name")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();
  if (!operator) redirect("/auth/check");

  const { data: order } = await supabase
    .from("orders")
    .select("id, importer_id, order_ref, total_qty_declared, order_total_gbp_declared, screenshot_url")
    .eq("id", orderId)
    .maybeSingle();
  if (!order) redirect("/importer");

  const { data: access } = await supabase
    .from("operator_importers")
    .select("id")
    .eq("operator_id", operator.id)
    .eq("importer_id", order.importer_id)
    .is("revoked_at", null)
    .limit(1)
    .maybeSingle();
  if (!access) redirect("/importer");

  const [{ data: invoiceRows, error: invoiceError }, { data: screenshots }] = await Promise.all([
    supabase.from("supplier_invoices").select("id, invoice_ref, invoice_pdf_url, uploaded_at, ocr_extracted_at, review_status").eq("order_id", orderId).order("uploaded_at", { ascending: false }),
    supabase.from("order_screenshots").select("id, screenshot_url, display_order, note").eq("order_id", orderId).order("display_order"),
  ]);
  const invoices = ((invoiceRows ?? []) as Invoice[]).filter((invoiceRow) => !retired.has(invoiceRow.review_status ?? ""));
  const cookieStore = await cookies();
  const requested = qp.supplier_invoice_id?.trim() || cookieStore.get(`recon_invoice_${orderId}`)?.value || "";
  const invoice = invoices.find((invoiceRow) => invoiceRow.id === requested) ?? invoices[0] ?? null;
  const invoiceIds = invoices.map((invoiceRow) => invoiceRow.id);

  const { data: allLineRows, error: linesError } = invoiceIds.length
    ? await supabase
        .from("supplier_invoice_lines")
        .select("id, supplier_invoice_id, line_order, line_source, retailer_sku, description, qty, size, amount_inc_vat_gbp, qty_confirmed, amount_confirmed, eligible_for_invoice_yn")
        .in("supplier_invoice_id", invoiceIds)
        .order("line_order")
    : { data: [] as Line[], error: null };
  const allLines = (allLineRows ?? []) as Line[];
  const lines = invoice ? allLines.filter((line) => line.supplier_invoice_id === invoice.id) : [];
  const lineIds = allLines.map((line) => line.id);

  const [{ data: resolutionRows }, { data: disputeRows }, { data: adjustmentRows }] = await Promise.all([
    lineIds.length
      ? supabase.from("supplier_invoice_line_resolutions").select("supplier_invoice_line_id, resolution_type, financial_type, notes").in("supplier_invoice_line_id", lineIds).eq("active", true).eq("resolution_type", "non_physical_financial")
      : Promise.resolve({ data: [] as Resolution[] }),
    lineIds.length
      ? supabase.from("dispute_lines").select("supplier_invoice_line_id, disputes!inner(id, desired_outcome, resolved_at)").in("supplier_invoice_line_id", lineIds).is("resolved_at", null)
      : Promise.resolve({ data: [] as any[] }),
    invoiceIds.length
      ? supabase.from("order_value_adjustments").select("supplier_invoice_id, adjustment_type, amount_gbp, approval_status").eq("order_id", orderId).in("supplier_invoice_id", invoiceIds)
      : Promise.resolve({ data: [] as OrderValueAdjustment[] }),
  ]);
  const resolutions = new Map(((resolutionRows ?? []) as Resolution[]).map((resolution) => [resolution.supplier_invoice_line_id, resolution]));
  const disputes = new Map<string, string>();
  for (const row of disputeRows ?? []) {
    const dispute = Array.isArray(row.disputes) ? row.disputes[0] : row.disputes;
    if (dispute && !dispute.resolved_at) disputes.set(row.supplier_invoice_line_id, dispute.desired_outcome);
  }

  const declaredQty = Number(order.total_qty_declared ?? 0);
  const declaredValue = Number(order.order_total_gbp_declared ?? 0);
  const accountedQty = allLines
    .filter((line) => progressed(line) || disputes.has(line.id))
    .reduce((sum, line) => sum + Number(line.qty ?? 0), 0);
  const accountedValue = allLines
    .filter((line) => progressed(line) || disputes.has(line.id) || resolutions.has(line.id))
    .reduce((sum, line) => sum + resolvedSignedAmount(line, resolutions.get(line.id)), 0);
  const remainingQty = Math.max(0, declaredQty - accountedQty);
  const remainingValue = Math.max(0, declaredValue - accountedValue);
  const accountedLineIds = new Set(allLines.filter((line) => progressed(line) || disputes.has(line.id) || resolutions.has(line.id)).map((line) => line.id));
  const resolvedLineIds = new Set(resolutions.keys());
  const adjustments = (adjustmentRows ?? []) as OrderValueAdjustment[];
  const selectable = lines.filter((line) =>
    !progressed(line)
    && !disputes.has(line.id)
    && !resolutions.has(line.id)
    && !obviousNonPhysical(line)
    && Number(line.amount_confirmed ?? line.amount_inc_vat_gbp) > 0
    && Number(line.qty_confirmed ?? line.qty) <= remainingQty
    && Number(line.amount_confirmed ?? line.amount_inc_vat_gbp) + provedUnresolvedFinancialOffset({ supplierInvoiceId: line.supplier_invoice_id, lines: allLines, accountedLineIds, resolvedLineIds, adjustments }) <= remainingValue + 0.01
  );
  const exceptionEligible = lines.filter((line) =>
    !progressed(line)
    && !disputes.has(line.id)
    && !resolutions.has(line.id)
    && !obviousNonPhysical(line)
    && Number(line.amount_inc_vat_gbp) >= 0
  );
  const qtyVariance = accountedQty - declaredQty;
  const valueVariance = accountedValue - declaredValue;

  return (
    <main className="min-h-screen bg-slate-50 p-4 text-slate-950 sm:p-6">
      <div className="mx-auto max-w-7xl space-y-6">
        <FlashQueryParamCleaner />
        <SelectedInvoiceCookie orderId={orderId} supplierInvoiceId={invoice?.id ?? null} />

        <section className="rounded-3xl border bg-white p-5 shadow-sm">
          <Link href={`/importer/orders/${orderId}/operations#invoice`} className="text-sm font-semibold text-sky-700">← Back to order evidence</Link>
          <p className="mt-5 text-xs font-bold uppercase tracking-[.18em] text-sky-600">Invoice reconciliation</p>
          <h1 className="mt-1 text-2xl font-semibold">Order {order.order_ref ?? orderId}</h1>
          <p className="mt-2 text-sm text-slate-600">The selected invoice stays separate; the baseline is counted once across all active invoices.</p>
          <div className="mt-4 flex flex-wrap gap-2">
            {invoices.map((invoiceRow) => (
              <Link
                key={invoiceRow.id}
                href={`/importer/reconciliation/${orderId}?supplier_invoice_id=${invoiceRow.id}`}
                className={`rounded-full px-3 py-1.5 text-xs font-semibold ${invoice?.id === invoiceRow.id ? "bg-sky-700 text-white" : "border border-sky-200 bg-sky-50 text-sky-800"}`}
              >
                {invoiceRow.invoice_ref}
              </Link>
            ))}
          </div>
          {qp.success ? <p className="mt-4 rounded-xl bg-emerald-50 p-3 text-sm text-emerald-900">{qp.success}</p> : null}
          {qp.error ? <p className="mt-4 rounded-xl bg-rose-50 p-3 text-sm text-rose-900">{qp.error}</p> : null}
        </section>

        <section className="rounded-3xl border bg-white p-5 shadow-sm">
          <div className="flex flex-wrap justify-between gap-3">
            <div>
              <p className="text-xs font-bold uppercase tracking-wide text-slate-500">Order-wide bundle check</p>
              <h2 className="text-xl font-semibold">All active invoice lines</h2>
            </div>
            <span className={`rounded-full px-3 py-1 text-xs font-semibold ${Math.abs(qtyVariance) < 0.01 && Math.abs(valueVariance) < 0.01 ? "bg-emerald-100 text-emerald-800" : "bg-amber-100 text-amber-800"}`}>
              {Math.abs(qtyVariance) < 0.01 && Math.abs(valueVariance) < 0.01 ? "Accounted for" : "Variance open"}
            </span>
          </div>
          <div className="mt-4 grid gap-3 md:grid-cols-6">
            {[
              ["Declared qty", declaredQty],
              ["Accounted qty", accountedQty],
              ["Qty variance", qtyVariance],
              ["Declared value", gbp(declaredValue)],
              ["Accounted value", gbp(accountedValue)],
              ["Value variance", signed(valueVariance)],
            ].map(([label, value]) => (
              <div key={String(label)} className="rounded-2xl bg-slate-50 p-3">
                <p className="text-xs text-slate-500">{label}</p>
                <p className="font-semibold">{value}</p>
              </div>
            ))}
          </div>
        </section>

        <section className="grid gap-6 lg:grid-cols-2">
          <article className="rounded-3xl border bg-white p-5 shadow-sm">
            <h2 className="text-xl font-semibold">Selected supplier invoice</h2>
            {invoiceError ? (
              <p className="mt-3 text-rose-700">{invoiceError.message}</p>
            ) : invoice ? (
              <>
                <dl className="mt-4 grid gap-3 sm:grid-cols-2">
                  <div><dt className="text-xs text-slate-500">Reference</dt><dd className="font-semibold">{invoice.invoice_ref}</dd></div>
                  <div><dt className="text-xs text-slate-500">Line count</dt><dd>{lines.length}</dd></div>
                  <div><dt className="text-xs text-slate-500">Uploaded</dt><dd>{invoice.uploaded_at ?? "—"}</dd></div>
                  <div><dt className="text-xs text-slate-500">OCR extracted</dt><dd>{invoice.ocr_extracted_at ?? "—"}</dd></div>
                </dl>
                <a href={invoice.invoice_pdf_url} target="_blank" rel="noreferrer" className="mt-4 inline-block rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white">Open this invoice</a>
              </>
            ) : <p className="mt-3 text-slate-600">No active invoice.</p>}
          </article>

          <article className="rounded-3xl border bg-white p-5 shadow-sm">
            <h2 className="text-xl font-semibold">Original order screenshots</h2>
            <div className="mt-4 space-y-3">
              {(screenshots ?? []).map((screenshot: any) => (
                <details key={screenshot.id} className="rounded-xl border p-3">
                  <summary className="cursor-pointer font-semibold">Screenshot {screenshot.display_order ?? ""}</summary>
                  {screenshot.note ? <p className="mt-2 text-sm">{screenshot.note}</p> : null}
                  <img src={screenshot.screenshot_url} alt="Order screenshot" className="mt-3 max-h-[60vh] w-full object-contain" />
                </details>
              ))}
            </div>
          </article>
        </section>

        {invoice ? (
          <>
            <section className="rounded-3xl border bg-white p-5 shadow-sm">
              <h2 className="text-xl font-semibold">Add manual line to {invoice.invoice_ref}</h2>
              <form action={addManualSupplierInvoiceLineAction} className="mt-4 grid gap-3 md:grid-cols-5">
                <input type="hidden" name="order_id" value={orderId} />
                <input type="hidden" name="supplier_invoice_id" value={invoice.id} />
                <input name="description" required placeholder="Description" className={`${input} md:col-span-2`} />
                <input name="qty" required type="number" min="0" step="1" placeholder="Qty" className={input} />
                <input name="amount_inc_vat_gbp" required type="number" min="0" step=".01" placeholder="Amount" className={input} />
                <button className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white">Add line</button>
              </form>
            </section>

            <section className="rounded-3xl border bg-white p-5 shadow-sm">
              <h2 className="text-xl font-semibold">Supplier invoice lines — {invoice.invoice_ref}</h2>
              {selectable.length ? (
                <div className="mt-4 rounded-2xl bg-emerald-50 p-4">
                  <BulkLineSelectionControls selectableCount={selectable.length} />
                  <form id="bulk-progress-form" action={bulkMarkSupplierInvoiceLinesProgressedAction} className="mt-3">
                    <input type="hidden" name="order_id" value={orderId} />
                    <input type="hidden" name="supplier_invoice_id" value={invoice.id} />
                    <button className="rounded-xl bg-emerald-700 px-4 py-2 text-sm font-semibold text-white">Mark selected as progressed</button>
                  </form>
                </div>
              ) : null}

              {linesError ? (
                <p className="mt-4 text-rose-700">{linesError.message}</p>
              ) : (
                <div className="mt-4 space-y-4">
                  {lines.map((line) => {
                    const done = progressed(line);
                    const dispute = disputes.get(line.id);
                    const resolution = resolutions.get(line.id);
                    const locked = Boolean(dispute || resolution);
                    const canProgress = selectable.some((candidate) => candidate.id === line.id);
                    const signedFinancialRow = Number(line.amount_inc_vat_gbp) < 0;
                    const suggestedType = suggestedFinancialType(line);
                    const classificationOnly = obviousNonPhysical(line);
                    const cardClass = done
                      ? "border-emerald-200 bg-emerald-50"
                      : locked
                        ? "border-amber-200 bg-amber-50"
                        : classificationOnly
                          ? "border-sky-200 bg-sky-50"
                          : "bg-white";

                    return (
                      <article key={line.id} className={`rounded-2xl border p-4 ${cardClass}`}>
                        <div className="flex flex-wrap justify-between gap-2">
                          <label className="font-semibold">
                            <input type="checkbox" name="line_ids" value={line.id} form="bulk-progress-form" disabled={!canProgress} className="mr-2" />
                            Line {line.line_order}
                          </label>
                          <span className="text-xs font-semibold">
                            {done ? "Progressed" : resolution ? `Parked: ${resolution.financial_type}` : dispute ? `Exception: ${dispute}` : classificationOnly ? "Non-physical classification required" : "Unresolved"}
                          </span>
                        </div>
                        {classificationOnly && !locked ? (
                          <p className="mt-3 rounded-xl border border-sky-200 bg-white p-3 text-sm text-sky-900">
                            OCR financial row: keep the signed amount and classify it below. It cannot enter physical progression, tracking or shipment.
                          </p>
                        ) : null}
                        <div className="mt-3 grid gap-3 md:grid-cols-6">
                          <input form={`edit-${line.id}`} name="description" defaultValue={line.description} readOnly={line.line_source === "ocr_extracted" || locked} className={`${input} md:col-span-3`} />
                          <input form={`edit-${line.id}`} name="qty" type="number" min="0" step="1" defaultValue={line.qty} readOnly={locked || signedFinancialRow} className={input} />
                          <input form={`edit-${line.id}`} name="amount_inc_vat_gbp" type="number" min={signedFinancialRow ? undefined : 0} step=".01" defaultValue={line.amount_inc_vat_gbp} readOnly={locked || signedFinancialRow} className={`${input} ${signedFinancialRow ? "font-semibold text-rose-700" : ""}`} />
                          <input form={`edit-${line.id}`} name="size" defaultValue={line.size ?? ""} readOnly={locked || signedFinancialRow} placeholder="Size" className={input} />
                        </div>
                        <div className="mt-3 flex flex-wrap gap-2">
                          {!locked && !signedFinancialRow ? <button form={`edit-${line.id}`} className="rounded-xl bg-sky-700 px-3 py-2 text-sm font-semibold text-white">Save</button> : null}
                          {canProgress ? (
                            <form action={markSupplierInvoiceLineProgressedAction}>
                              <input type="hidden" name="order_id" value={orderId} />
                              <input type="hidden" name="supplier_invoice_id" value={invoice.id} />
                              <input type="hidden" name="line_id" value={line.id} />
                              <button className="rounded-xl border border-emerald-300 bg-emerald-50 px-3 py-2 text-sm font-semibold text-emerald-800">Mark progressed</button>
                            </form>
                          ) : null}
                          {!done && !locked ? (
                            <form action={resolveSupplierInvoiceLineNonPhysicalAction} className="flex gap-2">
                              <input type="hidden" name="order_id" value={orderId} />
                              <input type="hidden" name="supplier_invoice_id" value={invoice.id} />
                              <input type="hidden" name="line_id" value={line.id} />
                              <select name="financial_type" defaultValue={suggestedType} className="rounded-xl border px-2 text-sm">
                                <option value="delivery">delivery</option>
                                <option value="discount">discount</option>
                                <option value="fee">fee</option>
                                <option value="other_non_physical">other non-physical</option>
                              </select>
                              <button className="rounded-xl bg-sky-100 px-3 py-2 text-sm font-semibold text-sky-900">Park</button>
                            </form>
                          ) : null}
                          {line.line_source === "manually_added" && !locked ? (
                            <form action={deleteManualSupplierInvoiceLineAction}>
                              <input type="hidden" name="order_id" value={orderId} />
                              <input type="hidden" name="supplier_invoice_id" value={invoice.id} />
                              <input type="hidden" name="line_id" value={line.id} />
                              <button className="rounded-xl bg-rose-50 px-3 py-2 text-sm font-semibold text-rose-800">Delete</button>
                            </form>
                          ) : null}
                        </div>
                        <form id={`edit-${line.id}`} action={updateSupplierInvoiceLineAction}>
                          <input type="hidden" name="order_id" value={orderId} />
                          <input type="hidden" name="supplier_invoice_id" value={invoice.id} />
                          <input type="hidden" name="line_id" value={line.id} />
                        </form>
                      </article>
                    );
                  })}
                </div>
              )}
            </section>

            {exceptionEligible.length ? (
              <section className="rounded-3xl border bg-white p-5 shadow-sm">
                <h2 className="text-xl font-semibold">Create exception from this invoice</h2>
                <form action={createExceptionCaseAction} className="mt-4 space-y-3">
                  <input type="hidden" name="order_id" value={orderId} />
                  <input type="hidden" name="supplier_invoice_id" value={invoice.id} />
                  {exceptionEligible.map((line) => (
                    <label key={line.id} className="block rounded-xl bg-slate-50 p-3">
                      <input type="checkbox" name="exception_line_ids" value={line.id} className="mr-2" />
                      Line {line.line_order} · {line.description} · {gbp(line.amount_inc_vat_gbp)}
                    </label>
                  ))}
                  <label className="mr-4"><input type="radio" name="remedy" value="refund" className="mr-2" />Refund</label>
                  <label><input type="radio" name="remedy" value="replacement" className="mr-2" />Replacement</label>
                  <button className="ml-4 rounded-xl bg-amber-700 px-4 py-2 text-sm font-semibold text-white">Create exception</button>
                </form>
              </section>
            ) : null}
          </>
        ) : null}
      </div>
    </main>
  );
}
