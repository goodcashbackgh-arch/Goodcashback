import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { reviewShippingDocumentAction, reviewShippingDocumentResubmissionRequestAction } from "../actions";

type DetailRow = {
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
  notes: string | null;
  version_no: number | null;
  created_at: string | null;
  accepted_at: string | null;
  reviewed_at: string | null;
  review_note: string | null;
  extracted_document_ref: string | null;
  extracted_document_date: string | null;
  extracted_currency_code: string | null;
  extracted_total_amount: number | string | null;
  package_count: number | string | null;
  item_qty: number | string | null;
};

type ResubmissionRequestRow = {
  message_id: string;
  message_body: string | null;
  created_at: string | null;
  shipper_user_name: string | null;
  status: string | null;
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
  if (!status || ["uploaded_pending_ocr", "ocr_pending", "needs_supervisor_review", "not_started"].includes(status)) return "bg-amber-100 text-amber-800";
  if (["accepted_current", "resubmission_approved"].includes(status)) return "bg-emerald-100 text-emerald-800";
  if (["rejected_resubmit_required"].includes(status)) return "bg-rose-100 text-rose-800";
  if (["superseded"].includes(status)) return "bg-slate-200 text-slate-700";
  return "bg-slate-100 text-slate-700";
}

function normalizeLink(value: string | null | undefined) {
  const raw = (value ?? "").trim();
  if (!raw) return null;
  if (/^[a-z][a-z0-9+.-]*:/i.test(raw)) return raw;
  if (raw.startsWith("//")) return `https:${raw}`;
  return `https://${raw}`;
}

