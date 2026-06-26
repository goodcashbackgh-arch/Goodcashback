import Link from "next/link";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { cleanUiText } from "@/lib/ui/cleanUiText";

type Row = Record<string, unknown>;
type SearchParamsValue = Record<string, string | string[] | undefined>;

const gbpFormatter = new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" });

function text(value: unknown) {
  if (Array.isArray(value)) return text(value[0]);
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  if (typeof value === "boolean") return value ? "true" : "false";
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

function short(value: unknown, max = 74) {
  const raw = cleanUiText(text(value));
  if (!raw) return "—";
  return raw.length > max ? `${raw.slice(0, max - 1)}…` : raw;
}

function firstParam(value: unknown) {
  if (Array.isArray(value)) return text(value[0]);
  return text(value);
}

function bool(value: unknown) {
  if (typeof value === "boolean") return value;
  return ["true", "t", "1", "yes"].includes(text(value).toLowerCase());
}

function statusBadge(canReset: boolean) {
  return canReset
    ? "border-emerald-200 bg-emerald-100 text-emerald-900"
    : "border-rose-200 bg-rose-100 text-rose-900";
}

function redirectWithResult(params: Record<string, string>): never {
  const query = new URLSearchParams(params);
  redirect(`/internal/completion-loyalty-reversals?${query.toString()}`);
}

async function resetCompletionLoyaltyReleaseAction(formData: FormData) {
  "use server";

  const loyaltyMatchId = firstParam(formData.get("loyalty_match_id"));
  const reason = firstParam(formData.get("reason"));
  const confirmed = firstParam(formData.get("confirm_reset")) === "yes";

  if (!loyaltyMatchId) redirectWithResult({ error: "Select one released loyalty row or group to reset." });
  if (!reason) redirectWithResult({ error: "Enter a reversal reason before resetting the release." });
  if (!confirmed) redirectWithResult({ error: "Confirm that this reset returns the reward to before funding selection." });

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("staff_reverse_completion_loyalty_release_to_selection_v1", {
    p_loyalty_match_id: loyaltyMatchId,
    p_reason: reason,
    p_reverse_group: true,
  });

  if (error) redirectWithResult({ error: error.message });

  const result = (data ?? {}) as Row;
  const reversedCount = text(result.reversed_count) || "1";
  const reversedTotal = gbp(result.reversed_total_gbp);

  revalidatePath("/internal/completion-loyalty-reversals");
  revalidatePath("/internal/dva-reconciliation/main-bank");
  revalidatePath("/internal/completion-loyalty-rewards");
  revalidatePath("/internal/accounting-command-centre/cash-posting");
  revalidatePath("/customer");

  redirectWithResult({ success: `Reset ${reversedCount} released loyalty reward(s), total ${reversedTotal}, back to before funding selection.` });
}

export default async function CompletionLoyaltyReversalsPage({
  searchParams,
}: {
  searchParams?: SearchParamsValue | Promise<SearchParamsValue>;
}) {
  const params = searchParams ? await Promise.resolve(searchParams) : {};
  const q = firstParam(params.q);
  const success = cleanUiText(firstParam(params.success));
  const error = cleanUiText(firstParam(params.error));

  const supabase = await createClient();
  const { data, error: rpcError } = await (supabase as any).rpc("internal_completion_loyalty_release_reversal_candidates_v1", {
    p_search: q || null,
    p_limit: 300,
    p_offset: 0,
  });

  const rows = (data ?? []) as Row[];
  const grouped = new Map<string, Row[]>();
  for (const row of rows) {
    const key = text(row.reversal_group_key) || text(row.loyalty_match_id);
    grouped.set(key, [...(grouped.get(key) ?? []), row]);
  }

  const groups = Array.from(grouped.entries()).map(([key, groupRows]) => {
    const first = groupRows[0] ?? {};
    const canReset = groupRows.every((row) => bool(row.can_reset_to_selection));
    const rewardCount = num(first.group_reward_count) || groupRows.length;
    const groupTotal = num(first.group_released_gbp) || groupRows.reduce((sum, row) => sum + num(row.matched_gbp_amount), 0);
    const groupExcess = num(first.group_destination_excess_gbp);
    return { key, rows: groupRows, first, canReset, rewardCount, groupTotal, groupExcess };
  });

  const eligibleCount = groups.filter((group) => group.canReset).length;

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 lg:px-8">
      <div className="mx-auto w-full max-w-7xl space-y-5">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href="/internal" className="text-sm font-semibold text-sky-700">← Back to internal dashboard</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Completion loyalty control</p>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight">Release reversal review</h1>
          <p className="mt-3 max-w-5xl text-sm leading-6 text-slate-600">
            Reset released but unapplied completion-loyalty credits back to before funding selection. This is for correcting wrong same-importer OUT/IN/reward selections before the credit is applied to an order or posted downstream.
          </p>
          <div className="mt-4 flex flex-wrap gap-2 text-sm font-semibold">
            <Link href="/internal/dva-reconciliation/main-bank?target=completion_loyalty&status=all" className="rounded-xl border border-sky-200 bg-sky-50 px-4 py-2 text-sky-900">Open main-bank loyalty workspace</Link>
            <Link href="/internal/completion-loyalty-rewards" className="rounded-xl border border-slate-200 bg-slate-50 px-4 py-2 text-slate-700">Open loyalty reward workbench</Link>
          </div>
          {success ? <p className="mt-4 rounded-2xl border border-emerald-200 bg-emerald-50 p-3 text-sm font-semibold text-emerald-900">{success}</p> : null}
          {error ? <p className="mt-4 rounded-2xl border border-rose-200 bg-rose-50 p-3 text-sm font-semibold text-rose-900">{error}</p> : null}
          {rpcError ? <p className="mt-4 rounded-2xl border border-amber-200 bg-amber-50 p-3 text-sm font-semibold text-amber-900">Reversal data unavailable: {cleanUiText(rpcError.message)}</p> : null}
        </section>

        <section className="grid gap-3 md:grid-cols-3">
          <div className="rounded-2xl border border-emerald-200 bg-emerald-50 p-4 text-emerald-950 shadow-sm">
            <p className="text-xs font-bold uppercase tracking-wide">Eligible reset groups</p>
            <p className="mt-2 text-3xl font-extrabold">{eligibleCount}</p>
          </div>
          <div className="rounded-2xl border border-slate-200 bg-white p-4 text-slate-950 shadow-sm">
            <p className="text-xs font-bold uppercase tracking-wide text-slate-500">Released groups loaded</p>
            <p className="mt-2 text-3xl font-extrabold">{groups.length}</p>
          </div>
          <form action="/internal/completion-loyalty-reversals" className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm">
            <label className="grid gap-1 text-xs font-bold uppercase tracking-wide text-slate-500">
              Search
              <input name="q" defaultValue={q} placeholder="Order ref, importer, source/destination ref" className="rounded-xl border border-slate-300 px-3 py-2 text-sm font-normal normal-case tracking-normal text-slate-950" />
            </label>
            <button className="mt-3 rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white" type="submit">Apply</button>
          </form>
        </section>

        <section className="grid gap-4">
          {groups.length === 0 ? (
            <div className="rounded-3xl border border-slate-200 bg-white p-6 text-sm text-slate-600 shadow-sm">
              No released completion-loyalty rows are currently available for reversal review.
            </div>
          ) : groups.map((group) => {
            const first = group.first;
            const blocker = group.rows.map((row) => text(row.reversal_blocker)).find(Boolean);
            const seedMatchId = text(first.loyalty_match_id);
            return (
              <article key={group.key} className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
                <div className="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
                  <div className="min-w-0 flex-1">
                    <div className="flex flex-wrap items-center gap-2">
                      <span className={`rounded-full border px-3 py-1 text-[11px] font-extrabold ${statusBadge(group.canReset)}`}>
                        {group.canReset ? "Safe to reset" : "Blocked"}
                      </span>
                      <span className="rounded-full border border-slate-200 bg-slate-50 px-3 py-1 text-[11px] font-bold text-slate-700">{group.rewardCount} reward{group.rewardCount === 1 ? "" : "s"}</span>
                    </div>
                    <h2 className="mt-3 text-lg font-extrabold text-slate-950">{short(first.importer_name, 90)}</h2>
                    <p className="mt-1 text-sm text-slate-600">Group released amount: <span className="font-extrabold text-slate-950">{gbp(group.groupTotal)}</span></p>
                    <div className="mt-3 grid gap-2 rounded-2xl border border-slate-100 bg-slate-50 p-3 text-xs font-semibold leading-5 text-slate-700">
                      <p>Source OUT: <span className="text-slate-950">{gbp(first.source_out_amount_gbp)}</span> · {short(first.source_out_reference, 100)}</p>
                      <p>Selected DVA/card IN: <span className="text-slate-950">{gbp(first.destination_in_amount_gbp)}</span> · {short(first.destination_in_reference, 100)}</p>
                      <p>Group excess left on IN after selected loyalty: <span className="text-slate-950">{gbp(group.groupExcess)}</span></p>
                      {blocker ? <p className="text-rose-800">Blocker: {blocker}</p> : <p className="text-emerald-800">No linked credit application debit or order funding event found.</p>}
                    </div>
                    <div className="mt-3 grid gap-2 text-xs text-slate-600">
                      {group.rows.map((row) => (
                        <div key={text(row.loyalty_match_id)} className="rounded-xl border border-slate-100 bg-white p-2">
                          <span className="font-bold text-slate-950">{short(row.order_ref, 48)}</span> · released {gbp(row.matched_gbp_amount)} · variance {gbp(row.variance_gbp)} · debit rows {text(row.credit_application_debit_rows)} · funding events {text(row.order_funding_event_rows)}
                        </div>
                      ))}
                    </div>
                  </div>

                  <form action={resetCompletionLoyaltyReleaseAction} className="grid gap-3 rounded-2xl border border-slate-200 bg-slate-50 p-4 lg:w-[390px]">
                    <input type="hidden" name="loyalty_match_id" value={seedMatchId} />
                    <label className="grid gap-1 text-xs font-bold uppercase tracking-wide text-slate-500">
                      Reversal reason
                      <textarea name="reason" required rows={3} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal normal-case tracking-normal text-slate-950" placeholder="Example: Wrong same-importer IN line selected; reset to repeat funding selection." />
                    </label>
                    <label className="flex gap-2 rounded-xl border border-amber-200 bg-amber-50 p-3 text-xs font-semibold leading-5 text-amber-950">
                      <input type="checkbox" name="confirm_reset" value="yes" required disabled={!group.canReset} className="mt-1" />
                      <span>I confirm this resets the released credit back to before reward funding selection. Staff must select the reward, source OUT, and destination IN again.</span>
                    </label>
                    <button type="submit" disabled={!group.canReset} className="rounded-xl bg-rose-700 px-4 py-2 text-sm font-bold text-white hover:bg-rose-800 disabled:bg-slate-200 disabled:text-slate-500">
                      Reset to before selection
                    </button>
                  </form>
                </div>
              </article>
            );
          })}
        </section>
      </div>
    </main>
  );
}
