import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { createGroupageMovementAction } from "../shipments/actions";

type CandidateBatch = {
  shipment_batch_id: string;
  booking_ref: string | null;
  importer_id: string | null;
  importer_name: string | null;
  final_recipient_name: string | null;
  final_recipient_address: string | null;
  box_count: number | string | null;
  package_count: number | string | null;
  item_qty: number | string | null;
  invoice_value_gbp: number | string | null;
  export_evidence_status: string | null;
  pod_status: string | null;
  existing_groupage_movement_id: string | null;
  existing_groupage_movement_ref: string | null;
};

type MovementRow = {
  groupage_movement_id: string;
  groupage_movement_ref: string | null;
  status: string | null;
  shipper_name: string | null;
  batch_count: number | string | null;
  signed_export_pack_count: number | string | null;
  pod_document_count: number | string | null;
  accepted_export_pack_count: number | string | null;
  accepted_pod_count: number | string | null;
  created_at: string | null;
  updated_at: string | null;
};

type ExportProfile = {
  id: string;
  profile_name: string | null;
  exporter_name: string | null;
  default_movement_consignee_name: string | null;
  active: boolean | null;
};

function n(value: number | string | null | undefined) {
  const parsed = Number(value ?? 0);
  return Number.isFinite(parsed) ? parsed : 0;
}

function money(value: number | string | null | undefined) {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" }).format(n(value));
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
  if (["complete", "movement_facts_ready", "signed_export_pack_fully_accepted", "pod_fully_accepted", "accepted_current"].includes(status ?? "")) return "bg-emerald-100 text-emerald-800";
  if (["voided", "rejected_resubmit_required"].includes(status ?? "")) return "bg-rose-100 text-rose-800";
  return "bg-amber-100 text-amber-800";
}

function hasSubmittedOrAcceptedEvidence(row: CandidateBatch) {
  return ["submitted_for_review", "accepted_current"].includes(row.export_evidence_status ?? "") || ["submitted_for_review", "accepted_current"].includes(row.pod_status ?? "");
}