export default async function ShippingDocumentReviewDetailPage({ params, searchParams }: { params: Promise<{ shipping_document_id: string }>; searchParams?: Promise<{ success?: string; error?: string }> }) {
  const { shipping_document_id: shippingDocumentId } = await params;
  const qp = searchParams ? await searchParams : {};
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

  const { data, error } = await (supabase as any).rpc("internal_shipping_document_detail_v1", {
    p_shipping_document_id: shippingDocumentId,
  });
  const rows = (data ?? []) as DetailRow[];
  const doc = rows[0] ?? null;

  let resubmissionRequests: ResubmissionRequestRow[] = [];
  let resubmissionError: string | null = null;
  if (doc) {
    const { data: requestData, error: requestError } = await (supabase as any).rpc("internal_shipping_document_resubmission_requests_v1", {
      p_shipping_document_id: shippingDocumentId,
    });
    resubmissionRequests = (requestData ?? []) as ResubmissionRequestRow[];
    resubmissionError = requestError?.message ?? null;
  }

  const fileUrl = normalizeLink(doc?.file_url);
  const isAccepted = doc?.review_status === "accepted_current";
  const replacementApproved = doc?.review_status === "resubmission_approved";
  const isSuperseded = doc?.review_status === "superseded";
  const hasOpenResubmissionRequest = resubmissionRequests.length > 0;
  const disableProcessing = isAccepted || replacementApproved || isSuperseded;

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-7xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-wrap gap-3 text-sm font-semibold text-sky-700">
            <Link href="/internal/shipping-control/shipper-documents">← Shipper document queue</Link>
            <Link href="/internal/shipping-control">Shipping control</Link>
          </div>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Goodcashback Internal</p>
          <div className="mt-2 flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
            <div>
              <h1 className="text-2xl font-semibold tracking-tight sm:text-3xl">Review shipper document</h1>
              <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">Process shipper invoice/receipt intake only. Acceptance locks shipper replacement and moves this toward shipping apportionment/Sage readiness later.</p>
            </div>
            <div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700"><div className="font-medium text-slate-950">{staff.full_name}</div><div>{staff.role_type}</div></div>
          </div>
          {qp.success ? <p className="mt-4 rounded-xl border border-emerald-300 bg-emerald-50 px-3 py-2 text-sm text-emerald-900">{qp.success}</p> : null}
          {qp.error ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">{qp.error}</p> : null}
          {error ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">{error.message}</p> : null}
          {resubmissionError ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">Resubmission request view unavailable: {resubmissionError}. Run the latest migration before testing unlock approval.</p> : null}
          {!doc && !error ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">Shipping document not found.</p> : null}
        </section>

        {doc ? (
          <>
            {isSuperseded ? (
              <section className="rounded-3xl border border-slate-300 bg-slate-100 p-5 text-sm leading-6 text-slate-800 shadow-sm">
                <h2 className="text-lg font-semibold text-slate-950">Superseded audit record</h2>
                <p className="mt-2">This document was replaced by a revised shipper upload. It remains visible for audit trail only and cannot be processed. Use the shipper document queue to open the current active document for this shipment batch.</p>
                <Link href="/internal/shipping-control/shipper-documents" className="mt-3 inline-block rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800">Open current document queue</Link>
              </section>
            ) : null}

            <section className="grid gap-4 md:grid-cols-5">
              <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Booking ref</p><p className="mt-1 text-xl font-semibold">{doc.booking_ref ?? doc.shipment_batch_id}</p></div>
              <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Importer</p><p className="mt-1 text-xl font-semibold">{doc.importer_name ?? "—"}</p></div>
              <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Shipper</p><p className="mt-1 text-xl font-semibold">{doc.shipper_name ?? "—"}</p></div>
              <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Packages / qty</p><p className="mt-1 text-xl font-semibold">{n(doc.package_count)} / {n(doc.item_qty)}</p></div>
              <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Status</p><span className={`mt-1 inline-block rounded-full px-2 py-1 text-xs font-semibold ${statusClass(doc.review_status)}`}>{friendly(doc.review_status)}</span></div>
            </section>

            {isAccepted ? (
              <section className="rounded-3xl border border-emerald-200 bg-emerald-50 p-5 text-sm leading-6 text-emerald-900 shadow-sm">
                <h2 className="text-lg font-semibold">Next lane: shipping cost apportionment</h2>
                <p className="mt-2">This accepted document is ready for supervisor shipping-cost apportionment. This still does not post to Sage, generate COS/BOL/POD or clear VAT.</p>
                <Link href={`/internal/shipping-control/apportionment/${doc.shipping_document_id}`} className="mt-3 inline-block rounded-xl bg-emerald-700 px-4 py-2 text-sm font-semibold text-white hover:bg-emerald-800">Review apportionment</Link>
              </section>
            ) : null}

            <section className="grid gap-6 lg:grid-cols-[1fr_1.1fr]">
              <article className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
                <h2 className="text-xl font-semibold">Uploaded document</h2>
                <div className="mt-4 grid gap-3 text-sm md:grid-cols-2">
                  <div className="rounded-2xl bg-slate-50 p-3"><span className="text-slate-500">Type</span><p className="font-semibold">{friendly(doc.document_kind)}</p></div>
                  <div className="rounded-2xl bg-slate-50 p-3"><span className="text-slate-500">Ref</span><p className="font-semibold">{doc.document_ref ?? "—"}</p></div>
                  <div className="rounded-2xl bg-slate-50 p-3"><span className="text-slate-500">Date</span><p className="font-semibold">{shortDate(doc.document_date)}</p></div>
                  <div className="rounded-2xl bg-slate-50 p-3"><span className="text-slate-500">Amount</span><p className="font-semibold">{money(doc.total_amount, doc.currency_code ?? "GBP")}</p></div>
                  <div className="rounded-2xl bg-slate-50 p-3"><span className="text-slate-500">OCR</span><p className="font-semibold">{friendly(doc.ocr_status)}</p></div>
                  <div className="rounded-2xl bg-slate-50 p-3"><span className="text-slate-500">Version</span><p className="font-semibold">v{doc.version_no ?? 1}</p></div>
                </div>
                {doc.notes ? <p className="mt-4 rounded-2xl bg-slate-50 p-3 text-sm text-slate-700"><span className="font-semibold">Shipper note:</span> {doc.notes}</p> : null}
                {fileUrl ? <a href={fileUrl} target="_blank" rel="noreferrer" className="mt-4 inline-block rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800">Open uploaded document</a> : null}
                {doc.review_note ? <p className="mt-4 rounded-2xl bg-amber-50 p-3 text-sm text-amber-900"><span className="font-semibold">Review note:</span> {doc.review_note}</p> : null}
              </article>

              <article className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
                <h2 className="text-xl font-semibold">Supervisor processing</h2>
                <p className="mt-2 text-sm leading-6 text-slate-600">Use OCR/manual extracted fields for document control only. Shipping apportionment and Sage posting happen later.</p>
                <form action={reviewShippingDocumentAction} className="mt-4 grid gap-3 md:grid-cols-2">
                  <input type="hidden" name="shipping_document_id" value={doc.shipping_document_id} />

                  <div className="rounded-2xl border border-slate-200 bg-slate-50 p-3 text-sm md:col-span-2">
                    <p className="font-semibold text-slate-950">Decision guide</p>
                    <p className="mt-1 text-slate-600"><strong>Queue OCR</strong> means extraction/review is still pending. <strong>Accept current document</strong> means this document is confirmed as the shipment money source and replacement is locked.</p>
                  </div>

                  <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-slate-500">Extracted ref</span><input name="extracted_document_ref" defaultValue={doc.extracted_document_ref ?? doc.document_ref ?? ""} className="w-full rounded-xl border border-slate-300 px-3 py-2" disabled={disableProcessing} /></label>
                  <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-slate-500">Extracted date</span><input name="extracted_document_date" type="date" defaultValue={doc.extracted_document_date ?? doc.document_date ?? ""} className="w-full rounded-xl border border-slate-300 px-3 py-2" disabled={disableProcessing} /></label>
                  <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-slate-500">Currency</span><input name="extracted_currency_code" defaultValue={doc.extracted_currency_code ?? doc.currency_code ?? "GBP"} maxLength={3} className="w-full rounded-xl border border-slate-300 px-3 py-2 uppercase" disabled={disableProcessing} /></label>
                  <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-slate-500">Extracted total</span><input name="extracted_total_amount" type="number" step="0.01" min="0" defaultValue={String(doc.extracted_total_amount ?? doc.total_amount ?? "")} className="w-full rounded-xl border border-slate-300 px-3 py-2" disabled={disableProcessing} /></label>
                  <label className="space-y-1 text-sm md:col-span-2"><span className="text-xs uppercase tracking-wide text-slate-500">Review note</span><textarea name="review_note" rows={3} defaultValue={doc.review_note ?? ""} className="w-full rounded-xl border border-slate-300 px-3 py-2" placeholder="Required if rejecting/resubmission is needed" disabled={disableProcessing} /></label>

                  <div className="md:col-span-2">
                    {isSuperseded ? (
                      <p className="rounded-2xl border border-slate-200 bg-slate-50 p-3 text-sm font-semibold text-slate-800">Superseded audit record. Open the current document from the queue to continue processing.</p>
                    ) : replacementApproved ? (
                      <p className="rounded-2xl border border-sky-200 bg-sky-50 p-3 text-sm font-semibold text-sky-900">Replacement upload approved. Shipper can now upload the revised current charge document.</p>
                    ) : isAccepted ? (
                      <p className="rounded-2xl border border-emerald-200 bg-emerald-50 p-3 text-sm font-semibold text-emerald-900">Accepted and locked. Shipper can no longer silently replace this document.</p>
                    ) : (
                      <div className="grid gap-2 sm:grid-cols-2">
                        <button type="submit" name="decision" value="mark_ocr_queued" className="rounded-xl border border-slate-300 bg-white px-4 py-2 text-sm font-semibold text-slate-800 hover:bg-slate-50">Queue OCR</button>
                        <button type="submit" name="decision" value="mark_ocr_not_applicable" className="rounded-xl border border-slate-300 bg-white px-4 py-2 text-sm font-semibold text-slate-800 hover:bg-slate-50">Manual review / no OCR</button>
                        <button type="submit" name="decision" value="accept_current" className="rounded-xl bg-emerald-700 px-4 py-2 text-sm font-semibold text-white hover:bg-emerald-800">Accept current document</button>
                        <button type="submit" name="decision" value="reject_resubmit_required" className="rounded-xl bg-rose-700 px-4 py-2 text-sm font-semibold text-white hover:bg-rose-800">Reject / request resubmission</button>
                      </div>
                    )}
                  </div>
                </form>
              </article>
            </section>

            {(hasOpenResubmissionRequest || replacementApproved) && !isSuperseded ? (
              <section className={`rounded-3xl border p-5 shadow-sm ${replacementApproved ? "border-sky-200 bg-sky-50" : "border-amber-200 bg-amber-50"}`}>
                <h2 className="text-xl font-semibold">Replacement / resubmission control</h2>
                {replacementApproved ? (
                  <p className="mt-2 text-sm leading-6 text-sky-900">Replacement has been approved. The shipper can now upload a revised charge document. The revised upload will supersede this accepted version and become the only active document for the batch.</p>
                ) : null}
                {hasOpenResubmissionRequest ? (
                  <>
                    <p className="mt-2 text-sm leading-6 text-amber-900">The shipper has requested permission to replace the accepted charge document. Approving this does not upload the replacement; it only unlocks one controlled replacement upload.</p>
                    <div className="mt-4 space-y-2">
                      {resubmissionRequests.map((request) => (
                        <div key={request.message_id} className="rounded-2xl bg-white p-3 text-sm text-slate-700">
                          <p className="font-semibold text-slate-950">{request.shipper_user_name ?? "Shipper"} · {shortDate(request.created_at)}</p>
                          <p className="mt-1">{request.message_body}</p>
                        </div>
                      ))}
                    </div>
                    <form action={reviewShippingDocumentResubmissionRequestAction} className="mt-4 grid gap-3 md:grid-cols-2">
                      <input type="hidden" name="shipping_document_id" value={doc.shipping_document_id} />
                      <label className="space-y-1 text-sm md:col-span-2">
                        <span className="text-xs uppercase tracking-wide text-slate-500">Supervisor note</span>
                        <textarea name="resubmission_review_note" rows={3} className="w-full rounded-xl border border-slate-300 px-3 py-2" placeholder="Optional note shown in the audit trail" />
                      </label>
                      <button type="submit" name="resubmission_decision" value="approve_replacement" className="rounded-xl bg-emerald-700 px-4 py-2 text-sm font-semibold text-white hover:bg-emerald-800">Approve replacement upload</button>
                      <button type="submit" name="resubmission_decision" value="decline_request" className="rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800">Decline request / keep locked</button>
                    </form>
                  </>
                ) : null}
              </section>
            ) : null}

            <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm leading-6 text-amber-900">
              <h2 className="font-semibold">Locked rule</h2>
              <p className="mt-2">Accepting this document only confirms the shipping invoice/receipt control document. It does not apportion shipping costs, generate COS/BOL/POD, clear VAT, or post to Sage. Those stay in later lanes.</p>
            </section>
          </>
        ) : null}
      </div>
    </main>
  );
}
