import { createClient } from "@/utils/supabase/server";

type Row = Record<string, unknown>;

type Props = {
  searchQuery?: string;
  categoryFilter?: string;
};

const gbpFormatter = new Intl.NumberFormat("en-GB", {
  style: "currency",
  currency: "GBP",
  minimumFractionDigits: 2,
});

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

function gbp(value: unknown) {
  return gbpFormatter.format(num(value));
}

function pretty(value: unknown) {
  const raw = text(value);
  return raw ? raw.replaceAll("_", " ") : "—";
}

function categoryTone(category: unknown) {
  const raw = text(category);
  if (raw === "bank_internal_transfer") return "border-violet-200 bg-violet-50 text-violet-950";
  if (raw === "non_cash_loyalty_customer_balance_settlement") return "border-sky-200 bg-sky-50 text-sky-950";
  if (raw === "released_unused_loyalty_control_balance") return "border-amber-200 bg-amber-50 text-amber-950";
  return "border-slate-200 bg-slate-50 text-slate-950";
}

function categoryLabel(category: unknown) {
  const raw = text(category);
  if (raw === "bank_internal_transfer") return "Bank internal transfer";
  if (raw === "non_cash_loyalty_customer_balance_settlement") return "Non-cash loyalty settlement";
  if (raw === "released_unused_loyalty_control_balance") return "Released unused loyalty";
  return pretty(raw);
}

function rowKey(row: Row) {
  return text(row.queue_row_id) || text(row.source_id) || `${text(row.order_ref)}-${text(row.amount_gbp)}-${text(row.category)}`;
}

