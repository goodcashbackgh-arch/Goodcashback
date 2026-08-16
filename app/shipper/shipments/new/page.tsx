import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { createExactShipmentBatchAction } from "./exact-actions";
import ShipmentSelectionControls from "./ShipmentSelectionControls";
import { PackageContentsPreview } from "../../PackageContentsPreview";

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

  const { data: rpcRows, error: rpcError } = await (supabase as any).rpc("shipper_shipment_batch_candidates_v2");
  const candidates = (rpcRows ?? []) as CandidateRow[];
  const groups = groupByImporter(candidates);
  const activeGroup = groups.find((group) => group.importerId === selectedImporter) ?? groups[0] ?? null;
  const shipper = Array.isArray((shipperUser as any).shippers) ? (shipperUser as any).shippers[0] : (shipperUser as any).shippers;

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-7xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <Link href="/shipper" className="text-sm font-semibold text-sky-700">← Back to shipper dashboard</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Goods To Ship Shipper</p>
          <h1 className="mt-2 text-2xl font-semibold tracking-tight sm:text-3xl">Create shipment batch</h1>
          <p className="mt-2 text-sm text-slate-600">{shipperUser.full_name} · {shipper?.name ?? "Shipper"}</p>
          <p className="mt-3 max-w-4xl text-sm leading-6 text-slate-600">
            Select received-clean packages for one importer and group them under a booking ref. The quantity and contents shown here are shipment eligible after active hold conflicts are removed. This does not create COS/BOL/POD, post to Sage, clear VAT, or change receipt history.
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
                Only latest received-clean packages not already in an active shipment batch are shown. Shipment-eligible contents show description and quantity only — no values.
              </p>
            </div>
            <form action="/shipper/shipments/new" className="flex flex-wrap items-end gap-3 rounded-2xl border border-slate-200 bg-slate-50 p-3">
              <label className="min-w-0 text-xs font-semibold uppercase tracking-wide text-slate-500">
                Importer
                <select name="importer" defaultValue={activeGroup?.importerId ?? ""} className="mt-1 w-full min-w-0 max-w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal text-slate-950">
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
            <form id="shipper-shipment-batch-create-form" action={createExactShipmentBatchAction} className="mt-5 space-y-5">
              <input type="hidden" name="importer_id" value={activeGroup.importerId} />
              <div className="min-w-0 overflow-hidden rounded-3xl border border-slate-200 bg-slate-50 p-4">
                <h3 className="break-words text-lg font-semibold">{activeGroup.importerName}</h3>
                <div className="mt-4 grid min-w-0 gap-3 md:grid-cols-2 xl:grid-cols-3">
                  <label className="min-w-0 space-y-1 text-sm">
                    <span className="text-xs uppercase tracking-wide text-slate-500">Booking ref</span>
                    <input name="booking_ref" required className="block w-full min-w-0 max-w-full rounded-xl border border-slate-300 px-3 py-2" placeholder="Booking/reference" />
                  </label>
                  <label className="min-w-0 space-y-1 text-sm">
                    <span className="text-xs uppercase tracking-wide text-slate-500">Shipment cut-off</span>
                    <input name="shipment_cutoff_at" type="datetime-local" className="block w-full min-w-0 max-w-full rounded-xl border border-slate-300 px-3 py-2" />
                  </label>
                  <label className="min-w-0 space-y-1 text-sm">
                    <span className="text-xs uppercase tracking-wide text-slate-500">Dispatch date/time</span>
                    <input name="dispatched_at" type="datetime-local" className="block w-full min-w-0 max-w-full rounded-xl border border-slate-300 px-3 py-2" />
                  </label>
                  <label className="min-w-0 space-y-1 text-sm">
                    <span className="text-xs uppercase tracking-wide text-slate-500">Box/carton count</span>
                    <input name="box_count" type="number" min="0" step="1" className="block w-full min-w-0 max-w-full rounded-xl border border-slate-300 px-3 py-2" />
                  </label>
                  <label className="min-w-0 space-y-1 text-sm md:col-span-2 xl:col-span-2">
                    <span className="text-xs uppercase tracking-wide text-slate-500">Notes</span>
                    <input name="notes" className="block w-full min-w-0 max-w-full rounded-xl border border-slate-300 px-3 py-2" placeholder="Optional package/shipment note" />
                  </label>
                </div>
              </div>

              <ShipmentSelectionControls
                formId="shipper-shipment-batch-create-form"
                selectableCount={new Set(activeGroup.rows.map((row) => row.tracking_submission_id)).size}
              />

              <div className="space-y-3 md:hidden">
                {activeGroup.rows.map((row) => (
                  <article key={row.tracking_submission_id} className="min-w-0 overflow-hidden rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
                    <label className="flex min-w-0 items-start gap-3">
                      <input
                        type="checkbox"
                        name="tracking_submission_ids"
                        value={row.tracking_submission_id}
                        data-shipment-batch-select="true"
                        className="mt-1 h-5 w-5 shrink-0"
                      />
                      <span className="min-w-0">
                        <span className="block text-xs font-semibold uppercase tracking-wide text-slate-500">Order</span>
                        <span className="mt-1 block break-all font-semibold text-slate-950">{row.order_ref ?? row.order_id}</span>
                      </span>
                    </label>

                    <dl className="mt-4 grid min-w-0 grid-cols-2 gap-x-4 gap-y-3 text-sm">
                      <div className="min-w-0">
                        <dt className="text-xs font-semibold uppercase tracking-wide text-slate-500">Retailer</dt>
                        <dd className="mt-1 break-words text-slate-900">{row.retailer_name ?? "—"}</dd>
                      </div>
                      <div className="min-w-0">
                        <dt className="text-xs font-semibold uppercase tracking-wide text-slate-500">Eligible qty</dt>
                        <dd className="mt-1 font-semibold text-slate-950">{Number(row.allocated_qty ?? 0)}</dd>
                      </div>
                      <div className="col-span-2 min-w-0">
                        <dt className="text-xs font-semibold uppercase tracking-wide text-slate-500">Tracking/package</dt>
                        <dd className="mt-1 break-all text-slate-900">{row.courier_name ?? "Courier"} · {row.tracking_ref}</dd>
                      </div>
                      <div className="min-w-0">
                        <dt className="text-xs font-semibold uppercase tracking-wide text-slate-500">Date</dt>
                        <dd className="mt-1 text-slate-900">{row.tracking_date ?? "—"}</dd>
                      </div>
                    </dl>

                    <div className="mt-4 min-w-0 overflow-hidden border-t border-slate-200 pt-4">
                      <p className="mb-2 text-xs font-semibold uppercase tracking-wide text-slate-500">Shipment-eligible contents</p>
                      <PackageContentsPreview trackingSubmissionId={row.tracking_submission_id} compact />
                    </div>
                  </article>
                ))}
              </div>

              <div className="hidden overflow-x-auto rounded-3xl border border-slate-200 bg-white md:block">
                <table className="min-w-full divide-y divide-slate-200 text-sm">
                  <thead className="bg-slate-100 text-xs uppercase tracking-wide text-slate-500">
                    <tr>
                      <th className="px-3 py-2 text-left">Select</th>
                      <th className="px-3 py-2 text-left">Order</th>
                      <th className="px-3 py-2 text-left">Retailer</th>
                      <th className="px-3 py-2 text-left">Tracking/package</th>
                      <th className="px-3 py-2 text-left">Date</th>
                      <th className="px-3 py-2 text-right">Eligible qty</th>
                      <th className="px-3 py-2 text-left">Shipment-eligible contents</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-slate-100">
                    {activeGroup.rows.map((row) => (
                      <tr key={row.tracking_submission_id}>
                        <td className="px-3 py-2">
                          <input type="checkbox" name="tracking_submission_ids" value={row.tracking_submission_id} data-shipment-batch-select="true" className="h-4 w-4" />
                        </td>
                        <td className="px-3 py-2 font-semibold">{row.order_ref ?? row.order_id}</td>
                        <td className="px-3 py-2">{row.retailer_name ?? "—"}</td>
                        <td className="px-3 py-2">{row.courier_name ?? "Courier"} · {row.tracking_ref}</td>
                        <td className="px-3 py-2">{row.tracking_date ?? "—"}</td>
                        <td className="px-3 py-2 text-right">{Number(row.allocated_qty ?? 0)}</td>
                        <td className="px-3 py-2"><PackageContentsPreview trackingSubmissionId={row.tracking_submission_id} compact /></td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>

              <button type="submit" className="w-full rounded-xl bg-slate-900 px-5 py-3 text-sm font-semibold text-white hover:bg-slate-800 sm:w-auto">
                Create shipment batch
              </button>
            </form>
          )}
        </section>
      </div>
    </main>
  );
}
