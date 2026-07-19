import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type HoldRow = {
  hold_request_id?: string | null;
  order_id: string;
  order_ref: string | null;
  tracking_submission_id: string | null;
  tracking_ref: string | null;
  supplier_invoice_line_id: string | null;
  line_description?: string | null;
  line_qty?: number | string | null;
  line_amount_inc_vat_gbp?: number | string | null;
  reason?: string | null;
  hold_scope: string | null;
  hold_status: string | null;
  set_aside_instruction: string | null;
  converted_dispute_id?: string | null;
};

type ReturnActionRow = {
  return_tracking_submission_id?: string | null;
  dispute_id: string;
  order_id: string;
  tracking_ref: string | null;
  task_status: string | null;
  affected_lines?: Array<{ supplier_invoice_line_id?: string | null }> | null;
};

function friendly(value: string | null | undefined) {
  if (!value) return "—";
  return value.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase());
}

function money(value: number | string | null | undefined) {
  const parsed = Number(value ?? 0);
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" }).format(Number.isFinite(parsed) ? parsed : 0);
}

function groupByOrder(rows: HoldRow[]) {
  const grouped = new Map<string, HoldRow[]>();
  rows.forEach((row) => {
    const existing = grouped.get(row.order_id) ?? [];
    existing.push(row);
    grouped.set(row.order_id, existing);
  });
  return Array.from(grouped.entries()).map(([orderId, holds]) => ({ orderId, holds }));
}

function returnActionMatchesHold(action: ReturnActionRow, hold: HoldRow) {
  if (action.order_id !== hold.order_id) return false;
  if (hold.converted_dispute_id && action.dispute_id === hold.converted_dispute_id) return true;

  const affectedLineIds = new Set((action.affected_lines ?? []).map((line) => line.supplier_invoice_line_id).filter(Boolean) as string[]);
  if (hold.supplier_invoice_line_id && affectedLineIds.has(hold.supplier_invoice_line_id)) return true;

  // Legacy fallback only. A return courier reference is normally different from
  // the inbound package reference, so dispute identity is authoritative above.
  if (hold.tracking_ref && action.tracking_ref === hold.tracking_ref) return true;

  return !hold.converted_dispute_id && !hold.supplier_invoice_line_id && !hold.tracking_ref;
}

function returnActionHref(action: ReturnActionRow | undefined, status: string) {
  const base = `/shipper/return-actions?source=customer_hold&status=${status}`;
  return action?.return_tracking_submission_id ? `${base}#return-action-${action.return_tracking_submission_id}` : base;
}

function nextStateForHoldGroup(holds: HoldRow[], returnActions: ReturnActionRow[]) {
  const matchingActions = returnActions.filter((action) => holds.some((hold) => returnActionMatchesHold(action, hold)));
  if (matchingActions.length === 0) {
    return {
      label: "Set aside only — waiting for operator return instructions",
      className: "bg-amber-100 text-amber-900 border-amber-200",
      href: null,
      cta: null,
    };
  }

  const readyAction = matchingActions.find((action) => action.task_status === "ready_to_action" || action.task_status === "held_query");
  if (readyAction) {
    return {
      label: "Return action ready — open return action",
      className: "bg-sky-100 text-sky-900 border-sky-200",
      href: returnActionHref(readyAction, readyAction.task_status === "held_query" ? "held_query" : "ready_to_action"),
      cta: "Open return action",
    };
  }

  const submittedAction = matchingActions.find((action) => action.task_status === "submitted_for_review");
  if (submittedAction) {
    return {
      label: "Return proof submitted — awaiting supervisor review",
      className: "bg-sky-100 text-sky-900 border-sky-200",
      href: returnActionHref(submittedAction, "submitted_for_review"),
      cta: "View submitted proof",
    };
  }

  const acceptedAction = matchingActions.find((action) => action.task_status === "accepted");
  if (acceptedAction && matchingActions.every((action) => action.task_status === "accepted")) {
    return {
      label: "Return accepted — physical return loop closed",
      className: "bg-emerald-100 text-emerald-900 border-emerald-200",
      href: returnActionHref(acceptedAction, "accepted"),
      cta: "View closed action",
    };
  }

  return {
    label: "Return action in progress",
    className: "bg-slate-100 text-slate-800 border-slate-200",
    href: returnActionHref(matchingActions[0], "all"),
    cta: "View return actions",
  };
}

