import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { recordPackageReceiptAction } from "../actions";
import { OriginalPackageContentsPreview } from "../OriginalPackageContentsPreview";

type PackageRow = {
  order_id: string;
  order_ref: string | null;
  importer_name: string | null;
  retailer_name: string | null;
  tracking_submission_id: string | null;
  courier_name: string | null;
  tracking_ref: string | null;
  tracking_date: string | null;
  tracking_evidence_url: string | null;
  allocated_qty: number | null;
  latest_receipt_status?: string | null;
  latest_receipt_note?: string | null;
  latest_receipt_evidence_url?: string | null;
  latest_receipt_recorded_at?: string | null;
};

type SearchParams = {
  success?: string;
  error?: string;
  tracking?: string;
  q?: string;
  importer?: string;
  status?: string;
};

function receiptLabel(status: string | null | undefined) {
  switch (status) {
    case "received_clean": return "Package received clean";
    case "received_damaged": return "Package received damaged";
    case "held_query": return "Package held / query";
    case "not_received": return "Package not received";
    default: return "Awaiting package receipt";
  }
}

function receiptClass(status: string | null | undefined) {
  switch (status) {
    case "received_clean": return "bg-emerald-100 text-emerald-800";
    case "received_damaged": return "bg-rose-100 text-rose-800";
    case "held_query": return "bg-amber-100 text-amber-800";
    case "not_received": return "bg-slate-200 text-slate-800";
    default: return "bg-slate-100 text-slate-700";
  }
}

