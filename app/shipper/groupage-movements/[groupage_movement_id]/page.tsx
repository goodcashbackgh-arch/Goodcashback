import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { submitGroupageSignedExportPackAction } from "../../shipments/actions";
import {
  cancelGroupageMovementAction,
  excludeGroupageBatchesAction,
  refreshGroupageMovementSnapshotsAction,
  saveGroupageMovementFactsAction,
} from "./actions";
import GroupageSelectionControls from "../GroupageSelectionControls";

type DetailRow = {
  groupage_movement_id: string;
  groupage_movement_ref: string | null;
  groupage_status: string | null;
  shipper_name: string | null;
  mbl_bol_sea_waybill_ref: string | null;
  container_number: string | null;
  seal_number: string | null;
  vessel_voyage: string | null;
  port_of_loading: string | null;
  port_of_discharge: string | null;
  place_of_delivery: string | null;
  export_shipment_date: string | null;
  weight_text: string | null;
  exporter_name_snapshot: string | null;
  exporter_address_snapshot: string | null;
  exporter_vat_number_snapshot: string | null;
  movement_consignee_name_snapshot: string | null;
  movement_consignee_address_snapshot: string | null;
  notify_party_name_snapshot: string | null;
  notify_party_address_snapshot: string | null;
  authorised_name: string | null;
  signature_stamp_confirmation_yn: boolean | null;
  shipment_batch_id: string;
  booking_ref: string | null;
  importer_name: string | null;
  final_recipient_name: string | null;
  final_recipient_address: string | null;
  package_count: number | string | null;
  item_qty: number | string | null;
  invoice_value_gbp: number | string | null;
  export_evidence_status: string | null;
  pod_status: string | null;
};

function n(value: number | string | null | undefined) {
  const parsed = Number(value ?? 0);
  return Number.isFinite(parsed) ? parsed : 0;
}

function money(value: number | string | null | undefined) {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" }).format(n(value));
}

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

function movementLabel(value: string | null | undefined) {
  if (value === "pod_part_submitted") return "POD partly submitted";
  if (value === "pod_part_accepted") return "POD partly accepted";
  if (value === "pod_fully_accepted") return "POD accepted";
  if (value === "signed_export_pack_fully_accepted") return "Export pack accepted";
  if (value === "complete") return "Complete";
  if (value === "signed_export_pack_submitted") return "Signed pack submitted";
  return friendly(value);
}

function podIsClosed(value: string | null | undefined) {
  return value === "submitted_for_review" || value === "accepted_current";
}

function pillClass(status: string | null | undefined) {
  if (["complete", "movement_facts_ready", "accepted_current", "pod_fully_accepted", "signed_export_pack_fully_accepted"].includes(status ?? "")) return "bg-emerald-100 text-emerald-800";
  if (["voided", "rejected_resubmit_required"].includes(status ?? "")) return "bg-rose-100 text-rose-800";
  return "bg-amber-100 text-amber-800";
}

function borderPillClass(status: string | null | undefined) {
  if (status === "accepted_current") return "border-emerald-300 bg-emerald-50 text-emerald-900";
  if (status === "submitted_for_review") return "border-amber-300 bg-amber-50 text-amber-900";
  if (status === "rejected_resubmit_required") return "border-rose-300 bg-rose-50 text-rose-900";
  return "border-slate-200 bg-white text-slate-700";
}

function field(label: string, value: string | null | undefined) {
  return (
    <div className="rounded-2xl border border-slate-200 bg-slate-50 p-3">
      <p className="text-xs uppercase tracking-wide text-slate-500">{label}</p>
      <p className="mt-1 whitespace-pre-wrap font-semibold">{value || "Not entered"}</p>
    </div>
  );
}

function inputField(label: string, name: string, value: string | null | undefined, type = "text") {
  return (
    <label className="space-y-1 text-sm">
      <span className="text-xs font-semibold uppercase tracking-wide text-amber-800">{label}</span>
      <input name={name} type={type} defaultValue={value ?? ""} className="w-full rounded-xl border border-amber-300 bg-white px-3 py-2 text-slate-950" />
    </label>
  );
}

