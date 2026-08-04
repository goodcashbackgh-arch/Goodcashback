"use client";

import { useMemo, useState } from "react";
import { decidePhysicalOutcomeLaneAction } from "./actions";

type OutcomeType = "refund" | "replacement";

type LaneItem = {
  physical_remedy_allocation_id: string;
  approved_remedy_qty: number | string | null;
  customer_commercial_value_gbp: number | string | null;
  dispute_status: string | null;
  line_status: string | null;
};

export default function OutcomeLaneDecisionForm({
  reviewId,
  laneId,
  staffId,
  outcomeType,
  items,
  disabled,
}: {
  reviewId: string;
  laneId: string;
  staffId: string;
  outcomeType: OutcomeType;
  items: LaneItem[];
  disabled?: boolean;
}) {
  const [confirmed, setConfirmed] = useState(false);
  const allocationIds = useMemo(
    () => items.map((item) => item.physical_remedy_allocation_id),
    [items],
  );
  const totalQuantity = items.reduce((sum, item) => sum + Number(item.approved_remedy_qty ?? 0), 0);
  const totalValue = items.reduce((sum, item) => sum + Number(item.customer_commercial_value_gbp ?? 0), 0);
  const label = outcomeType === "refund"
    ? "Settle grouped refund to credit balance"
    : "Accept grouped same-order free replacement";

  return <form action={decidePhysicalOutcomeLaneAction} className="space-y-4">
    <input type="hidden" name="review_id" value={reviewId} />
    <input type="hidden" name="lane_id" value={laneId} />
    <input type="hidden" name="staff_id" value={staffId} />
    <input type="hidden" name="outcome_type" value={outcomeType} />
    <input type="hidden" name="allocation_ids_json" value={JSON.stringify(allocationIds)} />

    <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-700">
      <div><strong>{items.length}</strong> grouped item{items.length === 1 ? "" : "s"} · quantity <strong>{totalQuantity}</strong></div>
      {outcomeType === "refund" ? <div className="mt-1">Recorded customer value: <strong>£{totalValue.toFixed(2)}</strong>. Final settlement remains controlled by the existing credit-balance authority.</div> : <div className="mt-1">Replacement remains on the original order through the existing free-replacement authority.</div>}
    </div>

    <label className="block">
      <span className="text-sm font-semibold">Supervisor note</span>
      <textarea name="note" required disabled={disabled} rows={4} className="mt-1 w-full rounded-xl border border-slate-300 px-3 py-2 disabled:bg-slate-100" />
    </label>

    <label className="flex items-start gap-3 rounded-xl border border-slate-200 p-3 text-sm text-slate-700">
      <input type="checkbox" checked={confirmed} onChange={(event) => setConfirmed(event.target.checked)} disabled={disabled} className="mt-0.5" />
      <span>I confirm this one grouped action applies to every item shown in this lane.</span>
    </label>

    <button disabled={disabled || !confirmed || items.length === 0} className="rounded-full bg-slate-950 px-5 py-2.5 font-semibold text-white disabled:opacity-40">
      {label}
    </button>
  </form>;
}
