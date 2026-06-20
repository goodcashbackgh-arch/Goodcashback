import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { submitGroupagePodAction, submitGroupageSignedExportPackAction } from "../../../shipments/actions";

type DetailRow = {
  groupage_movement_id: string;
  groupage_movement_ref: string | null;
  groupage_status: string | null;
  shipment_batch_id: string;
  booking_ref: string | null;
  importer_name: string | null;
  export_evidence_status: string | null;
  pod_status: string | null;
};

function friendly(value: string | null | undefined) {
  if (!value) return "—";
  return value.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase());
}

function evidenceLabel(value: string | null | undefined) {
  if (!value || value === "not_started") return "Not submitted";
  if (value === "submitted_for_review") return "Submitted for review";
  if (value === "accepted_current") return "Accepted current";
  if (value === "rejected_resubmit_required") return "Rejected — resubmit required";
  return friendly(value);
}

function statusClass(value: string | null | undefined) {
  if (value === "accepted_current") return "border-emerald-300 bg-emerald-50 text-emerald-900";
  if (value === "submitted_for_review") return "border-amber-300 bg-amber-50 text-amber-900";
  if (value === "rejected_resubmit_required") return "border-rose-300 bg-rose-50 text-rose-900";
  return "border-slate-200 bg-white text-slate-700";
}

function podIsClosed(value: string | null | undefined) {
  return value === "submitted_for_review" || value === "accepted_current";
}

