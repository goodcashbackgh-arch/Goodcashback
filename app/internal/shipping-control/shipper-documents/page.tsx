import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type DocumentRow = {
  shipping_document_id: string;
  shipment_batch_id: string;
  booking_ref: string | null;
  shipper_name: string | null;
  importer_name: string | null;
  document_kind: string | null;
  document_ref: string | null;
  document_date: string | null;
  currency_code: string | null;
  total_amount: number | string | null;
  file_url: string | null;
  ocr_status: string | null;
  review_status: string | null;
  version_no: number | null;
  created_at: string | null;
  accepted_at: string | null;
  reviewed_at: string | null;
  package_count: number | string | null;
  item_qty: number | string | null;
  open_message_count: number | string | null;
  next_action: string | null;
};

function n(value: number | string | null | undefined) {
  const parsed = Number(value ?? 0);
  return Number.isFinite(parsed) ? parsed : 0;
}

function shortDate(value: string | null | undefined) {
  if (!value) return "—";
  return value.includes("T") ? value.slice(0, 10) : value;
}

function money(value: number | string | null | undefined, currency = "GBP") {
  if (value === null || value === undefined || value === "") return "—";
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: currency || "GBP" }).format(n(value));
}

function friendly(value: string | null | undefined) {
  if (!value) return "—";
  return value.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase());
}

function statusClass(status: string | null | undefined) {
  if (!status || ["uploaded_pending_ocr", "ocr_pending", "not_started"].includes(status)) return "bg-amber-100 text-amber-800";
  if (["accepted_current", "accepted_locked"].includes(status)) return "bg-emerald-100 text-emerald-800";
  if (["rejected_resubmit_required", "awaiting_shipper_resubmission"].includes(status)) return "bg-rose-100 text-rose-800";
  return "bg-slate-100 text-slate-700";
}

function matches(row: DocumentRow, status: string, search: string) {
  if (status && status !== "all" && row.review_status !== status && row.next_action !== status) return false;
  if (!search) return true;
  const haystack = [row.booking_ref, row.shipper_name, row.importer_name, row.document_kind, row.document_ref, row.shipping_document_id].join(" ").toLowerCase();
  return haystack.includes(search);
}

