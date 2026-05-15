import Link from "next/link";
import { upsertFxRateAction } from "./actions";
import { createClient } from "@/utils/supabase/server";

type SearchParamsValue = Record<string, string | string[] | undefined>;
type Row = Record<string, unknown>;

type CountryRow = {
  id: string;
  name: string;
  iso_code: string;
  active: boolean;
};

function text(value: unknown) {
  if (Array.isArray(value)) return text(value[0]);
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return "";
}

function firstParam(value: unknown) {
  if (Array.isArray(value)) return text(value[0]);
  return text(value);
}

function num(value: unknown) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

function todayIso() {
  return new Date().toISOString().slice(0, 10);
}

function dateRange(from: string, to: string) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(from) || !/^\d{4}-\d{2}-\d{2}$/.test(to)) return [];
  const start = new Date(`${from}T00:00:00.000Z`);
  const end = new Date(`${to}T00:00:00.000Z`);
  if (Number.isNaN(start.getTime()) || Number.isNaN(end.getTime()) || start > end) return [];

  const days: string[] = [];
  const cursor = new Date(start);
  while (cursor <= end && days.length < 45) {
    days.push(cursor.toISOString().slice(0, 10));
    cursor.setUTCDate(cursor.getUTCDate() + 1);
  }
  return days;
}

function formatNumber(value: unknown) {
  const n = num(value);
  return Number.isFinite(n) ? n.toLocaleString("en-GB", { maximumFractionDigits: 6 }) : "—";
}

