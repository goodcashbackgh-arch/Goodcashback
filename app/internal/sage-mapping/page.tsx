import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { discoverSageCatalog, sageCatalogHints, type SageCatalogCategory } from "@/lib/sage/catalog";
import { saveSageMappingAction, saveSagePartyMappingAction } from "./actions";

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

type PartyRow = {
  platform_party_type: string;
  platform_party_id: string;
  platform_party_display_name: string | null;
  platform_context_text: string | null;
  recommended_sage_contact_type: string | null;
  sage_mapping_id: string | null;
  sage_contact_id: string | null;
  sage_contact_display_name: string | null;
  sage_contact_reference: string | null;
  sage_contact_type: string | null;
  mapping_status: string | null;
  blocker: string | null;
  verified_at: string | null;
  verified_by_staff_name: string | null;
  notes: string | null;
};

type SearchParams = {
  success?: string;
  error?: string;
  run?: string;
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
  if (group === "supplier_goods_ap") return "Supplier goods AP";
  if (group === "shipper_ap") return "Shipper AP";
  return friendly(group);
}

function partyLabel(type: string | null | undefined) {
  if (type === "importer_customer") return "Importer/customer";
  if (type === "retailer_supplier") return "Retailer/supplier";
  if (type === "shipper") return "Shipper";
  return friendly(type);
}

function discoveryTone(ok: boolean) {
  return ok ? "border-emerald-200 bg-emerald-50 text-emerald-900" : "border-rose-200 bg-rose-50 text-rose-900";
}

function RequirementList({ title, items }: { title: string; items: string[] }) {
  if (items.length === 0) return null;
  return (
    <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
      <h3 className="text-base font-semibold text-slate-950">{title}</h3>
      <div className="mt-3 grid gap-2 text-sm leading-6 text-slate-700">
        {items.map((item) => <p key={item} className="rounded-xl bg-slate-50 px-3 py-2">{item}</p>)}
      </div>
    </div>
  );
}