export default async function ShipperPackageReceiptsPage({
  searchParams,
}: {
  searchParams?: Promise<SearchParams>;
}) {
  const queryParams = searchParams ? await searchParams : {};
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

  const { data: rpcRows, error: rpcError } = await (supabase as any).rpc("shipper_package_receipt_dashboard_v1");
  const allRows = ((rpcRows ?? []) as PackageRow[]).filter((row) => row.tracking_submission_id);
  const search = (queryParams.q ?? "").trim().toLowerCase();
  const importer = (queryParams.importer ?? "").trim();
  const status = (queryParams.status ?? "").trim();
  const importers = Array.from(new Set(
    allRows.map((row) => row.importer_name?.trim()).filter((value): value is string => Boolean(value)),
  )).sort((a, b) => a.localeCompare(b));

  const rows = allRows.filter((row) => {
    if (queryParams.tracking && row.tracking_submission_id !== queryParams.tracking) return false;
    if (importer && row.importer_name !== importer) return false;
    if (status === "awaiting" && row.latest_receipt_status) return false;
    if (status && status !== "awaiting" && row.latest_receipt_status !== status) return false;
    if (!search) return true;
    return [row.tracking_ref, row.order_ref, row.order_id]
      .some((value) => value?.toLowerCase().includes(search));
  });

  const shipper = Array.isArray((shipperUser as any).shippers) ? (shipperUser as any).shippers[0] : (shipperUser as any).shippers;

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-7xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <Link href="/shipper" className="text-sm font-semibold text-sky-700">← Back to shipper dashboard</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Goodcashback Shipper</p>
          <h1 className="mt-2 text-2xl font-semibold tracking-tight sm:text-3xl">Package receipt actions</h1>
          <p className="mt-2 text-sm text-slate-600">{shipperUser.full_name} · {shipper?.name ?? "Shipper"}</p>
          <p className="mt-3 max-w-4xl text-sm leading-6 text-slate-600">
            Record package-level physical truth only. Original contents remain visible even when an item later moves to a hold, return or refund path. This does not create a shipment, final export evidence or downstream accounting effects.
          </p>
          {queryParams.success ? <p className="mt-4 rounded-xl border border-emerald-300 bg-emerald-50 px-3 py-2 text-sm text-emerald-900">{queryParams.success}</p> : null}
          {queryParams.error ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">{queryParams.error}</p> : null}
          {rpcError ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">{rpcError.message}</p> : null}
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
            <div>
              <h2 className="text-xl font-semibold">Tracking refs / packages</h2>
              <p className="mt-1 text-sm text-slate-600">Showing {rows.length} of {allRows.length} shipper-visible packages.</p>
            </div>
            <form method="get" className="grid w-full gap-3 sm:grid-cols-2 lg:max-w-4xl lg:grid-cols-[minmax(220px,1fr)_minmax(180px,0.8fr)_minmax(180px,0.8fr)_auto]">
              <label className="space-y-1 text-sm">
                <span className="text-xs uppercase tracking-wide text-slate-500">Search</span>
                <input name="q" defaultValue={queryParams.q ?? ""} className="w-full rounded-xl border border-slate-300 px-3 py-2" placeholder="Tracking or order reference" />
              </label>
              <label className="space-y-1 text-sm">
                <span className="text-xs uppercase tracking-wide text-slate-500">Importer</span>
                <select name="importer" defaultValue={importer} className="w-full rounded-xl border border-slate-300 px-3 py-2">
                  <option value="">All importers</option>
                  {importers.map((name) => <option key={name} value={name}>{name}</option>)}
                </select>
              </label>
              <label className="space-y-1 text-sm">
                <span className="text-xs uppercase tracking-wide text-slate-500">Receipt status</span>
                <select name="status" defaultValue={status} className="w-full rounded-xl border border-slate-300 px-3 py-2">
                  <option value="">All statuses</option>
                  <option value="awaiting">Awaiting package receipt</option>
                  <option value="received_clean">Package received clean</option>
                  <option value="received_damaged">Package received damaged</option>
                  <option value="held_query">Package held / query</option>
                  <option value="not_received">Package not received</option>
                </select>
              </label>
              <div className="flex items-end gap-2">
                <button type="submit" className="rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white">Apply</button>
                <Link href="/shipper/package-receipts" className="rounded-xl border border-slate-300 px-4 py-2 text-sm font-semibold text-slate-700">Clear</Link>
              </div>
            </form>
          </div>

          {rows.length === 0 ? (
            <p className="mt-4 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-700">No packages match the current filters.</p>
          ) : (
            <div className="mt-4 grid gap-4 lg:grid-cols-2">
              {rows.map((row) => (
                <article key={row.tracking_submission_id} className="rounded-3xl border border-slate-200 bg-slate-50 p-4">
                  <div className="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
                    <div>
                      <p className="text-sm font-semibold text-slate-900">{row.courier_name ?? "Courier"} · {row.tracking_ref}</p>
                      <p className="mt-1 text-sm text-slate-600">{row.order_ref ?? row.order_id} · {row.retailer_name ?? "Retailer"}</p>
                      <p className="mt-1 text-sm text-slate-600">{row.importer_name ?? "Importer"} · tracking date {row.tracking_date ?? "—"}</p>
                      <p className="mt-1 text-sm text-slate-600">Original package allocation: {Number(row.allocated_qty ?? 0)} unit{Number(row.allocated_qty ?? 0) === 1 ? "" : "s"}</p>
                    </div>
                    <span className={`w-fit rounded-full px-3 py-1 text-xs font-semibold ${receiptClass(row.latest_receipt_status)}`}>{receiptLabel(row.latest_receipt_status)}</span>
                  </div>

                  <div className="mt-3">
                    <OriginalPackageContentsPreview trackingSubmissionId={row.tracking_submission_id} />
                  </div>

                  <div className="mt-3 flex flex-wrap gap-3 text-sm">
                    <Link href={`/shipper/package-receipts/v2/${row.tracking_submission_id}`} className="rounded-xl bg-sky-700 px-3 py-2 font-semibold text-white hover:bg-sky-800">Open exact receipt</Link>
                    {row.tracking_evidence_url ? <a href={row.tracking_evidence_url} target="_blank" rel="noreferrer" className="font-semibold text-sky-700 underline">Open operator tracking evidence</a> : null}
                    {row.latest_receipt_evidence_url ? <a href={row.latest_receipt_evidence_url} target="_blank" rel="noreferrer" className="font-semibold text-sky-700 underline">Open receipt evidence</a> : null}
                  </div>

                  {row.latest_receipt_note ? <p className="mt-3 rounded-2xl bg-white p-3 text-sm text-slate-700">Latest note: {row.latest_receipt_note}</p> : null}

                  <form action={recordPackageReceiptAction} className="mt-4 rounded-2xl border border-slate-200 bg-white p-4">
                    <input type="hidden" name="tracking_submission_id" value={row.tracking_submission_id ?? ""} />
                    <div className="grid gap-3 md:grid-cols-2">
                      <label className="space-y-1 text-sm">
                        <span className="text-xs uppercase tracking-wide text-slate-500">Package receipt status</span>
                        <select name="receipt_status" defaultValue={row.latest_receipt_status ?? "received_clean"} className="w-full rounded-xl border border-slate-300 px-3 py-2">
                          <option value="received_clean">Package received clean</option>
                          <option value="received_damaged">Package received damaged</option>
                          <option value="held_query">Package held / query</option>
                          <option value="not_received">Package not received</option>
                        </select>
                      </label>
                      <label className="space-y-1 text-sm">
                        <span className="text-xs uppercase tracking-wide text-slate-500">Receipt evidence file</span>
                        <input name="receipt_evidence_file" type="file" accept=".pdf,image/*,.png,.jpg,.jpeg,.webp" className="w-full rounded-xl border border-slate-300 px-3 py-2" />
                      </label>
                      <label className="space-y-1 text-sm md:col-span-2">
                        <span className="text-xs uppercase tracking-wide text-slate-500">Optional evidence URL fallback</span>
                        <input name="evidence_url" className="w-full rounded-xl border border-slate-300 px-3 py-2" placeholder="Use only if no file is uploaded" />
                      </label>
                      <label className="space-y-1 text-sm md:col-span-2">
                        <span className="text-xs uppercase tracking-wide text-slate-500">Note</span>
                        <textarea name="condition_note" rows={2} className="w-full rounded-xl border border-slate-300 px-3 py-2" placeholder="Condition, damage, hold reason, or not-received note" />
                      </label>
                    </div>
                    <button type="submit" className="mt-3 rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800">Save receipt</button>
                  </form>
                </article>
              ))}
            </div>
          )}
        </section>
      </div>
    </main>
  );
}
