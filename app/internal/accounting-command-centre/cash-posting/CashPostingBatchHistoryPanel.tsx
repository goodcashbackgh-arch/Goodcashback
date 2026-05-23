import Link from "next/link";
import { createClient } from "@/utils/supabase/server";

type Row = Record<string, unknown>;

const money = new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" });

function text(value: unknown) {
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return "";
}

function amount(value: unknown) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim()) return Number(value) || 0;
  return 0;
}

export default async function CashPostingBatchHistoryPanel() {
  const supabase = await createClient();
  const { data, error } = await (supabase as any).rpc("internal_cash_posting_batch_history_v1", { p_limit: 20 });
  const rows = (data ?? []) as Row[];

  return (
    <section className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
      <p className="text-xs font-bold uppercase tracking-[0.2em] text-violet-500">Cash batch history</p>
      <h2 className="mt-1 text-xl font-semibold">Validated cash batches</h2>
      <p className="mt-1 text-sm leading-5 text-slate-600">Open a batch to inspect the frozen payload, statement line, order ref, Sage contact and Sage bank target before posting.</p>
      {error ? <p className="mt-3 rounded-2xl border border-amber-200 bg-amber-50 p-3 text-sm font-semibold text-amber-900">Cash batch history unavailable: {error.message}</p> : null}
      <div className="mt-3 overflow-x-auto">
        <table className="min-w-[760px] divide-y divide-slate-200 text-xs">
          <thead className="bg-slate-100 text-[10px] uppercase tracking-wide text-slate-500">
            <tr>
              <th className="px-2 py-2 text-left">Batch</th>
              <th className="px-2 py-2 text-left">Status</th>
              <th className="px-2 py-2 text-right">Rows</th>
              <th className="px-2 py-2 text-right">Value</th>
              <th className="px-2 py-2 text-left">Created</th>
              <th className="px-2 py-2 text-left">Action</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-100 bg-white">
            {rows.length === 0 ? (
              <tr><td colSpan={6} className="px-3 py-5 text-center text-sm text-slate-500">No cash batches yet.</td></tr>
            ) : rows.map((row) => {
              const href = text(row.detail_href) || `/internal/accounting-command-centre/cash-posting/batches/${text(row.batch_id)}`;
              return (
                <tr key={text(row.batch_id)}>
                  <td className="px-2 py-2"><Link href={href} className="font-mono text-[11px] font-bold text-sky-700 underline">{text(row.batch_ref)}</Link></td>
                  <td className="px-2 py-2 font-bold text-emerald-800">{text(row.batch_status).replaceAll("_", " ")}</td>
                  <td className="px-2 py-2 text-right font-bold">{text(row.row_count) || "0"}</td>
                  <td className="px-2 py-2 text-right font-bold">{money.format(amount(row.total_amount_gbp))}</td>
                  <td className="px-2 py-2 text-slate-600">{text(row.created_at)}</td>
                  <td className="px-2 py-2"><Link href={href} className="rounded-lg border border-slate-300 bg-white px-2 py-1 text-[11px] font-bold text-slate-800">Open</Link></td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </section>
  );
}
