import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type Row = {
  shipment_batch_id: string;
  booking_ref: string | null;
  importer_id: string | null;
  importer_name: string | null;
  shipper_id: string | null;
  shipper_name: string | null;
  proposed_invoice_type: string | null;
  proposed_invoice_status: string | null;
  customer_recharge_route: string | null;
  sales_invoice_state: string | null;
  vat_code: string | null;
  proposed_amount_gbp: number | string | null;
  proposed_goods_amount_gbp: number | string | null;
  proposed_shipping_amount_gbp: number | string | null;
  line_items_json: unknown;
  order_id: string | null;
  order_ref: string | null;
  tracking_submission_id: string | null;
  tracking_ref: string | null;
  supplier_invoice_line_id: string | null;
  item_description: string | null;
  qty_allocated: number | string | null;
  goods_amount_gbp: number | string | null;
  shipping_amount_gbp: number | string | null;
  total_line_amount_gbp: number | string | null;
  readiness_status: string | null;
  blocker: string | null;
};

function n(value: number | string | null | undefined) {
  const parsed = Number(value ?? 0);
  return Number.isFinite(parsed) ? parsed : 0;
}

function money(value: number | string | null | undefined) {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" }).format(n(value));
}

function qty(value: number | string | null | undefined) {
  const parsed = n(value);
  return parsed % 1 === 0 ? String(Math.trunc(parsed)) : parsed.toFixed(3).replace(/0+$/, "").replace(/\.$/, "");
}

function friendly(value: string | null | undefined) {
  if (!value) return "—";
  return value.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase());
}

function invoiceTypeLabel(value: string | null | undefined) {
  if (value === "main") return "Add to main invoice draft/release";
  if (value === "supplementary") return "Create supplementary shipping invoice";
  return friendly(value);
}

function routeLabel(value: string | null | undefined) {
  if (value === "include_shipping_in_main_sales_invoice_release") return "Add bundled charge to main invoice draft/release";
  if (value === "supplementary_shipping_recharge_invoice") return "Create supplementary shipping invoice";
  if (value === "supplementary_shipping_recharge_invoice_review_required") return "Supplementary invoice review required";
  return friendly(value);
}

function invoiceStateLabel(value: string | null | undefined) {
  if (value === "no_main_sales_invoice_found") return "No main invoice draft/posting exists yet";
  if (value === "main_sales_invoice_draft_exists") return "Main invoice draft exists";
  if (value === "main_sales_invoice_posted") return "Main invoice already posted";
  if (value === "main_sales_invoice_void_ignored") return "Voided main invoice ignored";
  return friendly(value);
}

function readinessLabel(value: string | null | undefined) {
  if (!value) return "—";
  if (value.startsWith("ready_")) return "Ready";
  if (value.startsWith("blocked")) return "Blocked";
  return friendly(value);
}

function statusClass(status: string | null | undefined) {
  if (!status) return "bg-slate-100 text-slate-700";
  if (status.startsWith("ready_") || status === "draft_preview") return "bg-emerald-100 text-emerald-800";
  if (status.startsWith("blocked") || status.includes("missing")) return "bg-rose-100 text-rose-800";
  return "bg-amber-100 text-amber-800";
}

