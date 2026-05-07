"use client";

import { useState } from "react";
import { uploadOperatorCreditNoteEvidenceAction, uploadReturnCollectionEvidenceAction } from "./actions";

type SupplierInvoiceOption = {
  id: string;
  invoice_ref: string | null;
  review_status?: string | null;
};

type CourierOption = {
  id: string;
  name: string;
};

type PrefillLine = {
  description: string;
  qty: number;
  amount: number;
};

type HistoryRow = {
  id: string;
  message_type: string | null;
  body: string | null;
  generated_by: string | null;
  created_at: string | null;
};

type Props = {
  disputeId: string;
  originalOrderId: string;
  invoiceOptions: SupplierInvoiceOption[];
  courierOptions: CourierOption[];
  prefillLines: PrefillLine[];
  returnHistory: HistoryRow[];
};

type Mode = "credit_note" | "refund_proof_no_credit_note" | "no_document";

function InvoiceSelector({ invoiceOptions }: { invoiceOptions: SupplierInvoiceOption[] }) {
  return (
    <label className="block text-sm font-semibold text-slate-700">
      Original supplier invoice
      <select name="original_supplier_invoice_id" required className="mt-2 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm">
        {invoiceOptions.map((option) => (
          <option key={option.id} value={option.id}>
            {option.invoice_ref ?? option.id} {option.review_status ? `· ${option.review_status}` : ""}
          </option>
        ))}
      </select>
    </label>
  );
}

function RefundLineInputs({ prefillLines }: { prefillLines: PrefillLine[] }) {
  return (
    <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
      <h3 className="font-semibold">Refund adjustment lines</h3>
      <p className="mt-1 text-xs text-slate-500">Prefilled from the exception. Values are stored as negative refund adjustment evidence.</p>
      <div className="mt-4 space-y-3">
        {prefillLines.map((line, index) => {
          const lineNumber = index + 1;
          return (
            <div key={lineNumber} className="grid gap-3 md:grid-cols-[1fr_120px_160px]">
              <input name={`line_${lineNumber}_description`} defaultValue={line.description} className="rounded-xl border border-slate-300 px-3 py-2 text-sm" placeholder={`Line ${lineNumber} description`} />
              <input name={`line_${lineNumber}_qty`} type="number" step="0.01" min="0" defaultValue={line.qty || ""} className="rounded-xl border border-slate-300 px-3 py-2 text-sm" placeholder="Qty" />
              <input name={`line_${lineNumber}_amount_gbp`} type="number" step="0.01" min="0" defaultValue={line.amount || ""} className="rounded-xl border border-slate-300 px-3 py-2 text-sm" placeholder="Amount GBP" />
            </div>
          );
        })}
      </div>
    </div>
  );
}

function AdjustmentInputs() {
  return (
    <div className="grid gap-4 md:grid-cols-2">
      <label className="block text-sm font-semibold text-slate-700">
        Delivery refund / adjustment GBP optional
        <input name="delivery_adjustment_gbp" type="number" step="0.01" min="0" className="mt-2 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm" placeholder="0.00" />
      </label>
      <label className="block text-sm font-semibold text-slate-700">
        Discount adjustment GBP optional
        <input name="discount_adjustment_gbp" type="number" step="0.01" min="0" className="mt-2 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm" placeholder="0.00" />
      </label>
    </div>
  );
}

function HiddenBaseFields({ disputeId, originalOrderId, mode }: { disputeId: string; originalOrderId: string; mode: Mode }) {
  return (
    <>
      <input type="hidden" name="dispute_id" value={disputeId} />
      <input type="hidden" name="original_order_id" value={originalOrderId} />
      <input type="hidden" name="document_mode" value={mode} />
    </>
  );
}

function ReturnHistory({ rows }: { rows: HistoryRow[] }) {
  if (rows.length === 0) {
    return (
      <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-600">
        No return/collection submissions yet.
      </div>
    );
  }

  return (
    <div className="rounded-3xl border border-slate-200 bg-white p-5">
      <div className="flex items-center justify-between gap-3">
        <div>
          <h3 className="text-lg font-semibold">Return / collection submission history</h3>
          <p className="mt-1 text-sm text-slate-600">Operator submissions and supervisor reviews appear here, so the operator can see what has already been sent.</p>
        </div>
        <span className="rounded-full bg-emerald-50 px-3 py-1 text-xs font-semibold text-emerald-800 ring-1 ring-emerald-200">{rows.length} record(s)</span>
      </div>
      <div className="mt-4 space-y-3">
        {rows.map((row) => (
          <article key={row.id} className={`rounded-2xl border p-4 text-sm ${row.message_type === "return_collection_evidence_review" ? "border-amber-200 bg-amber-50" : "border-slate-200 bg-slate-50"}`}>
            <p className="font-semibold">
              {row.message_type === "return_collection_evidence_review" ? "Supervisor review" : "Operator return/collection submission"}
              {row.generated_by ? ` · ${row.generated_by}` : ""}
            </p>
            <p className="mt-2 whitespace-pre-wrap text-slate-700">{row.body}</p>
            <p className="mt-2 text-xs text-slate-500">{row.created_at ?? "—"}</p>
          </article>
        ))}
      </div>
    </div>
  );
}

