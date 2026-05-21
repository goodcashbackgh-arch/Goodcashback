import Link from "next/link";
import { createClient } from "@/utils/supabase/server";
import { confirmSettlementSurplusCreditAction } from "../actions";

type Row = {
  order_id: string;
  order_ref: string | null;
  payment_auth_id: string | null;
  declared_order_gbp: string | number | null;
  funding_total_gbp: string | number | null;
  supplier_out_gbp: string | number | null;
  posted_invoice_gbp: string | number | null;
  draft_invoice_gbp: string | number | null;
  evidence_value_gbp: string | number | null;
  evidence_surplus_gbp: string | number | null;
  evidence_status: string | null;
  evidence_basis: string | null;
  open_dispute_count: string | number | null;
  active_hold_count: string | number | null;
};

type SearchParams = { settlement_success?: string; settlement_error?: string };

function num(v: unknown) { const n = Number(v ?? 0); return Number.isFinite(n) ? n : 0; }
function gbp(v: unknown) { return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" }).format(num(v)); }
function label(v: string | null | undefined) { return v ? v.replaceAll("_", " ") : "—"; }

export default async function SurplusEvidencePage({ searchParams }: { searchParams?: Promise<SearchParams> }) {
  const params = searchParams ? await searchParams : {};
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("order_surplus_evidence_position_v1")
    .select("order_id,order_ref,payment_auth_id,declared_order_gbp,funding_total_gbp,supplier_out_gbp,posted_invoice_gbp,draft_invoice_gbp,evidence_value_gbp,evidence_surplus_gbp,evidence_status,evidence_basis,open_dispute_count,active_hold_count")
    .in("evidence_status", ["ready_posted_invoice_surplus", "ready_draft_invoice_surplus", "ready_strong_in_out_surplus", "blocked_by_open_issue", "credit_created"])
    .order("evidence_surplus_gbp", { ascending: false });

  const rows = (data ?? []) as Row[];
  const ready = rows.filter((r) => String(r.evidence_status).startsWith("ready_") && num(r.evidence_surplus_gbp) > 0 && num(r.open_dispute_count) === 0 && num(r.active_hold_count) === 0);
  const other = rows.filter((r) => !ready.some((x) => x.order_id === r.order_id));

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto max-w-6xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href="/internal/funding" className="text-sm font-semibold text-sky-700">Back to funding</Link>
          <p className="mt-6 text-sm font-black uppercase tracking-[0.22em] text-cyan-700">Surplus evidence</p>
          <h1 className="mt-2 text-3xl font-black">Confirm probable customer surplus</h1>
          <p className="mt-2 text-sm text-slate-600">Ready rows use posted invoice, draft invoice, or strong matched IN/OUT evidence. Once confirmed, the value becomes available ledger balance.</p>
        </section>

        {params.settlement_success ? <div className="rounded-2xl border border-emerald-200 bg-emerald-50 p-4 text-sm font-semibold text-emerald-900">{params.settlement_success}</div> : null}
        {params.settlement_error ? <div className="rounded-2xl border border-red-200 bg-red-50 p-4 text-sm font-semibold text-red-900">{params.settlement_error}</div> : null}
        {error ? <div className="rounded-2xl border border-red-200 bg-red-50 p-4 text-sm text-red-900">{error.message}</div> : null}

        <section className="grid gap-3 md:grid-cols-3">
          <div className="rounded-2xl border border-cyan-200 bg-cyan-50 p-4"><p className="text-xs font-black uppercase text-cyan-700">Ready</p><p className="mt-1 text-3xl font-black">{ready.length}</p></div>
          <div className="rounded-2xl border border-emerald-200 bg-emerald-50 p-4"><p className="text-xs font-black uppercase text-emerald-700">Ready value</p><p className="mt-1 text-3xl font-black">{gbp(ready.reduce((s, r) => s + num(r.evidence_surplus_gbp), 0))}</p></div>
          <div className="rounded-2xl border border-slate-200 bg-white p-4"><p className="text-xs font-black uppercase text-slate-500">Other evidence</p><p className="mt-1 text-3xl font-black">{other.length}</p></div>
        </section>

        <section className="space-y-4">
          {ready.length === 0 ? <div className="rounded-2xl border border-slate-200 bg-white p-4 text-sm text-slate-600">No ready surplus evidence rows.</div> : null}
          {ready.map((r) => (
            <article key={r.order_id} className="rounded-3xl border border-cyan-200 bg-cyan-50 p-5 shadow-sm">
              <div className="flex flex-wrap items-start justify-between gap-3">
                <div><h2 className="text-xl font-black">{r.order_ref ?? r.order_id}</h2><p className="mt-1 text-xs text-slate-600">Auth: {r.payment_auth_id ?? "—"} · Basis: {label(r.evidence_basis)} · Status: {label(r.evidence_status)}</p></div>
                <div className="rounded-full bg-cyan-100 px-3 py-1 text-xs font-black text-cyan-800">Surplus {gbp(r.evidence_surplus_gbp)}</div>
              </div>
              <div className="mt-4 grid gap-3 md:grid-cols-5">
                <div className="rounded-2xl bg-white p-3"><p className="text-xs font-black uppercase text-slate-500">Original</p><p className="font-black">{gbp(r.declared_order_gbp)}</p></div>
                <div className="rounded-2xl bg-white p-3"><p className="text-xs font-black uppercase text-slate-500">IN funding</p><p className="font-black">{gbp(r.funding_total_gbp)}</p></div>
                <div className="rounded-2xl bg-white p-3"><p className="text-xs font-black uppercase text-slate-500">OUT supplier</p><p className="font-black">{gbp(r.supplier_out_gbp)}</p></div>
                <div className="rounded-2xl bg-white p-3"><p className="text-xs font-black uppercase text-slate-500">Evidence value</p><p className="font-black">{gbp(r.evidence_value_gbp)}</p></div>
                <div className="rounded-2xl bg-white p-3"><p className="text-xs font-black uppercase text-slate-500">Surplus</p><p className="font-black text-cyan-800">{gbp(r.evidence_surplus_gbp)}</p></div>
              </div>
              <form action={confirmSettlementSurplusCreditAction} className="mt-4 grid gap-2 md:grid-cols-[1fr_1fr_auto]">
                <input type="hidden" name="order_id" value={r.order_id} />
                <select name="reason" defaultValue="supervisor_confirmed_credit" className="rounded-xl border border-cyan-200 bg-white px-3 py-2 text-sm">
                  <option value="supervisor_confirmed_credit">Supervisor confirmed</option>
                  <option value="not_charged_closure">Not charged / not spent</option>
                  <option value="checkout_changed">Checkout changed</option>
                  <option value="discount_or_promo">Discount / promo</option>
                  <option value="item_removed_before_charge">Item removed before charge</option>
                  <option value="customer_hold_excluded">Customer hold excluded</option>
                </select>
                <input name="notes" className="rounded-xl border border-cyan-200 bg-white px-3 py-2 text-sm" defaultValue={`Funding ${gbp(r.funding_total_gbp)} less evidence value ${gbp(r.evidence_value_gbp)} = ${gbp(r.evidence_surplus_gbp)}.`} />
                <button className="rounded-xl bg-cyan-700 px-4 py-2 text-sm font-black text-white">Confirm available balance</button>
              </form>
            </article>
          ))}
        </section>
      </div>
    </main>
  );
}
