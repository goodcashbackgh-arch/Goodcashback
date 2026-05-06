"use client";

import { useEffect, useMemo, useState } from "react";

type Card = {
  order_id: string;
  order_ref: string;
  importer_id: string;
  status: string;
  order_type: string;
  importer_funding_in_gbp: number;
  credit_applied_gbp: number;
  funded_total_gbp: number;
  funding_required_gbp: number;
  funding_gap_gbp: number;
  supplier_out_gbp: number;
  supplier_invoice_total_gbp: number;
  supplier_allocation_gap_gbp: number;
  retailer_refund_in_gbp: number;
  fx_card_fee_gbp: number;
  exception_hold_gbp: number;
  unresolved_exception_impact_gbp: number;
  controlled_net_gbp: number;
  allocation_count: number;
  invoice_count: number;
  approved_current_invoice_count: number;
  blocker_count: number;
  blockers: string[];
  warnings: string[];
  ready_for_sage_preview: boolean;
};

type Payload = {
  cards: Card[];
  totals: {
    importer_funding_in_gbp: number;
    credit_applied_gbp: number;
    supplier_out_gbp: number;
    retailer_refund_in_gbp: number;
    controlled_net_gbp: number;
    unresolved_exception_impact_gbp: number;
  };
};

const gbpFormatter = new Intl.NumberFormat("en-GB", {
  style: "currency",
  currency: "GBP",
  minimumFractionDigits: 2,
});

function gbp(value: unknown) {
  const amount = typeof value === "number" && Number.isFinite(value) ? value : Number(value ?? 0);
  return gbpFormatter.format(Number.isFinite(amount) ? amount : 0);
}

function pretty(value: string) {
  return value ? value.replaceAll("_", " ") : "—";
}

function pillClass(ready: boolean) {
  return ready ? "border-emerald-200 bg-emerald-50 text-emerald-800" : "border-amber-200 bg-amber-50 text-amber-800";
}

