import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { saveGroupageMovementFactsAction, submitGroupagePodAction, submitGroupageSignedExportPackAction } from "../../shipments/actions";
import { cancelGroupageMovementAction, excludeGroupageBatchesAction, refreshGroupageMovementSnapshotsAction } from "./actions";
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
  box_count: number | string | null;
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

function qty(value: number | string | null | undefined) {
  const parsed = n(value);
  return parsed % 1 === 0 ? String(Math.trunc(parsed)) : parsed.toFixed(3).replace(/0+$/, "").replace(/\.$/, "");
}

function dateValue(value: string | null | undefined) {
  if (!value) return "";
  return value.includes("T") ? value.slice(0, 10) : value;
}

function friendly(value: string | null | undefined) {
  if (!value) return "—";
  return value.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase());
}

function statusClass(status: string | null | undefined) {
  if (["complete", "movement_facts_ready", "accepted_current", "pod_fully_accepted", "signed_export_pack_fully_accepted", "shipment_controls_complete"].includes(status ?? "")) return "bg-emerald-100 text-emerald-800";
  if (["voided", "rejected_resubmit_required"].includes(status ?? "")) return "bg-rose-100 text-rose-800";
  return "bg-amber-100 text-amber-800";
}

function field(label: string, value: string | null | undefined) {
  return <div className="rounded-2xl border border-slate-200 bg-slate-50 p-3"><p className="text-xs uppercase tracking-wide text-slate-500">{label}</p><p className="mt-1 whitespace-pre-wrap font-semibold">{value || "Not entered"}</p></div>;
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

  const { data, error } = await (supabase as any).rpc("shipper_groupage_movement_detail_v1", {
    p_groupage_movement_id: groupageMovementId,
  });

  const rows = (data ?? []) as DetailRow[];
  const first = rows[0] ?? null;
  const totalPackages = rows.reduce((sum, row) => sum + n(row.package_count), 0);
  const totalQty = rows.reduce((sum, row) => sum + n(row.item_qty), 0);
  const totalValue = rows.reduce((sum, row) => sum + n(row.invoice_value_gbp), 0);

  if (!first && !error) {
    const { data: movement } = await supabase
      .from("shipper_groupage_movements")
      .select("groupage_movement_ref, status")
      .eq("id", groupageMovementId)
      .maybeSingle();
    const ref = (movement as any)?.groupage_movement_ref ?? groupageMovementId;
    if ((movement as any)?.status === "voided") {
      redirect(`/shipper/groupage-movements?success=${encodeURIComponent(`Groupage Movement ${ref} cancelled/released.`)}`);
    }
    redirect("/shipper/groupage-movements");
  }

  const profileBlockers = [
    first && !first.exporter_name_snapshot ? "Exporter profile missing" : null,
    first && !first.movement_consignee_name_snapshot ? "Movement consignee missing" : null,
    rows.some((row) => !row.final_recipient_address) ? "One or more final recipient addresses are missing" : null,
    rows.length < 2 ? "A Groupage Movement requires at least two active booking refs" : null,
  ].filter(Boolean) as string[];

  const editable = ["draft", "movement_facts_incomplete", "movement_facts_ready"].includes(first?.groupage_status ?? "");
  const validGroupageSize = rows.length >= 2;

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-7xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-wrap gap-3 text-sm font-semibold text-sky-700">
            <Link href="/shipper/groupage-movements">← Groupage Movements</Link>
            <Link href="/shipper/shipments">Shipment batches</Link>
          </div>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Goodcashback Shipper</p>
          <div className="mt-2 flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
            <div>
              <h1 className="text-2xl font-semibold tracking-tight sm:text-3xl">Groupage Movement {first?.groupage_movement_ref ?? groupageMovementId}</h1>
              <p className="mt-2 text-sm text-slate-600">{(shipperUser as any).full_name} · {first?.shipper_name ?? "Shipper"}</p>
              <p className="mt-3 max-w-4xl text-sm leading-6 text-slate-600">Enter shared movement facts once, download the combined export pack, upload the signed pack once, and upload POD by selecting the booking refs covered. Each action writes back to the existing batch-level evidence tables.</p>
            </div>
            <span className={`w-fit rounded-full px-3 py-1 text-sm font-semibold ${statusClass(first?.groupage_status)}`}>{friendly(first?.groupage_status)}</span>
          </div>
          {qp.success ? <p className="mt-4 rounded-xl border border-emerald-300 bg-emerald-50 px-3 py-2 text-sm text-emerald-900">{qp.success}</p> : null}
          {qp.error ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">{qp.error}</p> : null}
          {error ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">{error.message}</p> : null}
        </section>

        {first ? (
          <>
            <section className="grid gap-4 md:grid-cols-4">
              <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Booking refs</p><p className="mt-1 text-2xl font-semibold">{rows.length}</p></div>
              <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Packages</p><p className="mt-1 text-2xl font-semibold">{totalPackages}</p></div>
              <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Qty</p><p className="mt-1 text-2xl font-semibold">{qty(totalQty)}</p></div>
              <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Invoice value</p><p className="mt-1 text-2xl font-semibold">{money(totalValue)}</p></div>
            </section>

            {profileBlockers.length > 0 ? (
              <section className="rounded-3xl border border-amber-300 bg-amber-50 p-5 text-sm leading-6 text-amber-900 shadow-sm">
                <h2 className="text-lg font-semibold text-amber-950">Profile/data blockers before strong export pack</h2>
                <ul className="mt-2 list-disc space-y-1 pl-5">{profileBlockers.map((blocker) => <li key={blocker}>{blocker}</li>)}</ul>
                <div className="mt-4 flex flex-wrap gap-3">
                  <Link href="/shipper/export-evidence-profile" className="rounded-xl border border-amber-300 bg-white px-4 py-2 text-sm font-semibold text-amber-900 hover:bg-amber-100">Complete export evidence profile</Link>
                  <Link href="/shipper/importer-delivery-profiles" className="rounded-xl border border-amber-300 bg-white px-4 py-2 text-sm font-semibold text-amber-900 hover:bg-amber-100">Complete importer delivery profiles</Link>
                  <form action={refreshGroupageMovementSnapshotsAction}>
                    <input type="hidden" name="groupage_movement_id" value={groupageMovementId} />
                    <button type="submit" className="rounded-xl bg-amber-900 px-4 py-2 text-sm font-semibold text-white hover:bg-amber-800">Refresh movement from profiles</button>
                  </form>
                </div>
                <p className="mt-3 text-xs text-amber-800">These fields are pulled from the source database profile tables and snapshotted into this movement. They are not free-typed into the movement as the primary source.</p>
              </section>
            ) : null}

            {editable ? (
              <section className="rounded-3xl border border-rose-200 bg-rose-50 p-5 shadow-sm sm:p-6">
                <h2 className="text-xl font-semibold text-rose-950">Reset / exclude booking refs</h2>
                <p className="mt-2 text-sm leading-6 text-rose-900">Use this before signed export pack or POD upload. If excluding selected refs leaves fewer than two active booking refs, the system cancels the Groupage Movement and releases the remaining batch.</p>
                <form action={excludeGroupageBatchesAction} className="mt-4 space-y-3">
                  <input type="hidden" name="groupage_movement_id" value={groupageMovementId} />
                  <GroupageSelectionControls fieldName="exclude_shipment_batch_ids" label="Included booking refs" />
                  <div className="rounded-2xl border border-rose-200 bg-white p-3">
                    <p className="text-xs font-semibold uppercase tracking-wide text-rose-800">Select booking refs to exclude</p>
                    <div className="mt-2 grid gap-2 md:grid-cols-2">
                      {rows.map((row) => <label key={row.shipment_batch_id} className="flex items-center gap-2 text-sm"><input type="checkbox" name="exclude_shipment_batch_ids" value={row.shipment_batch_id} /> <span className="font-semibold">{row.booking_ref ?? row.shipment_batch_id}</span><span className="text-slate-500">{row.importer_name ?? "Importer"}</span></label>)}
                    </div>
                  </div>
                  <button type="submit" className="rounded-xl border border-rose-300 bg-white px-4 py-2 text-sm font-semibold text-rose-900 hover:bg-rose-100">Exclude selected booking refs</button>
                </form>
                <form action={cancelGroupageMovementAction} className="mt-3">
                  <input type="hidden" name="groupage_movement_id" value={groupageMovementId} />
                  <button type="submit" className="rounded-xl bg-rose-900 px-4 py-2 text-sm font-semibold text-white hover:bg-rose-800">Cancel whole Groupage Movement</button>
                </form>
              </section>
            ) : null}

            <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
              <h2 className="text-xl font-semibold">Movement facts</h2>
              <p className="mt-2 text-sm leading-6 text-slate-600">These shared facts are applied to each included batch’s existing final shipment/COS completion fields.</p>
              <div className="mt-4 grid gap-3 md:grid-cols-3">
                {field("Exporter", first.exporter_name_snapshot)}
                {field("Exporter address", first.exporter_address_snapshot)}
                {field("Exporter VAT", first.exporter_vat_number_snapshot)}
                {field("Movement consignee", first.movement_consignee_name_snapshot)}
                {field("Consignee address", first.movement_consignee_address_snapshot)}
                {field("Weight text", first.weight_text || "Not separately recorded by issuing consolidator")}
                {field("MBOL / sea waybill", first.mbl_bol_sea_waybill_ref)}
                {field("Container / seal", `${first.container_number ?? "—"} / ${first.seal_number ?? "—"}`)}
                {field("Vessel / voyage", first.vessel_voyage)}
                {field("Port loading", first.port_of_loading)}
                {field("Port discharge", first.port_of_discharge)}
                {field("Place delivery", first.place_of_delivery)}
              </div>
              <details className="mt-5 rounded-2xl border border-slate-200 bg-slate-50 p-4">
                <summary className="cursor-pointer text-sm font-semibold text-slate-900">Edit/apply movement facts to included batches</summary>
                <form action={saveGroupageMovementFactsAction} className="mt-4 grid gap-3 md:grid-cols-2">
                  <input type="hidden" name="groupage_movement_id" value={groupageMovementId} />
                  <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-slate-500">MBL / BOL / sea waybill</span><input name="mbl_bol_sea_waybill_ref" defaultValue={first.mbl_bol_sea_waybill_ref ?? ""} className="w-full rounded-xl border border-slate-300 px-3 py-2" /></label>
                  <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-slate-500">Container number</span><input name="container_number" defaultValue={first.container_number ?? ""} className="w-full rounded-xl border border-slate-300 px-3 py-2" /></label>
                  <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-slate-500">Seal number</span><input name="seal_number" defaultValue={first.seal_number ?? ""} className="w-full rounded-xl border border-slate-300 px-3 py-2" /></label>
                  <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-slate-500">Vessel / voyage</span><input name="vessel_voyage" defaultValue={first.vessel_voyage ?? ""} className="w-full rounded-xl border border-slate-300 px-3 py-2" /></label>
                  <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-slate-500">Port of loading</span><input name="port_of_loading" defaultValue={first.port_of_loading ?? ""} className="w-full rounded-xl border border-slate-300 px-3 py-2" /></label>
                  <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-slate-500">Port of discharge</span><input name="port_of_discharge" defaultValue={first.port_of_discharge ?? ""} className="w-full rounded-xl border border-slate-300 px-3 py-2" /></label>
                  <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-slate-500">Place of delivery</span><input name="place_of_delivery" defaultValue={first.place_of_delivery ?? ""} className="w-full rounded-xl border border-slate-300 px-3 py-2" /></label>
                  <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-slate-500">Export / shipment date</span><input name="export_shipment_date" type="date" defaultValue={dateValue(first.export_shipment_date)} className="w-full rounded-xl border border-slate-300 px-3 py-2" /></label>
                  <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-slate-500">Weight text</span><input name="weight_text" defaultValue={first.weight_text ?? "Not separately recorded by issuing consolidator"} className="w-full rounded-xl border border-slate-300 px-3 py-2" /></label>
                  <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-slate-500">Movement consignee</span><input name="movement_consignee_name" defaultValue={first.movement_consignee_name_snapshot ?? ""} className="w-full rounded-xl border border-slate-300 px-3 py-2" /></label>
                  <label className="space-y-1 text-sm md:col-span-2"><span className="text-xs uppercase tracking-wide text-slate-500">Movement consignee address</span><input name="movement_consignee_address" defaultValue={first.movement_consignee_address_snapshot ?? ""} className="w-full rounded-xl border border-slate-300 px-3 py-2" /></label>
                  <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-slate-500">Notify party</span><input name="notify_party_name" defaultValue={first.notify_party_name_snapshot ?? ""} className="w-full rounded-xl border border-slate-300 px-3 py-2" /></label>
                  <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-slate-500">Notify party address</span><input name="notify_party_address" defaultValue={first.notify_party_address_snapshot ?? ""} className="w-full rounded-xl border border-slate-300 px-3 py-2" /></label>
                  <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-slate-500">Authorised name</span><input name="authorised_name" defaultValue={first.authorised_name ?? (shipperUser as any).full_name ?? ""} className="w-full rounded-xl border border-slate-300 px-3 py-2" /></label>
                  <label className="flex items-center gap-3 rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm"><input name="signature_stamp_confirmation_yn" type="checkbox" defaultChecked={Boolean(first.signature_stamp_confirmation_yn)} /> Signed/stamped pack will be authenticated by the shipper</label>
                  <div className="md:col-span-2"><button type="submit" disabled={!validGroupageSize} className="rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800 disabled:cursor-not-allowed disabled:bg-slate-400">Save and apply to included batches</button></div>
                </form>
              </details>
            </section>

            <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
              <div className="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
                <div><h2 className="text-xl font-semibold">Included booking refs</h2><p className="mt-2 text-sm leading-6 text-slate-600">Open individual batches from here. Batch status remains the canonical truth.</p></div>
                {validGroupageSize ? <Link href={`/shipper/groupage-movements/${groupageMovementId}/export-pack`} target="_blank" className="rounded-xl border border-indigo-300 bg-indigo-50 px-4 py-2 text-sm font-semibold text-indigo-900 hover:bg-indigo-100">Download combined export pack</Link> : <span className="rounded-xl border border-slate-300 bg-slate-100 px-4 py-2 text-sm font-semibold text-slate-600">Export pack blocked: needs 2+ booking refs</span>}
              </div>
              <div className="mt-4 overflow-x-auto rounded-2xl border border-slate-200">
                <table className="min-w-full divide-y divide-slate-200 text-sm"><thead className="bg-slate-100 text-xs uppercase tracking-wide text-slate-500"><tr><th className="px-3 py-2 text-left">Booking ref</th><th className="px-3 py-2 text-left">Importer / recipient</th><th className="px-3 py-2 text-right">Packages / qty</th><th className="px-3 py-2 text-right">Value</th><th className="px-3 py-2 text-left">Evidence</th><th className="px-3 py-2 text-left">Action</th></tr></thead><tbody className="divide-y divide-slate-100 bg-white">
                  {rows.map((row) => <tr key={row.shipment_batch_id}><td className="px-3 py-2 font-semibold">{row.booking_ref ?? row.shipment_batch_id}</td><td className="px-3 py-2"><p className="font-semibold">{row.importer_name ?? "Importer"}</p><p className="text-xs text-slate-500">Recipient: {row.final_recipient_name ?? "Not set"}</p>{row.final_recipient_address ? <p className="text-xs text-slate-500">{row.final_recipient_address}</p> : <p className="text-xs font-semibold text-amber-700">Recipient address missing</p>}</td><td className="px-3 py-2 text-right"><p className="font-semibold">{n(row.package_count)} pkg</p><p className="text-xs text-slate-500">Qty {qty(row.item_qty)}</p></td><td className="px-3 py-2 text-right font-semibold">{money(row.invoice_value_gbp)}</td><td className="px-3 py-2"><span className={`inline-block rounded-full px-2 py-1 text-xs font-semibold ${statusClass(row.export_evidence_status)}`}>Export: {friendly(row.export_evidence_status)}</span><span className={`mt-1 block w-fit rounded-full px-2 py-1 text-xs font-semibold ${statusClass(row.pod_status)}`}>POD: {friendly(row.pod_status)}</span></td><td className="px-3 py-2"><Link href={`/shipper/shipments/${row.shipment_batch_id}`} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-xs font-semibold text-slate-800 hover:bg-slate-50">Open batch</Link></td></tr>)}
                </tbody></table>
              </div>
            </section>

            <section className="grid gap-4 lg:grid-cols-2">
              <article className="rounded-3xl border border-amber-200 bg-amber-50 p-5 shadow-sm sm:p-6">
                <h2 className="text-xl font-semibold text-amber-950">Signed export pack upload</h2>
                <p className="mt-2 text-sm leading-6 text-amber-900">Upload one signed/stamped Groupage Export Pack. The system will create normal final export evidence rows for every included batch.</p>
                <form action={submitGroupageSignedExportPackAction} className="mt-5 grid gap-3">
                  <input type="hidden" name="groupage_movement_id" value={groupageMovementId} />
                  <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-amber-800">Document ref</span><input name="document_ref" defaultValue={first.groupage_movement_ref ?? ""} className="w-full rounded-xl border border-amber-300 bg-white px-3 py-2" /></label>
                  <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-amber-800">Signed export pack file</span><input name="groupage_export_pack_file" type="file" required className="w-full rounded-xl border border-amber-300 bg-white px-3 py-2" /></label>
                  <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-amber-800">Notes</span><textarea name="notes" rows={3} className="w-full rounded-xl border border-amber-300 bg-white px-3 py-2" /></label>
                  <button type="submit" disabled={!validGroupageSize} className="rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800 disabled:cursor-not-allowed disabled:bg-slate-400">Upload and apply to all included batches</button>
                </form>
              </article>
              <article className="rounded-3xl border border-sky-200 bg-sky-50 p-5 shadow-sm sm:p-6">
                <h2 className="text-xl font-semibold text-sky-950">POD / delivery evidence</h2>
                <p className="mt-2 text-sm leading-6 text-sky-900">Upload POD only for the booking refs covered by that POD. This will create normal POD evidence rows only for selected batches.</p>
                <form action={submitGroupagePodAction} className="mt-5 grid gap-3">
                  <input type="hidden" name="groupage_movement_id" value={groupageMovementId} />
                  <GroupageSelectionControls fieldName="pod_shipment_batch_ids" label="POD covered refs" />
                  <div className="rounded-2xl border border-sky-200 bg-white p-3">
                    <p className="text-xs font-semibold uppercase tracking-wide text-sky-800">Covered booking refs</p>
                    <div className="mt-2 grid gap-2">
                      {rows.map((row) => <label key={row.shipment_batch_id} className="flex items-center gap-2 text-sm"><input type="checkbox" name="pod_shipment_batch_ids" value={row.shipment_batch_id} disabled={!validGroupageSize} /> <span className="font-semibold">{row.booking_ref ?? row.shipment_batch_id}</span><span className="text-slate-500">{row.importer_name ?? "Importer"}</span></label>)}
                    </div>
                  </div>
                  <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-sky-800">POD ref</span><input name="pod_document_ref" className="w-full rounded-xl border border-sky-300 bg-white px-3 py-2" /></label>
                  <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-sky-800">POD file</span><input name="groupage_pod_file" type="file" required className="w-full rounded-xl border border-sky-300 bg-white px-3 py-2" /></label>
                  <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-sky-800">Notes</span><textarea name="pod_notes" rows={3} className="w-full rounded-xl border border-sky-300 bg-white px-3 py-2" /></label>
                  <button type="submit" disabled={!validGroupageSize} className="rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800 disabled:cursor-not-allowed disabled:bg-slate-400">Upload POD for selected booking refs</button>
                </form>
              </article>
            </section>
          </>
        ) : null}
      </div>
    </main>
  );
}