export default async function ShipperCustomerHoldsPage() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: shipperUser } = await supabase
    .from("shipper_users")
    .select("id, full_name, shipper_id, role_at_shipper, shippers(name)")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!shipperUser) redirect("/auth/check");

  let { data, error } = await (supabase as any).rpc("shipper_customer_hold_set_aside_v3");
  let usingFallback = false;

  if (error) {
    const fallbackV2 = await (supabase as any).rpc("shipper_customer_hold_set_aside_v2");
    data = fallbackV2.data;
    error = fallbackV2.error;
    usingFallback = true;
  }

  if (error) {
    const fallbackV1 = await (supabase as any).rpc("shipper_customer_hold_set_aside_v1");
    data = fallbackV1.data;
    error = fallbackV1.error;
    usingFallback = true;
  }

  const { data: returnActionData, error: returnActionError } = await (supabase as any).rpc("shipper_return_tasks_v1");
  const returnActions = (returnActionData ?? []) as ReturnActionRow[];
  const rows = (data ?? []) as HoldRow[];
  const orderGroups = groupByOrder(rows);
  const shipper = Array.isArray((shipperUser as any).shippers) ? (shipperUser as any).shippers[0] : (shipperUser as any).shippers;

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-6xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-wrap gap-3 text-sm font-semibold text-sky-700">
            <Link href="/shipper">← Package receipt dashboard</Link>
            <Link href="/shipper/shipments">Shipment batches</Link>
            <Link href="/shipper/package-receipts">Package receipt actions</Link>
            <Link href="/shipper/return-actions">Return actions</Link>
          </div>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Goodcashback Shipper</p>
          <h1 className="mt-2 text-2xl font-semibold tracking-tight sm:text-3xl">Customer hold / set-aside instructions</h1>
          <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">
            This page shows approved set-aside instructions and the next state. It does not show upstream finance, payment or accounting controls.
          </p>
          <p className="mt-3 text-sm text-slate-600">Welcome: <span className="font-semibold text-slate-900">{shipperUser.full_name}</span> · {shipper?.name ?? "Shipper"}</p>
          {error ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">Customer hold set-aside queue unavailable: {error.message}. Apply the latest migration before testing this page.</p> : null}
          {returnActionError ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">Return actions state unavailable: {returnActionError.message}. Apply the latest return-action migration before testing next-state links.</p> : null}
          {usingFallback && !error ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">Showing compatibility hold data. Apply the latest shipper hold identity migration for dispute-linked next-state matching.</p> : null}
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
            <div>
              <h2 className="text-xl font-semibold">Set-aside worklist</h2>
              <p className="mt-2 text-sm leading-6 text-slate-600">Do not ship packages/items shown here. Use the next-state card to continue when operator return instructions are ready.</p>
            </div>
            <div className={`rounded-2xl px-4 py-3 text-sm font-semibold ${rows.length > 0 ? "bg-amber-100 text-amber-900" : "bg-emerald-100 text-emerald-900"}`}>
              {rows.length} active hold(s) · {orderGroups.length} order(s)
            </div>
          </div>

          {rows.length === 0 ? (
            <p className="mt-5 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-600">No active customer hold instructions for your shipper account.</p>
          ) : (
            <div className="mt-5 grid gap-4">
              {orderGroups.map(({ orderId, holds }) => {
                const first = holds[0];
                const lineHolds = holds.filter((row) => row.hold_scope === "line");
                const trackingRefs = Array.from(new Set(holds.map((row) => row.tracking_ref).filter(Boolean)));
                const hasOrderHold = holds.some((row) => row.hold_scope === "order");
                const hasTrackingHold = holds.some((row) => row.hold_scope === "tracking");
                const nextState = nextStateForHoldGroup(holds, returnActions);

                return (
                  <article key={orderId} className="rounded-2xl border border-amber-200 bg-amber-50 p-4">
                    <div className="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
                      <div className="min-w-0 flex-1">
                        <p className="text-xs font-semibold uppercase tracking-wide text-amber-700">Set aside / do not ship</p>
                        <h3 className="mt-1 text-lg font-semibold text-amber-950">{first?.order_ref ?? orderId}</h3>
                        <p className="mt-2 text-sm leading-6 text-amber-900">
                          {hasOrderHold
                            ? "Order-level customer hold: watch for any package for this order. Do not consolidate or add to shipment until supervisor clears."
                            : hasTrackingHold
                              ? "Package/tracking hold: set aside the listed package. Do not add to shipment until supervisor clears."
                              : "Item-line hold: set aside the affected item(s) if identifiable. Clean unheld items may continue only if supervisor/process allows."}
                        </p>
                      </div>
                      <div className="grid gap-2 text-sm sm:grid-cols-3 lg:min-w-[560px]">
                        <div className="rounded-xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Active holds</p><p className="mt-1 font-semibold">{holds.length}</p></div>
                        <div className="rounded-xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Scope</p><p className="mt-1 font-semibold">{hasOrderHold ? "Order" : hasTrackingHold ? "Tracking/package" : "Line"}</p></div>
                        <div className="rounded-xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Tracking/package</p><p className="mt-1 font-semibold">{trackingRefs.length > 0 ? trackingRefs.join(", ") : "Order-level / not specified"}</p></div>
                      </div>
                    </div>

                    <div className={`mt-4 rounded-2xl border p-3 text-sm font-semibold ${nextState.className}`}>
                      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
                        <span>{nextState.label}</span>
                        {nextState.href && nextState.cta ? (
                          <Link href={nextState.href} className="w-fit rounded-xl bg-white px-3 py-2 text-xs font-semibold text-slate-900 hover:bg-slate-50">
                            {nextState.cta}
                          </Link>
                        ) : null}
                      </div>
                    </div>

                    {lineHolds.length > 0 ? (
                      <div className="mt-4 rounded-2xl border border-amber-200 bg-white p-3">
                        <p className="text-xs font-semibold uppercase tracking-wide text-slate-500">Held item lines</p>
                        <div className="mt-2 grid gap-2">
                          {lineHolds.map((row, index) => (
                            <div key={row.hold_request_id ?? `${row.order_id}-${row.supplier_invoice_line_id ?? index}`} className="rounded-xl bg-amber-50 p-3 text-sm">
                              <p className="font-semibold text-amber-950">{row.line_description ?? "Item line"}</p>
                              <p className="mt-1 text-amber-900">Qty {row.line_qty ?? "—"} · {money(row.line_amount_inc_vat_gbp)} · Tracking {row.tracking_ref ?? "—"}</p>
                              {row.reason ? <p className="mt-1 text-amber-900">Reason: {row.reason}</p> : null}
                            </div>
                          ))}
                        </div>
                      </div>
                    ) : null}
                  </article>
                );
              })}
            </div>
          )}
        </section>
      </div>
    </main>
  );
}
