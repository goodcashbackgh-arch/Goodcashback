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

export type RefundDocumentHistoryRow = {
  id: string;
  document_mode: string | null;
  credit_note_ref: string | null;
  credit_note_date: string | null;
  expected_credit_note_total_gbp: number | null;
  captured_refund_amount_abs_gbp: number | null;
  expected_exception_amount_abs_gbp: number | null;
  variance_abs_gbp: number | null;
  credit_note_file_url: string | null;
  refund_proof_file_url: string | null;
  ocr_status: string | null;
  match_status: string | null;
  amount_balance_status: string | null;
  supplier_control_status: string | null;
  supplier_approval_status: string | null;
  supervisor_review_status: string | null;
  notes: string | null;
  submitted_at: string | null;
};

type Props = {
  disputeId: string;
  originalOrderId: string;
  invoiceOptions: SupplierInvoiceOption[];
  courierOptions: CourierOption[];
  prefillLines: PrefillLine[];
  returnHistory: HistoryRow[];
  refundDocumentHistory: RefundDocumentHistoryRow[];
};

type Mode = "credit_note" | "refund_proof_no_credit_note" | "no_document";

function gbp(value: unknown) {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" }).format(Number(value ?? 0));
}

function statusLabel(value: string | null | undefined) {
  if (!value) return "Pending";
  return value.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase());
}

function modeLabel(value: string | null | undefined) {
  if (value === "credit_note") return "Credit note issued";
  if (value === "refund_proof_no_credit_note") return "Refund proof, no credit note";
  if (value === "no_document") return "No document issued";
  return statusLabel(value);
}

function badgeClass(value: string | null | undefined) {
  const status = String(value ?? "");
  if (["completed", "balanced", "approved_current", "accepted", "released_to_supplier_control", "matched_ready_to_release"].includes(status)) {
    return "bg-emerald-50 text-emerald-800 ring-1 ring-emerald-200";
  }
  if (["needs_supervisor_review", "pending", "pending_review", "pending_ocr", "not_released", "not_required"].includes(status)) {
    return "bg-amber-50 text-amber-800 ring-1 ring-amber-200";
  }
  if (["blocked", "failed", "rejected", "variance"].includes(status)) {
    return "bg-rose-50 text-rose-800 ring-1 ring-rose-200";
  }
  return "bg-slate-100 text-slate-700 ring-1 ring-slate-200";
}

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
      <p className="mt-1 text-xs text-slate-500">Prefilled from the exception. Confirm the lines that the refund document/proof covers.</p>
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

function historyValue(body: string, label: string) {
  return body.match(new RegExp(`${label}:\\s*(.*)`))?.[1]?.trim() || "";
}

function compactHistoryLine(row: HistoryRow) {
  const body = row.body ?? "";
  const courier = historyValue(body, "Courier");
  const trackingRef = historyValue(body, "Tracking reference");
  const trackingDate = historyValue(body, "Tracking date");
  const status = row.generated_by || historyValue(body, "Supervisor review") || "Pending review";

  if (row.message_type === "return_collection_evidence_review") return `Supervisor review · ${status}`;

  return [courier || "Courier not provided", trackingRef || "No tracking ref", trackingDate || "No date", status].join(" · ");
}

function detailRows(body: string | null) {
  return (body ?? "").split("\n").map((line) => line.trim()).filter(Boolean);
}

