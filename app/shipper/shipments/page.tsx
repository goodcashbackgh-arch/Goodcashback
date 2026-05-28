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

type ProgressRow = {
  shipment_batch_id: string;
  shipper_invoice_status: string | null;
  export_evidence_status: string | null;
  sage_readiness_status: string | null;
  next_action: string | null;
};

function formatDate(value: string | null | undefined) {
  if (!value) return "—";
  return value.includes("T") ? value.slice(0, 10) : value;
}

function importerName(batch: BatchRow, importerNameById: Map<string, string>) {
  return importerNameById.get(batch.importer_id) || batch.importers?.trading_name || batch.importers?.company_name || batch.importer_id;
}

function friendly(value: string | null | undefined) {
  if (!value) return "—";
  return value.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase());
}

function statusLabel(status: string | null | undefined) {
  if (status === "upload_shipping_charge_document") return "Upload shipping charge document";
  if (status === "awaiting_supervisor_shipping_document_review") return "Awaiting supervisor document review";
  if (status === "awaiting_supervisor_shipping_apportionment") return "Awaiting supervisor apportionment";
  if (status === "awaiting_supervisor_final_export_evidence_review") return "Awaiting supervisor final evidence review";
  if (status === "awaiting_supervisor_pod_review") return "Awaiting supervisor POD review";
  if (status === "upload_final_export_evidence") return "Upload final export evidence";
  if (status === "upload_pod_or_delivery_evidence") return "Upload POD / delivery evidence";
  if (status === "shipment_controls_complete") return "Shipment controls complete";
  if (status === "shipping_apportionment_approved") return "Shipping apportionment approved";
  if (status === "pod_delivery_evidence_accepted") return "POD / delivery evidence accepted";
  if (status === "pod_delivery_evidence_submitted_for_review") return "POD / delivery evidence submitted";
  return friendly(status);
}

function statusClass(status: string | null | undefined) {
  if (!status || status === "not_started" || status === "not_ready") return "bg-amber-100 text-amber-800";
  if (["accepted_current", "shipping_apportionment_approved", "pod_delivery_evidence_accepted", "shipment_controls_complete"].includes(status)) return "bg-emerald-100 text-emerald-800";
  if (["submitted_for_review", "uploaded_pending_ocr", "queued", "processing", "upload_final_export_evidence", "upload_pod_or_delivery_evidence", "awaiting_supervisor_shipping_document_review", "awaiting_supervisor_shipping_apportionment", "awaiting_supervisor_final_export_evidence_review", "awaiting_supervisor_pod_review", "pod_delivery_evidence_submitted_for_review"].includes(status)) return "bg-amber-100 text-amber-800";
  if (["rejected_resubmit_required"].includes(status)) return "bg-rose-100 text-rose-800";
  if (["voided", "voided_no_action"].includes(status)) return "bg-slate-200 text-slate-700";
  return "bg-slate-100 text-slate-700";
}

function taskAction(batch: BatchRow, progress: ProgressRow | null) {
  const action = progress?.next_action;
  if (action === "upload_shipping_charge_document") return { href: `/shipper/shipping-documents/new?batch=${batch.id}`, label: "Upload charge doc", tone: "sky" };
  if (action === "upload_final_export_evidence" || action === "upload_pod_or_delivery_evidence") return { href: `/shipper/shipments/${batch.id}/final-evidence`, label: action === "upload_pod_or_delivery_evidence" ? "Upload POD" : "Upload final evidence", tone: "amber" };
  return null;
}

