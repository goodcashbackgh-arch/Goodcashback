import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { saveExportEvidenceCompletionFieldsAction, updateShipmentBatchHeaderAction } from "../actions";
import { PackageContentsPreview } from "../../PackageContentsPreview";

type BatchPackageRow = {
  id: string;
  tracking_submission_id: string;
  order_id: string;
  active: boolean;
  created_at: string;
  orders?: { order_ref?: string | null; retailers?: { name?: string | null } | null } | null;
  order_tracking_submissions?: {
    tracking_ref?: string | null;
    tracking_date?: string | null;
    tracking_screenshot_url?: string | null;
    couriers?: { name?: string | null } | null;
  } | null;
};

type BatchRow = {
  id: string;
  booking_ref: string | null;
  importer_id: string;
  shipper_id: string;
  shipment_cutoff_at: string | null;
  dispatched_at: string | null;
  box_count: number | null;
  notes: string | null;
  status: string;
  created_at: string;
  importers?: { company_name?: string | null; trading_name?: string | null } | null;
  shipper_shipment_batch_packages?: BatchPackageRow[] | null;
};

type PackageDashboardRow = {
  importer_id: string | null;
  importer_name: string | null;
  order_id: string;
  order_ref: string | null;
  retailer_name: string | null;
  tracking_submission_id: string | null;
};

type ExportEvidenceCompletionFields = {
  id: string;
  shipment_batch_id: string;
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
  notes: string | null;
  completion_status: string | null;
  updated_at: string | null;
};

function formatDate(value: string | null | undefined) {
  if (!value) return "—";
  return value.includes("T") ? value.slice(0, 10) : value;
}

function datetimeLocalValue(value: string | null | undefined) {
  if (!value) return "";
  return value.slice(0, 16);
}

function dateValue(value: string | null | undefined) {
  if (!value) return "";
  return value.includes("T") ? value.slice(0, 10) : value;
}

function importerName(batch: BatchRow, importerNameById: Map<string, string>) {
  return importerNameById.get(batch.importer_id) || batch.importers?.trading_name || batch.importers?.company_name || batch.importer_id;
}

function normalizeLink(value: string | null | undefined) {
  const raw = (value ?? "").trim();
  if (!raw) return null;
  if (/^[a-z][a-z0-9+.-]*:/i.test(raw)) return raw;
  if (raw.startsWith("//")) return `https:${raw}`;
  return `https://${raw}`;
}

function friendly(value: string | null | undefined) {
  if (!value) return "Not started";
  return value.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase());
}

function statusClass(status: string | null | undefined) {
  if (status === "completion_fields_ready") return "bg-emerald-100 text-emerald-800";
  return "bg-amber-100 text-amber-800";
}

