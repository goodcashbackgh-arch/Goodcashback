"use client";

import type { Dispatch, SetStateAction } from "react";

export type PurchaseVatFilters = {
  search: string;
  supplier: string;
  dateFrom: string;
  dateTo: string;
  taxProfile: string;
  ledger: string;
  status: string;
};

type Row = Record<string, unknown>;

type Props = {
  rows: Row[];
  filters: PurchaseVatFilters;
  setFilters: Dispatch<SetStateAction<PurchaseVatFilters>>;
  sectionId: string;
  label?: string;
  includeTaxProfile?: boolean;
  includeLedger?: boolean;
  includeStatus?: boolean;
  statusForRow?: (row: Row) => string[];
  onChange?: () => void;
};

export const EMPTY_PURCHASE_VAT_FILTERS: PurchaseVatFilters = {
  search: "",
  supplier: "",
  dateFrom: "",
  dateTo: "",
  taxProfile: "",
  ledger: "",
  status: "",
};

const TAX_PROFILE_OPTIONS = ["Standard 20%", "Zero/exempt/out-of-scope", "Mixed", "Review required", "Other/unknown"];

function text(value: unknown): string {
  if (typeof value === "string") return value.trim();
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  if (typeof value === "boolean") return value ? "true" : "false";
  return "";
}

function normalise(value: unknown): string {
  return text(value).toLowerCase().replace(/[\s_-]+/g, " ").trim();
}

function optionValues(rows: Row[], getter: (row: Row) => unknown): string[] {
  return Array.from(new Set(rows.map(getter).map(text).filter(Boolean))).sort((a, b) => a.localeCompare(b));
}

function rowDate(row: Row): string {
  const raw = text(row.document_date || row.tax_point_date || row.ocr_invoice_date || row.uploaded_at);
  const iso = raw.match(/^\d{4}-\d{2}-\d{2}/)?.[0];
  if (iso) return iso;
  const parsed = raw ? new Date(raw) : null;
  return parsed && !Number.isNaN(parsed.getTime()) ? parsed.toISOString().slice(0, 10) : "";
}

function rowTaxProfile(row: Row): string {
  const haystack = normalise([row.tax_profile_summary, row.tax_rate_name, row.classification_summary, row.reason_summary].map(text).join(" "));
  if (haystack.includes("review")) return "Review required";
  if (haystack.includes("mixed")) return "Mixed";
  if (haystack.includes("20") || haystack.includes("standard")) return "Standard 20%";
  if (haystack.includes("zero") || haystack.includes("exempt") || haystack.includes("out of scope") || haystack.includes("outside scope")) return "Zero/exempt/out-of-scope";
  return "Other/unknown";
}

function defaultStatusForRow(row: Row): string[] {
  const haystack = normalise([row.status_control_result, row.classification_summary, row.reason_summary, row.document_status].map(text).join(" "));
  const values: string[] = [];
  if (haystack.includes("accepted")) values.push("Accepted");
  if (haystack.includes("sage covered") || haystack.includes("naturally covered")) values.push("Sage covered");
  if (haystack.includes("no journal") || haystack.includes("no adjustment journal")) values.push("No journal");
  if (haystack.includes("platform controlled") || haystack.includes("already covered by platform")) values.push("Already platform-controlled");
  if (haystack.includes("review")) values.push("Needs review");
  if (haystack.includes("direct") && haystack.includes("unresolved")) values.push("Direct unresolved");
  return values;
}

function searchHaystack(row: Row, extraStatuses: string[]): string {
  return [
    row.document_label,
    row.source_ref,
    row.invoice_ref,
    row.ocr_invoice_ref,
    row.sage_document_id,
    row.supplier_contact,
    row.contact_name,
    row.document_date,
    row.tax_point_date,
    row.ocr_invoice_date,
    row.net_amount,
    row.vat_amount,
    row.gross_amount,
    row.effective_box4_amount,
    row.effective_box7_amount,
    row.ocr_invoice_total_gbp,
    row.ledger_summary,
    row.category_summary,
    row.tax_profile_summary,
    row.classification_summary,
    row.reason_summary,
    row.document_status,
    row.status_control_result,
    ...extraStatuses,
  ].map(text).join(" ").toLowerCase();
}

