import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { reviewFinalExportEvidenceDocumentAction } from "./actions";

type FinalEvidenceDoc = {
  document_id: string;
  shipment_batch_id: string;
  booking_ref: string | null;
  shipper_name: string | null;
  document_kind: string | null;
  document_ref: string | null;
  file_url: string | null;
  notes: string | null;
  review_status: string | null;
  supervisor_review_notes: string | null;
  reviewed_at: string | null;
  created_at: string | null;
};

function friendly(value: string | null | undefined) {
  if (!value) return "—";
  return value.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase());
}

function shortDate(value: string | null | undefined) {
  if (!value) return "—";
  return value.includes("T") ? value.slice(0, 10) : value;
}

function statusClass(status: string | null | undefined) {
  if (status === "accepted_current") return "bg-emerald-100 text-emerald-800";
  if (status === "rejected_resubmit_required") return "bg-rose-100 text-rose-800";
  return "bg-amber-100 text-amber-800";
}

export default async function InternalFinalExportEvidencePage({
  params,
  searchParams,
}: {
  params: Promise<{ shipment_batch_id: string }>;
  searchParams?: Promise<{ success?: string; error?: string }>;
}) {
  const { shipment_batch_id: shipmentBatchId } = await params;
  const queryParams = searchParams ? await searchParams : {};
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

  const { data, error } = await (supabase as any).rpc("internal_final_export_evidence_documents_v1", {
    p_shipment_batch_id: shipmentBatchId,
  });

  const rows = (data ?? []) as FinalEvidenceDoc[];
  const first = rows[0] ?? null;

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-6xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-wrap gap-3 text-sm font-semibold text-sky-700">
            <Link href="/internal/shipping-control">← Shipping control</Link>
            <Link href={`/internal/export-evidence/draft/${shipmentBatchId}`}>Draft COS / EEP review</Link>
            <Link href={`/shipper/shipments/${shipmentBatchId}/draft-cos-pack`}>Download draft pack</Link>
          </div>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Goodcashback Internal</p>
          <h1 className="mt-2 text-2xl font-semibold tracking-tight sm:text-3xl">Final COS / export evidence review</h1>
          <p className="mt-2 text-sm leading-6 text-slate-600">
            Supervisor review lane for completed signed/stamped COS, final EEP/packing list, MBL/BOL, container/seal evidence and export/departure evidence uploaded by the shipper.
          </p>
          <p className="mt-2 text-sm text-slate-500">Batch: {first?.booking_ref ?? shipmentBatchId} · Shipper: {first?.shipper_name ?? "—"}</p>
          {queryParams.success ? <p className="mt-4 rounded-xl border border-emerald-300 bg-emerald-50 px-3 py-2 text-sm text-emerald-900">{queryParams.success}</p> : null}
          {queryParams.error ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">{queryParams.error}</p> : null}
          {error ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">{error.message}</p> : null}
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <h2 className="text-xl font-semibold">Uploaded final evidence</h2>
          {rows.length === 0 ? <p className="mt-4 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-700">No completed COS / final export evidence uploaded yet.</p> : (
            <div className="mt-4 space-y-4">
              {rows.map((doc) => (
                <article key={doc.document_id} className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
                  <div className="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
                    <div className="min-w-0">
                      <p className="text-lg font-semibold">{friendly(doc.document_kind)}</p>
                      <p className="text-sm text-slate-600">Ref: {doc.document_ref || "—"} · Uploaded {shortDate(doc.created_at)}</p>
                      {doc.notes ? <p className="mt-2 text-sm text-slate-700">{doc.notes}</p> : null}
                      {doc.supervisor_review_notes ? <p className="mt-2 text-sm font-semibold text-rose-800">Review note: {doc.supervisor_review_notes}</p> : null}
                    </div>
                    <div className="flex flex-wrap gap-2">
                      <span className={`rounded-full px-3 py-1 text-xs font-semibold ${statusClass(doc.review_status)}`}>{friendly(doc.review_status)}</span>
                      {doc.file_url ? <a href={doc.file_url} target="_blank" rel="noreferrer" className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-xs font-semibold text-slate-800 hover:bg-slate-100">View/download</a> : null}
                    </div>
                  </div>
                  <form action={reviewFinalExportEvidenceDocumentAction} className="mt-4 grid gap-3 md:grid-cols-[1fr_auto_auto]">
                    <input type="hidden" name="shipment_batch_id" value={shipmentBatchId} />
                    <input type="hidden" name="document_id" value={doc.document_id} />
                    <input name="review_notes" placeholder="Review note if rejecting or recording acceptance context" className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm" />
                    <button type="submit" name="review_status" value="accepted_current" className="rounded-xl bg-emerald-700 px-4 py-2 text-sm font-semibold text-white hover:bg-emerald-800">Accept current</button>
                    <button type="submit" name="review_status" value="rejected_resubmit_required" className="rounded-xl bg-rose-700 px-4 py-2 text-sm font-semibold text-white hover:bg-rose-800">Reject / resubmit</button>
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