export default async function GroupageFinalEvidencePage({
  params,
  searchParams,
}: {
  params: Promise<{ groupage_movement_id: string }>;
  searchParams?: Promise<{ success?: string; error?: string }>;
}) {
  const { groupage_movement_id: groupageMovementId } = await params;
  const qp = searchParams ? await searchParams : {};
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data, error } = await (supabase as any).rpc("shipper_groupage_movement_detail_v1", {
    p_groupage_movement_id: groupageMovementId,
  });
  const rows = (data ?? []) as DetailRow[];
  const first = rows[0] ?? null;

  if (!first && !error) redirect("/shipper/groupage-movements");

  const movementRef = first?.groupage_movement_ref ?? groupageMovementId;
  const validGroupageSize = rows.length >= 2;
  const signedPackSubmitted = ["signed_export_pack_submitted", "pod_part_submitted", "complete"].includes(first?.groupage_status ?? "");
  const signedPackUploadAllowed = validGroupageSize && first?.groupage_status === "movement_facts_ready";
  const uploadBlocked = !validGroupageSize || (!signedPackUploadAllowed && !signedPackSubmitted);
  const podOpenRows = rows.filter((row) => !podIsClosed(row.pod_status));
  const podSubmittedRows = rows.filter((row) => row.pod_status === "submitted_for_review");
  const podAcceptedRows = rows.filter((row) => row.pod_status === "accepted_current");
  const podUploadAllowed = validGroupageSize && podOpenRows.length > 0;

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-5xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-wrap gap-3 text-sm font-semibold text-sky-700">
            <Link href={`/shipper/groupage-movements/${groupageMovementId}`}>← Back to Groupage Movement</Link>
            <Link href={`/shipper/groupage-movements/${groupageMovementId}/export-pack`} target="_blank">Download combined export pack</Link>
            <Link href={`/shipper/groupage-movements/${groupageMovementId}/sales-invoices-zip`}>Download supporting ZIP</Link>
          </div>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Goodcashback Shipper</p>
          <h1 className="mt-2 text-2xl font-semibold tracking-tight sm:text-3xl">Final evidence upload · {movementRef}</h1>
          <p className="mt-2 text-sm leading-6 text-slate-600">Upload the signed/stamped Groupage Export Pack once for the full movement. Upload POD only for booking refs covered by the delivery evidence. Previously submitted or accepted POD booking refs are locked to prevent duplicate evidence.</p>
          {signedPackSubmitted ? <p className="mt-4 rounded-xl border border-emerald-300 bg-emerald-50 px-3 py-2 text-sm font-semibold text-emerald-900">Signed export pack already submitted for supervisor review.</p> : null}
          {qp.success ? <p className="mt-4 rounded-xl border border-emerald-300 bg-emerald-50 px-3 py-2 text-sm text-emerald-900">{qp.success}</p> : null}
          {qp.error && !signedPackSubmitted ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">{qp.error}</p> : null}
          {error ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">{error.message}</p> : null}
        </section>

        <section className="grid gap-3 md:grid-cols-3">
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs font-semibold uppercase tracking-wide text-slate-500">Booking refs</p><p className="mt-1 text-2xl font-semibold">{rows.length}</p></div>
          <div className="rounded-3xl border border-amber-200 bg-amber-50 p-4 shadow-sm"><p className="text-xs font-semibold uppercase tracking-wide text-amber-700">POD awaiting review</p><p className="mt-1 text-2xl font-semibold text-amber-950">{podSubmittedRows.length}</p></div>
          <div className="rounded-3xl border border-emerald-200 bg-emerald-50 p-4 shadow-sm"><p className="text-xs font-semibold uppercase tracking-wide text-emerald-700">POD accepted</p><p className="mt-1 text-2xl font-semibold text-emerald-950">{podAcceptedRows.length}</p></div>
        </section>

        {uploadBlocked ? (
          <section className="rounded-3xl border border-amber-300 bg-amber-50 p-5 text-sm leading-6 text-amber-900 shadow-sm sm:p-6">
            <h2 className="text-lg font-semibold text-amber-950">Signed pack upload blocked</h2>
            <ul className="mt-2 list-disc space-y-1 pl-5">
              {!validGroupageSize ? <li>A Groupage Movement requires at least two active booking refs.</li> : null}
              {!signedPackUploadAllowed && !signedPackSubmitted ? <li>Movement facts must be saved and ready before signed export pack upload.</li> : null}
            </ul>
          </section>
        ) : null}

        <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 shadow-sm sm:p-6">
          <h2 className="text-xl font-semibold text-amber-950">Signed export pack</h2>
          <p className="mt-2 text-sm leading-6 text-amber-900">The signed/stamped Groupage Export Pack applies to every active included booking ref. It should not be uploaded again unless supervisor/admin rejects it.</p>
          {signedPackSubmitted ? (
            <div className="mt-5 rounded-2xl border border-emerald-300 bg-white p-4 text-sm text-emerald-950">Already submitted. Await supervisor/admin review or rejection/resubmission instruction.</div>
          ) : (
            <form action={submitGroupageSignedExportPackAction} encType="multipart/form-data" className="mt-5 grid gap-3">
              <input type="hidden" name="groupage_movement_id" value={groupageMovementId} />
              <label className="space-y-1 text-sm"><span className="text-xs font-semibold uppercase tracking-wide text-amber-800">Document ref</span><input name="document_ref" defaultValue={movementRef} className="w-full rounded-xl border border-amber-300 bg-white px-3 py-2" /></label>
              <label className="space-y-1 text-sm"><span className="text-xs font-semibold uppercase tracking-wide text-amber-800">Signed export pack file</span><input name="groupage_export_pack_file" type="file" required className="w-full rounded-xl border border-amber-300 bg-white px-3 py-2" /></label>
              <label className="space-y-1 text-sm"><span className="text-xs font-semibold uppercase tracking-wide text-amber-800">Notes, optional</span><textarea name="notes" rows={3} className="w-full rounded-xl border border-amber-300 bg-white px-3 py-2" /></label>
              <button type="submit" disabled={!signedPackUploadAllowed} className="rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800 disabled:cursor-not-allowed disabled:bg-slate-400">Upload and apply to all included batches</button>
            </form>
          )}
        </section>

        <section className="rounded-3xl border border-sky-200 bg-sky-50 p-5 shadow-sm sm:p-6">
          <h2 className="text-xl font-semibold text-sky-950">POD / delivery evidence</h2>
          <p className="mt-2 text-sm leading-6 text-sky-900">Select only open booking refs covered by the POD file. Booking refs already submitted for review or accepted are locked and cannot be selected again.</p>
          <form action={submitGroupagePodAction} encType="multipart/form-data" className="mt-5 grid gap-3">
            <input type="hidden" name="groupage_movement_id" value={groupageMovementId} />
            <div className="grid gap-3">
              {rows.map((row) => {
                const closed = podIsClosed(row.pod_status);
                const rejected = row.pod_status === "rejected_resubmit_required";
                return (
                  <label key={row.shipment_batch_id} className={`flex items-start gap-3 rounded-2xl border p-4 text-sm shadow-sm ${closed ? "border-slate-200 bg-slate-50 opacity-80" : rejected ? "border-rose-300 bg-rose-50" : "border-sky-300 bg-white"}`}>
                    <input type="checkbox" name="pod_shipment_batch_ids" value={row.shipment_batch_id} disabled={!podUploadAllowed || closed} className="mt-1 h-5 w-5" />
                    <span className="min-w-0 flex-1">
                      <span className="block font-semibold text-slate-950">{row.booking_ref ?? row.shipment_batch_id}</span>
                      <span className="block text-slate-500">{row.importer_name ?? "Importer"}</span>
                      <span className={`mt-2 inline-block rounded-full border px-2 py-1 text-xs font-semibold ${statusClass(row.pod_status)}`}>POD: {evidenceLabel(row.pod_status)}</span>
                      <span className={`ml-2 mt-2 inline-block rounded-full border px-2 py-1 text-xs font-semibold ${statusClass(row.export_evidence_status)}`}>Export pack: {evidenceLabel(row.export_evidence_status)}</span>
                    </span>
                  </label>
                );
              })}
            </div>
            {!podUploadAllowed ? <p className="rounded-2xl border border-emerald-300 bg-white p-4 text-sm font-semibold text-emerald-900">No open booking refs require POD upload from this page.</p> : null}
            <label className="space-y-1 text-sm"><span className="text-xs font-semibold uppercase tracking-wide text-sky-800">POD ref</span><input name="pod_document_ref" defaultValue={movementRef} className="w-full rounded-xl border border-sky-300 bg-white px-3 py-2" /></label>
            <label className="space-y-1 text-sm"><span className="text-xs font-semibold uppercase tracking-wide text-sky-800">POD file</span><input name="groupage_pod_file" type="file" required disabled={!podUploadAllowed} className="w-full rounded-xl border border-sky-300 bg-white px-3 py-2 disabled:bg-slate-100" /></label>
            <label className="space-y-1 text-sm"><span className="text-xs font-semibold uppercase tracking-wide text-sky-800">Notes, optional</span><textarea name="pod_notes" rows={3} disabled={!podUploadAllowed} className="w-full rounded-xl border border-sky-300 bg-white px-3 py-2 disabled:bg-slate-100" /></label>
            <button type="submit" disabled={!podUploadAllowed} className="rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800 disabled:cursor-not-allowed disabled:bg-slate-400">Upload POD for selected open booking refs</button>
          </form>
        </section>
      </div>
    </main>
  );
}
