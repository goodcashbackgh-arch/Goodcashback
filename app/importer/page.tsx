import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { cleanUiText } from "@/lib/ui/cleanUiText";

type OrderRow = {
  id: string;
  order_ref: string | null;
  status: string | null;
  payment_auth_id: string | null;
  total_qty_declared: number | null;
  order_total_gbp_declared: number | null;
  funded_at: string | null;
  created_at: string | null;
  retailers: { name: string | null } | null;
};

type RefRow = { order_id: string };
type InvoiceRow = { order_id: string; review_status: string | null };
type AudienceStatusRow = {
  order_id: string;
  accepted_estimate_gbp: number | string | null;
  final_sale_value_gbp: number | string | null;
  canonical_amount_received_gbp: number | string | null;
  canonical_balance_due_gbp: number | string | null;
  potential_credit_pending_review_gbp: number | string | null;
  customer_sales_state: string | null;
  importer_status_label: string | null;
  importer_next_action: string | null;
};
type LineRow = { id: string; eligible_for_invoice_yn: string | null; supplier_invoices: { order_id: string }[] | { order_id: string } | null };
type DisputeLineRow = { supplier_invoice_line_id: string | null };
type QueryRow = { order_id: string; message: string | null };

const retiredInvoiceStatuses = new Set(["rejected_resubmit_required", "superseded", "duplicate_blocked"]);
const primaryActionClass = "inline-flex min-h-9 items-center justify-center rounded-full bg-slate-950 px-3 py-1.5 text-xs font-semibold text-white shadow-sm hover:bg-slate-800";
const secondaryActionClass = "inline-flex min-h-9 items-center justify-center rounded-full border border-slate-200 bg-white px-3 py-1.5 text-xs font-semibold text-slate-700 shadow-sm hover:border-sky-300 hover:bg-sky-50 hover:text-sky-800";
const warningActionClass = "inline-flex min-h-9 items-center justify-center rounded-full bg-rose-700 px-3 py-1.5 text-xs font-semibold text-white shadow-sm hover:bg-rose-800";
const successActionClass = "inline-flex min-h-9 items-center justify-center rounded-full bg-emerald-700 px-3 py-1.5 text-xs font-semibold text-white shadow-sm hover:bg-emerald-800";

function gbp(value: number | string | null | undefined) {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP", minimumFractionDigits: 2 }).format(Number(value ?? 0));
}

function friendlyStatus(value: string | null | undefined) {
  if (!value) return "In progress";
  const normal = value.trim().toLowerCase();
  if (normal === "reconcilling" || normal === "reconciling") return "Matching";
  return cleanUiText(value.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase()));
}

function isProgressed(value: string | null | undefined) {
  return ["y", "yes", "true", "1"].includes((value ?? "").trim().toLowerCase());
}

function needsInvoiceResubmission(invoices: InvoiceRow[]) {
  const hasRejected = invoices.some((invoice) => invoice.review_status === "rejected_resubmit_required");
  const hasLiveInvoice = invoices.some((invoice) => !retiredInvoiceStatuses.has(invoice.review_status ?? "pending_review"));
  return hasRejected && !hasLiveInvoice;
}

function statusClass(needsResubmission: boolean, hasQuery: boolean, status: string, balanceDueGbp = 0, canonicalMissing = false) {
  if (canonicalMissing) return "border-slate-200 bg-slate-50 text-slate-600";
  if (needsResubmission) return "border-rose-200 bg-rose-50 text-rose-800";
  if (hasQuery || balanceDueGbp > 0.01) return "border-amber-200 bg-amber-50 text-amber-800";
  if (status.toLowerCase().includes("complete")) return "border-emerald-200 bg-emerald-50 text-emerald-800";
  return "border-slate-200 bg-slate-50 text-slate-700";
}

