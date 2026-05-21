import Link from "next/link";
import { notFound } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { closeRefundExceptionAsSettlementCreditAction } from "../settlement-actions";

function gbp(value: unknown) {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP", minimumFractionDigits: 2 }).format(Number(value ?? 0));
}

export default async function SettlementCreditPage({ params }: { params: Promise<{ dispute_id: string }> }) {
  const { dispute_id: disputeId } = await params;
  const supabase = await createClient();

  const { data: dispute } = await supabase
    .from("disputes")
    .select("id, order_id, desired_outcome, status, amount_impact_gbp, resolved_at")
    .eq("id", disputeId)
    .maybeSingle();

  if (!dispute) notFound();

  const { data: position } = await supabase
    .from("order_settlement_credit_position_v1")
    .select("order_ref, funding_total_gbp, posted_customer_invoice_gbp, funding_less_posted_invoice_gbp, settlement_status")
    .eq("order_id", dispute.order_id)
    .maybeSingle();

  const canClose = dispute.desired_outcome === "refund" && !dispute.resolved_at && position?.settlement_status === "credit_due";

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto max-w-3xl space-y-6">
        <Link href={`/internal/exceptions/${disputeId}`} className="text-sm font-semibold text-sky-700">Back to exception</Link>
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h1 className="text-3xl font-black">Settlement credit closure</h1>
          <p className="mt-2 text-sm text-slate-600">Use after supervisor confirms the exception value was not spent and no refund receipt is expected.</p>
        </section>
        <section className="grid gap-3 rounded-3xl border border-slate-200 bg-white p-6 text-sm shadow-sm md:grid-cols-2">
          <p>Order: {position?.order_ref ?? dispute.order_id}</p>
          <p>Status: {dispute.status}</p>
          <p>Exception amount: {gbp(dispute.amount_impact_gbp)}</p>
          <p>Settlement: {position?.settlement_status ?? "—"}</p>
          <p>Funding: {gbp(position?.funding_total_gbp)}</p>
          <p>Posted invoice: {gbp(position?.posted_customer_invoice_gbp)}</p>
          <p>Credit due: {gbp(position?.funding_less_posted_invoice_gbp)}</p>
        </section>
        {!canClose ? <p className="rounded-3xl border border-amber-200 bg-amber-50 p-6 text-sm text-amber-900">Not eligible.</p> : (
          <form action={closeRefundExceptionAsSettlementCreditAction} className="space-y-4 rounded-3xl border border-cyan-200 bg-cyan-50 p-6 shadow-sm">
            <input type="hidden" name="dispute_id" value={dispute.id} />
            <select name="reason" defaultValue="not_charged_closure" className="w-full rounded-xl border border-cyan-200 bg-white px-3 py-2 text-sm">
              <option value="not_charged_closure">Not charged</option>
              <option value="checkout_changed">Checkout changed</option>
              <option value="discount_or_promo">Discount or promo</option>
              <option value="item_removed_before_charge">Item removed before charge</option>
              <option value="customer_hold_excluded">Customer hold excluded</option>
              <option value="supervisor_confirmed_credit">Supervisor confirmed</option>
            </select>
            <textarea name="notes" rows={4} className="w-full rounded-xl border border-cyan-200 bg-white px-3 py-2 text-sm" placeholder="Notes" />
            <button type="submit" className="rounded-xl bg-cyan-700 px-5 py-3 text-sm font-black text-white">Close and create credit</button>
          </form>
        )}
      </div>
    </main>
  );
}
