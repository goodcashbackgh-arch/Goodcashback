import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { confirmOrderSettlementCreditFromReconciliationAction } from "../settlement-actions";

function gbp(value: unknown) {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP", minimumFractionDigits: 2 }).format(Number(value ?? 0));
}

export default async function ReconciliationSettlementCreditPage({
  params,
}: {
  params: Promise<{ order_id: string }>;
}) {
  const { order_id: orderId } = await params;
  const supabase = await createClient();

  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff } = await supabase
    .from("staff")
    .select("id, full_name, role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!staff || !["admin", "supervisor"].includes(String(staff.role_type))) redirect("/internal");

  const { data: position } = await supabase
    .from("order_settlement_credit_position_v1")
    .select("order_id, order_ref, declared_order_gbp, funding_total_gbp, posted_customer_invoice_gbp, funding_less_posted_invoice_gbp, settlement_credit_created_gbp, settlement_status")
    .eq("order_id", orderId)
    .maybeSingle();

  if (!position) redirect(`/internal/reconciliation/${orderId}?error=Settlement+position+not+found`);

  const canCreateCredit = position.settlement_status === "credit_due" && Number(position.settlement_credit_created_gbp ?? 0) === 0;

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto max-w-4xl space-y-6">
        <Link href={`/internal/reconciliation/${orderId}`} className="text-sm font-semibold text-sky-700">Back to supervisor reconciliation</Link>

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <p className="text-sm font-black uppercase tracking-[0.22em] text-sky-600">Order settlement</p>
          <h1 className="mt-2 text-3xl font-black">Confirm surplus as customer credit</h1>
          <p className="mt-3 text-sm text-slate-600">
            Use this after supplier/customer invoice values are corrected and the DVA/card position confirms the customer funded more than the final posted customer invoice value.
          </p>
        </section>

        <section className="grid gap-3 rounded-3xl border border-slate-200 bg-white p-6 text-sm shadow-sm md:grid-cols-2 lg:grid-cols-3">
          <p><span className="font-semibold">Order:</span> {position.order_ref ?? orderId}</p>
          <p><span className="font-semibold">Settlement status:</span> {position.settlement_status}</p>
          <p><span className="font-semibold">Declared order:</span> {gbp(position.declared_order_gbp)}</p>
          <p><span className="font-semibold">Funding received:</span> {gbp(position.funding_total_gbp)}</p>
          <p><span className="font-semibold">Posted customer invoice:</span> {gbp(position.posted_customer_invoice_gbp)}</p>
          <p><span className="font-semibold">Credit due:</span> {gbp(position.funding_less_posted_invoice_gbp)}</p>
        </section>

        {!canCreateCredit ? (
          <section className="rounded-3xl border border-amber-200 bg-amber-50 p-6 text-sm text-amber-900 shadow-sm">
            This order is not eligible for a new settlement credit. It must have settlement_status = credit_due and no existing settlement credit.
          </section>
        ) : (
          <form action={confirmOrderSettlementCreditFromReconciliationAction} className="space-y-4 rounded-3xl border border-cyan-200 bg-cyan-50 p-6 shadow-sm">
            <input type="hidden" name="order_id" value={orderId} />
            <label className="block text-sm font-semibold text-slate-800">
              Reason
              <select name="reason" defaultValue="supervisor_confirmed_credit" className="mt-2 w-full rounded-xl border border-cyan-200 bg-white px-3 py-2 text-sm">
                <option value="supervisor_confirmed_credit">Supervisor confirmed customer credit</option>
                <option value="discount_or_promo">Discount / promo / voucher reduced final value</option>
                <option value="checkout_changed">Checkout value changed</option>
                <option value="item_removed_before_charge">Item removed before charge</option>
                <option value="not_charged_closure">Not charged / not spent</option>
                <option value="customer_hold_excluded">Customer hold excluded from final invoice</option>
              </select>
            </label>
            <label className="block text-sm font-semibold text-slate-800">
              Notes
              <textarea name="notes" rows={4} className="mt-2 w-full rounded-xl border border-cyan-200 bg-white px-3 py-2 text-sm" placeholder="Example: DVA/card shows 199.99 funded and 161.99 final customer invoice posted. Difference confirmed as customer credit." />
            </label>
            <button type="submit" className="rounded-xl bg-cyan-700 px-5 py-3 text-sm font-black text-white">Create customer credit</button>
          </form>
        )}
      </div>
    </main>
  );
}