export default async function ShipperShipmentDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ shipment_batch_id: string }>;
  searchParams?: Promise<{ success?: string; error?: string }>;
}) {
  const { shipment_batch_id: shipmentBatchId } = await params;
  const queryParams = searchParams ? await searchParams : {};
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: shipperUser } = await supabase
    .from("shipper_users")
    .select("id, full_name, shipper_id, shippers(name)")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!shipperUser) redirect("/auth/check");

  const [{ data: batch, error }, { data: packageDashboardRows }, exportEvidenceResult] = await Promise.all([
    supabase
      .from("shipper_shipment_batches")
      .select("id, booking_ref, importer_id, shipper_id, shipment_cutoff_at, dispatched_at, box_count, notes, status, created_at, importers(company_name, trading_name), shipper_shipment_batch_packages(id, tracking_submission_id, order_id, active, created_at, orders(order_ref, retailers(name)), order_tracking_submissions(tracking_ref, tracking_date, tracking_screenshot_url, couriers(name)))")
      .eq("id", shipmentBatchId)
      .eq("shipper_id", (shipperUser as any).shipper_id)
      .maybeSingle(),
    (supabase as any).rpc("shipper_package_receipt_dashboard_v1"),
    supabase
      .from("shipper_export_evidence_completion_fields")
      .select("id, shipment_batch_id, mbl_bol_sea_waybill_ref, container_number, seal_number, vessel_voyage, port_of_loading, port_of_discharge, place_of_delivery, export_shipment_date, final_package_confirmation, authorised_name, signature_stamp_confirmation_yn, notes, completion_status, updated_at")
      .eq("shipment_batch_id", shipmentBatchId)
      .maybeSingle(),
  ]);

  const row = batch as unknown as BatchRow | null;
  const packages = (row?.shipper_shipment_batch_packages ?? []).filter((pkg) => pkg.active);
  const shipper = Array.isArray((shipperUser as any).shippers) ? (shipperUser as any).shippers[0] : (shipperUser as any).shippers;
  const exportFields = (exportEvidenceResult.data ?? null) as ExportEvidenceCompletionFields | null;
  const exportFieldsError = exportEvidenceResult.error;
  const nameRows = (packageDashboardRows ?? []) as PackageDashboardRow[];
  const importerNameById = new Map<string, string>();
  const orderLabelById = new Map<string, string>();
  const retailerNameByOrderId = new Map<string, string>();
  const trackingLabelById = new Map<string, PackageDashboardRow>();
  for (const nameRow of nameRows) {
    if (nameRow.importer_id && nameRow.importer_name) importerNameById.set(nameRow.importer_id, nameRow.importer_name);
    if (nameRow.order_id && nameRow.order_ref) orderLabelById.set(nameRow.order_id, nameRow.order_ref);
    if (nameRow.order_id && nameRow.retailer_name) retailerNameByOrderId.set(nameRow.order_id, nameRow.retailer_name);
    if (nameRow.tracking_submission_id) trackingLabelById.set(nameRow.tracking_submission_id, nameRow);
  }
  const canEditHeader = row?.status === "created";
  const canEditExportFields = row?.status === "created";

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-7xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-wrap gap-3 text-sm font-semibold text-sky-700">
            <Link href="/shipper">← Dashboard</Link>
            <Link href="/shipper/shipments">Shipment batches</Link>
          </div>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Goodcashback Shipper</p>
          <h1 className="mt-2 text-2xl font-semibold tracking-tight sm:text-3xl">Shipment batch detail</h1>
          <p className="mt-2 text-sm text-slate-600">{(shipperUser as any).full_name} · {shipper?.name ?? "Shipper"}</p>
          {queryParams.success ? <p className="mt-4 rounded-xl border border-emerald-300 bg-emerald-50 px-3 py-2 text-sm text-emerald-900">{queryParams.success}</p> : null}
          {queryParams.error ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">{queryParams.error}</p> : null}
          {error ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">{error.message}</p> : null}
          {exportFieldsError ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">Export evidence completion fields are not available yet. Run the latest Supabase migration before testing this form.</p> : null}
          {!row && !error ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">Shipment batch not found for this shipper.</p> : null}
        </section>

        {row ? (
          <>
            <section className="grid gap-4 md:grid-cols-5">
              <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
                <p className="text-xs uppercase tracking-wide text-slate-500">Booking ref</p>
                <p className="mt-1 text-xl font-semibold">{row.booking_ref ?? row.id}</p>
              </div>
              <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
                <p className="text-xs uppercase tracking-wide text-slate-500">Importer</p>
                <p className="mt-1 text-xl font-semibold">{importerName(row, importerNameById)}</p>
              </div>
              <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
                <p className="text-xs uppercase tracking-wide text-slate-500">Packages</p>
                <p className="mt-1 text-xl font-semibold">{packages.length}</p>
              </div>
              <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
                <p className="text-xs uppercase tracking-wide text-slate-500">Status</p>
                <p className="mt-1 text-xl font-semibold">{row.status}</p>
              </div>
              <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
                <p className="text-xs uppercase tracking-wide text-slate-500">Export evidence fields</p>
                <p className={`mt-1 w-fit rounded-full px-3 py-1 text-sm font-semibold ${statusClass(exportFields?.completion_status)}`}>{friendly(exportFields?.completion_status)}</p>
              </div>
            </section>

            <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
              <div className="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
                <div>
                  <h2 className="text-xl font-semibold">Batch header</h2>
                  <p className="mt-1 text-sm text-slate-600">Shipment booking and dispatch facts used later for export-evidence review. This does not create COS/BOL/POD, master shipment evidence or Sage/VAT effects.</p>
                </div>
                {canEditHeader ? <span className="rounded-full bg-emerald-100 px-3 py-1 text-xs font-semibold text-emerald-800">Editable until export review starts</span> : <span className="rounded-full bg-slate-100 px-3 py-1 text-xs font-semibold text-slate-700">Locked by status</span>}
              </div>
              <div className="mt-4 grid gap-3 text-sm md:grid-cols-3">
                <div className="rounded-2xl border border-slate-200 bg-slate-50 p-3"><span className="text-slate-500">Created</span><p className="font-semibold">{formatDate(row.created_at)}</p></div>
                <div className="rounded-2xl border border-slate-200 bg-slate-50 p-3"><span className="text-slate-500">Cut-off</span><p className="font-semibold">{formatDate(row.shipment_cutoff_at)}</p></div>
                <div className="rounded-2xl border border-slate-200 bg-slate-50 p-3"><span className="text-slate-500">Dispatch</span><p className="font-semibold">{formatDate(row.dispatched_at)}</p></div>
                <div className="rounded-2xl border border-slate-200 bg-slate-50 p-3"><span className="text-slate-500">Box/carton count</span><p className="font-semibold">{row.box_count ?? "—"}</p></div>
              </div>
              {row.notes ? <p className="mt-4 rounded-2xl bg-slate-50 p-3 text-sm text-slate-700"><span className="font-semibold">Notes:</span> {row.notes}</p> : null}

              {canEditHeader ? (
                <details className="mt-5 rounded-2xl border border-slate-200 bg-slate-50 p-4">
                  <summary className="cursor-pointer text-sm font-semibold text-slate-900">Edit shipment batch header</summary>
                  <form action={updateShipmentBatchHeaderAction} className="mt-4 grid gap-3 md:grid-cols-3">
                    <input type="hidden" name="shipment_batch_id" value={row.id} />
                    <label className="space-y-1 text-sm">
                      <span className="text-xs uppercase tracking-wide text-slate-500">Booking ref</span>
                      <input name="booking_ref" required defaultValue={row.booking_ref ?? ""} className="w-full rounded-xl border border-slate-300 px-3 py-2" />
                    </label>
                    <label className="space-y-1 text-sm">
                      <span className="text-xs uppercase tracking-wide text-slate-500">Shipment cut-off</span>
                      <input name="shipment_cutoff_at" type="datetime-local" defaultValue={datetimeLocalValue(row.shipment_cutoff_at)} className="w-full rounded-xl border border-slate-300 px-3 py-2" />
                    </label>
                    <label className="space-y-1 text-sm">
                      <span className="text-xs uppercase tracking-wide text-slate-500">Dispatch date/time</span>
                      <input name="dispatched_at" type="datetime-local" defaultValue={datetimeLocalValue(row.dispatched_at)} className="w-full rounded-xl border border-slate-300 px-3 py-2" />
                    </label>
                    <label className="space-y-1 text-sm">
                      <span className="text-xs uppercase tracking-wide text-slate-500">Box/carton count</span>
                      <input name="box_count" type="number" min="0" step="1" defaultValue={row.box_count ?? ""} className="w-full rounded-xl border border-slate-300 px-3 py-2" />
                    </label>
                    <label className="space-y-1 text-sm md:col-span-2">
                      <span className="text-xs uppercase tracking-wide text-slate-500">Notes</span>
                      <input name="notes" defaultValue={row.notes ?? ""} className="w-full rounded-xl border border-slate-300 px-3 py-2" />
                    </label>
                    <div className="md:col-span-3">
                      <button type="submit" className="rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800">Save header correction</button>
                    </div>
                    <p className="text-xs text-slate-500 md:col-span-3">This updates booking/dispatch facts only. Package membership, item allocation, master shipment, COS/BOL/POD, export evidence and Sage/VAT readiness are not changed.</p>
                  </form>
                </details>
              ) : null}
            </section>

            <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm leading-6 text-amber-900 shadow-sm sm:p-6">
              <div className="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
                <div>
                  <h2 className="text-xl font-semibold text-amber-950">Final shipment / COS completion fields</h2>
                  <p className="mt-1">Enter the final shipment facts here first. The draft COS + EEP download will use these values and the platform-generated packing list. Upload of the signed/stamped final COS comes after this step.</p>
                </div>
                <span className={`w-fit rounded-full px-3 py-1 text-xs font-semibold ${statusClass(exportFields?.completion_status)}`}>{friendly(exportFields?.completion_status)}</span>
              </div>
              {canEditExportFields ? (
                <form action={saveExportEvidenceCompletionFieldsAction} className="mt-5 grid gap-3 md:grid-cols-2">
                  <input type="hidden" name="shipment_batch_id" value={row.id} />
                  <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-amber-800">MBL / BOL / sea waybill</span><input name="mbl_bol_sea_waybill_ref" defaultValue={exportFields?.mbl_bol_sea_waybill_ref ?? ""} className="w-full rounded-xl border border-amber-300 bg-white px-3 py-2 text-slate-950" /></label>
                  <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-amber-800">Container number</span><input name="container_number" defaultValue={exportFields?.container_number ?? ""} className="w-full rounded-xl border border-amber-300 bg-white px-3 py-2 text-slate-950" /></label>
                  <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-amber-800">Seal number</span><input name="seal_number" defaultValue={exportFields?.seal_number ?? ""} className="w-full rounded-xl border border-amber-300 bg-white px-3 py-2 text-slate-950" /></label>
                  <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-amber-800">Vessel / voyage</span><input name="vessel_voyage" defaultValue={exportFields?.vessel_voyage ?? ""} className="w-full rounded-xl border border-amber-300 bg-white px-3 py-2 text-slate-950" /></label>
                  <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-amber-800">Port of loading</span><input name="port_of_loading" defaultValue={exportFields?.port_of_loading ?? ""} className="w-full rounded-xl border border-amber-300 bg-white px-3 py-2 text-slate-950" /></label>
                  <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-amber-800">Port of discharge</span><input name="port_of_discharge" defaultValue={exportFields?.port_of_discharge ?? ""} className="w-full rounded-xl border border-amber-300 bg-white px-3 py-2 text-slate-950" /></label>
                  <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-amber-800">Place of delivery</span><input name="place_of_delivery" defaultValue={exportFields?.place_of_delivery ?? ""} className="w-full rounded-xl border border-amber-300 bg-white px-3 py-2 text-slate-950" /></label>
                  <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-amber-800">Export / shipment date</span><input name="export_shipment_date" type="date" defaultValue={dateValue(exportFields?.export_shipment_date)} className="w-full rounded-xl border border-amber-300 bg-white px-3 py-2 text-slate-950" /></label>
                  <label className="space-y-1 text-sm md:col-span-2"><span className="text-xs uppercase tracking-wide text-amber-800">Final package confirmation</span><input name="final_package_confirmation" defaultValue={exportFields?.final_package_confirmation ?? (row.box_count ? `${row.box_count} boxes/packages` : "")} className="w-full rounded-xl border border-amber-300 bg-white px-3 py-2 text-slate-950" /></label>
                  <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-amber-800">Authorised name</span><input name="authorised_name" defaultValue={exportFields?.authorised_name ?? (shipperUser as any).full_name ?? ""} className="w-full rounded-xl border border-amber-300 bg-white px-3 py-2 text-slate-950" /></label>
                  <label className="flex items-center gap-3 rounded-xl border border-amber-300 bg-white px-3 py-2 text-sm text-slate-950"><input name="signature_stamp_confirmation_yn" type="checkbox" defaultChecked={Boolean(exportFields?.signature_stamp_confirmation_yn)} /> I confirm the final COS will be signed/stamped/authenticated by the shipper.</label>
                  <label className="space-y-1 text-sm md:col-span-2"><span className="text-xs uppercase tracking-wide text-amber-800">Notes</span><textarea name="export_evidence_notes" defaultValue={exportFields?.notes ?? ""} rows={3} className="w-full rounded-xl border border-amber-300 bg-white px-3 py-2 text-slate-950" /></label>
                  <div className="md:col-span-2">
                    <button type="submit" className="rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800">Save final shipment fields</button>
                  </div>
                </form>
              ) : (
                <p className="mt-4 rounded-2xl border border-slate-200 bg-white p-4 text-sm text-slate-700">Final shipment fields are locked for this batch status.</p>
              )}
            </section>

            <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
              <h2 className="text-xl font-semibold">Selected packages</h2>
              <p className="mt-1 text-sm text-slate-600">These are the package/tracking refs included in this importer shipment batch. Contents preview shows description and quantity only. Final COS/BOL/POD belongs to the later export-evidence/master-shipment lane.</p>
              {packages.length === 0 ? (
                <p className="mt-4 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-700">No active packages are linked to this batch.</p>
              ) : (
                <div className="mt-4 overflow-x-auto rounded-2xl border border-slate-200">
                  <table className="min-w-full divide-y divide-slate-200 text-sm">
                    <thead className="bg-slate-100 text-xs uppercase tracking-wide text-slate-500">
                      <tr>
                        <th className="px-3 py-2 text-left">Order</th>
                        <th className="px-3 py-2 text-left">Retailer</th>
                        <th className="px-3 py-2 text-left">Tracking/package</th>
                        <th className="px-3 py-2 text-left">Tracking date</th>
                        <th className="px-3 py-2 text-left">Selected</th>
                        <th className="px-3 py-2 text-left">Contents</th>
                        <th className="px-3 py-2 text-left">Evidence</th>
                      </tr>
                    </thead>
                    <tbody className="divide-y divide-slate-100 bg-white">
                      {packages.map((pkg) => {
                        const tracking = pkg.order_tracking_submissions;
                        const dashboardTracking = trackingLabelById.get(pkg.tracking_submission_id);
                        const evidenceUrl = normalizeLink(tracking?.tracking_screenshot_url);
                        return (
                          <tr key={pkg.id}>
                            <td className="px-3 py-2 font-semibold">{pkg.orders?.order_ref ?? orderLabelById.get(pkg.order_id) ?? pkg.order_id}</td>
                            <td className="px-3 py-2">{pkg.orders?.retailers?.name ?? retailerNameByOrderId.get(pkg.order_id) ?? dashboardTracking?.retailer_name ?? "—"}</td>
                            <td className="px-3 py-2">{tracking?.couriers?.name ?? "Courier"} · {tracking?.tracking_ref ?? pkg.tracking_submission_id}</td>
                            <td className="px-3 py-2">{formatDate(tracking?.tracking_date)}</td>
                            <td className="px-3 py-2">{formatDate(pkg.created_at)}</td>
                            <td className="px-3 py-2"><PackageContentsPreview trackingSubmissionId={pkg.tracking_submission_id} compact /></td>
                            <td className="px-3 py-2">{evidenceUrl ? <a href={evidenceUrl} target="_blank" rel="noreferrer" className="font-semibold text-sky-700 underline">Open</a> : "—"}</td>
                          </tr>
                        );
                      })}
                    </tbody>
                  </table>
                </div>
              )}
            </section>
          </>
        ) : null}
      </div>
    </main>
  );
}
