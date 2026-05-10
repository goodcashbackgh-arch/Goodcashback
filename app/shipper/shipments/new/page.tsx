import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { createShipmentBatchAction } from "../actions";

type CandidateRow = {
  importer_id: string;
  importer_name: string | null;
  order_id: string;
  order_ref: string | null;
  retailer_name: string | null;
  tracking_submission_id: string;
  courier_name: string | null;
  tracking_ref: string | null;
  tracking_date: string | null;
  allocated_qty: number | null;
  allocated_net_value_gbp: number | null;
  latest_receipt_status: string | null;
  latest_receipt_recorded_at: string | null;
};

function gbp(value: unknown) {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" }).format(Number(value ?? 0));
}

function groupByImporter(rows: CandidateRow[]) {
  const groups = new Map<string, CandidateRow[]>();
  for (const row of rows) {
    const key = `${row.importer_id}::${row.importer_name ?? "Unknown importer"}`;
    groups.set(key, [...(groups.get(key) ?? []), row]);
  }
  return Array.from(groups.entries()).map(([key, rows]) => {
    const [importerId, importerName] = key.split("::");
    return { importerId, importerName, rows };
  });
}

export default async function NewShipperShipmentPage({
  searchParams,
}: {
  searchParams?: Promise<{ importer?: string; success?: string; error?: string }>;
}) {
  const queryParams = searchParams ? await searchParams : {};
  const selectedImporter = queryParams.importer ?? "";
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: shipperUser } = await supabase
    .from("shipper_users")
    .select("id, full_name, shippers(name)")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!shipperUser) redirect("/auth/check");

  const { data: rpcRows, error: rpcError } = await (supabase as any).rpc("shipper_shipment_batch_candidates_v1");
  const candidates = (rpcRows ?? []) as CandidateRow[];
  const groups = groupByImporter(candidates);
  const activeGroup = groups.find((group) => group.importerId === selectedImporter) ?? groups[0] ?? null;
  const shipper = Array.isArray((shipperUser as any).shippers) ? (shipperUser as any).shippers[0] : (shipperUser as any).shippers;

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-7xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <Link href="/shipper" className="text-sm font-semibold text-sky-700">← Back to shipper dashboard</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Goodcashback Shipper</p>
          <h1 className="mt-2 text-2xl font-semibold tracking-tight sm:text-3xl">Create shipment batch</h1>
          <p className="mt-2 text-sm text-slate-600">{shipperUser.full_name} · {shipper?.name ?? "Shipper"}</p>
          <p className="mt-3 max-w-4xl text-sm leading-6 text-slate-600">
            Select received-clean packages for one importer and group them under a booking ref. This creates package/shipment truth only. It does not generate COS/BOL, post to Sage, clear VAT, or lock item-content allocation.
          </p>
          {queryParams.success ? <p className="mt-4 rounded-xl border border-emerald-300 bg-emerald-50 px-3 py-2 text-sm text-emerald-900">{queryParams.success}</p> : null}
          {queryParams.error ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">{queryParams.error}</p> : null}
          {rpcError ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">{rpcError.message}</p> : null}
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
            <div>
              <h2 className="text-xl font-semibold">Eligible received packages</h2>
              <p className="mt-2 text-sm leading-6 text-slate-600">
                Only latest received-clean packages not already in an active shipment batch are shown.
              </p>
            </div>
            <form action="/shipper/shipments/new" className="flex flex-wrap items-end gap-3 rounded-2xl border border-slate-200 bg-slate-50 p-3">
              <label className="text-xs font-semibold uppercase tracking-wide text-slate-500">
                Importer
                <select name="importer" defaultValue={activeGroup?.importerId ?? ""} className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal text-slate-950">
                  {groups.length === 0 ? <option value="">No eligible importers</option> : null}
                  {groups.map((group) => (
                    <option key={group.importerId} value={group.importerId}>{group.importerName}</option>
                  ))}
                </select>
              </label>
              <button type="submit" className="rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800">Choose</button>
            </form>
          </div>

          {!activeGroup ? (
            <p className="mt-4 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-700">
              No received-clean packages are available for shipment batch selection yet.
            </p>
          ) : (
            <form action={createShipmentBatchAction} className="mt-5 space-y-5">
              <input type="hidden" name="importer_id" value={activeGroup.importerId} />
              <div className="rounded-3xl border border-slate-200 bg-slate-50 p-4">
                <h3 className="text-lg font-semibold">{activeGroup.importerName}</h3>
                <div className="mt-4 grid gap-3 md:grid-cols-3">
                  <label className="space-y-1 text-sm">
                    <span className="text-xs uppercase tracking-wide text-slate-500">Booking ref</span>
                    <input name="booking_ref" required className="w-full rounded-xl border border-slate-300 px-3 py-2" placeholder="Booking/reference" />
                  </label>
                  <label className="space-y-1 text-sm">
                    <span className="text-xs uppercase tracking-wide text-slate-500">Shipment cut-off</span>
                    <input name="shipment_cutoff_at" type="datetime-local" className="w-full rounded-xl border border-slate-300 px-3 py-2" />
                  </label>
                  <label className="space-y-1 text-sm">
                    <span className="text-xs uppercase tracking-wide text-slate-500">Dispatch date/time</span>
                    <input name="dispatched_at" type="datetime-local" className="w-full rounded-xl border border-slate-300 px-3 py-2" />
                  </label>
                  <label className="space-y-1 text-sm">
                    <span className="text-xs uppercase tracking-wide text-slate-500">Box/carton count</span>
                    <input name="box_count" type="number" min="0" step="1" className="w-full rounded-xl border border-slate-300 px-3 py-2" />
                  </label>
                  <label className="space-y-1 text-sm">
                    <span className="text-xs uppercase tracking-wide text-slate-500">Container ref</span>
                    <input name="container_ref" className="w-full rounded-xl border border-slate-300 px-3 py-2" placeholder="Optional" />
                  </label>
                  <label className="space-y-1 text-sm">
                    <span className="text-xs uppercase tracking-wide text-slate-500">BOL ref</span>
                    <input name="bol_ref" className="w-full rounded-xl border border-slate-300 px-3 py-2" placeholder="Optional" />
                  </label>
                  <label className="space-y-1 text-sm md:col-span-3">
                    <span className="text-xs uppercase tracking-wide text-slate-500">Notes</span>
                    <textarea name="notes" rows={2} className="w-full rounded-xl border border-slate-300 px-3 py-2" placeholder="Optional shipment/package notes" />
                  </label>
                </div>
              </div>

              <div className="overflow-x-auto rounded-3xl border border-slate-200 bg-white">
                <table className="min-w-full divide-y divide-slate-200 text-sm">
                  <thead className="bg-slate-100 text-xs uppercase tracking-wide text-slate-500">
                    <tr>
                      <th className="px-3 py-2 text-left">Select</th>
                      <th className="px-3 py-2 text-left">Order</th>
                      <th className="px-3 py-2 text-left">Retailer</th>
                      <th className="px-3 py-2 text-left">Tracking/package</th>
                      <th className="px-3 py-2 text-left">Date</th>
                      <th className="px-3 py-2 text-right">Allocated qty</th>
                      <th className="px-3 py-2 text-right">Allocated net</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-slate-100">
                    {activeGroup.rows.map((row) => (
                      <tr key={row.tracking_submission_id}>
                        <td className="px-3 py-2">
                          <input type="checkbox" name="tracking_submission_ids" value={row.tracking_submission_id} className="h-4 w-4" />
                        </td>
                        <td className="px-3 py-2 font-semibold">{row.order_ref ?? row.order_id}</td>
                        <td className="px-3 py-2">{row.retailer_name ?? "—"}</td>
                        <td className="px-3 py-2">{row.courier_name ?? "Courier"} · {row.tracking_ref}</td>
                        <td className="px-3 py-2">{row.tracking_date ?? "—"}</td>
                        <td className="px-3 py-2 text-right">{Number(row.allocated_qty ?? 0)}</td>
                        <td className="px-3 py-2 text-right font-semibold">{gbp(row.allocated_net_value_gbp)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>

              <button type="submit" className="rounded-xl bg-slate-900 px-5 py-3 text-sm font-semibold text-white hover:bg-slate-800">
                Create shipment batch
              </button>
            </form>
          )}
        </section>
      </div>
    </main>
  );
}