function SageCategoryTable({ category }: { category: SageCatalogCategory }) {
  const hints = sageCatalogHints(category);
  return (
    <section className={`rounded-3xl border bg-white p-5 shadow-sm ${category.ok ? "border-slate-200" : "border-rose-200"}`}>
      <div className="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
        <div>
          <p className="text-xs font-bold uppercase tracking-[0.2em] text-violet-500">{category.key}</p>
          <h3 className="mt-1 text-lg font-semibold text-slate-950">{category.label}</h3>
          <p className="mt-1 font-mono text-xs text-slate-500">GET {category.endpoint}</p>
        </div>
        <div className="flex flex-wrap gap-2 text-xs font-bold">
          <span className={`rounded-full border px-3 py-1 ${category.ok ? "border-emerald-200 bg-emerald-50 text-emerald-900" : "border-rose-200 bg-rose-50 text-rose-900"}`}>{category.ok ? "GET OK" : `GET failed ${category.http_status ?? ""}`}</span>
          <span className="rounded-full border border-slate-200 bg-slate-50 px-3 py-1 text-slate-700">{category.count} row(s)</span>
        </div>
      </div>

      {category.error ? <p className="mt-3 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm font-semibold text-rose-900">{category.error}</p> : null}

      {hints.length > 0 ? (
        <div className="mt-4 rounded-2xl border border-amber-200 bg-amber-50 p-3">
          <p className="text-xs font-bold uppercase tracking-wide text-amber-800">Likely mapping candidates — confirm before saving</p>
          <div className="mt-2 flex flex-wrap gap-2">
            {hints.map((item) => (
              <span key={`${category.key}-${item.id}-${item.display}`} className="rounded-full border border-amber-200 bg-white px-3 py-1 text-xs font-semibold text-amber-900">
                {item.display}{item.code ? ` · ${item.code}` : ""}{item.reference ? ` · ${item.reference}` : ""}
              </span>
            ))}
          </div>
        </div>
      ) : null}

      <div className="mt-4 overflow-x-auto rounded-2xl border border-slate-200">
        <table className="min-w-[900px] divide-y divide-slate-200 text-xs">
          <thead className="bg-slate-100 uppercase tracking-wide text-slate-500">
            <tr>
              <th className="px-3 py-2 text-left">Display</th>
              <th className="px-3 py-2 text-left">Sage id</th>
              <th className="px-3 py-2 text-left">Reference</th>
              <th className="px-3 py-2 text-left">Code</th>
              <th className="px-3 py-2 text-left">Type/status</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-100 bg-white">
            {category.items.length === 0 ? (
              <tr><td colSpan={5} className="px-3 py-6 text-center text-sm text-slate-500">No rows returned for this category.</td></tr>
            ) : category.items.map((item) => (
              <tr key={`${category.key}-${item.id}-${item.display}`} className="align-top hover:bg-slate-50">
                <td className="max-w-[260px] px-3 py-2 font-semibold text-slate-950">{item.display || "—"}</td>
                <td className="max-w-[240px] truncate px-3 py-2 font-mono text-[11px] text-slate-700" title={item.id}>{item.id || "—"}</td>
                <td className="max-w-[190px] truncate px-3 py-2 text-slate-700" title={item.reference}>{item.reference || "—"}</td>
                <td className="max-w-[140px] truncate px-3 py-2 text-slate-700" title={item.code}>{item.code || "—"}</td>
                <td className="max-w-[180px] truncate px-3 py-2 text-slate-700" title={`${item.type} ${item.active}`}>{[item.type, item.active].filter(Boolean).join(" · ") || "—"}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {category.items.length >= 60 ? <p className="mt-2 text-xs font-semibold text-slate-500">Showing first 60 rows only. Use exact Sage search/config later where the list is large.</p> : null}
    </section>
  );
}

function PartyMappingCard({ party }: { party: PartyRow }) {
  return (
    <article className="rounded-3xl border border-slate-200 bg-slate-50 p-5">
      <div className="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
        <div>
          <div className="flex flex-wrap items-center gap-2">
            <h3 className="text-lg font-semibold">{party.platform_party_display_name ?? party.platform_party_id}</h3>
            <span className={`rounded-full px-2 py-1 text-xs font-semibold ${statusClass(party.mapping_status)}`}>{friendly(party.mapping_status)}</span>
          </div>
          <div className="mt-3 flex flex-wrap gap-2 text-xs font-semibold text-slate-600">
            <span className="rounded-full bg-white px-2.5 py-1 ring-1 ring-slate-200">{partyLabel(party.platform_party_type)}</span>
            <span className="rounded-full bg-white px-2.5 py-1 ring-1 ring-slate-200">Recommended Sage type: {friendly(party.recommended_sage_contact_type)}</span>
            <span className="rounded-full bg-white px-2.5 py-1 ring-1 ring-slate-200">{party.platform_context_text ?? "—"}</span>
          </div>
          {party.blocker ? <p className="mt-3 rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm text-rose-800">{friendly(party.blocker)}</p> : null}
        </div>
        <div className="rounded-2xl bg-white p-4 text-sm shadow-sm ring-1 ring-slate-200 lg:w-96">
          <p className="text-xs uppercase tracking-wide text-slate-500">Current Sage contact</p>
          <p className="mt-1 break-all font-semibold">{party.sage_contact_id || "Not configured"}</p>
          <p className="mt-1 text-slate-600">{party.sage_contact_display_name || "—"}</p>
          <p className="mt-1 text-xs text-slate-500">Reference: {party.sage_contact_reference || "—"}</p>
          <p className="text-xs text-slate-500">Type: {friendly(party.sage_contact_type)}</p>
          <p className="mt-3 text-xs text-slate-500">Verified by: {party.verified_by_staff_name ?? "—"}</p>
          <p className="text-xs text-slate-500">Verified at: {party.verified_at ? party.verified_at.slice(0, 19).replace("T", " ") : "—"}</p>
        </div>
      </div>

      <form action={saveSagePartyMappingAction} className="mt-5 grid gap-3 rounded-2xl border border-slate-200 bg-white p-4 lg:grid-cols-[1.1fr_1.1fr_0.8fr_1.2fr_auto]">
        <input type="hidden" name="platform_party_type" value={party.platform_party_type} />
        <input type="hidden" name="platform_party_id" value={party.platform_party_id} />
        <label className="text-xs font-semibold uppercase tracking-wide text-slate-500">Sage contact id<input name="sage_contact_id" defaultValue={party.sage_contact_id ?? ""} placeholder="Exact Sage contact id" className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal text-slate-950" /></label>
        <label className="text-xs font-semibold uppercase tracking-wide text-slate-500">Sage contact name<input name="sage_contact_display_name" defaultValue={party.sage_contact_display_name ?? ""} placeholder="Name shown in Sage" className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal text-slate-950" /></label>
        <label className="text-xs font-semibold uppercase tracking-wide text-slate-500">Sage type<select name="sage_contact_type" defaultValue={party.sage_contact_type || party.recommended_sage_contact_type || "unknown"} className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal text-slate-950"><option value="customer">Customer</option><option value="supplier">Supplier</option><option value="customer_supplier">Customer + supplier</option><option value="unknown">Unknown</option></select></label>
        <label className="text-xs font-semibold uppercase tracking-wide text-slate-500">Reference / notes<input name="sage_contact_reference" defaultValue={party.sage_contact_reference ?? ""} placeholder="Sage reference if any" className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal text-slate-950" /><input name="notes" defaultValue={party.notes ?? ""} placeholder="How this was checked" className="mt-2 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal text-slate-950" /></label>
        <div className="flex items-end"><button className="w-full rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800">Save</button></div>
      </form>
    </article>
  );
}

export default async function SageMappingPage({ searchParams }: { searchParams?: Promise<SearchParams> }) {
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
  const { data: partyData, error: partyError } = await (supabase as any).rpc("internal_sage_party_mapping_control_v1");
  const rows = (data ?? []) as Row[];
  const partyRows = (partyData ?? []) as PartyRow[];
  const configured = rows.filter((row) => row.mapping_status === "configured");
  const missing = rows.filter((row) => row.mapping_status === "missing");
  const partyConfigured = partyRows.filter((row) => row.mapping_status === "configured");
  const partyMissing = partyRows.filter((row) => row.mapping_status === "missing");
  const discovery = params.run === "1" ? await discoverSageCatalog() : null;

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-7xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-wrap gap-3 text-sm font-semibold text-sky-700">
            <Link href="/internal">← Internal dashboard</Link>
            <Link href="/internal/accounting-command-centre">Accounting Command Centre</Link>
            <Link href="/internal/sage-ready">Ready for Sage queue</Link>
          </div>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Goodcashback Internal</p>
          <div className="mt-2 flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
            <div>
              <h1 className="text-2xl font-semibold tracking-tight sm:text-3xl">Sage mapping control</h1>
              <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">
                Configure Sage contacts, tax rates and ledger/account ids before any posting adapter can run. This page can also run read-only Sage catalogue checks. It does not post invoices, purchase invoices, payments or credit notes.
              </p>
            </div>
            <div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700">
              <div className="font-medium text-slate-950">{staff.full_name}</div>
              <div>{staff.role_type}</div>
            </div>
          </div>
          {params.success ? <p className="mt-4 rounded-xl border border-emerald-300 bg-emerald-50 px-3 py-2 text-sm text-emerald-900">{params.success}</p> : null}
          {params.error ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">{params.error}</p> : null}
          {error ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">GL/tax mapping control unavailable: {error.message}. Run the latest Supabase migration before testing this page.</p> : null}
          {partyError ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">Party mapping control unavailable: {partyError.message}. Run the Sage party mapping migration.</p> : null}
        </section>

        <section className="grid gap-4 md:grid-cols-4">
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">GL/tax mappings</p><p className="mt-1 text-2xl font-semibold">{rows.length}</p></div>
          <div className="rounded-3xl border border-emerald-200 bg-emerald-50 p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">GL/tax configured</p><p className="mt-1 text-2xl font-semibold">{configured.length}</p></div>
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Party contacts</p><p className="mt-1 text-2xl font-semibold">{partyRows.length}</p></div>
          <div className={`rounded-3xl border p-4 shadow-sm ${missing.length + partyMissing.length > 0 ? "border-rose-200 bg-rose-50" : "border-slate-200 bg-white"}`}><p className="text-xs uppercase tracking-wide text-slate-500">Missing total</p><p className="mt-1 text-2xl font-semibold">{missing.length + partyMissing.length}</p></div>
        </section>

        <section className="rounded-3xl border border-violet-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
            <div>
              <p className="text-xs font-bold uppercase tracking-[0.2em] text-violet-500">Read-only Sage discovery</p>
              <h2 className="mt-1 text-xl font-semibold">API check for contacts, AR and AP mapping data</h2>
              <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">Pulls contacts, ledger accounts, VAT/tax rates, bank accounts and currencies from Sage so admin can confirm the exact ids needed for AR and AP. It is diagnostic only.</p>
            </div>
            <Link href="/internal/sage-mapping?run=1" className="rounded-xl bg-violet-700 px-4 py-2 text-sm font-bold text-white hover:bg-violet-800">Run read-only Sage API check</Link>
          </div>
          {discovery ? (
            <div className="mt-5 space-y-4">
              <div className={`rounded-2xl border p-4 ${discoveryTone(discovery.ok)}`}>
                <p className="font-semibold">{discovery.ok ? "Discovery complete" : "Discovery failed"}</p>
                <p className="mt-1 text-sm leading-6">{discovery.error || "Sage catalogue data was read using the active encrypted connection. No Sage object was created."}</p>
                <div className="mt-3 flex flex-wrap gap-2 text-xs font-bold">
                  <span className="rounded-full border bg-white/70 px-3 py-1">{discovery.token_refreshed ? "Token refreshed" : "Token reused"}</span>
                  <span className="rounded-full border bg-white/70 px-3 py-1">Business: {discovery.business?.sage_business_name ?? "—"}</span>
                </div>
              </div>
              {discovery.ok ? <div className="grid gap-4 lg:grid-cols-2"><RequirementList title="AR posting needs" items={discovery.ar_requirements} /><RequirementList title="AP posting needs" items={discovery.ap_requirements} /></div> : null}
              {discovery.categories.map((category) => <SageCategoryTable key={category.key} category={category} />)}
            </div>
          ) : null}
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <h2 className="text-xl font-semibold">Sage party/contact mappings</h2>
          <p className="mt-2 text-sm leading-6 text-slate-600">Map platform importers, retailers and shippers to Sage contacts. These are contact ids, not GLs. OCR should match platform parties first; these mappings supply Sage contacts during payload build.</p>
          <div className="mt-3 flex flex-wrap gap-2 text-xs font-semibold">
            <span className="rounded-full border border-emerald-200 bg-emerald-50 px-3 py-1 text-emerald-900">Configured {partyConfigured.length}</span>
            <span className="rounded-full border border-rose-200 bg-rose-50 px-3 py-1 text-rose-900">Missing {partyMissing.length}</span>
          </div>
          <div className="mt-5 grid gap-4">
            {partyRows.length === 0 ? <p className="rounded-2xl bg-slate-50 p-4 text-sm text-slate-600">No party rows returned. Run the party mapping migration.</p> : partyRows.map((party) => <PartyMappingCard key={`${party.platform_party_type}-${party.platform_party_id}`} party={party} />)}
          </div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <h2 className="text-xl font-semibold">Required GL / tax / bank mappings</h2>
          <p className="mt-2 text-sm leading-6 text-slate-600">Enter exact Sage ids after checking Sage. Do not confuse VAT/tax rate ids with VAT control ledger accounts.</p>

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
          <p className="mt-2">Party/contact mappings and GL/tax mappings are separate. Saving either only removes mapping blockers; it does not post or change invoice status.</p>
        </section>
      </div>
    </main>
  );
}
