import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { requestShippingDocumentResubmissionAction, submitShippingDocumentAction } from "../../actions";

type WorklistRow = {
  shipper_user_id: string;
  shipper_id: string;
  shipper_name: string | null;
  shipment_batch_id: string;
  booking_ref: string | null;
  batch_status: string | null;
  importer_id: string | null;
  importer_name: string | null;
  dispatched_at: string | null;
  package_count: number | string | null;
  item_qty: number | string | null;
  latest_document_id: string | null;
  latest_document_kind: string | null;
  latest_document_ref: string | null;
  latest_document_date: string | null;
  latest_currency_code: string | null;
  latest_total_amount: number | string | null;
  latest_file_url: string | null;
  latest_ocr_status: string | null;
  latest_review_status: string | null;
  latest_version_no: number | null;
  open_resubmission_request_count: number | string | null;
  can_upload_or_replace: boolean;
  requires_resubmission_request: boolean;
};

function n(value: number | string | null | undefined) {
  const parsed = Number(value ?? 0);
  return Number.isFinite(parsed) ? parsed : 0;
}

function qty(value: number | string | null | undefined) {
  const parsed = n(value);
  return parsed % 1 === 0 ? String(Math.trunc(parsed)) : parsed.toFixed(3).replace(/0+$/, "").replace(/\.$/, "");
}

function money(value: number | string | null | undefined, currency = "GBP") {
  if (value === null || value === undefined || value === "") return "—";
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: currency || "GBP" }).format(n(value));
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
  if (!status || status === "not_started") return "bg-amber-100 text-amber-800";
  if (["uploaded_pending_ocr", "ocr_pending", "not_started"].includes(status)) return "bg-amber-100 text-amber-800";
  if (["accepted_current"].includes(status)) return "bg-emerald-100 text-emerald-800";
  if (["resubmission_requested", "rejected_resubmit_required"].includes(status)) return "bg-rose-100 text-rose-800";
  if (["superseded", "voided"].includes(status)) return "bg-slate-200 text-slate-700";
  return "bg-slate-100 text-slate-700";
}

function normalizeLink(value: string | null | undefined) {
  const raw = (value ?? "").trim();
  if (!raw) return null;
  if (/^[a-z][a-z0-9+.-]*:/i.test(raw)) return raw;
  if (raw.startsWith("//")) return `https:${raw}`;
  return `https://${raw}`;
}

