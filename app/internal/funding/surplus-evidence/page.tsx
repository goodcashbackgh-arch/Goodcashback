import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { confirmSettlementSurplusCreditAction } from "../actions";

type Row = Record<string, string | number | null>;
type StaffRow = { role_type: string | null };
type SearchParams = { settlement_success?: string; settlement_error?: string };

function num(value: unknown) {
  const parsed = Number(value ?? 0);
  return Number.isFinite(parsed) ? parsed : 0;
}

function gbp(value: unknown) {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" }).format(num(value));
}

function label(value: unknown) {
  return String(value ?? "—").replaceAll("_", " ");
}

export default async function SurplusEvidencePage({ searchParams }: { searchParams?: Promise<SearchParams> }) {
  const params = searchParams ? await searchParams : {};
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

  const { data, error } = await supabase
    .from("order_surplus_evidence_position_v3")
    .select("order_id,order_ref,payment_auth_id,declared_order_gbp,funding_total_gbp,effective_receipt_gbp,pending_surplus_gbp,supplier_out_gbp,posted_invoice_gbp,draft_invoice_gbp,evidence_value_gbp,evidence_surplus_gbp,evidence_status,evidence_basis,open_dispute_count,active_hold_count")
    .in("evidence_status", ["ready_posted_invoice_surplus", "ready_draft_invoice_surplus", "ready_strong_in_out_surplus", "blocked_by_open_issue", "credit_created"])
    .order("evidence_surplus_gbp", { ascending: false });

  const rows = (data ?? []) as Row[];
  const ready = rows.filter((row) => String(row.evidence_status ?? "").startsWith("ready_") && num(row.evidence_surplus_gbp) > 0 && num(row.open_dispute_count) === 0 && num(row.active_hold_count) === 0);
  const blocked = rows.filter((row) => row.evidence_status === "blocked_by_open_issue");
  const other = rows.filter((row) => !ready.some((readyRow) => readyRow.order_id === row.order_id) && row.evidence_status !== "blocked_by_open_issue");

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto max-w-6xl space-y-5">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href="/internal/funding" className="text-sm font-semibold text-sky-700">Back to funding</Link>
          <p className="mt-6 text-sm font-black uppercase tracking-[0.22em] text-cyan-700">Surplus evidence</p>
          <h1 className="mt-2 text-3xl font-black">Confirm customer surplus</h1>
          <p className="mt-2 max-w-4xl text-sm text-slate-600">Expand one row only when you are ready to confirm it as available customer credit.</p>
        </section>

        {params.settlement_success ? <div className="rounded-2xl border border-emerald-200 bg-emerald-50 p-4 text-sm font-semibold text-emerald-900">{params.settlement_success}</div> : null}
        {params.settlement_error ? <div className="rounded-2xl border border-red-200 bg-red-50 p-4 text-sm font-semibold text-red-900">{params.settlement_error}</div> : null}
        {error ? <div className="rounded-2xl border border-red-200 bg-red-50 p-4 text-sm text-red-900">{error.message}</div> : null}

        <section className="grid gap-3 md:grid-cols-4">
          <div className="rounded-2xl border border-cyan-200 bg-cyan-50 p-4"><p className="text-xs font-black uppercase text-cyan-700">Ready</p><p className="mt-1 text-3xl font-black">{ready.length}</p></div>
          <div className="rounded-2xl border border-emerald-200 bg-emerald-50 p-4"><p className="text-xs font-black uppercase text-emerald-700">Ready value</p><p className="mt-1 text-3xl font-black">{gbp(ready.reduce((sum, row) => sum + num(row.evidence_surplus_gbp), 0))}</p></div>
          <div className="rounded-2xl border border-amber-200 bg-amber-50 p-4"><p className="text-xs font-black uppercase text-amber-700">Blocked</p><p className="mt-1 text-3xl font-black">{blocked.length}</p></div>
          <div className="rounded-2xl border border-slate-200 bg-white p-4"><p className="text-xs font-black uppercase text-slate-500">Other</p><p className="mt-1 text-3xl font-black">{other.length}</p></div>
        </section>

        <section className="space-y-3 rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div><h2 className="text-xl font-black">Ready to confirm</h2><p className="mt-1 text-sm text-slate-600">Rows are collapsed so the queue still works when 50+ items need review.</p></div>
            <Link href="/internal/funding" className="rounded-xl border border-slate-200 px-3 py-2 text-sm font-bold text-slate-700">Funding overview</Link>
          </div>

          {ready.length === 0 ? <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-600">No ready surplus evidence rows.</div> : null}

          {ready.map((row) => (
            <details key={String(row.order_id)} className="rounded-2xl border border-cyan-200 bg-cyan-50 shadow-sm">
              <summary className="cursor-pointer list-none p-4">
                <div className="grid gap-3 md:grid-cols-[1.2fr_0.7fr_0.7fr_0.7fr_auto] md:items-center">
                  <div><p className="text-xs font-black uppercase text-cyan-700">{label(row.evidence_basis)}</p><h3 className="text-lg font-black">{row.order_ref ?? row.order_id}</h3><p className="text-xs text-slate-600">Auth: {row.payment_auth_id ?? "—"}</p></div>
                  <div><p className="text-xs font-black uppercase text-slate-500">IN</p><p className="font-black">{gbp(row.effective_receipt_gbp)}</p></div>
                  <div><p className="text-xs font-black uppercase text-slate-500">Evidence</p><p className="font-black">{gbp(row.evidence_value_gbp)}</p></div>
                  <div><p className="text-xs font-black uppercase text-slate-500">Surplus</p><p className="font-black text-cyan-800">{gbp(row.evidence_surplus_gbp)}</p></div>
                  <span className="rounded-full bg-white px-3 py-1 text-xs font-black text-cyan-800 ring-1 ring-cyan-200">Review</span>
                </div>
              </summary>
              <div className="border-t border-cyan-100 p-4">
                <div className="grid gap-2 md:grid-cols-4">
                  <div className="rounded-xl bg-white p-3"><p className="text-xs font-black uppercase text-slate-500">Original</p><p className="font-black">{gbp(row.declared_order_gbp)}</p></div>
                  <div className="rounded-xl bg-white p-3"><p className="text-xs font-black uppercase text-slate-500">Supplier OUT</p><p className="font-black">{gbp(row.supplier_out_gbp)}</p></div>
                  <div className="rounded-xl bg-white p-3"><p className="text-xs font-black uppercase text-slate-500">Posted invoice</p><p className="font-black">{gbp(row.posted_invoice_gbp)}</p></div>
                  <div className="rounded-xl bg-white p-3"><p className="text-xs font-black uppercase text-slate-500">Draft invoice</p><p className="font-black">{gbp(row.draft_invoice_gbp)}</p></div>
                </div>
                <form action={confirmSettlementSurplusCreditAction} className="mt-4 grid gap-2 md:grid-cols-[1fr_1.5fr_auto]">
                  <input type="hidden" name="order_id" value={String(row.order_id)} />
                  <select name="reason" defaultValue="supervisor_confirmed_credit" className="rounded-xl border border-cyan-200 bg-white px-3 py-2 text-sm">
                    <option value="supervisor_confirmed_credit">Supervisor confirmed</option>
                    <option value="not_charged_closure">Not charged / not spent</option>
                    <option value="checkout_changed">Checkout changed</option>
                    <option value="discount_or_promo">Discount / promo</option>
                    <option value="item_removed_before_charge">Item removed before charge</option>
                    <option value="customer_hold_excluded">Customer hold excluded</option>
                  </select>
                  <input name="notes" className="rounded-xl border border-cyan-200 bg-white px-3 py-2 text-sm" defaultValue={`Effective receipt ${gbp(row.effective_receipt_gbp)} less evidence value ${gbp(row.evidence_value_gbp)} = ${gbp(row.evidence_surplus_gbp)}.`} />
                  <button className="rounded-xl bg-cyan-700 px-4 py-2 text-sm font-black text-white">Confirm balance</button>
                </form>
              </div>
            </details>
          ))}
        </section>

        <details className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
          <summary className="cursor-pointer text-xl font-black">Blocked / created / other · {blocked.length + other.length}</summary>
          <div className="mt-4 grid gap-2">
            {[...blocked, ...other].slice(0, 60).map((row) => (
              <div key={`${String(row.order_id)}-${String(row.evidence_status)}`} className="grid gap-2 rounded-xl bg-slate-50 p-3 text-sm md:grid-cols-[1fr_auto_auto]">
                <span className="font-bold">{row.order_ref ?? row.order_id}</span>
                <span>{label(row.evidence_status)}</span>
                <span>{gbp(row.evidence_surplus_gbp)}</span>
              </div>
            ))}
          </div>
        </details>
      </div>
    </main>
  );
}
