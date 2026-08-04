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

function isFixtureRef(value: string | null | undefined) {
  return Boolean(value?.startsWith("PW-GROUPED-"));
}

function laneStatusLabel(lane: OutcomeLane) {
  if (lane.outcome_type === "refund" && lane.lane_status === "partially_resolved") {
    return "awaiting importer refund evidence";
  }
  return words(lane.lane_status);
}

function decisionLabel(lane: OutcomeLane) {
  if (lane.latest_decision?.decision_type === "refund_final_outcome_accept") {
    return "Final refund outcome accepted";
  }
  return words(lane.latest_decision?.decision_type);
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
  const fixture = isFixtureRef(review.order_ref);

  return <main className="min-h-screen bg-slate-50 px-3 py-4 md:p-6">
    <div className="mx-auto max-w-4xl space-y-4">
      <header className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm md:p-5">
        <Link href="/internal/physical-receipts" className="text-sm font-semibold text-violet-700">← Physical Receipt Reviews</Link>
        <div className="mt-3 flex flex-wrap items-start justify-between gap-3">
          <div className="min-w-0 flex-1">
            {fixture ? <div className="mb-1 text-xs font-semibold uppercase tracking-[0.18em] text-violet-700">Seeded test fixture</div> : null}
            <h1 className="break-words text-xl font-semibold leading-tight text-slate-950 md:text-2xl">
              {fixture ? "Grouped outcome workflow test" : (review.order_ref ?? review.id)}
            </h1>
            <p className="mt-1 text-sm text-slate-600">{review.retailer_name ?? "Retailer"}{review.tracking_ref ? ` · ${review.tracking_ref}` : ""}</p>
            {fixture ? <p className="mt-2 break-all text-xs text-slate-500">Fixture ref: {review.order_ref}</p> : null}
          </div>
          <span className="shrink-0 rounded-full bg-slate-100 px-3 py-1 text-xs font-semibold text-slate-700">{words(review.status)}</span>
        </div>
      </header>

      {query.error ? <div className="rounded-2xl border border-rose-200 bg-rose-50 p-4 text-rose-800">{query.error}</div> : null}
      {query.success ? <div className="rounded-2xl border border-emerald-200 bg-emerald-50 p-4 text-emerald-800">{query.success}</div> : null}

      {canDecideInitialReview ? <section className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm md:p-5">
        <h2 className="text-lg font-semibold text-slate-950">Initial supervisor decision</h2>
        <div className="mt-4"><DecisionForm reviewId={review.id} proposals={activeProposals} disabled={false} /></div>
      </section> : null}

      {initialDecisionComplete ? <section className="rounded-2xl border border-emerald-200 bg-emerald-50 px-4 py-3 shadow-sm">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <div>
            <div className="text-xs font-semibold uppercase tracking-[0.18em] text-emerald-700">Initial review complete</div>
            <p className="mt-1 text-sm font-medium text-emerald-950">{review.decision_note}</p>
          </div>
          <span className="rounded-full bg-white px-3 py-1 text-xs font-semibold text-emerald-800">recorded</span>
        </div>
      </section> : null}

      {lanes.length ? <section className="space-y-4">
        <div className="px-1">
          <h2 className="text-xl font-semibold text-slate-950">Grouped outcome lanes</h2>
          <p className="mt-1 text-sm text-slate-600">One supervisor action advances every item into its established downstream route.</p>
        </div>

        {lanes.map((lane) => {
          const totalQuantity = lane.items.reduce((sum, item) => sum + Number(item.approved_remedy_qty ?? 0), 0);
          const totalValue = lane.items.reduce((sum, item) => sum + Number(item.customer_commercial_value_gbp ?? 0), 0);
          const commonConversation = lane.items.every((item) => item.conversation_status === lane.items[0]?.conversation_status)
            ? lane.items[0]?.conversation_status
            : null;
          const commonDisputeStatus = lane.items.every((item) => item.dispute_status === lane.items[0]?.dispute_status)
            ? lane.items[0]?.dispute_status
            : null;

          return <article key={lane.id} className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm md:p-5">
            <div className="flex flex-wrap items-start justify-between gap-3">
              <div>
                <div className="text-xs font-semibold uppercase tracking-[0.18em] text-violet-700">{lane.outcome_type} lane</div>
                <h3 className="mt-1 text-lg font-semibold text-slate-950">{lane.outcome_type === "refund" ? "Final refund outcome" : "Same-order free replacement"}</h3>
              </div>
              <span className={`rounded-full px-3 py-1 text-xs font-semibold ${lane.can_decide ? "bg-amber-100 text-amber-800" : "bg-slate-100 text-slate-700"}`}>{laneStatusLabel(lane)}</span>
            </div>

            <div className="mt-4 grid grid-cols-3 gap-2 rounded-2xl bg-slate-50 p-3 text-center text-sm">
              <div><div className="font-semibold text-slate-950">{lane.items.length}</div><div className="text-xs text-slate-500">items</div></div>
              <div><div className="font-semibold text-slate-950">{totalQuantity}</div><div className="text-xs text-slate-500">quantity</div></div>
              <div><div className="font-semibold text-slate-950">£{totalValue.toFixed(2)}</div><div className="text-xs text-slate-500">value</div></div>
            </div>

            {(commonDisputeStatus || commonConversation) ? <div className="mt-3 flex flex-wrap gap-2 text-xs text-slate-600">
              {commonDisputeStatus ? <span className="rounded-full border border-slate-200 px-2.5 py-1">Disputes: {words(commonDisputeStatus)}</span> : null}
              {commonConversation ? <span className="rounded-full border border-slate-200 px-2.5 py-1">Retailer: {words(commonConversation)}</span> : null}
            </div> : null}

            <div className="mt-3 divide-y divide-slate-200 rounded-2xl border border-slate-200">
              {lane.items.map((item, index) => <div key={item.physical_remedy_allocation_id} className="flex items-center justify-between gap-3 px-3 py-3 text-sm">
                <div className="min-w-0">
                  <div className="font-semibold text-slate-950">Item {index + 1} · {Number(item.approved_remedy_qty ?? 0)} unit{Number(item.approved_remedy_qty ?? 0) === 1 ? "" : "s"}</div>
                  {(!commonConversation || !commonDisputeStatus) ? <div className="mt-0.5 text-xs text-slate-500">{words(item.dispute_status)} · {words(item.conversation_status)}</div> : null}
                </div>
                <div className="shrink-0 text-right">
                  <div className="font-semibold text-slate-950">£{Number(item.customer_commercial_value_gbp ?? 0).toFixed(2)}</div>
                  <div className="text-xs text-slate-500">{words(item.line_status)}</div>
                </div>
              </div>)}
            </div>

            {lane.outcome_type === "refund" && lane.lane_status === "partially_resolved" ? <div className="mt-4 rounded-2xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-950">
              <div className="font-semibold">Importer evidence required next</div>
              <p className="mt-1">The final retailer refund outcome is accepted. The importer must now submit the credit note, refund proof, or governed no-document evidence. Customer credit remains pending the existing downstream controls.</p>
            </div> : null}

            {lane.latest_decision ? <div className="mt-4 rounded-2xl border border-emerald-200 bg-emerald-50 p-3 text-sm text-emerald-950">
              <div className="font-semibold">Decision recorded: {decisionLabel(lane)}</div>
              {lane.latest_decision.note ? <p className="mt-1">{lane.latest_decision.note}</p> : null}
              <p className="mt-1 text-xs text-emerald-800">{new Date(lane.latest_decision.decided_at).toLocaleString("en-GB")}</p>
            </div> : null}

            {lane.can_decide ? <div className="mt-4 border-t border-slate-200 pt-4">
              <OutcomeLaneDecisionForm reviewId={review.id} laneId={lane.id} staffId={review.caller_staff_id} outcomeType={lane.outcome_type} items={lane.items} />
            </div> : null}
          </article>;
        })}
      </section> : null}

      <details className="rounded-3xl border border-slate-200 bg-white shadow-sm">
        <summary className="cursor-pointer list-none px-4 py-4 font-semibold text-slate-950">Receipt and evidence <span className="ml-1 text-sm font-normal text-slate-500">({review.dispositions.length} lines)</span></summary>
        <div className="border-t border-slate-200 p-4">
          <div className="divide-y divide-slate-200 rounded-2xl border border-slate-200">
            {review.dispositions.map((row) => <div key={row.id} className="px-3 py-3 text-sm">
              <div className="flex flex-wrap justify-between gap-2"><strong className="break-words">{row.item_description ?? "Invoice line"}</strong><span>{Number(row.quantity)} {words(row.disposition_type)}</span></div>
              {row.condition_note ? <p className="mt-1 break-words text-xs text-slate-500">{row.condition_note}</p> : null}
            </div>)}
          </div>
          <div className="mt-4 flex flex-wrap gap-2">{evidenceWithUrls.map((item) => item.signedUrl ? <a key={item.id} href={item.signedUrl} target="_blank" rel="noreferrer" className="rounded-full border border-slate-300 px-3 py-1.5 text-sm font-semibold">{item.original_filename ?? "Open evidence"}</a> : <span key={item.id} className="text-sm text-slate-500">{item.original_filename ?? "Evidence unavailable"}</span>)}</div>
        </div>
      </details>

      <details className="rounded-3xl border border-slate-200 bg-white shadow-sm">
        <summary className="cursor-pointer list-none px-4 py-4 font-semibold text-slate-950">Importer proposal <span className="ml-1 text-sm font-normal text-slate-500">({review.proposals.length})</span></summary>
        <div className="border-t border-slate-200 p-4">
          <p className="text-sm text-slate-700">{review.importer_proposal_note ?? "No proposal note."}</p>
          <div className="mt-3 grid gap-2">{review.proposals.map((proposal) => <div key={proposal.id} className="rounded-xl bg-slate-50 p-3 text-sm">Proposed {words(proposal.proposed_remedy_type)} · {Number(proposal.proposed_remedy_qty)} · {words(proposal.status)}{proposal.approved_remedy_type ? ` · approved ${words(proposal.approved_remedy_type)} ${Number(proposal.approved_remedy_qty)}` : ""}</div>)}</div>
        </div>
      </details>

      {review.linked_disputes?.length ? <details className="rounded-3xl border border-emerald-200 bg-emerald-50 shadow-sm">
        <summary className="cursor-pointer list-none px-4 py-4 font-semibold text-emerald-950">Linked disputes <span className="ml-1 text-sm font-normal text-emerald-700">({review.linked_disputes.length})</span></summary>
        <div className="border-t border-emerald-200 p-4"><div className="flex flex-wrap gap-2">{review.linked_disputes.map((link) => <Link key={`${link.dispute_id}-${link.remedy_type}`} href={`/internal/exceptions/${link.dispute_id}`} className="rounded-full bg-white px-3 py-1.5 text-sm font-semibold text-emerald-900 shadow-sm">{link.remedy_type}: {link.dispute_id.slice(0, 8)}…</Link>)}</div></div>
      </details> : null}
    </div>
  </main>;
}
