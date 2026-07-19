import Link from "next/link";
import { createClient } from "@/utils/supabase/server";
import OrderOperationsUxCleanup, {
  type BundleSummary,
  type InvoiceTotalPresentation,
} from "./OrderOperationsUxCleanup";
import { submitAdditionalInvoiceEvidenceAction } from "./multiInvoiceActions";

type OrderShape = {
  id: string;
  order_ref: string | null;
  order_type: string | null;
  parent_order_id: string | null;
  status: string | null;
  order_total_gbp_declared: number | null;
  retailers?: { name: string | null } | { name: string | null }[] | null;
};

type InvoiceShape = {
  id: string;
  invoice_ref: string;
  review_status: string | null;
  ocr_invoice_total_gbp: number | null;
};

type LineShape = {
  supplier_invoice_id: string;
  qty: number | null;
  amount_inc_vat_gbp: number | null;
};

type SummaryShape = {
  supplier_invoice_id: string;
  invoice_total_gbp: number | null;
  created_at: string | null;
};

type AdjustmentShape = {
  supplier_invoice_id: string | null;
  adjustment_type: string;
  amount_gbp: number | null;
  approval_status: string | null;
};

type AudienceShape = {
  accepted_estimate_gbp: number | string | null;
};

const retiredStatuses = new Set(["rejected_resubmit_required", "duplicate_blocked", "superseded"]);
const inputClass = "rounded-xl border border-slate-300 bg-white p-3 text-sm shadow-sm";

function retailerName(value: OrderShape["retailers"]) {
  if (Array.isArray(value)) return value[0]?.name ?? "—";
  return value?.name ?? "—";
}

function AdditionalInvoicePanel({ orderId, invoices }: { orderId: string; invoices: InvoiceShape[] }) {
  if (invoices.length === 0) return null;

  return (
    <div className="px-4 pb-8 md:px-6">
      <section className="mx-auto max-w-7xl rounded-3xl border border-sky-200 bg-sky-50 p-5 shadow-sm md:p-6">
        <div className="flex flex-col gap-2 md:flex-row md:items-start md:justify-between">
          <div>
            <p className="text-xs font-semibold uppercase tracking-[0.2em] text-sky-700">Split retailer order</p>
            <h2 className="mt-1 text-xl font-semibold text-sky-950">Upload another supplier invoice</h2>
            <p className="mt-2 max-w-4xl text-sm leading-6 text-sky-900">
              Use this only when the retailer issued another genuine invoice reference for the same order. The same reference remains blocked even where case, spaces or punctuation differ. Rejected evidence remains in the audit history.
            </p>
          </div>
          <span className="w-fit rounded-full bg-white px-3 py-1 text-xs font-semibold text-sky-800 ring-1 ring-sky-200">
            {invoices.length} active invoice{invoices.length === 1 ? "" : "s"}
          </span>
        </div>

        <div className="mt-4 flex flex-wrap gap-2 text-xs text-sky-900">
          {invoices.map((invoice) => (
            <span key={invoice.id} className="rounded-full bg-white px-3 py-1 ring-1 ring-sky-200">
              {invoice.invoice_ref} · {invoice.review_status ?? "pending_review"}
            </span>
          ))}
        </div>

        <form action={submitAdditionalInvoiceEvidenceAction} className="mt-5 grid gap-3 md:grid-cols-3">
          <input type="hidden" name="order_id" value={orderId} />
          <input name="invoice_ref" required className={inputClass} placeholder="New supplier invoice reference" />
          <input name="invoice_total_gbp" required type="number" min="0.01" step="0.01" className={inputClass} placeholder="Invoice total GBP" />
          <input name="invoice_file" required type="file" accept=".pdf,image/*,.png,.jpg,.jpeg,.webp" className={inputClass} />
          <input name="retailer_delivery_gbp" type="number" min="0" step="0.01" className={inputClass} placeholder="Optional delivery charge GBP" />
          <input name="retailer_discount_gbp" type="number" min="0" step="0.01" className={inputClass} placeholder="Optional discount GBP" />
          <div className="flex items-center md:col-span-3">
            <button className="rounded-full bg-sky-700 px-5 py-2.5 text-sm font-semibold text-white shadow-sm hover:bg-sky-800">
              Upload another invoice
            </button>
          </div>
        </form>
      </section>
    </div>
  );
}

