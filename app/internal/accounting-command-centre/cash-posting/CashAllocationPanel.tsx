import SelectionControls from "../SelectionControls";
import { createClient } from "@/utils/supabase/server";
import { postSelectedCashAllocationsAction } from "./actions";

type Row = Record<string, unknown>;

const gbp = new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" });

function text(v: unknown) {
  if (typeof v === "string") return v;
  if (typeof v === "number" && Number.isFinite(v)) return String(v);
  return "";
}
function num(v: unknown) {
  if (typeof v === "number" && Number.isFinite(v)) return v;
  if (typeof v === "string" && v.trim()) return Number(v) || 0;
  return 0;
}
function short(v: unknown, n = 34) {
  const s = text(v);
  return s.length > n ? `${s.slice(0, n - 1)}…` : s || "—";
}
function pill(status: string) {
  if (status === "ready") return "border-emerald-200 bg-emerald-50 text-emerald-900";
  if (status === "allocated") return "border-sky-200 bg-sky-50 text-sky-900";
  if (status === "failed") return "border-rose-200 bg-rose-50 text-rose-900";
  return "border-amber-200 bg-amber-50 text-amber-900";
}

export default async function CashAllocationPanel() {
  const supabase = await createClient();
  const { data, error } = await (supabase as any).rpc("internal_cash_allocation_workbench_rows_v1", {
    p_status: "all",
    p_category: "all",
    p_q: null,
    p_limit: 100,
  });
  const rows = (data ?? []) as Row[];
  const ready = rows.filter((r) => text(r.allocation_status) === "ready");
  const blocked = rows.filter((r) => text(r.allocation_status) === "blocked");
  const allocated = rows.filter((r) => text(r.allocation_status) === "allocated");
  const failed = rows.filter((r) => text(r.allocation_status) === "failed");
  const readyTotal = ready.reduce((s, r) => s + num(r.allocation_amount_gbp), 0);
  const live = process.env.SAGE_LIVE_CASH_ALLOCATION_ENABLED === "true";

  return (
    <section className="rounded-3xl border border-slate-200 bg-white shadow-sm">
      <div className="border-b border-slate-100 px-4 py-3">
        <p className="text-xs font-bold uppercase tracking-[0.2em] text-violet-500">Unified cash allocation</p>
        <h2 className="mt-1 text-xl font-semibold">Allocation rows</h2>
        <p className="mt-1 text-sm text-slate-500">Rows come from the internal read model so blockers are visible.</p>
        <div className="mt-3 grid gap-2 text-xs sm:grid-cols-4">
          <span className="rounded-xl border border-emerald-200 bg-emerald-50 px-3 py-2 font-bold text-emerald-900">Ready {ready.length}<br />{gbp.format(readyTotal)}</span>
          <span className="rounded-xl border border-amber-200 bg-amber-50 px-3 py-2 font-bold text-amber-900">Blocked {blocked.length}</span>
          <span className="rounded-xl border border-sky-200 bg-sky-50 px-3 py-2 font-bold text-sky-900">Allocated {allocated.length}</span>
          <span className="rounded-xl border border-rose-200 bg-rose-50 px-3 py-2 font-bold text-rose-900">Failed {failed.length}</span>
        </div>
        {error ? <p className="mt-3 rounded-2xl border border-amber-200 bg-amber-50 p-3 text-xs font-semibold text-amber-900">Run migration 20260523_cash_allocation_read_model_v1.sql. {error.message}</p> : null}
        <form action={postSelectedCashAllocationsAction} className="mt-3 space-y-3">
          <div className="flex flex-wrap items-center gap-2">
            <SelectionControls />
            <button type="submit" disabled={!live || ready.length === 0} className="rounded-lg bg-emerald-700 px-3 py-1.5 text-[11px] font-bold text-white disabled:bg-slate-200 disabled:text-slate-500">Allocate selected ready rows</button>
            <span className="rounded-lg border border-slate-200 bg-slate-50 px-3 py-1.5 text-[11px] font-bold text-slate-600">{live ? "Live flag enabled" : "Live flag disabled"}</span>
          </div>
          <div className="overflow-x-auto rounded-2xl border border-slate-100">
            <table className="min-w-[1100px] divide-y divide-slate-200 text-xs">
              <thead className="bg-slate-100 text-[10px] uppercase tracking-wide text-slate-500"><tr><th className="px-3 py-2 text-left">Select</th><th className="px-3 py-2 text-left">Status</th><th className="px-3 py-2 text-left">Order</th><th className="px-3 py-2 text-left">Counterparty</th><th className="px-3 py-2 text-left">Target</th><th className="px-3 py-2 text-right">Receipt</th><th className="px-3 py-2 text-right">Allocate</th><th className="px-3 py-2 text-right">Residual</th></tr></thead>
              <tbody className="divide-y divide-slate-100 bg-white">
                {rows.length === 0 ? <tr><td colSpan={8} className="px-3 py-6 text-center text-sm text-slate-500">No allocation rows returned.</td></tr> : rows.map((r) => {
                  const status = text(r.allocation_status) || "blocked";
                  const id = text(r.allocation_source_id) || text(r.cash_batch_row_id);
                  return <tr key={id} className="align-top"><td className="px-3 py-3">{status === "ready" ? <input type="checkbox" name="cash_allocation_row_id" value={id} defaultChecked data-accounting-row-select="true" className="h-4 w-4" /> : "—"}</td><td className="px-3 py-3"><span className={`inline-flex rounded-full border px-2 py-0.5 text-[10px] font-bold ${pill(status)}`}>{status}</span>{text(r.blocker) ? <p className="mt-1 text-[11px] text-rose-700">{short(r.blocker, 70)}</p> : null}</td><td className="px-3 py-3 font-mono font-bold">{short(r.order_ref)}</td><td className="px-3 py-3">{short(r.counterparty_name)}</td><td className="px-3 py-3 font-mono">{short(r.target_reference)}</td><td className="px-3 py-3 text-right font-bold">{gbp.format(num(r.receipt_amount_gbp))}</td><td className="px-3 py-3 text-right font-bold text-emerald-900">{gbp.format(num(r.allocation_amount_gbp))}</td><td className="px-3 py-3 text-right font-bold">{gbp.format(num(r.residual_gbp))}</td></tr>;
                })}
              </tbody>
            </table>
          </div>
        </form>
      </div>
    </section>
  );
}
