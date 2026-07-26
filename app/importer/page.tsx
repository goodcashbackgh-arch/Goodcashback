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

type TrackingRow = { order_id: string };
type InvoiceRow = {
  order_id: string;
  review_status: string | null;
  rejection_requires_resubmission_yn: boolean | null;
  is_current_for_order: boolean | null;
};
type AudienceStatusRow = {
  order_id: string;
  accepted_estimate_gbp: number | string | null;
  final_sale_value_gbp: number | string | null;
  canonical_balance_due_gbp: number | string | null;
  potential_credit_pending_review_gbp: number | string | null;
  customer_sales_state: string | null;
  importer_status_label: string | null;
  importer_next_action: string | null;
};

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

function isActiveInvoice(invoice: InvoiceRow) {
  if (invoice.is_current_for_order === false) return false;
  if (["superseded", "duplicate_blocked"].includes(invoice.review_status ?? "")) return false;
  return !(invoice.review_status === "rejected_resubmit_required" && invoice.rejection_requires_resubmission_yn === false);
}

function isNoImporterAction(action: string) {
  return action === "No importer action required" || action === "Order complete";
}

function statusClass(action: string, status: string, balanceDueGbp = 0, canonicalMissing = false) {
  if (canonicalMissing) return "border-slate-200 bg-slate-50 text-slate-600";
  if (action === "Resolve evidence issue") return "border-rose-200 bg-rose-50 text-rose-800";
  if (action === "Answer query" || balanceDueGbp > 0.01) return "border-amber-200 bg-amber-50 text-amber-800";
  if (isNoImporterAction(action) || status.toLowerCase().includes("complete")) return "border-emerald-200 bg-emerald-50 text-emerald-800";
  return "border-slate-200 bg-slate-50 text-slate-700";
}

