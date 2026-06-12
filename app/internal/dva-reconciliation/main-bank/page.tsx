import Link from "next/link";
import { createClient } from "@/utils/supabase/server";
import { cleanUiText } from "@/lib/ui/cleanUiText";
import MainBankAllocationController from "./MainBankAllocationController";

type Row = Record<string, unknown>;
type SearchParamsValue = Record<string, string | string[] | undefined>;
type TargetMode = "shipper_ap" | "completion_loyalty";

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

function targetHref(target: TargetMode, q: string) {
  const params = new URLSearchParams();
  params.set("target", target);
  if (q) params.set("q", q);
  return `/internal/dva-reconciliation/main-bank?${params.toString()}`;
}

function modeClass(active: boolean) {
  return active
    ? "border-sky-300 bg-sky-50 text-sky-950 ring-2 ring-sky-100"
    : "border-slate-200 bg-white text-slate-700 hover:border-sky-200 hover:bg-sky-50";
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
  const targetParam = firstParam(params.target);
  const targetMode: TargetMode = targetParam === "completion_loyalty" ? "completion_loyalty" : "shipper_ap";
  const success = cleanUiText(firstParam(params.success));
  const error = cleanUiText(firstParam(params.error));

  const supabase = await createClient();
  const linesResult = await (supabase as any).rpc("internal_main_bank_shipper_statement_lines_v1", {
    p_status: status,
    p_search: q || null,
    p_limit: 300,
    p_offset: 0,
  });

  const targetsResult = targetMode === "shipper_ap"
    ? await (supabase as any).rpc("internal_shipper_ap_posted_targets_for_main_bank_v1", {
        p_status: targetStatus,
        p_search: null,
        p_limit: 300,
        p_offset: 0,
      })
    : { data: [], error: null };

  const loyaltyTargetsResult = targetMode === "completion_loyalty"
    ? await (supabase as any).rpc("internal_main_bank_completion_loyalty_targets_v1", {
        p_search: null,
        p_limit: 300,
        p_offset: 0,
      })
    : { data: [], error: null };

  const lines = (linesResult.data ?? []) as Row[];
  const targets = (targetsResult.data ?? []) as Row[];
  const loyaltyTargets = (loyaltyTargetsResult.data ?? []) as Row[];
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
  const dataError = linesResult.error || targetsResult.error || loyaltyTargetsResult.error || residualsResult.error;

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 lg:px-8">
      <div className="mx-auto max-w-7xl space-y-5">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href="/internal" className="text-sm font-semibold text-sky-700">← Back to internal dashboard</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Main bank matching workspace</p>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight">Main bank matching</h1>
          <p className="mt-3 max-w-5xl text-sm leading-6 text-slate-600">
            Shared main-company bank workspace. Shipper charge matching remains the default lane. Completion loyalty uses the same bank lines but a separate target mode, so the same bank amount cannot be reused twice.
          </p>
          {success ? <p className="mt-4 rounded-2xl border border-emerald-200 bg-emerald-50 p-3 text-sm font-semibold text-emerald-900">{success}</p> : null}
          {error ? <p className="mt-4 rounded-2xl border border-rose-200 bg-rose-50 p-3 text-sm font-semibold text-rose-900">{error}</p> : null}
          {dataError ? (
            <p className="mt-4 rounded-2xl border border-amber-200 bg-amber-50 p-3 text-sm font-semibold text-amber-900">
              Main-bank data unavailable: {cleanUiText(linesResult.error?.message || targetsResult.error?.message || loyaltyTargetsResult.error?.message || residualsResult.error?.message)}
            </p>
          ) : null}
        </section>

        <section className="grid gap-3 md:grid-cols-2">
          <Link href={targetHref("shipper_ap", q)} className={`rounded-2xl border p-4 text-sm font-semibold shadow-sm ${modeClass(targetMode === "shipper_ap")}`}>
            <span className="block text-xs uppercase tracking-wide opacity-70">Target mode</span>
            <span className="mt-1 block text-lg font-extrabold">Shipper charge records</span>
            <span className="mt-1 block font-normal opacity-80">Match main-bank OUT lines to approved shipper charge records.</span>
          </Link>
          <Link href={targetHref("completion_loyalty", q)} className={`rounded-2xl border p-4 text-sm font-semibold shadow-sm ${modeClass(targetMode === "completion_loyalty")}`}>
            <span className="block text-xs uppercase tracking-wide opacity-70">Target mode</span>
            <span className="mt-1 block text-lg font-extrabold">Completion loyalty</span>
            <span className="mt-1 block font-normal opacity-80">Match main-bank payment proof to clean completed reward targets and release dashboard credit.</span>
          </Link>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
          <form action="/internal/dva-reconciliation/main-bank" className="grid gap-3 md:grid-cols-[1fr_180px_180px_auto] md:items-end">
            <input type="hidden" name="target" value={targetMode} />
            <label className="grid gap-1 text-xs font-bold uppercase tracking-wide text-slate-500">
              Search bank lines
              <input className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal normal-case tracking-normal text-slate-950" name="q" defaultValue={q} placeholder="Bank ref, date, amount, source bank" />
            </label>
            <label className="grid gap-1 text-xs font-bold uppercase tracking-wide text-slate-500">
              Statement status
              <select className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal normal-case tracking-normal text-slate-950" name="status" defaultValue={status}>
                <option value="unmatched">Unmatched</option>
                <option value="part_allocated">Part matched</option>
                <option value="balanced">Balanced</option>
                <option value="all">All</option>
              </select>
            </label>
            {targetMode === "shipper_ap" ? (
              <label className="grid gap-1 text-xs font-bold uppercase tracking-wide text-slate-500">
                Shipper charge status
                <select className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal normal-case tracking-normal text-slate-950" name="target_status" defaultValue={targetStatus}>
                  <option value="open">Open</option>
                  <option value="allocated">Matched</option>
                  <option value="all">All</option>
                </select>
              </label>
            ) : (
              <div className="rounded-xl border border-sky-200 bg-sky-50 px-3 py-2 text-xs font-semibold leading-5 text-sky-950">
                Loyalty target list shows clean completed reward proposals only.
              </div>
            )}
            <button className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white" type="submit">Apply</button>
          </form>
        </section>

        <MainBankAllocationController
          lines={lines}
          targets={targets}
          loyaltyTargets={loyaltyTargets}
          residualRows={residualRows}
          targetMode={targetMode}
        />
      </div>
    </main>
  );
}