function ReturnCollectionEvidenceForm({ disputeId, courierOptions }: { disputeId: string; courierOptions: CourierOption[] }) {
  return (
    <form action={uploadReturnCollectionEvidenceAction} encType="multipart/form-data" className="space-y-5 rounded-3xl border border-slate-200 bg-white p-5">
      <input type="hidden" name="dispute_id" value={disputeId} />
      <div>
        <p className="text-sm font-medium uppercase tracking-[0.2em] text-slate-500">Operational evidence</p>
        <h3 className="mt-2 text-lg font-semibold">Return / collection / tracking evidence</h3>
        <p className="mt-1 text-sm text-slate-600">
          Use this as soon as the retailer gives return instructions, collection details, label, tracking or proof. You can submit more than once. This does not feed supplier draft readiness; credit note/refund evidence can be submitted later.
        </p>
      </div>

      <div className="grid gap-4 md:grid-cols-2">
        <label className="block text-sm font-semibold text-slate-700">
          Courier
          <select name="courier_id" className="mt-2 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm">
            <option value="">Courier</option>
            {courierOptions.map((courier) => (
              <option key={courier.id} value={courier.id}>{courier.name}</option>
            ))}
          </select>
        </label>
        <label className="block text-sm font-semibold text-slate-700">
          Tracking ref
          <input name="tracking_ref" className="mt-2 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm" placeholder="Tracking ref" />
        </label>
        <label className="block text-sm font-semibold text-slate-700">
          Tracking date
          <input name="tracking_date" type="date" className="mt-2 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm" />
        </label>
        <label className="block text-sm font-semibold text-slate-700">
          Tracking URL / evidence link
          <input name="tracking_evidence_url" className="mt-2 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm" placeholder="Tracking URL / evidence link" />
        </label>
      </div>

      <div className="grid gap-4 md:grid-cols-3">
        <label className="block text-sm font-semibold text-slate-700">
          Retailer instructions upload optional
          <input name="retailer_return_instructions_file" type="file" className="mt-2 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm" />
        </label>
        <label className="block text-sm font-semibold text-slate-700">
          Return label upload optional
          <input name="return_label_file" type="file" className="mt-2 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm" />
        </label>
        <label className="block text-sm font-semibold text-slate-700">
          Return proof upload optional
          <input name="return_proof_file" type="file" className="mt-2 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm" />
        </label>
      </div>

      <label className="block text-sm font-semibold text-slate-700">
        Note
        <input name="note" className="mt-2 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm" placeholder="Note" />
      </label>

      <label className="flex items-center gap-2 text-sm font-semibold text-slate-700">
        <input type="checkbox" name="is_final_return_yn" className="h-4 w-4 rounded border-slate-300" />
        This completes return/collection for this exception
      </label>

      <button type="submit" className="rounded-xl bg-slate-700 px-5 py-3 text-sm font-semibold text-white">Save return / collection evidence only</button>
    </form>
  );
}

