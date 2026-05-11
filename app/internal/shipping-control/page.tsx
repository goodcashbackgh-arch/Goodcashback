import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type ShippingControlRow = {
  shipment_batch_id: string;
  booking_ref: string | null;
  shipper_id: string;
  shipper_name: string | null;
  importer_id: string;
  importer_name: string | null;
  batch_status: string | null;
  shipment_cutoff_at: string | null;
  dispatched_at: string | null;
  box_count: number | null;
  created_at: string | null;
  package_count: number | string | null;
  order_count: number | string | null;
  allocated_package_count: number | string | null;
  unallocated_package_count: number | string | null;
  item_qty: number | string | null;
  receipt_issue_count: number | string | null;
  package_refs_preview: string | null;
  order_refs_preview: string | null;
  receipt_status_summary: string | null;
  allocation_status_summary: string | null;
  shipper_invoice_status: string | null;
  export_evidence_status: string | null;
  master_shipment_status: string | null;
  sage_readiness_status: string | null;
  next_action: string | null;
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
  if ([
    "received_clean",
    "contents_allocated",
    "accepted_current",
    "shipping_apportionment_approved",
    "ready_for_sage_ap_readiness_review",
    "ready_for_shipping_document_or_draft_export_review",
    "shipping_document_ready_for_next_review",
  ].includes(status)) return "bg-emerald-100 text-emerald-800";
  if ([
    "allocation_missing",
    "mixed_or_missing_receipt",
    "not_started",
    "not_grouped",
    "not_ready",
    "uploaded_pending_ocr",
    "queued",
    "processing",
    "shipping_apportionment_pending",
    "shipper_invoice_or_export_review_needed",
    "shipping_document_uploaded_needs_supervisor_processing",
  ].includes(status)) return "bg-amber-100 text-amber-800";
  if (["receipt_issue", "check_empty_batch", "rejected_resubmit_required"].includes(status)) return "bg-rose-100 text-rose-800";
  if (["voided_no_action", "voided"].includes(status)) return "bg-slate-200 text-slate-700";
  return "bg-slate-100 text-slate-700";
}

function truncate(value: string | null | undefined, max = 70) {
  if (!value) return "—";
  return value.length > max ? `${value.slice(0, max - 1)}…` : value;
}

function matchesFilter(row: ShippingControlRow, filter: string) {
  if (!filter || filter === "all") return true;
  if (filter === "allocation_missing") return row.allocation_status_summary === "allocation_missing";
  if (filter === "receipt_issue") return row.receipt_status_summary === "receipt_issue";
  if (filter === "missing_shipper_invoice") return row.shipper_invoice_status === "not_started";
  if (filter === "apportionment_pending") return row.next_action === "shipping_apportionment_pending";
  if (filter === "sage_ap_ready") return row.next_action === "ready_for_sage_ap_readiness_review";
  if (filter === "voided") return row.batch_status === "voided";
  return true;
}