export default async function InternalShippingDocumentsPage({ searchParams }: { searchParams?: Promise<{ status?: string; q?: string; success?: string; error?: string }> }) {
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

  const { data, error } = await (supabase as any).rpc("internal_shipping_document_worklist_v1");
  const allRows = (data ?? []) as DocumentRow[];
  const rows = allRows.filter((row) => matches(row, selectedStatus, search));

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
              <h1 className="text-2xl font-semibold tracking-tight sm:text-3xl">Shipper invoice / receipt review</h1>
              <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">Supervisor review lane for shipping invoices, receipts and supporting charge documents. This does not apportion shipping, post Sage, create COS/BOL/POD or clear VAT.</p>
            </div>
            <div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700">
              <div className="font-medium text-slate-950">{staff.full_name}</div>
              <div>{staff.role_type}</div>
            </div>
          </div>
          {qp.success ? <p className="mt-4 rounded-xl border border-emerald-300 bg-emerald-50 px-3 py-2 text-sm text-emerald-900">{qp.success}</p> : null}
          {qp.error ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">{qp.error}</p> : null}
          {error ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">{error.message}</p> : null}
        </section>

        <section className="grid gap-4 md:grid-cols-4">
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Active docs</p><p className="mt-1 text-2xl font-semibold">{allRows.length}</p></div>
          <div className="rounded-3xl border border-amber-200 bg-amber-50 p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Needs review</p><p className="mt-1 text-2xl font-semibold">{allRows.filter((row) => !["accepted_current", "rejected_resubmit_required"].includes(row.review_status ?? "")).length}</p></div>
          <div className="rounded-3xl border border-emerald-200 bg-emerald-50 p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Accepted</p><p className="mt-1 text-2xl font-semibold">{allRows.filter((row) => row.review_status === "accepted_current").length}</p></div>
          <div className="rounded-3xl border border-rose-200 bg-rose-50 p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Resubmission</p><p className="mt-1 text-2xl font-semibold">{allRows.filter((row) => row.review_status === "rejected_resubmit_required" || n(row.open_message_count) > 0).length}</p></div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
            <div>
              <h2 className="text-xl font-semibold">Document worklist</h2>
              <p className="mt-2 text-sm leading-6 text-slate-600">Process the uploaded document before shipping apportionment or Sage readiness.</p>
            </div>
            <form action="/internal/shipping-control/shipper-documents" className="grid gap-3 rounded-2xl border border-slate-200 bg-slate-50 p-3 sm:grid-cols-[1fr_1fr_auto]">
              <label className="text-xs font-semibold uppercase tracking-wide text-slate-500">Status
                <select name="status" defaultValue={selectedStatus} className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal text-slate-950">
                  <option value="all">All</option>
                  <option value="uploaded_pending_ocr">Uploaded pending OCR</option>
                  <option value="ocr_pending">OCR pending</option>
                  <option value="needs_supervisor_review">Needs supervisor review</option>
                  <option value="accepted_current">Accepted current</option>
                  <option value="rejected_resubmit_required">Rejected / resubmit required</option>
                </select>
              </label>
              <label className="text-xs font-semibold uppercase tracking-wide text-slate-500">Search
                <input name="q" defaultValue={qp.q ?? ""} placeholder="Booking, importer, shipper, ref" className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal text-slate-950" />
              </label>
              <div className="flex items-end gap-2">
                <button type="submit" className="rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800">Apply</button>
                <Link href="/internal/shipping-control/shipper-documents" className="rounded-xl border border-slate-300 bg-white px-4 py-2 text-sm font-semibold text-slate-800 hover:bg-slate-100">Reset</Link>
              </div>
            </form>
          </div>

          {rows.length === 0 ? (
            <p className="mt-4 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-700">No shipping documents match the filters.</p>
          ) : (
            <div className="mt-5 overflow-x-auto rounded-2xl border border-slate-200">
              <table className="min-w-full divide-y divide-slate-200 text-sm">
                <thead className="bg-slate-100 text-xs uppercase tracking-wide text-slate-500">
                  <tr>
                    <th className="px-3 py-2 text-left">Document</th>
                    <th className="px-3 py-2 text-left">Shipment</th>
                    <th className="px-3 py-2 text-left">Parties</th>
                    <th className="px-3 py-2 text-right">Amount</th>
                    <th className="px-3 py-2 text-left">Status</th>
                    <th className="px-3 py-2 text-left">Next action</th>
                    <th className="px-3 py-2 text-left">Links</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-100 bg-white">
                  {rows.map((row) => (
                    <tr key={row.shipping_document_id}>
                      <td className="px-3 py-3 align-top"><p className="font-semibold">{friendly(row.document_kind)}</p><p className="text-xs text-slate-500">Ref: {row.document_ref ?? "—"} · {shortDate(row.document_date)}</p><p className="text-xs text-slate-500">v{row.version_no ?? 1} · uploaded {shortDate(row.created_at)}</p></td>
                      <td className="px-3 py-3 align-top"><p className="font-semibold">{row.booking_ref ?? row.shipment_batch_id}</p><p className="text-xs text-slate-500">{n(row.package_count)} package(s) · {n(row.item_qty)} unit(s)</p></td>
                      <td className="px-3 py-3 align-top"><p className="font-semibold">{row.importer_name ?? "Importer"}</p><p className="text-xs text-slate-600">{row.shipper_name ?? "Shipper"}</p></td>
                      <td className="px-3 py-3 text-right align-top"><p className="font-semibold">{money(row.total_amount, row.currency_code ?? "GBP")}</p><p className="text-xs text-slate-500">{row.currency_code ?? "GBP"}</p></td>
                      <td className="px-3 py-3 align-top"><span className={`rounded-full px-2 py-1 text-xs font-semibold ${statusClass(row.review_status)}`}>{friendly(row.review_status)}</span><p className="mt-2 text-xs text-slate-500">OCR: {friendly(row.ocr_status)}</p></td>
                      <td className="px-3 py-3 align-top"><span className={`rounded-full px-2 py-1 text-xs font-semibold ${statusClass(row.next_action)}`}>{friendly(row.next_action)}</span>{n(row.open_message_count) > 0 ? <p className="mt-2 text-xs font-semibold text-rose-700">{n(row.open_message_count)} open message(s)</p> : null}</td>
                      <td className="px-3 py-3 align-top"><Link href={`/internal/shipping-control/shipper-documents/${row.shipping_document_id}`} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-xs font-semibold text-slate-800 hover:bg-slate-50">Review document</Link></td>
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