function textAreaField(label: string, name: string, value: string | null | undefined) {
  return (
    <label className="space-y-1 text-sm md:col-span-2">
      <span className="text-xs font-semibold uppercase tracking-wide text-amber-800">{label}</span>
      <textarea name={name} defaultValue={value ?? ""} rows={3} className="w-full rounded-xl border border-amber-300 bg-white px-3 py-2 text-slate-950" />
    </label>
  );
}

function FloatingDownloadControls({ groupageMovementId }: { groupageMovementId: string }) {
  return (
    <div className="fixed inset-x-4 bottom-4 z-40 mx-auto max-w-5xl rounded-3xl border border-indigo-200 bg-white/95 p-4 shadow-xl backdrop-blur">
      <div className="grid gap-3 sm:grid-cols-2">
        <Link href={`/shipper/groupage-movements/${groupageMovementId}/export-pack`} target="_blank" className="rounded-xl border border-indigo-300 bg-indigo-50 px-4 py-3 text-center text-sm font-semibold text-indigo-900 hover:bg-indigo-100">Download combined export pack</Link>
        <Link href={`/shipper/groupage-movements/${groupageMovementId}/sales-invoices-zip`} className="rounded-xl border border-sky-300 bg-sky-50 px-4 py-3 text-center text-sm font-semibold text-sky-900 hover:bg-sky-100">Download supporting shipment documents ZIP</Link>
      </div>
      <p className="mt-3 text-sm text-slate-600">Download the groupage pack and supporting shipment documents without leaving this movement.</p>
    </div>
  );
}

