import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { saveImporterDeliveryProfileAction } from "./actions";

type ImporterDeliveryProfile = {
  importer_id: string;
  importer_name: string | null;
  profile_id: string | null;
  final_recipient_name: string | null;
  final_recipient_address_line_1: string | null;
  final_recipient_address_line_2: string | null;
  final_recipient_city: string | null;
  final_recipient_region: string | null;
  final_recipient_country: string | null;
  final_recipient_phone: string | null;
  final_recipient_email: string | null;
};

function isComplete(row: ImporterDeliveryProfile) {
  return Boolean(row.final_recipient_name && row.final_recipient_address_line_1 && row.final_recipient_country);
}

export default async function ShipperImporterDeliveryProfilesPage({ searchParams }: { searchParams?: Promise<{ success?: string; error?: string }> }) {
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

  const { data, error } = await (supabase as any).rpc("shipper_importer_delivery_profiles_v1");
  const rows = (data ?? []) as ImporterDeliveryProfile[];
  const missing = rows.filter((row) => !isComplete(row)).length;
  const shipper = Array.isArray((shipperUser as any).shippers) ? (shipperUser as any).shippers[0] : (shipperUser as any).shippers;

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-7xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-wrap gap-3 text-sm font-semibold text-sky-700">
            <Link href="/shipper">← Shipper dashboard</Link>
            <Link href="/shipper/groupage-movements">Groupage Movements</Link>
          </div>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Goodcashback Shipper</p>
          <h1 className="mt-2 text-2xl font-semibold tracking-tight sm:text-3xl">Importer export delivery profiles</h1>
          <p className="mt-2 text-sm text-slate-600">{(shipperUser as any).full_name} · {shipper?.name ?? "Shipper"}</p>
          <p className="mt-3 max-w-3xl text-sm leading-6 text-slate-600">Database source for final recipient/consignee details used in Groupage Export Pack schedules. Groupage movements snapshot these details by importer.</p>
          {qp.success ? <p className="mt-4 rounded-xl border border-emerald-300 bg-emerald-50 px-3 py-2 text-sm text-emerald-900">{qp.success}</p> : null}
          {qp.error ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">{qp.error}</p> : null}
          {error ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">Importer profile read model unavailable: {error.message}</p> : null}
        </section>

        <section className="grid gap-4 md:grid-cols-3">
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Importers</p><p className="mt-1 text-2xl font-semibold">{rows.length}</p></div>
          <div className="rounded-3xl border border-emerald-200 bg-emerald-50 p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-emerald-700">Complete</p><p className="mt-1 text-2xl font-semibold text-emerald-950">{rows.length - missing}</p></div>
          <div className="rounded-3xl border border-amber-200 bg-amber-50 p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-amber-700">Missing</p><p className="mt-1 text-2xl font-semibold text-amber-950">{missing}</p></div>
        </section>

        <section className="space-y-4">
          {rows.length === 0 ? <p className="rounded-3xl border border-slate-200 bg-white p-5 text-sm text-slate-700 shadow-sm">No importer shipment batches are currently available for this shipper.</p> : null}
          {rows.map((row) => (
            <article key={row.importer_id} className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
              <div className="flex flex-col gap-2 md:flex-row md:items-start md:justify-between">
                <div>
                  <h2 className="text-xl font-semibold">{row.importer_name ?? row.importer_id}</h2>
                  <p className="mt-1 text-sm text-slate-600">{isComplete(row) ? "Recipient profile complete" : "Recipient profile missing required fields"}</p>
                </div>
                <span className={`w-fit rounded-full px-3 py-1 text-sm font-semibold ${isComplete(row) ? "bg-emerald-100 text-emerald-800" : "bg-amber-100 text-amber-800"}`}>{isComplete(row) ? "Complete" : "Missing"}</span>
              </div>
              <form action={saveImporterDeliveryProfileAction} className="mt-5 grid gap-4 md:grid-cols-2">
                <input type="hidden" name="importer_id" value={row.importer_id} />
                <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-slate-500">Final recipient name</span><input name="final_recipient_name" required defaultValue={row.final_recipient_name ?? row.importer_name ?? ""} className="w-full rounded-xl border border-slate-300 px-3 py-2" /></label>
                <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-slate-500">Country</span><input name="final_recipient_country" required defaultValue={row.final_recipient_country ?? "Ghana"} className="w-full rounded-xl border border-slate-300 px-3 py-2" /></label>
                <label className="space-y-1 text-sm md:col-span-2"><span className="text-xs uppercase tracking-wide text-slate-500">Address line 1</span><input name="final_recipient_address_line_1" required defaultValue={row.final_recipient_address_line_1 ?? ""} className="w-full rounded-xl border border-slate-300 px-3 py-2" /></label>
                <label className="space-y-1 text-sm md:col-span-2"><span className="text-xs uppercase tracking-wide text-slate-500">Address line 2</span><input name="final_recipient_address_line_2" defaultValue={row.final_recipient_address_line_2 ?? ""} className="w-full rounded-xl border border-slate-300 px-3 py-2" /></label>
                <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-slate-500">City</span><input name="final_recipient_city" defaultValue={row.final_recipient_city ?? ""} className="w-full rounded-xl border border-slate-300 px-3 py-2" /></label>
                <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-slate-500">Region</span><input name="final_recipient_region" defaultValue={row.final_recipient_region ?? ""} className="w-full rounded-xl border border-slate-300 px-3 py-2" /></label>
                <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-slate-500">Phone</span><input name="final_recipient_phone" defaultValue={row.final_recipient_phone ?? ""} className="w-full rounded-xl border border-slate-300 px-3 py-2" /></label>
                <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-slate-500">Email</span><input name="final_recipient_email" type="email" defaultValue={row.final_recipient_email ?? ""} className="w-full rounded-xl border border-slate-300 px-3 py-2" /></label>
                <div className="md:col-span-2"><button type="submit" className="rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800">Save recipient profile</button></div>
              </form>
            </article>
          ))}
        </section>
      </div>
    </main>
  );
}
