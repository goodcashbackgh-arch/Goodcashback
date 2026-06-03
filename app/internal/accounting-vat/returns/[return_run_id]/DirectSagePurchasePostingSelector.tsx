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

function isGenericDocumentLabel(label: string): boolean {
  const normalized = label.trim().toLowerCase().replace(/[_-]+/g, " ").replace(/\s+/g, " ");
  return !normalized || new Set(["document", "invoice", "purchase invoice", "credit note", "purchase credit note", "bill", "unknown"]).has(normalized);
}

function directSageDisplayLabel(row: Row): string {
  const existing = text(row.document_label);
  if (existing && !isGenericDocumentLabel(existing)) return existing;
  const parts = [text(row.supplier_contact) || "Sage purchase document"];
  const rawDate = text(row.document_date).match(/^\d{4}-\d{2}-\d{2}/)?.[0] ?? "";
  if (rawDate) parts.push(rawDate);
  const gross = num(row.gross_amount);
  if (Math.abs(gross) > 0.005) parts.push(`£${Math.abs(gross).toFixed(2)}`);
  return parts.join(" — ");
}

function lineIndexes(row: Row): number[] {
  const value = row.selected_line_indexes;
  const indexes = Array.isArray(value) ? value : text(value).split(",");
  return indexes.map((item) => Number(text(item))).filter((item) => Number.isInteger(item) && item >= 0);
}

function groupCanBeSelected(row: Row): boolean {
  return yes(row.selectable) && lineIndexes(row).length > 0;
}

function taxProfile(row: Row): string {
  return text(row.tax_profile_summary) || "—";
}

function searchText(row: Row): string {
  return [directSageDisplayLabel(row), row.sage_document_id, row.supplier_contact, row.document_date, row.document_status, row.tax_profile_summary].map(text).join(" ").toLowerCase();
}

function nil(value: number): boolean {
  return Math.abs(value) <= 0.01;
}

