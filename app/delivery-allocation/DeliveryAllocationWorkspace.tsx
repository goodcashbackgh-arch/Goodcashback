import Link from "next/link";
import {
  clearDeliveryAllocationForLineAction,
  saveDeliveryAllocationAction,
} from "./actions";
import {
  DeliveryAllocationData,
  DeliveryAllocationLine,
  DeliveryAllocationRow,
  isProgressedFlag,
} from "./data";

function gbp(value: number | null | undefined) {
  return new Intl.NumberFormat("en-GB", {
    style: "currency",
    currency: "GBP",
    minimumFractionDigits: 2,
  }).format(Number(value ?? 0));
}

function formatDate(value: string | null | undefined) {
  if (!value) return "—";
  return value;
}

function allocationLabel(status: string) {
  return status
    .replaceAll("_", " ")
    .replace(/^./, (char) => char.toUpperCase());
}

function allocationsForLine(line: DeliveryAllocationLine, allocations: DeliveryAllocationRow[]) {
  return allocations.filter((allocation) => allocation.supplier_invoice_line_id === line.id);
}

function sumAllocatedQty(allocations: DeliveryAllocationRow[]) {
  return allocations.reduce((sum, allocation) => sum + Number(allocation.qty_allocated ?? 0), 0);
}

function sumAllocatedNet(allocations: DeliveryAllocationRow[]) {
  return allocations.reduce((sum, allocation) => sum + Number(allocation.adjusted_net_value_gbp ?? 0), 0);
}

function trackingName(data: DeliveryAllocationData, trackingId: string | null) {
  if (!trackingId) return "Unassigned / unknown";
  const tracking = data.tracking.find((row) => row.id === trackingId);
  if (!tracking) return trackingId;
  return `${tracking.courier_name ?? "Courier"} · ${tracking.tracking_ref}`;
}

