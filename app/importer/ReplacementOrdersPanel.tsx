"use client";

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";

type TrackingSubmission = {
  id: string;
  tracking_ref: string;
  tracking_date: string;
  submitted_at: string;
};

type SameOrderRoute = {
  id: string;
  order_id: string;
  order_ref: string;
  order_status: string;
  retailer_name: string;
  dispute_id: string;
  dispute_status: string;
  desired_outcome: string;
  route_status: string;
  replacement_qty: number | null;
  transferred_adjusted_net_value_gbp: number | string | null;
  successor_tracking_submission_id: string;
  successor_tracking_line_allocation_id: string;
  tracking_allocated_at: string;
  created_at: string;
  tracking_submissions: TrackingSubmission[];
};

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
  same_order_routes?: SameOrderRoute[];
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
  const [sameOrderRoutes, setSameOrderRoutes] = useState<SameOrderRoute[]>([]);
  const [error, setError] = useState("");
  const [success, setSuccess] = useState("");
  const [loading, setLoading] = useState(true);
  const [visible, setVisible] = useState(false);
  const [selectedByOrder, setSelectedByOrder] = useState<Record<string, string[]>>({});
  const [trackingByOrder, setTrackingByOrder] = useState<Record<string, string>>({});
  const [submittingOrder, setSubmittingOrder] = useState("");

  async function load() {
    setLoading(true);
    try {
      const response = await fetch("/importer/replacement-orders-data");
      const json = (await response.json()) as Payload;
      if (!response.ok) throw new Error(json.error || "Could not load replacement routes.");
      const routes = json.same_order_routes ?? [];
      setRows(json.rows ?? []);
      setSameOrderRoutes(routes);

      const waitingByOrder: Record<string, string[]> = {};
      for (const route of routes) {
        if (route.route_status !== "approved_waiting_tracking") continue;
        waitingByOrder[route.order_id] = [...(waitingByOrder[route.order_id] ?? []), route.id];
      }
      setSelectedByOrder(waitingByOrder);

      setTrackingByOrder((current) => {
        const next = { ...current };
        for (const route of routes) {
          if (!next[route.order_id] && route.tracking_submissions[0]?.id) next[route.order_id] = route.tracking_submissions[0].id;
        }
        return next;
      });
      setError("");
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not load replacement routes.");
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    setVisible(true);
    void load();
  }, []);

  const groups = useMemo(() => {
    const map = new Map<string, SameOrderRoute[]>();
    for (const route of sameOrderRoutes) {
      const current = map.get(route.order_id) ?? [];
      current.push(route);
      map.set(route.order_id, current);
    }
    return [...map.entries()];
  }, [sameOrderRoutes]);

  function toggleRoute(orderId: string, routeId: string) {
    setSelectedByOrder((current) => {
      const selected = new Set(current[orderId] ?? []);
      if (selected.has(routeId)) selected.delete(routeId);
      else selected.add(routeId);
      return { ...current, [orderId]: [...selected] };
    });
  }

  async function allocate(orderId: string) {
    const currentlyWaiting = new Set(
      sameOrderRoutes
        .filter((route) => route.order_id === orderId && route.route_status === "approved_waiting_tracking")
        .map((route) => route.id),
    );
    const routeIds = (selectedByOrder[orderId] ?? []).filter((routeId) => currentlyWaiting.has(routeId));
    const trackingSubmissionId = trackingByOrder[orderId] ?? "";
    if (!routeIds.length || !trackingSubmissionId) return;

    setSubmittingOrder(orderId);
    setError("");
    setSuccess("");
    try {
      const response = await fetch("/importer/replacement-orders-data", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          order_id: orderId,
          tracking_submission_id: trackingSubmissionId,
          route_ids: routeIds,
          note: "Allocated through importer same-order replacement handoff.",
        }),
      });
      const json = (await response.json()) as { error?: string };
      if (!response.ok) throw new Error(json.error || "Could not allocate successor tracking.");
      setSuccess("Successor tracking allocated to the selected same-order replacement route(s).");
      await load();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not allocate successor tracking.");
    } finally {
      setSubmittingOrder("");
    }
  }

  if (!visible) return null;

  const waitingCount = sameOrderRoutes.filter((route) => route.route_status === "approved_waiting_tracking").length;

  return (
    <section id="replacement-tracking" className="rounded-2xl border border-sky-200 bg-sky-50 p-4 text-slate-950">
      <div className="flex flex-col gap-2 md:flex-row md:items-start md:justify-between">
        <div>
          <p className="text-xs font-bold uppercase tracking-[0.2em] text-sky-700">Replacement tracking handoff</p>
          <h2 className="mt-1 text-lg font-semibold">Same-order replacements awaiting successor tracking</h2>
          <p className="mt-1 max-w-4xl text-sm text-sky-900">
            These replacements stay on the original order. Select the approved routes and attach them to an existing tracking submission for that order. No child order is created.
          </p>
        </div>
        <span className="rounded-full bg-white px-3 py-1 text-sm font-semibold text-sky-800 ring-1 ring-sky-200">
          {loading ? "Loading…" : `${waitingCount} route(s) waiting`}
        </span>
      </div>

      {error ? <p className="mt-4 rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm font-semibold text-rose-800">{error}</p> : null}
      {success ? <p className="mt-4 rounded-xl border border-emerald-200 bg-emerald-50 p-3 text-sm font-semibold text-emerald-800">{success}</p> : null}

      {!loading && !error && sameOrderRoutes.length === 0 ? (
        <p className="mt-4 rounded-xl border border-sky-200 bg-white p-3 text-sm text-sky-900">No same-order replacement routes currently need action.</p>
      ) : null}

      {groups.length > 0 ? (
        <div className="mt-4 grid gap-4">
          {groups.map(([orderId, routes]) => {
            const first = routes[0];
            const waitingRoutes = routes.filter((route) => route.route_status === "approved_waiting_tracking");
            const submissions = first.tracking_submissions ?? [];
            const selected = selectedByOrder[orderId] ?? [];
            return (
              <article key={orderId} className="rounded-2xl border border-sky-200 bg-white p-4 shadow-sm">
                <div className="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
                  <div>
                    <div className="flex flex-wrap items-center gap-2">
                      <span className="rounded-full bg-sky-100 px-2.5 py-1 text-xs font-bold text-sky-800">Original order</span>
                      <span className="rounded-full bg-slate-100 px-2.5 py-1 text-xs font-semibold text-slate-700">{pretty(first.order_status)}</span>
                    </div>
                    <h3 className="mt-2 text-base font-extrabold text-slate-950">{first.order_ref}</h3>
                    <p className="mt-1 text-sm text-slate-600">Retailer: {first.retailer_name || "—"}</p>
                    <p className="mt-1 text-xs text-slate-500">Order id: {orderId}</p>
                  </div>
                  <Link href={`/importer/orders/${orderId}/operations`} className="rounded-xl border border-slate-200 bg-white px-4 py-2 text-sm font-semibold text-slate-700 hover:bg-slate-50">
                    Open order operations
                  </Link>
                </div>

                <div className="mt-4 grid gap-2">
                  {routes.map((route) => {
                    const canSelect = route.route_status === "approved_waiting_tracking";
                    return (
                      <label key={route.id} className="flex gap-3 rounded-xl border border-slate-200 p-3">
                        <input
                          type="checkbox"
                          className="mt-1 h-4 w-4"
                          disabled={!canSelect}
                          checked={canSelect && selected.includes(route.id)}
                          onChange={() => toggleRoute(orderId, route.id)}
                        />
                        <span className="min-w-0">
                          <span className="flex flex-wrap items-center gap-2">
                            <span className="font-semibold text-slate-950">Qty {route.replacement_qty ?? "—"}</span>
                            <span className={`rounded-full px-2 py-0.5 text-xs font-semibold ${canSelect ? "bg-amber-100 text-amber-800" : "bg-emerald-100 text-emerald-800"}`}>
                              {pretty(route.route_status)}
                            </span>
                          </span>
                          <span className="mt-1 block text-sm text-slate-600">Transferred value: {gbp(route.transferred_adjusted_net_value_gbp)}</span>
                          <span className="mt-1 block text-xs text-slate-500">Same-order replacement · Exception DSP-{route.dispute_id.replaceAll("-", "").slice(0, 8).toUpperCase()}</span>
                        </span>
                      </label>
                    );
                  })}
                </div>

                {waitingRoutes.length > 0 ? (
                  <div className="mt-4 rounded-xl border border-sky-200 bg-sky-50 p-3">
                    {submissions.length > 0 ? (
                      <div className="flex flex-col gap-3 md:flex-row md:items-end">
                        <label className="flex-1 text-sm font-semibold text-slate-800">
                          Successor tracking submission
                          <select
                            className="mt-1 w-full rounded-xl border border-slate-300 bg-white p-3 text-sm"
                            value={trackingByOrder[orderId] ?? ""}
                            onChange={(event) => setTrackingByOrder((current) => ({ ...current, [orderId]: event.target.value }))}
                          >
                            <option value="">Select tracking</option>
                            {submissions.map((submission) => (
                              <option key={submission.id} value={submission.id}>
                                {submission.tracking_ref || submission.id}
                              </option>
                            ))}
                          </select>
                        </label>
                        <button
                          type="button"
                          className="rounded-xl bg-slate-950 px-4 py-3 text-sm font-semibold text-white disabled:cursor-not-allowed disabled:opacity-50"
                          disabled={submittingOrder === orderId || selected.length === 0 || !trackingByOrder[orderId]}
                          onClick={() => void allocate(orderId)}
                        >
                          {submittingOrder === orderId ? "Allocating…" : "Allocate successor tracking"}
                        </button>
                      </div>
                    ) : (
                      <p className="text-sm text-sky-900">
                        No active tracking submission exists for this order. Add the replacement tracking reference in order operations first, then return here to allocate it.
                      </p>
                    )}
                  </div>
                ) : null}
              </article>
            );
          })}
        </div>
      ) : null}

      {rows.length > 0 ? (
        <div className="mt-6 border-t border-sky-200 pt-5">
          <p className="text-xs font-bold uppercase tracking-[0.2em] text-slate-500">Legacy replacement child orders</p>
          <p className="mt-1 text-sm text-slate-600">Historical child-order records remain available below. They are not used for new same-order replacements.</p>
          <div className="mt-3 grid gap-3">
            {rows.map((order) => (
              <article key={order.id} className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm">
                <div className="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
                  <div className="min-w-0">
                    <div className="flex flex-wrap items-center gap-2">
                      <span className="rounded-full bg-slate-100 px-2.5 py-1 text-xs font-bold text-slate-700">Legacy replacement child</span>
                      <span className="rounded-full bg-slate-100 px-2.5 py-1 text-xs font-semibold text-slate-700">{pretty(order.status)}</span>
                    </div>
                    <h3 className="mt-2 text-base font-extrabold text-slate-950">{order.order_ref}</h3>
                    <p className="mt-1 text-sm text-slate-600">Parent order: {order.parent_order_ref || order.parent_order_id || "—"}</p>
                    <p className="mt-1 text-sm text-slate-600">Retailer: {order.retailer_name || "—"} · Qty {order.total_qty_declared ?? "—"} · Goods {gbp(order.order_total_gbp_declared)}</p>
                    <p className="mt-2 text-sm font-semibold text-slate-700">Next action: {nextAction(order)}</p>
                  </div>
                  <div className="flex flex-wrap gap-2 lg:justify-end">
                    <Link href={`/importer/orders/${order.id}/operations`} className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800">
                      Open operations
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
        </div>
      ) : null}
    </section>
  );
}