export default function RefundEvidenceModeSelector({ disputeId, originalOrderId, invoiceOptions, courierOptions, prefillLines, returnHistory }: Props) {
  const [mode, setMode] = useState<Mode>("credit_note");

  return (
    <div className="mt-6 space-y-6">
      <ReturnCollectionEvidenceForm disputeId={disputeId} courierOptions={courierOptions} />
      <ReturnHistory rows={returnHistory} />

      <div className="rounded-3xl border-2 border-dashed border-sky-200 bg-sky-50 p-5">
        <p className="text-sm font-medium uppercase tracking-[0.2em] text-sky-600">Refund document / credit note evidence</p>
        <h3 className="mt-2 text-lg font-semibold">Submit this only when the retailer gives the refund document or confirms no document exists</h3>
        <p className="mt-1 text-sm text-slate-600">This is separate from return tracking. This section feeds supplier draft readiness.</p>
      </div>

      <fieldset className="rounded-3xl border border-slate-200 bg-slate-50 p-4">
        <legend className="px-2 text-sm font-semibold text-slate-700">What refund document did the retailer provide?</legend>
        <div className="mt-3 grid gap-3 md:grid-cols-3">
          {[
            ["credit_note", "Credit note issued", "Use invoice-style upload; OCR/compare comes next."],
            ["refund_proof_no_credit_note", "Refund proof, no credit note", "Use prefilled exception lines as the refund adjustment source."],
            ["no_document", "No document issued", "Requires explanation and supervisor exception control."],
          ].map(([value, title, detail]) => (
            <label key={value} className={`cursor-pointer rounded-2xl border p-4 text-sm ${mode === value ? "border-sky-300 bg-white ring-2 ring-sky-100" : "border-slate-200 bg-white"}`}>
              <input type="radio" name="refund_evidence_mode_selector" value={value} checked={mode === value} onChange={() => setMode(value as Mode)} className="mr-2" />
              <span className="font-semibold text-slate-950">{title}</span>
              <p className="mt-1 text-xs text-slate-600">{detail}</p>
            </label>
          ))}
        </div>
      </fieldset>

      {mode === "credit_note" ? (
        <form action={uploadOperatorCreditNoteEvidenceAction} encType="multipart/form-data" className="space-y-5 rounded-3xl border border-sky-200 bg-white p-5">
          <HiddenBaseFields disputeId={disputeId} originalOrderId={originalOrderId} mode="credit_note" />
          <h3 className="text-lg font-semibold">Credit note issued</h3>
          <p className="text-sm text-slate-600">Enter the expected credit-note total and upload the document. OCR/compare will decide whether it is ready or needs review.</p>
          <InvoiceSelector invoiceOptions={invoiceOptions} />
          <div className="grid gap-4 md:grid-cols-2">
            <label className="block text-sm font-semibold text-slate-700">
              Credit note ref
              <input name="credit_note_ref" required className="mt-2 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm" placeholder="e.g. CN-12345" />
            </label>
            <label className="block text-sm font-semibold text-slate-700">
              Expected credit note total GBP
              <input name="expected_credit_note_total_gbp" type="number" step="0.01" min="0" required className="mt-2 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm" placeholder="0.00" />
            </label>
          </div>
          <div className="grid gap-4 md:grid-cols-2">
            <label className="block text-sm font-semibold text-slate-700">
              Credit note date optional
              <input name="credit_note_date" type="date" className="mt-2 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm" />
            </label>
            <label className="block text-sm font-semibold text-slate-700">
              Credit note file
              <input name="credit_note_file" type="file" required className="mt-2 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm" />
            </label>
          </div>
          <AdjustmentInputs />
          <label className="block text-sm font-semibold text-slate-700">
            Notes optional
            <textarea name="notes" rows={3} className="mt-2 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm" />
          </label>
          <button type="submit" className="rounded-xl bg-slate-950 px-5 py-3 text-sm font-semibold text-white">Submit credit note for OCR/readiness</button>
        </form>
      ) : null}

      {mode === "refund_proof_no_credit_note" ? (
        <form action={uploadOperatorCreditNoteEvidenceAction} encType="multipart/form-data" className="space-y-5 rounded-3xl border border-sky-200 bg-white p-5">
          <HiddenBaseFields disputeId={disputeId} originalOrderId={originalOrderId} mode="refund_proof_no_credit_note" />
          <h3 className="text-lg font-semibold">Refund proof, no credit note</h3>
          <p className="text-sm text-slate-600">Upload proof if available and confirm the prefilled exception lines. If balanced, this routes as supplier refund-adjustment readiness.</p>
          <InvoiceSelector invoiceOptions={invoiceOptions} />
          <label className="block text-sm font-semibold text-slate-700">
            Refund proof file optional if notes explain it
            <input name="refund_proof_file" type="file" className="mt-2 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm" />
          </label>
          <RefundLineInputs prefillLines={prefillLines} />
          <AdjustmentInputs />
          <label className="block text-sm font-semibold text-slate-700">
            Notes
            <textarea name="notes" rows={3} className="mt-2 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm" placeholder="Retailer refunded without issuing a credit note" />
          </label>
          <button type="submit" className="rounded-xl bg-sky-700 px-5 py-3 text-sm font-semibold text-white">Submit refund adjustment evidence</button>
        </form>
      ) : null}

      {mode === "no_document" ? (
        <form action={uploadOperatorCreditNoteEvidenceAction} encType="multipart/form-data" className="space-y-5 rounded-3xl border border-amber-200 bg-white p-5">
          <HiddenBaseFields disputeId={disputeId} originalOrderId={originalOrderId} mode="no_document" />
          <h3 className="text-lg font-semibold">No document issued</h3>
          <p className="text-sm text-slate-600">Use this only where the retailer provided no document. It will route as supervisor review required.</p>
          <InvoiceSelector invoiceOptions={invoiceOptions} />
          <RefundLineInputs prefillLines={prefillLines} />
          <AdjustmentInputs />
          <label className="block text-sm font-semibold text-slate-700">
            Notes required
            <textarea name="notes" rows={3} required className="mt-2 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm" placeholder="Explain why no document was issued and what the retailer confirmed" />
          </label>
          <button type="submit" className="rounded-xl bg-amber-700 px-5 py-3 text-sm font-semibold text-white">Submit no-document evidence for review</button>
        </form>
      ) : null}
    </div>
  );
}
