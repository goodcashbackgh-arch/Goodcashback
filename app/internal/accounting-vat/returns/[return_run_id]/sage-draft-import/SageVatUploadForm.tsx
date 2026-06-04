"use client";

import { useState } from "react";
import { importSageDraftVatReturnTotalsAction, previewSageDraftVatReturnTotalsAction, recordFinalSageVatSubmissionEvidenceAction } from "./actions";

type UploadPurpose = "draft_reconciliation" | "final_submission_evidence";

type SageVatUploadFormProps = {
  runId: string;
  uploadPurpose: UploadPurpose;
  defaultPurpose: UploadPurpose;
  previewValues: Record<number, string>;
  sageReturnReference: string;
  sageSubmissionTimestamp: string;
  showPreview: boolean;
  missingBoxes: string[];
  fileName: string;
};

const BOXES = [
  { box: 1, label: "VAT due on sales/outputs" },
  { box: 2, label: "VAT due on acquisitions", optional: true },
  { box: 3, label: "Total VAT due", optional: true },
  { box: 4, label: "VAT reclaimed on purchases/inputs" },
  { box: 5, label: "Net VAT to pay/reclaim", optional: true },
  { box: 6, label: "Net sales/outputs" },
  { box: 7, label: "Net purchases/inputs" },
  { box: 8, label: "EU dispatches", optional: true },
  { box: 9, label: "EU acquisitions", optional: true },
];

function amount(value: string): string {
  const parsed = Number(value.replace(/,/g, ""));
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP", minimumFractionDigits: 2 }).format(Number.isFinite(parsed) ? parsed : 0);
}

