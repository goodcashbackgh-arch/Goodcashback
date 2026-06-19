import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { saveExportEvidenceProfileAction } from "./actions";

type ExportProfile = {
  profile_id: string;
  profile_name: string | null;
  exporter_name: string | null;
  exporter_address: string | null;
  exporter_vat_number: string | null;
  default_movement_consignee_name: string | null;
  default_movement_consignee_address: string | null;
  default_notify_party_name: string | null;
  default_notify_party_address: string | null;
};

export default async function ShipperExportEvidenceProfilePage({ searchParams }: { searchParams?: Promise<{ success?: string; error?: string }> }) {
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

  const { data, error } = await (supabase as any).rpc("shipper_export_evidence_profiles_v1");
  const profile = ((data ?? []) as ExportProfile[])[0] ?? null;
  const shipper = Array.isArray((shipperUser as any).shippers) ? (shipperUser as any).shippers[0] : (shipperUser as any).shippers;

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-5xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-wrap gap-3 text-sm font-semibold text-sky-700">
            <Link href="/shipper">← Shipper dashboard</Link>
            <Link href="/shipper/groupage-movements">Groupage Movements</Link>
          </div>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Goodcashback Shipper</p>
          <h1 className="mt-2 text-2xl font-semibold tracking-tight sm:text-3xl">Export evidence profile</h1>
          <p className="mt-2 text-sm text-slate-600">{(shipperUser as any).full_name} · {shipper?.name ?? "Shipper"}</p>
          <p className="mt-3 max-w-3xl text-sm leading-6 text-slate-600">Database source for Groupage Export Pack exporter and movement consignee fields. Groupage movements snapshot these values from the profile.</p>
          {qp.success ? <p className="mt-4 rounded-xl border border-emerald-300 bg-emerald-50 px-3 py-2 text-sm text-emerald-900">{qp.success}</p> : null}
          {qp.error ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">{qp.error}</p> : null}
          {error ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">Profile read model unavailable: {error.message}</p> : null}
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <h2 className="text-xl font-semibold">Default export evidence profile</h2>
          <form action={saveExportEvidenceProfileAction} className="mt-5 grid gap-4 md:grid-cols-2">
            <input type="hidden" name="profile_id" value={profile?.profile_id ?? ""} />
            <label className="space-y-1 text-sm md:col-span-2"><span className="text-xs uppercase tracking-wide text-slate-500">Profile name</span><input name="profile_name" defaultValue={profile?.profile_name ?? "Default export evidence profile"} className="w-full rounded-xl border border-slate-300 px-3 py-2" /></label>
            <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-slate-500">Exporter name</span><input name="exporter_name" required defaultValue={profile?.exporter_name ?? ""} className="w-full rounded-xl border border-slate-300 px-3 py-2" /></label>
            <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-slate-500">Exporter VAT number</span><input name="exporter_vat_number" defaultValue={profile?.exporter_vat_number ?? ""} className="w-full rounded-xl border border-slate-300 px-3 py-2" /></label>
            <label className="space-y-1 text-sm md:col-span-2"><span className="text-xs uppercase tracking-wide text-slate-500">Exporter address</span><textarea name="exporter_address" required rows={3} defaultValue={profile?.exporter_address ?? ""} className="w-full rounded-xl border border-slate-300 px-3 py-2" /></label>
            <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-slate-500">Movement consignee</span><input name="default_movement_consignee_name" required defaultValue={profile?.default_movement_consignee_name ?? ""} className="w-full rounded-xl border border-slate-300 px-3 py-2" /></label>
            <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-slate-500">Notify party</span><input name="default_notify_party_name" defaultValue={profile?.default_notify_party_name ?? ""} className="w-full rounded-xl border border-slate-300 px-3 py-2" /></label>
            <label className="space-y-1 text-sm md:col-span-2"><span className="text-xs uppercase tracking-wide text-slate-500">Movement consignee address</span><textarea name="default_movement_consignee_address" required rows={3} defaultValue={profile?.default_movement_consignee_address ?? ""} className="w-full rounded-xl border border-slate-300 px-3 py-2" /></label>
            <label className="space-y-1 text-sm md:col-span-2"><span className="text-xs uppercase tracking-wide text-slate-500">Notify party address</span><textarea name="default_notify_party_address" rows={2} defaultValue={profile?.default_notify_party_address ?? ""} className="w-full rounded-xl border border-slate-300 px-3 py-2" /></label>
            <div className="md:col-span-2"><button type="submit" className="rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800">Save export evidence profile</button></div>
          </form>
        </section>
      </div>
    </main>
  );
}
