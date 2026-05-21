import Link from "next/link";
import { createClient } from "@/utils/supabase/server";
import { confirmSettlementSurplusCreditAction } from "../actions";

type SettlementRow = {
  order_id: string;
  order_ref: string | null;
  importer_id: string | null;
  declared_order_gbp: number | string | null;
  funding_total_gbp: number | string | null;
  posted_customer_invoice_gbp: number | string | null;
  funding_less_posted_invoice_gbp: number | string | null;
  settlement_credit_created_gbp: number | string | null;
  settlement_status: string | null;
};

type SearchParams = {
  settlement_success?: string;
  settlement_error?: string;
};

function n(value: unknown) {
  const parsed = Number(value ?? 0);
  return Number.isFinite(parsed) ? parsed : 0;
}

function gbp(value: unknown) {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP", minimumFractionDigits: 2 }).format(n(value));
}

export default async function SettlementSurplusPage({ searchParams }: { searchParams?: Promise<SearchParams> }) {
  const params = searchParams ? await searchParams : {};
  const supabase = await createClient();

  const { data: rows, error } = await supabase
    .from("order_settlement_credit_position_v1")
    .select("order_id, order_ref, importer_id, declared_order_gbp, funding_total_gbp, posted_customer_invoice_gbp, funding_less_posted_invoice_gbp, settlement_credit_created_gbp, settlement_status")
    .in("settlement_status", ["credit_due", "credit_created"])
    .order("funding_less_posted_invoice_gbp", { ascending: false });

  const allRows = (rows ?? []) as SettlementRow[];
  const readyRows = allRows.filter((row) => row.settlement_status === "credit_due" && n(row.settlement_credit_created_gbp) === 0 && n(row.posted_customer_invoice_gbp) > 0 && n(row.funding_less_posted_invoice_gbp) > 0);
  const auditRows = allRows.filter((row) => row.settlement_status === "credit_created" || n(row.settlement_credit_created_gbp) > 0);

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto flex max-w-6xl flex-col gap-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href="/internal/funding" className="text-sm font-semibold text-sky-700">Back to funding</Link>
          <p className="mt-6 text-sm font-black uppercase tracking-[0.22em] text-cyan-600">Funding settlement surplus</p>
          <h1 className="mt-2 text-3xl font-black">Convert overfunding to customer credit</h1>
          <p className="mt-3 max-w-4xl text-sm leading-6 text-slate-600">
            This is for orders where customer/importer funding is already matched, final customer invoice exists, and funding exceeds the posted final invoice. Supervisor rec remains the place for correcting invoice accounting; this page closes the funding surplus.
          </p>
        </section>

        {params.settlement_success ? <section className="rounded-2xl border border-emerald-200 bg-emerald-50 p-4 text-sm font-semibold text-emerald-900">{params.settlement_success}</section> : null}
        {params.settlement_error ? <section className="rounded-2xl border border-red-200 bg-red-50 p-4 text-sm font-semibold text-red-900">{params.settlement_error}</section> : null}
        {error ? <section className="rounded-2xl border border-red-200 bg-red-50 p-4 text-sm text-red-900">{error.message}</section> : null}

        <section className="grid gap-3 md:grid-cols-3">
          <div className="rounded-2xl border border-cyan-200 bg-cyan-50 p-4"><p className="text-xs font-black uppercase text-cyan-700">Ready surplus</p><p className="mt-1 text-3xl font-black">{readyRows.length}</p></div>
          <div className="rounded-2xl border border-emerald-200 bg-emerald-50 p-4"><p className="text-xs font-black uppercase text-emerald-700">Total ready credit</p><p className="mt-1 text-3xl font-black">{gbp(readyRows.reduce((sum, row) => sum + n(row.funding_less_posted_invoice_gbp), 0))}</p></div>
          <div className="rounded-2xl border border-slate-200 bg-white p-4"><p className="text-xs font-black uppercase text-slate-500">Already created</p><p className="mt-1 text-3xl font-black">{auditRows.length}</p></div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div>
              <h2 className="text-xl font-black">Ready settlement surplus</h2>
              <p className="mt-1 text-sm text-slate-600">Only orders with posted final customer invoice, matched funding surplus, and no settlement credit yet appear here.</p>
            </div>
            <span className="rounded-full bg-cyan-50 px-3 py-1 text-sm font-bold text-cyan-700 ring-1 ring-cyan-200">Safe action queue</span>
          </div>

          <div className="mt-5 grid gap-4">
            {readyRows.length === 0 ? <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-600">No orders currently need surplus-to-credit closure.</div> : null}
            {readyRows.map((row) => (
              <article key={row.order_id} className="rounded-2xl border border-cyan-200 bg-cyan-50 p-4 shadow-sm">
                <div className="flex flex-wrap items-start justify-between gap-3">
                  <div>
                    <p className="text-xs font-black uppercase tracking-wide text-cyan-700">Ready: funding surplus → customer credit</p>
                    <h3 className="mt-1 text-lg font-black">{row.order_ref ?? row.order_id}</h3>
                    <p className="mt-1 text-xs text-slate-500">Order id: {row.order_id}</p>
                  </div>
                  <span className="rounded-full bg-cyan-100 px-3 py-1 text-xs font-bold text-cyan-800 ring-1 ring-cyan-200">credit due</span>
                </div>

                <div className="mt-4 grid gap-3 md:grid-cols-4">
                  <div className="rounded-2xl bg-white p-3 ring-1 ring-cyan-100"><p className="text-xs font-black uppercase text-slate-500">Funding received</p><p className="mt-1 text-xl font-black">{gbp(row.funding_total_gbp)}</p></div>
                  <div className="rounded-2xl bg-white p-3 ring-1 ring-cyan-100"><p className="text-xs font-black uppercase text-slate-500">Posted invoice</p><p className="mt-1 text-xl font-black">{gbp(row.posted_customer_invoice_gbp)}</p></div>
                  <div className="rounded-2xl bg-white p-3 ring-1 ring-cyan-100"><p className="text-xs font-black uppercase text-slate-500">Credit due</p><p className="mt-1 text-xl font-black text-cyan-800">{gbp(row.funding_less_posted_invoice_gbp)}</p></div>
                  <div className="rounded-2xl bg-white p-3 ring-1 ring-cyan-100"><p className="text-xs font-black uppercase text-slate-500">Status</p><p className="mt-1 text-xl font-black">{row.settlement_status}</p></div>
                </div>

                <form action={confirmSettlementSurplusCreditAction} className="mt-4 grid gap-2 md:grid-cols-[1fr_1fr_auto]">
                  <input type="hidden" name="order_id" value={row.order_id} />
                  <select name="reason" defaultValue="supervisor_confirmed_credit" className="rounded-xl border border-cyan-200 bg-white px-3 py-2 text-sm">
                    <option value="supervisor_confirmed_credit">Supervisor confirmed customer credit</option>
                    <option value="discount_or_promo">Discount / promo / voucher reduced final value</option>
                    <option value="checkout_changed">Checkout value changed</option>
                    <option value="item_removed_before_charge">Item removed before charge</option>
                    <option value="not_charged_closure">Not charged / not spent</option>
                    <option value="customer_hold_excluded">Customer hold excluded from final invoice</option>
                  </select>
                  <input name="notes" className="rounded-xl border border-cyan-200 bg-white px-3 py-2 text-sm" placeholder="Notes" defaultValue={`Funding ${gbp(row.funding_total_gbp)} less posted invoice ${gbp(row.posted_customer_invoice_gbp)} = ${gbp(row.funding_less_posted_invoice_gbp)} customer credit.`} />
                  <button className="rounded-xl bg-cyan-700 px-4 py-2 text-sm font-black text-white">Create credit</button>
                </form>
              </article>
            ))}
          </div>
        </section>

        <details className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <summary className="cursor-pointer text-xl font-black">Settlement credit audit · {auditRows.length}</summary>
          <div className="mt-5 grid gap-3">
            {auditRows.length === 0 ? <p className="text-sm text-slate-600">No created settlement credits in this view.</p> : null}
            {auditRows.slice(0, 30).map((row) => (
              <div key={row.order_id} className="rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm">
                <p className="font-black">{row.order_ref ?? row.order_id}</p>
                <p className="mt-1 text-slate-600">Credit created: {gbp(row.settlement_credit_created_gbp)} · Funding {gbp(row.funding_total_gbp)} · Posted invoice {gbp(row.posted_customer_invoice_gbp)}</p>
              </div>
            ))}
          </div>
        </details>
      </div>
    </main>
  );
}
