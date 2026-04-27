import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type OrderRow = {
  id: string;
  order_ref: string | null;
  status: string | null;
  payment_auth_id: string | null;
  total_qty_declared: number | null;
  order_total_gbp_declared: number | null;
  quote_total_ghs: number | null;
  funded_at: string | null;
  created_at: string | null;
};

type DashboardOrderRow = OrderRow & {
  lifecycle_status: string | null;
};

type OrderReferenceRow = { order_id: string };
type OrderStateRow = { order_id: string; lifecycle_status: string | null };

type EvidenceQueryRow = {
  order_id: string;
  query_type: string | null;
  message: string | null;
};

function gbp(value: number | string | null | undefined) {
  const n = Number(value ?? 0);
  return new Intl.NumberFormat("en-GB", {
    style: "currency",
    currency: "GBP",
    minimumFractionDigits: 2,
  }).format(n);
}

function local(value: number | string | null | undefined) {
  const n = Number(value ?? 0);
  return new Intl.NumberFormat("en-GB", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  }).format(n);
}

function previewMessage(value: string | null | undefined, max = 72) {
  const message = (value ?? "").trim();
  if (!message) return "—";
  if (message.length <= max) return message;
  return `${message.slice(0, max - 1)}…`;
}

function nextAction(
  order: Pick<DashboardOrderRow, "lifecycle_status" | "funded_at">,
  hasOpenEvidenceQuery: boolean
) {
  if (hasOpenEvidenceQuery) return "Answer evidence query";
  if (order.lifecycle_status === "reconciling") return "Awaiting invoice reconciliation";
  if (order.lifecycle_status === "evidence_collecting") return "Upload invoice or tracking";
  if (!order.funded_at) return "Waiting for staff funding";
  return "In progress";
}

