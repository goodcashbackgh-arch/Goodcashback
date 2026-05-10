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
  latest_receipt_status?: string | null;
  latest_receipt_note?: string | null;
  latest_receipt_evidence_url?: string | null;
  latest_receipt_recorded_at?: string | null;
};

function gbp(value: unknown) {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" }).format(Number(value ?? 0));
}

function formatDate(value: string | null | undefined) {
  if (!value) return "—";
  return value;
}

function allocationStatusClass(row: PackageRow) {
  if (!row.tracking_submission_id) return "bg-slate-100 text-slate-700";
  if (row.allocation_status_summary && row.allocation_status_summary !== "not_allocated") return "bg-emerald-100 text-emerald-800";
  return "bg-amber-100 text-amber-800";
}

function allocationStatusLabel(row: PackageRow) {
  if (!row.tracking_submission_id) return "No tracking yet";
  if (row.allocation_status_summary && row.allocation_status_summary !== "not_allocated") {
    return `Allocated: ${row.allocation_status_summary.replaceAll("_", " ")}`;
  }
  return "Needs item allocation";
}

function receiptStatusLabel(status: string | null | undefined) {
  switch (status) {
    case "received_clean":
      return "Received clean";
    case "received_damaged":
      return "Damaged";
    case "held_query":
      return "Held / query";
    case "not_received":
      return "Not received";
    default:
      return "Awaiting receipt";
  }
}

function receiptStatusClass(status: string | null | undefined) {
  switch (status) {
    case "received_clean":
      return "bg-emerald-100 text-emerald-800";
    case "received_damaged":
      return "bg-rose-100 text-rose-800";
    case "held_query":
      return "bg-amber-100 text-amber-800";
    case "not_received":
      return "bg-slate-200 text-slate-800";
    default:
      return "bg-slate-100 text-slate-700";
  }
}

function groupByImporter(rows: PackageRow[]) {
  const groups = new Map<string, PackageRow[]>();
  for (const row of rows) {
    const key = `${row.importer_id ?? "unknown"}::${row.importer_name ?? "Unknown importer"}`;
    groups.set(key, [...(groups.get(key) ?? []), row]);
  }
  return Array.from(groups.entries()).map(([key, rows]) => {
    const [importerId, importerName] = key.split("::");
    return { importerId, importerName, rows };
  });
}

function matchesStatus(row: PackageRow, status: string) {
  if (!status || status === "all") return true;
  if (status === "with_tracking") return Boolean(row.tracking_submission_id);
  if (status === "no_tracking") return !row.tracking_submission_id;
  if (status === "allocated") return Boolean(row.tracking_submission_id) && Boolean(row.allocation_status_summary && row.allocation_status_summary !== "not_allocated");
  if (status === "needs_item_allocation") return Boolean(row.tracking_submission_id) && (!row.allocation_status_summary || row.allocation_status_summary === "not_allocated");
  if (status === "awaiting_receipt") return Boolean(row.tracking_submission_id) && !row.latest_receipt_status;
  if (status === "received_clean") return row.latest_receipt_status === "received_clean";
  if (status === "receipt_issue") return ["received_damaged", "held_query", "not_received"].includes(String(row.latest_receipt_status ?? ""));
  return true;
}

function filterLabel(status: string) {
  switch (status) {
    case "with_tracking": return "With tracking/package";
    case "no_tracking": return "No tracking yet";
    case "allocated": return "Item allocated";
    case "needs_item_allocation": return "Needs item allocation";
    case "awaiting_receipt": return "Awaiting receipt";
    case "received_clean": return "Received clean";
    case "receipt_issue": return "Receipt issue";
    default: return "All statuses";
  }
}