export default function DeliveryAllocationWorkspace({
  mode,
  data,
  success,
  error,
}: {
  mode: "operator" | "staff";
  data: DeliveryAllocationData;
  success?: string;
  error?: string;
}) {
  const progressedLines = data.lines.filter((line) => isProgressedFlag(line.eligible_for_invoice_yn));
  const totalProgressedQty = progressedLines.reduce((sum, line) => sum + Number(line.qty ?? 0), 0);
  const allocatedQty = data.allocations.reduce((sum, allocation) => sum + Number(allocation.qty_allocated ?? 0), 0);
  const unknownCount = data.allocations.filter((allocation) => ["unknown_contents", "needs_operator_evidence"].includes(allocation.allocation_status)).length;
  const basePath = mode === "staff" ? "/internal" : "/importer";
  const backHref = mode === "staff" ? `/internal/reconciliation/${data.order.id}` : `/importer/reconciliation/${data.order.id}`;

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto flex max-w-7xl flex-col gap-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <Link href={backHref} className="text-sm font-semibold text-sky-600">
            ← Back to {mode === "staff" ? "supervisor reconciliation" : "invoice reconciliation"}
          </Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Delivery allocation</p>
          <h1 className="mt-2 text-2xl font-semibold tracking-tight sm:text-3xl">
            Order {data.order.order_ref ?? data.order.id}
          </h1>
          <p className="mt-3 max-w-4xl text-sm leading-6 text-slate-600">
            Allocate progressed invoice lines to tracking refs/packages. This creates the item-to-package truth used later by shipper receipt, shipment batches, COS/BOL/export evidence and adjusted net value controls. It does not rewrite supplier invoice lines or block stable goods invoicing behind final POD/COS evidence.
          </p>
          <div className="mt-4 flex flex-wrap gap-2 text-xs font-semibold">
            <span className="rounded-full bg-sky-100 px-3 py-1 text-sky-800">Tracking ref = package</span>
            <span className="rounded-full bg-emerald-100 px-3 py-1 text-emerald-800">Original invoice lines stay intact</span>
            <span className="rounded-full bg-slate-100 px-3 py-1 text-slate-700">Net values include approved delivery/discount apportionment</span>
          </div>
          {success ? <p className="mt-4 rounded-xl border border-emerald-300 bg-emerald-50 px-3 py-2 text-sm text-emerald-900">{success}</p> : null}
          {error ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">{error}</p> : null}
        </section>

        <section className="grid gap-4 md:grid-cols-4">
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
            <p className="text-xs uppercase tracking-wide text-slate-500">Importer</p>
            <p className="mt-1 text-lg font-semibold">{data.order.importer_name ?? "—"}</p>
          </div>
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
            <p className="text-xs uppercase tracking-wide text-slate-500">Retailer</p>
            <p className="mt-1 text-lg font-semibold">{data.order.retailer_name ?? "—"}</p>
          </div>
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
            <p className="text-xs uppercase tracking-wide text-slate-500">Progressed qty</p>
            <p className="mt-1 text-lg font-semibold">{totalProgressedQty}</p>
          </div>
          <div className={`rounded-3xl border p-4 shadow-sm ${unknownCount > 0 ? "border-amber-200 bg-amber-50" : "border-slate-200 bg-white"}`}>
            <p className="text-xs uppercase tracking-wide text-slate-500">Allocated qty</p>
            <p className="mt-1 text-lg font-semibold">{allocatedQty}</p>
            {unknownCount > 0 ? <p className="mt-1 text-xs font-medium text-amber-800">{unknownCount} unknown/needs evidence allocation(s)</p> : null}
          </div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
            <div>
              <p className="text-sm font-medium uppercase tracking-[0.16em] text-slate-500">Approved adjustment basis</p>
              <h2 className="mt-1 text-xl font-semibold">Adjusted net value control</h2>
              <p className="mt-2 text-sm leading-6 text-slate-600">
                Approved retailer delivery and discount adjustments are apportioned by line value so shipment/COS values do not overstate the goods value.
              </p>
            </div>
            <Link href="/internal/adjustments" className="rounded-xl border border-slate-300 px-4 py-2 text-sm font-semibold text-slate-800 hover:bg-slate-50">
              Adjustment review
            </Link>
          </div>
          <div className="mt-4 grid gap-3 md:grid-cols-3">
            <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
              <p className="text-xs uppercase tracking-wide text-slate-500">Approved retailer delivery</p>
              <p className="mt-1 text-2xl font-semibold">{gbp(data.adjustments.retailerDeliveryGbp)}</p>
            </div>
            <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
              <p className="text-xs uppercase tracking-wide text-slate-500">Approved retailer discount</p>
              <p className="mt-1 text-2xl font-semibold">-{gbp(data.adjustments.retailerDiscountGbp)}</p>
            </div>
            <div className={`rounded-2xl border p-4 ${data.adjustments.pendingCount > 0 ? "border-amber-200 bg-amber-50" : "border-emerald-200 bg-emerald-50"}`}>
              <p className="text-xs uppercase tracking-wide text-slate-500">Pending adjustments</p>
              <p className="mt-1 text-2xl font-semibold">{data.adjustments.pendingCount}</p>
              {data.adjustments.pendingCount > 0 ? <p className="mt-1 text-xs text-amber-800">Approve/reject before locking export evidence values.</p> : null}
            </div>
          </div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <h2 className="text-xl font-semibold">Tracking refs / package handles</h2>
          {data.tracking.length > 0 ? (
            <div className="mt-4 grid gap-3 md:grid-cols-2">
              {data.tracking.map((tracking) => (
                <article key={tracking.id} className="rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm">
                  <p className="font-semibold text-slate-900">{tracking.courier_name ?? "Courier"} · {tracking.tracking_ref}</p>
                  <p className="mt-1 text-slate-600">Tracking date: {formatDate(tracking.tracking_date)}</p>
                  <p className="mt-1 text-slate-600">Final retailer delivery marker: {tracking.is_final_delivery_yn ? "Yes" : "No"}</p>
                  {tracking.note ? <p className="mt-2 text-slate-700">{tracking.note}</p> : null}
                  {tracking.tracking_screenshot_url ? <a href={tracking.tracking_screenshot_url} target="_blank" rel="noreferrer" className="mt-2 inline-block text-sm font-semibold text-sky-700 underline">Open tracking evidence</a> : null}
                </article>
              ))}
            </div>
          ) : (
            <p className="mt-4 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-900">
              No tracking refs have been submitted yet. Add tracking from the order operations page before allocating lines to packages.
            </p>
          )}
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <h2 className="text-xl font-semibold">Progressed lines → tracking refs</h2>
          {data.invoice ? <p className="mt-2 text-sm text-slate-600">Supplier invoice: {data.invoice.invoice_ref ?? data.invoice.id}</p> : null}

          {progressedLines.length === 0 ? (
            <p className="mt-4 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-900">
              No progressed lines are available. Progress clean invoice lines first, then return here for delivery allocation.
            </p>
          ) : (
            <div className="mt-4 space-y-5">
              {progressedLines.map((line) => {
                const lineAllocations = allocationsForLine(line, data.allocations);
                const lineAllocatedQty = sumAllocatedQty(lineAllocations);
                const remainingQty = Math.max(0, Number(line.qty ?? 0) - lineAllocatedQty);
                const allocatedNet = sumAllocatedNet(lineAllocations);
                const complete = remainingQty <= 0.0001;

                return (
                  <article key={line.id} className="rounded-3xl border border-slate-200 bg-slate-50 p-4">
                    <div className="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
                      <div>
                        <p className="text-sm font-semibold text-slate-900">Line {line.line_order}: {line.description}</p>
                        <p className="mt-1 text-sm text-slate-600">Original qty {line.qty} · original value {gbp(line.amount_inc_vat_gbp)}</p>
                      </div>
                      <span className={`w-fit rounded-full px-3 py-1 text-xs font-semibold ${complete ? "bg-emerald-100 text-emerald-800" : "bg-amber-100 text-amber-800"}`}>
                        {complete ? "Allocated" : `${remainingQty} qty remaining`}
                      </span>
                    </div>

                    {lineAllocations.length > 0 ? (
                      <div className="mt-4 overflow-x-auto rounded-2xl border border-slate-200 bg-white">
                        <table className="min-w-full divide-y divide-slate-200 text-sm">
                          <thead className="bg-slate-100 text-xs uppercase tracking-wide text-slate-500">
                            <tr>
                              <th className="px-3 py-2 text-left">Tracking/package</th>
                              <th className="px-3 py-2 text-right">Qty</th>
                              <th className="px-3 py-2 text-right">Base</th>
                              <th className="px-3 py-2 text-right">Discount</th>
                              <th className="px-3 py-2 text-right">Delivery</th>
                              <th className="px-3 py-2 text-right">Net</th>
                              <th className="px-3 py-2 text-left">Status</th>
                            </tr>
                          </thead>
                          <tbody className="divide-y divide-slate-100 bg-white">
                            {lineAllocations.map((allocation) => (
                              <tr key={allocation.id}>
                                <td className="px-3 py-2">{trackingName(data, allocation.tracking_submission_id)}</td>
                                <td className="px-3 py-2 text-right">{allocation.qty_allocated}</td>
                                <td className="px-3 py-2 text-right">{gbp(allocation.base_value_gbp)}</td>
                                <td className="px-3 py-2 text-right">-{gbp(allocation.discount_share_gbp)}</td>
                                <td className="px-3 py-2 text-right">{gbp(allocation.retailer_delivery_share_gbp)}</td>
                                <td className="px-3 py-2 text-right font-semibold">{gbp(allocation.adjusted_net_value_gbp)}</td>
                                <td className="px-3 py-2">{allocationLabel(allocation.allocation_status)}</td>
                              </tr>
                            ))}
                          </tbody>
                        </table>
                      </div>
                    ) : null}

                    <div className="mt-4 grid gap-4 lg:grid-cols-[2fr_1fr]">
                      <form action={saveDeliveryAllocationAction} className="rounded-2xl border border-slate-200 bg-white p-4">
                        <input type="hidden" name="mode" value={mode} />
                        <input type="hidden" name="order_id" value={data.order.id} />
                        <input type="hidden" name="supplier_invoice_line_id" value={line.id} />
                        <div className="grid gap-3 md:grid-cols-2">
                          <label className="space-y-1 text-sm">
                            <span className="text-xs uppercase tracking-wide text-slate-500">Tracking ref / package</span>
                            <select name="tracking_submission_id" className="w-full rounded-xl border border-slate-300 px-3 py-2">
                              <option value="">Select tracking ref or mark unknown</option>
                              {data.tracking.map((tracking) => (
                                <option key={tracking.id} value={tracking.id}>{tracking.courier_name ?? "Courier"} · {tracking.tracking_ref}</option>
                              ))}
                            </select>
                          </label>
                          <label className="space-y-1 text-sm">
                            <span className="text-xs uppercase tracking-wide text-slate-500">Qty to allocate</span>
                            <input name="qty_allocated" type="number" step="0.001" min="0" defaultValue={remainingQty > 0 ? remainingQty : line.qty} className="w-full rounded-xl border border-slate-300 px-3 py-2" />
                          </label>
                          <label className="space-y-1 text-sm">
                            <span className="text-xs uppercase tracking-wide text-slate-500">Allocation status</span>
                            <select name="allocation_status" className="w-full rounded-xl border border-slate-300 px-3 py-2" defaultValue="allocated">
                              <option value="allocated">Allocated</option>
                              <option value="partially_allocated">Partially allocated</option>
                              <option value="unknown_contents">Unknown contents</option>
                              <option value="needs_operator_evidence">Needs operator evidence</option>
                              {mode === "staff" ? <option value="supervisor_accepted_estimate">Supervisor accepted estimate</option> : null}
                            </select>
                          </label>
                          <label className="space-y-1 text-sm">
                            <span className="text-xs uppercase tracking-wide text-slate-500">Basis</span>
                            <select name="allocation_basis" className="w-full rounded-xl border border-slate-300 px-3 py-2" defaultValue={mode === "staff" ? "supervisor_estimate" : "operator_declaration"}>
                              <option value="operator_declaration">Operator declaration</option>
                              <option value="retailer_dispatch_email">Retailer dispatch email</option>
                              <option value="retailer_app">Retailer app</option>
                              <option value="packing_slip">Packing slip</option>
                              <option value="retailer_delivery_note">Retailer delivery note</option>
                              <option value="supervisor_estimate">Supervisor estimate</option>
                              <option value="unknown">Unknown</option>
                            </select>
                          </label>
                          <label className="space-y-1 text-sm md:col-span-2">
                            <span className="text-xs uppercase tracking-wide text-slate-500">Evidence URL</span>
                            <input name="evidence_url" className="w-full rounded-xl border border-slate-300 px-3 py-2" placeholder="Retailer dispatch screenshot/app/packing-slip link" />
                          </label>
                          <label className="space-y-1 text-sm md:col-span-2">
                            <span className="text-xs uppercase tracking-wide text-slate-500">Notes</span>
                            <textarea name="notes" rows={2} className="w-full rounded-xl border border-slate-300 px-3 py-2" placeholder="Explain split, evidence basis, or unknown contents." />
                          </label>
                        </div>
                        <div className="mt-3 flex flex-wrap gap-2">
                          <button type="submit" className="rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800">
                            Save allocation
                          </button>
                          <span className="rounded-xl bg-sky-50 px-3 py-2 text-xs font-semibold text-sky-800">Default qty = assign all remaining</span>
                        </div>
                      </form>

                      <form action={clearDeliveryAllocationForLineAction} className="rounded-2xl border border-rose-200 bg-rose-50 p-4">
                        <input type="hidden" name="mode" value={mode} />
                        <input type="hidden" name="order_id" value={data.order.id} />
                        <input type="hidden" name="supplier_invoice_line_id" value={line.id} />
                        <p className="text-sm font-semibold text-rose-900">Rework this line</p>
                        <p className="mt-2 text-sm leading-6 text-rose-800">
                          Clears unlocked allocations for this line so the operator or supervisor can split it again. Locked export-pack allocations are not touched.
                        </p>
                        <button type="submit" className="mt-3 rounded-xl border border-rose-300 bg-white px-4 py-2 text-sm font-semibold text-rose-800 hover:bg-rose-100">
                          Clear unlocked allocations
                        </button>
                      </form>
                    </div>
                  </article>
                );
              })}
            </div>
          )}
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <h2 className="text-xl font-semibold">What this page does next</h2>
          <div className="mt-3 grid gap-3 md:grid-cols-3">
            <div className="rounded-2xl bg-slate-50 p-4 text-sm text-slate-700">1. Operator/supervisor maps progressed lines to tracking refs/packages.</div>
            <div className="rounded-2xl bg-slate-50 p-4 text-sm text-slate-700">2. Shipper later confirms received packages and selects them into shipment batches.</div>
            <div className="rounded-2xl bg-slate-50 p-4 text-sm text-slate-700">3. Supervisor joins package, line, net value and shipment truth before draft COS.</div>
          </div>
          <div className="mt-4 flex flex-wrap gap-3">
            <Link href={`${basePath === "/internal" ? "/internal" : "/importer"}`} className="rounded-xl border border-slate-300 px-4 py-2 text-sm font-semibold text-slate-800 hover:bg-slate-50">Back to dashboard</Link>
            <Link href={backHref} className="rounded-xl bg-sky-600 px-4 py-2 text-sm font-semibold text-white hover:bg-sky-500">Return to reconciliation</Link>
          </div>
        </section>
      </div>
    </main>
  );
}
