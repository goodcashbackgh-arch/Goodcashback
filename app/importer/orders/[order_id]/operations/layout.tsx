import Link from "next/link";
import { createClient } from "@/utils/supabase/server";
import OrderOperationsUxCleanup from "./OrderOperationsUxCleanup";

type OrderShape = {
  id: string;
  order_ref: string | null;
  order_type: string | null;
  parent_order_id: string | null;
  status: string | null;
  retailers?: { name: string | null } | { name: string | null }[] | null;
};

function retailerName(value: OrderShape["retailers"]) {
  if (Array.isArray(value)) return value[0]?.name ?? "—";
  return value?.name ?? "—";
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

  const { data: child } = await supabase
    .from("orders")
    .select("id, order_ref, order_type, parent_order_id, status, retailers(name)")
    .eq("id", orderId)
    .maybeSingle();

  const order = child as OrderShape | null;

  if (order?.order_type !== "replacement_child" || !order.parent_order_id) {
    return <>{children}</>;
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
    </>
  );
}
