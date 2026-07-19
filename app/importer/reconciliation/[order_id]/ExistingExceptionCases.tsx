import Link from "next/link";
import { createClient } from "@/utils/supabase/server";
import { rescindExceptionCaseAction } from "./actions";

function gbp(value: unknown) {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" }).format(Number(value ?? 0));
}

export default async function ExistingExceptionCases({ orderId }: { orderId: string }) {
  const supabase = await createClient();
  const { data: disputes, error } = await supabase
    .from("disputes")
    .select("id, desired_outcome, status, amount_impact_gbp, refund_approved_at, resolved_at, replacement_child_order_id, replacement_child_order:orders!disputes_replacement_child_order_id_fkey(order_ref)")
    .eq("order_id", orderId)
    .order("raised_at", { ascending: false });

  if (error || !disputes?.length) return null;

  return (
    <div className="mx-auto max-w-7xl px-4 pb-6 sm:px-6">
      <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
        <h2 className="text-xl font-semibold">Existing exception cases</h2>
        <div className="mt-4 space-y-3">
          {disputes.map((dispute) => {
            const child = Array.isArray(dispute.replacement_child_order) ? dispute.replacement_child_order[0] : dispute.replacement_child_order;
            return (
              <article key={dispute.id} className="rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm">
                <p><span className="font-semibold">Desired outcome:</span> {dispute.desired_outcome}</p>
                <p><span className="font-semibold">Status:</span> {dispute.status}</p>
                <p><span className="font-semibold">Total amount:</span> {gbp(dispute.amount_impact_gbp)}</p>
                {dispute.desired_outcome === "refund" ? <p><span className="font-semibold">Refund approval:</span> {dispute.refund_approved_at ? "Approved" : "Pending approval"}</p> : null}
                {dispute.replacement_child_order_id ? <p><span className="font-semibold">Replacement child order:</span> {child?.order_ref ?? dispute.replacement_child_order_id}</p> : null}
                <Link href={`/importer/exceptions/${dispute.id}`} className="mt-3 inline-block rounded-xl border border-sky-300 bg-sky-50 px-3 py-2 font-semibold text-sky-800">Open exception workflow</Link>
                {dispute.resolved_at === null ? (
                  <form action={rescindExceptionCaseAction} className="mt-3">
                    <input type="hidden" name="order_id" value={orderId} />
                    <input type="hidden" name="dispute_id" value={dispute.id} />
                    <button className="rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 font-semibold text-rose-800">Rescind exception</button>
                  </form>
                ) : null}
              </article>
            );
          })}
        </div>
      </section>
    </div>
  );
}