function ReturnHistory({ rows }: { rows: HistoryRow[] }) {
  return (
    <div className="rounded-3xl border border-slate-200 bg-white p-5">
      <div className="flex items-center justify-between gap-3">
        <div>
          <h3 className="text-lg font-semibold">Return / collection submission history</h3>
          <p className="mt-1 text-sm text-slate-600">Operational return tracking only. This does not approve the refund value.</p>
        </div>
        <span className="rounded-full bg-emerald-50 px-3 py-1 text-xs font-semibold text-emerald-800 ring-1 ring-emerald-200">{rows.length} record(s)</span>
      </div>

      {rows.length === 0 ? (
        <div className="mt-4 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-600">No return/collection submissions yet.</div>
      ) : (
        <div className="mt-4 divide-y divide-slate-200 overflow-hidden rounded-2xl border border-slate-200">
          {rows.map((row) => (
            <details key={row.id} className="group bg-white open:bg-slate-50">
              <summary className="flex cursor-pointer list-none items-center justify-between gap-3 px-4 py-3 text-sm hover:bg-slate-50">
                <span className="font-semibold text-slate-900">{compactHistoryLine(row)}</span>
                <span className="shrink-0 rounded-full bg-slate-100 px-3 py-1 text-xs font-semibold text-slate-600 group-open:bg-sky-100 group-open:text-sky-700">View details</span>
              </summary>
              <div className="space-y-2 border-t border-slate-200 px-4 py-4 text-sm text-slate-700">
                {detailRows(row.body).map((line, index) => <p key={`${row.id}-${index}`} className="break-words">{line}</p>)}
                <p className="pt-2 text-xs text-slate-500">Submitted: {row.created_at ?? "—"}</p>
              </div>
            </details>
          ))}
        </div>
      )}
    </div>
  );
}

