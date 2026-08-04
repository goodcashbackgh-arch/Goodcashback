import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import DecisionForm from "./DecisionForm";
import OutcomeLaneDecisionForm from "./OutcomeLaneDecisionForm";

type Disposition = { id: string; item_description: string | null; disposition_type: string; quantity: number | string; condition_note: string | null };
type Evidence = { id: string; storage_object_path: string; original_filename: string | null };
type Proposal = { id: string; proposed_remedy_type: string; proposed_remedy_qty: number | string; status: string; approved_remedy_type: string | null; approved_remedy_qty: number | string | null };
type LinkedDispute = { dispute_id: string; remedy_type: string };
type OutcomeLaneItem = {
  physical_remedy_allocation_id: string;
  dispute_id: string | null;
  dispute_line_id: string | null;
  approved_remedy_type: "refund" | "replacement" | null;
  approved_remedy_qty: number | string | null;
  allocation_status: string;
  customer_commercial_value_gbp: number | string | null;
  dispute_status: string | null;
  refund_settlement_mode: string | null;
  line_status: string | null;
  resolution_method: string | null;
  conversation_status: string | null;
  resolved_at: string | null;
};
type LatestLaneDecision = {
  id: string;
  staff_id: string;
  decision_type: string;
  note: string | null;
  result_json: { lane_status?: string; resolved_items?: number; lane_item_count?: number } | null;
  decided_at: string;
};
type OutcomeLane = {
  id: string;
  outcome_type: "refund" | "replacement";
  lane_status: string;
  can_decide: boolean;
  items: OutcomeLaneItem[];
  latest_decision: LatestLaneDecision | null;
};
type Review = {
  id: string;
  status: string;
  caller_staff_id: string;
  order_ref: string | null;
  retailer_name: string | null;
  tracking_ref: string | null;
  importer_proposal_note: string | null;
  decision_note: string | null;
  dispositions: Disposition[];
  evidence: Evidence[];
  proposals: Proposal[];
  linked_disputes: LinkedDispute[];
  outcome_lanes: OutcomeLane[];
};

function words(value: string | null | undefined) {
  return value ? value.replaceAll("_", " ") : "not recorded";
}

