import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import {
  linkOperatorImporterAction,
  setSupervisorScopeAction,
  upsertExportEvidenceProfileAction,
  upsertImporterBranchAction,
  upsertImporterDeliveryProfileAction,
  upsertShipperBranchAction,
} from "./actions";

type Option = { id: string; name?: string; importer_name?: string; full_name?: string; country_name?: string; currency_code?: string };

function Field({ label, name, required = false, placeholder = "", defaultValue = "" }: { label: string; name: string; required?: boolean; placeholder?: string; defaultValue?: string }) {
  return (
    <label className="flex flex-col gap-1 text-sm font-medium text-slate-700">
      <span>{label}{required ? " *" : ""}</span>
      <input name={name} required={required} placeholder={placeholder} defaultValue={defaultValue} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm text-slate-950 shadow-sm outline-none focus:border-sky-500" />
    </label>
  );
}

function TextArea({ label, name, required = false, placeholder = "" }: { label: string; name: string; required?: boolean; placeholder?: string }) {
  return (
    <label className="flex flex-col gap-1 text-sm font-medium text-slate-700 md:col-span-2">
      <span>{label}{required ? " *" : ""}</span>
      <textarea name={name} required={required} placeholder={placeholder} rows={3} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm text-slate-950 shadow-sm outline-none focus:border-sky-500" />
    </label>
  );
}

function SelectField({ label, name, options, required = false, emptyLabel = "Create new / select" }: { label: string; name: string; options: Option[]; required?: boolean; emptyLabel?: string }) {
  return (
    <label className="flex flex-col gap-1 text-sm font-medium text-slate-700">
      <span>{label}{required ? " *" : ""}</span>
      <select name={name} required={required} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm text-slate-950 shadow-sm outline-none focus:border-sky-500">
        <option value="">{emptyLabel}</option>
        {options.map((option) => (
          <option key={option.id} value={option.id}>
            {option.name ?? option.importer_name ?? option.full_name ?? option.country_name ?? option.id}
            {option.currency_code ? ` (${option.currency_code})` : ""}
          </option>
        ))}
      </select>
    </label>
  );
}

function Panel({ title, eyebrow, children }: { title: string; eyebrow: string; children: React.ReactNode }) {
  return (
    <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
      <p className="text-xs font-bold uppercase tracking-[0.2em] text-sky-600">{eyebrow}</p>
      <h2 className="mt-2 text-xl font-semibold tracking-tight text-slate-950">{title}</h2>
      <div className="mt-5">{children}</div>
    </section>
  );
}

function SubmitButton({ children }: { children: React.ReactNode }) {
  return <button className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800">{children}</button>;
}

