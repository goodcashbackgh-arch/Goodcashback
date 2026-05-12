import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { saveSageMappingAction } from "./actions";

type Row = {
  mapping_code: string;
  mapping_group: string | null;
  display_name: string | null;
  description: string | null;
  value_kind: string | null;
  required_for: string[] | null;
  sage_external_id: string | null;
  sage_display_name: string | null;
  is_active: boolean | null;
  mapping_status: string | null;
  blocker: string | null;
  configured_at: string | null;
  configured_by_staff_name: string | null;
  notes: string | null;
};

function friendly(value: string | null | undefined) {
  if (!value) return "—";
  return value.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase());
}

function statusClass(status: string | null | undefined) {
  if (status === "configured") return "bg-emerald-100 text-emerald-800";
  if (status === "missing") return "bg-rose-100 text-rose-800";
  if (status === "disabled") return "bg-slate-200 text-slate-800";
  return "bg-amber-100 text-amber-800";
}

function groupLabel(group: string | null | undefined) {
  if (group === "customer_sales") return "Customer sales";
  if (group === "shipper_ap") return "Shipper AP";
  return friendly(group);
}

export default async function SageMappingPage({ searchParams }: { searchParams?: Promise<{ success?: string; error?: string }> }) {
  const params = searchParams ? await searchParams : {};
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

  const { data, error } = await (supabase as any).rpc("internal_sage_mapping_control_v1");
  const rows = (data ?? []) as Row[];
  const configured = rows.filter((row) => row.mapping_status === "configured");
  const missing = rows.filter((row) => row.mapping_status === "missing");

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-7xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-wrap gap-3 text-sm font-semibold text-sky-700">
            <Link href="/internal">← Internal dashboard</Link>
            <Link href="/internal/sage-ready">Ready for Sage queue</Link>
          </div>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Goodcashback Internal</p>
          <div className="mt-2 flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
            <div>
              <h1 className="text-2xl font-semibold tracking-tight sm:text-3xl">Sage mapping control</h1>
              <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">
                Configure the Sage tax-rate and ledger/account ids needed before any posting adapter can run. This page does not call Sage, post invoices, or mark anything posted. It only stores the mappings the posting queue will later use.
              </p>
            </div>
            <div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700">
              <div className="font-medium text-slate-950">{staff.full_name}</div>
              <div>{staff.role_type}</div>
            </div>
          </div>
          {params.success ? <p className="mt-4 rounded-xl border border-emerald-300 bg-emerald-50 px-3 py-2 text-sm text-emerald-900">{params.success}</p> : null}
          {params.error ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">{params.error}</p> : null}
          {error ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">Mapping control unavailable: {error.message}. Run the latest Supabase migration before testing this page.</p> : null}
        </section>

        <section className="grid gap-4 md:grid-cols-3">
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Mappings</p><p className="mt-1 text-2xl font-semibold">{rows.length}</p></div>
          <div className="rounded-3xl border border-emerald-200 bg-emerald-50 p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Configured</p><p className="mt-1 text-2xl font-semibold">{configured.length}</p></div>
          <div className={`rounded-3xl border p-4 shadow-sm ${missing.length > 0 ? "border-rose-200 bg-rose-50" : "border-slate-200 bg-white"}`}><p className="text-xs uppercase tracking-wide text-slate-500">Missing</p><p className="mt-1 text-2xl font-semibold">{missing.length}</p></div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <h2 className="text-xl font-semibold">Required Sage mappings</h2>
          <p className="mt-2 text-sm leading-6 text-slate-600">Enter the exact Sage tenant id/name after checking Sage. Do not guess values such as T0.</p>

          <div className="mt-5 grid gap-4">
            {rows.map((row) => (
              <article key={row.mapping_code} className="rounded-3xl border border-slate-200 bg-slate-50 p-5">
                <div className="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
                  <div>
                    <div className="flex flex-wrap items-center gap-2">
                      <h3 className="text-lg font-semibold">{row.display_name ?? row.mapping_code}</h3>
                      <span className={`rounded-full px-2 py-1 text-xs font-semibold ${statusClass(row.mapping_status)}`}>{friendly(row.mapping_status)}</span>
                    </div>
                    <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-600">{row.description}</p>
                    <div className="mt-3 flex flex-wrap gap-2 text-xs font-semibold text-slate-600">
                      <span className="rounded-full bg-white px-2.5 py-1 ring-1 ring-slate-200">{groupLabel(row.mapping_group)}</span>
                      <span className="rounded-full bg-white px-2.5 py-1 ring-1 ring-slate-200">{friendly(row.value_kind)}</span>
                      {(row.required_for ?? []).map((item) => <span key={item} className="rounded-full bg-white px-2.5 py-1 ring-1 ring-slate-200">{friendly(item)}</span>)}
                    </div>
                    {row.blocker ? <p className="mt-3 rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm text-rose-800">{friendly(row.blocker)}</p> : null}
                  </div>
                  <div className="rounded-2xl bg-white p-4 text-sm shadow-sm ring-1 ring-slate-200 lg:w-80">
                    <p className="text-xs uppercase tracking-wide text-slate-500">Current value</p>
                    <p className="mt-1 font-semibold">{row.sage_external_id || "Not configured"}</p>
                    <p className="mt-1 text-slate-600">{row.sage_display_name || "—"}</p>
                    <p className="mt-3 text-xs text-slate-500">Configured by: {row.configured_by_staff_name ?? "—"}</p>
                    <p className="text-xs text-slate-500">Configured at: {row.configured_at ? row.configured_at.slice(0, 19).replace("T", " ") : "—"}</p>
                  </div>
                </div>

                <form action={saveSageMappingAction} className="mt-5 grid gap-3 rounded-2xl border border-slate-200 bg-white p-4 md:grid-cols-[1.2fr_1.2fr_1.5fr_auto]">
                  <input type="hidden" name="mapping_code" value={row.mapping_code} />
                  <label className="text-xs font-semibold uppercase tracking-wide text-slate-500">Sage id<input name="sage_external_id" defaultValue={row.sage_external_id ?? ""} placeholder="Exact Sage tax/account id" className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal text-slate-950" /></label>
                  <label className="text-xs font-semibold uppercase tracking-wide text-slate-500">Display name<input name="sage_display_name" defaultValue={row.sage_display_name ?? ""} placeholder="Name seen in Sage" className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal text-slate-950" /></label>
                  <label className="text-xs font-semibold uppercase tracking-wide text-slate-500">Notes<input name="notes" defaultValue={row.notes ?? ""} placeholder="How this was checked" className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal text-slate-950" /></label>
                  <div className="flex items-end"><button className="w-full rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800">Save</button></div>
                </form>
              </article>
            ))}
          </div>
        </section>

        <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm leading-6 text-amber-900">
          <h2 className="font-semibold">Control rule</h2>
          <p className="mt-2">These mappings are tenant-specific. They must be checked against Sage before any external posting adapter is enabled. Saving a mapping only removes mapping blockers; it does not post or change invoice status.</p>
        </section>
      </div>
    </main>
  );
}
