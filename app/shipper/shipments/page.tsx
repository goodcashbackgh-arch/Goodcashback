import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type BatchRow = {
  id: string;
  booking_ref: string | null;
  importer_id: string;
  shipper_id: string;
  shipment_cutoff_at: string | null;
  dispatched_at: string | null;
  box_count: number | null;
  status: string;
  created_at: string;
  importers?: { company_name?: string | null; trading_name?: string | null } | null;
  shipper_shipment_batch_packages?: { id: string; tracking_submission_id: string; order_id: string; active: boolean }[] | null;
};

type PackageDashboardRow = {
  importer_id: string | null;
  importer_name: string | null;
  order_id: string;
  order_ref: string | null;
  retailer_name: string | null;
  tracking_submission_id: string | null;
};

function formatDate(value: string | null | undefined) {
  if (!value) return "—";
  return value.includes("T") ? value.slice(0, 10) : value;
}

function importerName(batch: BatchRow, importerNameById: Map<string, string>) {
  return importerNameById.get(batch.importer_id) || batch.importers?.trading_name || batch.importers?.company_name || batch.importer_id;
}

export default async function ShipperShipmentsPage() {
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

  const [{ data: batches, error }, { data: packageDashboardRows }] = await Promise.all([
    supabase
      .from("shipper_shipment_batches")
      .select("id, booking_ref, importer_id, shipper_id, shipment_cutoff_at, dispatched_at, box_count, status, created_at, importers(company_name, trading_name), shipper_shipment_batch_packages(id, tracking_submission_id, order_id, active)")
      .eq("shipper_id", (shipperUser as any).shipper_id)
      .order("created_at", { ascending: false }),
    (supabase as any).rpc("shipper_package_receipt_dashboard_v1"),
  ]);

  const nameRows = (packageDashboardRows ?? []) as PackageDashboardRow[];
  const importerNameById = new Map<string, string>();
  for (const row of nameRows) {
    if (row.importer_id && row.importer_name) importerNameById.set(row.importer_id, row.importer_name);
  }

  const rows = ((batches ?? []) as unknown as BatchRow[]).filter((batch) => batch.status !== "voided");
  const shipper = Array.isArray((shipperUser as any).shippers) ? (shipperUser as any).shippers[0] : (shipperUser as any).shippers;

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-7xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <Link href="/shipper" className="text-sm font-semibold text-sky-700">← Back to shipper dashboard</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Goodcashback Shipper</p>
          <h1 className="mt-2 text-2xl font-semibold tracking-tight sm:text-3xl">Shipment batches</h1>
          <p className="mt-2 text-sm text-slate-600">{(shipperUser as any).full_name} · {shipper?.name ?? "Shipper"}</p>
          <p className="mt-3 max-w-4xl text-sm leading-6 text-slate-600">
            View shipment batches created from received-clean packages. This is package/shipment truth only. Shipping charge documents are uploaded separately and reviewed by supervisor; COS/BOL/POD belongs to the later export evidence lane.
          </p>
          <div className="mt-5 flex flex-wrap gap-3">
            <Link href="/shipper/shipments/new" className="rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800">Create shipment batch</Link>
            <Link href="/shipper/shipping-documents/new" className="rounded-xl border border-sky-300 bg-sky-50 px-4 py-2 text-sm font-semibold text-sky-900 hover:bg-sky-100">Upload shipping charge doc</Link>
          </div>
          {error ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">{error.message}</p> : null}
        </section>

        <section className="grid gap-4 md:grid-cols-4">
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
            <p className="text-xs uppercase tracking-wide text-slate-500">Active batches</p>
            <p className="mt-1 text-2xl font-semibold">{rows.length}</p>
          </div>
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
            <p className="text-xs uppercase tracking-wide text-slate-500">Packages selected</p>
            <p className="mt-1 text-2xl font-semibold">{rows.reduce((sum, row) => sum + (row.shipper_shipment_batch_packages?.filter((p) => p.active).length ?? 0), 0)}</p>
          </div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <h2 className="text-xl font-semibold">Batch list</h2>
          {rows.length === 0 ? (
            <p className="mt-4 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-700">No shipment batches have been created yet.</p>
          ) : (
            <div className="mt-4 overflow-x-auto rounded-2xl border border-slate-200">
              <table className="min-w-full divide-y divide-slate-200 text-sm">
                <thead className="bg-slate-100 text-xs uppercase tracking-wide text-slate-500">
                  <tr>
                    <th className="px-3 py-2 text-left">Booking ref</th>
                    <th className="px-3 py-2 text-left">Importer</th>
                    <th className="px-3 py-2 text-left">Created</th>
                    <th className="px-3 py-2 text-left">Dispatch</th>
                    <th className="px-3 py-2 text-right">Packages</th>
                    <th className="px-3 py-2 text-left">Boxes</th>
                    <th className="px-3 py-2 text-left">Status</th>
                    <th className="px-3 py-2 text-left">Actions</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-100 bg-white">
                  {rows.map((batch) => (
                    <tr key={batch.id}>
                      <td className="px-3 py-2 font-semibold">{batch.booking_ref ?? batch.id}</td>
                      <td className="px-3 py-2">{importerName(batch, importerNameById)}</td>
                      <td className="px-3 py-2">{formatDate(batch.created_at)}</td>
                      <td className="px-3 py-2">{formatDate(batch.dispatched_at)}</td>
                      <td className="px-3 py-2 text-right">{batch.shipper_shipment_batch_packages?.filter((p) => p.active).length ?? 0}</td>
                      <td className="px-3 py-2">{batch.box_count ?? "—"}</td>
                      <td className="px-3 py-2"><span className="rounded-full bg-slate-100 px-2 py-1 text-xs font-semibold text-slate-700">{batch.status}</span></td>
                      <td className="px-3 py-2">
                        <div className="flex flex-col gap-1">
                          <Link href={`/shipper/shipments/${batch.id}`} className="font-semibold text-sky-700 underline">View detail</Link>
                          <Link href={`/shipper/shipping-documents/new?batch=${batch.id}`} className="font-semibold text-sky-700 underline">Upload charge doc</Link>
                        </div>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </section>
      </div>
    </main>
  );
}