export function DirectSagePurchasePostingSelector({ runId, snapshotId, rows, platformBox4, platformBox7, sageBox4, sageBox7 }: Props) {
  const [selectedGroupKeys, setSelectedGroupKeys] = useState<Set<string>>(new Set());
  const [query, setQuery] = useState("");
  const [showResolvedDetails, setShowResolvedDetails] = useState(false);
  const [visibleCount, setVisibleCount] = useState(50);
  const selectableKeys = useMemo(() => rows.filter(groupCanBeSelected).map((row, index) => text(row.group_key) || String(index)), [rows]);
  const selectedRows = rows.filter((row, index) => selectedGroupKeys.has(text(row.group_key) || String(index)));
  const selectedBox4 = selectedRows.reduce((sum, row) => sum + num(row.effective_box4_amount), 0);
  const selectedBox7 = selectedRows.reduce((sum, row) => sum + num(row.effective_box7_amount), 0);
  const remainingBox4 = platformBox4 + selectedBox4 - sageBox4;
  const remainingBox7 = platformBox7 + selectedBox7 - sageBox7;
  const invalidSelection = selectedRows.some((row) => !groupCanBeSelected(row));
  const canProceed = selectedGroupKeys.size > 0 && nil(remainingBox4) && nil(remainingBox7) && !invalidSelection;
  const selectedIndexes = selectedRows.flatMap(lineIndexes).sort((a, b) => a - b);
  const approvalUrl = `/internal/accounting-vat/returns/${runId}/sage-only-purchase-approval?sage_snapshot_id=${encodeURIComponent(snapshotId)}&selected_line_indexes=${encodeURIComponent(selectedIndexes.join(","))}`;
  const showSearch = rows.length > 50;
  const filteredRows = query.trim() ? rows.filter((row) => searchText(row).includes(query.trim().toLowerCase())) : rows;
  const visibleRows = filteredRows.slice(0, visibleCount);
  const fullyReconciled = rows.length === 0 && nil(remainingBox4) && nil(remainingBox7);

  if (fullyReconciled && !showResolvedDetails) {
    return <section className="rounded-3xl border border-emerald-200 bg-emerald-50 p-5 text-emerald-950 shadow-sm">
      <div className="flex flex-wrap items-center justify-between gap-4">
        <div>
          <h2 className="text-lg font-semibold">No unresolved direct Sage postings</h2>
          <p className="mt-1 text-sm leading-6">Direct Sage postings not on platform are 0, and the remaining Box 4 / Box 7 difference is £0.00.</p>
        </div>
        <button type="button" onClick={() => setShowResolvedDetails(true)} className="rounded-xl border border-emerald-300 bg-white px-4 py-2 text-sm font-bold text-emerald-800 hover:bg-emerald-100">Show resolved workbench details</button>
      </div>
    </section>;
  }

  return <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
    <div className="flex flex-wrap items-start justify-between gap-4">
      <div>
        <h2 className="text-lg font-semibold">Direct Sage postings not on platform</h2>
        <p className="mt-1 text-sm leading-6 text-slate-600">Select Sage purchase-side documents that explain the remaining Box 4 / Box 7 difference. Each visible row is a document group; approval still submits the hidden line indexes for audit and RPC validation.</p>
      </div>
      <div className="flex flex-wrap gap-2">
        {fullyReconciled ? <button type="button" onClick={() => setShowResolvedDetails(false)} className="rounded-xl border border-emerald-300 bg-emerald-50 px-3 py-2 text-xs font-bold text-emerald-800 hover:bg-emerald-100">Hide resolved workbench details</button> : null}
        {rows.length ? <button type="button" onClick={() => setSelectedGroupKeys(new Set(selectableKeys))} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-xs font-bold text-slate-700 hover:bg-slate-50">Select all direct documents</button> : null}
        {rows.length ? <button type="button" onClick={() => setSelectedGroupKeys(new Set())} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-xs font-bold text-slate-700 hover:bg-slate-50">Unselect all</button> : null}
      </div>
    </div>

    <div className="mt-4 grid gap-3 md:grid-cols-4">
      <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4"><p className="text-xs font-bold uppercase text-slate-500">Selected Box 4</p><p className="mt-1 text-xl font-extrabold">{gbp(selectedBox4)}</p></div>
      <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4"><p className="text-xs font-bold uppercase text-slate-500">Selected Box 7</p><p className="mt-1 text-xl font-extrabold">{gbp(selectedBox7)}</p></div>
      <div className={`rounded-2xl border p-4 ${nil(remainingBox4) ? "border-emerald-200 bg-emerald-50 text-emerald-900" : "border-amber-200 bg-amber-50 text-amber-900"}`}><p className="text-xs font-bold uppercase opacity-70">Remaining Box 4 difference</p><p className="mt-1 text-xl font-extrabold">{gbp(remainingBox4)}</p></div>
      <div className={`rounded-2xl border p-4 ${nil(remainingBox7) ? "border-emerald-200 bg-emerald-50 text-emerald-900" : "border-amber-200 bg-amber-50 text-amber-900"}`}><p className="text-xs font-bold uppercase opacity-70">Remaining Box 7 difference</p><p className="mt-1 text-xl font-extrabold">{gbp(remainingBox7)}</p></div>
    </div>

    {showSearch ? <div className="mt-4"><label className="text-xs font-bold uppercase tracking-wide text-slate-500" htmlFor="direct-sage-document-search">Filter document groups</label><input id="direct-sage-document-search" value={query} onChange={(event) => { setQuery(event.target.value); setVisibleCount(50); }} placeholder="Search supplier, ref, date, status or tax profile" className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm outline-none focus:border-sky-400" /></div> : null}

    <div className="mt-5 overflow-x-auto">
      <table className="min-w-full divide-y divide-slate-200 text-left text-sm">
        <thead className="text-xs uppercase tracking-wide text-slate-500"><tr><th className="px-3 py-2">Select</th><th className="px-3 py-2">Document/ref</th><th className="px-3 py-2">Supplier/contact</th><th className="px-3 py-2">Document date</th><th className="px-3 py-2">Status</th><th className="px-3 py-2">Ledger summary</th><th className="px-3 py-2">Tax profile</th><th className="px-3 py-2">Classification</th><th className="px-3 py-2">Net</th><th className="px-3 py-2">VAT</th><th className="px-3 py-2">Gross</th><th className="px-3 py-2">Box 4 effect</th><th className="px-3 py-2">Box 7 effect</th><th className="px-3 py-2">Lines</th><th className="px-3 py-2">Reason summary</th><th className="px-3 py-2">Action/help text</th></tr></thead>
        <tbody className="divide-y divide-slate-100">
          {visibleRows.length ? visibleRows.map((row, index) => {
            const groupKey = text(row.group_key) || String(index);
            const selectable = groupCanBeSelected(row);
            return <tr key={groupKey} className={selectable ? "bg-white" : "bg-slate-50 text-slate-500"}>
              <td className="whitespace-nowrap px-3 py-2"><input type="checkbox" checked={selectedGroupKeys.has(groupKey)} disabled={!selectable} aria-label={`Select ${directSageDisplayLabel(row) || `document ${index + 1}`}`} onChange={(event) => setSelectedGroupKeys((prev) => { const next = new Set(prev); if (event.target.checked) next.add(groupKey); else next.delete(groupKey); return next; })} /></td>
              <td className="whitespace-nowrap px-3 py-2 font-semibold">{cut(directSageDisplayLabel(row) || row.sage_document_id, 34)}</td>
              <td className="whitespace-nowrap px-3 py-2">{cut(row.supplier_contact, 34)}</td>
              <td className="whitespace-nowrap px-3 py-2">{date(row.document_date)}</td>
              <td className="whitespace-nowrap px-3 py-2">{cut(row.document_status, 24)}</td>
              <td className="whitespace-nowrap px-3 py-2">{cut(row.ledger_summary, 34)}</td>
              <td className="whitespace-nowrap px-3 py-2">{cut(taxProfile(row), 28)}</td>
              <td className="whitespace-nowrap px-3 py-2">{cut(row.classification_summary, 36)}</td>
              <td className="whitespace-nowrap px-3 py-2 font-semibold">{gbp(row.net_amount)}</td>
              <td className="whitespace-nowrap px-3 py-2 font-semibold">{gbp(row.vat_amount)}</td>
              <td className="whitespace-nowrap px-3 py-2 font-semibold">{gbp(row.gross_amount)}</td>
              <td className="whitespace-nowrap px-3 py-2 font-semibold">{gbp(row.effective_box4_amount)}</td>
              <td className="whitespace-nowrap px-3 py-2 font-semibold">{gbp(row.effective_box7_amount)}</td>
              <td className="whitespace-nowrap px-3 py-2 font-semibold">{num(row.line_count)}</td>
              <td className="min-w-48 px-3 py-2">{cut(row.reason_summary, 70)}</td>
              <td className="min-w-44 px-3 py-2">Copy ref / open Sage manually</td>
            </tr>;
          }) : <tr><td className="px-3 py-6 text-center text-slate-500" colSpan={16}>No direct Sage document groups not on platform found in the latest review snapshot.</td></tr>}
        </tbody>
      </table>
    </div>

    {filteredRows.length > visibleRows.length ? <div className="mt-4 flex justify-center"><button type="button" onClick={() => setVisibleCount((count) => count + 50)} className="rounded-xl border border-slate-300 bg-white px-4 py-2 text-sm font-bold text-slate-700 hover:bg-slate-50">Show more direct Sage documents ({filteredRows.length - visibleRows.length} remaining)</button></div> : null}

    {!fullyReconciled ? <div className="mt-5 flex flex-wrap items-center justify-between gap-3 rounded-2xl border border-slate-200 bg-slate-50 p-4">
      <p className="text-sm font-semibold text-slate-700">{canProceed ? "Ready to proceed: selected document groups reconcile Box 4 and Box 7 to nil." : "Select direct Sage document groups until both remaining differences are £0.00 within £0.01."}</p>
      {canProceed ? <a href={approvalUrl} className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-bold text-white hover:bg-slate-800">Proceed to final approval</a> : <button type="button" disabled className="cursor-not-allowed rounded-xl bg-slate-200 px-4 py-2 text-sm font-bold text-slate-500">Proceed to final approval</button>}
    </div> : null}
  </section>;
}
