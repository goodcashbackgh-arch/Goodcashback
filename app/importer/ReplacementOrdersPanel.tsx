"use client";

import Link from "next/link";
import { useEffect, useState } from "react";

type ReplacementOrder = {
  id: string;
  order_ref: string;
  status: string;
  order_type: string;
  parent_order_id: string;
  parent_order_ref: string;
  parent_order_status: string;
  retailer_name: string;
  total_qty_declared: number | null;
  order_total_gbp_declared: number | string | null;
  dispute_id: string;
  dispute_status: string;
  desired_outcome: string;
  created_at: string;
};

type Payload = {
  rows?: ReplacementOrder[];
  error?: string;
};

function gbp(value: unknown) {
  const amount = Number(value ?? 0);
  return new Intl.NumberFormat("en-GB", {
    style: "currency",
    currency: "GBP",
    minimumFractionDigits: 2,
  }).format(Number.isFinite(amount) ? amount : 0);
}

function pretty(value: string | null | undefined) {
  return value ? value.replaceAll("_", " ") : "—";
}

function nextAction(order: ReplacementOrder) {
  if (order.status === "evidence_collecting") return "Upload replacement invoice and/or tracking";
  if (order.status === "reconciling") return "Continue replacement invoice reconciliation";
  return "Continue replacement order flow";
}

export default function ReplacementOrdersPanel() {
  const [rows, setRows] = useState<ReplacementOrder[]>([]);
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(true);
  const [visible, setVisible] = useState(false);

  useEffect(() => {
    if (window.location.pathname !== "/importer") {
      setLoading(false);
      return;
    }

    setVisible(true);
    const controller = new AbortController();

    fetch("/importer/replacement-orders-data", { signal: controller.signal })
      .then(async (response) => {
        const json = (await response.json()) as Payload;
        if (!response.ok) throw new Error(json.error || "Could not load replacement orders.");
        setRows(json.rows ?? []);
        setError("");
      })
      .catch((err) => {
        if (err?.name === "AbortError") return;
        setError(err instanceof Error ? err.message : "Could not load replacement orders.");
      })
      .finally(() => setLoading(false));

    return () => controller.abort();
  }, []);

  if (!visible) return null;

  return (
    <section className="rounded-2xl border border-sky-200 bg-sky-50 p-4 text-slate-950">
      <div className="flex flex-col gap-2 md:flex-row md:items-start md:justify-between">
        <div>
          <p className="text-xs font-bold uppercase tracking-[0.2em] text-sky-700">Replacement / repurchase orders</p>
          <h2 className="mt-1 text-lg font-semibold">Child orders created from approved exceptions</h2>
          <p className="mt-1 max-w-4xl text-sm text-sky-900">
            Use the normal order path for replacements and repurchases: upload invoice/evidence, add tracking, then continue reconciliation. No separate replacement workflow is needed.
          </p>
        </div>
        <span className="rounded-full bg-white px-3 py-1 text-sm font-semibold text-sky-800 ring-1 ring-sky-200">
          {loading ? "Loading…" : `${rows.length} active child order(s)`}
        </span>
      </div>

      {error ? <p className="mt-4 rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm font-semibold text-rose-800">{error}</p> : null}

      {!loading && !error && rows.length === 0 ? (
        <p className="mt-4 rounded-xl border border-sky-200 bg-white p-3 text-sm text-sky-900">No replacement or repurchase child orders currently need action.</p>
      ) : null}

      {rows.length > 0 ? (
        <div className="mt-4 grid gap-3">
          {rows.map((order) => (
            <article key={order.id} className="rounded-2xl border border-sky-200 bg-white p-4 shadow-sm">
              <div className="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
                <div className="min-w-0">
                  <div className="flex flex-wrap items-center gap-2">
                    <span className="rounded-full bg-sky-100 px-2.5 py-1 text-xs font-bold text-sky-800">Replacement order</span>
                    <span className="rounded-full bg-slate-100 px-2.5 py-1 text-xs font-semibold text-slate-700">{pretty(order.status)}</span>
                    {order.dispute_status ? <span className="rounded-full bg-amber-100 px-2.5 py-1 text-xs font-semibold text-amber-800">Exception {pretty(order.dispute_status)}</span> : null}
                  </div>
                  <h3 className="mt-2 text-base font-extrabold text-slate-950">{order.order_ref}</h3>
                  <p className="mt-1 text-sm text-slate-600">Parent order: {order.parent_order_ref || order.parent_order_id || "—"}</p>
                  <p className="mt-1 text-sm text-slate-600">Retailer: {order.retailer_name || "—"} · Qty {order.total_qty_declared ?? "—"} · Goods {gbp(order.order_total_gbp_declared)}</p>
                  <p className="mt-1 text-xs text-slate-500">Linked exception id: {order.dispute_id || "not linked"}</p>
                  <p className="mt-2 text-sm font-semibold text-sky-900">Next action: {nextAction(order)}</p>
                </div>

                <div className="flex flex-wrap gap-2 lg:justify-end">
                  <Link href={`/importer/orders/${order.id}/operations`} className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800">
                    Open operations
                  </Link>
                  <Link href={`/importer/reconciliation/${order.id}`} className="rounded-xl border border-slate-200 bg-white px-4 py-2 text-sm font-semibold text-slate-700 hover:bg-slate-50">
                    Reconcile invoice
                  </Link>
                  {order.dispute_id ? (
                    <Link href={`/importer/exceptions/${order.dispute_id}`} className="rounded-xl border border-amber-200 bg-amber-50 px-4 py-2 text-sm font-semibold text-amber-800 hover:bg-amber-100">
                      Open linked exception
                    </Link>
                  ) : null}
                </div>
              </div>
            </article>
          ))}
        </div>
      ) : null}
    </section>
  );
}