export default async function ShippingCustomerInvoiceReadinessPage({ params }: { params: Promise<{ shipment_batch_id: string }> }) {
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

  const { data, error } = await (supabase as any).rpc("internal_shipping_customer_invoice_readiness_preview_v1", {
    p_shipment_batch_id: shipmentBatchId,
  });

  const rows = (data ?? []) as Row[];
  const first = rows[0] ?? null;
  const blockers = Array.from(new Set(rows.map((row) => row.blocker).filter(Boolean))) as string[];
  const ready = rows.length > 0 && blockers.length === 0;

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-7xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-wrap gap-3 text-sm font-semibold text-sky-700">
            <Link href="/internal/shipping-control">← Shipping control</Link>
            <Link href={`/internal/shipping-control/readiness/${shipmentBatchId}`}>AP / recharge preview</Link>
          </div>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Goodcashback Internal</p>
          <div className="mt-2 flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
            <div>
              <h1 className="text-2xl font-semibold tracking-tight sm:text-3xl">Customer invoice readiness preview</h1>
              <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">
                Read-only preview of what the later customer invoice creation lane should prepare. It does not mean a Sage invoice has already been posted. The customer payload is bundled; the adjusted goods/shipping split is shown only as a sanity check.
              </p>
            </div>
            <div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700"><div className="font-medium text-slate-950">{staff.full_name}</div><div>{staff.role_type}</div></div>
          </div>
          {error ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">{error.message}</p> : null}
          {!first && !error ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">No customer invoice readiness rows found.</p> : null}
        </section>

        {first ? (
          <>
            <section className="grid gap-4 md:grid-cols-5">
              <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Booking ref</p><p className="mt-1 text-xl font-semibold">{first.booking_ref ?? shipmentBatchId}</p></div>
              <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Importer</p><p className="mt-1 text-xl font-semibold">{first.importer_name ?? "—"}</p></div>
              <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Customer action</p><p className="mt-1 text-xl font-semibold">{invoiceTypeLabel(first.proposed_invoice_type)}</p></div>
              <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">VAT code</p><p className="mt-1 text-xl font-semibold">{first.vat_code ?? "T0"}</p></div>
              <div className={`rounded-3xl border p-4 shadow-sm ${ready ? "border-emerald-200 bg-emerald-50" : "border-rose-200 bg-rose-50"}`}><p className="text-xs uppercase tracking-wide text-slate-500">Readiness</p><p className="mt-1 text-xl font-semibold">{ready ? "Ready" : "Blocked"}</p></div>
            </section>

            {blockers.length > 0 ? (
              <section className="rounded-3xl border border-rose-300 bg-rose-50 p-5 text-sm text-rose-900 shadow-sm">
                <h2 className="text-lg font-semibold">Blocked before invoice preview</h2>
                <ul className="mt-2 list-disc space-y-1 pl-5">
                  {blockers.map((blocker) => <li key={blocker}>{friendly(blocker)}</li>)}
                </ul>
              </section>
            ) : null}

            <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
              <h2 className="text-xl font-semibold">Draft customer document summary</h2>
              <p className="mt-2 text-sm leading-6 text-slate-600">This is the customer-facing invoice basis. The invoice payload uses the bundled charge; the split below is retained only for review evidence.</p>
              <div className="mt-4 grid gap-3 md:grid-cols-4">
                <div className="rounded-2xl bg-slate-50 p-4"><p className="text-xs font-semibold uppercase tracking-wide text-slate-500">Customer action</p><p className="mt-1 text-lg font-semibold">{invoiceTypeLabel(first.proposed_invoice_type)}</p></div>
                <div className="rounded-2xl bg-slate-50 p-4"><p className="text-xs font-semibold uppercase tracking-wide text-slate-500">Sanity: adjusted goods</p><p className="mt-1 text-lg font-semibold">{money(first.proposed_goods_amount_gbp)}</p></div>
                <div className="rounded-2xl bg-slate-50 p-4"><p className="text-xs font-semibold uppercase tracking-wide text-slate-500">Sanity: apportioned shipping</p><p className="mt-1 text-lg font-semibold">{money(first.proposed_shipping_amount_gbp)}</p></div>
                <div className="rounded-2xl border border-emerald-200 bg-emerald-50 p-4"><p className="text-xs font-semibold uppercase tracking-wide text-emerald-700">Bundled customer charge</p><p className="mt-1 text-lg font-semibold">{money(first.proposed_amount_gbp)}</p></div>
              </div>
              <div className="mt-4 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-700">
                <p><span className="font-semibold">Route:</span> {routeLabel(first.customer_recharge_route)}</p>
                <p className="mt-1"><span className="font-semibold">Sales invoice state:</span> {invoiceStateLabel(first.sales_invoice_state)}</p>
              </div>
            </section>

            <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
              <h2 className="text-xl font-semibold">Line-level customer invoice preview</h2>
              <p className="mt-2 text-sm leading-6 text-slate-600">The split is displayed for sanity checking only. The eventual customer invoice line is the bundled customer charge.</p>

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
                    <div className="mt-4 grid grid-cols-2 gap-2 text-sm">
                      <div className="rounded-xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Qty</p><p className="mt-1 font-semibold">{qty(row.qty_allocated)}</p></div>
                      <div className="rounded-xl border border-emerald-200 bg-emerald-50 p-3"><p className="text-xs uppercase tracking-wide text-emerald-700">Bundled charge</p><p className="mt-1 font-semibold">{money(row.total_line_amount_gbp)}</p></div>
                      <div className="rounded-xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Sanity goods</p><p className="mt-1 font-semibold">{money(row.goods_amount_gbp)}</p></div>
                      <div className="rounded-xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Sanity shipping</p><p className="mt-1 font-semibold">{money(row.shipping_amount_gbp)}</p></div>
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
                      <th className="px-3 py-2 text-right">Sanity goods</th>
                      <th className="px-3 py-2 text-right">Sanity shipping</th>
                      <th className="px-3 py-2 text-right">Bundled charge</th>
                      <th className="px-3 py-2 text-left">Status</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-slate-100 bg-white">
                    {rows.map((row, index) => (
                      <tr key={`${row.order_id}-${row.tracking_submission_id}-${row.supplier_invoice_line_id}-${index}`}>
                        <td className="px-3 py-3 align-top"><p className="font-semibold">{row.order_ref ?? row.order_id ?? "—"}</p><p className="text-xs text-slate-500">{row.tracking_ref ?? row.tracking_submission_id ?? "—"}</p></td>
                        <td className="px-3 py-3 align-top">{row.item_description ?? "—"}</td>
                        <td className="px-3 py-3 text-right align-top">{qty(row.qty_allocated)}</td>
                        <td className="px-3 py-3 text-right align-top">{money(row.goods_amount_gbp)}</td>
                        <td className="px-3 py-3 text-right align-top">{money(row.shipping_amount_gbp)}</td>
                        <td className="px-3 py-3 text-right align-top font-semibold">{money(row.total_line_amount_gbp)}</td>
                        <td className="px-3 py-3 align-top"><span className={`rounded-full px-2 py-1 text-xs font-semibold ${statusClass(row.readiness_status)}`}>{readinessLabel(row.readiness_status)}</span></td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </section>

            <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
              <h2 className="text-xl font-semibold">Bundled payload JSON preview</h2>
              <p className="mt-2 text-sm leading-6 text-slate-600">Read-only preview of the eventual sales_invoices.line_items_json shape. The split is deliberately excluded from this payload.</p>
              <pre className="mt-4 max-h-96 overflow-auto rounded-2xl bg-slate-950 p-4 text-xs leading-5 text-slate-100">{JSON.stringify(first.line_items_json ?? [], null, 2)}</pre>
            </section>

            <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm leading-6 text-amber-900">
              <h2 className="font-semibold">Control rule</h2>
              <p className="mt-2">This page only previews the customer invoice basis. It does not create a sales invoice, create a supplementary invoice, post to Sage, generate COS/BOL/POD, or clear VAT/export evidence.</p>
            </section>
          </>
        ) : null}
      </div>
    </main>
  );
}
