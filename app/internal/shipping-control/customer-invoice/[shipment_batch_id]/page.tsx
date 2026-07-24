import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type Row = {
  shipment_batch_id: string;
  booking_ref: string | null;
  importer_name: string | null;
  proposed_invoice_type: string | null;
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

type SalesInvoiceRow = {
  id: string;
  order_id: string;
  invoice_type: string | null;
  linked_invoice_id: string | null;
  amount_gbp: number | string | null;
  vat_code: string | null;
  line_items_json: unknown;
  sage_status: string | null;
  sage_invoice_id: string | null;
  sage_posted_at: string | null;
  created_at: string | null;
};

type ReleaseLineRow = {
  id: string;
  sales_invoice_id: string;
  sales_invoice_type: string;
  order_id: string;
  commercial_parent_order_id: string;
  source_shipment_batch_id: string | null;
  supplier_invoice_id: string;
  supplier_invoice_line_id: string;
  tracking_submission_id: string;
  tracking_line_allocation_id: string;
  released_qty: number | string;
  goods_amount_gbp: number | string;
  delivery_share_gbp: number | string;
  discount_share_gbp: number | string;
  shipping_amount_gbp: number | string;
  customer_charge_amount_gbp: number | string;
  release_status: string;
  membership_fingerprint: string;
  created_at: string;
};

type IdTextRow = { id: string; [key: string]: string | null };

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
  if (value === "supplementary") return "Create supplementary export sale invoice";
  return friendly(value);
}

function existingInvoiceTypeLabel(value: string | null | undefined) {
  if (value === "main") return "Main customer sales invoice";
  if (value === "supplementary") return "Supplementary customer sales invoice";
  if (value === "credit_note") return "Customer sales credit note";
  return friendly(value);
}

function routeLabel(value: string | null | undefined) {
  if (value === "include_shipping_in_main_sales_invoice_release") return "Add bundled export sale charge to main invoice draft/release";
  if (value === "supplementary_shipping_recharge_invoice") return "Create supplementary export sale invoice";
  if (value === "supplementary_shipping_recharge_invoice_review_required") return "Supplementary export sale invoice review required";
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
  if (value.startsWith("ready_")) return "Draft ready";
  if (value.startsWith("blocked")) return "Draft blocked";
  return friendly(value);
}

function statusClass(status: string | null | undefined) {
  if (!status) return "bg-slate-100 text-slate-700";
  if (status.startsWith("ready_") || status === "draft_preview") return "bg-emerald-100 text-emerald-800";
  if (status.startsWith("blocked") || status.includes("missing")) return "bg-rose-100 text-rose-800";
  return "bg-amber-100 text-amber-800";
}

function invoiceLifecycleLabel(invoice: SalesInvoiceRow) {
  if (invoice.sage_status === "posted" && invoice.sage_invoice_id && invoice.sage_posted_at) return "Posted with Sage confirmation";
  if (invoice.sage_status === "posted") return "Internally marked posted — no Sage confirmation";
  if (invoice.sage_status === "void") return "Void";
  return "Draft — ready for Sage posting preview";
}

function invoiceLifecycleClass(invoice: SalesInvoiceRow) {
  if (invoice.sage_status === "void") return "border-slate-300 bg-slate-100 text-slate-800";
  if (invoice.sage_status === "posted" && invoice.sage_invoice_id && invoice.sage_posted_at) return "border-sky-200 bg-sky-50 text-sky-900";
  if (invoice.sage_status === "posted") return "border-amber-200 bg-amber-50 text-amber-900";
  return "border-emerald-200 bg-emerald-50 text-emerald-900";
}