export default async function NewShippingDocumentPage({
  searchParams,
}: {
  searchParams?: Promise<{ batch?: string; success?: string; error?: string }>;
}) {
  const qp = searchParams ? await searchParams : {};
  const selectedBatchId = qp.batch ?? "";
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

  const { data, error } = await (supabase as any).rpc("shipper_shipping_document_worklist_v1");
  const rows = (data ?? []) as WorklistRow[];
  const selectedRow = rows.find((row) => row.shipment_batch_id === selectedBatchId) ?? rows[0] ?? null;
  const shipper = Array.isArray((shipperUser as any).shippers) ? (shipperUser as any).shippers[0] : (shipperUser as any).shippers;

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-7xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-wrap gap-3 text-sm font-semibold text-sky-700">
            <Link href="/shipper">← Shipper dashboard</Link>
            <Link href="/shipper/shipments">Shipment batches</Link>
          </div>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Goodcashback Shipper</p>
          <h1 className="mt-2 text-2xl font-semibold tracking-tight sm:text-3xl">Shipping charge document upload</h1>
          <p className="mt-2 text-sm text-slate-600">{(shipperUser as any).full_name} · {shipper?.name ?? "Shipper"}</p>
          <p className="mt-3 max-w-4xl text-sm leading-6 text-slate-600">
            Upload the single current money document for this shipment batch. It may be a shipper invoice, receipt or supporting charge document, but only one active document can feed OCR, supervisor money review, shipping apportionment and Sage readiness. Uploading a new document before supervisor acceptance replaces the current one for this batch.
          </p>
          {qp.success ? <p className="mt-4 rounded-xl border border-emerald-300 bg-emerald-50 px-3 py-2 text-sm text-emerald-900">{qp.success}</p> : null}
          {qp.error ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">{qp.error}</p> : null}
          {error ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">{error.message}</p> : null}
        </section>

        <section className="grid gap-4 md:grid-cols-4">
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
            <p className="text-xs uppercase tracking-wide text-slate-500">Shipment batches</p>
            <p className="mt-1 text-2xl font-semibold">{rows.length}</p>
          </div>
          <div className="rounded-3xl border border-amber-200 bg-amber-50 p-4 shadow-sm">
            <p className="text-xs uppercase tracking-wide text-slate-500">No charge doc</p>
            <p className="mt-1 text-2xl font-semibold">{rows.filter((row) => !row.latest_document_id).length}</p>
          </div>
          <div className="rounded-3xl border border-sky-200 bg-sky-50 p-4 shadow-sm">
            <p className="text-xs uppercase tracking-wide text-slate-500">Uploaded</p>
            <p className="mt-1 text-2xl font-semibold">{rows.filter((row) => row.latest_document_id && row.latest_review_status !== "accepted_current").length}</p>
          </div>
          <div className="rounded-3xl border border-emerald-200 bg-emerald-50 p-4 shadow-sm">
            <p className="text-xs uppercase tracking-wide text-slate-500">Accepted</p>
            <p className="mt-1 text-2xl font-semibold">{rows.filter((row) => row.latest_review_status === "accepted_current").length}</p>
          </div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
            <div>
              <h2 className="text-xl font-semibold">Choose shipment batch</h2>
              <p className="mt-2 text-sm leading-6 text-slate-600">Select the importer shipment batch. There is only one current charge document per batch.</p>
            </div>
            <form action="/shipper/shipping-documents/new" className="flex flex-wrap items-end gap-3 rounded-2xl border border-slate-200 bg-slate-50 p-3">
              <label className="text-xs font-semibold uppercase tracking-wide text-slate-500">
                Shipment batch
                <select name="batch" defaultValue={selectedRow?.shipment_batch_id ?? ""} className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal text-slate-950">
                  {rows.length === 0 ? <option value="">No shipment batches</option> : null}
                  {rows.map((row) => (
                    <option key={row.shipment_batch_id} value={row.shipment_batch_id}>{row.booking_ref ?? row.shipment_batch_id} · {row.importer_name ?? "Importer"}</option>
                  ))}
                </select>
              </label>
              <button type="submit" className="rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800">Choose</button>
            </form>
          </div>

          {!selectedRow ? (
            <p className="mt-4 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-700">No shipment batches are available yet.</p>
          ) : (
            <div className="mt-5 grid gap-5 lg:grid-cols-[1fr_1.1fr]">
              <article className="rounded-3xl border border-slate-200 bg-slate-50 p-4">
                <h3 className="text-lg font-semibold">Batch summary</h3>
                <div className="mt-4 grid gap-3 text-sm md:grid-cols-2">
                  <div className="rounded-2xl bg-white p-3"><span className="text-slate-500">Booking ref</span><p className="font-semibold">{selectedRow.booking_ref ?? selectedRow.shipment_batch_id}</p></div>
                  <div className="rounded-2xl bg-white p-3"><span className="text-slate-500">Importer</span><p className="font-semibold">{selectedRow.importer_name ?? "—"}</p></div>
                  <div className="rounded-2xl bg-white p-3"><span className="text-slate-500">Dispatch</span><p className="font-semibold">{shortDate(selectedRow.dispatched_at)}</p></div>
                  <div className="rounded-2xl bg-white p-3"><span className="text-slate-500">Packages / qty</span><p className="font-semibold">{n(selectedRow.package_count)} package(s) · {qty(selectedRow.item_qty)} unit(s)</p></div>
                </div>

                <div className="mt-4 rounded-2xl border border-slate-200 bg-white p-4 text-sm">
                  <h4 className="font-semibold">Current charge document</h4>
                  <p className="mt-2"><span className="text-slate-500">Status:</span> <span className={`rounded-full px-2 py-1 text-xs font-semibold ${statusClass(selectedRow.latest_review_status)}`}>{friendly(selectedRow.latest_review_status ?? "not_started")}</span></p>
                  {selectedRow.latest_document_id ? (
                    <div className="mt-3 space-y-1 text-slate-700">
                      <p><span className="text-slate-500">Type:</span> {friendly(selectedRow.latest_document_kind)}</p>
                      <p><span className="text-slate-500">Ref:</span> {selectedRow.latest_document_ref ?? "—"}</p>
                      <p><span className="text-slate-500">Date:</span> {shortDate(selectedRow.latest_document_date)}</p>
                      <p><span className="text-slate-500">Amount:</span> {money(selectedRow.latest_total_amount, selectedRow.latest_currency_code ?? "GBP")}</p>
                      <p><span className="text-slate-500">OCR:</span> {friendly(selectedRow.latest_ocr_status)}</p>
                      <p><span className="text-slate-500">Version:</span> {selectedRow.latest_version_no ?? "—"}</p>
                      {normalizeLink(selectedRow.latest_file_url) ? <a href={normalizeLink(selectedRow.latest_file_url) ?? "#"} target="_blank" rel="noreferrer" className="inline-block font-semibold text-sky-700 underline">Open current document</a> : null}
                    </div>
                  ) : <p className="mt-2 text-slate-600">No current shipping charge document uploaded yet.</p>}
                </div>
              </article>

              <article className="rounded-3xl border border-slate-200 bg-white p-4">
                {selectedRow.can_upload_or_replace ? (
                  <>
                    <h3 className="text-lg font-semibold">{selectedRow.latest_document_id ? "Replace current charge document" : "Upload charge document"}</h3>
                    <p className="mt-2 text-sm leading-6 text-slate-600">
                      Replacement is allowed only before supervisor acceptance. A new upload supersedes the current active charge document for this shipment batch, even if the document type is different.
                    </p>
                    <form action={submitShippingDocumentAction} className="mt-4 grid gap-3 md:grid-cols-2">
                      <input type="hidden" name="shipment_batch_id" value={selectedRow.shipment_batch_id} />
                      <label className="space-y-1 text-sm">
                        <span className="text-xs uppercase tracking-wide text-slate-500">Document type</span>
                        <select name="document_kind" required className="w-full rounded-xl border border-slate-300 px-3 py-2">
                          <option value="shipper_invoice">Shipper invoice</option>
                          <option value="shipper_receipt">Shipper receipt</option>
                          <option value="supporting_charge_document">Supporting charge document</option>
                        </select>
                      </label>
                      <label className="space-y-1 text-sm">
                        <span className="text-xs uppercase tracking-wide text-slate-500">Ref</span>
                        <input name="document_ref" className="w-full rounded-xl border border-slate-300 px-3 py-2" placeholder="Invoice/receipt ref" />
                      </label>
                      <label className="space-y-1 text-sm">
                        <span className="text-xs uppercase tracking-wide text-slate-500">Document date</span>
                        <input name="document_date" type="date" className="w-full rounded-xl border border-slate-300 px-3 py-2" />
                      </label>
                      <label className="space-y-1 text-sm">
                        <span className="text-xs uppercase tracking-wide text-slate-500">Currency</span>
                        <input name="currency_code" defaultValue="GBP" maxLength={3} className="w-full rounded-xl border border-slate-300 px-3 py-2 uppercase" />
                      </label>
                      <label className="space-y-1 text-sm">
                        <span className="text-xs uppercase tracking-wide text-slate-500">Total amount</span>
                        <input name="total_amount" type="number" step="0.01" min="0" className="w-full rounded-xl border border-slate-300 px-3 py-2" />
                      </label>
                      <label className="space-y-1 text-sm">
                        <span className="text-xs uppercase tracking-wide text-slate-500">File</span>
                        <input name="shipping_document_file" required type="file" accept=".pdf,image/*,.png,.jpg,.jpeg,.webp" className="w-full rounded-xl border border-slate-300 px-3 py-2" />
                      </label>
                      <label className="space-y-1 text-sm md:col-span-2">
                        <span className="text-xs uppercase tracking-wide text-slate-500">Notes</span>
                        <textarea name="notes" rows={2} className="w-full rounded-xl border border-slate-300 px-3 py-2" placeholder="Optional note for supervisor" />
                      </label>
                      <div className="md:col-span-2">
                        <button type="submit" className="rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800">
                          {selectedRow.latest_document_id ? "Upload replacement" : "Upload document"}
                        </button>
                      </div>
                    </form>
                  </>
                ) : (
                  <>
                    <h3 className="text-lg font-semibold">Accepted document locked</h3>
                    <p className="mt-2 text-sm leading-6 text-slate-600">
                      Supervisor has accepted the current charge document. Submit a resubmission request message if a replacement is needed.
                    </p>
                    <form action={requestShippingDocumentResubmissionAction} className="mt-4 space-y-3">
                      <input type="hidden" name="shipping_document_id" value={selectedRow.latest_document_id ?? ""} />
                      <label className="space-y-1 text-sm">
                        <span className="text-xs uppercase tracking-wide text-slate-500">Resubmission request message</span>
                        <textarea name="message" required rows={3} className="w-full rounded-xl border border-slate-300 px-3 py-2" placeholder="Explain why a replacement is needed" />
                      </label>
                      <button type="submit" className="rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800">Send request</button>
                    </form>
                  </>
                )}
              </article>
            </div>
          )}
        </section>
      </div>
    </main>
  );
}
