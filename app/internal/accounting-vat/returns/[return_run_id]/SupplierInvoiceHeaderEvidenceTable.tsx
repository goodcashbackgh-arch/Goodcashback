"use client";

import { useMemo, useState } from "react";

type Row = Record<string, unknown>;

type Filters = {
  search: string;
  reviewStatus: string;
  ocrStatus: string;
  blocked: string;
  dateFrom: string;
  dateTo: string;
  amountMin: string;
  amountMax: string;
};

type Props = {
  rows: Row[];
  error: string | null;
  empty?: string;
};

const PAGE_SIZE = 50;
const EMPTY_FILTERS: Filters = { search: "", reviewStatus: "", ocrStatus: "", blocked: "", dateFrom: "", dateTo: "", amountMin: "", amountMax: "" };

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
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP", minimumFractionDigits: 2 }).format(num(value));
}

function date(value: unknown): string {
  const raw = text(value);
  if (!raw) return "—";
  const parsed = new Date(raw);
  if (Number.isNaN(parsed.getTime())) return raw;
  return new Intl.DateTimeFormat("en-GB", { day: "2-digit", month: "short", year: "numeric" }).format(parsed);
}

function isoDate(value: unknown): string {
  const raw = text(value);
  const iso = raw.match(/^\d{4}-\d{2}-\d{2}/)?.[0];
  if (iso) return iso;
  const parsed = raw ? new Date(raw) : null;
  return parsed && !Number.isNaN(parsed.getTime()) ? parsed.toISOString().slice(0, 10) : "";
}

function pretty(value: unknown): string {
  return text(value).replaceAll("_", " ") || "—";
}

function options(rows: Row[], getter: (row: Row) => unknown): string[] {
  return Array.from(new Set(rows.map(getter).map(text).filter(Boolean))).sort((a, b) => a.localeCompare(b));
}

function filterRows(rows: Row[], filters: Filters): Row[] {
  const needle = filters.search.trim().toLowerCase();
  const min = filters.amountMin ? Number(filters.amountMin) : null;
  const max = filters.amountMax ? Number(filters.amountMax) : null;
  return rows.filter((row) => {
    if (needle && ![row.invoice_ref, row.ocr_invoice_ref, row.ocr_invoice_date, row.ocr_invoice_total_gbp, row.review_status, row.mindee_ocr_status].map(text).join(" ").toLowerCase().includes(needle)) return false;
    if (filters.reviewStatus && text(row.review_status) !== filters.reviewStatus) return false;
    if (filters.ocrStatus && text(row.mindee_ocr_status) !== filters.ocrStatus) return false;
    if (filters.blocked === "yes" && !yes(row.blocked_from_sage_yn)) return false;
    if (filters.blocked === "no" && yes(row.blocked_from_sage_yn)) return false;
    const invoiceDate = isoDate(row.ocr_invoice_date || row.uploaded_at);
    if (filters.dateFrom && (!invoiceDate || invoiceDate < filters.dateFrom)) return false;
    if (filters.dateTo && (!invoiceDate || invoiceDate > filters.dateTo)) return false;
    const amount = num(row.ocr_invoice_total_gbp);
    if (min !== null && Number.isFinite(min) && amount < min) return false;
    if (max !== null && Number.isFinite(max) && amount > max) return false;
    return true;
  });
}

