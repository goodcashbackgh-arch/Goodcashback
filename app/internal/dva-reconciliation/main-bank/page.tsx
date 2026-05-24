import Link from "next/link";
import { createClient } from "@/utils/supabase/server";
import { allocateMainBankLineToShipperApAction } from "./actions";
import { allocateMainBankFxFeeAction } from "./fxFeeActions";

type Row = Record<string, unknown>;
type SearchParamsValue = Record<string, string | string[] | undefined>;

const gbpFormatter = new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" });
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

function short(value: unknown, max = 48) {
  const raw = text(value);
  if (!raw) return "—";
  return raw.length > max ? `${raw.slice(0, max - 1)}…` : raw;
}

function href(params: Record<string, string | undefined>) {
  const qp = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) {
    if (value) qp.set(key, value);
  }
  const query = qp.toString();
  return query ? `/internal/dva-reconciliation/main-bank?${query}` : "/internal/dva-reconciliation/main-bank";
}

function selectedClass(selected: boolean) {
  return selected ? "border-sky-500 bg-sky-50 ring-2 ring-sky-200" : "border-slate-200 bg-white";
}

function toneClass(tone: "ok" | "warn" | "blocked" | "muted") {
  if (tone === "ok") return "border-emerald-200 bg-emerald-50 text-emerald-900";
  if (tone === "warn") return "border-amber-200 bg-amber-50 text-amber-900";
  if (tone === "blocked") return "border-rose-200 bg-rose-50 text-rose-900";
  return "border-slate-200 bg-slate-50 text-slate-700";
}

function SummaryCard({ label, value, detail, tone }: { label: string; value: string; detail: string; tone: "ok" | "warn" | "blocked" | "muted" }) {
  return (
    <div className={`rounded-2xl border p-3 shadow-sm ${toneClass(tone)}`}>
      <p className="text-[11px] font-bold uppercase tracking-wide opacity-70">{label}</p>
      <p className="mt-1 text-2xl font-extrabold">{value}</p>
      <p className="mt-1 text-xs leading-4 opacity-90">{detail}</p>
    </div>
  );
}

function targetCheckboxValue(row: Row) {
  return text(row.shipping_document_id);
}

function residualLabel(value: string) {
  if (value === "fx_card_difference") return "FX/card difference";
  if (value === "bank_fee") return "Bank fee";
  return "Unmatched hold";
}