export function filterPurchaseVatRows(rows: Row[], filters: PurchaseVatFilters, statusForRow: (row: Row) => string[] = defaultStatusForRow): Row[] {
  const needle = filters.search.trim().toLowerCase();
  return rows.filter((row) => {
    const statuses = statusForRow(row);
    if (needle && !searchHaystack(row, statuses).includes(needle)) return false;
    if (filters.supplier && text(row.supplier_contact || row.contact_name) !== filters.supplier) return false;
    const dateValue = rowDate(row);
    if (filters.dateFrom && (!dateValue || dateValue < filters.dateFrom)) return false;
    if (filters.dateTo && (!dateValue || dateValue > filters.dateTo)) return false;
    if (filters.taxProfile && rowTaxProfile(row) !== filters.taxProfile) return false;
    if (filters.ledger && text(row.ledger_summary || row.category_summary) !== filters.ledger) return false;
    if (filters.status && !statuses.includes(filters.status)) return false;
    return true;
  });
}

export function PurchaseVatSectionFilters({ rows, filters, setFilters, sectionId, label = "Filter document groups", includeTaxProfile = true, includeLedger = true, includeStatus = true, statusForRow = defaultStatusForRow, onChange }: Props) {
  const suppliers = optionValues(rows, (row) => row.supplier_contact || row.contact_name);
  const ledgers = optionValues(rows, (row) => row.ledger_summary || row.category_summary);
  const statuses = Array.from(new Set(rows.flatMap(statusForRow).filter(Boolean))).sort((a, b) => a.localeCompare(b));
  const taxProfiles = TAX_PROFILE_OPTIONS.filter((option) => rows.some((row) => rowTaxProfile(row) === option));

  function update(key: keyof PurchaseVatFilters, value: string) {
    setFilters((current) => ({ ...current, [key]: value }));
    onChange?.();
  }

  return <div className="mt-4 rounded-2xl border border-slate-200 bg-slate-50 p-4">
    <p className="text-xs font-bold uppercase tracking-wide text-slate-500">{label}</p>
    <div className="mt-3 grid gap-3 md:grid-cols-2 xl:grid-cols-4">
      <label className="text-xs font-semibold text-slate-600" htmlFor={`${sectionId}-search`}>Search
        <input id={`${sectionId}-search`} value={filters.search} onChange={(event) => update("search", event.target.value)} placeholder="Supplier, ref, Sage id, date, amount, ledger" className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal text-slate-950 outline-none focus:border-sky-400" />
      </label>
      {suppliers.length ? <label className="text-xs font-semibold text-slate-600" htmlFor={`${sectionId}-supplier`}>Supplier/contact
        <select id={`${sectionId}-supplier`} value={filters.supplier} onChange={(event) => update("supplier", event.target.value)} className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal text-slate-950 outline-none focus:border-sky-400"><option value="">All suppliers</option>{suppliers.map((option) => <option key={option} value={option}>{option}</option>)}</select>
      </label> : null}
      <label className="text-xs font-semibold text-slate-600" htmlFor={`${sectionId}-from`}>Date from
        <input id={`${sectionId}-from`} type="date" value={filters.dateFrom} onChange={(event) => update("dateFrom", event.target.value)} className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal text-slate-950 outline-none focus:border-sky-400" />
      </label>
      <label className="text-xs font-semibold text-slate-600" htmlFor={`${sectionId}-to`}>Date to
        <input id={`${sectionId}-to`} type="date" value={filters.dateTo} onChange={(event) => update("dateTo", event.target.value)} className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal text-slate-950 outline-none focus:border-sky-400" />
      </label>
      {includeTaxProfile && taxProfiles.length ? <label className="text-xs font-semibold text-slate-600" htmlFor={`${sectionId}-tax`}>Tax profile
        <select id={`${sectionId}-tax`} value={filters.taxProfile} onChange={(event) => update("taxProfile", event.target.value)} className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal text-slate-950 outline-none focus:border-sky-400"><option value="">All tax profiles</option>{taxProfiles.map((option) => <option key={option} value={option}>{option}</option>)}</select>
      </label> : null}
      {includeLedger && ledgers.length ? <label className="text-xs font-semibold text-slate-600" htmlFor={`${sectionId}-ledger`}>Ledger/category
        <select id={`${sectionId}-ledger`} value={filters.ledger} onChange={(event) => update("ledger", event.target.value)} className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal text-slate-950 outline-none focus:border-sky-400"><option value="">All ledgers/categories</option>{ledgers.map((option) => <option key={option} value={option}>{option}</option>)}</select>
      </label> : null}
      {includeStatus && statuses.length ? <label className="text-xs font-semibold text-slate-600" htmlFor={`${sectionId}-status`}>Status/control result
        <select id={`${sectionId}-status`} value={filters.status} onChange={(event) => update("status", event.target.value)} className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal text-slate-950 outline-none focus:border-sky-400"><option value="">All statuses</option>{statuses.map((option) => <option key={option} value={option}>{option}</option>)}</select>
      </label> : null}
    </div>
  </div>;
}