function RefundDocumentHistory({ rows }: { rows: RefundDocumentHistoryRow[] }) {
  return (
    <div className="rounded-3xl border border-sky-200 bg-white p-5">
      <div className="flex items-center justify-between gap-3">
        <div>
          <h3 className="text-lg font-semibold">Refund document / credit note submission history</h3>
          <p className="mt-1 text-sm text-slate-600">Structured credit-note, refund-proof and no-document submissions. OCR/control happens in the internal supplier credit lane.</p>
        </div>
        <span className="rounded-full bg-sky-50 px-3 py-1 text-xs font-semibold text-sky-800 ring-1 ring-sky-200">{rows.length} record(s)</span>
      </div>

      {rows.length === 0 ? (
        <div className="mt-4 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-600">No refund document / credit note submissions yet.</div>
      ) : (
        <div className="mt-4 space-y-3">
          {rows.map((row) => {
            const amount = row.expected_credit_note_total_gbp ?? row.captured_refund_amount_abs_gbp ?? row.expected_exception_amount_abs_gbp ?? 0;
            return (
              <article key={row.id} className="rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm">
                <div className="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
                  <div>
                    <p className="font-semibold text-slate-950">{modeLabel(row.document_mode)} · {gbp(amount)}</p>
                    <p className="mt-1 text-slate-600">Ref {row.credit_note_ref ?? "—"} · Date {row.credit_note_date ?? "—"} · Submitted {row.submitted_at ?? "—"}</p>
                  </div>
                  <div className="flex flex-wrap gap-2">
                    <span className={`rounded-full px-2 py-1 text-xs font-semibold ${badgeClass(row.ocr_status)}`}>OCR {statusLabel(row.ocr_status)}</span>
                    <span className={`rounded-full px-2 py-1 text-xs font-semibold ${badgeClass(row.match_status)}`}>Match {statusLabel(row.match_status)}</span>
                    <span className={`rounded-full px-2 py-1 text-xs font-semibold ${badgeClass(row.amount_balance_status)}`}>Amount {statusLabel(row.amount_balance_status)}</span>
                    <span className={`rounded-full px-2 py-1 text-xs font-semibold ${badgeClass(row.supplier_approval_status)}`}>Approval {statusLabel(row.supplier_approval_status)}</span>
                  </div>
                </div>
                <div className="mt-3 flex flex-wrap gap-3 text-xs">
                  {row.credit_note_file_url ? <a href={row.credit_note_file_url} target="_blank" className="font-semibold text-sky-700 underline">Open credit note file</a> : null}
                  {row.refund_proof_file_url ? <a href={row.refund_proof_file_url} target="_blank" className="font-semibold text-sky-700 underline">Open refund proof</a> : null}
                  <span className="text-slate-500">Control: {statusLabel(row.supplier_control_status)}</span>
                  <span className="text-slate-500">Review: {statusLabel(row.supervisor_review_status)}</span>
                  {Math.abs(Number(row.variance_abs_gbp ?? 0)) > 0.01 ? <span className="font-semibold text-amber-700">Variance {gbp(row.variance_abs_gbp)}</span> : null}
                </div>
                {row.notes ? <p className="mt-2 text-xs text-slate-600">Notes: {row.notes}</p> : null}
              </article>
            );
          })}
        </div>
      )}
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
        <p className="mt-1 text-sm text-slate-600">Use this as soon as the retailer gives return instructions, collection details, label, tracking or proof. You can submit more than once. This does not feed supplier draft readiness.</p>
      </div>

      <div className="grid gap-4 md:grid-cols-2">
        <label className="block text-sm font-semibold text-slate-700">Courier<select name="courier_id" className="mt-2 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm"><option value="">Courier</option>{courierOptions.map((courier) => <option key={courier.id} value={courier.id}>{courier.name}</option>)}</select></label>
        <label className="block text-sm font-semibold text-slate-700">Tracking ref<input name="tracking_ref" className="mt-2 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm" placeholder="Tracking ref" /></label>
        <label className="block text-sm font-semibold text-slate-700">Tracking date<input name="tracking_date" type="date" className="mt-2 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm" /></label>
        <label className="block text-sm font-semibold text-slate-700">Tracking URL / evidence link<input name="tracking_evidence_url" className="mt-2 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm" placeholder="Tracking URL / evidence link" /></label>
      </div>

      <div className="grid gap-4 md:grid-cols-3">
        <label className="block text-sm font-semibold text-slate-700">Retailer instructions upload optional<input name="retailer_return_instructions_file" type="file" className="mt-2 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm" /></label>
        <label className="block text-sm font-semibold text-slate-700">Return label upload optional<input name="return_label_file" type="file" className="mt-2 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm" /></label>
        <label className="block text-sm font-semibold text-slate-700">Return proof upload optional<input name="return_proof_file" type="file" className="mt-2 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm" /></label>
      </div>

      <label className="block text-sm font-semibold text-slate-700">Note<input name="note" className="mt-2 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm" placeholder="Note" /></label>
      <label className="flex items-center gap-2 text-sm font-semibold text-slate-700"><input type="checkbox" name="is_final_return_yn" className="h-4 w-4 rounded border-slate-300" />This completes return/collection for this exception</label>
      <button type="submit" className="rounded-xl bg-slate-700 px-5 py-3 text-sm font-semibold text-white">Save return / collection evidence only</button>
    </form>
  );
}

function NotesBox({ required = false }: { required?: boolean }) {
  return (
    <label className="block text-sm font-semibold text-slate-700">
      Notes {required ? "required" : "optional"}
      <textarea name="notes" required={required} rows={4} className="mt-2 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm" placeholder="Add retailer explanation or internal context" />
    </label>
  );
}

