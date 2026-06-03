"use client";

import { useMemo, useState } from "react";
import { EMPTY_PURCHASE_VAT_FILTERS, filterPurchaseVatRows, PurchaseVatSectionFilters, type PurchaseVatFilters } from "./PurchaseVatSectionFilters";

type Row = Record<string, unknown>;

type ReviewTableProps = {
  title: string;
  rows: Row[];
  empty: string;
  tone?: "default" | "platform" | "review";
  collapseWhenHigh?: boolean;
};

type AcceptedProps = {
  rows: Row[];
};

const money = new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP", minimumFractionDigits: 2 });
const PAGE_SIZE = 50;

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

function gbp(value: unknown): string {
  return money.format(num(value));
}

function cut(value: unknown, max = 52): string {
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

function statusForAcceptedRow(): string[] {
  return ["Accepted", "Sage covered", "No journal"];
}

function statusForPlatformRow(): string[] {
  return ["Already platform-controlled", "Sage covered"];
}

function statusForReviewRow(): string[] {
  return ["Needs review"];
}

function Badge({ children, tone = "emerald" }: { children: string; tone?: "emerald" | "sky" | "slate" | "amber" }) {
  const classes = {
    emerald: "bg-emerald-100 text-emerald-800 ring-emerald-200",
    sky: "bg-sky-100 text-sky-800 ring-sky-200",
    slate: "bg-slate-100 text-slate-700 ring-slate-200",
    amber: "bg-amber-100 text-amber-900 ring-amber-200",
  }[tone];
  return <span className={`inline-flex rounded-full px-2.5 py-1 text-xs font-bold ring-1 ${classes}`}>{children}</span>;
}

function SummaryCard({ label, value, note }: { label: string; value: string; note: string }) {
  return <div className="rounded-2xl border border-emerald-200 bg-emerald-50 p-4 text-emerald-950">
    <p className="text-xs font-bold uppercase tracking-wide opacity-70">{label}</p>
    <p className="mt-1 text-2xl font-extrabold">{value}</p>
    <p className="mt-2 text-xs leading-5 opacity-90">{note}</p>
  </div>;
}

function ResultsPager({ shown, total, onShowMore, tone = "slate" }: { shown: number; total: number; onShowMore: () => void; tone?: "slate" | "emerald" }) {
  if (total <= PAGE_SIZE) return null;
  const buttonClass = tone === "emerald" ? "border-emerald-200 bg-emerald-50 text-emerald-800 hover:bg-emerald-100" : "border-slate-300 bg-white text-slate-700 hover:bg-slate-50";
  return <div className="mt-4 flex flex-wrap items-center justify-between gap-3 rounded-2xl border border-slate-200 bg-slate-50 px-4 py-3">
    <p className="text-sm font-semibold text-slate-700">Showing {Math.min(shown, total)} of {total}</p>
    {shown < total ? <button type="button" onClick={onShowMore} className={`rounded-xl border px-4 py-2 text-sm font-bold ${buttonClass}`}>Show more</button> : null}
  </div>;
}

export function AcceptedDirectSagePostings({ rows }: AcceptedProps) {
  const [filters, setFilters] = useState<PurchaseVatFilters>(EMPTY_PURCHASE_VAT_FILTERS);
  const [visibleCount, setVisibleCount] = useState(PAGE_SIZE);
  const filteredRows = useMemo(() => filterPurchaseVatRows(rows, filters, statusForAcceptedRow), [rows, filters]);
  const visibleRows = filteredRows.slice(0, visibleCount);
  const box4Accepted = rows.reduce((sum, row) => sum + num(row.effective_box4_amount), 0);
  const box7Accepted = rows.reduce((sum, row) => sum + num(row.effective_box7_amount), 0);

  return <section className="rounded-3xl border border-emerald-200 bg-white p-5 shadow-sm">
    <div className="flex flex-wrap items-start justify-between gap-3">
      <div>
        <h2 className="text-lg font-semibold tracking-tight">Accepted direct Sage postings — included in platform VAT return</h2>
        <p className="mt-1 text-sm leading-6 text-slate-600">Accepted document groups remain source-linked in the audit trail; this table only changes how the evidence is reviewed.</p>
      </div>
      <span className="rounded-full border border-emerald-200 bg-emerald-50 px-3 py-1 text-xs font-bold text-emerald-800">{rows.length} accepted</span>
    </div>

    {rows.length ? <div className="mt-4 grid gap-3 md:grid-cols-5">
      <SummaryCard label="Accepted documents" value={String(rows.length)} note="Grouped direct Sage purchase documents" />
      <SummaryCard label="Box 4 accepted" value={gbp(box4Accepted)} note="Signed accepted Box 4 effect" />
      <SummaryCard label="Box 7 accepted" value={gbp(box7Accepted)} note="Signed accepted Box 7 effect" />
      <SummaryCard label="All naturally covered by Sage" value="Yes" note="Accepted documents use Sage natural coverage" />
      <SummaryCard label="No Sage journals required" value="Yes" note="No adjustment journal for these accepted rows" />
    </div> : null}

    {rows.length ? <PurchaseVatSectionFilters rows={rows} filters={filters} setFilters={setFilters} sectionId="accepted-direct-sage" label="Filter accepted register" includeTaxProfile={false} includeLedger={false} statusForRow={statusForAcceptedRow} onChange={() => setVisibleCount(PAGE_SIZE)} /> : null}

    <div className="mt-4 overflow-x-auto">
      <table className="min-w-full divide-y divide-slate-200 text-left text-sm">
        <thead className="text-xs uppercase tracking-wide text-slate-500"><tr><th className="px-3 py-2">Document/ref</th><th className="px-3 py-2">Supplier/contact</th><th className="px-3 py-2">Document date</th><th className="px-3 py-2">Net</th><th className="px-3 py-2">VAT</th><th className="px-3 py-2">Gross</th><th className="px-3 py-2">Box 4 effect</th><th className="px-3 py-2">Box 7 effect</th><th className="px-3 py-2">Status</th></tr></thead>
        <tbody className="divide-y divide-slate-100">
          {visibleRows.length ? visibleRows.map((row, index) => <tr key={`${text(row.group_key) || text(row.document_label) || index}`}>
            <td className="whitespace-nowrap px-3 py-2 font-semibold text-slate-800">{cut(row.document_label, 42)}</td>
            <td className="whitespace-nowrap px-3 py-2 text-slate-700">{cut(row.supplier_contact, 34)}</td>
            <td className="whitespace-nowrap px-3 py-2 text-slate-700">{date(row.document_date)}</td>
            <td className="whitespace-nowrap px-3 py-2 font-semibold text-slate-700">{gbp(row.net_amount)}</td>
            <td className="whitespace-nowrap px-3 py-2 font-semibold text-slate-700">{gbp(row.vat_amount)}</td>
            <td className="whitespace-nowrap px-3 py-2 font-semibold text-slate-700">{gbp(row.gross_amount)}</td>
            <td className="whitespace-nowrap px-3 py-2 font-semibold text-slate-700">{gbp(row.effective_box4_amount)}</td>
            <td className="whitespace-nowrap px-3 py-2 font-semibold text-slate-700">{gbp(row.effective_box7_amount)}</td>
            <td className="min-w-56 px-3 py-2"><div className="flex flex-wrap gap-1.5"><Badge>Accepted</Badge><Badge tone="sky">Sage covered</Badge><Badge tone="slate">No journal</Badge></div></td>
          </tr>) : <tr><td className="px-3 py-5 text-sm text-slate-500" colSpan={9}>No accepted direct Sage purchase postings match the current filters.</td></tr>}
        </tbody>
      </table>
    </div>

    <ResultsPager shown={visibleRows.length} total={filteredRows.length} onShowMore={() => setVisibleCount((count) => count + PAGE_SIZE)} tone="emerald" />
  </section>;
}

export function PurchaseDocumentGroupsTable({ title, rows, empty, tone = "default", collapseWhenHigh = false }: ReviewTableProps) {
  const startsCollapsed = collapseWhenHigh && rows.length > 10;
  const [collapsed, setCollapsed] = useState(startsCollapsed);
  const [filters, setFilters] = useState<PurchaseVatFilters>(EMPTY_PURCHASE_VAT_FILTERS);
  const [visibleCount, setVisibleCount] = useState(PAGE_SIZE);
  const isReview = tone === "review";
  const isPlatform = tone === "platform";
  const statusForRow = isReview ? statusForReviewRow : isPlatform ? statusForPlatformRow : undefined;
  const filteredRows = useMemo(() => filterPurchaseVatRows(rows, filters, statusForRow), [rows, filters, statusForRow]);
  const visibleRows = filteredRows.slice(0, visibleCount);
  const shell = isReview ? "border-amber-300 bg-amber-50" : isPlatform ? "border-sky-200 bg-white" : "border-slate-200 bg-white";
  const badge = isReview ? "border-amber-300 bg-amber-100 text-amber-900" : "border-slate-200 bg-slate-50 text-slate-600";

  return <section className={`rounded-3xl border p-5 shadow-sm ${shell}`}>
    <div className="flex flex-wrap items-start justify-between gap-3">
      <div>
        <h2 className="text-lg font-semibold tracking-tight text-slate-950">{title}</h2>
        {isReview && rows.length ? <p className="mt-1 text-sm font-semibold text-amber-900">Review-required postings need investigation before VAT treatment is accepted.</p> : null}
        {isReview && !rows.length ? <p className="mt-1 text-sm font-semibold text-emerald-800">No review-required purchase postings in this snapshot.</p> : null}
        {isPlatform ? <p className="mt-1 text-sm font-semibold text-sky-900">{rows.length} platform-controlled document groups already covered by platform flow.</p> : null}
      </div>
      <div className="flex flex-wrap items-center gap-2">
        <span className={`rounded-full border px-3 py-1 text-xs font-bold ${badge}`}>{rows.length} document group(s)</span>
        {startsCollapsed ? <button type="button" onClick={() => setCollapsed((value) => !value)} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-xs font-bold text-slate-700 hover:bg-slate-50">{collapsed ? "Show platform-controlled evidence" : "Collapse platform-controlled evidence"}</button> : null}
      </div>
    </div>

    {collapsed ? <p className="mt-4 rounded-2xl border border-sky-200 bg-sky-50 p-4 text-sm font-semibold text-sky-900">{rows.length} platform-controlled document groups already covered by platform flow.</p> : <>
      {rows.length ? <PurchaseVatSectionFilters rows={rows} filters={filters} setFilters={setFilters} sectionId={title.replace(/\W+/g, "-").toLowerCase()} statusForRow={statusForRow} onChange={() => setVisibleCount(PAGE_SIZE)} /> : null}

      <div className="mt-4 overflow-x-auto">
        <table className="min-w-full divide-y divide-slate-200 text-left text-sm">
          <thead className="text-xs uppercase tracking-wide text-slate-500"><tr><th className="px-3 py-2">Document/ref</th><th className="px-3 py-2">Supplier/contact</th><th className="px-3 py-2">Document date</th><th className="px-3 py-2">Status</th><th className="px-3 py-2">Ledger summary</th><th className="px-3 py-2">Tax profile</th><th className="px-3 py-2">Classification</th><th className="px-3 py-2">Net</th><th className="px-3 py-2">VAT</th><th className="px-3 py-2">Gross</th><th className="px-3 py-2">Box 4 effect</th><th className="px-3 py-2">Box 7 effect</th><th className="px-3 py-2">Lines</th><th className="px-3 py-2">Reason summary</th><th className="px-3 py-2">Action/help text</th></tr></thead>
          <tbody className="divide-y divide-slate-100">
            {visibleRows.length ? visibleRows.map((row, index) => <tr key={`${text(row.group_key) || text(row.document_label) || index}`} className={isReview ? "bg-amber-50/70" : "bg-white"}>
              <td className="whitespace-nowrap px-3 py-2 font-semibold text-slate-800">{cut(row.document_label || row.sage_document_id, 36)}</td>
              <td className="whitespace-nowrap px-3 py-2 text-slate-700">{cut(row.supplier_contact, 34)}</td>
              <td className="whitespace-nowrap px-3 py-2 text-slate-700">{date(row.document_date)}</td>
              <td className="whitespace-nowrap px-3 py-2 text-slate-700">{cut(row.document_status, 24)}</td>
              <td className="whitespace-nowrap px-3 py-2 text-slate-700">{cut(row.ledger_summary, 34)}</td>
              <td className="whitespace-nowrap px-3 py-2 text-slate-700">{cut(row.tax_profile_summary, 28)}</td>
              <td className="whitespace-nowrap px-3 py-2 text-slate-700">{cut(row.classification_summary, 42)}</td>
              <td className="whitespace-nowrap px-3 py-2 font-semibold text-slate-700">{gbp(row.net_amount)}</td>
              <td className="whitespace-nowrap px-3 py-2 font-semibold text-slate-700">{gbp(row.vat_amount)}</td>
              <td className="whitespace-nowrap px-3 py-2 font-semibold text-slate-700">{gbp(row.gross_amount)}</td>
              <td className="whitespace-nowrap px-3 py-2 font-semibold text-slate-700">{gbp(row.effective_box4_amount)}</td>
              <td className="whitespace-nowrap px-3 py-2 font-semibold text-slate-700">{gbp(row.effective_box7_amount)}</td>
              <td className="whitespace-nowrap px-3 py-2 font-semibold text-slate-700">{num(row.line_count)}</td>
              <td className="min-w-48 px-3 py-2 text-slate-700">{cut(row.reason_summary, 70)}</td>
              <td className="min-w-44 px-3 py-2 text-slate-700">Copy ref / open Sage manually</td>
            </tr>) : <tr><td className="px-3 py-5 text-sm text-slate-500" colSpan={15}>{rows.length ? "No document groups match the current filters." : empty}</td></tr>}
          </tbody>
        </table>
      </div>

      <ResultsPager shown={visibleRows.length} total={filteredRows.length} onShowMore={() => setVisibleCount((count) => count + PAGE_SIZE)} />
    </>}
  </section>;
}