export default async function LoyaltyAccountingControlPanel({ searchQuery = "", categoryFilter = "all" }: Props) {
  const supabase = await createClient();
  const cleanSearch = searchQuery.trim() || null;
  const { data, error } = await (supabase as any).rpc("internal_loyalty_accounting_control_rows_v1", {
    p_search: cleanSearch,
    p_limit: 300,
    p_offset: 0,
  });

  const allRows = ((data ?? []) as Row[]);
  const rows = categoryFilter && categoryFilter !== "all"
    ? allRows.filter((row) => text(row.category) === categoryFilter)
    : allRows;
  const totalCount = rows.length;
  const totalAmount = rows.reduce((sum, row) => sum + num(row.amount_gbp), 0);
  const bankTransferCount = rows.filter((row) => text(row.category) === "bank_internal_transfer").length;
  const settlementCount = rows.filter((row) => text(row.category) === "non_cash_loyalty_customer_balance_settlement").length;
  const unusedCount = rows.filter((row) => text(row.category) === "released_unused_loyalty_control_balance").length;

  return (
    <section className="rounded-3xl border border-violet-200 bg-white p-5 shadow-sm">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <p className="text-sm font-medium uppercase tracking-[0.18em] text-violet-500">Read-only loyalty accounting controls</p>
          <h2 className="mt-2 text-xl font-semibold text-slate-950">Completion loyalty control rows</h2>
          <p className="mt-2 max-w-5xl text-sm leading-6 text-slate-600">
            These rows expose the accounting meaning of completion loyalty without adding them to the cash freeze/post grid. They are control evidence only until Sage mappings and posting endpoints are deliberately locked.
          </p>
        </div>
        <div className="rounded-2xl bg-violet-50 px-4 py-3 text-sm font-semibold text-violet-900 ring-1 ring-violet-200">
          {totalCount} shown · {gbp(totalAmount)}
        </div>
      </div>

      {(cleanSearch || categoryFilter !== "all") ? (
        <div className="mt-4 rounded-2xl border border-slate-200 bg-slate-50 px-4 py-3 text-sm text-slate-700">
          Filtered by {cleanSearch ? <span className="font-semibold">search “{cleanSearch}”</span> : <span className="font-semibold">all search terms</span>}
          {categoryFilter !== "all" ? <> · category <span className="font-semibold">{categoryLabel(categoryFilter)}</span></> : null}
        </div>
      ) : null}

      {error ? (
        <div className="mt-4 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm font-semibold text-amber-900">
          Loyalty accounting control RPC unavailable: {error.message}. Run the completion-loyalty pairing/accounting migration before testing this panel.
        </div>
      ) : null}

      <div className="mt-5 grid gap-3 sm:grid-cols-3">
        <div className="rounded-2xl border border-violet-200 bg-violet-50 p-4 text-violet-950">
          <p className="text-xs font-bold uppercase tracking-wide opacity-70">Bank internal transfer</p>
          <p className="mt-2 text-2xl font-extrabold">{bankTransferCount}</p>
          <p className="mt-1 text-xs leading-5 opacity-80">Dr DVA/card/virtual-card bank; Cr main bank. Not customer funding.</p>
        </div>
        <div className="rounded-2xl border border-sky-200 bg-sky-50 p-4 text-sky-950">
          <p className="text-xs font-bold uppercase tracking-wide opacity-70">Non-cash settlement</p>
          <p className="mt-2 text-2xl font-extrabold">{settlementCount}</p>
          <p className="mt-1 text-xs leading-5 opacity-80">Loyalty applied to an order balance. This is where customer balance is settled.</p>
        </div>
        <div className="rounded-2xl border border-amber-200 bg-amber-50 p-4 text-amber-950">
          <p className="text-xs font-bold uppercase tracking-wide opacity-70">Released unused loyalty</p>
          <p className="mt-2 text-2xl font-extrabold">{unusedCount}</p>
          <p className="mt-1 text-xs leading-5 opacity-80">Control balance only in MVP. No automatic P&amp;L accrual/posting.</p>
        </div>
      </div>

      <div className="mt-5 space-y-2 md:hidden">
        {rows.length === 0 ? (
          <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4 text-center text-sm text-slate-500">
            No completion-loyalty accounting control rows match the current filters.
          </div>
        ) : rows.map((row) => (
          <details key={rowKey(row)} className="group rounded-2xl border border-slate-200 bg-white shadow-sm open:bg-slate-50">
            <summary className="flex cursor-pointer list-none items-start justify-between gap-3 p-3">
              <div className="min-w-0">
                <p className="truncate font-bold text-slate-950">{text(row.order_ref) || "—"}</p>
                <p className="mt-1 truncate text-xs text-slate-500">{text(row.importer_name) || "Importer/customer"}</p>
                <span className={`mt-2 inline-flex rounded-full border px-2 py-1 text-[10px] font-bold ${categoryTone(row.category)}`}>
                  {categoryLabel(row.category)}
                </span>
              </div>
              <div className="shrink-0 text-right">
                <p className="text-sm font-extrabold text-slate-950">{gbp(row.amount_gbp)}</p>
                <p className="mt-1 text-[11px] font-semibold text-slate-500">Details ▾</p>
              </div>
            </summary>
            <div className="border-t border-slate-200 px-3 pb-3 pt-2 text-sm text-slate-700">
              {text(row.blocker) ? <p className="mb-2 font-semibold text-rose-700">{text(row.blocker)}</p> : null}
              <p><span className="font-semibold text-slate-950">Control:</span> {pretty(row.control_status)}</p>
              <p className="mt-1"><span className="font-semibold text-slate-950">Treatment:</span> {text(row.accounting_treatment) || "—"}</p>
              <div className="mt-3">
                <span className="rounded-full border border-slate-200 bg-white px-2 py-1 text-[11px] font-bold text-slate-700">
                  Read-only · not selectable
                </span>
              </div>
            </div>
          </details>
        ))}
      </div>

      <div className="mt-5 hidden overflow-x-auto rounded-2xl border border-slate-200 md:block">
        <table className="min-w-[980px] divide-y divide-slate-200 text-xs">
          <thead className="bg-slate-100 text-[11px] uppercase tracking-wide text-slate-500">
            <tr>
              <th className="px-3 py-2 text-left">Category</th>
              <th className="px-3 py-2 text-left">Order / importer</th>
              <th className="px-3 py-2 text-right">Amount</th>
              <th className="px-3 py-2 text-left">Control status</th>
              <th className="px-3 py-2 text-left">Accounting treatment</th>
              <th className="px-3 py-2 text-left">Posting gate</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-100 bg-white">
            {rows.length === 0 ? (
              <tr>
                <td colSpan={6} className="px-3 py-6 text-center text-sm text-slate-500">
                  No completion-loyalty accounting control rows match the current filters.
                </td>
              </tr>
            ) : rows.map((row) => (
              <tr key={rowKey(row)} className="align-top hover:bg-slate-50">
                <td className="px-3 py-3">
                  <span className={`inline-flex rounded-full border px-2 py-1 text-[11px] font-bold ${categoryTone(row.category)}`}>
                    {categoryLabel(row.category)}
                  </span>
                </td>
                <td className="px-3 py-3">
                  <p className="font-bold text-slate-950">{text(row.order_ref) || "—"}</p>
                  <p className="mt-1 text-slate-500">{text(row.importer_name) || "Importer/customer"}</p>
                  {text(row.blocker) ? <p className="mt-1 font-semibold text-rose-700">{text(row.blocker)}</p> : null}
                </td>
                <td className="px-3 py-3 text-right font-bold text-slate-950">{gbp(row.amount_gbp)}</td>
                <td className="px-3 py-3 text-slate-700">{pretty(row.control_status)}</td>
                <td className="px-3 py-3 text-slate-700">{text(row.accounting_treatment) || "—"}</td>
                <td className="px-3 py-3">
                  <span className="rounded-full border border-slate-200 bg-slate-50 px-2 py-1 text-[11px] font-bold text-slate-700">
                    Read-only · not selectable
                  </span>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  );
}
