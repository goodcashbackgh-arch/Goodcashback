import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import ProposalForm from "./ProposalForm";

type Disposition = { id: string; item_description: string | null; disposition_type: string; quantity: number | string; condition_note: string | null };
type Evidence = { id: string; storage_object_path: string; original_filename: string | null; content_type: string | null };
type Proposal = { id: string; proposed_remedy_type: string; proposed_remedy_qty: number | string; status: string };
type Review = {
  id: string; status: string; order_ref: string | null; retailer_name: string | null; tracking_ref: string | null;
  importer_proposal_note: string | null; decision_note: string | null; dispositions: Disposition[]; evidence: Evidence[]; proposals: Proposal[];
};

export default async function ImporterPhysicalReceiptDetail({ params, searchParams }: { params: Promise<{ review_id: string }>; searchParams: Promise<{ error?: string; success?: string }> }) {
  const { review_id: reviewId } = await params;
  const query = await searchParams;
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data, error } = await (supabase as any).rpc("importer_physical_receipt_reviews_v1", { p_review_id: reviewId });
  if (error) return <main className="p-6"><div className="rounded-2xl border border-rose-200 bg-rose-50 p-4 text-rose-800">{error.message}</div></main>;
  const review = (data?.reviews?.[0] ?? null) as Review | null;
  if (!review) notFound();

  const evidenceWithUrls = await Promise.all((review.evidence ?? []).map(async (item) => {
    const { data: signed } = await supabase.storage.from("invoice-evidence").createSignedUrl(item.storage_object_path, 900);
    return { ...item, signedUrl: signed?.signedUrl ?? null };
  }));
  const canSubmit = ["awaiting_importer_proposal", "returned_for_information"].includes(review.status);

  return <main className="min-h-screen space-y-5 bg-slate-50 p-4 md:p-6">
    <header className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
      <Link href="/importer/physical-receipts" className="text-sm font-semibold text-sky-700">← Physical Receipt Exceptions</Link>
      <h1 className="mt-3 text-2xl font-semibold text-slate-950">{review.order_ref ?? review.id}</h1>
      <p className="mt-1 text-sm text-slate-600">{review.retailer_name ?? "Retailer"} · {review.tracking_ref ?? "Tracking"}</p>
      <div className="mt-3 inline-flex rounded-full bg-slate-100 px-3 py-1 text-xs font-semibold text-slate-700">{review.status.replaceAll("_", " ")}</div>
    </header>

    {query.error ? <div className="rounded-2xl border border-rose-200 bg-rose-50 p-4 text-rose-800">{query.error}</div> : null}
    {query.success ? <div className="rounded-2xl border border-emerald-200 bg-emerald-50 p-4 text-emerald-800">{query.success}</div> : null}
    {review.status === "returned_for_information" && review.decision_note ? <div className="rounded-2xl border border-amber-200 bg-amber-50 p-4"><div className="font-semibold text-amber-900">Returned for information</div><p className="mt-1 text-sm text-amber-800">{review.decision_note}</p></div> : null}

    <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
      <h2 className="text-lg font-semibold text-slate-950">Immutable receipt facts</h2>
      <div className="mt-4 grid gap-3">
        {review.dispositions.map((row) => <div key={row.id} className="rounded-2xl border border-slate-200 p-4">
          <div className="flex flex-wrap justify-between gap-2"><strong>{row.item_description ?? "Invoice line"}</strong><span>{Number(row.quantity)} {row.disposition_type}</span></div>
          {row.condition_note ? <p className="mt-2 text-sm text-slate-600">{row.condition_note}</p> : null}
        </div>)}
      </div>
      <div className="mt-5"><h3 className="font-semibold text-slate-900">Evidence</h3><div className="mt-2 flex flex-wrap gap-2">
        {evidenceWithUrls.length === 0 ? <span className="text-sm text-slate-500">No evidence references.</span> : evidenceWithUrls.map((item) => item.signedUrl ? <a key={item.id} href={item.signedUrl} target="_blank" rel="noreferrer" className="rounded-full border border-slate-300 px-3 py-1.5 text-sm font-semibold">{item.original_filename ?? "Open evidence"}</a> : <span key={item.id} className="text-sm text-slate-500">{item.original_filename ?? "Evidence unavailable"}</span>)}
      </div></div>
    </section>

    <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
      <h2 className="text-lg font-semibold text-slate-950">Importer proposal</h2>
      {!canSubmit && review.importer_proposal_note ? <p className="mt-2 text-sm text-slate-700">{review.importer_proposal_note}</p> : null}
      {!canSubmit && review.proposals?.length ? <div className="mt-3 grid gap-2">{review.proposals.map((proposal) => <div key={proposal.id} className="rounded-xl bg-slate-50 p-3 text-sm">{proposal.proposed_remedy_type.replaceAll("_", " ")} · {Number(proposal.proposed_remedy_qty)} · {proposal.status}</div>)}</div> : null}
      <div className="mt-4"><ProposalForm reviewId={review.id} dispositions={review.dispositions} disabled={!canSubmit} /></div>
    </section>
  </main>;
}
