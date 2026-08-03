import { reviewReturnCollectionEvidenceAction } from "./actions";

type ShipperConfirmation = {
  outcome: string | null;
  proofUrl: string | null;
  note: string | null;
  submittedAt: string | null;
  reviewStatus: string | null;
  reviewNotes: string | null;
};

type ReturnTrackingSubmission = {
  id: string;
  courierName: string;
  trackingRef: string | null;
  trackingDate: string | null;
  trackingEvidenceUrl: string | null;
  retailerInstructionsUrl: string | null;
  returnLabelUrl: string | null;
  returnProofUrl: string | null;
  submittedAt: string | null;
  isFinalReturn: boolean | null;
  reviewStatus: string | null;
  note: string | null;
  latestShipperConfirmation: ShipperConfirmation | null;
};

function friendly(value: string | null | undefined) {
  if (!value) return "Pending";
  return value.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase());
}

function formatDateTime(value: string | null | undefined) {
  if (!value) return "—";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return date.toLocaleString("en-GB", { dateStyle: "medium", timeStyle: "short" });
}

function safeExternalUrl(value: string | null | undefined) {
  const trimmed = (value ?? "").trim();
  if (!trimmed) return "";
  return /^https?:\/\//i.test(trimmed) ? trimmed : `https://${trimmed}`;
}

export default function ReplacementReturnEvidenceReviewPanel({
  disputeId,
  submissions,
}: {
  disputeId: string;
  submissions: ReturnTrackingSubmission[];
}) {
  if (submissions.length === 0) return null;

  return (
    <section className="rounded-3xl border border-violet-200 bg-white p-6 shadow-sm">
      <p className="text-sm font-medium uppercase tracking-[0.2em] text-violet-600">
        Replacement original-item return
      </p>
      <h2 className="mt-2 text-xl font-semibold">Operational return evidence review</h2>
      <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-600">
        Review the operator&apos;s original-item return or collection instructions and the latest shipper confirmation. This review is operational only; it does not approve supplier refund value, customer settlement, accounting, or replacement-child funding.
      </p>

      <div className="mt-5 space-y-4">
        {submissions.map((submission) => {
          const shipper = submission.latestShipperConfirmation;
          return (
            <article key={submission.id} className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
              <div className="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
                <div>
                  <p className="font-semibold">{submission.isFinalReturn ? "Final return / collection" : "Return instructions / progress"}</p>
                  <p className="mt-1 text-xs text-slate-500">Operator submitted {formatDateTime(submission.submittedAt)}</p>
                </div>
                <span className="rounded-full bg-white px-3 py-1 text-xs font-semibold text-slate-700 ring-1 ring-slate-200">
                  {friendly(submission.reviewStatus)}
                </span>
              </div>

              <div className="mt-4 grid gap-3 text-sm sm:grid-cols-3">
                <div className="rounded-xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Courier</p><p className="mt-1 font-semibold">{submission.courierName}</p></div>
                <div className="rounded-xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Reference</p><p className="mt-1 font-semibold">{submission.trackingRef ?? "—"}</p></div>
                <div className="rounded-xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Date</p><p className="mt-1 font-semibold">{submission.trackingDate ?? "—"}</p></div>
              </div>

              <div className="mt-4 flex flex-wrap gap-3 text-sm">
                {submission.retailerInstructionsUrl ? <a href={submission.retailerInstructionsUrl} target="_blank" rel="noreferrer" className="font-semibold text-sky-700 underline">Retailer instructions</a> : null}
                {submission.returnLabelUrl ? <a href={submission.returnLabelUrl} target="_blank" rel="noreferrer" className="font-semibold text-sky-700 underline">Return label</a> : null}
                {submission.trackingEvidenceUrl ? <a href={safeExternalUrl(submission.trackingEvidenceUrl)} target="_blank" rel="noreferrer" className="font-semibold text-sky-700 underline">Tracking / evidence</a> : null}
                {submission.returnProofUrl ? <a href={submission.returnProofUrl} target="_blank" rel="noreferrer" className="font-semibold text-sky-700 underline">Operator proof</a> : null}
              </div>

              {submission.note ? <p className="mt-4 rounded-xl bg-white p-3 text-sm text-slate-700"><span className="font-semibold">Operator note:</span> {submission.note}</p> : null}

              {shipper ? (
                <div className="mt-4 rounded-2xl border border-sky-200 bg-sky-50 p-4 text-sm text-slate-800">
                  <p className="font-semibold text-slate-950">Latest shipper confirmation</p>
                  <p className="mt-1">Outcome: {friendly(shipper.outcome)} · Review: {friendly(shipper.reviewStatus)}</p>
                  <p className="mt-1 text-xs text-slate-500">Submitted {formatDateTime(shipper.submittedAt)}</p>
                  {shipper.proofUrl ? <p className="mt-2"><a href={safeExternalUrl(shipper.proofUrl)} target="_blank" rel="noreferrer" className="font-semibold text-sky-700 underline">Open shipper proof</a></p> : null}
                  {shipper.note ? <p className="mt-2"><span className="font-semibold">Shipper note:</span> {shipper.note}</p> : null}
                  {shipper.reviewNotes ? <p className="mt-2"><span className="font-semibold">Review notes:</span> {shipper.reviewNotes}</p> : null}
                </div>
              ) : (
                <p className="mt-4 rounded-xl border border-slate-200 bg-white p-3 text-sm text-slate-600">No shipper confirmation has been submitted yet.</p>
              )}

              <form action={reviewReturnCollectionEvidenceAction} className="mt-4 grid gap-3 rounded-2xl border border-slate-200 bg-white p-4 md:grid-cols-2">
                <input type="hidden" name="dispute_id" value={disputeId} />
                <input type="hidden" name="return_tracking_submission_id" value={submission.id} />
                <label className="text-sm font-semibold">Review decision
                  <select name="review_decision" required className="mt-1 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm font-normal">
                    <option value="">Choose decision</option>
                    <option value="accepted">Accept</option>
                    <option value="hold">Hold / query</option>
                    <option value="rejected">Reject</option>
                  </select>
                </label>
                <label className="text-sm font-semibold md:col-span-2">Review notes
                  <textarea name="review_notes" rows={3} className="mt-1 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm font-normal" placeholder="Record factual operational review notes." />
                </label>
                <div className="md:col-span-2"><button className="rounded-xl bg-violet-700 px-4 py-2 text-sm font-semibold text-white hover:bg-violet-800">Save operational review</button></div>
              </form>
            </article>
          );
        })}
      </div>
    </section>
  );
}
