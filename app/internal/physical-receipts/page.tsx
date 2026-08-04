import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type OutcomeLane = { id: string; outcome_type: "refund" | "replacement"; lane_status: string; can_decide: boolean; items: unknown[] };
type Review = { id: string; status: string; order_ref: string | null; retailer_name: string | null; tracking_ref: string | null; affected_quantity: number | string; outcome_lanes?: OutcomeLane[] };

function words(value: string) {
  return value.replaceAll("_", " ");
}

export default async function StaffPhysicalReceiptsPage({ searchParams }: { searchParams: Promise<{ error?: string }> }) {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");
  const { data, error } = await (supabase as any).rpc("staff_physical_receipt_reviews_v1", { p_review_id: null });
  const query = await searchParams;
  if (error) return <main className="p-6"><div className="rounded-2xl border border-rose-200 bg-rose-50 p-4 text-rose-800">{error.message}</div></main>;
  const reviews = (data?.reviews ?? []) as Review[];

  return <main className="min-h-screen space-y-5 bg-slate-50 p-4 md:p-6">
    <header className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
      <p className="text-xs font-semibold uppercase tracking-[0.2em] text-violet-700">Supervisor</p>
      <div className="mt-2 flex flex-wrap items-end justify-between gap-3"><div><h1 className="text-2xl font-semibold text-slate-950">Physical Receipt Actions</h1><p className="mt-1 text-sm text-slate-600">Initial review decisions and later grouped refund or replacement outcomes.</p></div><Link href="/internal" className="rounded-full border border-slate-300 px-4 py-2 text-sm font-semibold">Back to internal workspace</Link></div>
      <div className="mt-4 flex flex-wrap gap-2 text-xs font-semibold"><span className="rounded-full bg-slate-100 px-3 py-1 text-slate-700">All actions: {Number(data?.action_count ?? reviews.length)}</span><span className="rounded-full bg-amber-100 px-3 py-1 text-amber-800">Initial reviews: {Number(data?.initial_review_action_count ?? 0)}</span><span className="rounded-full bg-violet-100 px-3 py-1 text-violet-800">Outcome lanes: {Number(data?.outcome_lane_action_count ?? 0)}</span></div>
    </header>
    {query.error ? <div className="rounded-2xl border border-rose-200 bg-rose-50 p-4 text-rose-800">{query.error}</div> : null}
    <section className="grid gap-3">
      {reviews.length === 0 ? <div className="rounded-2xl border border-slate-200 bg-white p-6 text-slate-600">No physical receipt actions currently require supervisor attention.</div> : reviews.map((review) => {
        const activeLanes = (review.outcome_lanes ?? []).filter((lane) => lane.can_decide);
        const initialAction = review.status === "awaiting_supervisor_review";
        return <Link key={review.id} href={`/internal/physical-receipts/${review.id}`} className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm hover:border-violet-300">
          <div className="flex flex-wrap items-start justify-between gap-3"><div><div className="font-semibold text-slate-950">{review.order_ref ?? review.id}</div><div className="mt-1 text-sm text-slate-600">{review.retailer_name ?? "Retailer"} · {review.tracking_ref ?? "Tracking"}</div></div><div className="flex flex-wrap gap-2">{initialAction ? <span className="rounded-full bg-amber-100 px-3 py-1 text-xs font-semibold text-amber-800">initial review</span> : null}{activeLanes.map((lane) => <span key={lane.id} className="rounded-full bg-violet-100 px-3 py-1 text-xs font-semibold text-violet-800">{words(lane.outcome_type)} · {lane.items.length} item{lane.items.length === 1 ? "" : "s"}</span>)}</div></div>
          <div className="mt-3 text-sm text-slate-700">Affected quantity: <strong>{Number(review.affected_quantity)}</strong></div>
        </Link>;
      })}
    </section>
  </main>;
}