export default async function ImporterPage() {
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/login");
  }

  const { data: operator } = await supabase
    .from("operators")
    .select("id, full_name")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!operator) {
    redirect("/auth/check");
  }

  const [{ data: orders, error: ordersError }, { data: screenshots }, { data: tracking }, { data: invoices }] =
    await Promise.all([
      supabase
        .from("orders")
        .select(
          "id, order_ref, status, payment_auth_id, total_qty_declared, order_total_gbp_declared, quote_total_ghs, funded_at, created_at"
        )
        .order("created_at", { ascending: false }),
      supabase.from("order_screenshots").select("order_id"),
      supabase
        .from("order_tracking_submissions")
        .select("order_id, superseded_at")
        .is("superseded_at", null),
      supabase.from("supplier_invoices").select("order_id, invoice_ref"),
    ]);

  if (ordersError) {
    throw ordersError;
  }

  const orderRows = (orders ?? []) as OrderRow[];
  const orderIds = orderRows.map((order) => order.id);
  const { data: orderStates, error: orderStatesError } = orderIds.length
    ? await supabase.from("order_state_vw").select("order_id, lifecycle_status").in("order_id", orderIds)
    : { data: [], error: null };

  if (orderStatesError) {
    throw orderStatesError;
  }

  const lifecycleStatusByOrderId = new Map<string, string | null>();
  for (const row of (orderStates ?? []) as OrderStateRow[]) {
    lifecycleStatusByOrderId.set(row.order_id, row.lifecycle_status);
  }

  const dashboardRows: DashboardOrderRow[] = orderRows.map((order) => ({
    ...order,
    lifecycle_status: lifecycleStatusByOrderId.get(order.id) ?? null,
  }));

  const { data: openEvidenceQueries, error: openEvidenceQueriesError } = orderIds.length
    ? await supabase
        .from("order_evidence_queries")
        .select("order_id, query_type, message, status, created_at")
        .in("order_id", orderIds)
        .eq("status", "open")
        .order("created_at", { ascending: false })
    : { data: [], error: null };

  if (openEvidenceQueriesError) {
    throw openEvidenceQueriesError;
  }

  const openEvidenceQueryByOrderId = new Map<
    string,
    { count: number; latestQueryType: string | null; latestMessage: string | null }
  >();
  for (const query of (openEvidenceQueries ?? []) as EvidenceQueryRow[]) {
    const current = openEvidenceQueryByOrderId.get(query.order_id);
    if (!current) {
      openEvidenceQueryByOrderId.set(query.order_id, {
        count: 1,
        latestQueryType: query.query_type,
        latestMessage: query.message,
      });
      continue;
    }

    current.count += 1;
  }

  const screenshotCounts = new Map<string, number>();
  for (const row of (screenshots ?? []) as OrderReferenceRow[]) {
    screenshotCounts.set(row.order_id, (screenshotCounts.get(row.order_id) ?? 0) + 1);
  }

  const trackingSet = new Set((tracking ?? []).map((row) => row.order_id));
  const invoiceSet = new Set((invoices ?? []).map((row) => row.order_id));

  return (
    <main className="min-h-screen p-6 space-y-6">
      <header className="space-y-2">
        <h1 className="text-2xl font-semibold">Goodcashback Importer</h1>
        <p className="text-sm text-slate-600">
          Welcome: {operator.full_name}
        </p>
        <div className="rounded-xl border bg-slate-50 p-4 text-sm text-slate-700">
          This is the importer dashboard. Next steps to wire after this page:
          create order, dynamic tracking submission, invoice upload, and OCR reconciliation workspace.
        </div>
      </header>

      <section className="grid gap-4 md:grid-cols-4">
        <div className="rounded-2xl border p-4">
          <div className="text-sm text-slate-500">Total orders</div>
          <div className="mt-2 text-2xl font-semibold">{orders?.length ?? 0}</div>
        </div>
        <div className="rounded-2xl border p-4">
          <div className="text-sm text-slate-500">Funded</div>
          <div className="mt-2 text-2xl font-semibold">
            {dashboardRows.filter((order) => !!order.funded_at).length}
          </div>
        </div>
        <div className="rounded-2xl border p-4">
          <div className="text-sm text-slate-500">Tracking submitted</div>
          <div className="mt-2 text-2xl font-semibold">{trackingSet.size}</div>
        </div>
        <div className="rounded-2xl border p-4">
          <div className="text-sm text-slate-500">Invoices submitted</div>
          <div className="mt-2 text-2xl font-semibold">{invoiceSet.size}</div>
        </div>
      </section>

      <section className="rounded-2xl border p-4">
        <div className="flex items-center justify-between gap-4">
          <div>
            <h2 className="text-lg font-semibold">Orders</h2>
            <p className="text-sm text-slate-600">
              Current importer order state and the next importer action.
            </p>
          </div>
          <Link
            href="/importer/orders/new"
            className="rounded-lg bg-slate-900 px-4 py-2 text-sm text-white"
          >
            Create order
          </Link>
        </div>

        <div className="mt-4 overflow-x-auto">
          <table className="min-w-full text-sm">
            <thead className="bg-slate-50 text-left">
              <tr>
                <th className="p-3">Order</th>
                <th className="p-3">Auth ref</th>
                <th className="p-3">Qty</th>
                <th className="p-3">Declared GBP</th>
                <th className="p-3">Quote local</th>
                <th className="p-3">Screenshots</th>
                <th className="p-3">Tracking</th>
                <th className="p-3">Invoice</th>
                <th className="p-3">Open queries</th>
                <th className="p-3">Status</th>
                <th className="p-3">Next action</th>
              </tr>
            </thead>
            <tbody>
              {dashboardRows.map((order) => {
                const hasTracking = trackingSet.has(order.id);
                const hasInvoice = invoiceSet.has(order.id);
                const screenshotCount = screenshotCounts.get(order.id) ?? 0;
                const openQuerySummary = openEvidenceQueryByOrderId.get(order.id);
                const hasOpenEvidenceQuery = (openQuerySummary?.count ?? 0) > 0;

                return (
                  <tr key={order.id} className="border-t">
                    <td className="p-3">
                      <div className="font-medium">{order.order_ref}</div>
                      <div className="text-xs text-slate-500">{order.id}</div>
                    </td>
                    <td className="p-3">{order.payment_auth_id ?? "—"}</td>
                    <td className="p-3">{order.total_qty_declared ?? 0}</td>
                    <td className="p-3">{gbp(order.order_total_gbp_declared)}</td>
                    <td className="p-3">{local(order.quote_total_ghs)}</td>
                    <td className="p-3">{screenshotCount}</td>
                    <td className="p-3">{hasTracking ? "Yes" : "No"}</td>
                    <td className="p-3">{hasInvoice ? "Yes" : "No"}</td>
                    <td className="p-3">
                      {openQuerySummary ? (
                        <div className="space-y-1">
                          <div className="font-medium">{openQuerySummary.count}</div>
                          <div className="text-xs text-slate-500">
                            {openQuerySummary.latestQueryType ?? "—"}
                          </div>
                          <div className="text-xs text-slate-500">
                            {previewMessage(openQuerySummary.latestMessage)}
                          </div>
                        </div>
                      ) : (
                        "0"
                      )}
                    </td>
                    <td className="p-3">
                      <div>{order.status}</div>
                      <div className="text-xs text-slate-500">
                        {order.funded_at ? "Funded" : "Open"}
                      </div>
                    </td>
                    <td className="p-3">
                      <div>{nextAction(order, hasOpenEvidenceQuery)}</div>
                      {hasOpenEvidenceQuery ? (
                        <Link href="/importer/evidence-queries" className="text-xs font-medium text-sky-600">
                          Answer
                        </Link>
                      ) : null}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </section>
    </main>
  );
}
