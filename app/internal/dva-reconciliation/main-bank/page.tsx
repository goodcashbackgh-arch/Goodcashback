import Link from "next/link";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { cleanUiText } from "@/lib/ui/cleanUiText";
import MainBankAllocationController from "./MainBankAllocationController";

type Row = Record<string, unknown>;
type SearchParamsValue = Record<string, string | string[] | undefined>;
type TargetMode = "shipper_ap" | "completion_loyalty";

const RESIDUAL_TYPES = ["fx_card_difference", "bank_fee", "unmatched_hold"];
const gbpFormatter = new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" });

function text(value: unknown) {
  if (Array.isArray(value)) return text(value[0]);
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return "";
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

function short(value: unknown, max = 72) {
  const raw = cleanUiText(text(value));
  if (!raw) return "—";
  return raw.length > max ? `${raw.slice(0, max - 1)}…` : raw;
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

async function releaseReservedLoyaltyTopUpAction(formData: FormData) {
  "use server";

  const loyaltyMatchId = firstParam(formData.get("loyalty_match_id"));
  const topUpLineId = firstParam(formData.get("top_up_statement_line_id"));

  if (!loyaltyMatchId || !topUpLineId) {
    const params = new URLSearchParams({ target: "completion_loyalty", error: "Select one reserved loyalty OUT match and one DVA/card top-up IN line." });
    redirect(`/internal/dva-reconciliation/main-bank?${params.toString()}`);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("staff_pair_loyalty_destination_in_and_release_v1", {
    p_loyalty_match_id: loyaltyMatchId,
    p_destination_in_statement_line_id: topUpLineId,
    p_notes: "DVA/card top-up IN paired and completion loyalty released.",
  });

  if (error) {
    const params = new URLSearchParams({ target: "completion_loyalty", error: error.message });
    redirect(`/internal/dva-reconciliation/main-bank?${params.toString()}`);
  }

  const result = (data ?? {}) as Row;
  const amount = gbp(result.matched_gbp_amount);

  revalidatePath("/internal/dva-reconciliation/main-bank");
  revalidatePath("/internal/completion-loyalty-rewards");
  revalidatePath("/internal/accounting-command-centre/cash-posting");
  revalidatePath("/customer");

  const params = new URLSearchParams({ target: "completion_loyalty", success: `Paired DVA/card top-up and released ${amount} loyalty credit.` });
  redirect(`/internal/dva-reconciliation/main-bank?${params.toString()}`);
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

  const stagedLoyaltyResult = targetMode === "completion_loyalty"
    ? await (supabase as any).rpc("internal_staged_completion_loyalty_pairs_v1", {
        p_search: null,
        p_limit: 300,
        p_offset: 0,
      })
    : { data: [], error: null };

  const topUpCandidatesResult = targetMode === "completion_loyalty"
    ? await (supabase as any).rpc("internal_completion_loyalty_destination_in_candidates_v1", {
        p_importer_id: null,
        p_search: null,
        p_limit: 300,
        p_offset: 0,
      })
    : { data: [], error: null };

  const lines = (linesResult.data ?? []) as Row[];
  const targets = (targetsResult.data ?? []) as Row[];
  const loyaltyTargets = (loyaltyTargetsResult.data ?? []) as Row[];
  const stagedLoyaltyRows = (stagedLoyaltyResult.data ?? []) as Row[];
  const topUpCandidateRows = (topUpCandidatesResult.data ?? []) as Row[];
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
  const dataError = linesResult.error || targetsResult.error || loyaltyTargetsResult.error || stagedLoyaltyResult.error || topUpCandidatesResult.error || residualsResult.error;
  const hasPendingLoyaltyRelease = targetMode === "completion_loyalty" && stagedLoyaltyRows.length > 0;
  const hasNewLoyaltyTargets = targetMode === "completion_loyalty" && loyaltyTargets.length > 0;
  const shouldShowReservationWorkspace = targetMode === "shipper_ap" || hasNewLoyaltyTargets;

  return (
    <main className="min-h-screen overflow-x-hidden bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 lg:px-8">
      <div className="mx-auto w-full max-w-7xl space-y-5">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href="/internal" className="text-sm font-semibold text-sky-700">← Back to internal dashboard</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Main bank matching workspace</p>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight">Main bank matching</h1>
          <p className="mt-3 max-w-5xl text-sm leading-6 text-slate-600">
            Shared main-company bank workspace. Shipper charge matching remains the default lane. Completion loyalty uses a two-stage funding control: reserve the main-bank OUT first, then pair the DVA/card top-up IN before dashboard credit is released.
          </p>
          {success ? <p className="mt-4 rounded-2xl border border-emerald-200 bg-emerald-50 p-3 text-sm font-semibold text-emerald-900">{success}</p> : null}
          {error ? <p className="mt-4 rounded-2xl border border-rose-200 bg-rose-50 p-3 text-sm font-semibold text-rose-900">{error}</p> : null}
          {dataError ? (
            <p className="mt-4 rounded-2xl border border-amber-200 bg-amber-50 p-3 text-sm font-semibold text-amber-900">
              Main-bank data unavailable: {cleanUiText(linesResult.error?.message || targetsResult.error?.message || loyaltyTargetsResult.error?.message || stagedLoyaltyResult.error?.message || topUpCandidatesResult.error?.message || residualsResult.error?.message)}
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
            <span className="mt-1 block font-normal opacity-80">Complete existing reserved OUT rows first. Create a new OUT reservation only when a clean reward target is available.</span>
          </Link>
        </section>

        {targetMode === "completion_loyalty" ? (
          <section className={`rounded-3xl border p-5 shadow-sm ${hasPendingLoyaltyRelease ? "border-emerald-300 bg-emerald-50" : "border-slate-200 bg-white"}`}>
            <p className="text-xs font-bold uppercase tracking-[0.18em] text-emerald-700">Primary loyalty action</p>
            <h2 className="mt-2 text-2xl font-semibold">Complete existing reservation</h2>
            <p className="mt-2 text-sm leading-6 text-slate-600">
              Use this when the main-bank OUT has already been reserved. Select the reserved OUT row and the matching importer DVA/card top-up IN line. This is the step that releases dashboard loyalty credit.
            </p>
            <form action={releaseReservedLoyaltyTopUpAction} className="mt-4 grid min-w-0 gap-3 lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)_auto] lg:items-end">
              <label className="grid min-w-0 gap-1 text-xs font-bold uppercase tracking-wide text-slate-500">
                Reserved loyalty OUT waiting to release
                <select name="loyalty_match_id" className="w-full min-w-0 rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal normal-case tracking-normal text-slate-950" defaultValue={text(stagedLoyaltyRows[0]?.loyalty_match_id)}>
                  <option value="">Select reserved OUT</option>
                  {stagedLoyaltyRows.map((row) => (
                    <option key={text(row.loyalty_match_id)} value={text(row.loyalty_match_id)}>
                      {short(row.order_ref, 34)} · {gbp(row.matched_gbp_amount)} · {short(row.importer_name, 36)}
                    </option>
                  ))}
                </select>
              </label>
              <label className="grid min-w-0 gap-1 text-xs font-bold uppercase tracking-wide text-slate-500">
                Matching DVA/card top-up IN
                <select name="top_up_statement_line_id" className="w-full min-w-0 rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal normal-case tracking-normal text-slate-950" defaultValue={text(topUpCandidateRows[0]?.statement_line_id)}>
                  <option value="">Select top-up IN</option>
                  {topUpCandidateRows.map((row) => (
                    <option key={text(row.statement_line_id)} value={text(row.statement_line_id)}>
                      {text(row.statement_date)} · {gbp(row.remaining_gbp)} · {short(row.reference_raw, 52)}
                    </option>
                  ))}
                </select>
              </label>
              <button type="submit" disabled={stagedLoyaltyRows.length === 0 || topUpCandidateRows.length === 0} className="w-full rounded-xl bg-emerald-700 px-4 py-2 text-sm font-bold text-white disabled:bg-slate-200 disabled:text-slate-500 lg:w-auto">Pair IN and release</button>
            </form>
            <div className="mt-3 grid gap-3 text-xs font-semibold text-slate-600 md:grid-cols-2">
              <p>Reserved OUT rows waiting: <span className="text-slate-950">{stagedLoyaltyRows.length}</span></p>
              <p>Available DVA/card top-up IN lines: <span className="text-slate-950">{topUpCandidateRows.length}</span></p>
            </div>
          </section>
        ) : null}

        <section className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
          <form action="/internal/dva-reconciliation/main-bank" className="grid min-w-0 gap-3 md:grid-cols-[minmax(0,1fr)_minmax(0,180px)_minmax(0,180px)_auto] md:items-end">
            <input type="hidden" name="target" value={targetMode} />
            <label className="grid min-w-0 gap-1 text-xs font-bold uppercase tracking-wide text-slate-500">
              Search bank lines
              <input className="w-full min-w-0 rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal normal-case tracking-normal text-slate-950" name="q" defaultValue={q} placeholder="Bank ref, date, amount, source bank" />
            </label>
            <label className="grid min-w-0 gap-1 text-xs font-bold uppercase tracking-wide text-slate-500">
              Statement status
              <select className="w-full min-w-0 rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal normal-case tracking-normal text-slate-950" name="status" defaultValue={status}>
                <option value="unmatched">Unmatched</option>
                <option value="part_allocated">Part matched</option>
                <option value="balanced">Balanced</option>
                <option value="all">All</option>
              </select>
            </label>
            {targetMode === "shipper_ap" ? (
              <label className="grid min-w-0 gap-1 text-xs font-bold uppercase tracking-wide text-slate-500">
                Shipper charge status
                <select className="w-full min-w-0 rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal normal-case tracking-normal text-slate-950" name="target_status" defaultValue={targetStatus}>
                  <option value="open">Open</option>
                  <option value="allocated">Matched</option>
                  <option value="all">All</option>
                </select>
              </label>
            ) : (
              <div className="min-w-0 rounded-xl border border-sky-200 bg-sky-50 px-3 py-2 text-xs font-semibold leading-5 text-sky-950">
                Completion loyalty: use the primary release panel above for existing reservations. The reservation workspace appears only when a new reward target is available.
              </div>
            )}
            <button className="w-full rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white md:w-auto" type="submit">Apply</button>
          </form>
        </section>

        {targetMode === "completion_loyalty" && !hasNewLoyaltyTargets ? (
          <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
            <p className="text-xs font-bold uppercase tracking-[0.18em] text-slate-500">Create new OUT reservation</p>
            <h2 className="mt-2 text-xl font-semibold">No new loyalty targets to reserve</h2>
            <p className="mt-2 text-sm leading-6 text-slate-600">
              There are no clean completed reward proposals waiting for a new main-bank OUT reservation. Existing reserved OUT rows should be completed in the primary release panel above.
            </p>
          </section>
        ) : null}

        {shouldShowReservationWorkspace ? (
          <MainBankAllocationController
            lines={lines}
            targets={targets}
            loyaltyTargets={loyaltyTargets}
            residualRows={residualRows}
            targetMode={targetMode}
          />
        ) : null}
      </div>
    </main>
  );
}