export default async function ShipperGroupageMovementsPage({ searchParams }: { searchParams?: Promise<{ success?: string; error?: string }> }) {
  const qp = searchParams ? await searchParams : {};
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

  const [{ data: candidates, error: candidatesError }, { data: movements, error: movementsError }, { data: profiles }] = await Promise.all([
    (supabase as any).rpc("shipper_groupage_candidate_batches_v1"),
    (supabase as any).rpc("shipper_groupage_movements_v1"),
    supabase
      .from("tenant_export_evidence_profiles")
      .select("id, profile_name, exporter_name, default_movement_consignee_name, active")
      .or(`shipper_id.is.null,shipper_id.eq.${(shipperUser as any).shipper_id}`)
      .eq("active", true)
      .order("updated_at", { ascending: false }),
  ]);

  const candidateRows = ((candidates ?? []) as CandidateBatch[]);
  const movementRows = ((movements ?? []) as MovementRow[]);
  const profileRows = ((profiles ?? []) as ExportProfile[]);
  const availableCandidates = candidateRows.filter((row) => !row.existing_groupage_movement_id && !hasSubmittedOrAcceptedEvidence(row));
  const alreadyGroupedCount = candidateRows.filter((row) => row.existing_groupage_movement_id).length;
  const alreadyEvidencedCount = candidateRows.filter((row) => !row.existing_groupage_movement_id && hasSubmittedOrAcceptedEvidence(row)).length;
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
          <h1 className="mt-2 text-2xl font-semibold tracking-tight sm:text-3xl">Groupage Movements</h1>
          <p className="mt-2 text-sm text-slate-600">{(shipperUser as any).full_name} · {shipper?.name ?? "Shipper"}</p>
          <p className="mt-3 max-w-4xl text-sm leading-6 text-slate-600">Group existing shipment batches under one shared movement/container reference. The movement page applies shared export facts back to each included batch so existing evidence, POD and status controls continue to work.</p>
          {qp.success ? <p className="mt-4 rounded-xl border border-emerald-300 bg-emerald-50 px-3 py-2 text-sm text-emerald-900">{qp.success}</p> : null}
          {qp.error ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">{qp.error}</p> : null}
          {candidatesError ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">Groupage candidate list unavailable: {candidatesError.message}. Apply the latest Supabase migration before testing this page.</p> : null}
          {movementsError ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">Groupage movements unavailable: {movementsError.message}</p> : null}
        </section>

        <section className="grid gap-4 md:grid-cols-5">
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Movements</p><p className="mt-1 text-2xl font-semibold">{movementRows.length}</p></div>
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Available batches</p><p className="mt-1 text-2xl font-semibold">{availableCandidates.length}</p></div>
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Grouped batches</p><p className="mt-1 text-2xl font-semibold">{alreadyGroupedCount}</p></div>
          <div className="rounded-3xl border border-amber-200 bg-amber-50 p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-amber-700">Already evidenced</p><p className="mt-1 text-2xl font-semibold text-amber-950">{alreadyEvidencedCount}</p></div>
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Export profiles</p><p className="mt-1 text-2xl font-semibold">{profileRows.length}</p></div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <h2 className="text-xl font-semibold">Create Groupage Movement</h2>
          <p className="mt-2 text-sm leading-6 text-slate-600">Select real existing booking references. Batches already grouped, or with submitted/accepted final export or POD evidence, are excluded from normal groupage selection to prevent duplicate evidence rows.</p>
          <form action={createGroupageMovementAction} className="mt-5 space-y-4">
            <div className="grid gap-3 md:grid-cols-2">
              <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-slate-500">Groupage movement ref</span><input name="groupage_movement_ref" required placeholder="e.g. GM-20260619-001 / container movement ref" className="w-full rounded-xl border border-slate-300 px-3 py-2" /></label>
              <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-slate-500">Export evidence profile</span><select name="profile_id" className="w-full rounded-xl border border-slate-300 bg-white px-3 py-2"><option value="">Use latest available profile / leave blank</option>{profileRows.map((profile) => <option key={profile.id} value={profile.id}>{profile.profile_name ?? profile.exporter_name ?? profile.id}</option>)}</select></label>
            </div>
            {availableCandidates.length === 0 ? <p className="rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-700">No clean ungrouped candidate batches are currently available. Batches with submitted or accepted export/POD evidence are intentionally excluded.</p> : (
              <div className="overflow-x-auto rounded-2xl border border-slate-200">
                <table className="min-w-full divide-y divide-slate-200 text-sm">
                  <thead className="bg-slate-100 text-xs uppercase tracking-wide text-slate-500"><tr><th className="px-3 py-2 text-left">Select</th><th className="px-3 py-2 text-left">Booking ref</th><th className="px-3 py-2 text-left">Importer / recipient</th><th className="px-3 py-2 text-right">Packages / qty</th><th className="px-3 py-2 text-right">Value</th><th className="px-3 py-2 text-left">Evidence</th></tr></thead>
                  <tbody className="divide-y divide-slate-100 bg-white">
                    {availableCandidates.map((row) => (
                      <tr key={row.shipment_batch_id}>
                        <td className="px-3 py-2"><input type="checkbox" name="shipment_batch_ids" value={row.shipment_batch_id} /></td>
                        <td className="px-3 py-2 font-semibold">{row.booking_ref ?? row.shipment_batch_id}</td>
                        <td className="px-3 py-2"><p className="font-semibold">{row.importer_name ?? "Importer"}</p><p className="text-xs text-slate-500">Recipient: {row.final_recipient_name ?? "Not set"}</p>{row.final_recipient_address ? <p className="text-xs text-slate-500">{row.final_recipient_address}</p> : <p className="text-xs font-semibold text-amber-700">Recipient address profile missing</p>}</td>
                        <td className="px-3 py-2 text-right"><p className="font-semibold">{n(row.package_count)} pkg</p><p className="text-xs text-slate-500">Qty {qty(row.item_qty)}</p></td>
                        <td className="px-3 py-2 text-right font-semibold">{money(row.invoice_value_gbp)}</td>
                        <td className="px-3 py-2"><span className={`inline-block rounded-full px-2 py-1 text-xs font-semibold ${statusClass(row.export_evidence_status)}`}>Export: {friendly(row.export_evidence_status)}</span><span className={`mt-1 block w-fit rounded-full px-2 py-1 text-xs font-semibold ${statusClass(row.pod_status)}`}>POD: {friendly(row.pod_status)}</span></td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
            <button type="submit" className="rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800">Create Groupage Movement</button>
          </form>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <h2 className="text-xl font-semibold">Existing Groupage Movements</h2>
          {movementRows.length === 0 ? <p className="mt-4 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-700">No Groupage Movements have been created yet.</p> : (
            <div className="mt-4 overflow-x-auto rounded-2xl border border-slate-200">
              <table className="min-w-full divide-y divide-slate-200 text-sm">
                <thead className="bg-slate-100 text-xs uppercase tracking-wide text-slate-500"><tr><th className="px-3 py-2 text-left">Movement</th><th className="px-3 py-2 text-left">Status</th><th className="px-3 py-2 text-right">Batches</th><th className="px-3 py-2 text-right">Evidence</th><th className="px-3 py-2 text-left">Updated</th><th className="px-3 py-2 text-left">Action</th></tr></thead>
                <tbody className="divide-y divide-slate-100 bg-white">
                  {movementRows.map((row) => (
                    <tr key={row.groupage_movement_id}>
                      <td className="px-3 py-2 font-semibold">{row.groupage_movement_ref ?? row.groupage_movement_id}</td>
                      <td className="px-3 py-2"><span className={`rounded-full px-2 py-1 text-xs font-semibold ${statusClass(row.status)}`}>{friendly(row.status)}</span></td>
                      <td className="px-3 py-2 text-right">{n(row.batch_count)}</td>
                      <td className="px-3 py-2 text-right"><p>{n(row.signed_export_pack_count)} pack upload(s)</p><p className="text-xs text-slate-500">{n(row.pod_document_count)} POD upload(s)</p></td>
                      <td className="px-3 py-2">{shortDate(row.updated_at ?? row.created_at)}</td>
                      <td className="px-3 py-2"><Link href={`/shipper/groupage-movements/${row.groupage_movement_id}`} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-xs font-semibold text-slate-800 hover:bg-slate-50">Open movement</Link></td>
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