export default async function OrderOperationsLayout({
  children,
  params,
}: {
  children: React.ReactNode;
  params: Promise<{ order_id: string }>;
}) {
  const { order_id: orderId } = await params;
  const supabase = await createClient();

  const [
    { data: child },
    { data: invoiceRows },
    { data: lineRows },
    { data: summaryRows },
    { data: adjustmentRows },
    { data: audienceStatus },
  ] = await Promise.all([
    supabase
      .from("orders")
      .select("id, order_ref, order_type, parent_order_id, status, order_total_gbp_declared, retailers(name)")
      .eq("id", orderId)
      .maybeSingle(),
    supabase
      .from("supplier_invoices")
      .select("id, invoice_ref, review_status, ocr_invoice_total_gbp")
      .eq("order_id", orderId)
      .order("uploaded_at", { ascending: true }),
    supabase
      .from("supplier_invoice_lines")
      .select("supplier_invoice_id, qty, amount_inc_vat_gbp, supplier_invoices!inner(order_id)")
      .eq("supplier_invoices.order_id", orderId),
    supabase
      .from("supplier_invoice_financial_summary")
      .select("supplier_invoice_id, invoice_total_gbp, created_at, supplier_invoices!inner(order_id)")
      .eq("supplier_invoices.order_id", orderId)
      .order("created_at", { ascending: true }),
    supabase
      .from("order_value_adjustments")
      .select("supplier_invoice_id, adjustment_type, amount_gbp, approval_status")
      .eq("order_id", orderId),
    (supabase as any).rpc("order_audience_status_v1", { p_order_id: orderId }).maybeSingle(),
  ]);

  const invoices = (invoiceRows ?? []) as InvoiceShape[];
  const activeInvoices = invoices.filter(
    (invoice) => !retiredStatuses.has(invoice.review_status ?? "pending_review"),
  );
  const activeInvoiceIds = new Set(activeInvoices.map((invoice) => invoice.id));
  const order = child as OrderShape | null;

  const lineTotals = new Map<string, { qty: number; amount: number }>();
  for (const line of (lineRows ?? []) as LineShape[]) {
    const current = lineTotals.get(line.supplier_invoice_id) ?? { qty: 0, amount: 0 };
    current.qty += Number(line.qty ?? 0);
    current.amount += Number(line.amount_inc_vat_gbp ?? 0);
    lineTotals.set(line.supplier_invoice_id, current);
  }

  const latestSummary = new Map<string, SummaryShape>();
  for (const summary of (summaryRows ?? []) as SummaryShape[]) {
    latestSummary.set(summary.supplier_invoice_id, summary);
  }

  const invoiceAdjustments = new Map<string, { delivery: number; discount: number }>();
  let activeDeliveryGbp = 0;
  let activeDiscountGbp = 0;
  for (const adjustment of (adjustmentRows ?? []) as AdjustmentShape[]) {
    if (adjustment.approval_status === "rejected") continue;
    const amount = Number(adjustment.amount_gbp ?? 0);
    if (adjustment.adjustment_type === "retailer_delivery") activeDeliveryGbp += amount;
    if (adjustment.adjustment_type === "retailer_discount") activeDiscountGbp += amount;
    if (!adjustment.supplier_invoice_id || !activeInvoiceIds.has(adjustment.supplier_invoice_id)) continue;
    const current = invoiceAdjustments.get(adjustment.supplier_invoice_id) ?? { delivery: 0, discount: 0 };
    if (adjustment.adjustment_type === "retailer_delivery") current.delivery += amount;
    if (adjustment.adjustment_type === "retailer_discount") current.discount += amount;
    invoiceAdjustments.set(adjustment.supplier_invoice_id, current);
  }

  const invoiceTotals: InvoiceTotalPresentation[] = activeInvoices.map((invoice) => {
    const lineTotal = lineTotals.get(invoice.id) ?? { qty: 0, amount: 0 };
    const summary = latestSummary.get(invoice.id);
    const adjustments = invoiceAdjustments.get(invoice.id) ?? { delivery: 0, discount: 0 };
    return {
      invoiceId: invoice.id,
      invoiceRef: invoice.invoice_ref,
      goodsQty: lineTotal.qty,
      lineTotalGbp: lineTotal.amount,
      enteredTotalGbp: summary?.invoice_total_gbp == null ? null : Number(summary.invoice_total_gbp),
      ocrTotalGbp: invoice.ocr_invoice_total_gbp == null ? null : Number(invoice.ocr_invoice_total_gbp),
      deliveryAdjustmentGbp: adjustments.delivery,
      discountAdjustmentGbp: adjustments.discount,
    };
  });

  const acceptedEstimateGbp = Number(
    (audienceStatus as AudienceShape | null)?.accepted_estimate_gbp
      ?? order?.order_total_gbp_declared
      ?? 0,
  );
  const bundleSummary: BundleSummary = {
    acceptedEstimateGbp,
    activeInvoiceTotalGbp: invoiceTotals.reduce((sum, invoice) => sum + Number(invoice.enteredTotalGbp ?? 0), 0),
    activeDeliveryGbp,
    activeDiscountGbp,
  };

  const cleanup = (
    <OrderOperationsUxCleanup
      orderId={orderId}
      fallbackRetailerName={retailerName(order?.retailers) !== "—" ? retailerName(order?.retailers) : ""}
      invoiceTotals={invoiceTotals}
      bundleSummary={bundleSummary}
    />
  );

  if (order?.order_type !== "replacement_child" || !order.parent_order_id) {
    return <>{cleanup}{children}<AdditionalInvoicePanel orderId={orderId} invoices={activeInvoices} /></>;
  }

  const [{ data: parent }, { data: dispute }] = await Promise.all([
    supabase
      .from("orders")
      .select("id, order_ref, status, retailers(name)")
      .eq("id", order.parent_order_id)
      .maybeSingle(),
    supabase
      .from("disputes")
      .select("id, status, desired_outcome, replacement_child_order_id")
      .eq("replacement_child_order_id", order.id)
      .maybeSingle(),
  ]);

  const parentOrder = parent as OrderShape | null;
  const displayRetailer = retailerName(order.retailers) !== "—" ? retailerName(order.retailers) : retailerName(parentOrder?.retailers);

  return (
    <>
      <OrderOperationsUxCleanup
        orderId={orderId}
        fallbackRetailerName={displayRetailer !== "—" ? displayRetailer : ""}
        invoiceTotals={invoiceTotals}
        bundleSummary={bundleSummary}
      />
      <div className="px-6 pt-6">
        <section className="mx-auto max-w-7xl rounded-2xl border border-sky-200 bg-sky-50 p-4 text-sm text-sky-950 shadow-sm">
          <div className="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
            <div>
              <p className="text-xs font-bold uppercase tracking-[0.18em] text-sky-700">Replacement / repurchase child order</p>
              <h2 className="mt-1 text-lg font-semibold text-slate-950">
                {order.order_ref ?? order.id} is linked to parent order {parentOrder?.order_ref ?? order.parent_order_id}
              </h2>
              <p className="mt-1 text-sky-900">
                Use this same operations page for replacement or repurchase evidence: add tracking, upload invoice/evidence, then continue reconciliation. No separate replacement workflow is used.
              </p>
              <div className="mt-3 grid gap-2 md:grid-cols-4">
                <p><span className="font-semibold">Retailer:</span> {displayRetailer}</p>
                <p><span className="font-semibold">Child status:</span> {order.status ?? "—"}</p>
                <p><span className="font-semibold">Parent status:</span> {parentOrder?.status ?? "—"}</p>
                <p><span className="font-semibold">Exception:</span> {dispute?.status ?? "—"}</p>
              </div>
            </div>
            <div className="flex flex-wrap gap-2 md:justify-end">
              {dispute?.id ? (
                <Link href={`/importer/exceptions/${dispute.id}`} className="rounded-xl border border-amber-200 bg-amber-50 px-4 py-2 font-semibold text-amber-800 hover:bg-amber-100">
                  Parent exception
                </Link>
              ) : null}
              <Link href={`/importer/reconciliation/${order.id}${activeInvoices[0]?.id ? `?supplier_invoice_id=${activeInvoices[0].id}` : ""}`} className="rounded-xl bg-slate-950 px-4 py-2 font-semibold text-white hover:bg-slate-800">
                Reconcile child invoice
              </Link>
            </div>
          </div>
        </section>
      </div>
      {children}
      <AdditionalInvoicePanel orderId={orderId} invoices={activeInvoices} />
    </>
  );
}
