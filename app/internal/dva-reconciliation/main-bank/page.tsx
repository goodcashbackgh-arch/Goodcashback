import Link from "next/link";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { cleanUiText } from "@/lib/ui/cleanUiText";
import MainBankAllocationController from "./MainBankAllocationController";

type Row = Record<string, unknown>;
type SearchParamsValue = Record<string, string | string[] | undefined>;
type TargetMode = "shipper_ap" | "completion_loyalty";
type MatchBand = "Exact" | "Strong" | "Review" | "No match";
type PotMatchBand = "Exact pot" | "Strong pot" | "Review" | "No match";

type LoyaltyPairingSuggestion = {
  reservedOut: Row;
  candidates: Row[];
  suggestedCandidate: Row | null;
  matchBand: MatchBand;
  matchScore: number;
  matchReason: string;
  canRelease: boolean;
};

type LoyaltyFundingPotSuggestion = {
  potKey: string;
  importerId: string;
  importerName: string;
  sourceOutLineId: string;
  sourceOutReference: string;
  sourceOutDate: string;
  rows: Row[];
  rewardCount: number;
  totalRewardGbp: number;
  candidates: Row[];
  suggestedCandidate: Row | null;
  matchBand: PotMatchBand;
  matchReason: string;
};

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

function round2(value: number) {
  return Math.round((value + Number.EPSILON) * 100) / 100;
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

function matchBandClass(matchBand: MatchBand) {
  if (matchBand === "Exact") return "border-emerald-200 bg-emerald-100 text-emerald-900";
  if (matchBand === "Strong") return "border-sky-200 bg-sky-100 text-sky-900";
  if (matchBand === "Review") return "border-amber-200 bg-amber-100 text-amber-900";
  return "border-slate-200 bg-slate-100 text-slate-700";
}

function potBandClass(matchBand: PotMatchBand) {
  if (matchBand === "Exact pot") return "border-emerald-200 bg-emerald-100 text-emerald-900";
  if (matchBand === "Strong pot") return "border-sky-200 bg-sky-100 text-sky-900";
  if (matchBand === "Review") return "border-amber-200 bg-amber-100 text-amber-900";
  return "border-slate-200 bg-slate-100 text-slate-700";
}

function dateValue(value: unknown) {
  const raw = text(value);
  if (!raw) return 0;
  const parsed = Date.parse(raw);
  return Number.isFinite(parsed) ? parsed : 0;
}

function amountDiff(left: unknown, right: unknown) {
  return Math.abs(num(left) - num(right));
}

function referenceText(row: Row) {
  return `${text(row.reference_raw)} ${text(row.order_ref)} ${text(row.importer_name)}`.toLowerCase();
}

function candidateRank(reservedOut: Row, candidate: Row) {
  const rewardAmount = num(reservedOut.matched_gbp_amount);
  const remainingAmount = num(candidate.remaining_gbp);
  const exactAmount = amountDiff(remainingAmount, rewardAmount) <= 0.01;
  const sufficientAmount = remainingAmount + 0.01 >= rewardAmount;
  const sourceDate = dateValue(reservedOut.source_out_date || reservedOut.statement_date || reservedOut.created_at || reservedOut.paired_at);
  const candidateDate = dateValue(candidate.statement_date);
  const dateDistance = sourceDate && candidateDate ? Math.abs(candidateDate - sourceDate) : 0;
  const reference = referenceText(candidate);
  const orderRef = text(reservedOut.order_ref).toLowerCase();
  const importerName = text(reservedOut.importer_name).toLowerCase();
  const referenceHint = (!!orderRef && reference.includes(orderRef)) || (!!importerName && reference.includes(importerName));

  return {
    exactAmount,
    sufficientAmount,
    referenceHint,
    dateDistance,
    score: (exactAmount ? 70 : 0) + (sufficientAmount ? 15 : 0) + (referenceHint ? 15 : 0),
  };
}

function buildLoyaltyPairingSuggestions(stagedRows: Row[], topUpRows: Row[]): LoyaltyPairingSuggestion[] {
  return stagedRows.map((reservedOut) => {
    const importerId = text(reservedOut.importer_id);
    const rewardAmount = num(reservedOut.matched_gbp_amount);
    const sameImporterCandidates = topUpRows
      .filter((candidate) => text(candidate.importer_id) === importerId)
      .filter((candidate) => num(candidate.remaining_gbp) > 0.01)
      .map((candidate) => ({ candidate, rank: candidateRank(reservedOut, candidate) }))
      .sort((left, right) => {
        if (right.rank.score !== left.rank.score) return right.rank.score - left.rank.score;
        if (left.rank.dateDistance !== right.rank.dateDistance) return left.rank.dateDistance - right.rank.dateDistance;
        return dateValue(right.candidate.statement_date) - dateValue(left.candidate.statement_date);
      });

    const exactCandidates = sameImporterCandidates.filter((item) => item.rank.exactAmount);
    const sufficientCandidates = sameImporterCandidates.filter((item) => item.rank.sufficientAmount);
    const suggested = sameImporterCandidates[0]?.candidate ?? null;
    const suggestedRank = suggested ? candidateRank(reservedOut, suggested) : null;

    let matchBand: MatchBand = "No match";
    let matchScore = 0;
    let matchReason = "No same-importer DVA/card IN candidate with enough remaining value.";

    if (exactCandidates.length === 1) {
      matchBand = "Exact";
      matchScore = 100;
      matchReason = "Same importer and exact remaining amount.";
    } else if (exactCandidates.length > 1) {
      matchBand = "Review";
      matchScore = 70;
      matchReason = "Multiple same-importer exact-amount IN candidates exist. Staff should choose the correct one.";
    } else if (sufficientCandidates.length === 1) {
      matchBand = "Strong";
      matchScore = suggestedRank?.score ?? 75;
      matchReason = num(suggested?.remaining_gbp) > rewardAmount + 0.01
        ? "Same importer and sufficient IN value, but amount is higher than this reward. Treat as possible bulk top-up."
        : "Same importer and sufficient IN value.";
    } else if (sufficientCandidates.length > 1) {
      matchBand = "Review";
      matchScore = suggestedRank?.score ?? 60;
      matchReason = "Multiple same-importer sufficient IN candidates exist. Staff should choose the correct one.";
    }

    return {
      reservedOut,
      candidates: sameImporterCandidates.map((item) => item.candidate),
      suggestedCandidate: suggested,
      matchBand,
      matchScore,
      matchReason,
      canRelease: !!suggested && sufficientCandidates.length > 0,
    };
  });
}

function buildLoyaltyFundingPotSuggestions(stagedRows: Row[], topUpRows: Row[]): LoyaltyFundingPotSuggestion[] {
  const grouped = new Map<string, Row[]>();

  for (const row of stagedRows) {
    const importerId = text(row.importer_id);
    const sourceOutLineId = text(row.source_out_statement_line_id);
    if (!importerId || !sourceOutLineId) continue;
    const key = `${importerId}:${sourceOutLineId}`;
    grouped.set(key, [...(grouped.get(key) ?? []), row]);
  }

  return Array.from(grouped.entries())
    .map(([potKey, rows]) => {
      const first = rows[0] ?? {};
      const importerId = text(first.importer_id);
      const totalRewardGbp = round2(rows.reduce((sum, row) => sum + num(row.matched_gbp_amount), 0));
      const sameImporterCandidates = topUpRows
        .filter((candidate) => text(candidate.importer_id) === importerId)
        .filter((candidate) => num(candidate.remaining_gbp) + 0.01 >= totalRewardGbp)
        .sort((left, right) => {
          const leftExact = amountDiff(left.remaining_gbp, totalRewardGbp) <= 0.01 ? 1 : 0;
          const rightExact = amountDiff(right.remaining_gbp, totalRewardGbp) <= 0.01 ? 1 : 0;
          if (rightExact !== leftExact) return rightExact - leftExact;
          return dateValue(right.statement_date) - dateValue(left.statement_date);
        });

      const exactCandidates = sameImporterCandidates.filter((candidate) => amountDiff(candidate.remaining_gbp, totalRewardGbp) <= 0.01);
      const suggestedCandidate = sameImporterCandidates[0] ?? null;
      let matchBand: PotMatchBand = "No match";
      let matchReason = "No same-importer DVA/card IN candidate has enough remaining value for this funding pot.";

      if (exactCandidates.length === 1) {
        matchBand = "Exact pot";
        matchReason = "Same importer and exact remaining IN value for the selected reserved OUT pot.";
      } else if (exactCandidates.length > 1) {
        matchBand = "Review";
        matchReason = "Multiple same-importer exact funding-pot IN candidates exist. Staff should choose the correct one.";
      } else if (sameImporterCandidates.length === 1) {
        matchBand = "Strong pot";
        matchReason = "Same importer and sufficient IN value. This may be a bulk top-up with remaining balance after selected rewards.";
      } else if (sameImporterCandidates.length > 1) {
        matchBand = "Review";
        matchReason = "Multiple same-importer sufficient IN candidates exist. Staff should review before using this as a funding pot.";
      }

      return {
        potKey,
        importerId,
        importerName: text(first.importer_name) || "Importer/customer",
        sourceOutLineId: text(first.source_out_statement_line_id),
        sourceOutReference: text(first.source_out_reference),
        sourceOutDate: text(first.source_out_date),
        rows,
        rewardCount: rows.length,
        totalRewardGbp,
        candidates: sameImporterCandidates,
        suggestedCandidate,
        matchBand,
        matchReason,
      };
    })
    .filter((pot) => pot.rewardCount > 1)
    .sort((left, right) => right.rewardCount - left.rewardCount || right.totalRewardGbp - left.totalRewardGbp);
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
  const loyaltySuggestions = buildLoyaltyPairingSuggestions(stagedLoyaltyRows, topUpCandidateRows);
  const loyaltyFundingPotSuggestions = buildLoyaltyFundingPotSuggestions(stagedLoyaltyRows, topUpCandidateRows);
  const exactSuggestionCount = loyaltySuggestions.filter((item) => item.matchBand === "Exact").length;
  const strongSuggestionCount = loyaltySuggestions.filter((item) => item.matchBand === "Strong").length;
  const reviewSuggestionCount = loyaltySuggestions.filter((item) => item.matchBand === "Review").length;
  const noMatchSuggestionCount = loyaltySuggestions.filter((item) => item.matchBand === "No match").length;
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
            <div className="flex flex-wrap items-start justify-between gap-3">
              <div>
                <h2 className="mt-2 text-2xl font-semibold">Ready to release queue</h2>
                <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">
                  Each card is an already reserved main-bank OUT. The suggested DVA/card IN lines are same-importer only. Match bands are advisory; credit is released only when staff clicks Pair IN and release.
                </p>
              </div>
              <div className="grid grid-cols-2 gap-2 text-xs font-bold sm:grid-cols-4">
                <div className="rounded-xl border border-emerald-200 bg-white px-3 py-2 text-emerald-900">Exact<br /><span className="text-lg">{exactSuggestionCount}</span></div>
                <div className="rounded-xl border border-sky-200 bg-white px-3 py-2 text-sky-900">Strong<br /><span className="text-lg">{strongSuggestionCount}</span></div>
                <div className="rounded-xl border border-amber-200 bg-white px-3 py-2 text-amber-900">Review<br /><span className="text-lg">{reviewSuggestionCount}</span></div>
                <div className="rounded-xl border border-slate-200 bg-white px-3 py-2 text-slate-700">No match<br /><span className="text-lg">{noMatchSuggestionCount}</span></div>
              </div>
            </div>

            {loyaltyFundingPotSuggestions.length > 0 ? (
              <div className="mt-4 rounded-2xl border border-indigo-200 bg-indigo-50 p-4">
                <div className="flex flex-wrap items-start justify-between gap-3">
                  <div>
                    <p className="text-xs font-bold uppercase tracking-[0.18em] text-indigo-700">Funding pot view</p>
                    <h3 className="mt-1 text-lg font-extrabold text-indigo-950">Same-importer bulk funding pots detected</h3>
                    <p className="mt-1 text-sm leading-6 text-indigo-900">
                      This is read-only. It shows when one main-bank OUT may fund multiple same-importer loyalty rewards. Release still happens through the single-row cards until a controlled bulk wrapper is built.
                    </p>
                  </div>
                </div>
                <div className="mt-3 grid gap-3">
                  {loyaltyFundingPotSuggestions.map((pot) => {
                    const suggested = pot.suggestedCandidate;
                    return (
                      <article key={pot.potKey} className="rounded-2xl border border-indigo-100 bg-white p-4 shadow-sm">
                        <div className="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
                          <div className="min-w-0">
                            <div className="flex flex-wrap items-center gap-2">
                              <span className={`rounded-full border px-3 py-1 text-[11px] font-extrabold ${potBandClass(pot.matchBand)}`}>{pot.matchBand}</span>
                              <span className="rounded-full border border-slate-200 bg-slate-50 px-3 py-1 text-[11px] font-bold text-slate-700">{pot.rewardCount} rewards</span>
                            </div>
                            <h4 className="mt-3 text-base font-extrabold text-slate-950">{short(pot.importerName, 80)}</h4>
                            <p className="mt-1 text-xs text-slate-500">Source OUT: <span className="font-bold text-slate-900">{gbp(pot.totalRewardGbp)}</span> selected rewards · {short(pot.sourceOutReference, 70)}</p>
                            <p className="mt-2 rounded-xl border border-slate-100 bg-slate-50 p-2 text-xs font-semibold leading-5 text-slate-600">{pot.matchReason}</p>
                          </div>
                          <div className="grid min-w-0 gap-1 rounded-xl border border-slate-200 bg-slate-50 p-3 text-xs text-slate-600 lg:w-[420px]">
                            <p className="font-bold uppercase tracking-wide text-slate-500">Suggested same-importer DVA/card IN</p>
                            <p className="font-semibold text-slate-900">{suggested ? `${text(suggested.statement_date)} · ${gbp(suggested.remaining_gbp)} · ${short(suggested.reference_raw, 60)}` : "No sufficient same-importer IN candidate"}</p>
                            <p>Individual release remains controlled by each reward card below.</p>
                          </div>
                        </div>
                      </article>
                    );
                  })}
                </div>
              </div>
            ) : null}

            <div className="mt-4 grid gap-3">
              {loyaltySuggestions.length === 0 ? (
                <div className="rounded-2xl border border-slate-200 bg-white p-4 text-sm text-slate-600">
                  No reserved completion-loyalty OUT rows are waiting for DVA/card IN pairing.
                </div>
              ) : loyaltySuggestions.map((suggestion) => {
                const reservedOut = suggestion.reservedOut;
                const suggested = suggestion.suggestedCandidate;
                const loyaltyMatchId = text(reservedOut.loyalty_match_id);
                const suggestedLineId = text(suggested?.statement_line_id);
                return (
                  <article key={loyaltyMatchId} className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm">
                    <div className="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
                      <div className="min-w-0">
                        <div className="flex flex-wrap items-center gap-2">
                          <span className={`rounded-full border px-3 py-1 text-[11px] font-extrabold ${matchBandClass(suggestion.matchBand)}`}>{suggestion.matchBand}</span>
                          <span className="rounded-full border border-slate-200 bg-slate-50 px-3 py-1 text-[11px] font-bold text-slate-700">Score {suggestion.matchScore}</span>
                        </div>
                        <h3 className="mt-3 text-lg font-extrabold text-slate-950">{short(reservedOut.order_ref, 42)}</h3>
                        <p className="mt-1 text-sm font-semibold text-slate-700">{short(reservedOut.importer_name, 64)}</p>
                        <p className="mt-1 text-xs text-slate-500">Reserved OUT amount: <span className="font-bold text-slate-900">{gbp(reservedOut.matched_gbp_amount)}</span></p>
                        <p className="mt-2 rounded-xl border border-slate-100 bg-slate-50 p-2 text-xs font-semibold leading-5 text-slate-600">{suggestion.matchReason}</p>
                      </div>

                      <form action={releaseReservedLoyaltyTopUpAction} className="grid min-w-0 gap-2 lg:w-[460px]">
                        <input type="hidden" name="loyalty_match_id" value={loyaltyMatchId} />
                        <label className="grid gap-1 text-xs font-bold uppercase tracking-wide text-slate-500">
                          Suggested same-importer DVA/card IN
                          <select name="top_up_statement_line_id" defaultValue={suggestedLineId} disabled={suggestion.candidates.length === 0} className="w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal normal-case tracking-normal text-slate-950 disabled:bg-slate-100 disabled:text-slate-400">
                            {suggestion.candidates.length === 0 ? <option value="">No same-importer IN candidate</option> : null}
                            {suggestion.candidates.map((candidate) => (
                              <option key={text(candidate.statement_line_id)} value={text(candidate.statement_line_id)}>
                                {text(candidate.statement_date)} · {gbp(candidate.remaining_gbp)} · {short(candidate.reference_raw, 56)}
                              </option>
                            ))}
                          </select>
                        </label>
                        <button type="submit" disabled={!suggestion.canRelease} className="rounded-xl bg-emerald-700 px-4 py-2 text-sm font-bold text-white hover:bg-emerald-800 disabled:bg-slate-200 disabled:text-slate-500">
                          Pair IN and release
                        </button>
                      </form>
                    </div>
                  </article>
                );
              })}
            </div>

            <div className="mt-3 grid gap-3 text-xs font-semibold text-slate-600 md:grid-cols-2">
              <p>Reserved OUT rows waiting: <span className="text-slate-950">{stagedLoyaltyRows.length}</span></p>
              <p>DVA/card top-up IN candidates loaded for suggestion engine: <span className="text-slate-950">{topUpCandidateRows.length}</span> · card suggestions are same-importer only · funding-pot groups: <span className="text-slate-950">{loyaltyFundingPotSuggestions.length}</span></p>
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
                Completion loyalty: ready-to-release cards above do not replace the manual reservation/residual workspace below. FX/fee/hold residual posting remains available through the lower workspace.
              </div>
            )}
            <button className="w-full rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white md:w-auto" type="submit">Apply</button>
          </form>
        </section>

        {targetMode === "completion_loyalty" && !hasNewLoyaltyTargets ? (
          <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
            <p className="text-xs font-bold uppercase tracking-[0.18em] text-slate-500">Manual reservation and residual allocation</p>
            <h2 className="mt-2 text-xl font-semibold">No new loyalty targets to reserve</h2>
            <p className="mt-2 text-sm leading-6 text-slate-600">
              Existing reserved OUT rows should be completed in the ready-to-release queue above. The manual workspace remains below so main-bank residuals such as FX/payment variance, bank fees, and holds are still available.
            </p>
          </section>
        ) : null}

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
