import Link from "next/link";
import { createClient } from "@/utils/supabase/server";
import { allocateMainBankLineToShipperApAction } from "./actions";

type Row = Record<string, unknown>;
type SearchParamsValue = Record<string, string | string[] | undefined>;

const gbpFormatter = new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" });

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
  const selectedLine = lines.find((row) => text(row.statement_line_id) === selectedLineId) ?? lines[0];
  const activeLineId = text(selectedLine?.statement_line_id);
  const openTargets = targets.filter((row) => num(row.remaining_gbp) > 0);
  const sameShipperTargets = openTargets.filter((row) => text(row.shipper_name) === text(openTargets[0]?.shipper_name));
  const defaultSelectedTargets = sameShipperTargets.length > 0 ? sameShipperTargets : openTargets;
  const targetTotal = round2(defaultSelectedTargets.reduce((sum, row) => sum + num(row.remaining_gbp), 0));
  const lineRemaining = round2(num(selectedLine?.remaining_gbp));
  const visibleLineTotal = round2(lines.reduce((sum, row) => sum + num(row.remaining_gbp), 0));
  const visibleTargetTotal = round2(openTargets.reduce((sum, row) => sum + num(row.remaining_gbp), 0));
  const targetSelectionFits = targetTotal <= lineRemaining + 0.01;
  const suggestedGap = round2(lineRemaining - targetTotal);

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 lg:px-8">
      <form action={allocateMainBankLineToShipperApAction} className="mx-auto max-w-7xl space-y-5 pb-32">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href="/internal" className="text-sm font-semibold text-sky-700">← Back to internal dashboard</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Main bank allocation workspace</p>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight">Main bank → shipper AP allocation</h1>
          <p className="mt-3 max-w-5xl text-sm leading-6 text-slate-600">
            Isolated workspace for main company bank statement lines. It copies the importer-workspace pattern without touching the importer supplier/retailer flow: select one bank line, tick one or more shipper AP invoices, then confirm the allocation split.
          </p>
          {success ? <p className="mt-4 rounded-2xl border border-emerald-200 bg-emerald-50 p-3 text-sm font-semibold text-emerald-900">{success}</p> : null}
          {error ? <p className="mt-4 rounded-2xl border border-rose-200 bg-rose-50 p-3 text-sm font-semibold text-rose-900">{error}</p> : null}
          {(linesResult.error || targetsResult.error) ? (
            <p className="mt-4 rounded-2xl border border-amber-200 bg-amber-50 p-3 text-sm font-semibold text-amber-900">
              Main-bank RPC unavailable: {linesResult.error?.message || targetsResult.error?.message}. Apply migration 20260524_main_bank_shipper_matching_v1.sql first.
            </p>
          ) : null}
        </section>

        <section className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <SummaryCard label="Main-bank lines" value={String(lines.length)} detail={`${gbp(visibleLineTotal)} visible remaining`} tone={lines.length > 0 ? "ok" : "muted"} />
          <SummaryCard label="Open shipper AP" value={String(openTargets.length)} detail={`${gbp(visibleTargetTotal)} visible remaining`} tone={openTargets.length > 0 ? "ok" : "muted"} />
          <SummaryCard label="Selected AP total" value={gbp(targetTotal)} detail={defaultSelectedTargets.length ? `${defaultSelectedTargets.length} invoice(s) ticked by default` : "Tick invoices below"} tone={targetSelectionFits ? "ok" : "blocked"} />
          <SummaryCard label="Residual/gap" value={gbp(Math.abs(suggestedGap))} detail={suggestedGap === 0 ? "Exact split" : suggestedGap > 0 ? "Left for FX/fee/refund/hold later" : "Selected AP exceeds bank line"} tone={suggestedGap === 0 ? "ok" : suggestedGap > 0 ? "warn" : "blocked"} />
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
          <div className="grid gap-3 md:grid-cols-[1fr_180px_180px_auto] md:items-end">
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
            <button className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white" type="submit" formAction="/internal/dva-reconciliation/main-bank" formMethod="get">Apply</button>
          </div>
        </section>

        <section className="grid gap-4 xl:grid-cols-[1fr_1.2fr]">
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
            <div className="border-b border-slate-100 pb-3">
              <h2 className="text-xl font-semibold">1. Select one main bank line</h2>
              <p className="mt-1 text-sm text-slate-500">Only committed main-company-bank lines appear here. OUT lines allocate to shipper AP; IN lines will be for refund/recovery later.</p>
            </div>
            <div className="mt-4 grid gap-3">
              {lines.length === 0 ? <p className="rounded-2xl border border-dashed border-slate-300 p-6 text-center text-sm text-slate-500">No main-bank lines match this filter.</p> : null}
              {lines.map((line) => {
                const id = text(line.statement_line_id);
                return (
                  <Link
                    key={id}
                    href={href({ line_id: id, status, target_status: targetStatus, q })}
                    className={`rounded-2xl border p-4 shadow-sm ${selectedClass(id === activeLineId)}`}
                  >
                    <div className="flex items-start justify-between gap-3">
                      <div>
                        <p className="text-lg font-bold text-slate-950">{short(line.reference_raw, 70)}</p>
                        <p className="mt-1 text-sm text-slate-600">{text(line.statement_date)} · {text(line.direction).toUpperCase()} · {text(line.source_bank).toUpperCase()}</p>
                      </div>
                      <span className="rounded-full bg-slate-100 px-3 py-1 text-xs font-bold text-slate-700">{text(line.match_status)}</span>
                    </div>
                    <div className="mt-3 grid gap-2 text-sm text-slate-700 sm:grid-cols-3">
                      <p>Amount <span className="font-bold text-slate-950">{gbp(line.amount_gbp)}</span></p>
                      <p>Allocated <span className="font-bold text-slate-950">{gbp(line.allocated_gbp)}</span></p>
                      <p>Remaining <span className="font-bold text-slate-950">{gbp(line.remaining_gbp)}</span></p>
                    </div>
                  </Link>
                );
              })}
            </div>
          </div>

          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
            <div className="border-b border-slate-100 pb-3">
              <h2 className="text-xl font-semibold">2. Tick shipper AP invoice(s)</h2>
              <p className="mt-1 text-sm text-slate-500">One bank OUT line can cover one or more posted shipper AP invoices for the same shipper/Sage contact. Untick any invoice that does not belong to this payment.</p>
            </div>
            <div className="mt-4 grid gap-3">
              {targets.length === 0 ? <p className="rounded-2xl border border-dashed border-slate-300 p-6 text-center text-sm text-slate-500">No posted shipper AP targets match this filter.</p> : null}
              {targets.map((target) => {
                const id = targetCheckboxValue(target);
                const defaultChecked = defaultSelectedTargets.some((row) => targetCheckboxValue(row) === id) && targetSelectionFits;
                return (
                  <label
                    key={id}
                    className={`block cursor-pointer rounded-2xl border p-4 shadow-sm transition hover:border-sky-300 hover:bg-sky-50 ${defaultChecked ? "border-sky-300 bg-sky-50" : "border-slate-200 bg-white"}`}
                  >
                    <div className="flex items-start gap-3">
                      <input
                        className="mt-1 h-4 w-4 rounded border-slate-300"
                        type="checkbox"
                        name="shipping_document_id"
                        value={id}
                        defaultChecked={defaultChecked}
                      />
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
            </div>
          </div>
        </section>

        <section className="grid gap-3 lg:grid-cols-4">
          <div className={`rounded-3xl border p-4 shadow-sm ${toneClass("muted")}`}>
            <p className="text-xs font-bold uppercase tracking-wide opacity-70">FX/card difference</p>
            <p className="mt-2 text-sm leading-6">Visible as a residual/gap for now. Posting to FX gain/loss needs the separate GL/bank endpoint proof before it is enabled.</p>
          </div>
          <div className={`rounded-3xl border p-4 shadow-sm ${toneClass("muted")}`}>
            <p className="text-xs font-bold uppercase tracking-wide opacity-70">Bank fee</p>
            <p className="mt-2 text-sm leading-6">Keep fees separate from shipper AP payment. Bank fee posting remains disabled until the endpoint is proven.</p>
          </div>
          <div className={`rounded-3xl border p-4 shadow-sm ${toneClass("muted")}`}>
            <p className="text-xs font-bold uppercase tracking-wide opacity-70">Shipper refund / credit</p>
            <p className="mt-2 text-sm leading-6">Main-bank IN refunds/credits require their own shipper recovery target before cash posting. Not mixed into AP payment.</p>
          </div>
          <div className={`rounded-3xl border p-4 shadow-sm ${toneClass("warn")}`}>
            <p className="text-xs font-bold uppercase tracking-wide opacity-70">Hold / unmatched</p>
            <p className="mt-2 text-sm leading-6">If the bank line does not equal the selected AP invoices, leave the difference unposted until allocated to FX, fee, refund, or hold.</p>
          </div>
        </section>

        <section className="sticky bottom-4 z-20 rounded-3xl border border-slate-300 bg-white p-4 shadow-2xl">
          <input type="hidden" name="dva_statement_line_id" value={activeLineId} />
          <div className="grid gap-3 lg:grid-cols-[1fr_1fr_180px_auto] lg:items-end">
            <div>
              <p className="text-xs font-bold uppercase tracking-wide text-slate-500">Selected main bank line</p>
              <p className="mt-1 truncate text-sm font-semibold text-slate-950">{selectedLine ? `${short(selectedLine.reference_raw, 70)} · ${gbp(lineRemaining)}` : "None selected"}</p>
            </div>
            <div>
              <p className="text-xs font-bold uppercase tracking-wide text-slate-500">Default selected AP total</p>
              <p className="mt-1 truncate text-sm font-semibold text-slate-950">{defaultSelectedTargets.length} invoice(s) · {gbp(targetTotal)}</p>
            </div>
            <label className="grid gap-1 text-xs font-bold uppercase tracking-wide text-slate-500">
              One-invoice override
              <input className="rounded-xl border border-slate-300 px-3 py-2 text-sm font-normal normal-case tracking-normal text-slate-950" name="allocated_gbp_amount" placeholder="Only for one invoice" />
            </label>
            <button disabled={!activeLineId || openTargets.length === 0 || !targetSelectionFits} className="rounded-xl bg-emerald-700 px-4 py-2 text-sm font-bold text-white disabled:bg-slate-200 disabled:text-slate-500" type="submit">
              Confirm selected allocations
            </button>
            <input className="lg:col-span-4 rounded-xl border border-slate-300 px-3 py-2 text-sm" name="notes" placeholder="Optional allocation note" defaultValue="Main bank payment matched to posted shipper AP invoice(s)." />
          </div>
          {!targetSelectionFits ? (
            <p className="mt-3 rounded-2xl border border-rose-200 bg-rose-50 p-3 text-sm font-semibold text-rose-900">
              Default selected shipper AP total exceeds the selected bank line. Untick invoices or select a different bank line before confirming.
            </p>
          ) : null}
        </section>
      </form>
    </main>
  );
}
