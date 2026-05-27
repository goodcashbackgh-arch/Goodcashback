import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { submitFinalExportEvidenceAction } from "../../actions";

type EvidenceDoc = {
  id: string;
  document_kind: string;
  document_ref: string | null;
  file_url: string;
  notes: string | null;
  review_status: string;
  supervisor_review_notes: string | null;
  reviewed_at: string | null;
  created_at: string;
};

function friendly(value: string | null | undefined) {
  if (!value) return "—";
  return value.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase());
}

function statusClass(status: string | null | undefined) {
  if (status === "accepted_current") return "bg-emerald-100 text-emerald-800";
  if (status === "rejected_resubmit_required") return "bg-rose-100 text-rose-800";
  return "bg-amber-100 text-amber-800";
}

function shortDate(value: string | null | undefined) {
  if (!value) return "—";
  return value.includes("T") ? value.slice(0, 10) : value;
}

export default async function ShipperFinalEvidencePage({
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

  const { data: shipperUser } = await supabase
    .from("shipper_users")
    .select("id, full_name, shipper_id, shippers(name)")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!shipperUser) redirect("/auth/check");

  const [{ data: batch }, { data: fields }, { data: docs, error: docsError }] = await Promise.all([
    supabase
      .from("shipper_shipment_batches")
      .select("id, booking_ref, shipper_id, status")
      .eq("id", shipmentBatchId)
      .eq("shipper_id", (shipperUser as any).shipper_id)
      .maybeSingle(),
    supabase
      .from("shipper_export_evidence_completion_fields")
      .select("completion_status")
      .eq("shipment_batch_id", shipmentBatchId)
      .maybeSingle(),
    supabase
      .from("shipper_final_export_evidence_documents")
      .select("id, document_kind, document_ref, file_url, notes, review_status, supervisor_review_notes, reviewed_at, created_at")
      .eq("shipment_batch_id", shipmentBatchId)
      .order("created_at", { ascending: false }),
  ]);

  if (!batch) redirect("/shipper/shipments?error=Shipment%20batch%20not%20found.");
  const completionReady = (fields as any)?.completion_status === "completion_fields_ready";
  const rows = (docs ?? []) as EvidenceDoc[];
  const shipper = Array.isArray((shipperUser as any).shippers) ? (shipperUser as any).shippers[0] : (shipperUser as any).shippers;

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-5xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-wrap gap-3 text-sm font-semibold text-sky-700">
            <Link href={`/shipper/shipments/${shipmentBatchId}`}>← Shipment batch</Link>
            <Link href="/shipper/shipments">Shipment batches</Link>
          </div>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Goodcashback Shipper</p>
          <h1 className="mt-2 text-2xl font-semibold tracking-tight sm:text-3xl">Upload completed COS / final export evidence</h1>
          <p className="mt-2 text-sm text-slate-600">{(shipperUser as any).full_name} · {shipper?.name ?? "Shipper"} · Batch {(batch as any).booking_ref ?? shipmentBatchId}</p>
          {queryParams.success ? <p className="mt-4 rounded-xl border border-emerald-300 bg-emerald-50 px-3 py-2 text-sm text-emerald-900">{queryParams.success}</p> : null}
          {queryParams.error ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">{queryParams.error}</p> : null}
          {docsError ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">Final evidence table unavailable. Apply the latest migration before testing this page.</p> : null}
        </section>

        <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 shadow-sm sm:p-6">
          <h2 className="text-xl font-semibold text-amber-950">Final evidence upload</h2>
          <p className="mt-2 text-sm leading-6 text-amber-900">Upload the completed signed/stamped COS and any final export evidence documents. Supervisor can view/download and accept or reject after submission.</p>
          {!completionReady ? (
            <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">Complete and save the final shipment/COS fields before uploading final export evidence.</p>
          ) : (
            <form action={submitFinalExportEvidenceAction} className="mt-5 grid gap-3 md:grid-cols-2">
              <input type="hidden" name="shipment_batch_id" value={shipmentBatchId} />
              <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-amber-800">Document type</span><select name="document_kind" required className="w-full rounded-xl border border-amber-300 bg-white px-3 py-2 text-slate-950"><option value="completed_cos">Completed signed/stamped COS</option><option value="final_eep_packing_list">Final EEP / packing list if amended</option><option value="mbl_bol_sea_waybill">MBL / BOL / sea waybill</option><option value="container_seal_evidence">Container / seal evidence</option><option value="export_date_departure_evidence">Export date / departure evidence</option><option value="other_final_export_evidence">Other final export evidence</option></select></label>
              <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-amber-800">Document ref</span><input name="document_ref" placeholder="COS ref, MBL ref, container ref, etc." className="w-full rounded-xl border border-amber-300 bg-white px-3 py-2 text-slate-950" /></label>
              <label className="space-y-1 text-sm md:col-span-2"><span className="text-xs uppercase tracking-wide text-amber-800">File</span><input name="final_export_evidence_file" type="file" required className="w-full rounded-xl border border-amber-300 bg-white px-3 py-2 text-slate-950" /></label>
              <label className="space-y-1 text-sm md:col-span-2"><span className="text-xs uppercase tracking-wide text-amber-800">Notes</span><textarea name="notes" rows={3} className="w-full rounded-xl border border-amber-300 bg-white px-3 py-2 text-slate-950" /></label>
              <div className="md:col-span-2"><button type="submit" className="rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800">Upload for supervisor review</button></div>
            </form>
          )}
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <h2 className="text-xl font-semibold">Submitted final evidence</h2>
          {rows.length === 0 ? <p className="mt-4 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-700">No final evidence uploaded yet.</p> : (
            <div className="mt-4 space-y-3">
              {rows.map((doc) => (
                <article key={doc.id} className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
                  <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
                    <div><p className="font-semibold">{friendly(doc.document_kind)}</p><p className="text-sm text-slate-600">Ref: {doc.document_ref || "—"} · Uploaded {shortDate(doc.created_at)}</p>{doc.notes ? <p className="mt-2 text-sm text-slate-700">{doc.notes}</p> : null}{doc.supervisor_review_notes ? <p className="mt-2 text-sm font-semibold text-rose-800">Supervisor: {doc.supervisor_review_notes}</p> : null}</div>
                    <div className="flex flex-wrap gap-2"><span className={`rounded-full px-3 py-1 text-xs font-semibold ${statusClass(doc.review_status)}`}>{friendly(doc.review_status)}</span><a href={doc.file_url} target="_blank" rel="noreferrer" className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-xs font-semibold text-slate-800 hover:bg-slate-100">View/download</a></div>
                  </div>
                </article>
              ))}
            </div>
          )}
        </section>
      </div>
    </main>
  );
}
