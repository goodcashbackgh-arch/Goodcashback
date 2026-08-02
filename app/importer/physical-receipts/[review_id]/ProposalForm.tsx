"use client";

import { useMemo, useState } from "react";
import { submitPhysicalReceiptProposalAction } from "./actions";

type Disposition = {
  id: string;
  item_description: string | null;
  disposition_type: string;
  quantity: number | string;
};

type ProposalRow = {
  key: string;
  receipt_line_disposition_id: string;
  proposed_remedy_type: "refund" | "replacement" | "hold_investigate" | "no_action";
  proposed_remedy_qty: number;
};

export default function ProposalForm({ reviewId, dispositions, disabled }: { reviewId: string; dispositions: Disposition[]; disabled?: boolean }) {
  const affected = dispositions.filter((row) => row.disposition_type !== "clean");
  const [rows, setRows] = useState<ProposalRow[]>(affected.map((row) => ({
    key: crypto.randomUUID(),
    receipt_line_disposition_id: row.id,
    proposed_remedy_type: "replacement",
    proposed_remedy_qty: Number(row.quantity),
  })));

  const limits = useMemo(() => new Map(affected.map((row) => [row.id, Number(row.quantity)])), [affected]);
  const totals = useMemo(() => {
    const map = new Map<string, number>();
    for (const row of rows) map.set(row.receipt_line_disposition_id, (map.get(row.receipt_line_disposition_id) ?? 0) + Number(row.proposed_remedy_qty || 0));
    return map;
  }, [rows]);
  const invalid = rows.length === 0 || rows.some((row) =>
    !Number.isInteger(row.proposed_remedy_qty)
    || row.proposed_remedy_qty <= 0
    || (totals.get(row.receipt_line_disposition_id) ?? 0) > (limits.get(row.receipt_line_disposition_id) ?? 0)
  );

  function update(key: string, patch: Partial<ProposalRow>) {
    setRows((current) => current.map((row) => row.key === key ? { ...row, ...patch } : row));
  }

  function addRow(dispositionId: string) {
    setRows((current) => [...current, {
      key: crypto.randomUUID(),
      receipt_line_disposition_id: dispositionId,
      proposed_remedy_type: "refund",
      proposed_remedy_qty: 1,
    }]);
  }

  return (
    <form action={submitPhysicalReceiptProposalAction} className="space-y-4">
      <input type="hidden" name="review_id" value={reviewId} />
      <input type="hidden" name="proposals_json" value={JSON.stringify(rows.map(({ key: _key, ...row }) => row))} />

      <div className="space-y-3">
        {affected.map((disposition) => {
          const used = totals.get(disposition.id) ?? 0;
          const limit = limits.get(disposition.id) ?? 0;
          return (
            <section key={disposition.id} className="rounded-2xl border border-slate-200 bg-white p-4">
              <div className="flex items-start justify-between gap-3">
                <div>
                  <div className="font-semibold text-slate-950">{disposition.item_description ?? "Invoice line"}</div>
                  <div className="text-sm text-slate-600">{disposition.disposition_type.replaceAll("_", " ")} · affected {limit}</div>
                </div>
                <button type="button" disabled={disabled} onClick={() => addRow(disposition.id)} className="rounded-full border border-slate-300 px-3 py-1 text-sm font-semibold disabled:opacity-50">Add split</button>
              </div>

              <div className="mt-3 space-y-2">
                {rows.filter((row) => row.receipt_line_disposition_id === disposition.id).map((row) => (
                  <div key={row.key} className="grid gap-2 rounded-xl bg-slate-50 p-3 md:grid-cols-[1fr_140px_auto]">
                    <select disabled={disabled} value={row.proposed_remedy_type} onChange={(event) => update(row.key, { proposed_remedy_type: event.target.value as ProposalRow["proposed_remedy_type"] })} className="rounded-lg border border-slate-300 bg-white px-3 py-2">
                      <option value="refund">Refund</option>
                      <option value="replacement">Replacement</option>
                      <option value="hold_investigate">Hold / investigate</option>
                      <option value="no_action">No action</option>
                    </select>
                    <input disabled={disabled} type="number" min="1" step="1" inputMode="numeric" value={row.proposed_remedy_qty} onChange={(event) => update(row.key, { proposed_remedy_qty: Number(event.target.value) })} className="rounded-lg border border-slate-300 bg-white px-3 py-2" />
                    <button type="button" disabled={disabled || rows.filter((item) => item.receipt_line_disposition_id === disposition.id).length === 1} onClick={() => setRows((current) => current.filter((item) => item.key !== row.key))} className="rounded-lg border border-slate-300 px-3 py-2 text-sm disabled:opacity-40">Remove</button>
                  </div>
                ))}
              </div>
              <div className={`mt-2 text-sm ${used > limit || !Number.isInteger(used) ? "text-rose-700" : "text-slate-600"}`}>Proposed {used} of {limit} whole units</div>
            </section>
          );
        })}
      </div>

      <label className="block">
        <span className="text-sm font-semibold text-slate-800">Factual proposal note</span>
        <textarea name="proposal_note" required disabled={disabled} rows={4} className="mt-1 w-full rounded-xl border border-slate-300 px-3 py-2 disabled:bg-slate-100" />
      </label>

      <button disabled={disabled || invalid} className="rounded-full bg-slate-950 px-5 py-2.5 font-semibold text-white disabled:cursor-not-allowed disabled:opacity-40">Submit proposal</button>
    </form>
  );
}
