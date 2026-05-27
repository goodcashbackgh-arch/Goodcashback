import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type BatchDetailRow = {
  shipment_batch_id: string;
  booking_ref: string | null;
  batch_status: string | null;
  shipper_id: string;
  shipper_name: string | null;
  importer_id: string;
  importer_name: string | null;
  shipment_cutoff_at: string | null;
  dispatched_at: string | null;
  box_count: number | string | null;
  batch_notes: string | null;
  package_link_id: string | null;
  tracking_submission_id: string | null;
  order_id: string | null;
  order_ref: string | null;
  retailer_name: string | null;
  courier_name: string | null;
  tracking_ref: string | null;
  tracking_date: string | null;
  allocated_qty: number | string | null;
  allocation_status_summary: string | null;
  latest_receipt_status: string | null;
};

type CustomerPreviewRow = {
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

type ShippingApPreviewRow = {
  readiness_status: string | null;
  blocker: string | null;
  shipping_document_ref: string | null;
  shipping_document_review_status: string | null;
  shipping_apportionment_status: string | null;
  allocated_shipping_amount: number | string | null;
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

function shortDate(value: string | null | undefined) {
  if (!value) return "—";
  return value.includes("T") ? value.slice(0, 10) : value;
}

function friendly(value: string | null | undefined) {
  if (!value) return "—";
  return value.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase());
}

function statusClass(status: string | null | undefined) {
  if (!status) return "bg-slate-100 text-slate-700";
  if (status.startsWith("ready") || ["received_clean", "contents_allocated", "accepted_current", "approved"].includes(status)) return "bg-emerald-100 text-emerald-800";
  if (status.startsWith("blocked") || status.includes("missing") || status.includes("issue")) return "bg-rose-100 text-rose-800";
  return "bg-amber-100 text-amber-800";
}

function cleanGoodsDescription(value: string | null | undefined) {
  const raw = (value ?? "").trim();
  if (!raw) return "Assorted retail goods";
  return raw
    .replace(/^export\s+sale\s*-\s*/i, "")
    .replace(/\s*-\s*ord[-\s_]*[a-z0-9-]+\s*$/i, "")
    .replace(/\s*-\s*ord[-\s_]*[a-z0-9-]+\s*-\s*booking\s+[a-z0-9-]+\s*$/i, "")
    .replace(/\s*-\s*booking\s+[a-z0-9-]+\s*$/i, "")
    .replace(/\s+/g, " ")
    .trim() || "Assorted retail goods";
}

function traceSku(index: number) {
  return `EEP-L${String(index + 1).padStart(3, "0")}`;
}

export default async function DraftCosExportEvidencePage({ params }: { params: Promise<{ shipment_batch_id: string }> }) {
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

  const [batchResult, customerPreviewResult, apPreviewResult] = await Promise.all([
    (supabase as any).rpc("internal_shipping_batch_detail_v1", { p_shipment_batch_id: shipmentBatchId }),
    (supabase as any).rpc("internal_shipping_customer_invoice_readiness_preview_v1", { p_shipment_batch_id: shipmentBatchId }),
    (supabase as any).rpc("internal_shipping_ap_recharge_readiness_preview_v1", { p_shipment_batch_id: shipmentBatchId }),
  ]);

  const batchRows = ((batchResult.data ?? []) as BatchDetailRow[]);
  const customerRows = ((customerPreviewResult.data ?? []) as CustomerPreviewRow[]);
  const apRows = ((apPreviewResult.data ?? []) as ShippingApPreviewRow[]);
  const firstBatch = batchRows[0] ?? null;
  const firstCustomer = customerRows[0] ?? null;
  const packageRows = batchRows.filter((row) => row.package_link_id);
  const eepRef = `EEP-${(firstBatch?.booking_ref ?? shipmentBatchId).replace(/[^a-z0-9-]/gi, "").slice(0, 24)}`;
  const totalPackages = n(firstBatch?.box_count) || packageRows.length;
  const totalQty = customerRows.reduce((sum, row) => sum + n(row.qty_allocated), 0);
  const totalGoodsValue = customerRows.reduce((sum, row) => sum + n(row.goods_amount_gbp), 0);
  const totalCustomerCharge = customerRows.reduce((sum, row) => sum + n(row.total_line_amount_gbp), 0);
  const totalShipping = customerRows.reduce((sum, row) => sum + n(row.shipping_amount_gbp), 0);
  const apBlockers = Array.from(new Set(apRows.map((row) => row.blocker).filter(Boolean))) as string[];
  const customerBlockers = Array.from(new Set(customerRows.map((row) => row.blocker).filter(Boolean))) as string[];
  const missingReceiptRows = packageRows.filter((row) => row.latest_receipt_status && row.latest_receipt_status !== "received_clean");

  const blockers = [
    packageRows.length === 0 ? "no_packages_selected_into_shipment_batch" : null,
    customerRows.length === 0 ? "no_customer_invoice_basis_or_delivery_allocation_lines" : null,
    totalQty <= 0 ? "no_allocated_quantity" : null,
    totalGoodsValue <= 0 ? "missing_adjusted_goods_value" : null,
    ...customerBlockers,
    missingReceiptRows.length > 0 ? "receipt_issue_or_non_clean_package_in_batch" : null,
  ].filter(Boolean) as string[];

  const warnings = [
    ...apBlockers.map((blocker) => `shipping_apportionment: ${blocker}`),
    "final COS / MBL / container / seal / export date will be completed and uploaded by shipper",
  ];

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-7xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-wrap gap-3 text-sm font-semibold text-sky-700">
            <Link href="/internal/shipping-control">← Shipping control</Link>
            <Link href={`/internal/shipping-control/${shipmentBatchId}`}>Batch detail</Link>
            <Link href={`/internal/shipping-control/readiness/${shipmentBatchId}`}>Readiness / route preview</Link>
          </div>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Goodcashback Internal</p>
          <div className="mt-2 flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
            <div>
              <h1 className="text-2xl font-semibold tracking-tight sm:text-3xl">Draft COS / Export Evidence Pack review</h1>
              <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">
                Read-only first pass. GCB prepares a draft Certificate of Shipment plus an EEP / packing list. The shipper enters final shipment facts on the shipper side, downloads the draft in their letterhead/template format, signs/stamps/authenticates it, and uploads the final COS/export evidence. Supervisors can view and download the final pack once uploaded.
              </p>
            </div>
            <div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700"><div className="font-medium text-slate-950">{(staff as any).full_name}</div><div>{(staff as any).role_type}</div></div>
          </div>
          {batchResult.error ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">Batch detail unavailable: {batchResult.error.message}</p> : null}
          {customerPreviewResult.error ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">Customer invoice basis unavailable: {customerPreviewResult.error.message}</p> : null}
          {apPreviewResult.error ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">Shipping apportionment preview unavailable: {apPreviewResult.error.message}</p> : null}
        </section>

        <section className="grid gap-4 md:grid-cols-5">
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">EEP ref</p><p className="mt-1 text-xl font-semibold">{eepRef}</p></div>
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Packages / boxes</p><p className="mt-1 text-xl font-semibold">{totalPackages || "—"}</p></div>
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Allocated qty</p><p className="mt-1 text-xl font-semibold">{qty(totalQty)}</p></div>
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Goods export value</p><p className="mt-1 text-xl font-semibold">{money(totalGoodsValue)}</p></div>
          <div className={`rounded-3xl border p-4 shadow-sm ${blockers.length === 0 ? "border-emerald-200 bg-emerald-50" : "border-rose-200 bg-rose-50"}`}><p className="text-xs uppercase tracking-wide text-slate-500">Draft pack</p><p className="mt-1 text-xl font-semibold">{blockers.length === 0 ? "Ready" : "Blocked"}</p></div>
        </section>

        {blockers.length > 0 ? (
          <section className="rounded-3xl border border-rose-300 bg-rose-50 p-5 text-sm text-rose-900 shadow-sm">
            <h2 className="text-lg font-semibold">Blockers before draft COS / EEP pack</h2>
            <ul className="mt-2 list-disc space-y-1 pl-5">
              {blockers.map((blocker) => <li key={blocker}>{friendly(blocker)}</li>)}
            </ul>
          </section>
        ) : null}

        <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm leading-6 text-amber-900 shadow-sm">
          <h2 className="font-semibold">Final evidence remains shipper-side</h2>
          <p className="mt-2">The shipper enters MBL/BOL, container, seal, vessel/route, ports, export date and final package confirmation on the shipper side, then downloads the draft in their letterhead/template format and uploads the signed/stamped COS plus final export evidence. Accepted upload types: completed COS, final EEP / packing list if amended, MBL/BOL/sea waybill, container/seal evidence, and export date/departure evidence. Supervisor access is view/download only after upload.</p>
          <div className="mt-4 flex flex-wrap gap-3">
            <button disabled className="rounded-xl border border-slate-300 bg-white px-4 py-2 text-sm font-semibold text-slate-500">Download draft COS + EEP pack — next</button>
            <button disabled className="rounded-xl border border-slate-300 bg-white px-4 py-2 text-sm font-semibold text-slate-500">Upload completed COS / final export evidence — shipper side next</button>
          </div>
        </section>

        <section className="grid gap-4 lg:grid-cols-2">
          <article className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
            <h2 className="text-xl font-semibold">Draft COS header preview</h2>
            <div className="mt-4 grid gap-3 text-sm md:grid-cols-2">
              <div className="rounded-2xl bg-slate-50 p-3"><span className="text-slate-500">Exporter / supplier</span><p className="font-semibold">Goodcashback / tenant exporter</p><p className="text-xs text-slate-500">Dummy UK address · Dummy VAT number</p></div>
              <div className="rounded-2xl bg-slate-50 p-3"><span className="text-slate-500">Freight forwarder / packer</span><p className="font-semibold">{firstBatch?.shipper_name ?? "Shipper to complete"}</p></div>
              <div className="rounded-2xl bg-slate-50 p-3"><span className="text-slate-500">Consignee</span><p className="font-semibold">Ghana jurisdiction hub / tenant destination hub</p><p className="text-xs text-slate-500">Dummy Ghana address</p></div>
              <div className="rounded-2xl bg-slate-50 p-3"><span className="text-slate-500">Customer reference</span><p className="font-semibold">{firstBatch?.booking_ref ?? shipmentBatchId}</p></div>
              <div className="rounded-2xl bg-slate-50 p-3"><span className="text-slate-500">Description</span><p className="font-semibold">Assorted retail consumer goods as per attached {eepRef}</p></div>
              <div className="rounded-2xl bg-slate-50 p-3"><span className="text-slate-500">Destination</span><p className="font-semibold">Ghana / destination hub</p></div>
            </div>
          </article>

          <article className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
            <h2 className="text-xl font-semibold">Shipper-completed fields</h2>
            <div className="mt-4 grid gap-2 text-sm md:grid-cols-2">
              {["MBL / BOL / sea waybill", "Container number", "Seal number", "Vessel / voyage", "Port of loading", "Port of discharge", "Place of delivery", "Date of export / shipment", "Final package confirmation", "Authorised name / signature / stamp"].map((field) => (
                <div key={field} className="rounded-2xl border border-dashed border-slate-300 bg-slate-50 p-3 text-slate-600">{field}</div>
              ))}
            </div>
          </article>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <h2 className="text-xl font-semibold">EEP / packing list line preview</h2>
          <p className="mt-2 text-sm leading-6 text-slate-600">Detailed goods schedule. The short COS references this frozen EEP instead of carrying every line on the certificate itself.</p>
          <div className="mt-4 overflow-x-auto rounded-2xl border border-slate-200">
            <table className="min-w-full divide-y divide-slate-200 text-sm">
              <thead className="bg-slate-100 text-xs uppercase tracking-wide text-slate-500">
                <tr>
                  <th className="px-3 py-2 text-left">Customer</th>
                  <th className="px-3 py-2 text-left">Sage A/C ref</th>
                  <th className="px-3 py-2 text-left">Sales invoice ref</th>
                  <th className="px-3 py-2 text-left">Order</th>
                  <th className="px-3 py-2 text-left">Supplier invoice ref</th>
                  <th className="px-3 py-2 text-left">Trace SKU</th>
                  <th className="px-3 py-2 text-left">Description</th>
                  <th className="px-3 py-2 text-right">Qty</th>
                  <th className="px-3 py-2 text-right">Unit export value</th>
                  <th className="px-3 py-2 text-right">Total export value</th>
                  <th className="px-3 py-2 text-left">Package / box</th>
                  <th className="px-3 py-2 text-left">Destination</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100 bg-white">
                {customerRows.length === 0 ? (
                  <tr><td colSpan={12} className="px-3 py-4 text-slate-600">No delivery allocation/customer invoice basis rows found for this shipment batch.</td></tr>
                ) : customerRows.map((row, index) => {
                  const rowQty = n(row.qty_allocated);
                  const rowGoodsValue = n(row.goods_amount_gbp);
                  const unitValue = rowQty > 0 ? rowGoodsValue / rowQty : 0;
                  const description = cleanGoodsDescription(row.item_description);
                  return (
                    <tr key={`${row.order_id}-${row.tracking_submission_id}-${row.supplier_invoice_line_id}-${index}`}>
                      <td className="px-3 py-2 font-semibold">{firstCustomer?.importer_name ?? firstBatch?.importer_name ?? "Customer"}</td>
                      <td className="px-3 py-2 text-slate-500">Pending Sage A/C ref</td>
                      <td className="px-3 py-2 text-slate-500">Pending sales invoice ref</td>
                      <td className="px-3 py-2">{row.order_ref ?? row.order_id ?? "—"}</td>
                      <td className="px-3 py-2 text-slate-500">Pending supplier invoice ref</td>
                      <td className="px-3 py-2 font-mono text-xs">{traceSku(index)}</td>
                      <td className="px-3 py-2">{description}</td>
                      <td className="px-3 py-2 text-right font-semibold">{qty(row.qty_allocated)}</td>
                      <td className="px-3 py-2 text-right">{money(unitValue)}</td>
                      <td className="px-3 py-2 text-right font-semibold">{money(row.goods_amount_gbp)}</td>
                      <td className="px-3 py-2">{row.tracking_ref ?? row.tracking_submission_id ?? "Batch package"}</td>
                      <td className="px-3 py-2">Ghana</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <h2 className="text-xl font-semibold">Customer invoice and shipping sanity</h2>
          <div className="mt-4 grid gap-3 md:grid-cols-4">
            <div className="rounded-2xl bg-slate-50 p-4"><p className="text-xs uppercase tracking-wide text-slate-500">Customer invoice route</p><p className="mt-1 font-semibold">{friendly(firstCustomer?.customer_recharge_route)}</p></div>
            <div className="rounded-2xl bg-slate-50 p-4"><p className="text-xs uppercase tracking-wide text-slate-500">Goods value</p><p className="mt-1 font-semibold">{money(totalGoodsValue)}</p></div>
            <div className="rounded-2xl bg-slate-50 p-4"><p className="text-xs uppercase tracking-wide text-slate-500">Apportioned shipping</p><p className="mt-1 font-semibold">{money(totalShipping)}</p></div>
            <div className="rounded-2xl bg-slate-50 p-4"><p className="text-xs uppercase tracking-wide text-slate-500">Customer charge</p><p className="mt-1 font-semibold">{money(totalCustomerCharge)}</p></div>
          </div>
          <div className="mt-4 flex flex-wrap gap-2">
            {warnings.map((warning) => <span key={warning} className={`rounded-full px-3 py-1 text-xs font-semibold ${statusClass(warning.includes(": null") ? null : warning)}`}>{warning}</span>)}
          </div>
        </section>
      </div>
    </main>
  );
}
