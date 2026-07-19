import Link from "next/link";
import { createClient } from "@/utils/supabase/server";
import OrderOperationsUxCleanup from "./OrderOperationsUxCleanup";
import { submitAdditionalInvoiceEvidenceAction } from "./multiInvoiceActions";

type OrderShape = {
  id: string;
  order_ref: string | null;
  order_type: string | null;
  parent_order_id: string | null;
  status: string | null;
  retailers?: { name: string | null } | { name: string | null }[] | null;
};

type InvoiceShape = {
  id: string;
  invoice_ref: string;
  review_status: string | null;
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

  const [{ data: child }, { data: invoiceRows }] = await Promise.all([
    supabase
      .from("orders")
      .select("id, order_ref, order_type, parent_order_id, status, retailers(name)")
      .eq("id", orderId)
      .maybeSingle(),
    supabase
      .from("supplier_invoices")
      .select("id, invoice_ref, review_status")
      .eq("order_id", orderId)
      .order("uploaded_at", { ascending: true }),
  ]);

  const activeInvoices = ((invoiceRows ?? []) as InvoiceShape[]).filter(
    (invoice) => !retiredStatuses.has(invoice.review_status ?? "pending_review"),
  );
  const order = child as OrderShape | null;

  if (order?.order_type !== "replacement_child" || !order.parent_order_id) {
    return <>{children}<AdditionalInvoicePanel orderId={orderId} invoices={activeInvoices} /></>;
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
      <OrderOperationsUxCleanup fallbackRetailerName={displayRetailer !== "—" ? displayRetailer : ""} />
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
              <Link href={`/importer/reconciliation/${order.id}`} className="rounded-xl bg-slate-950 px-4 py-2 font-semibold text-white hover:bg-slate-800">
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
