"use client";

import { useMemo, useState } from "react";
import { upsertRetailerAccountAction } from "./retailer-account-actions";

type Lane = {
  shipper_id: string;
  shipper_name: string;
  retailer_id: string;
  retailer_name: string;
  active_account_count: number;
  active_account_id?: string | null;
  readiness: string;
};

type Account = {
  id: string;
  shipper_id: string;
  retailer_id: string;
  account_email: string;
  account_username?: string | null;
  credentials_vault_ref?: string | null;
  credential_delivery_method: string;
  delivery_address_locked_to_hub_id: string;
  delivery_hub_name?: string | null;
  card_last_4?: string | null;
  card_vault_ref?: string | null;
  status: string;
};

type Hub = { id: string; shipper_id: string; name: string; full_address: string; postcode?: string | null };

type Props = { data: { lanes?: Lane[]; accounts?: Account[]; hubs?: Hub[] } };

export default function RetailerAccountReadinessPanel({ data }: Props) {
  const lanes = data.lanes ?? [];
  const accounts = data.accounts ?? [];
  const hubs = data.hubs ?? [];
  const [laneKey, setLaneKey] = useState("");
  const [accountId, setAccountId] = useState("");

  const selectedLane = lanes.find((lane) => `${lane.shipper_id}:${lane.retailer_id}` === laneKey);
  const laneAccounts = useMemo(
    () => selectedLane ? accounts.filter((account) => account.shipper_id === selectedLane.shipper_id && account.retailer_id === selectedLane.retailer_id) : [],
    [accounts, selectedLane],
  );
  const selectedAccount = laneAccounts.find((account) => account.id === accountId);
  const laneHubs = selectedLane ? hubs.filter((hub) => hub.shipper_id === selectedLane.shipper_id) : [];

  return (
    <section className="mx-auto mt-6 max-w-7xl rounded-3xl border border-slate-200 bg-white p-5 text-slate-950 shadow-sm sm:p-6">
      <p className="text-xs font-bold uppercase tracking-[0.2em] text-sky-600">Patch E · Retailer-account readiness</p>
      <h2 className="mt-2 text-xl font-semibold tracking-tight">Create or maintain retailer account</h2>
      <p className="mt-2 text-sm leading-6 text-slate-600">An enabled shipper + retailer lane is ready only when it resolves to exactly one active retailer account. Missing accounts are shown as not ready; they are not auto-created.</p>

      <div className="mt-5 grid gap-4 md:grid-cols-3">
        <label className="flex flex-col gap-1 text-sm font-medium text-slate-700 md:col-span-2">
          <span>Enabled shipper + retailer lane *</span>
          <select value={laneKey} onChange={(event) => { setLaneKey(event.target.value); setAccountId(""); }} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm">
            <option value="">Select lane</option>
            {lanes.map((lane) => (
              <option key={`${lane.shipper_id}:${lane.retailer_id}`} value={`${lane.shipper_id}:${lane.retailer_id}`}>
                {lane.shipper_name} → {lane.retailer_name} — {lane.readiness === "ready" ? "READY" : "NOT READY"}
              </option>
            ))}
          </select>
        </label>
        <div className={`rounded-2xl border p-3 text-sm ${selectedLane?.readiness === "ready" ? "border-emerald-200 bg-emerald-50 text-emerald-950" : "border-amber-200 bg-amber-50 text-amber-950"}`}>
          <div className="font-semibold">Readiness</div>
          <div className="mt-1">{selectedLane ? (selectedLane.readiness === "ready" ? "Ready — exactly one active account" : "Not ready — active account required") : "Select a lane"}</div>
        </div>
      </div>

      {selectedLane ? (
        <form action={upsertRetailerAccountAction} className="mt-5 grid gap-4 md:grid-cols-2">
          <input type="hidden" name="shipper_id" value={selectedLane.shipper_id} />
          <input type="hidden" name="retailer_id" value={selectedLane.retailer_id} />

          <label className="flex flex-col gap-1 text-sm font-medium text-slate-700 md:col-span-2">
            <span>Existing account</span>
            <select name="retailer_account_id" value={accountId} onChange={(event) => setAccountId(event.target.value)} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm">
              <option value="">Create new account for this lane</option>
              {laneAccounts.map((account) => <option key={account.id} value={account.id}>{account.account_email} — {account.status}</option>)}
            </select>
          </label>

          <label className="flex flex-col gap-1 text-sm font-medium text-slate-700"><span>Account email *</span><input name="account_email" required defaultValue={selectedAccount?.account_email ?? ""} key={`email-${selectedAccount?.id ?? "new"}`} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm" /></label>
          <label className="flex flex-col gap-1 text-sm font-medium text-slate-700"><span>Account username</span><input name="account_username" defaultValue={selectedAccount?.account_username ?? ""} key={`user-${selectedAccount?.id ?? "new"}`} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm" /></label>
          <label className="flex flex-col gap-1 text-sm font-medium text-slate-700"><span>Credential delivery method *</span><select name="credential_delivery_method" defaultValue={selectedAccount?.credential_delivery_method ?? "pending_vault_upgrade"} key={`method-${selectedAccount?.id ?? "new"}`} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm"><option value="pending_vault_upgrade">pending_vault_upgrade</option><option value="vault_brokered">vault_brokered</option><option value="shared_direct">shared_direct</option></select></label>
          <label className="flex flex-col gap-1 text-sm font-medium text-slate-700"><span>Status *</span><select name="status" defaultValue={selectedAccount?.status ?? "active"} key={`status-${selectedAccount?.id ?? "new"}`} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm"><option value="active">active</option><option value="suspended">suspended</option><option value="locked_out">locked_out</option></select></label>
          <label className="flex flex-col gap-1 text-sm font-medium text-slate-700 md:col-span-2"><span>Delivery hub *</span><select name="delivery_address_locked_to_hub_id" required defaultValue={selectedAccount?.delivery_address_locked_to_hub_id ?? ""} key={`hub-${selectedAccount?.id ?? "new"}`} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm"><option value="">Select active hub for this shipper</option>{laneHubs.map((hub) => <option key={hub.id} value={hub.id}>{hub.name} — {hub.full_address}</option>)}</select></label>
          <label className="flex flex-col gap-1 text-sm font-medium text-slate-700"><span>Credentials vault reference</span><input name="credentials_vault_ref" defaultValue={selectedAccount?.credentials_vault_ref ?? ""} key={`cred-${selectedAccount?.id ?? "new"}`} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm" /></label>
          <label className="flex flex-col gap-1 text-sm font-medium text-slate-700"><span>Card vault reference</span><input name="card_vault_ref" defaultValue={selectedAccount?.card_vault_ref ?? ""} key={`cardref-${selectedAccount?.id ?? "new"}`} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm" /></label>
          <label className="flex flex-col gap-1 text-sm font-medium text-slate-700"><span>Card last 4</span><input name="card_last_4" inputMode="numeric" maxLength={4} defaultValue={selectedAccount?.card_last_4 ?? ""} key={`card4-${selectedAccount?.id ?? "new"}`} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm" /></label>

          <div className="md:col-span-2"><button className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800">Save retailer account</button></div>
        </form>
      ) : null}
    </section>
  );
}