export default function SageVatUploadForm({
  runId,
  uploadPurpose,
  defaultPurpose,
  previewValues,
  sageReturnReference,
  sageSubmissionTimestamp,
  showPreview,
  missingBoxes,
  fileName,
}: SageVatUploadFormProps) {
  const [selectedPurpose, setSelectedPurpose] = useState<UploadPurpose>(uploadPurpose);
  const isFinal = selectedPurpose === "final_submission_evidence";

  return (
    <>
      {showPreview ? (
        <section className={`rounded-3xl border p-5 shadow-sm ${missingBoxes.length ? "border-amber-200 bg-amber-50 text-amber-950" : "border-emerald-200 bg-emerald-50 text-emerald-950"}`}>
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div>
              <h2 className="text-xl font-semibold tracking-tight">Preview extracted Sage boxes</h2>
              <p className="mt-1 text-sm leading-6 opacity-90">
                Preview purpose: <span className="font-bold">{isFinal ? "Final submitted Sage VAT return evidence" : "Draft reconciliation check"}</span>. {fileName ? `Source file: ${fileName}.` : "Source: manual values."}
              </p>
            </div>
            <span className={`rounded-full px-3 py-1 text-xs font-bold ${missingBoxes.length ? "bg-amber-100 text-amber-800" : "bg-emerald-100 text-emerald-800"}`}>
              {missingBoxes.length ? `Missing Box ${missingBoxes.join(", ")}` : "Ready to save"}
            </span>
          </div>
          {isFinal ? (
            <p className="mt-3 rounded-2xl border border-amber-200 bg-white/70 p-3 text-sm font-semibold text-amber-900">
              Final evidence will compare submitted Sage boxes to platform expected boxes. If they do not match, the return will not lock.
            </p>
          ) : null}
          <div className="mt-4 overflow-x-auto rounded-2xl border border-white/70 bg-white">
            <table className="min-w-full divide-y divide-slate-200 text-left text-sm">
              <thead className="text-xs uppercase tracking-wide text-slate-500"><tr><th className="px-3 py-2">Box</th><th className="px-3 py-2">Meaning</th><th className="px-3 py-2">Preview value</th></tr></thead>
              <tbody className="divide-y divide-slate-100">
                {BOXES.map((item) => <tr key={item.box}><td className="px-3 py-2 font-bold text-slate-950">Box {item.box}</td><td className="px-3 py-2 text-slate-600">{item.label}</td><td className="px-3 py-2 font-semibold text-slate-900">{previewValues[item.box] !== undefined ? amount(previewValues[item.box]) : "—"}</td></tr>)}
              </tbody>
            </table>
          </div>
          <p className="mt-3 text-xs leading-5 opacity-90">The values have been copied into the manual boxes below. If they are correct, use the purpose-specific save button. The browser clears file uploads after preview, so reselect the file before saving only if you need its hash recorded; otherwise it saves the confirmed manual Sage totals.</p>
        </section>
      ) : null}

      <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
        <h2 className="text-xl font-semibold tracking-tight">Upload Sage VAT return export</h2>
        <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-600">
          Upload a Sage VAT return XLSX/CSV/text export, or enter Boxes 1–9 manually. Draft mode saves a reconstruction snapshot; final mode records submitted values and asks the match/lock RPC to lock only when the submitted boxes match the platform expected boxes.
        </p>

        <form action={isFinal ? recordFinalSageVatSubmissionEvidenceAction : importSageDraftVatReturnTotalsAction} className="mt-6 grid gap-5">
          <input type="hidden" name="vat_return_run_id" value={runId} />

          <section className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
            <h3 className="font-semibold text-slate-950">Upload purpose</h3>
            <p className="mt-1 text-xs leading-5 text-slate-600">The default follows the return state, but admins can switch purpose manually. Choosing final requires an explicit confirmation and calls the Sage match/lock RPC.</p>
            <div className="mt-3 grid gap-3 md:grid-cols-2">
              <label className="flex gap-3 rounded-2xl border border-slate-200 bg-white p-4 text-sm">
                <input type="radio" name="upload_purpose" value="draft_reconciliation" checked={!isFinal} onChange={() => setSelectedPurpose("draft_reconciliation")} />
                <span><span className="block font-bold text-slate-950">Draft reconciliation check</span><span className="mt-1 block text-xs leading-5 text-slate-600">Save a Sage reconstruction snapshot only. This does not lock the return.</span></span>
              </label>
              <label className="flex gap-3 rounded-2xl border border-slate-200 bg-white p-4 text-sm">
                <input type="radio" name="upload_purpose" value="final_submission_evidence" checked={isFinal} onChange={() => setSelectedPurpose("final_submission_evidence")} />
                <span><span className="block font-bold text-slate-950">Final submitted Sage VAT return evidence</span><span className="mt-1 block text-xs leading-5 text-slate-600">Record final Sage values and lock only if the RPC match rules pass.</span></span>
              </label>
            </div>
            <p className="mt-3 text-xs font-semibold text-slate-600">Current default: {defaultPurpose === "final_submission_evidence" ? "Final submission evidence" : "Draft reconciliation"}.</p>
          </section>

          {isFinal ? (
            <section className="grid gap-3 rounded-2xl border border-amber-200 bg-amber-50 p-4 md:grid-cols-2">
              <label className="grid gap-2 text-sm">
                <span className="font-semibold text-amber-950">Sage return reference (required for final)</span>
                <input name="sage_return_reference" defaultValue={sageReturnReference} placeholder="Sage/HMRC return reference" className="rounded-xl border border-amber-200 bg-white px-3 py-2 text-sm" />
              </label>
              <label className="grid gap-2 text-sm">
                <span className="font-semibold text-amber-950">Sage submission timestamp (required for final)</span>
                <input name="sage_submission_timestamp" type="datetime-local" defaultValue={sageSubmissionTimestamp} className="rounded-xl border border-amber-200 bg-white px-3 py-2 text-sm" />
              </label>
              <label className="flex items-start gap-3 rounded-2xl border border-amber-200 bg-white p-3 text-sm md:col-span-2">
                <input className="mt-1" type="checkbox" name="confirm_final_sage_submission" value="yes" />
                <span><span className="font-bold text-amber-950">Confirm final Sage submission evidence</span><span className="mt-1 block text-xs leading-5 text-amber-900">Required only for final evidence. The action is blocked without this confirmation.</span></span>
              </label>
            </section>
          ) : null}

          <label className="grid gap-2 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm">
            <span className="font-semibold text-slate-950">Sage VAT file</span>
            <span className="text-xs leading-5 text-slate-600">XLSX, CSV, TSV or plain-text export. Keep it under 2MB.</span>
            <input name="sage_draft_file" type="file" accept=".xlsx,.csv,.tsv,.txt,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet,text/csv,text/plain" className="rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm" />
          </label>

          <section className="rounded-2xl border border-slate-200 bg-white p-4">
            <div className="flex flex-wrap items-start justify-between gap-3">
              <div>
                <h3 className="font-semibold text-slate-950">Manual override / confirmation</h3>
                <p className="mt-1 text-xs leading-5 text-slate-600">Required boxes are 1, 4, 6 and 7. Optional boxes can be left blank unless Sage shows a value. Box 3 and Box 5 are calculated if blank.</p>
              </div>
              <span className="rounded-full bg-amber-100 px-3 py-1 text-xs font-bold text-amber-800">Admin must check against Sage</span>
            </div>

            <div className="mt-4 grid gap-3 md:grid-cols-3">
              {BOXES.map((item) => (
                <label key={item.box} className="grid gap-1 text-sm">
                  <span className="font-medium text-slate-800">Box {item.box}{item.optional ? " (optional)" : ""}</span>
                  <span className="text-xs text-slate-500">{item.label}</span>
                  <input name={`box${item.box}_gbp`} inputMode="decimal" defaultValue={previewValues[item.box] ?? ""} placeholder="0.00" className="rounded-xl border border-slate-200 px-3 py-2 text-sm" />
                </label>
              ))}
            </div>
          </section>

          {isFinal ? (
            <div className="rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm leading-6 text-amber-900">
              Final evidence calls the existing lock RPC; blockers, journal state and box mismatches remain enforced by the database.
            </div>
          ) : (
            <div className="rounded-2xl border border-sky-200 bg-sky-50 p-4 text-sm leading-6 text-sky-900">
              Draft reconciliation saves into the existing Sage reconstruction snapshot history and returns to the summary tab.
            </div>
          )}

          <div className="flex flex-wrap gap-3">
            <button formAction={previewSageDraftVatReturnTotalsAction} className="rounded-xl border border-sky-200 bg-sky-50 px-5 py-3 text-sm font-bold text-sky-800 hover:bg-sky-100">Preview extracted boxes</button>
            {isFinal ? (
              <button formAction={recordFinalSageVatSubmissionEvidenceAction} className="rounded-xl border border-emerald-700 bg-emerald-600 px-5 py-3 text-sm font-bold text-white hover:bg-emerald-700">Record final Sage submission and lock if matched</button>
            ) : (
              <button formAction={importSageDraftVatReturnTotalsAction} className="rounded-xl bg-slate-950 px-5 py-3 text-sm font-bold text-white hover:bg-slate-800">Save draft reconciliation snapshot</button>
            )}
          </div>
        </form>
      </section>
    </>
  );
}
