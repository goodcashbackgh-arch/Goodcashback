import Link from "next/link";
import { createClient } from "@/utils/supabase/server";
import { generateSupplierInvoiceSuggestionsAction } from "../actions";

type Row = Record<string, unknown>;
type SearchParamsValue = Record<string, string | string[] | undefined>;

const gbpFormatter = new Intl.NumberFormat("en-GB", {
  style: "currency",
  currency: "GBP",
  minimumFractionDigits: 2,
});

const suggestionPresets = [
  { label: "Tight", hint: "£5 · 14 days", tolerance: "5", days: "14" },
  { label: "Normal", hint: "£20 · 21 days", tolerance: "20", days: "21" },
  { label: "Broad FX", hint: "£50 · 45 days", tolerance: "50", days: "45" },
];

function text(value: unknown) {
  if (Array.isArray(value)) return text(value[0]);
  return typeof value === "string" ? value : "";
}

function num(value: unknown) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

function gbp(value: unknown) {
  return gbpFormatter.format(num(value));
}

function SuggestionPresetForms({ row }: { row: Row }) {
  return (
    <div className="mt-5 rounded-2xl border border-sky-100 bg-sky-50 p-4">
      <p className="text-xs font-semibold uppercase tracking-wide text-sky-900">Generate supplier-invoice suggestions</p>
      <p className="mt-1 text-xs leading-5 text-sky-900">
        Start broad when FX/card conversion makes exact GBP matching unrealistic. This only suggests; it does not allocate.
      </p>
      <div className="mt-3 grid gap-2 sm:grid-cols-3">
        {suggestionPresets.map((preset) => (
          <form key={preset.label} action={generateSupplierInvoiceSuggestionsAction}>
            <input type="hidden" name="return_path" value="/internal/dva-reconciliation/unmatched" />
            <input type="hidden" name="dva_statement_line_id" value={text(row.dva_statement_line_id)} />
            <input type="hidden" name="tolerance_gbp" value={preset.tolerance} />
            <input type="hidden" name="max_days" value={preset.days} />
            <button className="w-full rounded-xl bg-white px-3 py-2 text-left text-sm font-semibold text-sky-800 ring-1 ring-sky-200" type="submit">
              {preset.label}
              <span className="block text-xs font-normal text-sky-700">{preset.hint}</span>
            </button>
          </form>
        ))}
      </div>
    </div>
  );
}

export default async function DvaUnmatchedStatementActionPage({
  searchParams,
}: {
  searchParams?: SearchParamsValue | Promise<SearchParamsValue>;
}) {
  const params = searchParams ? await Promise.resolve(searchParams) : {};
  const allocationSuccess = text(params.allocation_success);
  const allocationError = text(params.allocation_error);
  const supabase = await createClient();

  const { data, error } = await supabase
    .from("dva_statement_line_allocation_summary_vw")
    .select("dva_statement_line_id, importer_id, statement_date, reference_raw, direction, amount_local_ccy, local_ccy, statement_gbp_amount, auth_id_ref, retailer_name_ref, match_status, confirmed_allocated_gbp, confirmed_unallocated_gbp, confirmed_balanced_yn")
    .eq("direction", "out")
    .eq("confirmed_balanced_yn", false)
    .eq("confirmed_allocated_gbp", 0)
    .order("statement_date", { ascending: false })
    .limit(50);

  const rows = (data ?? []) as unknown as Row[];

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-5xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href="/internal/dva-reconciliation" className="text-sm font-semibold text-sky-600">← Back to DVA reconciliation</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">DVA/card unmatched controls</p>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight">Unmatched OUT statement lines</h1>
          <p className="mt-3 max-w-3xl text-sm leading-6 text-slate-600">
            These are active card/payment outflows with no confirmed primary allocation. Do not classify them as FX/card residuals. First generate supplier-invoice suggestions, manually investigate, hold/query, or void the import if it is test/wrong data.
          </p>
        </section>

        {allocationSuccess ? (
          <section className="rounded-3xl border border-emerald-200 bg-emerald-50 p-5 text-sm font-semibold text-emerald-800">{allocationSuccess}</section>
        ) : null}
        {allocationError ? (
          <section className="rounded-3xl border border-rose-200 bg-rose-50 p-5 text-sm font-semibold text-rose-900">{allocationError}</section>
        ) : null}
        {error ? (
          <section className="rounded-3xl border border-rose-200 bg-rose-50 p-5 text-sm text-rose-900">Could not read unmatched statement lines: {error.message}</section>
        ) : null}

        <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm leading-6 text-amber-950">
          <h2 className="font-semibold">Correct handling</h2>
          <p className="mt-2">Use this page for first-line triage. If the line is a supplier purchase, generate a supplier-invoice suggestion. If no suggestion appears, investigate merchant/date/amount or wait for manual-link/hold actions. FX/card/fee is only for the remaining balance after the primary allocation exists.</p>
        </section>

        <section className="space-y-4">
          {rows.length === 0 ? (
            <div className="rounded-3xl border border-slate-200 bg-white p-6 text-sm text-slate-600 shadow-sm">No unmatched OUT statement lines are visible.</div>
          ) : rows.map((row) => (
            <article key={text(row.dva_statement_line_id)} className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
              <div className="flex flex-wrap items-start justify-between gap-3">
                <div>
                  <p className="text-sm font-semibold text-slate-500">{text(row.statement_date)} · OUT</p>
                  <h2 className="mt-1 text-2xl font-semibold">{gbp(row.statement_gbp_amount)}</h2>
                </div>
                <span className="rounded-full bg-amber-50 px-3 py-1 text-xs font-semibold text-amber-700 ring-1 ring-amber-200">needs primary match</span>
              </div>

              <div className="mt-4 grid gap-3 text-sm text-slate-700 sm:grid-cols-2">
                <p><span className="font-semibold text-slate-500">Reference:</span> {text(row.reference_raw) || "—"}</p>
                <p><span className="font-semibold text-slate-500">Merchant/card ref:</span> {text(row.retailer_name_ref) || "—"}</p>
                <p><span className="font-semibold text-slate-500">Auth/ref:</span> {text(row.auth_id_ref) || "—"}</p>
                <p><span className="font-semibold text-slate-500">Local:</span> {num(row.amount_local_ccy).toLocaleString("en-GB")} {text(row.local_ccy)}</p>
                <p><span className="font-semibold text-slate-500">Current match status:</span> {text(row.match_status) || "—"}</p>
                <p><span className="font-semibold text-slate-500">Remaining:</span> {gbp(row.confirmed_unallocated_gbp)}</p>
              </div>

              <SuggestionPresetForms row={row} />

              <div className="mt-4 grid gap-2 text-sm text-slate-500 sm:grid-cols-3">
                <div className="rounded-2xl bg-slate-50 p-3">Manual supplier invoice search/link: next build.</div>
                <div className="rounded-2xl bg-slate-50 p-3">Hold/query/exception route: next build.</div>
                <div className="rounded-2xl bg-slate-50 p-3">Void import: use import history until UI action is added.</div>
              </div>
            </article>
          ))}
        </section>
      </div>
    </main>
  );
}
