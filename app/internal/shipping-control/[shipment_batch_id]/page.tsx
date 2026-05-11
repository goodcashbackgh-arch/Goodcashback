import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type BatchDetailRow = {
  shipment_batch_id: string;
  booking_ref: string | null;
  batch_status: string | null;
  shipper_id: string;
  shipper_name: string | null;
  importer_id: string;
  importer_name: string | null;
  shipment_cutoff_at: string | null;
  dispatched_at: string | null;
  box_count: number | null;
  batch_notes: string | null;
  package_link_id: string | null;
  tracking_submission_id: string | null;
  order_id: string | null;
  order_ref: string | null;
  retailer_name: string | null;
  courier_name: string | null;
  tracking_ref: string | null;
  tracking_date: string | null;
  tracking_evidence_url: string | null;
  allocated_qty: number | string | null;
  allocation_status_summary: string | null;
  latest_receipt_status: string | null;
  latest_receipt_note: string | null;
  latest_receipt_evidence_url: string | null;
  latest_receipt_recorded_at: string | null;
};

function n(value: number | string | null | undefined) {
  const parsed = Number(value ?? 0);
  return Number.isFinite(parsed) ? parsed : 0;
}

function qty(value: number | string | null | undefined) {
  const parsed = n(value);
  return parsed % 1 === 0 ? String(Math.trunc(parsed)) : parsed.toFixed(3).replace(/0+$/, "").replace(/\.$/, "");
}

function shortDate(value: string | null | undefined) {
  if (!value) return "—";
  return value.includes("T") ? value.slice(0, 10) : value;
}

function friendly(value: string | null | undefined) {
  if (!value) return "—";
  return value.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase());
}

function statusClass(status: string | null | undefined) {
  if (!status) return "bg-slate-100 text-slate-700";
  if (["received_clean", "allocated", "contents_allocated"].includes(status)) return "bg-emerald-100 text-emerald-800";
  if (["not_allocated", "mixed_or_missing_receipt"].includes(status)) return "bg-amber-100 text-amber-800";
  if (["received_damaged", "held_query", "not_received"].includes(status)) return "bg-rose-100 text-rose-800";
  return "bg-slate-100 text-slate-700";
}

function normalizeLink(value: string | null | undefined) {
  const raw = (value ?? "").trim();
  if (!raw) return null;
  if (/^[a-z][a-z0-9+.-]*:/i.test(raw)) return raw;
  if (raw.startsWith("//")) return `https:${raw}`;
  return `https://${raw}`;
}

