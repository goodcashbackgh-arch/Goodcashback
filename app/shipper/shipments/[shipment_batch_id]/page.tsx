import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

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
  container_ref: string | null;
  bol_ref: string | null;
  notes: string | null;
  status: string;
  created_at: string;
  importers?: { company_name?: string | null; trading_name?: string | null } | null;
  shipper_shipment_batch_packages?: BatchPackageRow[] | null;
};

function formatDate(value: string | null | undefined) {
  if (!value) return "—";
  return value.includes("T") ? value.slice(0, 10) : value;
}

function importerName(batch: BatchRow) {
  return batch.importers?.trading_name || batch.importers?.company_name || batch.importer_id;
}

function normalizeLink(value: string | null | undefined) {
  const raw = (value ?? "").trim();
  if (!raw) return null;
  if (/^[a-z][a-z0-9+.-]*:/i.test(raw)) return raw;
  if (raw.startsWith("//")) return `https:${raw}`;
  return `https://${raw}`;
}

export default async function ShipperShipmentDetailPage({
  params,
}: {
  params: Promise<{ shipment_batch_id: string }>;
}) {
  const { shipment_batch_id: shipmentBatchId } = await params;
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

  const { data: batch, error } = await supabase
    .from("shipper_shipment_batches")
    .select("id, booking_ref, importer_id, shipper_id, shipment_cutoff_at, dispatched_at, box_count, container_ref, bol_ref, notes, status, created_at, importers(company_name, trading_name), shipper_shipment_batch_packages(id, tracking_submission_id, order_id, active, created_at, orders(order_ref, retailers(name)), order_tracking_submissions(tracking_ref, tracking_date, tracking_screenshot_url, couriers(name)))")
    .eq("id", shipmentBatchId)
    .eq("shipper_id", (shipperUser as any).shipper_id)
    .maybeSingle();

  const row = batch as unknown as BatchRow | null;
  const packages = (row?.shipper_shipment_batch_packages ?? []).filter((pkg) => pkg.active);
  const shipper = Array.isArray((shipperUser as any).shippers) ? (shipperUser as any).shippers[0] : (shipperUser as any).shippers;

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
          {error ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">{error.message}</p> : null}
          {!row && !error ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">Shipment batch not found for this shipper.</p> : null}
        </section>

        {row ? (
          <>
            <section className="grid gap-4 md:grid-cols-4">
              <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
                <p className="text-xs uppercase tracking-wide text-slate-500">Booking ref</p>
                <p className="mt-1 text-xl font-semibold">{row.booking_ref ?? row.id}</p>
              </div>
              <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
                <p className="text-xs uppercase tracking-wide text-slate-500">Importer</p>
                <p className="mt-1 text-xl font-semibold">{importerName(row)}</p>
              </div>
              <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
                <p className="text-xs uppercase tracking-wide text-slate-500">Packages</p>
                <p className="mt-1 text-xl font-semibold">{packages.length}</p>
              </div>
              <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
                <p className="text-xs uppercase tracking-wide text-slate-500">Status</p>
                <p className="mt-1 text-xl font-semibold">{row.status}</p>
              </div>
            </section>

            <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
              <h2 className="text-xl font-semibold">Batch header</h2>
              <div className="mt-4 grid gap-3 text-sm md:grid-cols-3">
                <div className="rounded-2xl border border-slate-200 bg-slate-50 p-3"><span className="text-slate-500">Created</span><p className="font-semibold">{formatDate(row.created_at)}</p></div>
                <div className="rounded-2xl border border-slate-200 bg-slate-50 p-3"><span className="text-slate-500">Cut-off</span><p className="font-semibold">{formatDate(row.shipment_cutoff_at)}</p></div>
                <div className="rounded-2xl border border-slate-200 bg-slate-50 p-3"><span className="text-slate-500">Dispatch</span><p className="font-semibold">{formatDate(row.dispatched_at)}</p></div>
                <div className="rounded-2xl border border-slate-200 bg-slate-50 p-3"><span className="text-slate-500">Box/carton count</span><p className="font-semibold">{row.box_count ?? "—"}</p></div>
                <div className="rounded-2xl border border-slate-200 bg-slate-50 p-3"><span className="text-slate-500">Container ref</span><p className="font-semibold">{row.container_ref ?? "—"}</p></div>
                <div className="rounded-2xl border border-slate-200 bg-slate-50 p-3"><span className="text-slate-500">BOL ref</span><p className="font-semibold">{row.bol_ref ?? "—"}</p></div>
              </div>
              {row.notes ? <p className="mt-4 rounded-2xl bg-slate-50 p-3 text-sm text-slate-700"><span className="font-semibold">Notes:</span> {row.notes}</p> : null}
            </section>

            <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
              <h2 className="text-xl font-semibold">Selected packages</h2>
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
                        <th className="px-3 py-2 text-left">Evidence</th>
                      </tr>
                    </thead>
                    <tbody className="divide-y divide-slate-100 bg-white">
                      {packages.map((pkg) => {
                        const tracking = pkg.order_tracking_submissions;
                        const evidenceUrl = normalizeLink(tracking?.tracking_screenshot_url);
                        return (
                          <tr key={pkg.id}>
                            <td className="px-3 py-2 font-semibold">{pkg.orders?.order_ref ?? pkg.order_id}</td>
                            <td className="px-3 py-2">{pkg.orders?.retailers?.name ?? "—"}</td>
                            <td className="px-3 py-2">{tracking?.couriers?.name ?? "Courier"} · {tracking?.tracking_ref ?? pkg.tracking_submission_id}</td>
                            <td className="px-3 py-2">{formatDate(tracking?.tracking_date)}</td>
                            <td className="px-3 py-2">{formatDate(pkg.created_at)}</td>
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
