import type { ReactNode } from "react";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { FundingLifecycleNav } from "./FundingLifecycleNav";

type DataRow = Record<string, unknown>;

type StaffRow = { role_type: string | null };

function amount(value: unknown) {
  const parsed = Number(value ?? 0);
  return Number.isFinite(parsed) ? parsed : 0;
}

function gbp(value: unknown) {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP", minimumFractionDigits: 2 }).format(amount(value));
}

export default async function FundingLayout({ children }: { children: ReactNode }) {
  const supabase = await createClient();

  const { data: authData } = await supabase.auth.getUser();
  const userId = authData.user?.id;
  if (!userId) redirect("/login");

  const { data: staffData, error: staffError } = await supabase
    .from("staff")
    .select("role_type")
    .eq("auth_user_id", userId)
    .eq("active", true)
    .maybeSingle();

  const staff = staffData as StaffRow | null;
  if (staffError || !staff || !["admin", "supervisor"].includes(String(staff.role_type))) redirect("/internal");

  const [{ data: surplusRows, error: surplusError }, { data: creditRows }] = await Promise.all([
    supabase
      .from("order_surplus_evidence_position_v3")
      .select("order_id,evidence_status,evidence_surplus_gbp,open_dispute_count,active_hold_count")
      .in("evidence_status", ["ready_posted_invoice_surplus", "ready_draft_invoice_surplus", "ready_strong_in_out_surplus", "blocked_by_open_issue", "credit_created"])
      .limit(500),
    supabase.from("importer_balance_vw").select("available_credit_gbp").limit(200),
  ]);

  const rows = (surplusRows ?? []) as DataRow[];
  const readyRows = rows.filter(
    (row) =>
      String(row.evidence_status ?? "").startsWith("ready_") &&
      amount(row.evidence_surplus_gbp) > 0 &&
      amount(row.open_dispute_count) === 0 &&
      amount(row.active_hold_count) === 0,
  );
  const blockedRows = rows.filter((row) => row.evidence_status === "blocked_by_open_issue");
  const createdRows = rows.filter((row) => row.evidence_status === "credit_created");
  const readyValue = readyRows.reduce((sum, row) => sum + amount(row.evidence_surplus_gbp), 0);
  const availableCredit = ((creditRows ?? []) as DataRow[]).reduce((sum, row) => sum + amount(row.available_credit_gbp), 0);

  return (
    <>
      <section className="bg-slate-50 px-6 pt-6 text-slate-950">
        <div className="mx-auto max-w-7xl rounded-3xl border border-cyan-200 bg-white p-5 shadow-sm">
          <div>
            <p className="text-sm font-black uppercase tracking-[0.22em] text-cyan-700">Credit lifecycle</p>
            <h2 className="mt-2 text-2xl font-black">Confirm surplus credit, then auto-apply confirmed credit</h2>
            <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">
              Surplus evidence creates confirmed customer credit. Confirmed credit is the spendable balance used against new order funding gaps.
            </p>
            <FundingLifecycleNav />
          </div>

          {surplusError ? (
            <div className="mt-4 rounded-2xl border border-amber-200 bg-amber-50 p-3 text-sm font-semibold text-amber-900">
              Surplus evidence view is not available yet: {surplusError.message}
            </div>
          ) : null}

          <div className="mt-5 grid gap-3 md:grid-cols-4">
            <div className="rounded-2xl border border-cyan-200 bg-cyan-50 p-4">
              <p className="text-xs font-black uppercase text-cyan-700">Ready surplus</p>
              <p className="mt-1 text-3xl font-black">{readyRows.length}</p>
              <p className="mt-1 text-xs text-slate-600">Needs supervisor confirmation.</p>
            </div>
            <div className="rounded-2xl border border-emerald-200 bg-emerald-50 p-4">
              <p className="text-xs font-black uppercase text-emerald-700">Ready surplus value</p>
              <p className="mt-1 text-3xl font-black">{gbp(readyValue)}</p>
              <p className="mt-1 text-xs text-slate-600">Becomes spendable after confirmation.</p>
            </div>
            <div className="rounded-2xl border border-sky-200 bg-sky-50 p-4">
              <p className="text-xs font-black uppercase text-sky-700">Available credit</p>
              <p className="mt-1 text-3xl font-black">{gbp(availableCredit)}</p>
              <p className="mt-1 text-xs text-slate-600">Spendable against order gaps.</p>
            </div>
            <div className="rounded-2xl border border-amber-200 bg-amber-50 p-4">
              <p className="text-xs font-black uppercase text-amber-700">Blocked / created</p>
              <p className="mt-1 text-3xl font-black">{blockedRows.length} / {createdRows.length}</p>
              <p className="mt-1 text-xs text-slate-600">Audit, not action queue.</p>
            </div>
          </div>
        </div>
      </section>
      {children}
    </>
  );
}
