"use client";

import Link from "next/link";
import { useMemo, useState } from "react";
import {
  linkOperatorImporterAction,
  setSupervisorScopeAction,
  upsertExportEvidenceProfileAction,
  upsertImporterBranchAction,
  upsertImporterDeliveryProfileAction,
  upsertShipperBranchAction,
} from "./actions";
import Notice from "./notice";

type Country = { id: string; name: string; currency_code?: string };
type Shipper = { id: string; name: string; contact_email?: string | null; contact_phone?: string | null; vat_treatment?: string | null; vat_registration_country?: string | null; countries?: { country_id: string; country_name: string; currency_code?: string }[] };
type Importer = { id: string; importer_name: string; company_name: string; trading_name?: string | null; address?: string | null; shipper_id: string; country_id: string; delivery_profile?: any };
type Operator = { id: string; full_name: string; email: string; auth_user_id?: string | null };
type ExportProfile = { id: string; shipper_id?: string | null; country_id?: string | null; profile_name?: string | null; exporter_name?: string | null; exporter_address?: string | null; exporter_vat_number?: string | null; default_movement_consignee_name?: string | null; default_movement_consignee_address?: string | null; default_notify_party_name?: string | null; default_notify_party_address?: string | null };
type Supervisor = { id: string; full_name: string; email: string; scope_mode?: string | null };

type Props = {
  staff: { full_name: string; role_type: string };
  countries: Country[];
  shippers: Shipper[];
  importers: Importer[];
  operators: Operator[];
  exportProfiles: ExportProfile[];
  supervisors: Supervisor[];
  blockers: any;
  savedMessage?: string | null;
};

function Field({ label, name, required, value, placeholder }: { label: string; name: string; required?: boolean; value?: string | null; placeholder?: string }) {
  return (
    <label className="flex flex-col gap-1 text-sm font-medium text-slate-700">
      <span>{label}{required ? " *" : ""}</span>
      <input name={name} required={required} defaultValue={value ?? ""} placeholder={placeholder} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm text-slate-950 shadow-sm outline-none focus:border-sky-500" />
    </label>
  );
}

function TextArea({ label, name, required, value }: { label: string; name: string; required?: boolean; value?: string | null }) {
  return (
    <label className="flex flex-col gap-1 text-sm font-medium text-slate-700 md:col-span-2">
      <span>{label}{required ? " *" : ""}</span>
      <textarea name={name} required={required} defaultValue={value ?? ""} rows={3} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm text-slate-950 shadow-sm outline-none focus:border-sky-500" />
    </label>
  );
}

function Panel({ eyebrow, title, note, children }: { eyebrow: string; title: string; note?: string; children: React.ReactNode }) {
  return (
    <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
      <p className="text-xs font-bold uppercase tracking-[0.2em] text-sky-600">{eyebrow}</p>
      <h2 className="mt-2 text-xl font-semibold tracking-tight text-slate-950">{title}</h2>
      {note ? <p className="mt-2 text-sm leading-6 text-slate-600">{note}</p> : null}
      <div className="mt-5">{children}</div>
    </section>
  );
}

function Button({ children }: { children: React.ReactNode }) {
  return <button className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800">{children}</button>;
}