export default async function ShipperPage({
  searchParams,
}: {
  searchParams?: Promise<{ importer?: string; status?: string }>;
}) {
  const queryParams = searchParams ? await searchParams : {};
  const selectedImporter = queryParams.importer ?? "all";
  const selectedStatus = queryParams.status ?? "all";
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

  const { data: rpcRows, error: rpcError } = await (supabase as any).rpc("shipper_package_receipt_dashboard_v1");
  const rows = ((rpcRows ?? []) as PackageRow[]);
  const filteredRows = rows.filter((row) => {
    const importerMatch = selectedImporter === "all" || row.importer_id === selectedImporter;
    return importerMatch && matchesStatus(row, selectedStatus);
  });
  const packageRows = rows.filter((row) => Boolean(row.tracking_submission_id));
  const allocatedPackages = packageRows.filter((row) => row.allocation_status_summary && row.allocation_status_summary !== "not_allocated");
  const unallocatedPackages = packageRows.length - allocatedPackages.length;
  const awaitingReceiptPackages = packageRows.filter((row) => !row.latest_receipt_status);
  const receiptIssuePackages = packageRows.filter((row) => ["received_damaged", "held_query", "not_received"].includes(String(row.latest_receipt_status ?? "")));
  const importerGroups = groupByImporter(filteredRows);
  const importerOptions = groupByImporter(rows);
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
            This dashboard is scoped to your shipper account. Work by importer and package row: review tracking evidence, record receipt, and keep package-level truth separate from item-content allocation.
          </p>
          {rpcError ? (
            <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">
              Receipt dashboard RPC is not available yet: {rpcError.message}. Apply the latest Supabase migration before live package testing.
            </p>
          ) : null}
        </section>

        <section className="grid gap-4 md:grid-cols-6">
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
          <div className={`rounded-3xl border p-4 shadow-sm ${awaitingReceiptPackages.length > 0 ? "border-sky-200 bg-sky-50" : "border-slate-200 bg-white"}`}>
            <p className="text-xs uppercase tracking-wide text-slate-500">Awaiting receipt</p>
            <p className="mt-1 text-2xl font-semibold">{awaitingReceiptPackages.length}</p>
          </div>
          <div className={`rounded-3xl border p-4 shadow-sm ${receiptIssuePackages.length > 0 ? "border-rose-200 bg-rose-50" : "border-slate-200 bg-white"}`}>
            <p className="text-xs uppercase tracking-wide text-slate-500">Receipt issues</p>
            <p className="mt-1 text-2xl font-semibold">{receiptIssuePackages.length}</p>
          </div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
            <div>
              <h2 className="text-xl font-semibold">Package worklist</h2>
              <p className="mt-2 text-sm leading-6 text-slate-600">
                Receipt actions sit next to each package. Orders with no tracking remain in the same importer section so there is one worklist, not duplicate sections.
              </p>
            </div>
            <form action="/shipper" className="grid gap-3 rounded-2xl border border-slate-200 bg-slate-50 p-3 sm:grid-cols-[1fr_1fr_auto]">
              <label className="text-xs font-semibold uppercase tracking-wide text-slate-500">
                Importer
                <select name="importer" defaultValue={selectedImporter} className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal text-slate-950">
                  <option value="all">All importers</option>
                  {importerOptions.map((group) => (
                    <option key={group.importerId} value={group.importerId}>{group.importerName}</option>
                  ))}
                </select>
              </label>
              <label className="text-xs font-semibold uppercase tracking-wide text-slate-500">
                Status
                <select name="status" defaultValue={selectedStatus} className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal text-slate-950">
                  <option value="all">All statuses</option>
                  <option value="with_tracking">With tracking/package</option>
                  <option value="no_tracking">No tracking yet</option>
                  <option value="allocated">Item allocated</option>
                  <option value="needs_item_allocation">Needs item allocation</option>
                  <option value="awaiting_receipt">Awaiting receipt</option>
                  <option value="received_clean">Received clean</option>
                  <option value="receipt_issue">Receipt issue</option>
                </select>
              </label>
              <div className="flex items-end gap-2">
                <button type="submit" className="rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800">Apply</button>
                <Link href="/shipper" className="rounded-xl border border-slate-300 bg-white px-4 py-2 text-sm font-semibold text-slate-800 hover:bg-slate-100">Reset</Link>
              </div>
            </form>
          </div>

          <p className="mt-4 text-xs font-semibold uppercase tracking-wide text-slate-500">
            Showing {filteredRows.length} row(s) · {selectedImporter === "all" ? "All importers" : importerOptions.find((group) => group.importerId === selectedImporter)?.importerName ?? "Selected importer"} · {filterLabel(selectedStatus)}
          </p>

          {filteredRows.length === 0 ? (
            <p className="mt-4 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-700">
              No rows match the selected filters.
            </p>
          ) : (
            <div className="mt-5 space-y-5">
              {importerGroups.map((group) => (
                <article key={group.importerId} className="rounded-3xl border border-slate-200 bg-slate-50 p-4">
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
                          <th className="px-3 py-2 text-left">Allocation</th>
                          <th className="px-3 py-2 text-left">Receipt</th>
                          <th className="px-3 py-2 text-left">Evidence</th>
                          <th className="px-3 py-2 text-left">Action</th>
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
                              <span className={`rounded-full px-2 py-1 text-xs font-semibold ${allocationStatusClass(row)}`}>{allocationStatusLabel(row)}</span>
                            </td>
                            <td className="px-3 py-2">
                              <span className={`rounded-full px-2 py-1 text-xs font-semibold ${receiptStatusClass(row.latest_receipt_status)}`}>{receiptStatusLabel(row.latest_receipt_status)}</span>
                              {row.latest_receipt_note ? <p className="mt-1 text-xs text-slate-500">{row.latest_receipt_note}</p> : null}
                            </td>
                            <td className="px-3 py-2">
                              {row.tracking_evidence_url ? <a href={row.tracking_evidence_url} target="_blank" rel="noreferrer" className="font-semibold text-sky-700 underline">Tracking</a> : "—"}
                              {row.latest_receipt_evidence_url ? <a href={row.latest_receipt_evidence_url} target="_blank" rel="noreferrer" className="ml-2 font-semibold text-sky-700 underline">Receipt</a> : null}
                            </td>
                            <td className="px-3 py-2">
                              {row.tracking_submission_id ? (
                                <Link href={`/shipper/package-receipts?tracking=${row.tracking_submission_id}`} className="rounded-xl bg-slate-900 px-3 py-2 text-xs font-semibold text-white hover:bg-slate-800">
                                  Record receipt
                                </Link>
                              ) : (
                                <span className="text-xs text-slate-500">Waiting for operator tracking</span>
                              )}
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
      </div>
    </main>
  );
}