export default function OrderFinancialControlSummary() {
  const [payload, setPayload] = useState<Payload | null>(null);
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const controller = new AbortController();
    const params = new URLSearchParams(window.location.search);
    const url = `/internal/status-control/pre-sage-financial-readiness/summary-data?${params.toString()}`;

    setLoading(true);
    fetch(url, { signal: controller.signal })
      .then(async (response) => {
        const json = await response.json();
        if (!response.ok) throw new Error(json?.error || "Could not load order financial control summary.");
        setPayload(json as Payload);
        setError("");
      })
      .catch((err) => {
        if (err?.name === "AbortError") return;
        setError(err instanceof Error ? err.message : "Could not load order financial control summary.");
      })
      .finally(() => setLoading(false));

    return () => controller.abort();
  }, []);

  const cards = payload?.cards ?? [];
  const readyCount = useMemo(() => cards.filter((card) => card.ready_for_sage_preview).length, [cards]);
  const blockedCount = cards.length - readyCount;

  if (loading) {
    return (
      <section className="mx-auto mb-5 max-w-7xl rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
        <p className="text-sm font-semibold text-slate-600">Loading order financial control summary…</p>
      </section>
    );
  }

  if (error) {
    return (
      <section className="mx-auto mb-5 max-w-7xl rounded-3xl border border-rose-200 bg-rose-50 p-5 text-sm font-semibold text-rose-800 shadow-sm">
        {error}
      </section>
    );
  }

  return (
    <section className="mx-auto mb-5 max-w-7xl space-y-4 rounded-3xl border border-slate-200 bg-white p-5 text-slate-950 shadow-sm">
      <div>
        <p className="text-xs font-bold uppercase tracking-[0.22em] text-sky-600">Order financial control summary</p>
        <h2 className="mt-2 text-2xl font-extrabold tracking-tight">Money in / money out position before Sage preview</h2>
        <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">
          Read-only control layer. It pulls importer funding, supplier OUT allocations, retailer refund IN allocations, FX/card fees, exception holds, and unresolved exception impact into one order-level position.
        </p>
      </div>

      <div className="grid gap-3 sm:grid-cols-3 lg:grid-cols-6">
        <div className="rounded-2xl border border-slate-200 bg-slate-50 p-3"><p className="text-[11px] font-bold uppercase tracking-wide text-slate-500">Orders shown</p><p className="mt-1 text-xl font-extrabold">{cards.length}</p></div>
        <div className="rounded-2xl border border-emerald-200 bg-emerald-50 p-3"><p className="text-[11px] font-bold uppercase tracking-wide text-emerald-700">Ready</p><p className="mt-1 text-xl font-extrabold text-emerald-950">{readyCount}</p></div>
        <div className="rounded-2xl border border-amber-200 bg-amber-50 p-3"><p className="text-[11px] font-bold uppercase tracking-wide text-amber-700">Blocked</p><p className="mt-1 text-xl font-extrabold text-amber-950">{blockedCount}</p></div>
        <div className="rounded-2xl border border-sky-200 bg-sky-50 p-3"><p className="text-[11px] font-bold uppercase tracking-wide text-sky-700">Funding/credit in</p><p className="mt-1 text-xl font-extrabold text-sky-950">{gbp((payload?.totals.importer_funding_in_gbp ?? 0) + (payload?.totals.credit_applied_gbp ?? 0))}</p></div>
        <div className="rounded-2xl border border-indigo-200 bg-indigo-50 p-3"><p className="text-[11px] font-bold uppercase tracking-wide text-indigo-700">Supplier/fees out</p><p className="mt-1 text-xl font-extrabold text-indigo-950">{gbp((payload?.totals.supplier_out_gbp ?? 0) + (payload?.totals.controlled_net_gbp ? 0 : 0))}</p></div>
        <div className="rounded-2xl border border-rose-200 bg-rose-50 p-3"><p className="text-[11px] font-bold uppercase tracking-wide text-rose-700">Unresolved exception</p><p className="mt-1 text-xl font-extrabold text-rose-950">{gbp(payload?.totals.unresolved_exception_impact_gbp ?? 0)}</p></div>
      </div>

      <div className="space-y-3">
        {cards.slice(0, 20).map((card) => (
          <article key={card.order_id} className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm">
            <div className="flex flex-wrap items-start justify-between gap-3">
              <div>
                <p className="text-lg font-extrabold">{card.order_ref}</p>
                <p className="mt-1 text-sm text-slate-600">Raw status {pretty(card.status)} · Type {pretty(card.order_type)}</p>
              </div>
              <span className={`rounded-full border px-3 py-1 text-xs font-bold ${pillClass(card.ready_for_sage_preview)}`}>
                {card.ready_for_sage_preview ? "money picture controlled" : "financial blockers remain"}
              </span>
            </div>

            <div className="mt-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-6">
              <div className="rounded-xl border border-slate-200 bg-slate-50 p-3"><p className="text-[11px] font-bold uppercase tracking-wide text-slate-500">Importer funding IN</p><p className="font-extrabold">{gbp(card.importer_funding_in_gbp)}</p><p className="text-xs text-slate-500">Credit applied {gbp(card.credit_applied_gbp)}</p></div>
              <div className="rounded-xl border border-slate-200 bg-slate-50 p-3"><p className="text-[11px] font-bold uppercase tracking-wide text-slate-500">Funding need</p><p className="font-extrabold">{gbp(card.funding_required_gbp)}</p><p className="text-xs text-slate-500">Gap {gbp(card.funding_gap_gbp)}</p></div>
              <div className="rounded-xl border border-slate-200 bg-slate-50 p-3"><p className="text-[11px] font-bold uppercase tracking-wide text-slate-500">Supplier OUT</p><p className="font-extrabold">{gbp(card.supplier_out_gbp)}</p><p className="text-xs text-slate-500">Invoice total {gbp(card.supplier_invoice_total_gbp)}</p></div>
              <div className="rounded-xl border border-slate-200 bg-slate-50 p-3"><p className="text-[11px] font-bold uppercase tracking-wide text-slate-500">Refund IN</p><p className="font-extrabold">{gbp(card.retailer_refund_in_gbp)}</p><p className="text-xs text-slate-500">Retailer refunds only</p></div>
              <div className="rounded-xl border border-slate-200 bg-slate-50 p-3"><p className="text-[11px] font-bold uppercase tracking-wide text-slate-500">FX/fees/holds</p><p className="font-extrabold">{gbp(card.fx_card_fee_gbp)}</p><p className="text-xs text-slate-500">Hold {gbp(card.exception_hold_gbp)}</p></div>
              <div className="rounded-xl border border-slate-200 bg-slate-50 p-3"><p className="text-[11px] font-bold uppercase tracking-wide text-slate-500">Controlled net</p><p className="font-extrabold">{gbp(card.controlled_net_gbp)}</p><p className="text-xs text-slate-500">Unresolved {gbp(card.unresolved_exception_impact_gbp)}</p></div>
            </div>

            {card.blockers.length > 0 ? (
              <div className="mt-4 rounded-xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-950">
                <p className="font-bold">Blockers</p>
                <ul className="mt-2 list-disc space-y-1 pl-5">
                  {card.blockers.map((blocker) => <li key={blocker}>{blocker}</li>)}
                </ul>
              </div>
            ) : null}

            {card.warnings.length > 0 ? (
              <div className="mt-3 rounded-xl border border-sky-200 bg-sky-50 p-3 text-sm text-sky-950">
                <p className="font-bold">Warnings</p>
                <ul className="mt-2 list-disc space-y-1 pl-5">
                  {card.warnings.map((warning) => <li key={warning}>{warning}</li>)}
                </ul>
              </div>
            ) : null}
          </article>
        ))}
      </div>
    </section>
  );
}