export default async function InternalShippingControlPage({ searchParams }: { searchParams?: Promise<{ status?: string; q?: string }> }) {
  const qp = searchParams ? await searchParams : {};
  const selectedStatus = qp.status ?? "all";
  const search = (qp.q ?? "").trim().toLowerCase();

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

  const { data, error } = await (supabase as any).rpc("internal_shipping_control_v1");
  const allRows = ((data ?? []) as ShippingControlRow[]);
  const rows = allRows.filter((row) => {
    const matchesStatus = matchesFilter(row, selectedStatus);
    if (!matchesStatus) return false;
    if (!search) return true;
    const haystack = [row.booking_ref, row.shipper_name, row.importer_name, row.package_refs_preview, row.order_refs_preview, row.shipment_batch_id].join(" ").toLowerCase();
    return haystack.includes(search);
  });

  const packageTotal = allRows.reduce((sum, row) => sum + n(row.package_count), 0);
  const allocationMissing = allRows.filter((row) => row.allocation_status_summary === "allocation_missing").length;
  const receiptIssues = allRows.filter((row) => row.receipt_status_summary === "receipt_issue").length;
  const readyForNext = allRows.filter((row) => row.next_action === "ready_for_sage_ap_readiness_review").length;
  const missingShipperInvoice = allRows.filter((row) => row.shipper_invoice_status === "not_started").length;
  const invoiceReleaseCandidates = allRows.filter((row) =>
    row.allocation_status_summary === "contents_allocated" &&
    row.receipt_status_summary === "received_clean" &&
    row.shipper_invoice_status === "accepted_current" &&
    row.sage_readiness_status === "shipping_apportionment_approved"
  ).length;

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-7xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <Link href="/internal" className="text-sm font-semibold text-sky-700">← Back to internal dashboard</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Goodcashback Internal</p>
          <div className="mt-2 flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
            <div>
              <h1 className="text-2xl font-semibold tracking-tight sm:text-3xl">Shipping control centre</h1>
              <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">Read-only supervisor overview of shipment batches, package receipt truth, content allocation, shipper documents, apportionment, customer invoice release readiness, draft COS, master shipment and Sage/AP readiness. Action work belongs in focused child queues.</p>
            </div>
            <div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700"><div className="font-medium text-slate-950">{staff.full_name}</div><div>{staff.role_type}</div></div>
          </div>
          {error ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">Shipping control read model unavailable: {error.message}. Run the latest Supabase migration before testing this page.</p> : null}
        </section>

        <section className="grid gap-4 md:grid-cols-5">
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Shipment batches</p><p className="mt-1 text-2xl font-semibold">{allRows.length}</p></div>
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Packages</p><p className="mt-1 text-2xl font-semibold">{packageTotal}</p></div>
          <div className={`rounded-3xl border p-4 shadow-sm ${allocationMissing > 0 ? "border-amber-200 bg-amber-50" : "border-slate-200 bg-white"}`}><p className="text-xs uppercase tracking-wide text-slate-500">Allocation missing</p><p className="mt-1 text-2xl font-semibold">{allocationMissing}</p></div>
          <div className={`rounded-3xl border p-4 shadow-sm ${receiptIssues > 0 ? "border-rose-200 bg-rose-50" : "border-slate-200 bg-white"}`}><p className="text-xs uppercase tracking-wide text-slate-500">Receipt issues</p><p className="mt-1 text-2xl font-semibold">{receiptIssues}</p></div>
          <div className="rounded-3xl border border-sky-200 bg-sky-50 p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Missing shipper invoice</p><p className="mt-1 text-2xl font-semibold">{missingShipperInvoice}</p></div>
        </section>

        <section className="grid gap-4 lg:grid-cols-3">
          <Link href="/internal/shipping-control/customer-invoice-release" className="rounded-3xl border border-emerald-200 bg-emerald-50 p-5 shadow-sm hover:bg-emerald-100">
            <p className="text-xs font-semibold uppercase tracking-wide text-emerald-700">Focused action queue</p>
            <h2 className="mt-2 text-xl font-semibold text-emerald-950">Customer invoice release queue</h2>
            <p className="mt-2 text-sm leading-6 text-emerald-900">Review all stable customer invoice intents in one place before bulk draft creation is enabled.</p>
            <p className="mt-3 text-2xl font-semibold text-emerald-950">{invoiceReleaseCandidates}</p>
            <p className="text-xs font-semibold uppercase tracking-wide text-emerald-700">candidate shipment batches</p>
          </Link>
          <Link href="/internal/shipping-control/shipper-documents" className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm hover:bg-slate-50">
            <p className="text-xs font-semibold uppercase tracking-wide text-slate-500">Focused action queue</p>
            <h2 className="mt-2 text-xl font-semibold">Shipper document review</h2>
            <p className="mt-2 text-sm leading-6 text-slate-600">Accept, reject or request resubmission for shipper invoice/receipt documents.</p>
          </Link>
          <div className="rounded-3xl border border-dashed border-slate-300 bg-slate-50 p-5 text-slate-500">
            <p className="text-xs font-semibold uppercase tracking-wide">Later action queue</p>
            <h2 className="mt-2 text-xl font-semibold">Draft COS / export pack</h2>
            <p className="mt-2 text-sm leading-6">Kept separate from customer invoice release and Sage/AP readiness.</p>
          </div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
            <div><h2 className="text-xl font-semibold">Shipment batch worklist</h2><p className="mt-2 text-sm leading-6 text-slate-600">Summary-first control view. Use child queues for repeated actions; use row links for drill-down review.</p></div>
            <form action="/internal/shipping-control" className="grid gap-3 rounded-2xl border border-slate-200 bg-slate-50 p-3 sm:grid-cols-[1fr_1fr_auto]">
              <label className="text-xs font-semibold uppercase tracking-wide text-slate-500">Status<select name="status" defaultValue={selectedStatus} className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal text-slate-950"><option value="all">All</option><option value="allocation_missing">Allocation missing</option><option value="receipt_issue">Receipt issue</option><option value="missing_shipper_invoice">Missing shipper invoice</option><option value="apportionment_pending">Apportionment pending</option><option value="sage_ap_ready">Ready for Sage/AP review</option><option value="voided">Voided</option></select></label>
              <label className="text-xs font-semibold uppercase tracking-wide text-slate-500">Search<input name="q" defaultValue={qp.q ?? ""} placeholder="Booking, importer, shipper, tracking" className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal text-slate-950" /></label>
              <div className="flex items-end gap-2"><button type="submit" className="rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800">Apply</button><Link href="/internal/shipping-control" className="rounded-xl border border-slate-300 bg-white px-4 py-2 text-sm font-semibold text-slate-800 hover:bg-slate-100">Reset</Link></div>
            </form>
          </div>
          <p className="mt-4 text-xs font-semibold uppercase tracking-wide text-slate-500">Showing {rows.length} row(s) · Ready for Sage/AP review: {readyForNext}</p>
          {rows.length === 0 ? <p className="mt-4 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-700">No shipment batches match the selected filters.</p> : (
            <div className="mt-5 overflow-x-auto rounded-2xl border border-slate-200"><table className="min-w-full divide-y divide-slate-200 text-sm"><thead className="bg-slate-100 text-xs uppercase tracking-wide text-slate-500"><tr><th className="px-3 py-2 text-left">Shipment batch</th><th className="px-3 py-2 text-left">Parties</th><th className="px-3 py-2 text-left">Dispatch</th><th className="px-3 py-2 text-right">Packages / qty</th><th className="px-3 py-2 text-left">Receipt</th><th className="px-3 py-2 text-left">Allocation</th><th className="px-3 py-2 text-left">Documents</th><th className="px-3 py-2 text-left">Next action</th><th className="px-3 py-2 text-left">Links</th></tr></thead><tbody className="divide-y divide-slate-100 bg-white">
              {rows.map((row) => (
                <tr key={row.shipment_batch_id}>
                  <td className="px-3 py-3 align-top"><p className="font-semibold text-slate-950">{row.booking_ref ?? row.shipment_batch_id}</p><p className="mt-1 text-xs text-slate-500">Batch {row.shipment_batch_id.slice(0, 8)}…</p><span className={`mt-2 inline-block rounded-full px-2 py-1 text-xs font-semibold ${statusClass(row.batch_status)}`}>{friendly(row.batch_status)}</span></td>
                  <td className="px-3 py-3 align-top"><p className="font-semibold">{row.importer_name ?? "Importer"}</p><p className="mt-1 text-xs text-slate-600">{row.shipper_name ?? "Shipper"}</p><p className="mt-2 text-xs text-slate-500">Orders: {truncate(row.order_refs_preview, 58)}</p></td>
                  <td className="px-3 py-3 align-top"><p><span className="text-slate-500">Dispatch:</span> {shortDate(row.dispatched_at)}</p><p className="mt-1"><span className="text-slate-500">Cut-off:</span> {shortDate(row.shipment_cutoff_at)}</p><p className="mt-1"><span className="text-slate-500">Boxes:</span> {row.box_count ?? "—"}</p></td>
                  <td className="px-3 py-3 text-right align-top"><p className="font-semibold">{n(row.package_count)} package{n(row.package_count) === 1 ? "" : "s"}</p><p className="mt-1 text-xs text-slate-600">{qty(row.item_qty)} unit{n(row.item_qty) === 1 ? "" : "s"}</p><p className="mt-2 text-xs text-slate-500">{truncate(row.package_refs_preview, 52)}</p></td>
                  <td className="px-3 py-3 align-top"><span className={`rounded-full px-2 py-1 text-xs font-semibold ${statusClass(row.receipt_status_summary)}`}>{friendly(row.receipt_status_summary)}</span>{n(row.receipt_issue_count) > 0 ? <p className="mt-2 text-xs font-semibold text-rose-700">{n(row.receipt_issue_count)} issue(s)</p> : null}</td>
                  <td className="px-3 py-3 align-top"><span className={`rounded-full px-2 py-1 text-xs font-semibold ${statusClass(row.allocation_status_summary)}`}>{friendly(row.allocation_status_summary)}</span><p className="mt-2 text-xs text-slate-600">{n(row.allocated_package_count)} allocated · {n(row.unallocated_package_count)} missing</p></td>
                  <td className="px-3 py-3 align-top"><div className="space-y-1"><span className={`inline-block rounded-full px-2 py-1 text-xs font-semibold ${statusClass(row.shipper_invoice_status)}`}>Shipper invoice: {friendly(row.shipper_invoice_status)}</span><span className={`block w-fit rounded-full px-2 py-1 text-xs font-semibold ${statusClass(row.export_evidence_status)}`}>Export evidence: {friendly(row.export_evidence_status)}</span><span className={`block w-fit rounded-full px-2 py-1 text-xs font-semibold ${statusClass(row.master_shipment_status)}`}>Master shipment: {friendly(row.master_shipment_status)}</span><span className={`block w-fit rounded-full px-2 py-1 text-xs font-semibold ${statusClass(row.sage_readiness_status)}`}>AP/Sage: {friendly(row.sage_readiness_status)}</span></div></td>
                  <td className="px-3 py-3 align-top"><span className={`rounded-full px-2 py-1 text-xs font-semibold ${statusClass(row.next_action)}`}>{friendly(row.next_action)}</span></td>
                  <td className="px-3 py-3 align-top"><div className="flex flex-col gap-2"><Link href={`/internal/shipping-control/${row.shipment_batch_id}`} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-xs font-semibold text-slate-800 hover:bg-slate-50">View batch detail</Link><Link href="/internal/shipping-control/shipper-documents" className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-xs font-semibold text-slate-800 hover:bg-slate-50">Review shipper docs</Link><span className="rounded-xl border border-dashed border-slate-300 bg-slate-50 px-3 py-2 text-xs font-semibold text-slate-500">Draft COS review later</span></div></td>
                </tr>
              ))}
            </tbody></table></div>
          )}
        </section>
        <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm leading-6 text-amber-900"><h2 className="font-semibold">Control rule</h2><p className="mt-2">This page is the overview. Repeated actions belong in focused child queues: shipper document review, customer invoice release, AP/Sage readiness, draft COS and export evidence. This page itself does not approve, post, clear VAT, generate COS/BOL/POD or create customer invoices.</p></section>
      </div>
    </main>
  );
}
