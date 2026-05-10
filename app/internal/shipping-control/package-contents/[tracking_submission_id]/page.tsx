import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type PackageContentsRow = {
  tracking_submission_id: string;
  order_id: string;
  order_ref: string | null;
  importer_name: string | null;
  shipper_name: string | null;
  retailer_name: string | null;
  courier_name: string | null;
  tracking_ref: string | null;
  tracking_date: string | null;
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

function shortDate(value: string | null | undefined) {
  if (!value) return "—";
  return value.includes("T") ? value.slice(0, 10) : value;
}

function statusLabel(value: string | null | undefined) {
  return (value ?? "allocated").replaceAll("_", " ");
}

export default async function InternalPackageContentsPage({
  params,
}: {
  params: Promise<{ tracking_submission_id: string }>;
}) {
  const { tracking_submission_id: trackingSubmissionId } = await params;
  const supabase = await createClient();

  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff } = await supabase
    .from("staff")
    .select("id, full_name, role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!staff) redirect("/auth/check");

  const { data, error } = await (supabase as any).rpc("internal_package_contents_preview_v1", {
    p_tracking_submission_id: trackingSubmissionId,
  });

  const rows = (data ?? []) as PackageContentsRow[];
  const first = rows[0] ?? null;
  const totalQty = rows.reduce((sum, row) => sum + qtyNumber(row.qty_allocated), 0);

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-6xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-wrap gap-3 text-sm font-semibold text-sky-700">
            <Link href="/internal/shipping-control">← Shipping control</Link>
            <Link href="/internal">Internal dashboard</Link>
          </div>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Goodcashback Internal</p>
          <h1 className="mt-2 text-2xl font-semibold tracking-tight sm:text-3xl">Package contents</h1>
          <p className="mt-2 text-sm text-slate-600">{staff.full_name} · {staff.role_type}</p>
          <p className="mt-3 max-w-4xl text-sm leading-6 text-slate-600">
            Staff read-only contents view. Description and quantity only. Values, VAT, margin, Sage, DVA/card, adjusted net and payment data are hidden here.
          </p>
          {error ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">{error.message}</p> : null}
        </section>

        <section className="grid gap-4 md:grid-cols-5">
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm md:col-span-2">
            <p className="text-xs uppercase tracking-wide text-slate-500">Tracking/package</p>
            <p className="mt-1 text-xl font-semibold">{first ? `${first.courier_name ?? "Courier"} · ${first.tracking_ref ?? trackingSubmissionId}` : trackingSubmissionId}</p>
            <p className="mt-1 text-xs text-slate-500">Tracking date: {shortDate(first?.tracking_date)}</p>
          </div>
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
            <p className="text-xs uppercase tracking-wide text-slate-500">Order</p>
            <p className="mt-1 text-xl font-semibold">{first?.order_ref ?? "—"}</p>
          </div>
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
            <p className="text-xs uppercase tracking-wide text-slate-500">Retailer</p>
            <p className="mt-1 text-xl font-semibold">{first?.retailer_name ?? "—"}</p>
          </div>
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
            <p className="text-xs uppercase tracking-wide text-slate-500">Contents</p>
            <p className="mt-1 text-xl font-semibold">{rows.length} item{rows.length === 1 ? "" : "s"} · {formatTotalQty(totalQty)} unit{totalQty === 1 ? "" : "s"}</p>
          </div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <h2 className="text-xl font-semibold">Item list</h2>
          {rows.length === 0 && !error ? (
            <p className="mt-4 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-900">
              Contents not allocated yet. Package can still be received, but export evidence/COS review will require operator/supervisor allocation.
            </p>
          ) : (
            <div className="mt-4 overflow-x-auto rounded-2xl border border-slate-200">
              <table className="min-w-full divide-y divide-slate-200 text-sm">
                <thead className="bg-slate-100 text-xs uppercase tracking-wide text-slate-500">
                  <tr>
                    <th className="px-3 py-2 text-left">#</th>
                    <th className="px-3 py-2 text-left">Description</th>
                    <th className="px-3 py-2 text-right">Qty</th>
                    <th className="px-3 py-2 text-left">Allocation status</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-100 bg-white">
                  {rows.map((row, index) => (
                    <tr key={`${row.tracking_submission_id}-${row.supplier_invoice_line_id}-${index}`}>
                      <td className="px-3 py-2 text-slate-500">{index + 1}</td>
                      <td className="px-3 py-2 font-medium text-slate-900">{row.item_description ?? "Unlabelled item"}</td>
                      <td className="px-3 py-2 text-right font-semibold text-slate-900">{formatQty(row.qty_allocated)}</td>
                      <td className="px-3 py-2"><span className="rounded-full bg-emerald-100 px-2 py-1 text-xs font-semibold text-emerald-800">{statusLabel(row.allocation_status)}</span></td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
          <p className="mt-4 rounded-2xl bg-slate-50 p-3 text-xs text-slate-600">
            This page is only for internal package content visibility. It does not permit item allocation, value review, COS generation, Sage posting or VAT clearance.
          </p>
        </section>
      </div>
    </main>
  );
}
