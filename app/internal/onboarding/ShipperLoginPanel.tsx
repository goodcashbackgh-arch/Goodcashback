"use client";

import { useActionState } from "react";
import {
  createNewShipperOnboardingAction,
  type NewShipperOnboardingState,
} from "./shipper-login-actions";

type Shipper = { id: string; name: string };

type Props = {
  shippers: Shipper[];
};

const initialState: NewShipperOnboardingState = { status: "idle" };

export default function ShipperLoginPanel({ shippers }: Props) {
  const [state, action, pending] = useActionState(
    createNewShipperOnboardingAction,
    initialState,
  );

  return (
    <section className="mx-auto max-w-7xl rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
      <p className="text-xs font-bold uppercase tracking-[0.2em] text-sky-600">5C. Shipper user login</p>
      <h2 className="mt-2 text-xl font-semibold tracking-tight text-slate-950">Create new shipper login</h2>
      <p className="mt-2 text-sm leading-6 text-slate-600">
        For genuinely new shipper users only. This uses the same temporary-password and first-login password-change flow as other platform logins.
      </p>

      <form action={action} className="mt-5 grid gap-4 md:grid-cols-2">
        <label className="flex flex-col gap-1 text-sm font-medium text-slate-700">
          <span>Full name *</span>
          <input name="full_name" required className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm text-slate-950 shadow-sm outline-none focus:border-sky-500" />
        </label>

        <label className="flex flex-col gap-1 text-sm font-medium text-slate-700">
          <span>Email *</span>
          <input name="email" type="email" required className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm text-slate-950 shadow-sm outline-none focus:border-sky-500" />
        </label>

        <label className="flex flex-col gap-1 text-sm font-medium text-slate-700">
          <span>Phone</span>
          <input name="phone" className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm text-slate-950 shadow-sm outline-none focus:border-sky-500" />
        </label>

        <label className="flex flex-col gap-1 text-sm font-medium text-slate-700">
          <span>Shipper branch *</span>
          <select name="shipper_id" required className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm">
            <option value="">Select shipper branch</option>
            {shippers.map((shipper) => (
              <option key={shipper.id} value={shipper.id}>{shipper.name}</option>
            ))}
          </select>
        </label>

        <label className="flex flex-col gap-1 text-sm font-medium text-slate-700 md:col-span-2">
          <span>Access level *</span>
          <select name="role_code" required defaultValue="shipper_operator" className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm md:max-w-md">
            <option value="shipper_operator">Operator</option>
            <option value="shipper_admin">Admin</option>
            <option value="shipper_readonly">Read only</option>
          </select>
        </label>

        <div className="md:col-span-2">
          <button disabled={pending} className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800 disabled:cursor-not-allowed disabled:opacity-60">
            {pending ? "Creating shipper login…" : "Create shipper login"}
          </button>
        </div>
      </form>

      {state.status === "error" ? (
        <div className="mt-4 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-950">{state.message}</div>
      ) : null}

      {state.status === "success" ? (
        <div className="mt-4 rounded-2xl border border-emerald-200 bg-emerald-50 p-4 text-sm text-emerald-950">
          <p className="font-semibold">Login created — copy these details now</p>
          <p className="mt-1">{state.message}</p>
          <dl className="mt-4 grid gap-3 sm:grid-cols-2">
            <div className="rounded-xl bg-white p-3 ring-1 ring-emerald-200">
              <dt className="text-xs font-semibold uppercase tracking-wide text-emerald-700">Email</dt>
              <dd className="mt-1 break-all font-mono text-sm">{state.email}</dd>
            </div>
            <div className="rounded-xl bg-white p-3 ring-1 ring-emerald-200">
              <dt className="text-xs font-semibold uppercase tracking-wide text-emerald-700">Temporary password</dt>
              <dd className="mt-1 break-all font-mono text-sm">{state.temporaryPassword}</dd>
            </div>
          </dl>
          <p className="mt-3 text-xs font-medium">This password disappears when this page is refreshed or another onboarding attempt replaces this result.</p>
        </div>
      ) : null}
    </section>
  );
}
