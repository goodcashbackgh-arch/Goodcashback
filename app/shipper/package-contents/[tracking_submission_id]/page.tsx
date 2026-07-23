import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type PackageContentsRow = {
  tracking_submission_id: string;
  order_id: string;
  order_ref: string | null;
  retailer_name: string | null;
  courier_name: string | null;
  tracking_ref: string | null;
  supplier_invoice_line_id: string;
  item_description: string | null;
  qty_allocated: number | string | null;
  allocation_status: string | null;
};

function qtyNumber(value: number | string | null | undefined) {
  const n = Number(value ?? 0);
  return Number.isFinite(n) ? n : 0;
}

function formatQty(value: number | string | null | undefined) {
  const n = qtyNumber(value);
  return n % 1 === 0 ? String(Math.trunc(n)) : n.toFixed(3).replace(/0+$/, "").replace(/\.$/, "");
}

function formatTotalQty(value: number) {
  return value % 1 === 0 ? String(Math.trunc(value)) : value.toFixed(3).replace(/0+$/, "").replace(/\.$/, "");
}

function statusLabel(value: string | null | undefined) {
  return (value ?? "allocated").replaceAll("_", " ");
}

export default async function ShipperPackageContentsPage({
  params,
}: {
  params: Promise<{ tracking_submission_id: string }>;
}) {
  const { tracking_submission_id: trackingSubmissionId } = await params;
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

  const [originalResult, eligibleResult] = await Promise.all([
    (supabase as any).rpc("shipper_package_original_contents_preview_v1", {
      p_tracking_submission_id: trackingSubmissionId,
    }),
    (supabase as any).rpc("shipper_package_contents_preview_v1", {
      p_tracking_submission_id: trackingSubmissionId,
    }),
  ]);

  const originalRows = (originalResult.data ?? []) as PackageContentsRow[];
  const eligibleRows = (eligibleResult.data ?? []) as PackageContentsRow[];
  const first = originalRows[0] ?? eligibleRows[0] ?? null;
  const originalQty = originalRows.reduce((sum, row) => sum + qtyNumber(row.qty_allocated), 0);
  const eligibleQty = eligibleRows.reduce((sum, row) => sum + qtyNumber(row.qty_allocated), 0);
  const divertedQty = Math.max(originalQty - eligibleQty, 0);
  const eligibleByLine = new Map(eligibleRows.map((row) => [row.supplier_invoice_line_id, qtyNumber(row.qty_allocated)]));
  const divertedRows = originalRows
    .map((row) => ({ ...row, qty_allocated: Math.max(qtyNumber(row.qty_allocated) - (eligibleByLine.get(row.supplier_invoice_line_id) ?? 0), 0) }))
    .filter((row) => qtyNumber(row.qty_allocated) > 0);
  const shipper = Array.isArray((shipperUser as any).shippers) ? (shipperUser as any).shippers[0] : (shipperUser as any).shippers;
  const error = originalResult.error ?? eligibleResult.error;

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-6xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-wrap gap-3 text-sm font-semibold text-sky-700">
            <Link href="/shipper">← Dashboard</Link>
            <Link href="/shipper/package-receipts">Package receipts</Link>
            <Link href="/shipper/shipments">Shipment batches</Link>
          </div>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Goodcashback Shipper</p>
          <h1 className="mt-2 text-2xl font-semibold tracking-tight sm:text-3xl">Package contents and current routing</h1>
          <p className="mt-2 text-sm text-slate-600">{(shipperUser as any).full_name} · {shipper?.name ?? "Shipper"}</p>
          <p className="mt-3 max-w-4xl text-sm leading-6 text-slate-600">
            Original package allocation remains visible as receipt history. Current routing separately shows what remains shipment eligible and what has moved to a hold, return or refund path. Commercial values and payment data are hidden.
          </p>
          {error ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">{error.message}</p> : null}
        </section>

        <section className="grid gap-4 md:grid-cols-3 lg:grid-cols-6">
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm lg:col-span-2">
            <p className="text-xs uppercase tracking-wide text-slate-500">Tracking/package</p>
            <p className="mt-1 text-xl font-semibold">{first ? `${first.courier_name ?? "Courier"} · ${first.tracking_ref ?? trackingSubmissionId}` : trackingSubmissionId}</p>
          </div>
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
            <p className="text-xs uppercase tracking-wide text-slate-500">Order</p>
            <p className="mt-1 text-xl font-semibold">{first?.order_ref ?? "—"}</p>
          </div>
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
            <p className="text-xs uppercase tracking-wide text-slate-500">Original units</p>
            <p className="mt-1 text-xl font-semibold">{formatTotalQty(originalQty)}</p>
          </div>
          <div className="rounded-3xl border border-emerald-200 bg-emerald-50 p-4 shadow-sm">
            <p className="text-xs uppercase tracking-wide text-emerald-700">Shipment eligible</p>
            <p className="mt-1 text-xl font-semibold text-emerald-950">{formatTotalQty(eligibleQty)}</p>
          </div>
          <div className="rounded-3xl border border-amber-200 bg-amber-50 p-4 shadow-sm">
            <p className="text-xs uppercase tracking-wide text-amber-700">Diverted</p>
            <p className="mt-1 text-xl font-semibold text-amber-950">{formatTotalQty(divertedQty)}</p>
          </div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <h2 className="text-xl font-semibold">Original package contents</h2>
          <p className="mt-1 text-sm text-slate-600">Immutable allocation history used alongside package receipt evidence.</p>
          {originalRows.length === 0 && !originalResult.error ? (
            <p className="mt-4 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-900">Original contents are not allocated yet.</p>
          ) : (
            <div className="mt-4 overflow-x-auto rounded-2xl border border-slate-200">
              <table className="min-w-full divide-y divide-slate-200 text-sm">
                <thead className="bg-slate-100 text-xs uppercase tracking-wide text-slate-500"><tr><th className="px-3 py-2 text-left">#</th><th className="px-3 py-2 text-left">Description</th><th className="px-3 py-2 text-right">Qty</th><th className="px-3 py-2 text-left">Allocation status</th></tr></thead>
                <tbody className="divide-y divide-slate-100 bg-white">
                  {originalRows.map((row, index) => <tr key={`original-${row.supplier_invoice_line_id}-${index}`}><td className="px-3 py-2 text-slate-500">{index + 1}</td><td className="px-3 py-2 font-medium">{row.item_description ?? "Unlabelled item"}</td><td className="px-3 py-2 text-right font-semibold">{formatQty(row.qty_allocated)}</td><td className="px-3 py-2"><span className="rounded-full bg-slate-100 px-2 py-1 text-xs font-semibold text-slate-700">{statusLabel(row.allocation_status)}</span></td></tr>)}
                </tbody>
              </table>
            </div>
          )}
        </section>

        <section className="grid gap-6 lg:grid-cols-2">
          <div className="rounded-3xl border border-emerald-200 bg-emerald-50 p-5 shadow-sm sm:p-6">
            <h2 className="text-xl font-semibold text-emerald-950">Shipment-eligible contents</h2>
            <p className="mt-1 text-sm text-emerald-900">These lines continue through shipment membership, freight and AP/recharge.</p>
            {eligibleRows.length === 0 ? <p className="mt-4 rounded-2xl bg-white p-4 text-sm text-emerald-900">No units are currently shipment eligible.</p> : <div className="mt-4 space-y-2">{eligibleRows.map((row) => <div key={`eligible-${row.supplier_invoice_line_id}`} className="rounded-2xl bg-white p-3 text-sm"><p className="font-semibold">{row.item_description ?? "Unlabelled item"}</p><p className="text-slate-600">Qty {formatQty(row.qty_allocated)}</p></div>)}</div>}
          </div>

          <div className="rounded-3xl border border-amber-200 bg-amber-50 p-5 shadow-sm sm:p-6">
            <h2 className="text-xl font-semibold text-amber-950">Diverted from shipment</h2>
            <p className="mt-1 text-sm text-amber-900">These units remain visible here and continue through their existing hold, return, exception or refund workflow.</p>
            {divertedRows.length === 0 ? <p className="mt-4 rounded-2xl bg-white p-4 text-sm text-amber-900">No units are currently diverted.</p> : <div className="mt-4 space-y-2">{divertedRows.map((row) => <div key={`diverted-${row.supplier_invoice_line_id}`} className="rounded-2xl bg-white p-3 text-sm"><p className="font-semibold">{row.item_description ?? "Unlabelled item"}</p><p className="text-slate-600">Qty {formatQty(row.qty_allocated)}</p></div>)}</div>}
          </div>
        </section>

        <p className="rounded-2xl bg-white p-4 text-xs text-slate-600 shadow-sm">This page is read-only. It does not alter allocation, receipt, holds, shipment membership, freight, AP/recharge, Sage, credit notes or refunds.</p>
      </div>
    </main>
  );
}