function buttonClass(tone: string) {
  if (tone === "sky") return "rounded-xl border border-sky-300 bg-sky-50 px-3 py-2 text-xs font-semibold text-sky-900 hover:bg-sky-100";
  if (tone === "amber") return "rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-xs font-semibold text-amber-900 hover:bg-amber-100";
  return "rounded-xl border border-slate-300 bg-white px-3 py-2 text-xs font-semibold text-slate-800 hover:bg-slate-100";
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

  const [{ data: batches, error }, { data: packageDashboardRows }, { data: progressData, error: progressError }] = await Promise.all([
    supabase
      .from("shipper_shipment_batches")
      .select("id, booking_ref, importer_id, shipper_id, shipment_cutoff_at, dispatched_at, box_count, status, created_at, importers(company_name, trading_name), shipper_shipment_batch_packages(id, tracking_submission_id, order_id, active)")
      .eq("shipper_id", (shipperUser as any).shipper_id)
      .order("created_at", { ascending: false }),
    (supabase as any).rpc("shipper_package_receipt_dashboard_v1"),
    (supabase as any).rpc("shipper_shipment_batch_progress_v1"),
  ]);

  const nameRows = (packageDashboardRows ?? []) as PackageDashboardRow[];
  const importerNameById = new Map<string, string>();
  for (const row of nameRows) {
    if (row.importer_id && row.importer_name) importerNameById.set(row.importer_id, row.importer_name);
  }

  const progressByBatch = new Map<string, ProgressRow>();
  for (const row of (progressData ?? []) as ProgressRow[]) progressByBatch.set(row.shipment_batch_id, row);

  const rows = ((batches ?? []) as unknown as BatchRow[]).filter((batch) => batch.status !== "voided");
  const shipper = Array.isArray((shipperUser as any).shippers) ? (shipperUser as any).shippers[0] : (shipperUser as any).shippers;
  const podPending = rows.filter((batch) => progressByBatch.get(batch.id)?.next_action === "upload_pod_or_delivery_evidence").length;
  const complete = rows.filter((batch) => progressByBatch.get(batch.id)?.next_action === "shipment_controls_complete").length;

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-7xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <Link href="/shipper" className="text-sm font-semibold text-sky-700">← Back to shipper dashboard</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Goodcashback Shipper</p>
          <h1 className="mt-2 text-2xl font-semibold tracking-tight sm:text-3xl">Shipment batches</h1>
          <p className="mt-2 text-sm text-slate-600">{(shipperUser as any).full_name} · {shipper?.name ?? "Shipper"}</p>
          <p className="mt-3 max-w-4xl text-sm leading-6 text-slate-600">
            View shipment batches created from received-clean packages. Status now tracks charge-document review, supervisor apportionment, final export evidence and POD/delivery evidence. Financial values and Sage coding stay supervisor-only.
          </p>
          <div className="mt-5 flex flex-wrap gap-3">
            <Link href="/shipper/shipments/new" className="rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800">Create shipment batch</Link>
            <Link href="/shipper/shipping-documents/new" className="rounded-xl border border-sky-300 bg-sky-50 px-4 py-2 text-sm font-semibold text-sky-900 hover:bg-sky-100">Upload shipping charge doc</Link>
          </div>
          {error ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">{error.message}</p> : null}
          {progressError ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">Progress statuses unavailable. Apply the latest shipping-control migration before testing this view.</p> : null}
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
          <div className={`rounded-3xl border p-4 shadow-sm ${podPending > 0 ? "border-amber-200 bg-amber-50" : "border-slate-200 bg-white"}`}>
            <p className="text-xs uppercase tracking-wide text-slate-500">POD pending</p>
            <p className="mt-1 text-2xl font-semibold">{podPending}</p>
          </div>
          <div className="rounded-3xl border border-emerald-200 bg-emerald-50 p-4 shadow-sm">
            <p className="text-xs uppercase tracking-wide text-slate-500">Complete</p>
            <p className="mt-1 text-2xl font-semibold">{complete}</p>
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
                    <th className="px-3 py-2 text-left">Progress</th>
                    <th className="px-3 py-2 text-left">Actions</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-100 bg-white">
                  {rows.map((batch) => {
                    const progress = progressByBatch.get(batch.id) ?? null;
                    const task = taskAction(batch, progress);
                    return (
                      <tr key={batch.id}>
                        <td className="px-3 py-2 font-semibold">{batch.booking_ref ?? batch.id}</td>
                        <td className="px-3 py-2">{importerName(batch, importerNameById)}</td>
                        <td className="px-3 py-2">{formatDate(batch.created_at)}</td>
                        <td className="px-3 py-2">{formatDate(batch.dispatched_at)}</td>
                        <td className="px-3 py-2 text-right">{batch.shipper_shipment_batch_packages?.filter((p) => p.active).length ?? 0}</td>
                        <td className="px-3 py-2">{batch.box_count ?? "—"}</td>
                        <td className="px-3 py-2">
                          <div className="space-y-1">
                            <span className={`inline-block rounded-full px-2 py-1 text-xs font-semibold ${statusClass(progress?.next_action ?? batch.status)}`}>{statusLabel(progress?.next_action ?? batch.status)}</span>
                            <span className={`block w-fit rounded-full px-2 py-1 text-xs font-semibold ${statusClass(progress?.shipper_invoice_status)}`}>Charge doc: {statusLabel(progress?.shipper_invoice_status)}</span>
                            <span className={`block w-fit rounded-full px-2 py-1 text-xs font-semibold ${statusClass(progress?.export_evidence_status)}`}>Export/POD: {statusLabel(progress?.export_evidence_status)}</span>
                          </div>
                        </td>
                        <td className="px-3 py-2">
                          <div className="flex flex-col gap-2">
                            {task ? <Link href={task.href} className={buttonClass(task.tone)}>{task.label}</Link> : null}
                            <Link href={`/shipper/shipments/${batch.id}`} className={buttonClass("slate")}>View detail</Link>
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
      </div>
    </main>
  );
}
