import Link from "next/link";
import { createClient } from "@/utils/supabase/server";

type Row = Record<string, unknown>;

const money = new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" });

function text(value: unknown) {
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

function pretty(value: unknown) {
  return text(value).replaceAll("_", " ") || "—";
}

function toneClass(status: unknown) {
  const raw = text(status);
  if (["draft", "validated", "posted"].includes(raw)) return "border-emerald-200 bg-emerald-50 text-emerald-900";
  if (["posting"].includes(raw)) return "border-amber-200 bg-amber-50 text-amber-900";
  if (["failed", "partial_success"].includes(raw)) return "border-rose-200 bg-rose-50 text-rose-900";
  return "border-slate-200 bg-slate-50 text-slate-700";
}

function isCancelledOrSuperseded(row: Row) {
  const status = text(row.status).toLowerCase();
  const batchStatus = text(row.batch_status).toLowerCase();
  const batchStatusField = text(row.batch_status_field).toLowerCase();

  return status === "cancelled"
    || status === "superseded"
    || batchStatus === "cancelled"
    || batchStatus === "superseded"
    || batchStatusField === "cancelled"
    || batchStatusField === "superseded";
}

export default async function PostingBatchHistoryPanel() {
  const supabase = await createClient();
  const { data, error } = await (supabase as any).rpc("internal_sage_posting_batch_history_v1", { p_limit: 30 });
  const rows = ((data ?? []) as Row[]).filter((row) => !isCancelledOrSuperseded(row));

  return (
    <section className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
      <div className="flex flex-col gap-2 lg:flex-row lg:items-center lg:justify-between">
        <div>
          <p className="text-xs font-bold uppercase tracking-[0.2em] text-violet-500">Posting batch history</p>
          <h2 className="mt-1 text-xl font-semibold">Recent active batches</h2>
          <p className="mt-1 text-sm leading-5 text-slate-600">Read-only list of current local batch locks. Cancelled/superseded batches are hidden here so they do not look like work in progress. Use Queue = Cancelled/Superseded or All documents in the grid only when you need audit history or refreeze pointers.</p>
        </div>
        <Link href="/internal/accounting-command-centre?queue=all" className="w-fit rounded-xl border border-slate-300 bg-white px-3 py-2 text-xs font-bold text-slate-800 hover:bg-slate-50">Open full history grid</Link>
      </div>

      {error ? <p className="mt-3 rounded-2xl border border-amber-200 bg-amber-50 p-3 text-sm font-semibold text-amber-900">Batch history unavailable: {error.message}</p> : null}

      <div className="mt-3 overflow-x-auto">
        <table className="min-w-[940px] table-fixed divide-y divide-slate-200 text-xs">
          <colgroup>
            <col className="w-[160px]" />
            <col className="w-[92px]" />
            <col className="w-[96px]" />
            <col className="w-[96px]" />
            <col className="w-[96px]" />
            <col className="w-[118px]" />
            <col className="w-[120px]" />
            <col className="w-[150px]" />
            <col className="w-[70px]" />
          </colgroup>
          <thead className="bg-slate-100 text-[10px] uppercase tracking-wide text-slate-500">
            <tr>
              <th className="px-2 py-2 text-left">Batch</th>
              <th className="px-2 py-2 text-left">Status</th>
              <th className="px-2 py-2 text-left">Lane</th>
              <th className="px-2 py-2 text-right">Value</th>
              <th className="px-2 py-2 text-right">Included</th>
              <th className="px-2 py-2 text-right">Excluded candidates</th>
              <th className="px-2 py-2 text-left">Lane mix</th>
              <th className="px-2 py-2 text-left">Created</th>
              <th className="px-2 py-2 text-left">Action</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-100 bg-white">
            {rows.length === 0 ? (
              <tr><td colSpan={9} className="px-3 py-5 text-center text-sm text-slate-500">No active posting batches.</td></tr>
            ) : rows.map((row) => {
              const href = text(row.detail_href) || `/internal/accounting-command-centre/batches/${text(row.batch_id)}`;
              return (
                <tr key={text(row.batch_id)} className="hover:bg-slate-50">
                  <td className="px-2 py-2">
                    <Link href={href} className="truncate font-mono text-[11px] font-bold text-sky-700 underline">{text(row.batch_ref)}</Link>
                    <p className="truncate text-[10px] text-slate-500">{pretty(row.batch_kind)}</p>
                  </td>
                  <td className="px-2 py-2"><span className={`inline-flex rounded-full border px-2 py-0.5 text-[10px] font-bold ${toneClass(row.status)}`}>{pretty(row.status)}</span></td>
                  <td className="px-2 py-2 font-bold text-slate-800">{pretty(row.lane)}</td>
                  <td className="px-2 py-2 text-right font-bold text-slate-950">{money.format(num(row.total_amount_gbp))}</td>
                  <td className="px-2 py-2 text-right font-bold text-emerald-800">{text(row.included_count) || "0"}</td>
                  <td className="px-2 py-2 text-right font-bold text-amber-800">{text(row.excluded_count) || "0"}</td>
                  <td className="px-2 py-2 text-slate-600"><b>CS</b> {text(row.customer_sales_count) || "0"} · <b>AP</b> {text(row.shipper_ap_count) || "0"}</td>
                  <td className="px-2 py-2"><p className="truncate text-slate-700">{text(row.created_at)}</p><p className="truncate text-[10px] text-slate-500">{text(row.created_by_name)}</p></td>
                  <td className="px-2 py-2"><Link href={href} className="rounded-lg border border-slate-300 bg-white px-2 py-1 text-[11px] font-bold text-slate-800 hover:bg-slate-50">Open</Link></td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </section>
  );
}