export default async function FxRatesPage({ searchParams }: { searchParams?: SearchParamsValue | Promise<SearchParamsValue> }) {
  const params = searchParams ? await Promise.resolve(searchParams) : {};
  const selectedCountryId = firstParam(params.country_id);
  const from = firstParam(params.from) || todayIso();
  const to = firstParam(params.to) || from;
  const success = firstParam(params.fx_success);
  const error = firstParam(params.fx_error);

  const supabase = await createClient();

  const { data: countriesData, error: countriesError } = await supabase
    .from("countries")
    .select("id, name, iso_code, active")
    .order("name", { ascending: true });

  const countries = ((countriesData ?? []) as unknown as CountryRow[]).filter((country) => country.active !== false);
  const defaultCountryId = selectedCountryId || countries[0]?.id || "";
  const selectedCountry = countries.find((country) => country.id === defaultCountryId);

  const rateQuery = supabase
    .from("fx_rates")
    .select("id, country_id, rate_date, quote_rate, quote_card_markup_pct, settlement_rate, settlement_card_markup_pct, entered_by_staff_id, created_at")
    .order("rate_date", { ascending: false })
    .limit(120);

  if (defaultCountryId) rateQuery.eq("country_id", defaultCountryId);

  const { data: ratesData, error: ratesError } = await rateQuery;
  const rates = (ratesData ?? []) as Row[];
  const ratesByDate = new Set(rates.map((rate) => text(rate.rate_date)));
  const missingDates = defaultCountryId ? dateRange(from, to).filter((day) => !ratesByDate.has(day)) : [];

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 lg:px-8">
      <div className="mx-auto max-w-7xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href="/internal" className="text-sm font-semibold text-sky-600">← Back to internal dashboard</Link>
          <p className="mt-6 text-sm font-bold uppercase tracking-[0.25em] text-sky-600">FX control</p>
          <h1 className="mt-2 text-3xl font-bold tracking-tight">Daily FX rates</h1>
          <p className="mt-3 max-w-4xl text-sm leading-6 text-slate-600">
            Maintain the daily quote and settlement controls used by customer quotes and DVA/card statement extraction. All four daily fields are required; enter 0 for markup where no spread applies. This page reads the existing fx_rates table and saves through a staff-only RPC, not direct table writes.
          </p>
          <div className="mt-4 flex flex-wrap gap-2">
            <Link href="/internal/dva-statement-import" className="rounded-xl border border-slate-200 bg-white px-4 py-2 text-sm font-semibold text-slate-700">Statement import</Link>
            <Link href="/internal/status-control/pre-sage-financial-readiness" className="rounded-xl border border-slate-200 bg-white px-4 py-2 text-sm font-semibold text-slate-700">Pre-Sage control pack</Link>
          </div>
        </section>

        {success ? <section className="rounded-2xl border border-emerald-200 bg-emerald-50 p-4 text-sm font-semibold text-emerald-900">{success}</section> : null}
        {error ? <section className="rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-semibold text-rose-900">{error}</section> : null}
        {countriesError ? <section className="rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-semibold text-rose-900">Countries: {countriesError.message}</section> : null}
        {ratesError ? <section className="rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-semibold text-rose-900">FX rates: {ratesError.message}</section> : null}

        <section className="grid gap-4 lg:grid-cols-[1fr_1.2fr]">
          <div className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
            <h2 className="text-xl font-bold">Add or update one day</h2>
            <p className="mt-2 text-sm leading-6 text-slate-600">One country/date can have only one FX rate. Saving the same country/date updates the existing row. Markups are explicit controls: enter 0 if none applies.</p>
            <form action={upsertFxRateAction} className="mt-5 grid gap-4">
              <input type="hidden" name="from" value={from} />
              <input type="hidden" name="to" value={to} />
              <label className="grid gap-1 text-sm font-semibold text-slate-700">
                Country
                <select name="country_id" defaultValue={defaultCountryId} className="rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm text-slate-900" required>
                  {countries.map((country) => (
                    <option key={country.id} value={country.id}>{country.name} ({country.iso_code})</option>
                  ))}
                </select>
              </label>
              <label className="grid gap-1 text-sm font-semibold text-slate-700">
                Rate date
                <input name="rate_date" type="date" defaultValue={from} className="rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm" required />
              </label>
              <div className="grid gap-4 sm:grid-cols-2">
                <label className="grid gap-1 text-sm font-semibold text-slate-700">
                  Quote rate
                  <input name="quote_rate" type="number" step="0.000001" min="0.000001" className="rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm" required />
                  <span className="text-xs font-normal text-slate-500">Base quote rate before quote markup.</span>
                </label>
                <label className="grid gap-1 text-sm font-semibold text-slate-700">
                  Quote card markup %
                  <input name="quote_card_markup_pct" type="number" step="0.0001" min="0" defaultValue="0" className="rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm" required />
                  <span className="text-xs font-normal text-slate-500">Required. Enter 0 if no quote spread applies.</span>
                </label>
              </div>
              <div className="grid gap-4 sm:grid-cols-2">
                <label className="grid gap-1 text-sm font-semibold text-slate-700">
                  Settlement/base rate
                  <input name="settlement_rate" type="number" step="0.000001" min="0.000001" className="rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm" required />
                  <span className="text-xs font-normal text-slate-500">Used for statement GBP total: local amount ÷ settlement/base rate.</span>
                </label>
                <label className="grid gap-1 text-sm font-semibold text-slate-700">
                  Settlement card markup %
                  <input name="settlement_card_markup_pct" type="number" step="0.0001" min="0" defaultValue="0" className="rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm" required />
                  <span className="text-xs font-normal text-slate-500">Required. Used to calculate the FX/card residual audit split. Enter 0 if none applies.</span>
                </label>
              </div>
              <button type="submit" className="rounded-xl bg-slate-950 px-4 py-3 text-sm font-bold text-white">Save FX rate</button>
            </form>
          </div>

          <div className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
            <h2 className="text-xl font-bold">Missing daily rates</h2>
            <p className="mt-2 text-sm leading-6 text-slate-600">Check the dates needed before extracting a statement. The check is capped at 45 days to prevent accidental huge ranges.</p>
            <form className="mt-5 grid gap-3 sm:grid-cols-[1fr_auto_auto_auto] sm:items-end" action="/internal/fx-rates">
              <label className="grid gap-1 text-xs font-semibold text-slate-600">
                Country
                <select name="country_id" defaultValue={defaultCountryId} className="rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm">
                  {countries.map((country) => (
                    <option key={country.id} value={country.id}>{country.name} ({country.iso_code})</option>
                  ))}
                </select>
              </label>
              <label className="grid gap-1 text-xs font-semibold text-slate-600">
                From
                <input name="from" type="date" defaultValue={from} className="rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm" />
              </label>
              <label className="grid gap-1 text-xs font-semibold text-slate-600">
                To
                <input name="to" type="date" defaultValue={to} className="rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm" />
              </label>
              <button className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white" type="submit">Check</button>
            </form>
            <div className="mt-5 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-700">
              <p className="font-bold">{selectedCountry ? `${selectedCountry.name} (${selectedCountry.iso_code})` : "No country selected"}</p>
              {missingDates.length === 0 ? (
                <p className="mt-2 text-emerald-700">No missing dates found for this selected range.</p>
              ) : (
                <div className="mt-2">
                  <p className="font-semibold text-amber-800">Missing {missingDates.length} date(s):</p>
                  <div className="mt-2 flex flex-wrap gap-2">
                    {missingDates.map((day) => <span key={day} className="rounded-full bg-white px-3 py-1 text-xs font-semibold text-slate-700 ring-1 ring-slate-200">{day}</span>)}
                  </div>
                </div>
              )}
            </div>
          </div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div>
              <h2 className="text-xl font-bold">Latest rates</h2>
              <p className="mt-2 text-sm leading-6 text-slate-600">Statement GBP total uses the settlement/base rate. Settlement markup is retained for the FX/card residual audit split.</p>
            </div>
            <span className="rounded-full bg-slate-100 px-3 py-1 text-sm font-semibold text-slate-700 ring-1 ring-slate-200">{rates.length} row(s)</span>
          </div>
          <div className="mt-5 overflow-x-auto">
            <table className="min-w-full text-left text-sm">
              <thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500">
                <tr>
                  <th className="px-3 py-2">Date</th>
                  <th className="px-3 py-2">Quote rate</th>
                  <th className="px-3 py-2">Quote markup %</th>
                  <th className="px-3 py-2">Settlement/base rate</th>
                  <th className="px-3 py-2">Settlement markup %</th>
                  <th className="px-3 py-2">Entered by</th>
                </tr>
              </thead>
              <tbody>
                {rates.length === 0 ? (
                  <tr><td colSpan={6} className="px-3 py-6 text-center text-slate-500">No rates found.</td></tr>
                ) : rates.map((rate) => (
                  <tr key={text(rate.id)} className="border-t border-slate-100">
                    <td className="px-3 py-2 font-semibold text-slate-950">{text(rate.rate_date)}</td>
                    <td className="px-3 py-2">{formatNumber(rate.quote_rate)}</td>
                    <td className="px-3 py-2">{formatNumber(rate.quote_card_markup_pct)}</td>
                    <td className="px-3 py-2 font-semibold">{formatNumber(rate.settlement_rate)}</td>
                    <td className="px-3 py-2">{formatNumber(rate.settlement_card_markup_pct)}</td>
                    <td className="px-3 py-2 text-xs text-slate-500">{text(rate.entered_by_staff_id) || "—"}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>
      </div>
    </main>
  );
}
