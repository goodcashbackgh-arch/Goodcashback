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

type DashboardOrderRow = OrderRow & { lifecycle_status: string | null };
type OrderReferenceRow = { order_id: string };
type InvoiceReferenceRow = { order_id: string; review_status: string | null; uploaded_at: string | null };
type OrderStateRow = { id: string; lifecycle_status: string | null };
type EvidenceQueryRow = { order_id: string; query_type: string | null; message: string | null };
type InvoiceLineProgressRow = { id: string; eligible_for_invoice_yn: string | null; supplier_invoices: { order_id: string }[] | { order_id: string } | null };
type DisputeLineLinkRow = { supplier_invoice_line_id: string | null };

function gbp(value: number | string | null | undefined) {
  const n = Number(value ?? 0);
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP", minimumFractionDigits: 2 }).format(n);
}

function previewMessage(value: string | null | undefined, max = 72) {
  const message = (value ?? "").trim();
  if (!message) return "—";
  if (message.length <= max) return message;
  return `${message.slice(0, max - 1)}…`;
}

function friendlyStatus(value: string | null | undefined) {
  if (!value) return "In progress";
  const normal = value.trim().toLowerCase();
  if (normal === "reconcilling" || normal === "reconciling") return "Reconciling";
  return value.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase());
}

function isProgressed(value: string | null | undefined) {
  return ["y", "yes", "true", "1"].includes((value ?? "").trim().toLowerCase());
}

function latestRejectedNeedsResubmission(invoices: InvoiceReferenceRow[]) {
  const sorted = [...invoices].sort((a, b) => new Date(b.uploaded_at ?? 0).getTime() - new Date(a.uploaded_at ?? 0).getTime());
  return sorted[0]?.review_status === "rejected_resubmit_required";
}

