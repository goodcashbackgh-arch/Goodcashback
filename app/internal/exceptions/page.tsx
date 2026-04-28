import Link from "next/link";
import { createClient } from "@/utils/supabase/server";

function gbp(value: number | null | undefined) {
  return new Intl.NumberFormat("en-GB", {
    style: "currency",
    currency: "GBP",
    minimumFractionDigits: 2,
  }).format(Number(value ?? 0));
}

type DisputeRow = {
  id: string;
  order_id: string;
  desired_outcome: string;
  status: string;
  amount_impact_gbp: number | null;
  replacement_child_order_id: string | null;
  orders: { order_ref: string | null }[] | null;
};

export default async function InternalExceptionsPage() {
  const supabase = await createClient();
  const { data: disputes, error } = await supabase
    .from("disputes")
    .select("id, order_id, desired_outcome, status, amount_impact_gbp, raised_at, replacement_child_order_id, orders!disputes_order_id_fkey(order_ref)")
    .order("raised_at", { ascending: false })
    .limit(50);

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto max-w-6xl rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
        <Link href="/internal" className="text-sm font-semibold text-sky-600">← Back to internal dashboard</Link>
        <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Day 4</p>
        <h1 className="mt-2 text-3xl font-semibold tracking-tight">Child exceptions</h1>
        <p className="mt-3 max-w-3xl text-sm leading-6 text-slate-600">Refund gate, replacement child creation, and conversation review controls.</p>

        {error ? <p className="mt-4 rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm text-rose-700">Failed to load disputes: {error.message}</p> : null}

        <div className="mt-6 space-y-3">
          {((disputes ?? []) as DisputeRow[]).map((dispute) => (
            <article key={dispute.id} className="rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm">
              <p className="font-semibold">{dispute.orders?.[0]?.order_ref ?? dispute.order_id} · {dispute.desired_outcome} · {dispute.status}</p>
              <p className="mt-1">Impact: {gbp(dispute.amount_impact_gbp)}</p>
              {dispute.replacement_child_order_id ? <p className="mt-1">Child order: {dispute.replacement_child_order_id}</p> : null}
              <Link href={`/internal/exceptions/${dispute.id}`} className="mt-2 inline-block font-semibold text-sky-700 underline">Open exception review</Link>
            </article>
          ))}
          {(disputes ?? []).length === 0 ? <p className="text-sm text-slate-600">No disputes available.</p> : null}
        </div>
      </div>
    </main>
  );
}
