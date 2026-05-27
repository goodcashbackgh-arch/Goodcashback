import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type BatchDetailRow = {
  booking_ref: string | null;
  box_count: number | string | null;
  package_link_id: string | null;
  latest_receipt_status: string | null;
};

type CompletionFieldsRow = {
  mbl_bol_sea_waybill_ref: string | null;
  container_number: string | null;
  seal_number: string | null;
  vessel_voyage: string | null;
  port_of_loading: string | null;
  port_of_discharge: string | null;
  place_of_delivery: string | null;
  export_shipment_date: string | null;
  final_package_confirmation: string | null;
  authorised_name: string | null;
  signature_stamp_confirmation_yn: boolean | null;
  completion_status: string | null;
};

type ExportEvidencePackRow = {
  booking_ref: string | null;
  eep_ref: string | null;
  shipper_name: string | null;
  customer_name: string | null;
  package_box_ref: string | null;
  total_boxes: number | string | null;
  mbl_bol_sea_waybill_ref: string | null;
  container_number: string | null;
  seal_number: string | null;
  vessel_voyage: string | null;
  port_of_loading: string | null;
  port_of_discharge: string | null;
  place_of_delivery: string | null;
  export_shipment_date: string | null;
  final_package_confirmation: string | null;
  authorised_name: string | null;
  signature_stamp_confirmation_yn: boolean | null;
  completion_status: string | null;
  order_id: string | null;
  order_ref: string | null;
  sales_invoice_ref: string | null;
  supplier_invoice_ref: string | null;
  supplier_invoice_line_id: string | null;
  item_description: string | null;
  qty_allocated: number | string | null;
  unit_export_value_gbp: number | string | null;
  total_export_value_gbp: number | string | null;
  destination: string | null;
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

function cleanDescription(value: string | null | undefined) {
  return (value ?? "Assorted retail goods")
    .replace(/^export\s+sale\s*-\s*/i, "")
    .replace(/^export\s+sale\s+goods\s+charge\s*-\s*/i, "")
    .replace(/^supplementary\s+export\s+sale\s+shipping\s+charge\s*-\s*/i, "")
    .replace(/\s*-\s*ord[-\s_]*[a-z0-9-]+\s*$/i, "")
    .replace(/\s*-\s*ord[-\s_]*[a-z0-9-]+\s*-\s*booking\s+[a-z0-9-]+\s*$/i, "")
    .replace(/\s*-\s*booking\s+[a-z0-9-]+\s*$/i, "")
    .replace(/\s+/g, " ")
    .trim() || "Assorted retail goods";
}

function last3(value: string | null | undefined) {
  const compact = (value ?? "").replace(/[^a-z0-9]/gi, "");
  return compact.length <= 3 ? compact || "REF" : compact.slice(-3);
}

function traceSku(row: ExportEvidencePackRow) {
  return `${last3(row.order_ref ?? row.order_id)}/${last3(row.supplier_invoice_ref ?? row.supplier_invoice_line_id)}`;
}

function statusPill(status: string | null | undefined) {
  const value = status ?? "completion_fields_draft";
  const ok = ["completion_fields_ready", "accepted_current", "approved"].includes(value);
  return <span className={`rounded-full px-3 py-1 text-xs font-semibold ${ok ? "bg-emerald-100 text-emerald-800" : "bg-amber-100 text-amber-800"}`}>{friendly(value)}</span>;
}

function fieldValue(value: string | boolean | null | undefined) {
  if (typeof value === "boolean") return value ? "Confirmed" : "Not confirmed";
  return value && value.trim() ? value : "Not entered";
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

  const [batchResult, completionResult, packResult] = await Promise.all([
    (supabase as any).rpc("internal_shipping_batch_detail_v1", { p_shipment_batch_id: shipmentBatchId }),
    (supabase as any).rpc("internal_shipment_export_evidence_completion_fields_v1", { p_shipment_batch_id: shipmentBatchId }),
    (supabase as any).rpc("shipper_export_evidence_pack_preview_v1", { p_shipment_batch_id: shipmentBatchId }),
  ]);

  const batchRows = (batchResult.data ?? []) as BatchDetailRow[];
  const packRows = (packResult.data ?? []) as ExportEvidencePackRow[];
  const completion = ((completionResult.data ?? []) as CompletionFieldsRow[])[0] ?? null;
  const firstBatch = batchRows[0] ?? null;
  const firstPack = packRows[0] ?? null;
  const packageRows = batchRows.filter((row) => row.package_link_id);
  const eepRef = firstPack?.eep_ref ?? `EEP-${(firstBatch?.booking_ref ?? shipmentBatchId).replace(/[^a-z0-9-]/gi, "").slice(0, 24)}`;
  const totalBoxes = n(firstPack?.total_boxes) || n(firstBatch?.box_count) || packageRows.length;
  const totalQty = packRows.reduce((sum, row) => sum + n(row.qty_allocated), 0);
  const invoiceValue = packRows.reduce((sum, row) => sum + n(row.total_export_value_gbp), 0);
  const invoiceRefs = Array.from(new Set(packRows.map((row) => row.sales_invoice_ref).filter(Boolean))) as string[];
  const basisLabel = invoiceRefs.length > 0 ? "Posted customer sales invoice" : "Delivery allocation fallback";
  const basisTone = invoiceRefs.length > 0 ? "border-emerald-200 bg-emerald-50" : "border-amber-200 bg-amber-50";
  const receiptIssue = packageRows.some((row) => row.latest_receipt_status && row.latest_receipt_status !== "received_clean");
  const completionStatus = completion?.completion_status ?? firstPack?.completion_status ?? null;
  const blockers = [
    packResult.error ? "export_evidence_pack_preview_unavailable" : null,
    packRows.length === 0 ? "no_cos_eep_invoice_or_allocation_lines" : null,
    totalQty <= 0 ? "no_allocated_quantity" : null,
    invoiceValue <= 0 ? "missing_invoice_export_value" : null,
    receiptIssue ? "receipt_issue_or_non_clean_package_in_batch" : null,
  ].filter(Boolean) as string[];

  const shipperFields = [
    ["MBL / BOL / sea waybill", completion?.mbl_bol_sea_waybill_ref ?? firstPack?.mbl_bol_sea_waybill_ref],
    ["Container number", completion?.container_number ?? firstPack?.container_number],
    ["Seal number", completion?.seal_number ?? firstPack?.seal_number],
    ["Vessel / voyage", completion?.vessel_voyage ?? firstPack?.vessel_voyage],
    ["Port of loading", completion?.port_of_loading ?? firstPack?.port_of_loading],
    ["Port of discharge", completion?.port_of_discharge ?? firstPack?.port_of_discharge],
    ["Place of delivery", completion?.place_of_delivery ?? firstPack?.place_of_delivery],
    ["Date of export / shipment", shortDate(completion?.export_shipment_date ?? firstPack?.export_shipment_date)],
    ["Final package confirmation", completion?.final_package_confirmation ?? firstPack?.final_package_confirmation],
    ["Authorised name", completion?.authorised_name ?? firstPack?.authorised_name],
    ["Signature / stamp confirmation", completion?.signature_stamp_confirmation_yn ?? firstPack?.signature_stamp_confirmation_yn],
  ] as const;

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
                COS/EEP values follow the posted customer export sales invoice where one exists. Delivery allocation is used only as a fallback where no posted customer invoice exists. Supplementary shipping-only invoices are excluded from this goods schedule.
              </p>
            </div>
            <div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700"><div className="font-medium text-slate-950">{(staff as any).full_name}</div><div>{(staff as any).role_type}</div></div>
          </div>
          {batchResult.error ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">Batch detail unavailable: {batchResult.error.message}</p> : null}
          {completionResult.error ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">Completion fields unavailable: {completionResult.error.message}</p> : null}
          {packResult.error ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">COS/EEP invoice basis unavailable: {packResult.error.message}</p> : null}
        </section>

        <section className="grid gap-4 md:grid-cols-5">
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">EEP ref</p><p className="mt-1 text-xl font-semibold">{eepRef}</p></div>
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Packages / boxes</p><p className="mt-1 text-xl font-semibold">{totalBoxes || "—"}</p></div>
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Allocated qty</p><p className="mt-1 text-xl font-semibold">{qty(totalQty)}</p></div>
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Invoice export value</p><p className="mt-1 text-xl font-semibold">{money(invoiceValue)}</p></div>
          <div className={`rounded-3xl border p-4 shadow-sm ${blockers.length === 0 ? "border-emerald-200 bg-emerald-50" : "border-rose-200 bg-rose-50"}`}><p className="text-xs uppercase tracking-wide text-slate-500">Draft pack</p><p className="mt-1 text-xl font-semibold">{blockers.length === 0 ? "Ready" : "Blocked"}</p></div>
        </section>

        {blockers.length > 0 ? (
          <section className="rounded-3xl border border-rose-300 bg-rose-50 p-5 text-sm text-rose-900 shadow-sm">
            <h2 className="text-lg font-semibold">Blockers before draft COS / EEP pack</h2>
            <ul className="mt-2 list-disc space-y-1 pl-5">{blockers.map((blocker) => <li key={blocker}>{friendly(blocker)}</li>)}</ul>
          </section>
        ) : null}

        <section className={`rounded-3xl border p-5 shadow-sm ${basisTone}`}>
          <h2 className="text-xl font-semibold">Sales invoice basis</h2>
          <div className="mt-4 grid gap-3 md:grid-cols-4">
            <div className="rounded-2xl bg-white/70 p-4"><p className="text-xs uppercase tracking-wide text-slate-500">Basis</p><p className="mt-1 font-semibold">{basisLabel}</p></div>
            <div className="rounded-2xl bg-white/70 p-4"><p className="text-xs uppercase tracking-wide text-slate-500">Invoice ref</p><p className="mt-1 font-semibold">{invoiceRefs.length > 0 ? invoiceRefs.join(", ") : "—"}</p></div>
            <div className="rounded-2xl bg-white/70 p-4"><p className="text-xs uppercase tracking-wide text-slate-500">COS/EEP invoice value</p><p className="mt-1 font-semibold">{money(invoiceValue)}</p></div>
            <div className="rounded-2xl bg-white/70 p-4"><p className="text-xs uppercase tracking-wide text-slate-500">Supplementary shipping</p><p className="mt-1 font-semibold">Excluded from COS/EEP</p></div>
          </div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <h2 className="text-xl font-semibold">EEP / packing list line preview</h2>
          <p className="mt-2 text-sm leading-6 text-slate-600">Detailed goods schedule. The short COS references this EEP instead of carrying every line on the certificate itself.</p>
          <div className="mt-4 overflow-x-auto rounded-2xl border border-slate-200">
            <table className="min-w-full divide-y divide-slate-200 text-sm">
              <thead className="bg-slate-100 text-xs uppercase tracking-wide text-slate-500">
                <tr>
                  <th className="px-3 py-2 text-left">Customer</th>
                  <th className="px-3 py-2 text-left">Sales invoice ref</th>
                  <th className="px-3 py-2 text-left">Trace SKU</th>
                  <th className="px-3 py-2 text-left">Description</th>
                  <th className="px-3 py-2 text-right">Qty</th>
                  <th className="px-3 py-2 text-right">Unit invoice value</th>
                  <th className="px-3 py-2 text-right">Total invoice value</th>
                  <th className="px-3 py-2 text-left">Package / box</th>
                  <th className="px-3 py-2 text-left">Destination</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100 bg-white">
                {packRows.length === 0 ? (
                  <tr><td colSpan={9} className="px-3 py-4 text-slate-600">No COS/EEP rows found for this shipment batch.</td></tr>
                ) : packRows.map((row, index) => (
                  <tr key={`${row.order_id}-${row.supplier_invoice_line_id}-${index}`}>
                    <td className="px-3 py-2 font-semibold">{row.customer_name ?? "Customer"}</td>
                    <td className="px-3 py-2 font-semibold text-slate-700">{row.sales_invoice_ref ?? "Allocation fallback"}</td>
                    <td className="px-3 py-2 font-mono text-xs">{traceSku(row)}</td>
                    <td className="px-3 py-2">{cleanDescription(row.item_description)}</td>
                    <td className="px-3 py-2 text-right font-semibold">{qty(row.qty_allocated)}</td>
                    <td className="px-3 py-2 text-right">{money(row.unit_export_value_gbp)}</td>
                    <td className="px-3 py-2 text-right font-semibold">{money(row.total_export_value_gbp)}</td>
                    <td className="px-3 py-2">{row.package_box_ref ?? firstBatch?.booking_ref ?? eepRef}</td>
                    <td className="px-3 py-2">{row.destination ?? "Ghana"}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>

        <section className="grid gap-4 lg:grid-cols-2">
          <article className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
            <h2 className="text-xl font-semibold">Draft COS header preview</h2>
            <div className="mt-4 grid gap-3 text-sm md:grid-cols-2">
              <div className="rounded-2xl bg-slate-50 p-3"><span className="text-slate-500">Exporter / supplier</span><p className="font-semibold">Goodcashback / tenant exporter</p></div>
              <div className="rounded-2xl bg-slate-50 p-3"><span className="text-slate-500">Freight forwarder / packer</span><p className="font-semibold">{firstPack?.shipper_name ?? "Shipper to complete"}</p></div>
              <div className="rounded-2xl bg-slate-50 p-3"><span className="text-slate-500">Consignee</span><p className="font-semibold">Ghana jurisdiction hub / tenant destination hub</p></div>
              <div className="rounded-2xl bg-slate-50 p-3"><span className="text-slate-500">Customer reference</span><p className="font-semibold">{firstPack?.booking_ref ?? firstBatch?.booking_ref ?? shipmentBatchId}</p></div>
              <div className="rounded-2xl bg-slate-50 p-3"><span className="text-slate-500">Description</span><p className="font-semibold">Assorted retail consumer goods as per attached {eepRef}</p></div>
              <div className="rounded-2xl bg-slate-50 p-3"><span className="text-slate-500">Destination</span><p className="font-semibold">{firstPack?.destination ?? "Ghana / destination hub"}</p></div>
            </div>
          </article>

          <article className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
            <div className="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
              <div>
                <h2 className="text-xl font-semibold">Shipper-completed fields</h2>
                <p className="mt-1 text-sm text-slate-600">Supervisor view only. These values are saved by the shipper on the shipper-side shipment page.</p>
              </div>
              {statusPill(completionStatus)}
            </div>
            <div className="mt-4 grid gap-2 text-sm md:grid-cols-2">
              {shipperFields.map(([label, value]) => (
                <div key={label} className="rounded-2xl border border-slate-200 bg-slate-50 p-3">
                  <span className="text-xs font-semibold uppercase tracking-wide text-slate-500">{label}</span>
                  <p className="mt-1 font-semibold">{fieldValue(value as any)}</p>
                </div>
              ))}
            </div>
          </article>
        </section>

        <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm leading-6 text-amber-900 shadow-sm">
          <h2 className="font-semibold">Final evidence remains shipper-side</h2>
          <p className="mt-2">The shipper enters final shipment facts, downloads the draft COS/EEP, signs or stamps it, and uploads final export evidence. Supervisors can view and download the final pack once uploaded.</p>
          <div className="mt-4 flex flex-wrap gap-3">
            <Link href={`/shipper/shipments/${shipmentBatchId}/draft-cos-pack`} className="rounded-xl border border-emerald-300 bg-white px-4 py-2 text-sm font-semibold text-emerald-700">Download draft COS + EEP pack</Link>
            <Link href={`/internal/export-evidence/final/${shipmentBatchId}`} className="rounded-xl border border-sky-300 bg-white px-4 py-2 text-sm font-semibold text-sky-700">Review uploaded final evidence</Link>
          </div>
        </section>
      </div>
    </main>
  );
}