function nextAction(order: Pick<DashboardOrderRow, "lifecycle_status" | "funded_at">, hasOpenEvidenceQuery: boolean, needsInvoiceResubmission: boolean, reconciliationSummary?: { unresolvedCount: number; unresolvedNonExceptionCount: number }) {
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

function importerStatusLabel(order: Pick<DashboardOrderRow, "lifecycle_status" | "funded_at">, hasOpenEvidenceQuery: boolean, needsInvoiceResubmission: boolean, reconciliationSummary?: { unresolvedCount: number; unresolvedNonExceptionCount: number }) {
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

function statusPillClass(needsInvoiceResubmission: boolean, hasOpenEvidenceQuery: boolean, importerStatus: string) {
  if (needsInvoiceResubmission) return "border-rose-200 bg-rose-50 text-rose-800";
  if (hasOpenEvidenceQuery) return "border-amber-200 bg-amber-50 text-amber-800";
  if (importerStatus.includes("complete")) return "border-emerald-200 bg-emerald-50 text-emerald-800";
  return "border-slate-200 bg-slate-50 text-slate-700";
}

const primaryActionClass = "inline-flex min-h-9 items-center justify-center rounded-full bg-slate-950 px-3 py-1.5 text-xs font-semibold text-white shadow-sm hover:bg-slate-800";
const secondaryActionClass = "inline-flex min-h-9 items-center justify-center rounded-full border border-slate-200 bg-white px-3 py-1.5 text-xs font-semibold text-slate-700 shadow-sm hover:border-sky-300 hover:bg-sky-50 hover:text-sky-800";
const warningActionClass = "inline-flex min-h-9 items-center justify-center rounded-full bg-rose-700 px-3 py-1.5 text-xs font-semibold text-white shadow-sm hover:bg-rose-800";
const successActionClass = "inline-flex min-h-9 items-center justify-center rounded-full bg-emerald-700 px-3 py-1.5 text-xs font-semibold text-white shadow-sm hover:bg-emerald-800";

export default async function ImporterPage() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: operator } = await supabase.from("operators").select("id, full_name").eq("auth_user_id", user.id).eq("active", true).maybeSingle();
  if (!operator) redirect("/auth/check");

  const { data: customerPortalLink } = await supabase.from("operator_importers").select("id").eq("operator_id", operator.id).is("revoked_at", null).limit(1).maybeSingle();
  const canOpenCustomerPortal = Boolean(customerPortalLink);

  const [{ data: orders, error: ordersError }, { data: screenshots }, { data: tracking }, { data: invoices }] = await Promise.all([
    supabase.from("orders").select("id, order_ref, status, payment_auth_id, total_qty_declared, order_total_gbp_declared, quote_total_ghs, funded_at, created_at, retailers(name)").order("created_at", { ascending: false }),
    supabase.from("order_screenshots").select("order_id"),
    supabase.from("order_tracking_submissions").select("order_id, superseded_at").is("superseded_at", null),
    supabase.from("supplier_invoices").select("order_id, invoice_ref, review_status, uploaded_at"),
  ]);
  if (ordersError) throw ordersError;

  const orderRows = (orders ?? []) as unknown as OrderRow[];
  const orderIds = orderRows.map((order) => order.id);
  const { data: orderStates, error: orderStatesError } = orderIds.length ? await supabase.from("order_state_vw").select("id, lifecycle_status").in("id", orderIds) : { data: [], error: null };
  if (orderStatesError) throw orderStatesError;

  const lifecycleStatusByOrderId = new Map<string, string | null>();
  for (const row of (orderStates ?? []) as OrderStateRow[]) lifecycleStatusByOrderId.set(row.id, row.lifecycle_status);

  const dashboardRows: DashboardOrderRow[] = orderRows.map((order) => ({ ...order, lifecycle_status: lifecycleStatusByOrderId.get(order.id) ?? null }));

  const { data: openEvidenceQueries, error: openEvidenceQueriesError } = orderIds.length
    ? await supabase.from("order_evidence_queries").select("order_id, query_type, message, status, created_at").in("order_id", orderIds).eq("status", "open").order("created_at", { ascending: false })
    : { data: [], error: null };
  if (openEvidenceQueriesError) throw openEvidenceQueriesError;

  const openEvidenceQueryByOrderId = new Map<string, { count: number; latestQueryType: string | null; latestMessage: string | null }>();
  for (const query of (openEvidenceQueries ?? []) as EvidenceQueryRow[]) {
    const current = openEvidenceQueryByOrderId.get(query.order_id);
    if (!current) {
      openEvidenceQueryByOrderId.set(query.order_id, { count: 1, latestQueryType: query.query_type, latestMessage: query.message });
      continue;
    }
    current.count += 1;
  }

  const screenshotCounts = new Map<string, number>();
  for (const row of (screenshots ?? []) as OrderReferenceRow[]) screenshotCounts.set(row.order_id, (screenshotCounts.get(row.order_id) ?? 0) + 1);

  const trackingSet = new Set((tracking ?? []).map((row) => row.order_id));
  const invoiceRows = (invoices ?? []) as InvoiceReferenceRow[];
  const invoiceSet = new Set(invoiceRows.map((row) => row.order_id));
  const invoicesByOrderId = new Map<string, InvoiceReferenceRow[]>();
  for (const invoice of invoiceRows) {
    const current = invoicesByOrderId.get(invoice.order_id) ?? [];
    current.push(invoice);
    invoicesByOrderId.set(invoice.order_id, current);
  }

  const { data: invoiceLines } = orderIds.length ? await supabase.from("supplier_invoice_lines").select("id, eligible_for_invoice_yn, supplier_invoices!inner(order_id)").in("supplier_invoices.order_id", orderIds) : { data: [] };
  const invoiceLineRows = (invoiceLines ?? []) as InvoiceLineProgressRow[];
  const unresolvedLineIds = invoiceLineRows.filter((line) => !isProgressed(line.eligible_for_invoice_yn)).map((line) => line.id);
  const { data: disputeLineLinks } = unresolvedLineIds.length ? await supabase.from("dispute_lines").select("supplier_invoice_line_id").in("supplier_invoice_line_id", unresolvedLineIds) : { data: [] };
  const unresolvedLineLinkedToException = new Set(((disputeLineLinks ?? []) as DisputeLineLinkRow[]).map((row) => row.supplier_invoice_line_id).filter((value): value is string => typeof value === "string" && value.length > 0));

  const reconciliationByOrderId = new Map<string, { unresolvedCount: number; unresolvedNonExceptionCount: number }>();
  for (const line of invoiceLineRows) {
    const invoice = Array.isArray(line.supplier_invoices) ? line.supplier_invoices[0] : line.supplier_invoices;
    const orderId = invoice?.order_id;
    if (!orderId || isProgressed(line.eligible_for_invoice_yn)) continue;
    const current = reconciliationByOrderId.get(orderId) ?? { unresolvedCount: 0, unresolvedNonExceptionCount: 0 };
    current.unresolvedCount += 1;
    if (!unresolvedLineLinkedToException.has(line.id)) current.unresolvedNonExceptionCount += 1;
    reconciliationByOrderId.set(orderId, current);
  }

  const dashboardViewRows = dashboardRows.map((order) => {
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
    const canUploadInvoice = needsInvoiceResubmission || !hasInvoice;
    const canAddTracking = !needsInvoiceResubmission && !hasTracking;
    const canReconcile = !needsInvoiceResubmission && hasInvoice;
    const canAssignTracking = !needsInvoiceResubmission && hasInvoice && hasTracking;
    const showAssignAfterTracking = !needsInvoiceResubmission && hasInvoice && !hasTracking;
    return { order, hasTracking, hasInvoice, needsInvoiceResubmission, screenshotCount, openQuerySummary, hasOpenEvidenceQuery, importerNextAction, importerStatus, operationsHref, canUploadInvoice, canAddTracking, canReconcile, canAssignTracking, showAssignAfterTracking };
  });

  const resubmissionCount = dashboardViewRows.filter((row) => row.needsInvoiceResubmission).length;
  const openQueryCount = dashboardViewRows.filter((row) => row.hasOpenEvidenceQuery).length;

  return (
    <main className="min-h-screen space-y-6 bg-slate-50 p-4 md:p-6">
      <header className="overflow-hidden rounded-3xl border border-slate-200 bg-white shadow-sm">
        <div className="border-b border-slate-100 bg-gradient-to-br from-sky-50 via-white to-slate-50 p-5 md:p-6">
          <div className="flex flex-col gap-4 md:flex-row md:items-start md:justify-between">
            <div>
              <p className="text-xs font-semibold uppercase tracking-[0.22em] text-sky-700">Importer workspace</p>
              <h1 className="mt-2 text-2xl font-semibold tracking-tight text-slate-950 md:text-3xl">Goodcashback Importer</h1>
              <p className="mt-2 text-sm text-slate-600">Welcome, {operator.full_name}. Manage orders, invoice evidence, tracking and reconciliation from one control view.</p>
            </div>
            <div className="flex flex-wrap gap-2">
              <Link href="/importer/exceptions" className={secondaryActionClass}>Active exceptions</Link>
              <Link href="/importer/orders/new" className={primaryActionClass}>Create order</Link>
            </div>
          </div>
        </div>
      </header>

      {canOpenCustomerPortal ? (
        <section className="rounded-2xl border border-sky-200 bg-sky-50 p-4 text-sm text-slate-800 shadow-sm">
          <div className="flex flex-col gap-3 md:flex-row md:items-center md:justify-between">
            <div>
              <h2 className="text-base font-semibold text-slate-950">Customer lane available</h2>
              <p className="mt-1 text-slate-600">Open the customer dashboard to view ledger balance, order status, pro forma values and final invoice readiness.</p>
            </div>
            <Link href="/customer" className="inline-flex min-h-10 items-center justify-center rounded-full bg-sky-600 px-4 py-2 text-sm font-semibold text-white shadow-sm hover:bg-sky-700">Open Customer Portal</Link>
          </div>
        </section>
      ) : null}

      <section className="grid gap-3 md:grid-cols-5">
        <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm"><div className="text-xs font-medium uppercase tracking-wide text-slate-500">Total orders</div><div className="mt-2 text-2xl font-semibold text-slate-950">{orders?.length ?? 0}</div></div>
        <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm"><div className="text-xs font-medium uppercase tracking-wide text-slate-500">Funded</div><div className="mt-2 text-2xl font-semibold text-slate-950">{dashboardRows.filter((order) => !!order.funded_at).length}</div></div>
        <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm"><div className="text-xs font-medium uppercase tracking-wide text-slate-500">Tracking submitted</div><div className="mt-2 text-2xl font-semibold text-slate-950">{trackingSet.size}</div></div>
        <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm"><div className="text-xs font-medium uppercase tracking-wide text-slate-500">Invoices submitted</div><div className="mt-2 text-2xl font-semibold text-slate-950">{invoiceSet.size}</div></div>
        <div className={`rounded-2xl border p-4 shadow-sm ${resubmissionCount > 0 ? "border-rose-200 bg-rose-50" : "border-emerald-200 bg-emerald-50"}`}><div className={`text-xs font-medium uppercase tracking-wide ${resubmissionCount > 0 ? "text-rose-700" : "text-emerald-700"}`}>Needs action</div><div className={`mt-2 text-2xl font-semibold ${resubmissionCount > 0 ? "text-rose-900" : "text-emerald-900"}`}>{resubmissionCount + openQueryCount}</div></div>
      </section>

      <section className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm md:p-5">
        <div className="flex flex-col gap-3 md:flex-row md:items-center md:justify-between"><div><h2 className="text-lg font-semibold text-slate-950">Orders</h2><p className="text-sm text-slate-600">Current importer order state and the next importer action.</p></div><Link href="/importer/orders/new" className={primaryActionClass}>Create order</Link></div>

        <div className="mt-4 grid gap-3 lg:hidden">
          {dashboardViewRows.map((row) => (
            <article key={row.order.id} className={`rounded-2xl border p-4 shadow-sm ${row.needsInvoiceResubmission ? "border-rose-200 bg-rose-50" : "border-slate-200 bg-white"}`}>
              <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between"><div><div className="text-xs font-semibold uppercase tracking-wide text-slate-500">{row.order.retailers?.name ?? "Retailer not set"}</div><h3 className="mt-1 text-base font-semibold text-slate-950">{row.order.order_ref ?? row.order.id}</h3><p className="mt-1 break-all text-xs text-slate-500">{row.order.id}</p></div><span className={`w-fit rounded-full border px-3 py-1 text-xs font-semibold ${statusPillClass(row.needsInvoiceResubmission, row.hasOpenEvidenceQuery, row.importerStatus)}`}>{row.importerStatus}</span></div>
              <div className="mt-4 grid grid-cols-2 gap-3 text-sm sm:grid-cols-4">
                <div className="rounded-xl bg-white/70 p-3 ring-1 ring-slate-100"><div className="text-xs text-slate-500">Qty</div><div className="font-semibold text-slate-950">{row.order.total_qty_declared ?? 0}</div></div>
                <div className="rounded-xl bg-white/70 p-3 ring-1 ring-slate-100"><div className="text-xs text-slate-500">Declared GBP</div><div className="font-semibold text-slate-950">{gbp(row.order.order_total_gbp_declared)}</div></div>
                <div className="rounded-xl bg-white/70 p-3 ring-1 ring-slate-100"><div className="text-xs text-slate-500">Tracking</div><div className="font-semibold text-slate-950">{row.hasTracking ? "Yes" : "No"}</div></div>
                <div className="rounded-xl bg-white/70 p-3 ring-1 ring-slate-100"><div className="text-xs text-slate-500">Invoice</div><div className="font-semibold text-slate-950">{row.hasInvoice ? "Yes" : "No"}</div></div>
              </div>
              <div className="mt-4 rounded-xl border border-slate-200 bg-white/80 p-3 text-sm"><div className="text-xs font-semibold uppercase tracking-wide text-slate-500">Next action</div><div className={row.needsInvoiceResubmission ? "mt-1 font-semibold text-rose-700" : "mt-1 font-semibold text-slate-900"}>{row.importerNextAction}</div><div className="mt-1 text-xs text-slate-500">{row.order.funded_at ? "Funded" : "Open"} · Raw: {friendlyStatus(row.order.status)}</div></div>
              <div className="mt-4 flex flex-wrap gap-2">
                <Link className={secondaryActionClass} href={row.operationsHref}>Open order</Link>
                {row.canUploadInvoice ? <Link className={row.needsInvoiceResubmission ? warningActionClass : secondaryActionClass} href={`${row.operationsHref}#invoice`}>{row.needsInvoiceResubmission ? "Upload corrected invoice" : "Upload invoice"}</Link> : null}
                {row.canAddTracking ? <Link className={secondaryActionClass} href={`${row.operationsHref}#tracking`}>Add tracking</Link> : null}
                {row.canReconcile ? <Link className={secondaryActionClass} href={`/importer/reconciliation/${row.order.id}`}>Reconcile</Link> : null}
                {row.canAssignTracking ? <Link className={successActionClass} href={`/importer/delivery-allocation/${row.order.id}`}>Assign tracking</Link> : row.showAssignAfterTracking ? <span className="inline-flex min-h-9 items-center rounded-full border border-slate-200 bg-slate-100 px-3 py-1.5 text-xs font-semibold text-slate-400">Assign after tracking</span> : null}
                {row.hasOpenEvidenceQuery ? <Link href="/importer/evidence-queries" className={warningActionClass}>Answer query</Link> : null}
              </div>
            </article>
          ))}
        </div>

        <div className="mt-4 hidden overflow-x-auto rounded-2xl border border-slate-200 lg:block">
          <table className="min-w-full text-sm">
            <thead className="bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500"><tr><th className="p-3">Order</th><th className="p-3">Retailer</th><th className="p-3">Auth ref</th><th className="p-3">Qty</th><th className="p-3">Declared</th><th className="p-3">Evidence</th><th className="p-3">Status</th><th className="p-3">Next action</th><th className="p-3">Actions</th></tr></thead>
            <tbody className="divide-y divide-slate-100">
              {dashboardViewRows.map((row) => (
                <tr key={row.order.id} className={row.needsInvoiceResubmission ? "align-top bg-rose-50/70" : "align-top hover:bg-slate-50/80"}>
                  <td className="p-3"><div className="font-semibold text-slate-950">{row.order.order_ref}</div><div className="max-w-[180px] break-words text-xs text-slate-500">{row.order.id}</div></td>
                  <td className="p-3 font-medium text-slate-800">{row.order.retailers?.name ?? "—"}</td>
                  <td className="max-w-[180px] break-words p-3 text-slate-700">{row.order.payment_auth_id ?? "—"}</td>
                  <td className="p-3 text-slate-700">{row.order.total_qty_declared ?? 0}</td>
                  <td className="p-3 font-semibold text-slate-900">{gbp(row.order.order_total_gbp_declared)}</td>
                  <td className="p-3"><div className="flex flex-wrap gap-1.5"><span className="rounded-full bg-slate-100 px-2.5 py-1 text-xs font-medium text-slate-700">Screenshots {row.screenshotCount}</span><span className={`rounded-full px-2.5 py-1 text-xs font-medium ${row.hasTracking ? "bg-emerald-100 text-emerald-800" : "bg-slate-100 text-slate-600"}`}>Tracking {row.hasTracking ? "yes" : "no"}</span><span className={`rounded-full px-2.5 py-1 text-xs font-medium ${row.needsInvoiceResubmission ? "bg-rose-100 text-rose-800" : row.hasInvoice ? "bg-emerald-100 text-emerald-800" : "bg-slate-100 text-slate-600"}`}>{row.needsInvoiceResubmission ? "Invoice resubmit" : row.hasInvoice ? "Invoice yes" : "Invoice no"}</span></div></td>
                  <td className="p-3"><span className={`inline-flex rounded-full border px-3 py-1 text-xs font-semibold ${statusPillClass(row.needsInvoiceResubmission, row.hasOpenEvidenceQuery, row.importerStatus)}`}>{row.importerStatus}</span><div className="mt-1 text-xs text-slate-500">{row.order.funded_at ? "Funded" : "Open"} · Raw: {friendlyStatus(row.order.status)}</div>{row.openQuerySummary ? <div className="mt-2 text-xs text-slate-500">Query: {previewMessage(row.openQuerySummary.latestMessage)}</div> : null}</td>
                  <td className="p-3"><div className={row.needsInvoiceResubmission ? "font-semibold text-rose-700" : "font-semibold text-slate-900"}>{row.importerNextAction}</div>{row.hasOpenEvidenceQuery ? <Link href="/importer/evidence-queries" className="mt-1 inline-flex text-xs font-semibold text-sky-700 hover:underline">Answer query</Link> : null}</td>
                  <td className="p-3"><div className="flex max-w-[360px] flex-wrap gap-2"><Link className={secondaryActionClass} href={row.operationsHref}>Open</Link>{row.canUploadInvoice ? <Link className={row.needsInvoiceResubmission ? warningActionClass : secondaryActionClass} href={`${row.operationsHref}#invoice`}>{row.needsInvoiceResubmission ? "Upload corrected invoice" : "Upload invoice"}</Link> : null}{row.canAddTracking ? <Link className={secondaryActionClass} href={`${row.operationsHref}#tracking`}>Add tracking</Link> : null}{row.canReconcile ? <Link className={secondaryActionClass} href={`/importer/reconciliation/${row.order.id}`}>Reconcile</Link> : null}{row.canAssignTracking ? <Link className={successActionClass} href={`/importer/delivery-allocation/${row.order.id}`}>Assign tracking</Link> : row.showAssignAfterTracking ? <span className="inline-flex min-h-9 items-center rounded-full border border-slate-200 bg-slate-100 px-3 py-1.5 text-xs font-semibold text-slate-400">Assign after tracking</span> : null}</div></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>
    </main>
  );
}
