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
  retailers: { name: string | null } | null;
};

type DashboardOrderRow = OrderRow & {
  lifecycle_status: string | null;
};

type OrderReferenceRow = { order_id: string };
type InvoiceReferenceRow = { order_id: string; review_status: string | null; uploaded_at: string | null };
type OrderStateRow = { id: string; lifecycle_status: string | null };

type EvidenceQueryRow = {
  order_id: string;
  query_type: string | null;
  message: string | null;
};

type InvoiceLineProgressRow = {
  id: string;
  eligible_for_invoice_yn: string | null;
  supplier_invoices: { order_id: string }[] | { order_id: string } | null;
};

type DisputeLineLinkRow = {
  supplier_invoice_line_id: string | null;
};

function gbp(value: number | string | null | undefined) {
  const n = Number(value ?? 0);
  return new Intl.NumberFormat("en-GB", {
    style: "currency",
    currency: "GBP",
    minimumFractionDigits: 2,
  }).format(n);
}

function previewMessage(value: string | null | undefined, max = 72) {
  const message = (value ?? "").trim();
  if (!message) return "—";
  if (message.length <= max) return message;
  return `${message.slice(0, max - 1)}…`;
}

function friendlyStatus(value: string | null | undefined) {
  if (!value) return "In progress";
  return value.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase());
}

function isProgressed(value: string | null | undefined) {
  return ["y", "yes", "true", "1"].includes((value ?? "").trim().toLowerCase());
}

function latestRejectedNeedsResubmission(invoices: InvoiceReferenceRow[]) {
  const sorted = [...invoices].sort((a, b) => new Date(b.uploaded_at ?? 0).getTime() - new Date(a.uploaded_at ?? 0).getTime());
  const latest = sorted[0];
  return latest?.review_status === "rejected_resubmit_required";
}

function nextAction(
  order: Pick<DashboardOrderRow, "lifecycle_status" | "funded_at">,
  hasOpenEvidenceQuery: boolean,
  needsInvoiceResubmission: boolean,
  reconciliationSummary?: { unresolvedCount: number; unresolvedNonExceptionCount: number }
) {
  if (needsInvoiceResubmission) return "Upload corrected invoice";
  if (hasOpenEvidenceQuery) return "Answer evidence query";
  if (order.lifecycle_status === "partially_progressed") {
    if (!reconciliationSummary) return "Continue invoice reconciliation";
    if (reconciliationSummary.unresolvedNonExceptionCount > 0) return "Continue invoice reconciliation";
    if (reconciliationSummary.unresolvedCount > 0) return "Exception branches in progress";
    return "No importer reconciliation action required";
  }
  if (order.lifecycle_status === "reconciling") return "Awaiting invoice reconciliation";
  if (order.lifecycle_status === "evidence_collecting") return "Upload invoice or tracking";
  if (!order.funded_at) return "No importer action required";
  return "In progress";
}

