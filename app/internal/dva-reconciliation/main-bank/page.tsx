import Link from "next/link";
import { createClient } from "@/utils/supabase/server";
import MainBankAllocationController from "./MainBankAllocationController";

type Row = Record<string, unknown>;
type SearchParamsValue = Record<string, string | string[] | undefined>;

const RESIDUAL_TYPES = ["fx_card_difference", "bank_fee", "unmatched_hold"];

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

export default async function MainBankShipperMatchingPage({
  searchParams,
}: {
  searchParams?: SearchParamsValue | Promise<SearchParamsValue>;
}) {
  const params = searchParams ? await Promise.resolve(searchParams) : {};
  const status = firstParam(params.status) || "unmatched";
  const targetStatus = firstParam(params.target_status) || "open";
  const q = firstParam(params.q);
  const success = firstParam(params.success);
  const error = firstParam(params.error);

  const supabase = await createClient();
  const [linesResult, targetsResult] = await Promise.all([
    (supabase as any).rpc("internal_main_bank_shipper_statement_lines_v1", {
      p_status: status,
      p_search: q || null,
      p_limit: 300,
      p_offset: 0,
    }),
    (supabase as any).rpc("internal_shipper_ap_posted_targets_for_main_bank_v1", {
      p_status: targetStatus,
      p_search: q || null,
      p_limit: 300,
      p_offset: 0,
    }),
  ]);

  const lines = (linesResult.data ?? []) as Row[];
  const targets = (targetsResult.data ?? []) as Row[];
  const lineIds = lines.map((line) => text(line.statement_line_id)).filter(Boolean);
  const residualsResult = lineIds.length
    ? await supabase
        .from("dva_statement_line_allocations")
        .select("dva_statement_line_id, allocation_type, allocated_gbp_amount")
        .eq("allocation_status", "confirmed")
        .in("allocation_type", RESIDUAL_TYPES)
        .in("dva_statement_line_id", lineIds)
    : { data: [], error: null };

  const residualRows = (residualsResult.data ?? []) as Row[];

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 lg:px-8">
      <div className="mx-auto max-w-7xl space-y-5">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href="/internal" className="text-sm font-semibold text-sky-700">← Back to internal dashboard</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Main bank allocation workspace</p>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight">Main bank → shipper AP allocation</h1>
          <p className="mt-3 max-w-5xl text-sm leading-6 text-slate-600">
            Separate branch for main company bank statement lines. It keeps the importer DVA/supplier/retailer workspace untouched, but uses the same practical pattern: pick bank line(s), pick targets, watch the floating balance bar, then confirm.
          </p>
          {success ? <p className="mt-4 rounded-2xl border border-emerald-200 bg-emerald-50 p-3 text-sm font-semibold text-emerald-900">{success}</p> : null}
          {error ? <p className="mt-4 rounded-2xl border border-rose-200 bg-rose-50 p-3 text-sm font-semibold text-rose-900">{error}</p> : null}
          {(linesResult.error || targetsResult.error || residualsResult.error) ? (
            <p className="mt-4 rounded-2xl border border-amber-200 bg-amber-50 p-3 text-sm font-semibold text-amber-900">
              Main-bank data unavailable: {linesResult.error?.message || targetsResult.error?.message || residualsResult.error?.message}
            </p>
          ) : null}
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
          <form action="/internal/dva-reconciliation/main-bank" className="grid gap-3 md:grid-cols-[1fr_180px_180px_auto] md:items-end">
            <label className="grid gap-1 text-xs font-bold uppercase tracking-wide text-slate-500">
              Search
              <input className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal normal-case tracking-normal text-slate-950" name="q" defaultValue={q} placeholder="Shipper, invoice ref, bank ref" />
            </label>
            <label className="grid gap-1 text-xs font-bold uppercase tracking-wide text-slate-500">
              Statement status
              <select className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal normal-case tracking-normal text-slate-950" name="status" defaultValue={status}>
                <option value="unmatched">Unmatched</option>
                <option value="part_allocated">Part allocated</option>
                <option value="balanced">Balanced</option>
                <option value="all">All</option>
              </select>
            </label>
            <label className="grid gap-1 text-xs font-bold uppercase tracking-wide text-slate-500">
              Shipper AP status
              <select className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal normal-case tracking-normal text-slate-950" name="target_status" defaultValue={targetStatus}>
                <option value="open">Open</option>
                <option value="allocated">Allocated</option>
                <option value="all">All</option>
              </select>
            </label>
            <button className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white" type="submit">Apply</button>
          </form>
        </section>

        <MainBankAllocationController lines={lines} targets={targets} residualRows={residualRows} />
      </div>
    </main>
  );
}
