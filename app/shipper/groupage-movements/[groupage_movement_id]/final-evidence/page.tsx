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
          <p className="mt-2 text-sm leading-6 text-slate-600">Upload the signed/stamped Groupage Export Pack after downloading the pack and supporting shipment documents. The upload is applied to all active included booking refs through the existing batch evidence controls.</p>
          {signedPackSubmitted ? <p className="mt-4 rounded-xl border border-emerald-300 bg-emerald-50 px-3 py-2 text-sm font-semibold text-emerald-900">Signed export pack already submitted for supervisor review.</p> : null}
          {qp.success ? <p className="mt-4 rounded-xl border border-emerald-300 bg-emerald-50 px-3 py-2 text-sm text-emerald-900">{qp.success}</p> : null}
          {qp.error && !signedPackSubmitted ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">{qp.error}</p> : null}
          {error ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">{error.message}</p> : null}
        </section>

        {uploadBlocked ? (
          <section className="rounded-3xl border border-amber-300 bg-amber-50 p-5 text-sm leading-6 text-amber-900 shadow-sm sm:p-6">
            <h2 className="text-lg font-semibold text-amber-950">Upload blocked</h2>
            <ul className="mt-2 list-disc space-y-1 pl-5">
              {!validGroupageSize ? <li>A Groupage Movement requires at least two active booking refs.</li> : null}
              {!signedPackUploadAllowed && !signedPackSubmitted ? <li>Movement facts must be saved and ready before signed export pack upload.</li> : null}
            </ul>
          </section>
        ) : null}

        <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 shadow-sm sm:p-6">
          <h2 className="text-xl font-semibold text-amber-950">Signed export pack upload</h2>
          <p className="mt-2 text-sm leading-6 text-amber-900">Use the signed/stamped combined Groupage Export Pack. This creates submitted export evidence rows for every included booking ref.</p>
          {signedPackSubmitted ? (
            <div className="mt-5 rounded-2xl border border-emerald-300 bg-white p-4 text-sm text-emerald-950">
              The signed export pack has already been submitted. No further signed-pack upload is required unless supervisor/admin rejects and requests resubmission.
            </div>
          ) : (
            <form action={submitGroupageSignedExportPackAction} encType="multipart/form-data" className="mt-5 grid gap-3">
              <input type="hidden" name="groupage_movement_id" value={groupageMovementId} />
              <label className="space-y-1 text-sm">
                <span className="text-xs font-semibold uppercase tracking-wide text-amber-800">Document ref</span>
                <input name="document_ref" defaultValue={movementRef} className="w-full rounded-xl border border-amber-300 bg-white px-3 py-2" />
              </label>
              <label className="space-y-1 text-sm">
                <span className="text-xs font-semibold uppercase tracking-wide text-amber-800">Signed export pack file</span>
                <input name="groupage_export_pack_file" type="file" required className="w-full rounded-xl border border-amber-300 bg-white px-3 py-2" />
              </label>
              <label className="space-y-1 text-sm">
                <span className="text-xs font-semibold uppercase tracking-wide text-amber-800">Notes, optional</span>
                <textarea name="notes" rows={3} className="w-full rounded-xl border border-amber-300 bg-white px-3 py-2" />
              </label>
              <button type="submit" disabled={!signedPackUploadAllowed} className="rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800 disabled:cursor-not-allowed disabled:bg-slate-400">Upload signed export pack and apply to all included booking refs</button>
            </form>
          )}
        </section>

        <section className="rounded-3xl border border-sky-200 bg-sky-50 p-5 shadow-sm sm:p-6">
          <h2 className="text-xl font-semibold text-sky-950">POD / delivery evidence upload</h2>
          <p className="mt-2 text-sm leading-6 text-sky-900">Select only the booking refs covered by the POD file.</p>
          <form action={submitGroupagePodAction} encType="multipart/form-data" className="mt-5 grid gap-3">
            <input type="hidden" name="groupage_movement_id" value={groupageMovementId} />
            <div className="rounded-2xl border border-sky-200 bg-white p-3">
              <div className="grid gap-2">
                {rows.map((row) => (
                  <label key={row.shipment_batch_id} className="flex items-center gap-2 text-sm">
                    <input type="checkbox" name="pod_shipment_batch_ids" value={row.shipment_batch_id} disabled={!validGroupageSize} />
                    <span className="font-semibold">{row.booking_ref ?? row.shipment_batch_id}</span>
                    <span className="text-slate-500">{row.importer_name ?? "Importer"}</span>
                    <span className="text-xs text-slate-500">Export: {friendly(row.export_evidence_status)} · POD: {friendly(row.pod_status)}</span>
                  </label>
                ))}
              </div>
            </div>
            <label className="space-y-1 text-sm">
              <span className="text-xs font-semibold uppercase tracking-wide text-sky-800">POD ref</span>
              <input name="pod_document_ref" defaultValue={movementRef} className="w-full rounded-xl border border-sky-300 bg-white px-3 py-2" />
            </label>
            <label className="space-y-1 text-sm">
              <span className="text-xs font-semibold uppercase tracking-wide text-sky-800">POD file</span>
              <input name="groupage_pod_file" type="file" required className="w-full rounded-xl border border-sky-300 bg-white px-3 py-2" />
            </label>
            <label className="space-y-1 text-sm">
              <span className="text-xs font-semibold uppercase tracking-wide text-sky-800">Notes, optional</span>
              <textarea name="pod_notes" rows={3} className="w-full rounded-xl border border-sky-300 bg-white px-3 py-2" />
            </label>
            <button type="submit" disabled={!validGroupageSize} className="rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800 disabled:cursor-not-allowed disabled:bg-slate-400">Upload POD for selected booking refs</button>
          </form>
        </section>
      </div>
    </main>
  );
}