export default async function InternalOnboardingPage() {
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

  const { data, error } = await (supabase as any).rpc("internal_onboarding_overview_v1");
  const overview = (data ?? {}) as any;
  const countries = (overview.countries ?? []) as any[];
  const shippers = (overview.shippers ?? []) as any[];
  const importers = (overview.importers ?? []) as any[];
  const operators = (overview.operators ?? []) as any[];
  const exportProfiles = (overview.export_profiles ?? []) as any[];
  const supervisors = (overview.supervisors ?? []) as any[];
  const blockers = overview.blockers ?? {};

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-7xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-wrap gap-3 text-sm font-semibold text-sky-700">
            <Link href="/internal">← Internal dashboard</Link>
            <Link href="/internal/access-control">Access diagnostic</Link>
            <Link href="/shipper/groupage-movements">Groupage movements</Link>
          </div>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Goodcashback Internal</p>
          <div className="mt-2 flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
            <div>
              <h1 className="text-2xl font-semibold tracking-tight sm:text-3xl">Multi-tenant onboarding centre</h1>
              <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">Contract v1 onboarding surface: branch setup, importer/customer branch setup, source delivery/export profiles, operator membership, and supervisor branch scope. Login routing is still legacy-safe and unchanged.</p>
            </div>
            <div className="rounded-2xl border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-950">
              <div className="font-semibold">Enforcement off</div>
              <div>{staff.full_name} · {staff.role_type}</div>
            </div>
          </div>
          {error ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">{error.message}. Run migration 20260620_internal_onboarding_overview_v1.sql first.</p> : null}
        </section>

        <section className="grid gap-4 md:grid-cols-4">
          <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Shipper branches</p><p className="mt-1 text-3xl font-semibold">{shippers.length}</p></div>
          <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Importer/customers</p><p className="mt-1 text-3xl font-semibold">{importers.length}</p></div>
          <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Delivery gaps</p><p className="mt-1 text-3xl font-semibold">{(blockers.importers_missing_delivery_profile ?? []).length}</p></div>
          <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Export profile gaps</p><p className="mt-1 text-3xl font-semibold">{(blockers.shipper_branches_missing_export_profile ?? []).length}</p></div>
        </section>

        <Panel eyebrow="1. Branch setup" title="Create / update shipping-company branch">
          <form action={upsertShipperBranchAction} className="grid gap-4 md:grid-cols-2">
            <SelectField label="Existing branch" name="shipper_id" options={shippers} emptyLabel="Create new branch" />
            <SelectField label="Country / currency lane" name="country_id" options={countries.map((c) => ({ id: c.id, name: c.name, currency_code: c.currency_code }))} required emptyLabel="Select country" />
            <Field label="Branch / shipper name" name="name" required placeholder="Jobyco Ghana" />
            <Field label="Contact email" name="contact_email" placeholder="ops@example.com" />
            <Field label="Contact phone" name="contact_phone" />
            <Field label="VAT treatment" name="vat_treatment" placeholder="outside_scope / domestic_vat / zero_rated" />
            <Field label="VAT registration country" name="vat_registration_country" placeholder="GBR / GHA / NGA" />
            <div className="md:col-span-2"><SubmitButton>Save branch</SubmitButton></div>
          </form>
        </Panel>

        <Panel eyebrow="2. Importer/customer branch" title="Create / update importer/customer under a branch">
          <form action={upsertImporterBranchAction} className="grid gap-4 md:grid-cols-2">
            <SelectField label="Existing importer/customer" name="importer_id" options={importers} emptyLabel="Create new importer/customer" />
            <SelectField label="Assigned shipper branch" name="shipper_id" options={shippers} required emptyLabel="Select branch" />
            <SelectField label="Country / currency lane" name="country_id" options={countries.map((c) => ({ id: c.id, name: c.name, currency_code: c.currency_code }))} required emptyLabel="Select country" />
            <Field label="Legal/customer name" name="company_name" required />
            <Field label="Trading/display name" name="trading_name" />
            <TextArea label="Business/customer address" name="address" />
            <div className="md:col-span-2"><SubmitButton>Save importer/customer</SubmitButton></div>
          </form>
        </Panel>

        <Panel eyebrow="3. Delivery source profile" title="Importer/customer final recipient details">
          <form action={upsertImporterDeliveryProfileAction} className="grid gap-4 md:grid-cols-2">
            <SelectField label="Importer/customer" name="importer_id" options={importers} required emptyLabel="Select importer/customer" />
            <Field label="Final recipient name" name="final_recipient_name" required />
            <Field label="Address line 1" name="final_recipient_address_line_1" required />
            <Field label="Address line 2" name="final_recipient_address_line_2" />
            <Field label="City" name="final_recipient_city" />
            <Field label="Region" name="final_recipient_region" />
            <Field label="Country" name="final_recipient_country" required />
            <Field label="Phone" name="final_recipient_phone" />
            <Field label="Email" name="final_recipient_email" />
            <div className="md:col-span-2"><SubmitButton>Save delivery profile</SubmitButton></div>
          </form>
        </Panel>

        <Panel eyebrow="4. Export source profile" title="Exporter, movement consignee and notify party">
          <form action={upsertExportEvidenceProfileAction} className="grid gap-4 md:grid-cols-2">
            <SelectField label="Existing export profile" name="profile_id" options={exportProfiles.map((p) => ({ id: p.id, name: `${p.profile_name} — ${p.shipper_name ?? "No branch"}` }))} emptyLabel="Create new profile" />
            <SelectField label="Shipper branch" name="shipper_id" options={shippers} required emptyLabel="Select branch" />
            <SelectField label="Country / currency lane" name="country_id" options={countries.map((c) => ({ id: c.id, name: c.name, currency_code: c.currency_code }))} required emptyLabel="Select country" />
            <Field label="Profile name" name="profile_name" placeholder="Default export evidence profile" />
            <Field label="Exporter name" name="exporter_name" required />
            <TextArea label="Exporter address" name="exporter_address" required />
            <Field label="Exporter VAT number" name="exporter_vat_number" />
            <Field label="Movement consignee / receiving hub name" name="default_movement_consignee_name" required />
            <TextArea label="Movement consignee / receiving hub address" name="default_movement_consignee_address" required />
            <Field label="Notify party name" name="default_notify_party_name" />
            <TextArea label="Notify party address" name="default_notify_party_address" />
            <div className="md:col-span-2"><SubmitButton>Save export profile</SubmitButton></div>
          </form>
        </Panel>

        <Panel eyebrow="5. Existing user link" title="Link existing operator/user to importer as customer or importer">
          <form action={linkOperatorImporterAction} className="grid gap-4 md:grid-cols-2">
            <SelectField label="Existing operator/user" name="operator_id" options={operators.map((o) => ({ id: o.id, name: `${o.full_name} — ${o.email}${o.auth_user_id ? "" : " (no auth user)"}` }))} required emptyLabel="Select operator/user" />
            <SelectField label="Importer/customer branch" name="importer_id" options={importers} required emptyLabel="Select importer/customer" />
            <label className="flex flex-col gap-1 text-sm font-medium text-slate-700"><span>Portal role *</span><select name="role_code" required className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm"><option value="customer">customer</option><option value="importer">importer</option></select></label>
            <label className="flex flex-col gap-1 text-sm font-medium text-slate-700"><span>Relationship *</span><select name="relationship_type" required className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm"><option value="sole_owner">sole_owner</option><option value="authorised_user">authorised_user</option></select></label>
            <div className="md:col-span-2"><SubmitButton>Link existing user</SubmitButton></div>
          </form>
          <p className="mt-3 text-xs leading-5 text-slate-500">New auth user/password creation is intentionally not in this first page. This form links an existing operator/auth user safely.</p>
        </Panel>

        <Panel eyebrow="6. Supervisor scope" title="Assign supervisor visibility">
          <form action={setSupervisorScopeAction} className="grid gap-4">
            <SelectField label="Supervisor" name="supervisor_staff_id" options={supervisors.map((s) => ({ id: s.id, name: `${s.full_name} — ${s.email}` }))} required emptyLabel="Select supervisor" />
            <label className="flex flex-col gap-1 text-sm font-medium text-slate-700"><span>Scope mode *</span><select name="scope_mode" required className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm"><option value="all">all</option><option value="assigned">assigned</option></select></label>
            <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
              <p className="text-sm font-semibold">Assigned branches, only used when scope mode = assigned</p>
              <div className="mt-3 grid gap-2 md:grid-cols-2">
                {shippers.map((shipper) => (
                  <label key={shipper.id} className="flex items-center gap-2 rounded-xl bg-white px-3 py-2 text-sm ring-1 ring-slate-200">
                    <input type="checkbox" name="shipper_ids" value={shipper.id} />
                    <span>{shipper.name}</span>
                  </label>
                ))}
              </div>
            </div>
            <div><SubmitButton>Save supervisor scope</SubmitButton></div>
          </form>
        </Panel>

        <section className="grid gap-4 lg:grid-cols-2">
          <Panel eyebrow="Source blockers" title="Importer/customer delivery gaps">
            <pre className="max-h-96 overflow-auto rounded-2xl bg-slate-950 p-4 text-xs leading-5 text-white">{JSON.stringify(blockers.importers_missing_delivery_profile ?? [], null, 2)}</pre>
          </Panel>
          <Panel eyebrow="Source blockers" title="Shipper branch export profile gaps">
            <pre className="max-h-96 overflow-auto rounded-2xl bg-slate-950 p-4 text-xs leading-5 text-white">{JSON.stringify(blockers.shipper_branches_missing_export_profile ?? [], null, 2)}</pre>
          </Panel>
        </section>
      </div>
    </main>
  );
}
