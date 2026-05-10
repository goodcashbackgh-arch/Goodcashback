import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type PackageRow = {
  shipper_user_id: string;
  shipper_id: string;
  shipper_name: string | null;
  importer_id: string | null;
  importer_name: string | null;
  order_id: string;
  order_ref: string | null;
  retailer_name: string | null;
  tracking_submission_id: string | null;
  courier_name: string | null;
  tracking_ref: string | null;
  tracking_date: string | null;
  submitted_at: string | null;
  is_final_delivery_yn: boolean | null;
  tracking_evidence_url: string | null;
  tracking_note: string | null;
  allocated_qty: number | null;
  allocated_net_value_gbp: number | null;
  allocation_status_summary: string | null;
};

function gbp(value: unknown) {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" }).format(Number(value ?? 0));
}

function formatDate(value: string | null | undefined) {
  if (!value) return "—";
  return value;
}

function statusClass(row: PackageRow) {
  if (!row.tracking_submission_id) return "bg-slate-100 text-slate-700";
  if (row.allocation_status_summary && row.allocation_status_summary !== "not_allocated") return "bg-emerald-100 text-emerald-800";
  return "bg-amber-100 text-amber-800";
}

function statusLabel(row: PackageRow) {
  if (!row.tracking_submission_id) return "No tracking yet";
  if (row.allocation_status_summary && row.allocation_status_summary !== "not_allocated") {
    return `Allocated: ${row.allocation_status_summary.replaceAll("_", " ")}`;
  }
  return "Package not item-allocated yet";
}

function groupByImporter(rows: PackageRow[]) {
  const groups = new Map<string, PackageRow[]>();
  for (const row of rows) {
    const key = `${row.importer_id ?? "unknown"}::${row.importer_name ?? "Unknown importer"}`;
    groups.set(key, [...(groups.get(key) ?? []), row]);
  }
  return Array.from(groups.entries()).map(([key, rows]) => {
    const [, importerName] = key.split("::");
    return { importerName, rows };
  });
}

