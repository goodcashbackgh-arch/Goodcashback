import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type IncomingTrafficRow = {
  order_id: string;
  order_date: string;
  importer_id: string;
  importer_name: string | null;
  retailer_id: string;
  retailer_name: string | null;
  order_ref: string;
  total_qty_declared: number;
};

type SearchParams = {
  importer?: string;
  date_from?: string;
  date_to?: string;
  retailer?: string;
  qty?: string;
  order_ref?: string;
};

function formatOrderDate(value: string) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return new Intl.DateTimeFormat("en-GB", {
    day: "2-digit",
    month: "short",
    year: "numeric",
  }).format(date);
}

export default async function IncomingTrafficPage({
  searchParams,
}: {
  searchParams?: Promise<SearchParams>;
}) {
  const queryParams = searchParams ? await searchParams : {};
  const selectedImporter = queryParams.importer ?? "all";
  const selectedRetailer = queryParams.retailer ?? "all";
  const selectedDateFrom = queryParams.date_from ?? "";
  const selectedDateTo = queryParams.date_to ?? "";
  const selectedQty = queryParams.qty ?? "";
  const selectedOrderRef = (queryParams.order_ref ?? "").trim();

  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: shipperUser } = await supabase
    .from("shipper_users")
    .select("id")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();
  if (!shipperUser) redirect("/auth/check");

  const { data: rpcRows, error: rpcError } = await (supabase as any).rpc("shipper_incoming_traffic_v1");
  const rows = (rpcRows ?? []) as IncomingTrafficRow[];

  const qtyFilter = selectedQty === "" ? null : Number(selectedQty);
  const orderRefFilter = selectedOrderRef.toLocaleLowerCase("en-GB");

  const filteredRows = rows.filter((row) => {
    if (selectedImporter !== "all" && row.importer_id !== selectedImporter) return false;
    if (selectedRetailer !== "all" && row.retailer_id !== selectedRetailer) return false;
    if (selectedDateFrom && row.order_date.slice(0, 10) < selectedDateFrom) return false;
    if (selectedDateTo && row.order_date.slice(0, 10) > selectedDateTo) return false;
    if (qtyFilter !== null && (!Number.isFinite(qtyFilter) || Number(row.total_qty_declared) !== qtyFilter)) return false;
    if (orderRefFilter && !String(row.order_ref ?? "").toLocaleLowerCase("en-GB").includes(orderRefFilter)) return false;
    return true;
  });

  const importerOptions = Array.from(
    new Map(rows.map((row) => [row.importer_id, row.importer_name ?? "Unknown importer"])).entries(),
  ).sort((a, b) => a[1].localeCompare(b[1]));

  const retailerOptions = Array.from(
    new Map(rows.map((row) => [row.retailer_id, row.retailer_name ?? "Unknown retailer"])).entries(),
  ).sort((a, b) => a[1].localeCompare(b[1]));

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto flex max-w-7xl flex-col gap-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <p className="text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Goods To Ship Shipper</p>
          <div className="mt-2 flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
            <div>
              <h1 className="text-2xl font-semibold tracking-tight sm:text-3xl">Incoming traffic</h1>
              <p className="mt-2 text-sm text-slate-600">Orders in your shipper lane that do not yet have an item linked to tracking.</p>
            </div>
            <Link href="/shipper" className="w-fit rounded-xl border border-slate-300 bg-white px-4 py-2 text-sm font-semibold">Back to shipper dashboard</Link>
          </div>
          {rpcError ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">{rpcError.message}</p> : null}
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-col gap-4">
            <div>
              <h2 className="text-xl font-semibold">Incoming traffic</h2>
              <p className="mt-2 text-sm text-slate-600">Filter the orders currently awaiting an item-to-tracking association.</p>
            </div>

            <form action="/shipper/incoming-traffic" className="grid gap-3 rounded-2xl border border-slate-200 bg-slate-50 p-3 sm:grid-cols-2 xl:grid-cols-[1fr_1fr_1fr_1fr_0.7fr_1.2fr_auto]">
              <label className="text-xs font-semibold uppercase tracking-wide text-slate-500">Importer
                <select name="importer" defaultValue={selectedImporter} className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal">
                  <option value="all">All importers</option>
                  {importerOptions.map(([id, name]) => <option key={id} value={id}>{name}</option>)}
                </select>
              </label>

              <label className="text-xs font-semibold uppercase tracking-wide text-slate-500">Date from
                <input type="date" name="date_from" defaultValue={selectedDateFrom} className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal" />
              </label>

              <label className="text-xs font-semibold uppercase tracking-wide text-slate-500">Date to
                <input type="date" name="date_to" defaultValue={selectedDateTo} className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal" />
              </label>

              <label className="text-xs font-semibold uppercase tracking-wide text-slate-500">Retailer
                <select name="retailer" defaultValue={selectedRetailer} className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal">
                  <option value="all">All retailers</option>
                  {retailerOptions.map(([id, name]) => <option key={id} value={id}>{name}</option>)}
                </select>
              </label>

              <label className="text-xs font-semibold uppercase tracking-wide text-slate-500">Qty
                <input type="number" min="1" step="1" name="qty" defaultValue={selectedQty} className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal" />
              </label>

              <label className="text-xs font-semibold uppercase tracking-wide text-slate-500">Order ref
                <input type="text" name="order_ref" defaultValue={selectedOrderRef} className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal" />
              </label>

              <div className="flex items-end gap-2">
                <button type="submit" className="rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white">Apply</button>
                <Link href="/shipper/incoming-traffic" className="rounded-xl border border-slate-300 bg-white px-4 py-2 text-sm font-semibold">Reset</Link>
              </div>
            </form>
          </div>

          <p className="mt-4 text-xs font-semibold uppercase tracking-wide text-slate-500">Showing {filteredRows.length} row(s)</p>

          {filteredRows.length === 0 ? (
            <p className="mt-5 rounded-2xl border border-slate-200 bg-slate-50 px-4 py-5 text-sm text-slate-600">No incoming traffic awaiting item/tracking allocation.</p>
          ) : (
            <div className="mt-5 overflow-x-auto rounded-2xl border border-slate-200 bg-white">
              <table className="min-w-full divide-y divide-slate-200 text-sm">
                <thead className="bg-slate-100 text-xs uppercase tracking-wide text-slate-500">
                  <tr>
                    <th className="px-3 py-2 text-left">Order date</th>
                    <th className="px-3 py-2 text-left">Importer</th>
                    <th className="px-3 py-2 text-left">Retailer</th>
                    <th className="px-3 py-2 text-left">Order ref</th>
                    <th className="px-3 py-2 text-right">Qty</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-100">
                  {filteredRows.map((row) => (
                    <tr key={row.order_id}>
                      <td className="px-3 py-2">{formatOrderDate(row.order_date)}</td>
                      <td className="px-3 py-2">{row.importer_name ?? "—"}</td>
                      <td className="px-3 py-2">{row.retailer_name ?? "—"}</td>
                      <td className="px-3 py-2 font-semibold">{row.order_ref}</td>
                      <td className="px-3 py-2 text-right">{Number(row.total_qty_declared)}</td>
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
