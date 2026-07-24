"use client";

import { usePathname } from "next/navigation";

type SettlementRow = {
  order_id: string;
  order_ref: string | null;
  credit_added_to_account_gbp: number | string | null;
  other_settlement_adjustment_gbp: number | string | null;
  potential_additional_credit_gbp: number | string | null;
  resolution_status: string | null;
};

function amount(value: number | string | null | undefined) {
  const parsed = Number(value ?? 0);
  return Number.isFinite(parsed) ? Math.max(parsed, 0) : 0;
}

function money(value: number) {
  return new Intl.NumberFormat("en-GB", {
    style: "currency",
    currency: "GBP",
    minimumFractionDigits: 2,
  }).format(value);
}

export default function SettlementImporterSummary({ rows }: { rows: SettlementRow[] }) {
  const pathname = usePathname();
  if (pathname !== "/importer") return null;

  const visibleRows = rows.filter((row) =>
    amount(row.credit_added_to_account_gbp) > 0.01
    || amount(row.other_settlement_adjustment_gbp) > 0.01
    || amount(row.potential_additional_credit_gbp) > 0.01
  );

  if (visibleRows.length === 0) return null;

  return (
    <div className="bg-slate-50 px-4 pt-4 md:px-6 md:pt-6">
      <section className="rounded-3xl border border-cyan-100 bg-white p-4 shadow-sm md:p-5">
        <h2 className="text-lg font-semibold text-slate-950">Settlement position</h2>
        <p className="mt-1 text-sm text-slate-600">Supervisor-controlled credit and settlement adjustments. No importer action is required.</p>
        <div className="mt-4 grid gap-3">
          {visibleRows.map((row) => {
            const credit = amount(row.credit_added_to_account_gbp);
            const adjustment = amount(row.other_settlement_adjustment_gbp);
            const pending = amount(row.potential_additional_credit_gbp);
            return (
              <article key={row.order_id} className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
                <div className="flex flex-wrap items-start justify-between gap-2">
                  <p className="font-semibold text-slate-950">{row.order_ref ?? row.order_id}</p>
                  <span className={`rounded-full px-3 py-1 text-xs font-semibold ${pending > 0.01 ? "bg-amber-100 text-amber-900" : "bg-emerald-100 text-emerald-800"}`}>
                    {pending > 0.01 ? "Pending supervisor review" : "Fully accounted for"}
                  </span>
                </div>
                <div className="mt-3 grid grid-cols-1 gap-2 text-sm sm:grid-cols-3">
                  <div><span className="text-slate-500">Credit added</span><div className="font-semibold text-slate-950">{money(credit)}</div></div>
                  <div><span className="text-slate-500">Other settlement adjustment</span><div className="font-semibold text-slate-950">{money(adjustment)}</div></div>
                  <div><span className="text-slate-500">Pending review</span><div className="font-semibold text-slate-950">{money(pending)}</div></div>
                </div>
              </article>
            );
          })}
        </div>
      </section>
    </div>
  );
}