export default function OnboardingWorkspace({ staff, countries, shippers, importers, operators, exportProfiles, supervisors, blockers, savedMessage }: Props) {
  const [shipperId, setShipperId] = useState("");
  const [importerId, setImporterId] = useState("");
  const [deliveryImporterId, setDeliveryImporterId] = useState("");
  const [exportShipperId, setExportShipperId] = useState("");
  const [exportCountryId, setExportCountryId] = useState("");
  const [scopeMode, setScopeMode] = useState("all");

  const selectedShipper = shippers.find((item) => item.id === shipperId);
  const selectedImporter = importers.find((item) => item.id === importerId);
  const selectedDeliveryImporter = importers.find((item) => item.id === deliveryImporterId);

  const matchingExportProfile = useMemo(
    () => exportProfiles.find((item) => item.shipper_id === exportShipperId && item.country_id === exportCountryId),
    [exportProfiles, exportShipperId, exportCountryId]
  );

  const deliveryGaps = blockers?.importers_missing_delivery_profile ?? [];
  const exportGaps = blockers?.shipper_branches_missing_export_profile ?? [];

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-7xl space-y-6">
        <Notice message={savedMessage} />

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
              <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">One efficient control surface for branch setup, importer/customer setup, source profiles, role memberships and supervisor scope. Login routing is still legacy-safe and unchanged.</p>
            </div>
            <div className="rounded-2xl border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-950">
              <div className="font-semibold">Enforcement off</div>
              <div>{staff.full_name} · {staff.role_type}</div>
            </div>
          </div>
        </section>

        <section className="grid gap-4 md:grid-cols-4">
          <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Shipper branches</p><p className="mt-1 text-3xl font-semibold">{shippers.length}</p></div>
          <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Importer/customers</p><p className="mt-1 text-3xl font-semibold">{importers.length}</p></div>
          <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Delivery gaps</p><p className="mt-1 text-3xl font-semibold">{deliveryGaps.length}</p></div>
          <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Export profile gaps</p><p className="mt-1 text-3xl font-semibold">{exportGaps.length}</p></div>
        </section>

        <Panel eyebrow="1. Branch setup" title="Create or update shipping-company branch" note="Select an existing branch to edit it. The country/currency lane is the MVP branch lane.">
          <form action={upsertShipperBranchAction} className="grid gap-4 md:grid-cols-2">
            <label className="flex flex-col gap-1 text-sm font-medium text-slate-700">
              <span>Existing branch</span>
              <select name="shipper_id" value={shipperId} onChange={(event) => setShipperId(event.target.value)} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm">
                <option value="">Create new branch</option>
                {shippers.map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}
              </select>
            </label>
            <label className="flex flex-col gap-1 text-sm font-medium text-slate-700">
              <span>Country / currency lane *</span>
              <select name="country_id" required defaultValue={selectedShipper?.countries?.[0]?.country_id ?? ""} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm">
                <option value="">Select country</option>
                {countries.map((item) => <option key={item.id} value={item.id}>{item.name}{item.currency_code ? ` (${item.currency_code})` : ""}</option>)}
              </select>
            </label>
            <Field label="Branch / shipper name" name="name" required value={selectedShipper?.name} placeholder="Jobyco Ghana" />
            <Field label="Contact email" name="contact_email" value={selectedShipper?.contact_email} />
            <Field label="Contact phone" name="contact_phone" value={selectedShipper?.contact_phone} />
            <Field label="VAT treatment" name="vat_treatment" value={selectedShipper?.vat_treatment} />
            <Field label="VAT registration country" name="vat_registration_country" value={selectedShipper?.vat_registration_country} />
            <div className="md:col-span-2"><Button>Save branch</Button></div>
          </form>
        </Panel>

        <Panel eyebrow="2. Importer/customer branch" title="Create or update importer/customer" note="Importer/customer inherits its shipper branch and country/currency lane here.">
          <form action={upsertImporterBranchAction} className="grid gap-4 md:grid-cols-2">
            <label className="flex flex-col gap-1 text-sm font-medium text-slate-700"><span>Existing importer/customer</span><select name="importer_id" value={importerId} onChange={(event) => setImporterId(event.target.value)} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm"><option value="">Create new importer/customer</option>{importers.map((item) => <option key={item.id} value={item.id}>{item.importer_name}</option>)}</select></label>
            <label className="flex flex-col gap-1 text-sm font-medium text-slate-700"><span>Assigned shipper branch *</span><select name="shipper_id" required defaultValue={selectedImporter?.shipper_id ?? ""} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm"><option value="">Select branch</option>{shippers.map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}</select></label>
            <label className="flex flex-col gap-1 text-sm font-medium text-slate-700"><span>Country / currency lane *</span><select name="country_id" required defaultValue={selectedImporter?.country_id ?? ""} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm"><option value="">Select country</option>{countries.map((item) => <option key={item.id} value={item.id}>{item.name}{item.currency_code ? ` (${item.currency_code})` : ""}</option>)}</select></label>
            <Field label="Legal/customer name" name="company_name" required value={selectedImporter?.company_name} />
            <Field label="Trading/display name" name="trading_name" value={selectedImporter?.trading_name} />
            <TextArea label="Business/customer address" name="address" value={selectedImporter?.address} />
            <div className="md:col-span-2"><Button>Save importer/customer</Button></div>
          </form>
        </Panel>

        <Panel eyebrow="3. Delivery source profile" title="Final recipient details" note="Select the importer/customer once. Existing saved details appear for editing.">
          <form action={upsertImporterDeliveryProfileAction} className="grid gap-4 md:grid-cols-2">
            <label className="flex flex-col gap-1 text-sm font-medium text-slate-700 md:col-span-2"><span>Importer/customer *</span><select name="importer_id" required value={deliveryImporterId} onChange={(event) => setDeliveryImporterId(event.target.value)} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm"><option value="">Select importer/customer</option>{importers.map((item) => <option key={item.id} value={item.id}>{item.importer_name}</option>)}</select></label>
            <Field label="Final recipient name" name="final_recipient_name" required value={selectedDeliveryImporter?.delivery_profile?.final_recipient_name ?? selectedDeliveryImporter?.importer_name} />
            <Field label="Address line 1" name="final_recipient_address_line_1" required value={selectedDeliveryImporter?.delivery_profile?.final_recipient_address_line_1} />
            <Field label="Country" name="final_recipient_country" required value={selectedDeliveryImporter?.delivery_profile?.final_recipient_country} />
            <Field label="Phone" name="final_recipient_phone" value={selectedDeliveryImporter?.delivery_profile?.final_recipient_phone} />
            <Field label="Email" name="final_recipient_email" value={selectedDeliveryImporter?.delivery_profile?.final_recipient_email} />
            <div className="md:col-span-2"><Button>Save delivery profile</Button></div>
          </form>
        </Panel>

        <Panel eyebrow="4. Export source profile" title="Exporter, receiving hub and notify party" note="No random profile selection. Pick branch and country; the system updates that profile or creates it if missing.">
          <form action={upsertExportEvidenceProfileAction} className="grid gap-4 md:grid-cols-2">
            <input type="hidden" name="profile_id" value={matchingExportProfile?.id ?? ""} />
            <label className="flex flex-col gap-1 text-sm font-medium text-slate-700"><span>Shipper branch *</span><select name="shipper_id" required value={exportShipperId} onChange={(event) => setExportShipperId(event.target.value)} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm"><option value="">Select branch</option>{shippers.map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}</select></label>
            <label className="flex flex-col gap-1 text-sm font-medium text-slate-700"><span>Country / currency lane *</span><select name="country_id" required value={exportCountryId} onChange={(event) => setExportCountryId(event.target.value)} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm"><option value="">Select country</option>{countries.map((item) => <option key={item.id} value={item.id}>{item.name}{item.currency_code ? ` (${item.currency_code})` : ""}</option>)}</select></label>
            <Field label="Profile name" name="profile_name" value={matchingExportProfile?.profile_name ?? "Default export evidence profile"} />
            <Field label="Exporter name" name="exporter_name" required value={matchingExportProfile?.exporter_name} />
            <TextArea label="Exporter address" name="exporter_address" required value={matchingExportProfile?.exporter_address} />
            <Field label="Exporter VAT number" name="exporter_vat_number" value={matchingExportProfile?.exporter_vat_number} />
            <Field label="Movement consignee / receiving hub name" name="default_movement_consignee_name" required value={matchingExportProfile?.default_movement_consignee_name} />
            <TextArea label="Movement consignee / receiving hub address" name="default_movement_consignee_address" required value={matchingExportProfile?.default_movement_consignee_address} />
            <Field label="Notify party name" name="default_notify_party_name" value={matchingExportProfile?.default_notify_party_name} />
            <TextArea label="Notify party address" name="default_notify_party_address" value={matchingExportProfile?.default_notify_party_address} />
            <div className="md:col-span-2"><Button>Save export profile</Button></div>
          </form>
        </Panel>

        <Panel eyebrow="5. Existing user link" title="Link existing user once" note="Select one or both portal roles. This saves customer and importer memberships in one action.">
          <form action={linkOperatorImporterAction} className="grid gap-4 md:grid-cols-2">
            <label className="flex flex-col gap-1 text-sm font-medium text-slate-700"><span>Existing operator/user *</span><select name="operator_id" required className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm"><option value="">Select operator/user</option>{operators.map((item) => <option key={item.id} value={item.id}>{item.full_name} — {item.email}{item.auth_user_id ? "" : " (no auth user)"}</option>)}</select></label>
            <label className="flex flex-col gap-1 text-sm font-medium text-slate-700"><span>Importer/customer branch *</span><select name="importer_id" required className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm"><option value="">Select importer/customer</option>{importers.map((item) => <option key={item.id} value={item.id}>{item.importer_name}</option>)}</select></label>
            <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4 md:col-span-2"><p className="text-sm font-semibold text-slate-800">Portal roles *</p><div className="mt-3 grid gap-2 sm:grid-cols-2"><label className="flex items-center gap-2 rounded-xl bg-white px-3 py-2 text-sm ring-1 ring-slate-200"><input type="checkbox" name="role_codes" value="customer" defaultChecked /> Customer</label><label className="flex items-center gap-2 rounded-xl bg-white px-3 py-2 text-sm ring-1 ring-slate-200"><input type="checkbox" name="role_codes" value="importer" defaultChecked /> Importer</label></div></div>
            <label className="flex flex-col gap-1 text-sm font-medium text-slate-700"><span>Relationship *</span><select name="relationship_type" required className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm"><option value="sole_owner">sole_owner</option><option value="authorised_user">authorised_user</option></select></label>
            <div className="md:col-span-2"><Button>Link existing user</Button></div>
          </form>
        </Panel>

        <Panel eyebrow="6. Supervisor scope" title="Assign supervisor visibility" note="All-mode preserves current visibility. Assigned-mode limits the supervisor to selected shipper branches.">
          <form action={setSupervisorScopeAction} className="grid gap-4">
            <label className="flex flex-col gap-1 text-sm font-medium text-slate-700"><span>Supervisor *</span><select name="supervisor_staff_id" required className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm"><option value="">Select supervisor</option>{supervisors.map((item) => <option key={item.id} value={item.id}>{item.full_name} — {item.email}</option>)}</select></label>
            <label className="flex flex-col gap-1 text-sm font-medium text-slate-700"><span>Scope mode *</span><select name="scope_mode" required value={scopeMode} onChange={(event) => setScopeMode(event.target.value)} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm"><option value="all">all</option><option value="assigned">assigned</option></select></label>
            {scopeMode === "assigned" ? <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4"><p className="text-sm font-semibold">Assigned branches</p><div className="mt-3 grid gap-2 md:grid-cols-2">{shippers.map((item) => <label key={item.id} className="flex items-center gap-2 rounded-xl bg-white px-3 py-2 text-sm ring-1 ring-slate-200"><input type="checkbox" name="shipper_ids" value={item.id} /> {item.name}</label>)}</div></div> : null}
            <div><Button>Save supervisor scope</Button></div>
          </form>
        </Panel>

        <section className="grid gap-4 lg:grid-cols-2">
          <Panel eyebrow="Source blockers" title="Importer/customer delivery gaps"><pre className="max-h-96 overflow-auto rounded-2xl bg-slate-950 p-4 text-xs leading-5 text-white">{JSON.stringify(deliveryGaps, null, 2)}</pre></Panel>
          <Panel eyebrow="Source blockers" title="Shipper branch export profile gaps"><pre className="max-h-96 overflow-auto rounded-2xl bg-slate-950 p-4 text-xs leading-5 text-white">{JSON.stringify(exportGaps, null, 2)}</pre></Panel>
        </section>
      </div>
    </main>
  );
}