export default async function ShipperGroupageMovementDetailPage({
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

  const { data: shipperUser } = await supabase
    .from("shipper_users")
    .select("id, full_name, shipper_id, shippers(name)")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();
  if (!shipperUser) redirect("/auth/check");

  const { data, error } = await (supabase as any).rpc("shipper_groupage_movement_detail_v1", { p_groupage_movement_id: groupageMovementId });
  const rows = (data ?? []) as DetailRow[];
  const first = rows[0] ?? null;

  if (!first && !error) {
    const { data: movement } = await supabase
      .from("shipper_groupage_movements")
      .select("groupage_movement_ref, status")
      .eq("id", groupageMovementId)
      .maybeSingle();
    const ref = (movement as any)?.groupage_movement_ref ?? groupageMovementId;
    if ((movement as any)?.status === "voided") redirect(`/shipper/groupage-movements?success=${encodeURIComponent(`Groupage Movement ${ref} cancelled/released.`)}`);
    redirect("/shipper/groupage-movements");
  }

  const totalPackages = rows.reduce((sum, row) => sum + n(row.package_count), 0);
  const totalQty = rows.reduce((sum, row) => sum + n(row.item_qty), 0);
  const totalValue = rows.reduce((sum, row) => sum + n(row.invoice_value_gbp), 0);
  const validGroupageSize = rows.length >= 2;
  const allExportAccepted = validGroupageSize && rows.every((row) => row.export_evidence_status === "accepted_current");
  const allPodAccepted = validGroupageSize && rows.every((row) => row.pod_status === "accepted_current");
  const movementComplete = first?.groupage_status === "complete" || (allExportAccepted && allPodAccepted);
  const movementFactsReady = movementComplete || Boolean(
    first?.exporter_name_snapshot && first?.exporter_address_snapshot && first?.exporter_vat_number_snapshot &&
    first?.movement_consignee_name_snapshot && first?.movement_consignee_address_snapshot &&
    first?.mbl_bol_sea_waybill_ref && first?.container_number && first?.seal_number && first?.vessel_voyage &&
    first?.port_of_loading && first?.port_of_discharge && first?.place_of_delivery && first?.export_shipment_date
  );
  const blockers = [
    first && !first.exporter_name_snapshot ? "Exporter profile missing from admin/onboarding source data" : null,
    first && !first.movement_consignee_name_snapshot ? "Movement consignee missing from admin/onboarding source data" : null,
    rows.some((row) => !row.final_recipient_address) ? "One or more final recipient addresses are missing from importer/customer onboarding" : null,
    rows.length < 2 ? "A Groupage Movement requires at least two active booking refs" : null,
  ].filter(Boolean) as string[];
  const editable = !movementComplete && ["draft", "movement_facts_incomplete", "movement_facts_ready"].includes(first?.groupage_status ?? "");
  const signedPackSubmitted = ["signed_export_pack_submitted", "pod_part_submitted", "pod_part_accepted", "pod_fully_accepted", "complete"].includes(first?.groupage_status ?? "");
  const podOpenRows = rows.filter((row) => !podIsClosed(row.pod_status));
  const podSubmittedCount = rows.filter((row) => row.pod_status === "submitted_for_review").length;
  const podAcceptedCount = rows.filter((row) => row.pod_status === "accepted_current").length;
  const podUploadAllowed = !movementComplete && validGroupageSize && podOpenRows.length > 0;
  const showSuccess = Boolean(qp.success) && !movementComplete;
  const shipper = Array.isArray((shipperUser as any).shippers) ? (shipperUser as any).shippers[0] : (shipperUser as any).shippers;

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-7xl space-y-6 pb-40">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-wrap gap-3 text-sm font-semibold text-sky-700">
            <Link href="/shipper/groupage-movements">← Groupage Movements</Link>
            <Link href="/shipper/shipments">Shipment batches</Link>
          </div>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Goodcashback Shipper</p>
          <div className="mt-2 flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
            <div>
              <h1 className="text-2xl font-semibold tracking-tight sm:text-3xl">Groupage Movement {first?.groupage_movement_ref ?? groupageMovementId}</h1>
              <p className="mt-2 text-sm text-slate-600">{(shipperUser as any).full_name} · {first?.shipper_name ?? shipper?.name ?? "Shipper"}</p>
              <p className="mt-3 max-w-4xl text-sm leading-6 text-slate-600">Groupage uses source data from admin/onboarding records, snapshots it into the movement, and writes uploads back to existing batch evidence controls.</p>
            </div>
            <span className={`w-fit rounded-full px-3 py-1 text-sm font-semibold ${pillClass(movementComplete ? "complete" : first?.groupage_status)}`}>{movementComplete ? "Complete" : movementLabel(first?.groupage_status)}</span>
          </div>
          {movementComplete ? <p className="mt-4 rounded-xl border border-emerald-300 bg-emerald-50 px-3 py-2 text-sm font-semibold text-emerald-900">Groupage Movement complete: export pack and POD are accepted for all included booking refs.</p> : null}
          {showSuccess ? <p className="mt-4 rounded-xl border border-emerald-300 bg-emerald-50 px-3 py-2 text-sm font-semibold text-emerald-900">{qp.success}</p> : null}
          {qp.error ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">{qp.error}</p> : null}
          {error ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">{error.message}</p> : null}
        </section>

        {first ? <>
          <section className="grid gap-4 md:grid-cols-6">
            <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Booking refs</p><p className="mt-1 text-2xl font-semibold">{rows.length}</p></div>
            <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Packages</p><p className="mt-1 text-2xl font-semibold">{totalPackages}</p></div>
            <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Qty</p><p className="mt-1 text-2xl font-semibold">{totalQty}</p></div>
            <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Invoice value</p><p className="mt-1 text-2xl font-semibold">{money(totalValue)}</p></div>
            <div className="rounded-3xl border border-amber-200 bg-amber-50 p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-amber-700">POD awaiting review</p><p className="mt-1 text-2xl font-semibold text-amber-950">{podSubmittedCount}</p></div>
            <div className="rounded-3xl border border-emerald-200 bg-emerald-50 p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-emerald-700">POD accepted</p><p className="mt-1 text-2xl font-semibold text-emerald-950">{podAcceptedCount}</p></div>
          </section>

          {blockers.length > 0 && !movementComplete ? <section className="rounded-3xl border border-amber-300 bg-amber-50 p-5 text-sm leading-6 text-amber-900 shadow-sm"><h2 className="text-lg font-semibold text-amber-950">Profile/data blockers before strong export pack</h2><ul className="mt-2 list-disc space-y-1 pl-5">{blockers.map((blocker) => <li key={blocker}>{blocker}</li>)}</ul><div className="mt-4 rounded-2xl border border-amber-300 bg-white p-4 text-sm text-amber-950">Complete the missing source records in admin/onboarding. The shipper workspace does not maintain exporter, movement consignee, or importer/customer delivery source records.</div><form action={refreshGroupageMovementSnapshotsAction} className="mt-4"><input type="hidden" name="groupage_movement_id" value={groupageMovementId} /><button type="submit" className="rounded-xl bg-amber-900 px-4 py-2 text-sm font-semibold text-white hover:bg-amber-800">Refresh movement from source profiles</button></form></section> : null}

          {editable ? <section className="rounded-3xl border border-rose-200 bg-rose-50 p-5 shadow-sm sm:p-6"><h2 className="text-xl font-semibold text-rose-950">Reset / exclude booking refs</h2><p className="mt-2 text-sm leading-6 text-rose-900">If excluding selected refs leaves fewer than two active booking refs, the system cancels the movement and releases the remaining batch.</p><form action={excludeGroupageBatchesAction} className="mt-4 space-y-3"><input type="hidden" name="groupage_movement_id" value={groupageMovementId} /><GroupageSelectionControls fieldName="exclude_shipment_batch_ids" label="Included booking refs" /><div className="rounded-2xl border border-rose-200 bg-white p-3"><div className="mt-2 grid gap-2 md:grid-cols-2">{rows.map((row) => <label key={row.shipment_batch_id} className="flex items-center gap-2 text-sm"><input type="checkbox" name="exclude_shipment_batch_ids" value={row.shipment_batch_id} /> <span className="font-semibold">{row.booking_ref ?? row.shipment_batch_id}</span><span className="text-slate-500">{row.importer_name ?? "Importer"}</span></label>)}</div></div><button type="submit" className="rounded-xl border border-rose-300 bg-white px-4 py-2 text-sm font-semibold text-rose-900 hover:bg-rose-100">Exclude selected booking refs</button></form><form action={cancelGroupageMovementAction} className="mt-3"><input type="hidden" name="groupage_movement_id" value={groupageMovementId} /><button type="submit" className="rounded-xl bg-rose-900 px-4 py-2 text-sm font-semibold text-white hover:bg-rose-800">Cancel whole Groupage Movement</button></form></section> : null}

          <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
            <div className="flex flex-col gap-2 md:flex-row md:items-start md:justify-between"><div><h2 className="text-xl font-semibold">Movement facts</h2><p className="mt-2 text-sm leading-6 text-slate-600">Source profile facts are snapshotted from admin/onboarding. Transport facts below are entered for this movement and applied to included batches.</p></div><span className={`w-fit rounded-full px-3 py-1 text-sm font-semibold ${movementFactsReady ? "bg-emerald-100 text-emerald-800" : "bg-amber-100 text-amber-800"}`}>{movementFactsReady ? "Facts ready" : "Facts incomplete"}</span></div>
            <div className="mt-4 grid gap-3 md:grid-cols-3">{field("Exporter", first.exporter_name_snapshot)}{field("Exporter address", first.exporter_address_snapshot)}{field("Exporter VAT", first.exporter_vat_number_snapshot)}{field("Movement consignee", first.movement_consignee_name_snapshot)}{field("Consignee address", first.movement_consignee_address_snapshot)}{field("Notify party", first.notify_party_name_snapshot)}{field("Notify party address", first.notify_party_address_snapshot)}{field("Weight text", first.weight_text || "Not separately recorded by issuing consolidator")}</div>
            {editable ? <details className="mt-5 rounded-2xl border border-amber-200 bg-amber-50 p-4" open={!movementFactsReady}><summary className="cursor-pointer text-sm font-semibold text-amber-950">Enter / update final shipment fields for this Groupage Movement</summary><form action={saveGroupageMovementFactsAction} className="mt-4 grid gap-3 md:grid-cols-2"><input type="hidden" name="groupage_movement_id" value={groupageMovementId} /><p className="text-sm leading-6 text-amber-900 md:col-span-2">These values are saved once at Groupage Movement level and applied to all included booking refs using the same batch export-evidence completion lane.</p>{inputField("MBL / BOL / sea waybill", "mbl_bol_sea_waybill_ref", first.mbl_bol_sea_waybill_ref)}{inputField("Container number", "container_number", first.container_number)}{inputField("Seal number", "seal_number", first.seal_number)}{inputField("Vessel / voyage", "vessel_voyage", first.vessel_voyage)}{inputField("Port of loading", "port_of_loading", first.port_of_loading)}{inputField("Port of discharge", "port_of_discharge", first.port_of_discharge)}{inputField("Place of delivery", "place_of_delivery", first.place_of_delivery)}{inputField("Export / shipment date", "export_shipment_date", first.export_shipment_date, "date")}{inputField("Weight text", "weight_text", first.weight_text)}{inputField("Authorised name", "authorised_name", first.authorised_name ?? (shipperUser as any).full_name ?? "")}<label className="flex items-center gap-3 rounded-xl border border-amber-300 bg-white px-3 py-2 text-sm text-slate-950"><input name="signature_stamp_confirmation_yn" type="checkbox" defaultChecked={Boolean(first.signature_stamp_confirmation_yn)} /> I confirm the final export pack will be signed/stamped/authenticated by the shipper.</label><div className="rounded-xl border border-amber-300 bg-white px-3 py-2 text-xs leading-5 text-amber-900">Exporter, consignee and recipient source records are maintained in internal onboarding. Use the optional overrides below only where the movement document needs a one-off label change.</div>{textAreaField("Movement consignee override, optional", "movement_consignee_name", first.movement_consignee_name_snapshot)}{textAreaField("Movement consignee address override, optional", "movement_consignee_address", first.movement_consignee_address_snapshot)}{inputField("Notify party override, optional", "notify_party_name", first.notify_party_name_snapshot)}{textAreaField("Notify party address override, optional", "notify_party_address", first.notify_party_address_snapshot)}<div className="md:col-span-2"><button type="submit" className="rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800">Save movement facts</button></div></form></details> : null}
          </section>

          <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6"><div className="flex flex-col gap-3 md:flex-row md:items-start md:justify-between"><div><h2 className="text-xl font-semibold">Included booking refs</h2><p className="mt-2 text-sm leading-6 text-slate-600">Batch status remains the canonical truth.</p></div></div><div className="mt-4 overflow-x-auto rounded-2xl border border-slate-200"><table className="min-w-full divide-y divide-slate-200 text-sm"><thead className="bg-slate-100 text-xs uppercase tracking-wide text-slate-500"><tr><th className="px-3 py-2 text-left">Booking ref</th><th className="px-3 py-2 text-left">Importer / recipient</th><th className="px-3 py-2 text-right">Packages / qty</th><th className="px-3 py-2 text-right">Value</th><th className="px-3 py-2 text-left">Evidence</th><th className="px-3 py-2 text-left">Action</th></tr></thead><tbody className="divide-y divide-slate-100 bg-white">{rows.map((row) => <tr key={row.shipment_batch_id}><td className="px-3 py-2 font-semibold">{row.booking_ref ?? row.shipment_batch_id}</td><td className="px-3 py-2"><p className="font-semibold">{row.importer_name ?? "Importer"}</p><p className="text-xs text-slate-500">Recipient: {row.final_recipient_name ?? "Not set"}</p>{row.final_recipient_address ? <p className="text-xs text-slate-500">{row.final_recipient_address}</p> : <p className="text-xs font-semibold text-amber-700">Recipient address missing</p>}</td><td className="px-3 py-2 text-right"><p className="font-semibold">{n(row.package_count)} pkg</p><p className="text-xs text-slate-500">Qty {n(row.item_qty)}</p></td><td className="px-3 py-2 text-right font-semibold">{money(row.invoice_value_gbp)}</td><td className="px-3 py-2"><span className={`inline-block rounded-full border px-2 py-1 text-xs font-semibold ${borderPillClass(row.export_evidence_status)}`}>Export: {evidenceLabel(row.export_evidence_status)}</span><span className={`mt-1 block w-fit rounded-full border px-2 py-1 text-xs font-semibold ${borderPillClass(row.pod_status)}`}>POD: {evidenceLabel(row.pod_status)}</span></td><td className="px-3 py-2"><Link href={`/shipper/shipments/${row.shipment_batch_id}`} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-xs font-semibold text-slate-800 hover:bg-slate-50">Open batch</Link></td></tr>)}</tbody></table></div></section>

          {!movementComplete ? <section className="grid gap-4 lg:grid-cols-2"><article className="rounded-3xl border border-amber-200 bg-amber-50 p-5 shadow-sm sm:p-6"><h2 className="text-xl font-semibold text-amber-950">Signed export pack</h2><p className="mt-2 text-sm leading-6 text-amber-900">The signed/stamped Groupage Export Pack applies to all active included booking refs. It should not be re-uploaded unless supervisor/admin rejects it.</p>{allExportAccepted ? <div className="mt-5 rounded-2xl border border-emerald-300 bg-white p-4 text-sm font-semibold text-emerald-950">Signed export pack accepted. No re-upload required.</div> : signedPackSubmitted ? <div className="mt-5 rounded-2xl border border-amber-300 bg-white p-4 text-sm font-semibold text-amber-950">Already submitted. Await supervisor/admin review or resubmission instruction.</div> : <form action={submitGroupageSignedExportPackAction} encType="multipart/form-data" className="mt-5 grid gap-3"><input type="hidden" name="groupage_movement_id" value={groupageMovementId} /><label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-amber-800">Document ref</span><input name="document_ref" defaultValue={first.groupage_movement_ref ?? ""} className="w-full rounded-xl border border-amber-300 bg-white px-3 py-2" /></label><label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-amber-800">Signed export pack file</span><input name="groupage_export_pack_file" type="file" required className="w-full rounded-xl border border-amber-300 bg-white px-3 py-2" /></label><button type="submit" disabled={!validGroupageSize} className="rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800 disabled:cursor-not-allowed disabled:bg-slate-400">Upload and apply to all included batches</button></form>}</article><article className="rounded-3xl border border-sky-200 bg-sky-50 p-5 shadow-sm sm:p-6"><h2 className="text-xl font-semibold text-sky-950">POD / delivery evidence</h2><p className="mt-2 text-sm leading-6 text-sky-900">Select only open booking refs covered by the POD file. Submitted or accepted POD refs are locked.</p><form action={`/shipper/groupage-movements/${groupageMovementId}/pod-upload`} method="post" encType="multipart/form-data" className="mt-5 grid gap-3"><input type="hidden" name="groupage_movement_id" value={groupageMovementId} /><GroupageSelectionControls fieldName="pod_shipment_batch_ids" label="Open POD booking refs" /><div className="grid gap-3">{rows.map((row) => { const closed = podIsClosed(row.pod_status); const rejected = row.pod_status === "rejected_resubmit_required"; return <label key={row.shipment_batch_id} className={`flex items-start gap-3 rounded-2xl border p-4 text-sm shadow-sm ${closed ? "border-slate-200 bg-slate-50 opacity-80" : rejected ? "border-rose-300 bg-rose-50" : "border-sky-300 bg-white"}`}><input type="checkbox" name="pod_shipment_batch_ids" value={row.shipment_batch_id} disabled={!podUploadAllowed || closed} className="mt-1 h-5 w-5" /><span className="min-w-0 flex-1"><span className="block font-semibold text-slate-950">{row.booking_ref ?? row.shipment_batch_id}</span><span className="block text-slate-500">{row.importer_name ?? "Importer"}</span><span className={`mt-2 inline-block rounded-full border px-2 py-1 text-xs font-semibold ${borderPillClass(row.pod_status)}`}>POD: {evidenceLabel(row.pod_status)}</span><span className={`ml-2 mt-2 inline-block rounded-full border px-2 py-1 text-xs font-semibold ${borderPillClass(row.export_evidence_status)}`}>Export: {evidenceLabel(row.export_evidence_status)}</span></span></label>; })}</div>{!podUploadAllowed ? <div className="rounded-2xl border border-emerald-300 bg-white p-4 text-sm font-semibold text-emerald-900">No open booking refs require POD upload from this page.</div> : null}<label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-sky-800">POD ref</span><input name="pod_document_ref" defaultValue={first.groupage_movement_ref ?? ""} disabled={!podUploadAllowed} className="w-full rounded-xl border border-sky-300 bg-white px-3 py-2 disabled:bg-slate-100" /></label><label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-sky-800">POD file</span><input name="groupage_pod_file" type="file" required disabled={!podUploadAllowed} className="w-full rounded-xl border border-sky-300 bg-white px-3 py-2 disabled:bg-slate-100" /></label><button type="submit" disabled={!podUploadAllowed} className="rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800 disabled:cursor-not-allowed disabled:bg-slate-400">Upload POD for selected open booking refs</button></form></article></section> : <section className="rounded-3xl border border-emerald-300 bg-emerald-50 p-5 shadow-sm sm:p-6"><h2 className="text-xl font-semibold text-emerald-950">Evidence complete</h2><p className="mt-2 text-sm leading-6 text-emerald-900">Signed groupage export pack and POD are accepted for every active included booking ref. No further shipper upload action is required.</p></section>}
        </> : null}
      </div>
      <FloatingDownloadControls groupageMovementId={groupageMovementId} />
    </main>
  );
}
