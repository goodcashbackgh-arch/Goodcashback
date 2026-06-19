import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

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

function shortDate(value: string | null | undefined) {
  if (!value) return "—";
  return value.includes("T") ? value.slice(0, 10) : value;
}

function friendly(value: string | null | undefined) {
  if (!value) return "—";
  return value.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase());
}

function statusClass(status: string | null | undefined) {
  if (["accepted_current", "movement_facts_ready", "complete", "pod_fully_accepted", "signed_export_pack_fully_accepted"].includes(status ?? "")) return "bg-emerald-100 text-emerald-800";
  if (["rejected_resubmit_required", "voided"].includes(status ?? "")) return "bg-rose-100 text-rose-800";
  return "bg-amber-100 text-amber-800";
}

function field(label: string, value: string | null | undefined) {
  return <div className="rounded-2xl border border-slate-200 bg-slate-50 p-3"><p className="text-xs uppercase tracking-wide text-slate-500">{label}</p><p className="mt-1 whitespace-pre-wrap font-semibold">{value || "Not entered"}</p></div>;
}

export default async function InternalGroupageMovementDetailPage({ params }: { params: Promise<{ groupage_movement_id: string }> }) {
  const { groupage_movement_id: groupageMovementId } = await params;
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

  const { data, error } = await (supabase as any).rpc("shipper_groupage_movement_detail_v1", {
    p_groupage_movement_id: groupageMovementId,
  });

  const rows = (data ?? []) as DetailRow[];
  const first = rows[0] ?? null;
  const totalPackages = rows.reduce((sum, row) => sum + n(row.package_count), 0);
  const totalQty = rows.reduce((sum, row) => sum + n(row.item_qty), 0);
  const totalValue = rows.reduce((sum, row) => sum + n(row.invoice_value_gbp), 0);

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-7xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-wrap gap-3 text-sm font-semibold text-sky-700">
            <Link href="/internal/shipping-control">← Shipping control</Link>
          </div>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Goodcashback Internal</p>
          <div className="mt-2 flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
            <div>
              <h1 className="text-2xl font-semibold tracking-tight sm:text-3xl">Groupage Movement {first?.groupage_movement_ref ?? groupageMovementId}</h1>
              <p className="mt-2 text-sm text-slate-600">Supervisor visibility across included importer shipment batches. Groupage status is aggregate only; batch/order status remains canonical.</p>
            </div>
            <div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700"><div className="font-medium text-slate-950">{(staff as any).full_name}</div><div>{(staff as any).role_type}</div></div>
          </div>
          {error ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">{error.message}</p> : null}
          {!first && !error ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">Groupage Movement not found.</p> : null}
        </section>

        {first ? (
          <>
            <section className="grid gap-4 md:grid-cols-4">
              <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Status</p><p className={`mt-1 w-fit rounded-full px-3 py-1 text-sm font-semibold ${statusClass(first.groupage_status)}`}>{friendly(first.groupage_status)}</p></div>
              <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Booking refs</p><p className="mt-1 text-2xl font-semibold">{rows.length}</p></div>
              <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Packages / qty</p><p className="mt-1 text-2xl font-semibold">{totalPackages} / {qty(totalQty)}</p></div>
              <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Invoice value</p><p className="mt-1 text-2xl font-semibold">{money(totalValue)}</p></div>
            </section>

            <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
              <div className="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
                <div><h2 className="text-xl font-semibold">Movement facts</h2><p className="mt-2 text-sm text-slate-600">These facts should match the signed export pack and underlying batch completion fields.</p></div>
                <Link href={`/shipper/groupage-movements/${groupageMovementId}/export-pack`} target="_blank" className="rounded-xl border border-indigo-300 bg-indigo-50 px-4 py-2 text-sm font-semibold text-indigo-900 hover:bg-indigo-100">View combined export pack</Link>
              </div>
              <div className="mt-4 grid gap-3 md:grid-cols-3">
                {field("Exporter", first.exporter_name_snapshot)}
                {field("Exporter address", first.exporter_address_snapshot)}
                {field("Exporter VAT", first.exporter_vat_number_snapshot)}
                {field("Shipper", first.shipper_name)}
                {field("Movement consignee", first.movement_consignee_name_snapshot)}
                {field("Consignee address", first.movement_consignee_address_snapshot)}
                {field("MBOL / BOL", first.mbl_bol_sea_waybill_ref)}
                {field("Container / seal", `${first.container_number ?? "—"} / ${first.seal_number ?? "—"}`)}
                {field("Vessel / voyage", first.vessel_voyage)}
                {field("Route", `${first.port_of_loading ?? "—"} → ${first.port_of_discharge ?? "—"}`)}
                {field("Place / date", `${first.place_of_delivery ?? "—"} · ${shortDate(first.export_shipment_date)}`)}
                {field("Weight", first.weight_text || "Not separately recorded by issuing consolidator")}
              </div>
            </section>

            <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
              <h2 className="text-xl font-semibold">Included booking refs</h2>
              <div className="mt-4 overflow-x-auto rounded-2xl border border-slate-200">
                <table className="min-w-full divide-y divide-slate-200 text-sm"><thead className="bg-slate-100 text-xs uppercase tracking-wide text-slate-500"><tr><th className="px-3 py-2 text-left">Booking ref</th><th className="px-3 py-2 text-left">Importer / recipient</th><th className="px-3 py-2 text-right">Packages / qty</th><th className="px-3 py-2 text-right">Value</th><th className="px-3 py-2 text-left">Evidence status</th><th className="px-3 py-2 text-left">Actions</th></tr></thead><tbody className="divide-y divide-slate-100 bg-white">
                  {rows.map((row) => <tr key={row.shipment_batch_id}><td className="px-3 py-2 font-semibold">{row.booking_ref ?? row.shipment_batch_id}</td><td className="px-3 py-2"><p className="font-semibold">{row.importer_name ?? "Importer"}</p><p className="text-xs text-slate-500">Recipient: {row.final_recipient_name ?? "Not set"}</p><p className="text-xs text-slate-500">{row.final_recipient_address ?? "Recipient address missing"}</p></td><td className="px-3 py-2 text-right"><p className="font-semibold">{n(row.package_count)} pkg</p><p className="text-xs text-slate-500">Qty {qty(row.item_qty)}</p></td><td className="px-3 py-2 text-right font-semibold">{money(row.invoice_value_gbp)}</td><td className="px-3 py-2"><span className={`inline-block rounded-full px-2 py-1 text-xs font-semibold ${statusClass(row.export_evidence_status)}`}>Export: {friendly(row.export_evidence_status)}</span><span className={`mt-1 block w-fit rounded-full px-2 py-1 text-xs font-semibold ${statusClass(row.pod_status)}`}>POD: {friendly(row.pod_status)}</span></td><td className="px-3 py-2"><div className="flex flex-col gap-2"><Link href={`/internal/shipping-control/${row.shipment_batch_id}`} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-xs font-semibold text-slate-800 hover:bg-slate-50">View batch detail</Link><Link href={`/internal/export-evidence/final/${row.shipment_batch_id}`} className="rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-xs font-semibold text-amber-900 hover:bg-amber-100">Review final evidence / POD</Link></div></td></tr>)}
                </tbody></table>
              </div>
            </section>
          </>
        ) : null}
      </div>
    </main>
  );
}