export default function RefundEvidenceModeSelector({ disputeId, originalOrderId, invoiceOptions, courierOptions, prefillLines, returnHistory, refundDocumentHistory }: Props) {
  const [mode, setMode] = useState<Mode>("credit_note");
  const hasPriorRefundDocument = refundDocumentHistory.length > 0;

  return (
    <div className="mt-6 space-y-6">
      <ReturnCollectionEvidenceForm disputeId={disputeId} courierOptions={courierOptions} />
      <ReturnHistory rows={returnHistory} />
      <RefundDocumentHistory rows={refundDocumentHistory} />

      <div className="rounded-3xl border-2 border-dashed border-sky-200 bg-sky-50 p-5">
        <p className="text-sm font-medium uppercase tracking-[0.2em] text-sky-600">Refund document / credit note evidence</p>
        <h3 className="mt-2 text-lg font-semibold">Submit this only when the retailer gives the refund document or confirms no document exists</h3>
        <p className="mt-1 text-sm text-slate-600">This is separate from return tracking. This section feeds supplier credit/refund document control.</p>
        {hasPriorRefundDocument ? <p className="mt-3 rounded-2xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">A refund document has already been submitted. Submit again only if the retailer issued a revised or additional document.</p> : null}
      </div>

      <fieldset className="rounded-3xl border border-slate-200 bg-slate-50 p-4">
        <legend className="px-2 text-sm font-semibold text-slate-700">What refund document did the retailer provide?</legend>
        <div className="mt-3 grid gap-3 md:grid-cols-3">
          {[
            ["credit_note", "Credit note issued", "Upload the credit note; OCR/compare comes next."],
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
            <label className="block text-sm font-semibold text-slate-700">Credit note ref<input name="credit_note_ref" required className="mt-2 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm" placeholder="e.g. CN-12345" /></label>
            <label className="block text-sm font-semibold text-slate-700">Expected credit note total GBP<input name="expected_credit_note_total_gbp" type="number" step="0.01" min="0" required className="mt-2 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm" placeholder="0.00" /></label>
            <label className="block text-sm font-semibold text-slate-700">Credit note date optional<input name="credit_note_date" type="date" className="mt-2 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm" /></label>
            <label className="block text-sm font-semibold text-slate-700">Credit note file<input name="credit_note_file" type="file" required className="mt-2 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm" /></label>
          </div>
          <AdjustmentInputs />
          <NotesBox />
          <button type="submit" className="rounded-xl bg-sky-700 px-5 py-3 text-sm font-semibold text-white">Submit credit note evidence</button>
        </form>
      ) : null}

      {mode === "refund_proof_no_credit_note" ? (
        <form action={uploadOperatorCreditNoteEvidenceAction} encType="multipart/form-data" className="space-y-5 rounded-3xl border border-sky-200 bg-white p-5">
          <HiddenBaseFields disputeId={disputeId} originalOrderId={originalOrderId} mode="refund_proof_no_credit_note" />
          <h3 className="text-lg font-semibold">Refund proof, no credit note</h3>
          <p className="text-sm text-slate-600">Use this when the retailer refunded or confirmed the adjustment but did not issue a formal credit note.</p>
          <InvoiceSelector invoiceOptions={invoiceOptions} />
          <RefundLineInputs prefillLines={prefillLines} />
          <AdjustmentInputs />
          <label className="block text-sm font-semibold text-slate-700">Refund proof upload optional<input name="refund_proof_file" type="file" className="mt-2 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm" /></label>
          <NotesBox />
          <button type="submit" className="rounded-xl bg-sky-700 px-5 py-3 text-sm font-semibold text-white">Submit refund proof evidence</button>
        </form>
      ) : null}

      {mode === "no_document" ? (
        <form action={uploadOperatorCreditNoteEvidenceAction} encType="multipart/form-data" className="space-y-5 rounded-3xl border border-amber-200 bg-white p-5">
          <HiddenBaseFields disputeId={disputeId} originalOrderId={originalOrderId} mode="no_document" />
          <h3 className="text-lg font-semibold">No document issued</h3>
          <p className="text-sm text-slate-600">Use only when the retailer confirms no credit note/refund document exists. This stays under supervisor exception control.</p>
          <InvoiceSelector invoiceOptions={invoiceOptions} />
          <RefundLineInputs prefillLines={prefillLines} />
          <AdjustmentInputs />
          <NotesBox required />
          <button type="submit" className="rounded-xl bg-amber-700 px-5 py-3 text-sm font-semibold text-white">Submit no-document evidence</button>
        </form>
      ) : null}
    </div>
  );
}
