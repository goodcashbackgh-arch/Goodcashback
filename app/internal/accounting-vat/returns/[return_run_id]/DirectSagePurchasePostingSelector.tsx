"use client";

import { useMemo, useState } from "react";

type Row = Record<string, unknown>;

type Props = {
  runId: string;
  snapshotId: string;
  rows: Row[];
  platformBox4: number;
  platformBox7: number;
  sageBox4: number;
  sageBox7: number;
};

const money = new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP", minimumFractionDigits: 2 });

function text(value: unknown): string {
  if (typeof value === "string") return value.trim();
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  if (typeof value === "boolean") return value ? "true" : "false";
  return "";
}

function num(value: unknown): number {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  const parsed = Number(text(value).replace(/,/g, ""));
  return Number.isFinite(parsed) ? parsed : 0;
}

function yes(value: unknown): boolean {
  return value === true || text(value).toLowerCase() === "true";
}

function gbp(value: unknown): string {
  return money.format(num(value));
}

function cut(value: unknown, max = 44): string {
  const raw = text(value).replaceAll("_", " ");
  return raw ? (raw.length > max ? `${raw.slice(0, max - 1)}…` : raw) : "—";
}

function date(value: unknown): string {
  const raw = text(value);
  if (!raw) return "—";
  const parsed = new Date(raw);
  if (Number.isNaN(parsed.getTime())) return raw;
  return new Intl.DateTimeFormat("en-GB", { day: "2-digit", month: "short", year: "numeric" }).format(parsed);
}

function lineIsReviewRequired(row: Row): boolean {
  return yes(row.review_required) || text(row.classification).toLowerCase() === "review_required_purchase_posting" || text(row.reason).toLowerCase().includes("review required");
}

function lineCanBeSelected(row: Row): boolean {
  return text(row.classification) === "direct_sage_purchase_posting_not_on_platform" && !yes(row.platform_controlled) && !lineIsReviewRequired(row);
}

function originalIndex(row: Row, fallback: number): number {
  const parsed = num(row.__direct_line_index);
  return Number.isInteger(parsed) && parsed >= 0 ? parsed : fallback;
}

function nil(value: number): boolean {
  return Math.abs(value) <= 0.01;
}