export default async function ImporterPage() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: operator } = await supabase.from("operators").select("id, full_name").eq("auth_user_id", user.id).eq("active", true).maybeSingle();
  if (!operator) redirect("/auth/check");

  const [{ data: orders, error: ordersError }, { data: screenshots }, { data: tracking }, { data: invoices }] = await Promise.all([
    supabase.from("orders").select("id, order_ref, status, payment_auth_id, total_qty_declared, order_total_gbp_declared, funded_at, created_at, retailers(name)").order("created_at", { ascending: false }),
    supabase.from("order_screenshots").select("order_id"),
    supabase.from("order_tracking_submissions").select("order_id, superseded_at").is("superseded_at", null),
    supabase.from("supplier_invoices").select("order_id, review_status"),
  ]);
  if (ordersError) throw ordersError;

  const orderRows = (orders ?? []) as unknown as OrderRow[];
  const orderIds = orderRows.map((order) => order.id);

  const [{ data: openQueries, error: queryError }, { data: invoiceLines }, { data: disputeLines }, { data: audienceStatuses, error: audienceStatusError }] = await Promise.all([
    orderIds.length ? supabase.from("order_evidence_queries").select("order_id, message, status, created_at").in("order_id", orderIds).eq("status", "open").order("created_at", { ascending: false }) : { data: [], error: null },
    orderIds.length ? supabase.from("supplier_invoice_lines").select("id, eligible_for_invoice_yn, supplier_invoices!inner(order_id)").in("supplier_invoices.order_id", orderIds) : { data: [] },
    supabase.from("dispute_lines").select("supplier_invoice_line_id"),
    orderIds.length ? supabase.rpc("order_audience_status_v1", { p_order_id: null }) : { data: [], error: null },
  ]);
  if (queryError) throw queryError;
  if (audienceStatusError) throw audienceStatusError;

  const screenshotCountByOrderId = new Map<string, number>();
  for (const row of (screenshots ?? []) as RefRow[]) screenshotCountByOrderId.set(row.order_id, (screenshotCountByOrderId.get(row.order_id) ?? 0) + 1);

  const trackingSet = new Set(((tracking ?? []) as RefRow[]).map((row) => row.order_id));

  const invoicesByOrderId = new Map<string, InvoiceRow[]>();
  for (const invoice of (invoices ?? []) as InvoiceRow[]) {
    const current = invoicesByOrderId.get(invoice.order_id) ?? [];
    current.push(invoice);
    invoicesByOrderId.set(invoice.order_id, current);
  }

  const queryByOrderId = new Map<string, { count: number; message: string | null }>();
  for (const query of (openQueries ?? []) as QueryRow[]) {
    const current = queryByOrderId.get(query.order_id);
    if (!current) queryByOrderId.set(query.order_id, { count: 1, message: query.message });
    else current.count += 1;
  }

  const exceptionLineIds = new Set(((disputeLines ?? []) as DisputeLineRow[]).map((row) => row.supplier_invoice_line_id).filter((value): value is string => Boolean(value)));
  const reconciliationByOrderId = new Map<string, { unresolvedCount: number; unresolvedNonExceptionCount: number }>();
  for (const line of (invoiceLines ?? []) as LineRow[]) {
    if (isProgressed(line.eligible_for_invoice_yn)) continue;
    const invoice = Array.isArray(line.supplier_invoices) ? line.supplier_invoices[0] : line.supplier_invoices;
    const orderId = invoice?.order_id;
    if (!orderId) continue;
    const current = reconciliationByOrderId.get(orderId) ?? { unresolvedCount: 0, unresolvedNonExceptionCount: 0 };
    current.unresolvedCount += 1;
    if (!exceptionLineIds.has(line.id)) current.unresolvedNonExceptionCount += 1;
    reconciliationByOrderId.set(orderId, current);
  }

  const audienceByOrderId = new Map<string, AudienceStatusRow>();
  for (const audienceStatus of (audienceStatuses ?? []) as AudienceStatusRow[]) audienceByOrderId.set(audienceStatus.order_id, audienceStatus);

  const rows = orderRows.map((order) => {
    const orderInvoices = invoicesByOrderId.get(order.id) ?? [];
    const hasInvoice = orderInvoices.length > 0;
    const hasTracking = trackingSet.has(order.id);
    const needsResubmission = needsInvoiceResubmission(orderInvoices);
    const querySummary = queryByOrderId.get(order.id);
    const rec = reconciliationByOrderId.get(order.id) ?? { unresolvedCount: 0, unresolvedNonExceptionCount: 0 };
    const audienceStatus = audienceByOrderId.get(order.id);
    const canonicalMissing = !audienceStatus?.importer_status_label || !audienceStatus?.importer_next_action;
    const acceptedEstimateGbp = Number(audienceStatus?.accepted_estimate_gbp ?? order.order_total_gbp_declared ?? 0);
    const finalSaleValueGbp = Number(audienceStatus?.final_sale_value_gbp ?? acceptedEstimateGbp);
    const amountReceivedGbp = Number(audienceStatus?.canonical_amount_received_gbp ?? 0);
    const finalBalanceDueGbp = canonicalMissing ? 0 : Number(audienceStatus?.canonical_balance_due_gbp ?? 0);
    const pendingCreditGbp = canonicalMissing ? 0 : Number(audienceStatus?.potential_credit_pending_review_gbp ?? 0);
    const status = {
      status: canonicalMissing ? "Status unavailable" : cleanUiText(audienceStatus!.importer_status_label!),
      action: canonicalMissing ? "Open order for details" : cleanUiText(audienceStatus!.importer_next_action!),
    };
    return { order, hasInvoice, hasTracking, needsResubmission, querySummary, rec, status, screenshotCount: screenshotCountByOrderId.get(order.id) ?? 0, acceptedEstimateGbp, finalSaleValueGbp, finalSaleConfirmed: audienceStatus?.customer_sales_state === "posted", finalBalanceDueGbp, pendingCreditGbp, amountReceivedGbp, canonicalMissing };
  });

  const resubmissionCount = rows.filter((row) => row.needsResubmission).length;
  const openQueryCount = rows.filter((row) => Boolean(row.querySummary?.count)).length;
  const finalBalanceCount = rows.filter((row) => row.finalBalanceDueGbp > 0.01).length;
  const invoiceOrderCount = invoicesByOrderId.size;

  return (
    <main className="min-h-screen space-y-6 bg-slate-50 p-4 md:p-6">
      <header className="overflow-hidden rounded-3xl border border-slate-200 bg-white shadow-sm">
        <div className="border-b border-slate-100 bg-gradient-to-br from-sky-50 via-white to-slate-50 p-5 md:p-6">
          <div className="flex flex-col gap-4 md:flex-row md:items-start md:justify-between">
            <div>
              <p className="text-xs font-semibold uppercase tracking-[0.22em] text-sky-700">Importer workspace</p>
              <h1 className="mt-2 text-2xl font-semibold tracking-tight text-slate-950 md:text-3xl">Goodcashback Importer</h1>
              <p className="mt-2 text-sm text-slate-600">Welcome, {operator.full_name}. Manage orders, evidence, tracking, matching and remaining order balances from one control view.</p>
            </div>
            <div className="flex flex-wrap gap-2">
              <Link href="/importer/exceptions" className={secondaryActionClass}>Active exceptions</Link>
              <Link href="/importer/orders/new" className={primaryActionClass}>Create order</Link>
            </div>
          </div>
        </div>
      </header>

      <section className="grid gap-3 md:grid-cols-5">
        <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm"><div className="text-xs font-medium uppercase tracking-wide text-slate-500">Total orders</div><div className="mt-2 text-2xl font-semibold text-slate-950">{rows.length}</div></div>
        <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm"><div className="text-xs font-medium uppercase tracking-wide text-slate-500">Initial payment received</div><div className="mt-2 text-2xl font-semibold text-slate-950">{orderRows.filter((order) => !!order.funded_at).length}</div></div>
        <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm"><div className="text-xs font-medium uppercase tracking-wide text-slate-500">Tracking submitted</div><div className="mt-2 text-2xl font-semibold text-slate-950">{trackingSet.size}</div></div>
        <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm"><div className="text-xs font-medium uppercase tracking-wide text-slate-500">Order evidence submitted</div><div className="mt-2 text-2xl font-semibold text-slate-950">{invoiceOrderCount}</div></div>
        <div className={`rounded-2xl border p-4 shadow-sm ${resubmissionCount + finalBalanceCount > 0 ? "border-amber-200 bg-amber-50" : "border-emerald-200 bg-emerald-50"}`}><div className={`text-xs font-medium uppercase tracking-wide ${resubmissionCount + finalBalanceCount > 0 ? "text-amber-700" : "text-emerald-700"}`}>Needs action</div><div className={`mt-2 text-2xl font-semibold ${resubmissionCount + finalBalanceCount > 0 ? "text-amber-900" : "text-emerald-900"}`}>{resubmissionCount + openQueryCount + finalBalanceCount}</div></div>
      </section>

      <section className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm md:p-5">
        <div className="flex flex-col gap-3 md:flex-row md:items-center md:justify-between"><div><h2 className="text-lg font-semibold text-slate-950">Orders</h2><p className="text-sm text-slate-600">Current importer order state, final order value and next importer action.</p></div><Link href="/importer/orders/new" className={primaryActionClass}>Create order</Link></div>
        <div className="mt-4 grid gap-3">
          {rows.map((row) => {
            const operationsHref = `/importer/orders/${row.order.id}/operations`;
            const canUploadInvoice = row.needsResubmission || !row.hasInvoice;
            const canAddTracking = !row.needsResubmission && !row.hasTracking;
            const canReconcile = !row.needsResubmission && row.hasInvoice;
            const canAssignTracking = !row.needsResubmission && row.hasInvoice && row.hasTracking;
            return (
              <article key={row.order.id} className={`rounded-2xl border p-4 shadow-sm ${row.needsResubmission ? "border-rose-200 bg-rose-50" : row.finalBalanceDueGbp > 0.01 ? "border-amber-200 bg-amber-50" : "border-slate-200 bg-white"}`}>
                <div className="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
                  <div><div className="text-xs font-semibold uppercase tracking-wide text-slate-500">{row.order.retailers?.name ?? "Retailer not set"}</div><h3 className="mt-1 text-base font-semibold text-slate-950">{row.order.order_ref ?? row.order.id}</h3><p className="mt-1 break-all text-xs text-slate-500">Payment reference: {row.order.payment_auth_id ?? "Not assigned"}</p></div>
                  <span className={`w-fit rounded-full border px-3 py-1 text-xs font-semibold ${statusClass(row.needsResubmission, Boolean(row.querySummary?.count), row.status.status, row.finalBalanceDueGbp, row.canonicalMissing)}`}>{row.status.status}</span>
                </div>
                {row.canonicalMissing ? <p className="mt-3 rounded-xl border border-slate-200 bg-slate-50 p-3 text-xs text-slate-600">Order status is unavailable for this order, so no remaining balance is shown here.</p> : null}
                <div className="mt-4 grid grid-cols-2 gap-3 text-sm md:grid-cols-4">
                  <div className="rounded-xl bg-white/70 p-3 ring-1 ring-slate-100"><div className="text-xs text-slate-500">Qty</div><div className="font-semibold text-slate-950">{row.order.total_qty_declared ?? 0}</div></div>
                  <div className="rounded-xl bg-white/70 p-3 ring-1 ring-slate-100"><div className="text-xs text-slate-500">Accepted estimate</div><div className="font-semibold text-slate-950">{gbp(row.acceptedEstimateGbp)}</div></div>
                  {row.finalSaleConfirmed ? <div className="rounded-xl bg-white/70 p-3 ring-1 ring-slate-100"><div className="text-xs text-slate-500">Final order value</div><div className="font-semibold text-slate-950">{gbp(row.finalSaleValueGbp)}</div>{row.finalBalanceDueGbp > 0.01 ? <div className="mt-1 text-[11px] text-amber-700">Remaining balance {gbp(row.finalBalanceDueGbp)}</div> : null}{row.pendingCreditGbp > 0.01 ? <div className="mt-1 text-[11px] text-amber-700">Potential credit pending review {gbp(row.pendingCreditGbp)}</div> : null}</div> : null}
                  <div className="rounded-xl bg-white/70 p-3 ring-1 ring-slate-100"><div className="text-xs text-slate-500">Tracking / evidence</div><div className="font-semibold text-slate-950">{row.hasTracking ? "Tracking yes" : "Tracking no"}</div><div className="mt-1 text-[11px] text-slate-500">Evidence {row.hasInvoice ? "yes" : "no"}</div></div>
                </div>
                <div className="mt-4 rounded-xl border border-slate-200 bg-white/80 p-3 text-sm"><div className="text-xs font-semibold uppercase tracking-wide text-slate-500">Next action</div><div className={row.needsResubmission ? "mt-1 font-semibold text-rose-700" : row.finalBalanceDueGbp > 0.01 ? "mt-1 font-semibold text-amber-800" : "mt-1 font-semibold text-slate-900"}>{row.status.action}</div><div className="mt-1 text-xs text-slate-500">{row.order.funded_at ? "Initial payment received" : "Open"} · Raw: {friendlyStatus(row.order.status)}</div></div>
                <div className="mt-4 flex flex-wrap gap-2">
                  <Link className={secondaryActionClass} href={operationsHref}>Open order</Link>
                  {canUploadInvoice ? <Link className={row.needsResubmission ? warningActionClass : secondaryActionClass} href={`${operationsHref}#invoice`}>{row.needsResubmission ? "Upload corrected evidence" : "Upload order evidence"}</Link> : null}
                  {canAddTracking ? <Link className={secondaryActionClass} href={`${operationsHref}#tracking`}>Add tracking</Link> : null}
                  {canReconcile ? <Link className={secondaryActionClass} href={`/importer/reconciliation/${row.order.id}`}>Match evidence</Link> : null}
                  {canAssignTracking ? <Link className={successActionClass} href={`/importer/delivery-allocation/${row.order.id}`}>Assign tracking</Link> : row.hasInvoice && !row.hasTracking && !row.needsResubmission ? <span className="inline-flex min-h-9 items-center rounded-full border border-slate-200 bg-slate-100 px-3 py-1.5 text-xs font-semibold text-slate-400">Assign after tracking</span> : null}
                  {row.querySummary?.count ? <Link href="/importer/evidence-queries" className={warningActionClass}>Answer query</Link> : null}
                </div>
              </article>
            );
          })}
        </div>
      </section>
    </main>
  );
}