function unique(values: Array<string | null | undefined>) {
  return Array.from(new Set(values.filter((value): value is string => Boolean(value))));
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

  // Mini-build 3 lifecycle adaptation:
  // this route remains the existing pre-draft preview while no release exists.
  // Once a draft has been created, the durable release ledger—not the now-zero
  // remaining-source preview—is the authoritative detail source.
  const { data: routeMembershipData, error: routeMembershipError } = await (supabase as any)
    .from("customer_sales_release_lines")
    .select("sales_invoice_id")
    .eq("source_shipment_batch_id", shipmentBatchId)
    .eq("release_status", "active");

  const salesInvoiceIds = unique(((routeMembershipData ?? []) as Array<{ sales_invoice_id: string | null }>).map((row) => row.sales_invoice_id));

  if (salesInvoiceIds.length > 0) {
    const [invoiceResult, releaseResult] = await Promise.all([
      (supabase as any)
        .from("sales_invoices")
        .select("id, order_id, invoice_type, linked_invoice_id, amount_gbp, vat_code, line_items_json, sage_status, sage_invoice_id, sage_posted_at, created_at")
        .in("id", salesInvoiceIds)
        .order("created_at", { ascending: true }),
      (supabase as any)
        .from("customer_sales_release_lines")
        .select("id, sales_invoice_id, sales_invoice_type, order_id, commercial_parent_order_id, source_shipment_batch_id, supplier_invoice_id, supplier_invoice_line_id, tracking_submission_id, tracking_line_allocation_id, released_qty, goods_amount_gbp, delivery_share_gbp, discount_share_gbp, shipping_amount_gbp, customer_charge_amount_gbp, release_status, membership_fingerprint, created_at")
        .in("sales_invoice_id", salesInvoiceIds)
        .eq("release_status", "active")
        .order("created_at", { ascending: true }),
    ]);

    const invoices = (invoiceResult.data ?? []) as SalesInvoiceRow[];
    const releaseLines = (releaseResult.data ?? []) as ReleaseLineRow[];
    const lineIds = unique(releaseLines.map((line) => line.supplier_invoice_line_id));
    const trackingIds = unique(releaseLines.map((line) => line.tracking_submission_id));
    const orderIds = unique(releaseLines.flatMap((line) => [line.order_id, line.commercial_parent_order_id]));
    const batchIds = unique(releaseLines.map((line) => line.source_shipment_batch_id));

    const [lineResult, trackingResult, orderResult, batchResult] = await Promise.all([
      lineIds.length > 0
        ? (supabase as any).from("supplier_invoice_lines").select("id, description").in("id", lineIds)
        : Promise.resolve({ data: [], error: null }),
      trackingIds.length > 0
        ? (supabase as any).from("order_tracking_submissions").select("id, tracking_ref").in("id", trackingIds)
        : Promise.resolve({ data: [], error: null }),
      orderIds.length > 0
        ? (supabase as any).from("orders").select("id, order_ref").in("id", orderIds)
        : Promise.resolve({ data: [], error: null }),
      batchIds.length > 0
        ? (supabase as any).from("shipper_shipment_batches").select("id, booking_ref").in("id", batchIds)
        : Promise.resolve({ data: [], error: null }),
    ]);

    const descriptionByLine = new Map(((lineResult.data ?? []) as IdTextRow[]).map((row) => [row.id, row.description ?? "Goods"]));
    const trackingById = new Map(((trackingResult.data ?? []) as IdTextRow[]).map((row) => [row.id, row.tracking_ref ?? row.id]));
    const orderById = new Map(((orderResult.data ?? []) as IdTextRow[]).map((row) => [row.id, row.order_ref ?? row.id]));
    const bookingByBatch = new Map(((batchResult.data ?? []) as IdTextRow[]).map((row) => [row.id, row.booking_ref ?? row.id]));

    const detailErrors = [
      routeMembershipError?.message,
      invoiceResult.error?.message,
      releaseResult.error?.message,
      lineResult.error?.message,
      trackingResult.error?.message,
      orderResult.error?.message,
      batchResult.error?.message,
    ].filter(Boolean) as string[];

    return (
      <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
        <div className="mx-auto max-w-7xl space-y-6">
          <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
            <div className="flex flex-wrap gap-3 text-sm font-semibold text-sky-700">
              <Link href="/internal/shipping-control">← Shipping control</Link>
              <Link href="/internal/shipping-control/customer-invoice-release">Customer invoice release queue</Link>
              <Link href="/internal/sage-ready">Ready for Sage</Link>
            </div>
            <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Goodcashback Internal</p>
            <div className="mt-2 flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
              <div>
                <h1 className="text-2xl font-semibold tracking-tight sm:text-3xl">Customer sales invoice detail</h1>
                <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">
                  Existing customer document and its durable exact Mini-build 3 release membership. The document amount and line detail below come from the created sales invoice and customer sales release ledger; this page does not reconstruct released value from the remaining-source preview.
                </p>
              </div>
              <div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700"><div className="font-medium text-slate-950">{staff.full_name}</div><div>{staff.role_type}</div></div>
            </div>
            {detailErrors.length > 0 ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">Some supporting labels could not be loaded: {detailErrors.join(" · ")}</p> : null}
          </section>

          {invoices.length === 0 ? (
            <section className="rounded-3xl border border-rose-300 bg-rose-50 p-5 text-sm text-rose-900 shadow-sm">
              Durable release membership exists for this booking, but the linked sales invoice could not be read. No zero-value preview has been substituted.
            </section>
          ) : null}

          {invoices.map((invoice) => {
            const invoiceLines = releaseLines.filter((line) => line.sales_invoice_id === invoice.id);
            const ledgerTotal = invoiceLines.reduce((sum, line) => sum + n(line.customer_charge_amount_gbp), 0);
            const goodsTotal = invoiceLines.reduce((sum, line) => sum + n(line.goods_amount_gbp), 0);
            const shippingTotal = invoiceLines.reduce((sum, line) => sum + n(line.shipping_amount_gbp), 0);
            const deliveryTotal = invoiceLines.reduce((sum, line) => sum + n(line.delivery_share_gbp), 0);
            const discountTotal = invoiceLines.reduce((sum, line) => sum + n(line.discount_share_gbp), 0);
            const balanced = Math.abs(ledgerTotal - n(invoice.amount_gbp)) <= 0.02;
            const bookingRefs = unique(invoiceLines.map((line) => line.source_shipment_batch_id ? bookingByBatch.get(line.source_shipment_batch_id) ?? line.source_shipment_batch_id : null));

            return (
              <section key={invoice.id} className="space-y-6">
                <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
                  <div className="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
                    <div>
                      <p className="text-xs font-semibold uppercase tracking-wide text-slate-500">{existingInvoiceTypeLabel(invoice.invoice_type)}</p>
                      <h2 className="mt-1 text-2xl font-semibold">{orderById.get(invoice.order_id) ?? invoice.order_id}</h2>
                      <p className="mt-1 text-sm text-slate-600">Bookings: {bookingRefs.join(", ") || shipmentBatchId}</p>
                    </div>
                    <span className={`rounded-full border px-3 py-2 text-xs font-semibold ${invoiceLifecycleClass(invoice)}`}>{invoiceLifecycleLabel(invoice)}</span>
                  </div>

                  <div className="mt-5 grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
                    <div className="rounded-2xl border border-emerald-200 bg-emerald-50 p-4"><p className="text-xs font-semibold uppercase tracking-wide text-emerald-700">Invoice amount</p><p className="mt-1 text-xl font-semibold">{money(invoice.amount_gbp)}</p></div>
                    <div className={`rounded-2xl border p-4 ${balanced ? "border-emerald-200 bg-emerald-50" : "border-rose-200 bg-rose-50"}`}><p className="text-xs font-semibold uppercase tracking-wide text-slate-500">Ledger membership total</p><p className="mt-1 text-xl font-semibold">{money(ledgerTotal)}</p><p className="mt-1 text-xs text-slate-600">{balanced ? "Matches invoice" : "Mismatch — blocked for investigation"}</p></div>
                    <div className="rounded-2xl bg-slate-50 p-4"><p className="text-xs font-semibold uppercase tracking-wide text-slate-500">Adjusted goods</p><p className="mt-1 text-xl font-semibold">{money(goodsTotal)}</p></div>
                    <div className="rounded-2xl bg-slate-50 p-4"><p className="text-xs font-semibold uppercase tracking-wide text-slate-500">Apportioned shipping</p><p className="mt-1 text-xl font-semibold">{money(shippingTotal)}</p></div>
                    <div className="rounded-2xl bg-slate-50 p-4"><p className="text-xs font-semibold uppercase tracking-wide text-slate-500">Exact release lines</p><p className="mt-1 text-xl font-semibold">{invoiceLines.length}</p></div>
                  </div>

                  <div className="mt-4 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-700">
                    <p><span className="font-semibold">VAT code:</span> {invoice.vat_code ?? "T0 / GB_ZERO"}</p>
                    <p className="mt-1"><span className="font-semibold">Retailer adjustment evidence:</span> delivery {money(deliveryTotal)} · discount −{money(discountTotal)}</p>
                    <p className="mt-1 break-all text-xs text-slate-500"><span className="font-semibold">Sales invoice ID:</span> {invoice.id}</p>
                    {invoice.linked_invoice_id ? <p className="mt-1 break-all text-xs text-slate-500"><span className="font-semibold">Linked main invoice:</span> {invoice.linked_invoice_id}</p> : null}
                  </div>
                </section>

                <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
                  <h2 className="text-xl font-semibold">Durable line-level release membership</h2>
                  <p className="mt-2 text-sm leading-6 text-slate-600">These are the exact source quantities and values frozen when the customer document was created. A draft-existing state is therefore a completed release step, not a blocker or a zero-value supplementary preview.</p>

                  <div className="mt-4 grid gap-3 md:hidden">
                    {invoiceLines.map((line) => (
                      <article key={line.id} className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
                        <div className="flex items-start justify-between gap-3">
                          <div>
                            <p className="text-xs font-semibold uppercase tracking-wide text-slate-500">Order / booking</p>
                            <p className="mt-1 font-semibold">{orderById.get(line.order_id) ?? line.order_id}</p>
                            <p className="text-sm text-slate-500">{line.source_shipment_batch_id ? bookingByBatch.get(line.source_shipment_batch_id) ?? line.source_shipment_batch_id : "—"} · {trackingById.get(line.tracking_submission_id) ?? line.tracking_submission_id}</p>
                          </div>
                          <span className="shrink-0 rounded-full bg-emerald-100 px-2 py-1 text-xs font-semibold text-emerald-800">Released in document</span>
                        </div>
                        <p className="mt-3 text-sm text-slate-700">{descriptionByLine.get(line.supplier_invoice_line_id) ?? "Goods"}</p>
                        <div className="mt-4 grid grid-cols-2 gap-2 text-sm">
                          <div className="rounded-xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Qty</p><p className="mt-1 font-semibold">{qty(line.released_qty)}</p></div>
                          <div className="rounded-xl border border-emerald-200 bg-emerald-50 p-3"><p className="text-xs uppercase tracking-wide text-emerald-700">Bundled charge</p><p className="mt-1 font-semibold">{money(line.customer_charge_amount_gbp)}</p></div>
                          <div className="rounded-xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Adjusted goods</p><p className="mt-1 font-semibold">{money(line.goods_amount_gbp)}</p></div>
                          <div className="rounded-xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Shipping</p><p className="mt-1 font-semibold">{money(line.shipping_amount_gbp)}</p></div>
                        </div>
                        <p className="mt-3 text-xs text-slate-500">Delivery share {money(line.delivery_share_gbp)} · discount share −{money(line.discount_share_gbp)}</p>
                      </article>
                    ))}
                  </div>

                  <div className="mt-4 hidden overflow-x-auto rounded-2xl border border-slate-200 md:block">
                    <table className="min-w-full divide-y divide-slate-200 text-sm">
                      <thead className="bg-slate-100 text-xs uppercase tracking-wide text-slate-500">
                        <tr>
                          <th className="px-3 py-2 text-left">Order / booking / tracking</th>
                          <th className="px-3 py-2 text-left">Description</th>
                          <th className="px-3 py-2 text-right">Qty</th>
                          <th className="px-3 py-2 text-right">Adjusted goods</th>
                          <th className="px-3 py-2 text-right">Shipping</th>
                          <th className="px-3 py-2 text-right">Bundled charge</th>
                          <th className="px-3 py-2 text-left">Status</th>
                        </tr>
                      </thead>
                      <tbody className="divide-y divide-slate-100 bg-white">
                        {invoiceLines.map((line) => (
                          <tr key={line.id}>
                            <td className="px-3 py-3 align-top"><p className="font-semibold">{orderById.get(line.order_id) ?? line.order_id}</p><p className="text-xs text-slate-500">{line.source_shipment_batch_id ? bookingByBatch.get(line.source_shipment_batch_id) ?? line.source_shipment_batch_id : "—"} · {trackingById.get(line.tracking_submission_id) ?? line.tracking_submission_id}</p></td>
                            <td className="px-3 py-3 align-top"><p>{descriptionByLine.get(line.supplier_invoice_line_id) ?? "Goods"}</p><p className="mt-1 text-xs text-slate-500">Delivery {money(line.delivery_share_gbp)} · discount −{money(line.discount_share_gbp)}</p></td>
                            <td className="px-3 py-3 text-right align-top">{qty(line.released_qty)}</td>
                            <td className="px-3 py-3 text-right align-top">{money(line.goods_amount_gbp)}</td>
                            <td className="px-3 py-3 text-right align-top">{money(line.shipping_amount_gbp)}</td>
                            <td className="px-3 py-3 text-right align-top font-semibold">{money(line.customer_charge_amount_gbp)}</td>
                            <td className="px-3 py-3 align-top"><span className="rounded-full bg-emerald-100 px-2 py-1 text-xs font-semibold text-emerald-800">Released in document</span></td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                </section>

                <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
                  <h2 className="text-xl font-semibold">Created customer document payload</h2>
                  <p className="mt-2 text-sm leading-6 text-slate-600">Read-only mirror retained for Sage payload compatibility and display. The durable release ledger above remains authoritative for source membership.</p>
                  <pre className="mt-4 max-h-96 overflow-auto rounded-2xl bg-slate-950 p-4 text-xs leading-5 text-slate-100">{JSON.stringify(invoice.line_items_json ?? [], null, 2)}</pre>
                </section>
              </section>
            );
          })}

          <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm leading-6 text-amber-900">
            <h2 className="font-semibold">Control rule</h2>
            <p className="mt-2">This page is read-only. It does not create another main or supplementary invoice, change release membership, post to Sage, generate COS/BOL/POD, or clear VAT/export evidence.</p>
          </section>
        </div>
      </main>
    );
  }

  const blockers = Array.from(new Set(rows.map((row) => row.blocker).filter(Boolean))) as string[];
  const ready = rows.length > 0 && blockers.length === 0;

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-7xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-wrap gap-3 text-sm font-semibold text-sky-700">
            <Link href="/internal/shipping-control">← Shipping control</Link>
            <Link href={`/internal/shipping-control/readiness/${shipmentBatchId}`}>AP / sale preview</Link>
          </div>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Goodcashback Internal</p>
          <div className="mt-2 flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
            <div>
              <h1 className="text-2xl font-semibold tracking-tight sm:text-3xl">Customer invoice readiness preview</h1>
              <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">
                Read-only preview of what the later customer invoice creation lane should prepare. This is draft readiness, not Sage posting readiness. Sage mapping is checked separately in the Ready for Sage queue. The customer payload is an export sale charge; the adjusted goods/shipping split is shown only as a sanity check.
              </p>
            </div>
            <div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700"><div className="font-medium text-slate-950">{staff.full_name}</div><div>{staff.role_type}</div></div>
          </div>
          {error ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">{error.message}</p> : null}
          {routeMembershipError ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">Existing release membership could not be checked: {routeMembershipError.message}</p> : null}
          {!first && !error ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">No customer invoice readiness rows found.</p> : null}
        </section>

        {first ? (
          <>
            <section className="grid gap-4 md:grid-cols-5">
              <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Booking ref</p><p className="mt-1 text-xl font-semibold">{first.booking_ref ?? shipmentBatchId}</p></div>
              <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Importer</p><p className="mt-1 text-xl font-semibold">{first.importer_name ?? "—"}</p></div>
              <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Customer action</p><p className="mt-1 text-xl font-semibold">{invoiceTypeLabel(first.proposed_invoice_type)}</p></div>
              <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">VAT code</p><p className="mt-1 text-xl font-semibold">{first.vat_code ?? "T0"}</p></div>
              <div className={`rounded-3xl border p-4 shadow-sm ${ready ? "border-emerald-200 bg-emerald-50" : "border-rose-200 bg-rose-50"}`}><p className="text-xs uppercase tracking-wide text-slate-500">Draft readiness</p><p className="mt-1 text-xl font-semibold">{ready ? "Draft ready" : "Draft blocked"}</p><p className="mt-1 text-xs text-slate-500">Sage mapping is checked in Ready for Sage.</p></div>
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
              <p className="mt-2 text-sm leading-6 text-slate-600">The split is displayed for sanity checking only. The eventual customer invoice line is the bundled export sale charge.</p>

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
                      <th className="px-3 py-2 text-left">Description</th>
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