export function SupplierInvoiceHeaderEvidenceTable({ rows, error, empty = "No supplier invoice header evidence found." }: Props) {
  const [filters, setFilters] = useState<Filters>(EMPTY_FILTERS);
  const [visibleCount, setVisibleCount] = useState(PAGE_SIZE);
  const filteredRows = useMemo(() => filterRows(rows, filters), [rows, filters]);
  const visibleRows = filteredRows.slice(0, visibleCount);
  const reviewStatuses = options(rows, (row) => row.review_status);
  const ocrStatuses = options(rows, (row) => row.mindee_ocr_status);

  function update(key: keyof Filters, value: string) {
    setFilters((current) => ({ ...current, [key]: value }));
    setVisibleCount(PAGE_SIZE);
  }

  return <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
    <div className="flex flex-wrap items-start justify-between gap-3">
      <div>
        <h2 className="text-lg font-semibold tracking-tight">Supplier invoice header evidence</h2>
        {error ? <p className="mt-1 text-xs font-semibold text-rose-700">Read error: {error}</p> : null}
      </div>
      <span className="rounded-full border border-slate-200 bg-slate-50 px-3 py-1 text-xs font-bold text-slate-600">{rows.length} loaded</span>
    </div>

    {rows.length ? <div className="mt-4 rounded-2xl border border-slate-200 bg-slate-50 p-4">
      <p className="text-xs font-bold uppercase tracking-wide text-slate-500">Filter invoice headers</p>
      <div className="mt-3 grid gap-3 md:grid-cols-2 xl:grid-cols-4">
        <label className="text-xs font-semibold text-slate-600" htmlFor="supplier-header-search">Search ref
          <input id="supplier-header-search" value={filters.search} onChange={(event) => update("search", event.target.value)} placeholder="Invoice ref or OCR ref" className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal text-slate-950 outline-none focus:border-sky-400" />
        </label>
        {reviewStatuses.length ? <label className="text-xs font-semibold text-slate-600" htmlFor="supplier-header-review">Review status
          <select id="supplier-header-review" value={filters.reviewStatus} onChange={(event) => update("reviewStatus", event.target.value)} className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal text-slate-950 outline-none focus:border-sky-400"><option value="">All review statuses</option>{reviewStatuses.map((option) => <option key={option} value={option}>{pretty(option)}</option>)}</select>
        </label> : null}
        {ocrStatuses.length ? <label className="text-xs font-semibold text-slate-600" htmlFor="supplier-header-ocr">OCR status
          <select id="supplier-header-ocr" value={filters.ocrStatus} onChange={(event) => update("ocrStatus", event.target.value)} className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal text-slate-950 outline-none focus:border-sky-400"><option value="">All OCR statuses</option>{ocrStatuses.map((option) => <option key={option} value={option}>{pretty(option)}</option>)}</select>
        </label> : null}
        <label className="text-xs font-semibold text-slate-600" htmlFor="supplier-header-blocked">Blocked
          <select id="supplier-header-blocked" value={filters.blocked} onChange={(event) => update("blocked", event.target.value)} className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal text-slate-950 outline-none focus:border-sky-400"><option value="">Blocked yes/no</option><option value="yes">Blocked</option><option value="no">Not blocked</option></select>
        </label>
        <label className="text-xs font-semibold text-slate-600" htmlFor="supplier-header-from">Date from
          <input id="supplier-header-from" type="date" value={filters.dateFrom} onChange={(event) => update("dateFrom", event.target.value)} className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal text-slate-950 outline-none focus:border-sky-400" />
        </label>
        <label className="text-xs font-semibold text-slate-600" htmlFor="supplier-header-to">Date to
          <input id="supplier-header-to" type="date" value={filters.dateTo} onChange={(event) => update("dateTo", event.target.value)} className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal text-slate-950 outline-none focus:border-sky-400" />
        </label>
        <label className="text-xs font-semibold text-slate-600" htmlFor="supplier-header-min">Amount min
          <input id="supplier-header-min" type="number" step="0.01" value={filters.amountMin} onChange={(event) => update("amountMin", event.target.value)} className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal text-slate-950 outline-none focus:border-sky-400" />
        </label>
        <label className="text-xs font-semibold text-slate-600" htmlFor="supplier-header-max">Amount max
          <input id="supplier-header-max" type="number" step="0.01" value={filters.amountMax} onChange={(event) => update("amountMax", event.target.value)} className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal text-slate-950 outline-none focus:border-sky-400" />
        </label>
      </div>
    </div> : null}

    <div className="mt-4 overflow-x-auto">
      <table className="min-w-full divide-y divide-slate-200 text-left text-sm">
        <thead className="text-xs uppercase tracking-wide text-slate-500"><tr><th className="px-3 py-2">Invoice ref</th><th className="px-3 py-2">OCR ref</th><th className="px-3 py-2">OCR date</th><th className="px-3 py-2">OCR total</th><th className="px-3 py-2">Review</th><th className="px-3 py-2">Blocked</th><th className="px-3 py-2">OCR</th><th className="px-3 py-2">Uploaded</th></tr></thead>
        <tbody className="divide-y divide-slate-100">
          {visibleRows.length ? visibleRows.map((row, index) => <tr key={`${text(row.id) || index}`}>
            <td className="whitespace-nowrap px-3 py-2 text-slate-700">{text(row.invoice_ref) || "—"}</td>
            <td className="whitespace-nowrap px-3 py-2 text-slate-700">{text(row.ocr_invoice_ref) || "—"}</td>
            <td className="whitespace-nowrap px-3 py-2 text-slate-700">{date(row.ocr_invoice_date)}</td>
            <td className="whitespace-nowrap px-3 py-2 font-semibold text-slate-700">{gbp(row.ocr_invoice_total_gbp)}</td>
            <td className="whitespace-nowrap px-3 py-2 text-slate-700">{pretty(row.review_status)}</td>
            <td className="whitespace-nowrap px-3 py-2 text-slate-700">{yes(row.blocked_from_sage_yn) ? "Blocked" : "No"}</td>
            <td className="whitespace-nowrap px-3 py-2 text-slate-700">{pretty(row.mindee_ocr_status)}</td>
            <td className="whitespace-nowrap px-3 py-2 text-slate-700">{date(row.uploaded_at)}</td>
          </tr>) : <tr><td className="px-3 py-5 text-sm text-slate-500" colSpan={8}>{rows.length ? "No supplier invoice headers match the current filters." : empty}</td></tr>}
        </tbody>
      </table>
    </div>

    {filteredRows.length > PAGE_SIZE ? <div className="mt-4 flex flex-wrap items-center justify-between gap-3 rounded-2xl border border-slate-200 bg-slate-50 px-4 py-3"><p className="text-sm font-semibold text-slate-700">Showing {Math.min(visibleRows.length, filteredRows.length)} of {filteredRows.length}</p>{visibleRows.length < filteredRows.length ? <button type="button" onClick={() => setVisibleCount((count) => count + PAGE_SIZE)} className="rounded-xl border border-slate-300 bg-white px-4 py-2 text-sm font-bold text-slate-700 hover:bg-slate-50">Show more</button> : null}</div> : null}
  </section>;
}