export default async function ImporterPage() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: operator } = await supabase.from("operators").select("id, full_name").eq("auth_user_id", user.id).eq("active", true).maybeSingle();
  if (!operator) redirect("/auth/check");

  const [{ data: orders, error: ordersError }, { data: tracking }, { data: invoices }] = await Promise.all([
    supabase.from("orders").select("id, order_ref, status, payment_auth_id, total_qty_declared, order_total_gbp_declared, funded_at, created_at, retailers(name)").order("created_at", { ascending: false }),
    supabase.from("order_tracking_submissions").select("order_id").is("superseded_at", null),
    supabase.from("supplier_invoices").select("order_id, review_status, rejection_requires_resubmission_yn, is_current_for_order"),
  ]);
  if (ordersError) throw ordersError;

  const orderRows = (orders ?? []) as unknown as OrderRow[];
  const orderIds = orderRows.map((order) => order.id);
  const { data: audienceStatuses, error: audienceStatusError } = orderIds.length
    ? await supabase.rpc("order_audience_status_v1", { p_order_id: null })
    : { data: [], error: null };
  if (audienceStatusError) throw audienceStatusError;

  const trackingSet = new Set(((tracking ?? []) as TrackingRow[]).map((row) => row.order_id));
  const invoicesByOrderId = new Map<string, InvoiceRow[]>();
  for (const invoice of (invoices ?? []) as InvoiceRow[]) {
    const current = invoicesByOrderId.get(invoice.order_id) ?? [];
    current.push(invoice);
    invoicesByOrderId.set(invoice.order_id, current);
  }

  const audienceByOrderId = new Map<string, AudienceStatusRow>();
  for (const audienceStatus of (audienceStatuses ?? []) as AudienceStatusRow[]) audienceByOrderId.set(audienceStatus.order_id, audienceStatus);

  const rows = orderRows.map((order) => {
    const activeInvoices = (invoicesByOrderId.get(order.id) ?? []).filter(isActiveInvoice);
    const hasInvoice = activeInvoices.length > 0;
    const hasTracking = trackingSet.has(order.id);
    const audienceStatus = audienceByOrderId.get(order.id);
    const canonicalMissing = !audienceStatus?.importer_status_label || !audienceStatus?.importer_next_action;
    const acceptedEstimateGbp = Number(audienceStatus?.accepted_estimate_gbp ?? order.order_total_gbp_declared ?? 0);
    const finalSaleValueGbp = Number(audienceStatus?.final_sale_value_gbp ?? acceptedEstimateGbp);
    const finalBalanceDueGbp = canonicalMissing ? 0 : Number(audienceStatus?.canonical_balance_due_gbp ?? 0);
    const pendingCreditGbp = canonicalMissing ? 0 : Number(audienceStatus?.potential_credit_pending_review_gbp ?? 0);
    const canonicalStatus = canonicalMissing ? "Status unavailable" : cleanUiText(audienceStatus!.importer_status_label!);
    const canonicalAction = canonicalMissing ? "Open order for details" : cleanUiText(audienceStatus!.importer_next_action!);
    return {
      order,
      hasInvoice,
      hasTracking,
      status: { status: canonicalStatus, action: canonicalAction },
      acceptedEstimateGbp,
      finalSaleValueGbp,
      finalSaleConfirmed: audienceStatus?.customer_sales_state === "posted",
      finalBalanceDueGbp,
      pendingCreditGbp,
      canonicalMissing,
    };
  });

  const needsActionCount = rows.filter((row) => !row.canonicalMissing && !isNoImporterAction(row.status.action)).length;
  const invoiceOrderCount = rows.filter((row) => row.hasInvoice).length;

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
            <div className="grid gap-2 md:flex md:flex-wrap md:justify-end">
              <Link href="/importer/orders/new" className={primaryActionClass}>Create order</Link>
              <Link href="/customer" className={secondaryActionClass}>Customer portal</Link>
              <Link href="/importer/exceptions" className={secondaryActionClass}>Active exceptions</Link>
            </div>
          </div>
        </div>
      </header>

      <section className="grid gap-3 md:grid-cols-5">
        <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm"><div className="text-xs font-medium uppercase tracking-wide text-slate-500">Total orders</div><div className="mt-2 text-2xl font-semibold text-slate-950">{rows.length}</div></div>
        <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm"><div className="text-xs font-medium uppercase tracking-wide text-slate-500">Initial payment received</div><div className="mt-2 text-2xl font-semibold text-slate-950">{orderRows.filter((order) => !!order.funded_at).length}</div></div>
        <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm"><div className="text-xs font-medium uppercase tracking-wide text-slate-500">Tracking submitted</div><div className="mt-2 text-2xl font-semibold text-slate-950">{trackingSet.size}</div></div>
        <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm"><div className="text-xs font-medium uppercase tracking-wide text-slate-500">Order evidence submitted</div><div className="mt-2 text-2xl font-semibold text-slate-950">{invoiceOrderCount}</div></div>
        <div className={`rounded-2xl border p-4 shadow-sm ${needsActionCount > 0 ? "border-amber-200 bg-amber-50" : "border-emerald-200 bg-emerald-50"}`}><div className={`text-xs font-medium uppercase tracking-wide ${needsActionCount > 0 ? "text-amber-700" : "text-emerald-700"}`}>Needs action</div><div className={`mt-2 text-2xl font-semibold ${needsActionCount > 0 ? "text-amber-900" : "text-emerald-900"}`}>{needsActionCount}</div></div>
      </section>

      <section className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm md:p-5">
        <div className="flex flex-col gap-3 md:flex-row md:items-center md:justify-between"><div><h2 className="text-lg font-semibold text-slate-950">Orders</h2><p className="text-sm text-slate-600">Current importer order state, final order value and next importer action.</p></div><Link href="/importer/orders/new" className={primaryActionClass}>Create order</Link></div>
        <div className="mt-4 grid gap-3">
          {rows.map((row) => {
            const operationsHref = `/importer/orders/${row.order.id}/operations`;
            const action = row.status.action;
            return (
              <article key={row.order.id} className={`rounded-2xl border p-4 shadow-sm ${action === "Resolve evidence issue" ? "border-rose-200 bg-rose-50" : row.finalBalanceDueGbp > 0.01 || action === "Answer query" ? "border-amber-200 bg-amber-50" : "border-slate-200 bg-white"}`}>
                <div className="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
                  <div><div className="text-xs font-semibold uppercase tracking-wide text-slate-500">{row.order.retailers?.name ?? "Retailer not set"}</div><h3 className="mt-1 text-base font-semibold text-slate-950">{row.order.order_ref ?? row.order.id}</h3><p className="mt-1 break-all text-xs text-slate-500">Payment reference: {row.order.payment_auth_id ?? "Not assigned"}</p></div>
                  <span className={`w-fit rounded-full border px-3 py-1 text-xs font-semibold ${statusClass(action, row.status.status, row.finalBalanceDueGbp, row.canonicalMissing)}`}>{row.status.status}</span>
                </div>
                {row.canonicalMissing ? <p className="mt-3 rounded-xl border border-slate-200 bg-slate-50 p-3 text-xs text-slate-600">Order status is unavailable for this order, so no remaining balance is shown here.</p> : null}
                <div className="mt-4 grid grid-cols-2 gap-3 text-sm md:grid-cols-4">
                  <div className="rounded-xl bg-white/70 p-3 ring-1 ring-slate-100"><div className="text-xs text-slate-500">Qty</div><div className="font-semibold text-slate-950">{row.order.total_qty_declared ?? 0}</div></div>
                  <div className="rounded-xl bg-white/70 p-3 ring-1 ring-slate-100"><div className="text-xs text-slate-500">Accepted estimate</div><div className="font-semibold text-slate-950">{gbp(row.acceptedEstimateGbp)}</div></div>
                  {row.finalSaleConfirmed ? <div className="rounded-xl bg-white/70 p-3 ring-1 ring-slate-100"><div className="text-xs text-slate-500">Final order value</div><div className="font-semibold text-slate-950">{gbp(row.finalSaleValueGbp)}</div>{row.finalBalanceDueGbp > 0.01 ? <div className="mt-1 text-[11px] text-amber-700">Remaining balance {gbp(row.finalBalanceDueGbp)}</div> : null}{row.pendingCreditGbp > 0.01 ? <div className="mt-1 text-[11px] text-amber-700">Potential credit pending review {gbp(row.pendingCreditGbp)}</div> : null}</div> : null}
                  <div className="rounded-xl bg-white/70 p-3 ring-1 ring-slate-100"><div className="text-xs text-slate-500">Tracking</div><div className="font-semibold text-slate-950">{row.hasTracking ? "Submitted" : "Missing"}</div></div>
                  <div className="rounded-xl bg-white/70 p-3 ring-1 ring-slate-100"><div className="text-xs text-slate-500">Order evidence</div><div className="font-semibold text-slate-950">{row.hasInvoice ? "Uploaded" : "Missing"}</div></div>
                </div>
                <div className="mt-4 rounded-xl border border-slate-200 bg-white/80 p-3 text-sm"><div className="text-xs font-semibold uppercase tracking-wide text-slate-500">Next action</div><div className={action === "Resolve evidence issue" ? "mt-1 font-semibold text-rose-700" : row.finalBalanceDueGbp > 0.01 || action === "Answer query" ? "mt-1 font-semibold text-amber-800" : "mt-1 font-semibold text-slate-900"}>{action}</div><div className="mt-1 text-xs text-slate-500">{row.order.funded_at ? "Initial payment received" : "Open"} · Raw: {friendlyStatus(row.order.status)}</div></div>
                <div className="mt-4 flex flex-wrap gap-2">
                  <Link className={secondaryActionClass} href={operationsHref}>Open order</Link>
                  {action === "Resolve evidence issue" ? <Link className={warningActionClass} href={`${operationsHref}#invoice`}>Resolve evidence issue</Link> : null}
                  {action === "Answer query" ? <Link href="/importer/evidence-queries" className={warningActionClass}>Answer query</Link> : null}
                  {action === "Continue invoice reconciliation" ? <Link className={secondaryActionClass} href={`/importer/reconciliation/${row.order.id}`}>Continue invoice reconciliation</Link> : null}
                  {action === "Add tracking" ? <Link className={secondaryActionClass} href={`${operationsHref}#tracking`}>Add tracking</Link> : null}
                  {action === "Assign tracking" ? <Link className={successActionClass} href={`/importer/delivery-allocation/${row.order.id}`}>Assign tracking</Link> : null}
                  {action === "Resolve exception or hold" ? <Link className={warningActionClass} href="/importer/exceptions">Resolve exception or hold</Link> : null}
                  {action === "Collect final balance" ? <Link className={warningActionClass} href={operationsHref}>Collect final balance</Link> : null}
                </div>
              </article>
            );
          })}
        </div>
      </section>
    </main>
  );
}
