import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

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

function nextAction(order: any, hasTracking: boolean, hasInvoice: boolean) {
  if (!order.funded_at) return "Waiting for staff funding";
  if (!hasTracking && !hasInvoice) return "Submit tracking or invoice";
  if (!hasTracking) return "Submit tracking";
  if (!hasInvoice) return "Submit invoice";
  return "Open reconciliation / monitor progress";
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

  const screenshotCounts = new Map<string, number>();
  for (const row of screenshots ?? []) {
    screenshotCounts.set(row.order_id, (screenshotCounts.get(row.order_id) ?? 0) + 1);
  }

  const trackingSet = new Set((tracking ?? []).map((row: any) => row.order_id));
  const invoiceSet = new Set((invoices ?? []).map((row: any) => row.order_id));

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
            {(orders ?? []).filter((o: any) => !!o.funded_at).length}
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
                <th className="p-3">Status</th>
                <th className="p-3">Next action</th>
              </tr>
            </thead>
            <tbody>
              {(orders ?? []).map((order: any) => {
                const hasTracking = trackingSet.has(order.id);
                const hasInvoice = invoiceSet.has(order.id);
                const screenshotCount = screenshotCounts.get(order.id) ?? 0;

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
                      <div>{order.status}</div>
                      <div className="text-xs text-slate-500">
                        {order.funded_at ? "Funded" : "Open"}
                      </div>
                    </td>
                    <td className="p-3">{nextAction(order, hasTracking, hasInvoice)}</td>
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