export default async function ShipperPage() {
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/login");
  }

  const { data: shipperUser } = await supabase
    .from("shipper_users")
    .select("id, full_name, shipper_id, role_at_shipper, permissions_json, shippers(name)")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!shipperUser) {
    redirect("/auth/check");
  }

  const { data: rpcRows, error: rpcError } = await (supabase as any).rpc("shipper_package_dashboard_v1");
  const rows = ((rpcRows ?? []) as PackageRow[]);
  const packageRows = rows.filter((row) => Boolean(row.tracking_submission_id));
  const ordersWithoutTracking = rows.filter((row) => !row.tracking_submission_id);
  const allocatedPackages = packageRows.filter((row) => row.allocation_status_summary && row.allocation_status_summary !== "not_allocated");
  const unallocatedPackages = packageRows.length - allocatedPackages.length;
  const importerGroups = groupByImporter(rows);
  const shipper = Array.isArray((shipperUser as any).shippers) ? (shipperUser as any).shippers[0] : (shipperUser as any).shippers;
  const shipperName = shipper?.name ?? rows[0]?.shipper_name ?? "Shipper";

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto flex max-w-7xl flex-col gap-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <p className="text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Goodcashback Shipper</p>
          <h1 className="mt-2 text-2xl font-semibold tracking-tight sm:text-3xl">Package receipt dashboard</h1>
          <p className="mt-2 text-sm text-slate-600">
            Welcome: <span className="font-semibold text-slate-900">{shipperUser.full_name}</span> · {shipperName}
          </p>
          <p className="mt-3 max-w-4xl text-sm leading-6 text-slate-600">
            This dashboard is scoped to your shipper account. It shows expected tracking refs/packages grouped by importer/order. Shipper work stays package-level: receive, hold, damage/query, and later select received packages into shipment batches.
          </p>
          <div className="mt-5 flex flex-wrap gap-3">
            <Link href="/shipper/package-receipts" className="rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800">
              Record package receipt
            </Link>
          </div>
          {rpcError ? (
            <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">
              Dashboard RPC is not available yet: {rpcError.message}. Apply the latest Supabase migration before live package testing.
            </p>
          ) : null}
        </section>

        <section className="grid gap-4 md:grid-cols-4">
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
            <p className="text-xs uppercase tracking-wide text-slate-500">Orders in shipper lane</p>
            <p className="mt-1 text-2xl font-semibold">{new Set(rows.map((row) => row.order_id)).size}</p>
          </div>
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
            <p className="text-xs uppercase tracking-wide text-slate-500">Tracking refs/packages</p>
            <p className="mt-1 text-2xl font-semibold">{packageRows.length}</p>
          </div>
          <div className="rounded-3xl border border-emerald-200 bg-emerald-50 p-4 shadow-sm">
            <p className="text-xs uppercase tracking-wide text-emerald-700">Allocated packages</p>
            <p className="mt-1 text-2xl font-semibold text-emerald-950">{allocatedPackages.length}</p>
          </div>
          <div className={`rounded-3xl border p-4 shadow-sm ${unallocatedPackages > 0 ? "border-amber-200 bg-amber-50" : "border-slate-200 bg-white"}`}>
            <p className="text-xs uppercase tracking-wide text-slate-500">Need item allocation</p>
            <p className="mt-1 text-2xl font-semibold">{unallocatedPackages}</p>
          </div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
            <div>
              <h2 className="text-xl font-semibold">Outstanding package list</h2>
              <p className="mt-2 text-sm leading-6 text-slate-600">
                Use the package receipt action page to record received clean, damaged, held/query, or not received. This dashboard remains the scoped package overview.
              </p>
            </div>
            <Link href="/shipper/package-receipts" className="rounded-full bg-sky-100 px-3 py-1 text-xs font-semibold text-sky-800 hover:bg-sky-200">
              Package receipt actions
            </Link>
          </div>

          {rows.length === 0 ? (
            <p className="mt-4 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-700">
              No assigned orders or tracking refs are currently visible for this shipper.
            </p>
          ) : (
            <div className="mt-5 space-y-5">
              {importerGroups.map((group) => (
                <article key={group.importerName} className="rounded-3xl border border-slate-200 bg-slate-50 p-4">
                  <h3 className="text-lg font-semibold">{group.importerName}</h3>
                  <div className="mt-3 overflow-x-auto rounded-2xl border border-slate-200 bg-white">
                    <table className="min-w-full divide-y divide-slate-200 text-sm">
                      <thead className="bg-slate-100 text-xs uppercase tracking-wide text-slate-500">
                        <tr>
                          <th className="px-3 py-2 text-left">Order</th>
                          <th className="px-3 py-2 text-left">Retailer</th>
                          <th className="px-3 py-2 text-left">Tracking/package</th>
                          <th className="px-3 py-2 text-left">Date</th>
                          <th className="px-3 py-2 text-right">Allocated qty</th>
                          <th className="px-3 py-2 text-right">Allocated net</th>
                          <th className="px-3 py-2 text-left">Status</th>
                          <th className="px-3 py-2 text-left">Evidence</th>
                        </tr>
                      </thead>
                      <tbody className="divide-y divide-slate-100">
                        {group.rows.map((row) => (
                          <tr key={`${row.order_id}-${row.tracking_submission_id ?? "no-tracking"}`}>
                            <td className="px-3 py-2 font-semibold">{row.order_ref ?? row.order_id}</td>
                            <td className="px-3 py-2">{row.retailer_name ?? "—"}</td>
                            <td className="px-3 py-2">
                              {row.tracking_submission_id ? (
                                <div>
                                  <p className="font-semibold">{row.courier_name ?? "Courier"} · {row.tracking_ref}</p>
                                  {row.is_final_delivery_yn ? <p className="text-xs font-medium text-emerald-700">Final retailer delivery marker</p> : null}
                                  {row.tracking_note ? <p className="mt-1 text-xs text-slate-500">{row.tracking_note}</p> : null}
                                </div>
                              ) : (
                                <span className="text-slate-500">No tracking submitted</span>
                              )}
                            </td>
                            <td className="px-3 py-2">{formatDate(row.tracking_date ?? row.submitted_at)}</td>
                            <td className="px-3 py-2 text-right">{Number(row.allocated_qty ?? 0)}</td>
                            <td className="px-3 py-2 text-right font-semibold">{gbp(row.allocated_net_value_gbp)}</td>
                            <td className="px-3 py-2">
                              <span className={`rounded-full px-2 py-1 text-xs font-semibold ${statusClass(row)}`}>{statusLabel(row)}</span>
                            </td>
                            <td className="px-3 py-2">
                              {row.tracking_evidence_url ? <a href={row.tracking_evidence_url} target="_blank" rel="noreferrer" className="font-semibold text-sky-700 underline">Open</a> : "—"}
                            </td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                </article>
              ))}
            </div>
          )}
        </section>

        {ordersWithoutTracking.length > 0 ? (
          <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 shadow-sm sm:p-6">
            <h2 className="text-xl font-semibold text-amber-950">Orders with no tracking yet</h2>
            <p className="mt-2 text-sm text-amber-900">These are assigned to your shipper, but the operator has not submitted tracking refs/packages yet.</p>
            <ul className="mt-3 space-y-2 text-sm text-amber-950">
              {ordersWithoutTracking.map((row) => (
                <li key={row.order_id} className="rounded-xl border border-amber-200 bg-white/70 p-3">
                  {row.order_ref ?? row.order_id} · {row.retailer_name ?? "Retailer"} · {row.importer_name ?? "Importer"}
                </li>
              ))}
            </ul>
          </section>
        ) : null}
      </div>
    </main>
  );
}