export default async function InternalShippingBatchDetailPage({
  params,
}: {
  params: Promise<{ shipment_batch_id: string }>;
}) {
  const { shipment_batch_id: shipmentBatchId } = await params;
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

  const { data, error } = await (supabase as any).rpc("internal_shipping_batch_detail_v1", {
    p_shipment_batch_id: shipmentBatchId,
  });

  const rows = (data ?? []) as BatchDetailRow[];
  const first = rows[0] ?? null;
  const packageRows = rows.filter((row) => row.package_link_id);
  const totalQty = packageRows.reduce((sum, row) => sum + n(row.allocated_qty), 0);

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-7xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-wrap gap-3 text-sm font-semibold text-sky-700">
            <Link href="/internal/shipping-control">← Shipping control</Link>
            <Link href="/internal">Internal dashboard</Link>
          </div>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Goodcashback Internal</p>
          <div className="mt-2 flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
            <div>
              <h1 className="text-2xl font-semibold tracking-tight sm:text-3xl">Shipment batch detail</h1>
              <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">
                Internal read-only view of the importer shipment batch. This is staff-safe and does not rely on shipper-user access. It does not approve, post, apportion, generate COS/BOL/POD or clear VAT.
              </p>
            </div>
            <div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700">
              <div className="font-medium text-slate-950">{staff.full_name}</div>
              <div>{staff.role_type}</div>
            </div>
          </div>
          {error ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">{error.message}</p> : null}
          {!first && !error ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">No shipment batch detail found.</p> : null}
        </section>

        {first ? (
          <>
            <section className="grid gap-4 md:grid-cols-5">
              <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
                <p className="text-xs uppercase tracking-wide text-slate-500">Booking ref</p>
                <p className="mt-1 text-xl font-semibold">{first.booking_ref ?? shipmentBatchId}</p>
              </div>
              <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
                <p className="text-xs uppercase tracking-wide text-slate-500">Importer</p>
                <p className="mt-1 text-xl font-semibold">{first.importer_name ?? "—"}</p>
              </div>
              <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
                <p className="text-xs uppercase tracking-wide text-slate-500">Shipper</p>
                <p className="mt-1 text-xl font-semibold">{first.shipper_name ?? "—"}</p>
              </div>
              <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
                <p className="text-xs uppercase tracking-wide text-slate-500">Packages</p>
                <p className="mt-1 text-xl font-semibold">{packageRows.length}</p>
              </div>
              <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
                <p className="text-xs uppercase tracking-wide text-slate-500">Item qty</p>
                <p className="mt-1 text-xl font-semibold">{qty(totalQty)}</p>
              </div>
            </section>

            <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
              <h2 className="text-xl font-semibold">Batch header</h2>
              <div className="mt-4 grid gap-3 md:grid-cols-4">
                <div className="rounded-2xl bg-slate-50 p-3 text-sm"><span className="text-slate-500">Status</span><p className="font-semibold">{friendly(first.batch_status)}</p></div>
                <div className="rounded-2xl bg-slate-50 p-3 text-sm"><span className="text-slate-500">Cut-off</span><p className="font-semibold">{shortDate(first.shipment_cutoff_at)}</p></div>
                <div className="rounded-2xl bg-slate-50 p-3 text-sm"><span className="text-slate-500">Dispatch</span><p className="font-semibold">{shortDate(first.dispatched_at)}</p></div>
                <div className="rounded-2xl bg-slate-50 p-3 text-sm"><span className="text-slate-500">Box/carton count</span><p className="font-semibold">{first.box_count ?? "—"}</p></div>
              </div>
              {first.batch_notes ? <p className="mt-4 rounded-2xl bg-slate-50 p-3 text-sm text-slate-700"><span className="font-semibold">Notes:</span> {first.batch_notes}</p> : null}
            </section>

            <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
              <h2 className="text-xl font-semibold">Selected packages</h2>
              <p className="mt-2 text-sm text-slate-600">Package-level movement truth only. Use Review delivery allocation to inspect or correct order/item allocation before shipping fee apportionment.</p>
              {packageRows.length === 0 ? (
                <p className="mt-4 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-700">No active packages linked to this batch.</p>
              ) : (
                <div className="mt-4 overflow-x-auto rounded-2xl border border-slate-200">
                  <table className="min-w-full divide-y divide-slate-200 text-sm">
                    <thead className="bg-slate-100 text-xs uppercase tracking-wide text-slate-500">
                      <tr>
                        <th className="px-3 py-2 text-left">Order</th>
                        <th className="px-3 py-2 text-left">Retailer</th>
                        <th className="px-3 py-2 text-left">Tracking/package</th>
                        <th className="px-3 py-2 text-left">Tracking date</th>
                        <th className="px-3 py-2 text-right">Allocated qty</th>
                        <th className="px-3 py-2 text-left">Allocation</th>
                        <th className="px-3 py-2 text-left">Receipt</th>
                        <th className="px-3 py-2 text-left">Evidence</th>
                        <th className="px-3 py-2 text-left">Actions</th>
                      </tr>
                    </thead>
                    <tbody className="divide-y divide-slate-100 bg-white">
                      {packageRows.map((row) => {
                        const trackingEvidence = normalizeLink(row.tracking_evidence_url);
                        const receiptEvidence = normalizeLink(row.latest_receipt_evidence_url);
                        return (
                          <tr key={row.package_link_id ?? `${row.tracking_submission_id}-${row.order_id}`}>
                            <td className="px-3 py-2 font-semibold">{row.order_ref ?? row.order_id ?? "—"}</td>
                            <td className="px-3 py-2">{row.retailer_name ?? "—"}</td>
                            <td className="px-3 py-2">{row.courier_name ?? "Courier"} · {row.tracking_ref ?? "—"}</td>
                            <td className="px-3 py-2">{shortDate(row.tracking_date)}</td>
                            <td className="px-3 py-2 text-right font-semibold">{qty(row.allocated_qty)}</td>
                            <td className="px-3 py-2"><span className={`rounded-full px-2 py-1 text-xs font-semibold ${statusClass(row.allocation_status_summary)}`}>{friendly(row.allocation_status_summary)}</span></td>
                            <td className="px-3 py-2">
                              <span className={`rounded-full px-2 py-1 text-xs font-semibold ${statusClass(row.latest_receipt_status)}`}>{friendly(row.latest_receipt_status)}</span>
                              {row.latest_receipt_note ? <p className="mt-1 text-xs text-slate-500">{row.latest_receipt_note}</p> : null}
                            </td>
                            <td className="px-3 py-2">
                              <div className="flex flex-col gap-1">
                                {trackingEvidence ? <a href={trackingEvidence} target="_blank" rel="noreferrer" className="font-semibold text-sky-700 underline">Tracking</a> : null}
                                {receiptEvidence ? <a href={receiptEvidence} target="_blank" rel="noreferrer" className="font-semibold text-sky-700 underline">Receipt</a> : null}
                                {!trackingEvidence && !receiptEvidence ? "—" : null}
                              </div>
                            </td>
                            <td className="px-3 py-2">
                              <div className="flex flex-col gap-2">
                                {row.order_id ? (
                                  <Link href={`/internal/delivery-allocation/${row.order_id}`} className="rounded-xl bg-slate-900 px-3 py-2 text-xs font-semibold text-white hover:bg-slate-800">
                                    Review delivery allocation
                                  </Link>
                                ) : null}
                                {row.tracking_submission_id ? (
                                  <Link href={`/internal/shipping-control/package-contents/${row.tracking_submission_id}`} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-xs font-semibold text-slate-800 hover:bg-slate-50">
                                    View contents
                                  </Link>
                                ) : null}
                              </div>
                            </td>
                          </tr>
                        );
                      })}
                    </tbody>
                  </table>
                </div>
              )}
            </section>

            <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm leading-6 text-amber-900">
              <h2 className="font-semibold">Next lanes</h2>
              <p className="mt-2">Shipper invoice/receipt review, shipping apportionment, draft COS review, master shipment grouping and final export evidence upload remain separate supervisor lanes. This page is only the internal read-only package movement view.</p>
            </section>
          </>
        ) : null}
      </div>
    </main>
  );
}
