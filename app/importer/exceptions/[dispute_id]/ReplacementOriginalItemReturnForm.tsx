import { uploadReplacementReturnCollectionAction } from "./replacement-return-actions";

type CourierOption = {
  id: string;
  name: string;
};

type ReturnHistoryRow = {
  id: string;
  courier_name: string | null;
  tracking_ref: string | null;
  tracking_date: string | null;
  tracking_evidence_url: string | null;
  retailer_return_instructions_file_url: string | null;
  return_label_file_url: string | null;
  return_proof_file_url: string | null;
  submitted_at: string | null;
  is_final_return_yn: boolean | null;
  review_status: string | null;
  note: string | null;
};

function formatDateTime(value: string | null) {
  if (!value) return "—";
  const date = new Date(value);
  return Number.isNaN(date.getTime())
    ? value
    : date.toLocaleString("en-GB", { dateStyle: "medium", timeStyle: "short" });
}

function displayStatus(value: string | null) {
  return (value ?? "pending_review").replaceAll("_", " ");
}

export default function ReplacementOriginalItemReturnForm({
  disputeId,
  courierOptions,
  returnHistory,
}: {
  disputeId: string;
  courierOptions: CourierOption[];
  returnHistory: ReturnHistoryRow[];
}) {
  return (
    <section className="rounded-3xl border border-violet-200 bg-white p-6 shadow-sm">
      <p className="text-sm font-medium uppercase tracking-[0.2em] text-violet-600">
        Replacement original-item return
      </p>
      <h2 className="mt-2 text-xl font-semibold">Original damaged item return / collection</h2>
      <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-600">
        Use this only when the retailer has accepted the replacement and requires the physically received damaged or wrong item to be returned or collected. Missing items cannot use this action. Save the shipper-facing instructions before the replacement child is created.
      </p>

      <form action={uploadReplacementReturnCollectionAction} className="mt-5 grid gap-4 md:grid-cols-2">
        <input type="hidden" name="dispute_id" value={disputeId} />

        <label className="text-sm font-semibold text-slate-800">
          Courier, optional until final return
          <select name="courier_id" className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal">
            <option value="">Choose courier</option>
            {courierOptions.map((courier) => (
              <option key={courier.id} value={courier.id}>{courier.name}</option>
            ))}
          </select>
        </label>

        <label className="text-sm font-semibold text-slate-800">
          Tracking / collection reference
          <input name="tracking_ref" className="mt-1 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm font-normal" />
        </label>

        <label className="text-sm font-semibold text-slate-800">
          Tracking / collection date
          <input name="tracking_date" type="date" className="mt-1 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm font-normal" />
        </label>

        <label className="text-sm font-semibold text-slate-800">
          Tracking or evidence URL
          <input
            name="tracking_evidence_url"
            type="text"
            inputMode="url"
            autoCapitalize="none"
            autoCorrect="off"
            spellCheck={false}
            className="mt-1 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm font-normal"
            placeholder="www.example.com"
          />
        </label>

        <label className="text-sm font-semibold text-slate-800 md:col-span-2">
          Retailer return instructions file
          <input name="retailer_return_instructions_file" type="file" className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal" />
        </label>

        <label className="text-sm font-semibold text-slate-800 md:col-span-2">
          Return label file
          <input name="return_label_file" type="file" className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal" />
        </label>

        <label className="text-sm font-semibold text-slate-800 md:col-span-2">
          Operator return proof, optional supporting file
          <input name="return_proof_file" type="file" className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal" />
          <span className="mt-1 block text-xs font-normal text-slate-500">
            This file alone is not enough to create a shipper task. Add instructions, a label, a reference, a URL, or a meaningful note.
          </span>
        </label>

        <label className="text-sm font-semibold text-slate-800 md:col-span-2">
          Shipper-facing note
          <textarea name="note" rows={4} className="mt-1 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm font-normal" placeholder="Explain where, how and by when the original item must be returned or collected." />
        </label>

        <label className="flex items-start gap-3 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm md:col-span-2">
          <input name="is_final_return_yn" type="checkbox" className="mt-1" />
          <span>
            <span className="font-semibold text-slate-900">This is the final confirmed return / collection record.</span>
            <span className="mt-1 block text-slate-600">Courier, tracking or collection reference, and date are mandatory when checked.</span>
          </span>
        </label>

        <div className="md:col-span-2">
          <button type="submit" className="rounded-xl bg-violet-700 px-4 py-2 text-sm font-semibold text-white hover:bg-violet-800">
            Save original-item return instructions
          </button>
        </div>
      </form>

      <div className="mt-8 border-t border-violet-100 pt-6">
        <div className="flex items-center justify-between gap-3">
          <h3 className="text-lg font-semibold">Replacement return / collection history</h3>
          <span className="rounded-full bg-violet-50 px-3 py-1 text-xs font-semibold text-violet-800 ring-1 ring-violet-200">
            {returnHistory.length} record(s)
          </span>
        </div>

        {returnHistory.length ? (
          <div className="mt-4 space-y-3">
            {returnHistory.map((row) => (
              <details key={row.id} className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
                <summary className="cursor-pointer font-semibold text-slate-900">
                  Return collection record · {formatDateTime(row.submitted_at)}
                </summary>
                <div className="mt-3 space-y-1 text-sm text-slate-700">
                  <p>Courier: {row.courier_name ?? "Not provided"}</p>
                  <p>Tracking reference: {row.tracking_ref ?? "Not provided"}</p>
                  <p>Tracking date: {row.tracking_date ?? "Not provided"}</p>
                  <p>Final return / collection: {row.is_final_return_yn ? "Yes" : "No"}</p>
                  <p>Supervisor review: {displayStatus(row.review_status)}</p>
                  <p>Note: {row.note || "No note."}</p>
                  {row.tracking_evidence_url ? <p><a className="font-semibold text-sky-700 underline" href={row.tracking_evidence_url} target="_blank" rel="noreferrer">Open tracking / evidence link</a></p> : null}
                  {row.retailer_return_instructions_file_url ? <p><a className="font-semibold text-sky-700 underline" href={row.retailer_return_instructions_file_url} target="_blank" rel="noreferrer">Open retailer instructions file</a></p> : null}
                  {row.return_label_file_url ? <p><a className="font-semibold text-sky-700 underline" href={row.return_label_file_url} target="_blank" rel="noreferrer">Open return label</a></p> : null}
                  {row.return_proof_file_url ? <p><a className="font-semibold text-sky-700 underline" href={row.return_proof_file_url} target="_blank" rel="noreferrer">Open return proof</a></p> : null}
                </div>
              </details>
            ))}
          </div>
        ) : (
          <p className="mt-4 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-700">No replacement return records have been saved yet.</p>
        )}
      </div>
    </section>
  );
}