function importerStatusLabel(
  order: Pick<DashboardOrderRow, "lifecycle_status" | "funded_at">,
  hasOpenEvidenceQuery: boolean,
  needsInvoiceResubmission: boolean,
  reconciliationSummary?: { unresolvedCount: number; unresolvedNonExceptionCount: number }
) {
  if (needsInvoiceResubmission) return "Invoice resubmission required";
  if (hasOpenEvidenceQuery) return "Evidence query open";
  if (order.lifecycle_status === "partially_progressed" && reconciliationSummary) {
    if (reconciliationSummary.unresolvedNonExceptionCount > 0) return "Invoice reconciliation open";
    if (reconciliationSummary.unresolvedCount > 0) return "Exception branch in progress";
    return "Importer reconciliation complete";
  }
  if (order.lifecycle_status) return friendlyStatus(order.lifecycle_status);
  return order.funded_at ? "Funded" : "Open";
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

  const { data: customerPortalLink } = await supabase
    .from("operator_importers")
    .select("id")
    .eq("operator_id", operator.id)
    .is("revoked_at", null)
    .limit(1)
    .maybeSingle();

  const canOpenCustomerPortal = Boolean(customerPortalLink);

  const [{ data: orders, error: ordersError }, { data: screenshots }, { data: tracking }, { data: invoices }] =
    await Promise.all([
      supabase
        .from("orders")
        .select(
          "id, order_ref, status, payment_auth_id, total_qty_declared, order_total_gbp_declared, quote_total_ghs, funded_at, created_at, retailers(name)"
        )
        .order("created_at", { ascending: false }),
      supabase.from("order_screenshots").select("order_id"),
      supabase
        .from("order_tracking_submissions")
        .select("order_id, superseded_at")
        .is("superseded_at", null),
      supabase.from("supplier_invoices").select("order_id, invoice_ref, review_status, uploaded_at"),
    ]);

  if (ordersError) {
    throw ordersError;
  }

  const orderRows = (orders ?? []) as unknown as OrderRow[];
  const orderIds = orderRows.map((order) => order.id);
  const { data: orderStates, error: orderStatesError } = orderIds.length
    ? await supabase.from("order_state_vw").select("id, lifecycle_status").in("id", orderIds)
    : { data: [], error: null };

  if (orderStatesError) {
    throw orderStatesError;
  }

  const lifecycleStatusByOrderId = new Map<string, string | null>();
  for (const row of (orderStates ?? []) as OrderStateRow[]) {
    lifecycleStatusByOrderId.set(row.id, row.lifecycle_status);
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
  const invoiceRows = (invoices ?? []) as InvoiceReferenceRow[];
  const invoiceSet = new Set(invoiceRows.map((row) => row.order_id));
  const invoicesByOrderId = new Map<string, InvoiceReferenceRow[]>();
  for (const invoice of invoiceRows) {
    const current = invoicesByOrderId.get(invoice.order_id) ?? [];
    current.push(invoice);
    invoicesByOrderId.set(invoice.order_id, current);
  }

  const { data: invoiceLines } = orderIds.length
    ? await supabase
        .from("supplier_invoice_lines")
        .select("id, eligible_for_invoice_yn, supplier_invoices!inner(order_id)")
        .in("supplier_invoices.order_id", orderIds)
    : { data: [] };

  const invoiceLineRows = (invoiceLines ?? []) as InvoiceLineProgressRow[];
  const unresolvedLineIds = invoiceLineRows.filter((line) => !isProgressed(line.eligible_for_invoice_yn)).map((line) => line.id);
  const { data: disputeLineLinks } = unresolvedLineIds.length
    ? await supabase
        .from("dispute_lines")
        .select("supplier_invoice_line_id")
        .in("supplier_invoice_line_id", unresolvedLineIds)
    : { data: [] };

  const unresolvedLineLinkedToException = new Set(
    ((disputeLineLinks ?? []) as DisputeLineLinkRow[])
      .map((row) => row.supplier_invoice_line_id)
      .filter((value): value is string => typeof value === "string" && value.length > 0)
  );

  const reconciliationByOrderId = new Map<string, { unresolvedCount: number; unresolvedNonExceptionCount: number }>();
  for (const line of invoiceLineRows) {
    const invoice = Array.isArray(line.supplier_invoices) ? line.supplier_invoices[0] : line.supplier_invoices;
    const orderId = invoice?.order_id;
    if (!orderId || isProgressed(line.eligible_for_invoice_yn)) continue;

    const current = reconciliationByOrderId.get(orderId) ?? { unresolvedCount: 0, unresolvedNonExceptionCount: 0 };
    current.unresolvedCount += 1;
    if (!unresolvedLineLinkedToException.has(line.id)) {
      current.unresolvedNonExceptionCount += 1;
    }
    reconciliationByOrderId.set(orderId, current);
  }

  return (
    <main className="min-h-screen p-6 space-y-6">
      <header className="space-y-2">
        <h1 className="text-2xl font-semibold">Goodcashback Importer</h1>
        <p className="text-sm text-slate-600">
          Welcome: {operator.full_name}
        </p>
        <div className="rounded-xl border bg-slate-50 p-4 text-sm text-slate-700">
          Manage orders, upload invoices, add tracking, and continue reconciliation from one dashboard.
          <div className="mt-3">
            <Link href="/importer/exceptions" className="font-semibold text-sky-700 underline">View active exception cases</Link>
            <span className="mx-2">·</span>
            <Link href="/importer/orders/new" className="font-semibold text-sky-700 underline">Create new order</Link>
          </div>
        </div>
      </header>

      {canOpenCustomerPortal ? (
        <section className="rounded-2xl border border-sky-200 bg-sky-50 p-4 text-sm text-slate-800">
          <div className="flex flex-col gap-3 md:flex-row md:items-center md:justify-between">
            <div>
              <h2 className="text-base font-semibold text-slate-950">Customer lane available</h2>
              <p className="mt-1 text-slate-600">Open the customer dashboard to view ledger balance, order status, pro forma values and final invoice readiness.</p>
            </div>
            <Link href="/customer" className="rounded-lg bg-sky-600 px-4 py-2 text-center font-semibold text-white">Open Customer Portal</Link>
          </div>
        </section>
      ) : null}

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
                <th className="p-3">Retailer</th>
                <th className="p-3">Auth ref</th>
                <th className="p-3">Qty</th>
                <th className="p-3">Declared GBP</th>
                <th className="p-3">Screenshots</th>
                <th className="p-3">Tracking</th>
                <th className="p-3">Invoice</th>
                <th className="p-3">Open queries</th>
                <th className="p-3">Status</th>
                <th className="p-3">Next action</th>
                <th className="p-3">Actions</th>
              </tr>
            </thead>
            <tbody>
              {dashboardRows.map((order) => {
                const hasTracking = trackingSet.has(order.id);
                const orderInvoices = invoicesByOrderId.get(order.id) ?? [];
                const hasInvoice = orderInvoices.length > 0;
                const needsInvoiceResubmission = latestRejectedNeedsResubmission(orderInvoices);
                const screenshotCount = screenshotCounts.get(order.id) ?? 0;
                const openQuerySummary = openEvidenceQueryByOrderId.get(order.id);
                const hasOpenEvidenceQuery = (openQuerySummary?.count ?? 0) > 0;
                const reconciliationSummary = reconciliationByOrderId.get(order.id) ?? (hasInvoice ? { unresolvedCount: 0, unresolvedNonExceptionCount: 0 } : undefined);
                const importerNextAction = nextAction(order, hasOpenEvidenceQuery, needsInvoiceResubmission, reconciliationSummary);
                const importerStatus = importerStatusLabel(order, hasOpenEvidenceQuery, needsInvoiceResubmission, reconciliationSummary);
                const operationsHref = `/importer/orders/${order.id}/operations`;

                return (
                  <tr key={order.id} className="border-t align-top">
                    <td className="p-3">
                      <div className="font-medium">{order.order_ref}</div>
                      <div className="text-xs text-slate-500">{order.id}</div>
                    </td>
                    <td className="p-3">{order.retailers?.name ?? "—"}</td>
                    <td className="p-3">{order.payment_auth_id ?? "—"}</td>
                    <td className="p-3">{order.total_qty_declared ?? 0}</td>
                    <td className="p-3">{gbp(order.order_total_gbp_declared)}</td>
                    <td className="p-3">{screenshotCount}</td>
                    <td className="p-3">{hasTracking ? "Yes" : "No"}</td>
                    <td className="p-3">
                      <div>{hasInvoice ? "Yes" : "No"}</div>
                      {needsInvoiceResubmission ? <div className="mt-1 rounded bg-rose-100 px-2 py-1 text-xs font-medium text-rose-800">Resubmit required</div> : null}
                    </td>
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
                      <div className="font-medium">{importerStatus}</div>
                      <div className="text-xs text-slate-500">
                        {order.funded_at ? "Funded" : "Open"} · Raw: {friendlyStatus(order.status)}
                      </div>
                    </td>
                    <td className="p-3">
                      <div className={needsInvoiceResubmission ? "font-semibold text-rose-700" : ""}>{importerNextAction}</div>
                      {hasOpenEvidenceQuery ? (
                        <Link href="/importer/evidence-queries" className="text-xs font-medium text-sky-600">
                          Answer
                        </Link>
                      ) : null}
                    </td>
                    <td className="p-3">
                      <div className="flex flex-col gap-1 whitespace-nowrap">
                        <Link className="text-sky-700 underline" href={operationsHref}>Open</Link>
                        <Link className={needsInvoiceResubmission ? "font-semibold text-rose-700 underline" : "text-sky-700 underline"} href={`${operationsHref}#invoice`}>{needsInvoiceResubmission ? "Upload corrected invoice" : "Upload invoice"}</Link>
                        <Link className="text-sky-700 underline" href={`${operationsHref}#tracking`}>Add tracking</Link>
                        {hasInvoice ? <Link className="text-sky-700 underline" href={`/importer/reconciliation/${order.id}`}>Reconcile</Link> : null}
                        {hasInvoice && hasTracking ? (
                          <Link className="font-semibold text-emerald-700 underline" href={`/importer/delivery-allocation/${order.id}`}>Assign tracking to items</Link>
                        ) : hasInvoice ? (
                          <span className="text-xs text-slate-400">Assign items after tracking</span>
                        ) : null}
                      </div>
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