export default async function StaffPhysicalReceiptDetail({ params, searchParams }: { params: Promise<{ review_id: string }>; searchParams: Promise<{ error?: string; success?: string }> }) {
  const { review_id: reviewId } = await params;
  const query = await searchParams;
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");
  const { data, error } = await (supabase as any).rpc("staff_physical_receipt_reviews_v1", { p_review_id: reviewId });
  if (error) return <main className="p-6"><div className="rounded-2xl border border-rose-200 bg-rose-50 p-4 text-rose-800">{error.message}</div></main>;
  const review = (data?.reviews?.[0] ?? null) as Review | null;
  if (!review) notFound();
  const evidenceWithUrls = await Promise.all((review.evidence ?? []).map(async (item) => {
    const { data: signed } = await supabase.storage.from("invoice-evidence").createSignedUrl(item.storage_object_path, 900);
    return { ...item, signedUrl: signed?.signedUrl ?? null };
  }));
  const activeProposals = (review.proposals ?? []).filter((row) => row.status === "proposed");
  const canDecideInitialReview = review.status === "awaiting_supervisor_review";
  const initialDecisionComplete = !canDecideInitialReview && Boolean(review.decision_note);
  const lanes = review.outcome_lanes ?? [];

  return <main className="min-h-screen space-y-5 bg-slate-50 p-4 md:p-6">
    <header className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><Link href="/internal/physical-receipts" className="text-sm font-semibold text-violet-700">← Physical Receipt Reviews</Link><h1 className="mt-3 text-2xl font-semibold text-slate-950">{review.order_ref ?? review.id}</h1><p className="mt-1 text-sm text-slate-600">{review.retailer_name ?? "Retailer"} · {review.tracking_ref ?? "Tracking"}</p><div className="mt-3 inline-flex rounded-full bg-slate-100 px-3 py-1 text-xs font-semibold text-slate-700">{words(review.status)}</div></header>
    {query.error ? <div className="rounded-2xl border border-rose-200 bg-rose-50 p-4 text-rose-800">{query.error}</div> : null}
    {query.success ? <div className="rounded-2xl border border-emerald-200 bg-emerald-50 p-4 text-emerald-800">{query.success}</div> : null}

    <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><h2 className="text-lg font-semibold text-slate-950">Receipt and evidence</h2><div className="mt-4 grid gap-3">{review.dispositions.map((row) => <div key={row.id} className="rounded-2xl border border-slate-200 p-4"><div className="flex flex-wrap justify-between gap-2"><strong>{row.item_description ?? "Invoice line"}</strong><span>{Number(row.quantity)} {row.disposition_type}</span></div>{row.condition_note ? <p className="mt-2 text-sm text-slate-600">{row.condition_note}</p> : null}</div>)}</div><div className="mt-5 flex flex-wrap gap-2">{evidenceWithUrls.map((item) => item.signedUrl ? <a key={item.id} href={item.signedUrl} target="_blank" rel="noreferrer" className="rounded-full border border-slate-300 px-3 py-1.5 text-sm font-semibold">{item.original_filename ?? "Open evidence"}</a> : <span key={item.id} className="text-sm text-slate-500">{item.original_filename ?? "Evidence unavailable"}</span>)}</div></section>

    <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><h2 className="text-lg font-semibold text-slate-950">Importer proposal</h2><p className="mt-2 text-sm text-slate-700">{review.importer_proposal_note ?? "No proposal note."}</p><div className="mt-3 grid gap-2">{review.proposals.map((proposal) => <div key={proposal.id} className="rounded-xl bg-slate-50 p-3 text-sm">Proposed {words(proposal.proposed_remedy_type)} · {Number(proposal.proposed_remedy_qty)} · {proposal.status}{proposal.approved_remedy_type ? ` · approved ${words(proposal.approved_remedy_type)} ${Number(proposal.approved_remedy_qty)}` : ""}</div>)}</div></section>

    {review.linked_disputes?.length ? <section className="rounded-3xl border border-emerald-200 bg-emerald-50 p-5"><h2 className="font-semibold text-emerald-950">Linked disputes</h2><div className="mt-3 flex flex-wrap gap-2">{review.linked_disputes.map((link) => <Link key={`${link.dispute_id}-${link.remedy_type}`} href={`/internal/exceptions/${link.dispute_id}`} className="rounded-full bg-white px-3 py-1.5 text-sm font-semibold text-emerald-900 shadow-sm">{link.remedy_type}: {link.dispute_id}</Link>)}</div></section> : null}

    {canDecideInitialReview ? <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><h2 className="text-lg font-semibold text-slate-950">Initial supervisor decision</h2><div className="mt-4"><DecisionForm reviewId={review.id} proposals={activeProposals} disabled={false} /></div></section> : null}

    {initialDecisionComplete ? <section className="rounded-3xl border border-emerald-200 bg-emerald-50 p-5 shadow-sm"><div className="text-xs font-semibold uppercase tracking-[0.2em] text-emerald-700">Initial review complete</div><h2 className="mt-1 text-lg font-semibold text-emerald-950">Supervisor decision recorded</h2><p className="mt-2 text-sm text-emerald-900">{review.decision_note}</p></section> : null}

    {initialDecisionComplete && !lanes.length ? <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 shadow-sm"><div className="text-xs font-semibold uppercase tracking-[0.2em] text-amber-700">Grouped outcomes pending</div><h2 className="mt-1 text-lg font-semibold text-amber-950">Waiting for retailer outcomes</h2><p className="mt-2 text-sm text-amber-900">The initial receipt decision is complete. Grouped refund and same-order replacement lanes will appear on this page when the linked disputes have compatible retailer outcomes. Do not use the legacy child-order replacement action on the individual exception pages.</p></section> : null}

    {lanes.length ? <section className="space-y-4">
      <div><h2 className="text-xl font-semibold text-slate-950">Grouped outcome lanes</h2><p className="mt-1 text-sm text-slate-600">Later refund and replacement outcomes are completed here as one supervisor action per lane.</p></div>
      {lanes.map((lane) => <article key={lane.id} className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
        <div className="flex flex-wrap items-start justify-between gap-3"><div><div className="text-xs font-semibold uppercase tracking-[0.2em] text-violet-700">{lane.outcome_type} lane</div><h3 className="mt-1 text-lg font-semibold text-slate-950">{lane.outcome_type === "refund" ? "Credit-balance settlement" : "Same-order free replacement"}</h3></div><span className={`rounded-full px-3 py-1 text-xs font-semibold ${lane.can_decide ? "bg-amber-100 text-amber-800" : "bg-slate-100 text-slate-700"}`}>{words(lane.lane_status)}</span></div>

        <div className="mt-4 grid gap-3">{lane.items.map((item) => <div key={item.physical_remedy_allocation_id} className="rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm">
          <div className="flex flex-wrap justify-between gap-2"><strong>{Number(item.approved_remedy_qty ?? 0)} unit{Number(item.approved_remedy_qty ?? 0) === 1 ? "" : "s"}</strong><span>{words(item.line_status)}</span></div>
          <div className="mt-2 grid gap-1 text-slate-600 md:grid-cols-2"><div>Dispute: {words(item.dispute_status)}</div><div>Conversation: {words(item.conversation_status)}</div>{item.customer_commercial_value_gbp != null ? <div>Customer value: £{Number(item.customer_commercial_value_gbp).toFixed(2)}</div> : null}{item.refund_settlement_mode ? <div>Settlement: {words(item.refund_settlement_mode)}</div> : null}</div>
        </div>)}</div>

        {lane.latest_decision ? <div className="mt-4 rounded-2xl border border-emerald-200 bg-emerald-50 p-4 text-sm text-emerald-950"><div className="font-semibold">Decision recorded: {words(lane.latest_decision.decision_type)}</div>{lane.latest_decision.note ? <p className="mt-1">{lane.latest_decision.note}</p> : null}<p className="mt-1 text-emerald-800">{new Date(lane.latest_decision.decided_at).toLocaleString("en-GB")}</p></div> : null}

        {lane.can_decide ? <div className="mt-5"><OutcomeLaneDecisionForm reviewId={review.id} laneId={lane.id} staffId={review.caller_staff_id} outcomeType={lane.outcome_type} items={lane.items} /></div> : null}
      </article>)}
    </section> : null}
  </main>;
}
