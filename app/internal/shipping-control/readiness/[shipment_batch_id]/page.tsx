import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type ReadinessRow = {
  shipment_batch_id: string;
  booking_ref: string | null;
  shipper_id: string;
  shipper_name: string | null;
  importer_id: string | null;
  importer_name: string | null;
  shipping_document_id: string | null;
  shipping_document_kind: string | null;
  shipping_document_ref: string | null;
  shipping_document_date: string | null;
  shipping_document_currency: string | null;
  shipping_document_total: number | string | null;
  shipping_document_review_status: string | null;
  shipping_cost_allocation_id: string | null;
  shipping_apportionment_status: string | null;
  shipping_apportionment_approved_at: string | null;
  order_id: string | null;
  order_ref: string | null;
  tracking_submission_id: string | null;
  tracking_ref: string | null;
  supplier_invoice_line_id: string | null;
  item_description: string | null;
  qty_allocated: number | string | null;
  adjusted_goods_basis_gbp: number | string | null;
  allocated_shipping_amount: number | string | null;
  ap_document_route: string | null;
  customer_recharge_route: string | null;
  sales_invoice_state: string | null;
  readiness_status: string | null;
  blocker: string | null;
};

function n(value: number | string | null | undefined) {
  const parsed = Number(value ?? 0);
  return Number.isFinite(parsed) ? parsed : 0;
}

function money(value: number | string | null | undefined, currency = "GBP") {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: currency || "GBP" }).format(n(value));
}

function qty(value: number | string | null | undefined) {
  const parsed = n(value);
  return parsed % 1 === 0 ? String(Math.trunc(parsed)) : parsed.toFixed(3).replace(/0+$/, "").replace(/\.$/, "");
}

function friendly(value: string | null | undefined) {
  if (!value) return "—";
  return value.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase());
}

function shortDate(value: string | null | undefined) {
  if (!value) return "—";
  return value.includes("T") ? value.slice(0, 10) : value;
}

function routeLabel(value: string | null | undefined) {
  if (value === "include_shipping_in_main_sales_invoice_release") return "Main invoice";
  if (value === "supplementary_shipping_recharge_invoice") return "Supplementary invoice";
  if (value === "supplementary_shipping_recharge_invoice_review_required") return "Supplementary review";
  if (value === "sales_invoice_route_not_resolved") return "Route unresolved";
  return friendly(value);
}

function invoiceStateLabel(value: string | null | undefined) {
  if (value === "no_main_sales_invoice_found") return "No main sales invoice found";
  if (value === "main_sales_invoice_exists") return "Main sales invoice exists";
  if (value === "main_sales_invoice_exists_status_unknown") return "Main invoice exists — status unknown";
  if (value === "sales_invoice_exists_type_unknown") return "Sales invoice exists — type unknown";
  if (value === "sales_invoice_table_not_available") return "Sales invoice table unavailable";
  return friendly(value);
}

function readinessLabel(value: string | null | undefined) {
  if (value === "ready_for_ap_and_customer_recharge_payload_preview") return "Ready";
  if (!value) return "—";
  if (value.startsWith("blocked_")) return "Blocked";
  return friendly(value);
}

function statusClass(status: string | null | undefined) {
  if (!status) return "bg-slate-100 text-slate-700";
  if (status.startsWith("ready_") || ["accepted_current", "approved", "include_shipping_in_main_sales_invoice_release", "supplementary_shipping_recharge_invoice"].includes(status)) {
    return "bg-emerald-100 text-emerald-800";
  }
  if (status.startsWith("blocked_") || status.includes("missing") || status.includes("not_approved") || status.includes("not_accepted")) {
    return "bg-rose-100 text-rose-800";
  }
  return "bg-amber-100 text-amber-800";
}