export default async function MainBankShipperMatchingPage({
  searchParams,
}: {
  searchParams?: SearchParamsValue | Promise<SearchParamsValue>;
}) {
  const params = searchParams ? await Promise.resolve(searchParams) : {};
  const selectedLineId = firstParam(params.line_id);
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
      p_limit: 100,
      p_offset: 0,
    }),
    (supabase as any).rpc("internal_shipper_ap_posted_targets_for_main_bank_v1", {
      p_status: targetStatus,
      p_search: q || null,
      p_limit: 100,
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
  const residualByLine = new Map<string, number>();
  const residualByType = new Map<string, number>();
  for (const row of residualRows) {
    const lineId = text(row.dva_statement_line_id);
    const allocationType = text(row.allocation_type);
    const amount = num(row.allocated_gbp_amount);
    residualByLine.set(lineId, round2((residualByLine.get(lineId) ?? 0) + amount));
    residualByType.set(allocationType, round2((residualByType.get(allocationType) ?? 0) + amount));
  }

  const selectedLine = lines.find((row) => text(row.statement_line_id) === selectedLineId) ?? lines[0];
  const activeLineId = text(selectedLine?.statement_line_id);
  const selectedLineResidual = residualByLine.get(activeLineId) ?? 0;
  const openTargets = targets.filter((row) => num(row.remaining_gbp) > 0);
  const sameShipperTargets = openTargets.filter((row) => text(row.shipper_name) === text(openTargets[0]?.shipper_name));
  const defaultSelectedTargets = sameShipperTargets.length > 0 ? sameShipperTargets : openTargets;
  const targetTotal = round2(defaultSelectedTargets.reduce((sum, row) => sum + num(row.remaining_gbp), 0));
  const rawLineRemaining = round2(num(selectedLine?.remaining_gbp));
  const lineRemaining = round2(Math.max(rawLineRemaining - selectedLineResidual, 0));
  const visibleLineTotal = round2(lines.reduce((sum, row) => {
    const lineId = text(row.statement_line_id);
    return sum + Math.max(num(row.remaining_gbp) - (residualByLine.get(lineId) ?? 0), 0);
  }, 0));
  const visibleTargetTotal = round2(openTargets.reduce((sum, row) => sum + num(row.remaining_gbp), 0));
  const targetSelectionFits = targetTotal <= lineRemaining + 0.01;
  const suggestedGap = round2(lineRemaining - targetTotal);
  const existingResidualTotal = round2(Array.from(residualByLine.values()).reduce((sum, amount) => sum + amount, 0));
  const selectedLineExplainedTotal = round2(num(selectedLine?.amount_gbp) - lineRemaining + Math.min(targetTotal, lineRemaining));

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 lg:px-8">
      <div className="mx-auto max-w-7xl space-y-5 pb-32">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href="/internal" className="text-sm font-semibold text-sky-700">← Back to internal dashboard</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Main bank allocation workspace</p>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight">Main bank → shipper AP allocation</h1>
          <p className="mt-3 max-w-5xl text-sm leading-6 text-slate-600">
            Isolated workspace for main company bank statement lines. It does not touch the importer supplier/retailer DVA workspace. Shipper AP is saved in the shipper bridge; FX/card differences and bank fees are saved in the existing DVA allocation table.
          </p>
          {success ? <p className="mt-4 rounded-2xl border border-emerald-200 bg-emerald-50 p-3 text-sm font-semibold text-emerald-900">{success}</p> : null}
          {error ? <p className="mt-4 rounded-2xl border border-rose-200 bg-rose-50 p-3 text-sm font-semibold text-rose-900">{error}</p> : null}
          {(linesResult.error || targetsResult.error || residualsResult.error) ? (
            <p className="mt-4 rounded-2xl border border-amber-200 bg-amber-50 p-3 text-sm font-semibold text-amber-900">
              Main-bank data unavailable: {linesResult.error?.message || targetsResult.error?.message || residualsResult.error?.message}
            </p>
          ) : null}
        </section>

        <section className="grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
          <SummaryCard label="Main-bank lines" value={String(lines.length)} detail={`${gbp(visibleLineTotal)} visible remaining after residuals`} tone={lines.length > 0 ? "ok" : "muted"} />
          <SummaryCard label="Open shipper AP" value={String(openTargets.length)} detail={`${gbp(visibleTargetTotal)} visible remaining`} tone={openTargets.length > 0 ? "ok" : "muted"} />
          <SummaryCard label="Selected AP total" value={gbp(targetTotal)} detail={defaultSelectedTargets.length ? `${defaultSelectedTargets.length} invoice(s) ticked by default` : "Tick invoices below"} tone={targetSelectionFits ? "ok" : "blocked"} />
          <SummaryCard label="Existing FX/fee/hold" value={gbp(existingResidualTotal)} detail="Existing residuals from the DVA allocation table" tone={existingResidualTotal > 0 ? "warn" : "muted"} />
          <SummaryCard label="Residual/gap" value={gbp(Math.abs(suggestedGap))} detail={suggestedGap === 0 ? "Exact split" : suggestedGap > 0 ? "Allocate to FX/fee or leave unposted" : "Selected AP exceeds available line"} tone={suggestedGap === 0 ? "ok" : suggestedGap > 0 ? "warn" : "blocked"} />
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

        <section className="grid gap-4 xl:grid-cols-[1fr_1.2fr]">
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
            <div className="border-b border-slate-100 pb-3">
              <h2 className="text-xl font-semibold">1. Select one main bank line</h2>
              <p className="mt-1 text-sm text-slate-500">OUT lines allocate to shipper AP plus FX/fee residuals. IN refunds/recoveries remain visible but not posted here yet.</p>
            </div>
            <div className="mt-4 grid gap-3">
              {lines.length === 0 ? <p className="rounded-2xl border border-dashed border-slate-300 p-6 text-center text-sm text-slate-500">No main-bank lines match this filter.</p> : null}
              {lines.map((line) => {
                const id = text(line.statement_line_id);
                const residual = residualByLine.get(id) ?? 0;
                const combinedRemaining = Math.max(num(line.remaining_gbp) - residual, 0);
                return (
                  <Link key={id} href={href({ line_id: id, status, target_status: targetStatus, q })} className={`rounded-2xl border p-4 shadow-sm ${selectedClass(id === activeLineId)}`}>
                    <div className="flex items-start justify-between gap-3">
                      <div>
                        <p className="text-lg font-bold text-slate-950">{short(line.reference_raw, 70)}</p>
                        <p className="mt-1 text-sm text-slate-600">{text(line.statement_date)} · {text(line.direction).toUpperCase()} · {text(line.source_bank).toUpperCase()}</p>
                      </div>
                      <span className="rounded-full bg-slate-100 px-3 py-1 text-xs font-bold text-slate-700">{combinedRemaining <= 0.01 ? "balanced" : text(line.match_status)}</span>
                    </div>
                    <div className="mt-3 grid gap-2 text-sm text-slate-700 sm:grid-cols-4">
                      <p>Amount <span className="font-bold text-slate-950">{gbp(line.amount_gbp)}</span></p>
                      <p>Shipper AP <span className="font-bold text-slate-950">{gbp(line.allocated_gbp)}</span></p>
                      <p>FX/fee/hold <span className="font-bold text-slate-950">{gbp(residual)}</span></p>
                      <p>Remaining <span className="font-bold text-slate-950">{gbp(combinedRemaining)}</span></p>
                    </div>
                  </Link>
                );
              })}
            </div>
          </div>

          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
            <div className="border-b border-slate-100 pb-3">
              <h2 className="text-xl font-semibold">2. Tick shipper AP invoice(s)</h2>
              <p className="mt-1 text-sm text-slate-500">One bank OUT line can cover one or more posted shipper AP invoices for the same shipper/Sage contact.</p>
            </div>
            <form action={allocateMainBankLineToShipperApAction} className="mt-4 grid gap-3">
              <input type="hidden" name="dva_statement_line_id" value={activeLineId} />
              {targets.length === 0 ? <p className="rounded-2xl border border-dashed border-slate-300 p-6 text-center text-sm text-slate-500">No posted shipper AP targets match this filter.</p> : null}
              {targets.map((target) => {
                const id = targetCheckboxValue(target);
                const defaultChecked = defaultSelectedTargets.some((row) => targetCheckboxValue(row) === id) && targetSelectionFits;
                return (
                  <label key={id} className={`block cursor-pointer rounded-2xl border p-4 shadow-sm transition hover:border-sky-300 hover:bg-sky-50 ${defaultChecked ? "border-sky-300 bg-sky-50" : "border-slate-200 bg-white"}`}>
                    <div className="flex items-start gap-3">
                      <input className="mt-1 h-4 w-4 rounded border-slate-300" type="checkbox" name="shipping_document_id" value={id} defaultChecked={defaultChecked} />
                      <div className="min-w-0 flex-1">
                        <div className="flex flex-wrap items-start justify-between gap-3">
                          <div>
                            <p className="text-lg font-bold text-slate-950">{short(target.shipper_invoice_ref, 70)}</p>
                            <p className="mt-1 text-sm text-slate-600">{text(target.shipper_name)} · Sage posted</p>
                          </div>
                          <span className="rounded-full bg-slate-100 px-3 py-1 text-xs font-bold text-slate-700">{text(target.target_status)}</span>
                        </div>
                        <div className="mt-3 grid gap-2 text-sm text-slate-700 sm:grid-cols-3">
                          <p>Amount <span className="font-bold text-slate-950">{gbp(target.amount_gbp)}</span></p>
                          <p>Allocated <span className="font-bold text-slate-950">{gbp(target.allocated_gbp)}</span></p>
                          <p>Remaining <span className="font-bold text-slate-950">{gbp(target.remaining_gbp)}</span></p>
                        </div>
                        <p className="mt-2 break-all text-xs text-slate-500">Sage invoice: {short(target.sage_purchase_invoice_id, 42)}</p>
                      </div>
                    </div>
                  </label>
                );
              })}
              <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
                <p className="text-xs font-bold uppercase tracking-wide text-slate-500">Selected main bank line</p>
                <p className="mt-1 text-sm font-semibold text-slate-950">{selectedLine ? `${short(selectedLine.reference_raw, 70)} · available ${gbp(lineRemaining)}` : "None selected"}</p>
                <label className="mt-3 grid gap-1 text-xs font-bold uppercase tracking-wide text-slate-500">
                  One-invoice override
                  <input className="rounded-xl border border-slate-300 px-3 py-2 text-sm font-normal normal-case tracking-normal text-slate-950" name="allocated_gbp_amount" placeholder="Only for one invoice" />
                </label>
                <input className="mt-3 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm" name="notes" defaultValue="Main bank payment matched to posted shipper AP invoice(s)." />
                <button disabled={!activeLineId || openTargets.length === 0 || !targetSelectionFits} className="mt-3 w-full rounded-xl bg-emerald-700 px-4 py-2 text-sm font-bold text-white disabled:bg-slate-200 disabled:text-slate-500" type="submit">
                  Confirm selected shipper AP allocation(s)
                </button>
              </div>
            </form>
          </div>
        </section>

        <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 shadow-sm">
          <h2 className="text-xl font-semibold text-amber-950">3. Allocate remaining residual to FX/card or bank fee</h2>
          <p className="mt-2 max-w-4xl text-sm leading-6 text-amber-900">
            This saves the residual in the existing DVA allocation table. It does not post to Sage yet. Shipper AP payment remains separate.
          </p>
          <form action={allocateMainBankFxFeeAction} className="mt-4 grid gap-3 md:grid-cols-[1fr_180px_180px_auto] md:items-end">
            <input type="hidden" name="dva_statement_line_id" value={activeLineId} />
            <label className="grid gap-1 text-xs font-bold uppercase tracking-wide text-amber-800">
              Residual type
              <select className="rounded-xl border border-amber-200 bg-white px-3 py-2 text-sm font-normal normal-case tracking-normal text-slate-950" name="residual_allocation_type" defaultValue="fx_card_difference">
                <option value="fx_card_difference">FX/card difference</option>
                <option value="bank_fee">Bank fee</option>
              </select>
            </label>
            <label className="grid gap-1 text-xs font-bold uppercase tracking-wide text-amber-800">
              Amount
              <input className="rounded-xl border border-amber-200 bg-white px-3 py-2 text-sm font-normal normal-case tracking-normal text-slate-950" name="residual_gbp_amount" defaultValue={suggestedGap > 0 ? suggestedGap.toFixed(2) : ""} />
            </label>
            <label className="grid gap-1 text-xs font-bold uppercase tracking-wide text-amber-800 md:col-span-1">
              Note
              <input className="rounded-xl border border-amber-200 bg-white px-3 py-2 text-sm font-normal normal-case tracking-normal text-slate-950" name="notes" defaultValue="Main-bank residual allocated separately from shipper AP." />
            </label>
            <button disabled={!activeLineId || suggestedGap <= 0} className="rounded-xl bg-amber-700 px-4 py-2 text-sm font-bold text-white disabled:bg-slate-200 disabled:text-slate-500" type="submit">
              Save FX/fee residual
            </button>
          </form>
        </section>

        <section className="grid gap-3 lg:grid-cols-3">
          <div className={`rounded-3xl border p-4 shadow-sm ${toneClass("muted")}`}>
            <p className="text-xs font-bold uppercase tracking-wide opacity-70">Residual breakdown</p>
            <p className="mt-2 text-sm leading-6">FX/card: {gbp(residualByType.get("fx_card_difference") ?? 0)} · Bank fee: {gbp(residualByType.get("bank_fee") ?? 0)} · Hold: {gbp(residualByType.get("unmatched_hold") ?? 0)}</p>
          </div>
          <div className={`rounded-3xl border p-4 shadow-sm ${toneClass("warn")}`}>
            <p className="text-xs font-bold uppercase tracking-wide opacity-70">Unmatched hold</p>
            <p className="mt-2 text-sm leading-6">The DB supports unmatched hold via the existing DVA allocation table. This screen keeps the hold visible; the hold write button is deliberately separate from shipper AP and FX/fee.</p>
          </div>
          <div className={`rounded-3xl border p-4 shadow-sm ${toneClass(selectedLineExplainedTotal >= num(selectedLine?.amount_gbp) - 0.01 ? "ok" : "warn")}`}>
            <p className="text-xs font-bold uppercase tracking-wide opacity-70">Selected line explained</p>
            <p className="mt-2 text-sm leading-6">Explained now/selected: {gbp(selectedLineExplainedTotal)} of {gbp(selectedLine?.amount_gbp)}. Keep AP, FX, fees and holds separate even when the summary balances.</p>
          </div>
        </section>
      </div>
    </main>
  );
}
