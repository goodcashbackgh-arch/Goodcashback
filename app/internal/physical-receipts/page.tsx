import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type Review = { id: string; status: string; order_ref: string | null; retailer_name: string | null; tracking_ref: string | null; affected_quantity: number | string };

export default async function StaffPhysicalReceiptsPage({ searchParams }: { searchParams: Promise<{ error?: string }> }) {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");
  const { data, error } = await (supabase as any).rpc("staff_physical_receipt_reviews_v1", { p_review_id: null });
  const query = await searchParams;
  if (error) return <main className="p-6"><div className="rounded-2xl border border-rose-200 bg-rose-50 p-4 text-rose-800">{error.message}</div></main>;
  const reviews = ((data?.reviews ?? []) as Review[]).filter((review) => review.status === "awaiting_supervisor_review");

  return <main className="min-h-screen space-y-5 bg-slate-50 p-4 md:p-6">
    <header className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
      <p className="text-xs font-semibold uppercase tracking-[0.2em] text-violet-700">Supervisor</p>
      <div className="mt-2 flex flex-wrap items-end justify-between gap-3"><div><h1 className="text-2xl font-semibold text-slate-950">Physical Receipt Reviews</h1><p className="mt-1 text-sm text-slate-600">Reviews currently requiring an initial supervisor route decision.</p></div><Link href="/internal" className="rounded-full border border-slate-300 px-4 py-2 text-sm font-semibold">Back to internal workspace</Link></div>
    </header>
    {query.error ? <div className="rounded-2xl border border-rose-200 bg-rose-50 p-4 text-rose-800">{query.error}</div> : null}
    <section className="grid gap-3">
      {reviews.length === 0 ? <div className="rounded-2xl border border-slate-200 bg-white p-6 text-slate-600">No physical receipt reviews currently require supervisor action.</div> : reviews.map((review) => <Link key={review.id} href={`/internal/physical-receipts/${review.id}`} className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm hover:border-violet-300">
        <div className="flex flex-wrap items-start justify-between gap-3"><div><div className="font-semibold text-slate-950">{review.order_ref ?? review.id}</div><div className="mt-1 text-sm text-slate-600">{review.retailer_name ?? "Retailer"} · {review.tracking_ref ?? "Tracking"}</div></div><span className="rounded-full bg-amber-100 px-3 py-1 text-xs font-semibold text-amber-800">awaiting supervisor review</span></div>
        <div className="mt-3 text-sm text-slate-700">Affected quantity: <strong>{Number(review.affected_quantity)}</strong></div>
      </Link>)}
    </section>
  </main>;
}