export default async function ShippingReadinessPreviewPage({ params }: { params: Promise<{ shipment_batch_id: string }> }) {
  const { shipment_batch_id: shipmentBatchId } = await params;
  const supabase = await createClient();

  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff } = await supabase
    .from("staff")
    .select("id, full_name, role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!staff) redirect("/auth/check");

  const { data, error } = await (supabase as any).rpc("internal_shipping_ap_recharge_readiness_preview_v1", {
    p_shipment_batch_id: shipmentBatchId,
  });

  const rows = (data ?? []) as ReadinessRow[];
  const first = rows[0] ?? null;
  const blockers = Array.from(new Set(rows.map((row) => row.blocker).filter(Boolean))) as string[];
  const currency = first?.shipping_document_currency ?? "GBP";
  const totalShippingAllocated = rows.reduce((sum, row) => sum + n(row.allocated_shipping_amount), 0);
  const totalAdjustedGoods = rows.reduce((sum, row) => sum + n(row.adjusted_goods_basis_gbp), 0);
  const itemQty = rows.reduce((sum, row) => sum + n(row.qty_allocated), 0);
  const customerRoutes = Array.from(new Set(rows.map((row) => row.customer_recharge_route).filter(Boolean))) as string[];
  const primaryCustomerRoute = customerRoutes[0] ?? null;
  const apReady = rows.length > 0 && blockers.length === 0;

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-7xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-wrap gap-3 text-sm font-semibold text-sky-700">
            <Link href="/internal/shipping-control">← Shipping control</Link>
            {first?.shipping_document_id ? <Link href={`/internal/shipping-control/shipper-documents/${first.shipping_document_id}`}>Review shipper document</Link> : null}
            {first?.shipping_document_id ? <Link href={`/internal/shipping-control/apportionment/${first.shipping_document_id}`}>Review apportionment</Link> : null}
          </div>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Goodcashback Internal</p>
          <div className="mt-2 flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
            <div>
              <h1 className="text-2xl font-semibold tracking-tight sm:text-3xl">Shipping AP / recharge readiness preview</h1>
              <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">
                Read-only resolver showing what the accepted shipper charge would feed next: Sage AP purchase invoice for the shipper, and customer/importer shipping recharge as main-sales-invoice line or supplementary invoice. This does not post to Sage, create COS/BOL/POD, or clear VAT.
              </p>
            </div>
            <div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700"><div className="font-medium text-slate-950">{staff.full_name}</div><div>{staff.role_type}</div></div>
          </div>
          {error ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">{error.message}</p> : null}
          {!first && !error ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">No readiness rows found for this shipment batch.</p> : null}
        </section>

        {first ? (
          <>
            <section className="grid gap-4 md:grid-cols-5">
              <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Booking ref</p><p className="mt-1 text-xl font-semibold">{first.booking_ref ?? shipmentBatchId}</p></div>
              <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Importer</p><p className="mt-1 text-xl font-semibold">{first.importer_name ?? "—"}</p></div>
              <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Shipper</p><p className="mt-1 text-xl font-semibold">{first.shipper_name ?? "—"}</p></div>
              <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Item qty</p><p className="mt-1 text-xl font-semibold">{qty(itemQty)}</p></div>
              <div className={`rounded-3xl border p-4 shadow-sm ${apReady ? "border-emerald-200 bg-emerald-50" : "border-rose-200 bg-rose-50"}`}><p className="text-xs uppercase tracking-wide text-slate-500">Readiness</p><p className="mt-1 text-xl font-semibold">{apReady ? "Ready" : "Blocked"}</p></div>
            </section>

            {blockers.length > 0 ? (
              <section className="rounded-3xl border border-rose-300 bg-rose-50 p-5 text-sm text-rose-900 shadow-sm">
                <h2 className="text-lg font-semibold">Blocked before payload preview</h2>
                <ul className="mt-2 list-disc space-y-1 pl-5">
                  {blockers.map((blocker) => <li key={blocker}>{friendly(blocker)}</li>)}
                </ul>
              </section>
            ) : null}

            <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
              <h2 className="text-xl font-semibold">Posting route summary</h2>
              <p className="mt-2 text-sm leading-6 text-slate-600">This is only the resolver result. It confirms what the later posting/release lane should prepare.</p>
              <div className="mt-4 grid gap-3 lg:grid-cols-2">
                <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
                  <p className="text-xs font-semibold uppercase tracking-wide text-slate-500">AP</p>
                  <p className="mt-1 text-lg font-semibold">Purchase invoice to {first.shipper_name ?? "shipper"}</p>
                  <p className="mt-1 text-sm text-slate-600">{first.shipping_document_ref ?? "No ref"} · {money(first.shipping_document_total, currency)}</p>
                </div>
                <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
                  <p className="text-xs font-semibold uppercase tracking-wide text-slate-500">Customer recharge</p>
                  <p className="mt-1 text-lg font-semibold">{routeLabel(primaryCustomerRoute)}</p>
                  <p className="mt-1 text-sm text-slate-600">{money(totalShippingAllocated, currency)} shipping recharge on {money(totalAdjustedGoods, "GBP")} adjusted goods basis</p>
                </div>
              </div>
            </section>

            <section className="grid gap-4 lg:grid-cols-2">
              <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
                <h2 className="text-xl font-semibold">AP side</h2>
                <p className="mt-2 text-sm leading-6 text-slate-600">Future Sage document route for the accepted shipper invoice/receipt.</p>
                <div className="mt-4 grid gap-3 sm:grid-cols-2">
                  <div className="rounded-2xl bg-slate-50 p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Document route</p><p className="mt-1 font-semibold">Sage AP / purchase invoice</p></div>
                  <div className="rounded-2xl bg-slate-50 p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Payable to</p><p className="mt-1 font-semibold">{first.shipper_name ?? "Shipper"}</p></div>
                  <div className="rounded-2xl bg-slate-50 p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Document ref</p><p className="mt-1 font-semibold">{first.shipping_document_ref ?? "—"}</p></div>
                  <div className="rounded-2xl bg-slate-50 p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Document date</p><p className="mt-1 font-semibold">{shortDate(first.shipping_document_date)}</p></div>
                  <div className="rounded-2xl bg-slate-50 p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Accepted amount</p><p className="mt-1 font-semibold">{money(first.shipping_document_total, currency)}</p></div>
                  <div className="rounded-2xl bg-slate-50 p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Status</p><span className={`mt-1 inline-block rounded-full px-2 py-1 text-xs font-semibold ${statusClass(first.shipping_document_review_status)}`}>{friendly(first.shipping_document_review_status)}</span></div>
                </div>
              </div>

              <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
                <h2 className="text-xl font-semibold">Customer/importer side</h2>
                <p className="mt-2 text-sm leading-6 text-slate-600">Resolver decides whether shipping recharge belongs to the main sales invoice release or a supplementary shipping invoice.</p>
                <div className="mt-4 grid gap-3 sm:grid-cols-2">
                  <div className="rounded-2xl bg-slate-50 p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Adjusted goods basis</p><p className="mt-1 font-semibold">{money(totalAdjustedGoods, "GBP")}</p></div>
                  <div className="rounded-2xl bg-slate-50 p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Shipping recharge</p><p className="mt-1 font-semibold">{money(totalShippingAllocated, currency)}</p></div>
                  <div className="rounded-2xl bg-slate-50 p-3 sm:col-span-2"><p className="text-xs uppercase tracking-wide text-slate-500">Route</p><div className="mt-2 flex flex-wrap gap-2">{customerRoutes.length ? customerRoutes.map((route) => <span key={route} className={`rounded-full px-2 py-1 text-xs font-semibold ${statusClass(route)}`}>{routeLabel(route)}</span>) : <span className="text-sm font-semibold">—</span>}</div></div>
                </div>
              </div>
            </section>

            <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
              <h2 className="text-xl font-semibold">Line-level payload preview</h2>
              <p className="mt-2 text-sm leading-6 text-slate-600">This is the controlled source that later feeds Sage/AP and customer recharge payloads. COS/export evidence stays separate.</p>

              <div className="mt-4 grid gap-3 md:hidden">
                {rows.map((row, index) => (
                  <article key={`${row.order_id}-${row.tracking_submission_id}-${row.supplier_invoice_line_id}-${index}-card`} className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
                    <div className="flex items-start justify-between gap-3">
                      <div>
                        <p className="text-xs font-semibold uppercase tracking-wide text-slate-500">Order / package</p>
                        <p className="mt-1 font-semibold">{row.order_ref ?? row.order_id ?? "—"}</p>
                        <p className="text-sm text-slate-500">{row.tracking_ref ?? row.tracking_submission_id ?? "—"}</p>
                      </div>
                      <span className={`shrink-0 rounded-full px-2 py-1 text-xs font-semibold ${statusClass(row.readiness_status)}`}>{readinessLabel(row.readiness_status)}</span>
                    </div>
                    <p className="mt-3 text-sm text-slate-700">{row.item_description ?? "—"}</p>
                    <div className="mt-4 grid grid-cols-3 gap-2 text-sm">
                      <div className="rounded-xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Qty</p><p className="mt-1 font-semibold">{qty(row.qty_allocated)}</p></div>
                      <div className="rounded-xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Basis</p><p className="mt-1 font-semibold">{money(row.adjusted_goods_basis_gbp, "GBP")}</p></div>
                      <div className="rounded-xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Shipping</p><p className="mt-1 font-semibold">{money(row.allocated_shipping_amount, currency)}</p></div>
                    </div>
                    <div className="mt-3 rounded-xl bg-white p-3 text-sm">
                      <p className="text-xs font-semibold uppercase tracking-wide text-slate-500">Customer route</p>
                      <div className="mt-2 flex flex-wrap items-center gap-2">
                        <span className={`rounded-full px-2 py-1 text-xs font-semibold ${statusClass(row.customer_recharge_route)}`}>{routeLabel(row.customer_recharge_route)}</span>
                        <span className="text-xs text-slate-500">{invoiceStateLabel(row.sales_invoice_state)}</span>
                      </div>
                    </div>
                  </article>
                ))}
              </div>

              <div className="mt-4 hidden overflow-x-auto rounded-2xl border border-slate-200 md:block">
                <table className="min-w-full divide-y divide-slate-200 text-sm">
                  <thead className="bg-slate-100 text-xs uppercase tracking-wide text-slate-500">
                    <tr>
                      <th className="px-3 py-2 text-left">Order / package</th>
                      <th className="px-3 py-2 text-left">Item</th>
                      <th className="px-3 py-2 text-right">Qty</th>
                      <th className="px-3 py-2 text-right">Adjusted basis</th>
                      <th className="px-3 py-2 text-right">Shipping</th>
                      <th className="px-3 py-2 text-left">Customer route</th>
                      <th className="px-3 py-2 text-left">Status</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-slate-100 bg-white">
                    {rows.map((row, index) => (
                      <tr key={`${row.order_id}-${row.tracking_submission_id}-${row.supplier_invoice_line_id}-${index}`}>
                        <td className="px-3 py-3 align-top"><p className="font-semibold">{row.order_ref ?? row.order_id ?? "—"}</p><p className="text-xs text-slate-500">{row.tracking_ref ?? row.tracking_submission_id ?? "—"}</p></td>
                        <td className="px-3 py-3 align-top">{row.item_description ?? "—"}</td>
                        <td className="px-3 py-3 text-right align-top">{qty(row.qty_allocated)}</td>
                        <td className="px-3 py-3 text-right align-top">{money(row.adjusted_goods_basis_gbp, "GBP")}</td>
                        <td className="px-3 py-3 text-right align-top font-semibold">{money(row.allocated_shipping_amount, currency)}</td>
                        <td className="px-3 py-3 align-top"><span className={`rounded-full px-2 py-1 text-xs font-semibold ${statusClass(row.customer_recharge_route)}`}>{routeLabel(row.customer_recharge_route)}</span><p className="mt-1 text-xs text-slate-500">{invoiceStateLabel(row.sales_invoice_state)}</p></td>
                        <td className="px-3 py-3 align-top"><span className={`rounded-full px-2 py-1 text-xs font-semibold ${statusClass(row.readiness_status)}`}>{readinessLabel(row.readiness_status)}</span></td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </section>

            <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm leading-6 text-amber-900">
              <h2 className="font-semibold">Control rule</h2>
              <p className="mt-2">This page only resolves the next accounting route. It does not post to Sage. AP invoice posting, customer sales invoice/supplementary invoice creation, draft COS review, master shipment grouping and final export evidence clearance remain separate controlled steps.</p>
            </section>
          </>
        ) : null}
      </div>
    </main>
  );
}
