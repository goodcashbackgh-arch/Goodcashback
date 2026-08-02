import { uploadReplacementReturnCollectionAction } from "./replacement-return-actions";

type CourierOption = {
  id: string;
  name: string;
};

export default function ReplacementOriginalItemReturnForm({
  disputeId,
  courierOptions,
}: {
  disputeId: string;
  courierOptions: CourierOption[];
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
          <input name="tracking_evidence_url" type="url" className="mt-1 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm font-normal" placeholder="https://…" />
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
    </section>
  );
}