export function DirectSagePurchasePostingSelector({ runId, snapshotId, rows, platformBox4, platformBox7, sageBox4, sageBox7 }: Props) {
  const [selected, setSelected] = useState<Set<number>>(new Set());
  const selectableIndexes = useMemo(() => rows.map((row, index) => lineCanBeSelected(row) ? originalIndex(row, index) : -1).filter((index) => index >= 0), [rows]);
  const selectedRows = rows.filter((row, index) => selected.has(originalIndex(row, index)));
  const selectedBox4 = selectedRows.reduce((sum, row) => sum + num(row.effective_box4_amount), 0);
  const selectedBox7 = selectedRows.reduce((sum, row) => sum + num(row.effective_box7_amount), 0);
  const remainingBox4 = platformBox4 + selectedBox4 - sageBox4;
  const remainingBox7 = platformBox7 + selectedBox7 - sageBox7;
  const invalidSelection = selectedRows.some((row) => !lineCanBeSelected(row));
  const canProceed = selected.size > 0 && nil(remainingBox4) && nil(remainingBox7) && !invalidSelection;
  const selectedIndexes = Array.from(selected as Set<number>).sort((a, b) => a - b);
  const approvalUrl = `/internal/accounting-vat/returns/${runId}/sage-only-purchase-approval?sage_snapshot_id=${encodeURIComponent(snapshotId)}&selected_line_indexes=${encodeURIComponent(selectedIndexes.join(","))}`;

  return <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
    <div className="flex flex-wrap items-start justify-between gap-4">
      <div>
        <h2 className="text-lg font-semibold">Direct Sage postings not on platform</h2>
        <p className="mt-1 text-sm leading-6 text-slate-600">Select the exact Sage purchase-side posting lines that explain the remaining Box 4 / Box 7 difference. Platform-controlled or review-required lines are shown but cannot be selected.</p>
      </div>
      <div className="flex flex-wrap gap-2">
        <button type="button" onClick={() => setSelected(new Set(selectableIndexes))} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-xs font-bold text-slate-700 hover:bg-slate-50">Select all direct postings</button>
        <button type="button" onClick={() => setSelected(new Set())} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-xs font-bold text-slate-700 hover:bg-slate-50">Unselect all</button>
      </div>
    </div>

    <div className="mt-4 grid gap-3 md:grid-cols-4">
      <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4"><p className="text-xs font-bold uppercase text-slate-500">Selected Box 4</p><p className="mt-1 text-xl font-extrabold">{gbp(selectedBox4)}</p></div>
      <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4"><p className="text-xs font-bold uppercase text-slate-500">Selected Box 7</p><p className="mt-1 text-xl font-extrabold">{gbp(selectedBox7)}</p></div>
      <div className={`rounded-2xl border p-4 ${nil(remainingBox4) ? "border-emerald-200 bg-emerald-50 text-emerald-900" : "border-amber-200 bg-amber-50 text-amber-900"}`}><p className="text-xs font-bold uppercase opacity-70">Remaining Box 4 difference</p><p className="mt-1 text-xl font-extrabold">{gbp(remainingBox4)}</p></div>
      <div className={`rounded-2xl border p-4 ${nil(remainingBox7) ? "border-emerald-200 bg-emerald-50 text-emerald-900" : "border-amber-200 bg-amber-50 text-amber-900"}`}><p className="text-xs font-bold uppercase opacity-70">Remaining Box 7 difference</p><p className="mt-1 text-xl font-extrabold">{gbp(remainingBox7)}</p></div>
    </div>

    <div className="mt-5 overflow-x-auto">
      <table className="min-w-full divide-y divide-slate-200 text-left text-sm">
        <thead className="text-xs uppercase tracking-wide text-slate-500"><tr><th className="px-3 py-2">Select</th><th className="px-3 py-2">Document/ref</th><th className="px-3 py-2">Supplier/contact</th><th className="px-3 py-2">Document date</th><th className="px-3 py-2">Status</th><th className="px-3 py-2">Ledger</th><th className="px-3 py-2">Tax rate</th><th className="px-3 py-2">Description</th><th className="px-3 py-2">Net</th><th className="px-3 py-2">VAT</th><th className="px-3 py-2">Gross</th><th className="px-3 py-2">Box 4 effect</th><th className="px-3 py-2">Box 7 effect</th><th className="px-3 py-2">Reason</th><th className="px-3 py-2">Action/help text</th></tr></thead>
        <tbody className="divide-y divide-slate-100">
          {rows.length ? rows.map((row, index) => {
            const sourceIndex = originalIndex(row, index);
            const selectable = lineCanBeSelected(row);
            return <tr key={`${sourceIndex}-${text(row.sage_document_id) || text(row.document_label)}`} className={selectable ? "bg-white" : "bg-slate-50 text-slate-500"}>
              <td className="whitespace-nowrap px-3 py-2"><input type="checkbox" checked={selected.has(sourceIndex)} disabled={!selectable} aria-label={`Select ${text(row.document_label) || `line ${index + 1}`}`} onChange={(event) => setSelected((prev) => { const next = new Set(prev); if (event.target.checked) next.add(sourceIndex); else next.delete(sourceIndex); return next; })} /></td>
              <td className="whitespace-nowrap px-3 py-2 font-semibold">{cut(row.document_label || row.sage_document_id, 34)}</td>
              <td className="whitespace-nowrap px-3 py-2">{cut(row.supplier_contact, 34)}</td>
              <td className="whitespace-nowrap px-3 py-2">{date(row.document_date)}</td>
              <td className="whitespace-nowrap px-3 py-2">{cut(row.document_status, 24)}</td>
              <td className="whitespace-nowrap px-3 py-2">{cut(row.ledger_account, 34)}</td>
              <td className="whitespace-nowrap px-3 py-2">{cut(row.tax_rate, 28)}</td>
              <td className="min-w-48 px-3 py-2">{cut(row.line_description, 60)}</td>
              <td className="whitespace-nowrap px-3 py-2 font-semibold">{gbp(row.net_amount)}</td>
              <td className="whitespace-nowrap px-3 py-2 font-semibold">{gbp(row.vat_amount)}</td>
              <td className="whitespace-nowrap px-3 py-2 font-semibold">{gbp(row.gross_amount)}</td>
              <td className="whitespace-nowrap px-3 py-2 font-semibold">{gbp(row.effective_box4_amount)}</td>
              <td className="whitespace-nowrap px-3 py-2 font-semibold">{gbp(row.effective_box7_amount)}</td>
              <td className="min-w-56 px-3 py-2">{cut(row.reason, 90)}</td>
              <td className="min-w-44 px-3 py-2">Copy ref / open Sage manually</td>
            </tr>;
          }) : <tr><td className="px-3 py-6 text-center text-slate-500" colSpan={15}>No direct Sage postings not on platform found in the latest review snapshot.</td></tr>}
        </tbody>
      </table>
    </div>

    <div className="mt-5 flex flex-wrap items-center justify-between gap-3 rounded-2xl border border-slate-200 bg-slate-50 p-4">
      <p className="text-sm font-semibold text-slate-700">{canProceed ? "Ready to proceed: selected lines reconcile Box 4 and Box 7 to nil." : "Select direct Sage posting lines until both remaining differences are £0.00 within £0.01."}</p>
      {canProceed ? <a href={approvalUrl} className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-bold text-white hover:bg-slate-800">Proceed to final approval</a> : <button type="button" disabled className="cursor-not-allowed rounded-xl bg-slate-200 px-4 py-2 text-sm font-bold text-slate-500">Proceed to final approval</button>}
    </div>
  </section>;
}
