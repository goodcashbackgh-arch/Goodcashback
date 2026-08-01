"use client";

import { useMemo, useState } from "react";
import { decidePhysicalReceiptReviewAction } from "./actions";

type Proposal = {
  id: string;
  proposed_remedy_type: string;
  proposed_remedy_qty: number | string;
};

type DecisionRow = {
  remedy_allocation_id: string;
  approved_remedy_type: "refund" | "replacement" | "hold_investigate" | "no_action";
  approved_remedy_qty: number;
  supplier_cost_mode: "not_applicable" | "free_replacement" | "charged_repurchase" | "pending_supplier_evidence";
};

export default function DecisionForm({ reviewId, proposals, disabled }: { reviewId: string; proposals: Proposal[]; disabled?: boolean }) {
  const [decision, setDecision] = useState("approve_existing_exception");
  const [rows, setRows] = useState<DecisionRow[]>(proposals.map((proposal) => ({
    remedy_allocation_id: proposal.id,
    approved_remedy_type: proposal.proposed_remedy_type as DecisionRow["approved_remedy_type"],
    approved_remedy_qty: Number(proposal.proposed_remedy_qty),
    supplier_cost_mode: proposal.proposed_remedy_type === "replacement" ? "pending_supplier_evidence" : "not_applicable",
  })));

  const allocationDecision = !["return_for_information", "reject"].includes(decision);
  const invalid = useMemo(() => {
    if (!allocationDecision) return false;
    if (rows.length !== proposals.length) return true;
    return rows.some((row, index) => {
      const proposed = Number(proposals[index]?.proposed_remedy_qty ?? 0);
      const wholeRequired = ["refund", "replacement"].includes(row.approved_remedy_type);
      return row.approved_remedy_qty <= 0 || row.approved_remedy_qty > proposed || (wholeRequired && !Number.isInteger(row.approved_remedy_qty));
    });
  }, [allocationDecision, rows, proposals]);

  function update(id: string, patch: Partial<DecisionRow>) {
    setRows((current) => current.map((row) => {
      if (row.remedy_allocation_id !== id) return row;
      const next = { ...row, ...patch };
      if (patch.approved_remedy_type && patch.approved_remedy_type !== "replacement") next.supplier_cost_mode = "not_applicable";
      if (patch.approved_remedy_type === "replacement" && next.supplier_cost_mode === "not_applicable") next.supplier_cost_mode = "pending_supplier_evidence";
      return next;
    }));
  }

  return <form action={decidePhysicalReceiptReviewAction} className="space-y-4">
    <input type="hidden" name="review_id" value={reviewId} />
    <input type="hidden" name="allocations_json" value={JSON.stringify(allocationDecision ? rows : [])} />

    <label className="block"><span className="text-sm font-semibold">Decision</span>
      <select name="decision" value={decision} onChange={(event) => setDecision(event.target.value)} disabled={disabled} className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2">
        <option value="approve_existing_exception">Approve existing exception route</option>
        <option value="approve_investigation">Approve investigation</option>
        <option value="close_no_action">Close — no action</option>
        <option value="return_for_information">Return for information</option>
        <option value="reject">Reject</option>
      </select>
    </label>

    {allocationDecision ? <div className="space-y-3">
      {rows.map((row, index) => <div key={row.remedy_allocation_id} className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
        <div className="text-sm text-slate-600">Importer proposed {proposals[index]?.proposed_remedy_type.replaceAll("_", " ")} · {Number(proposals[index]?.proposed_remedy_qty)}</div>
        <div className="mt-3 grid gap-3 md:grid-cols-3">
          <select disabled={disabled} value={row.approved_remedy_type} onChange={(event) => update(row.remedy_allocation_id, { approved_remedy_type: event.target.value as DecisionRow["approved_remedy_type"] })} className="rounded-lg border border-slate-300 bg-white px-3 py-2">
            <option value="refund">Refund</option><option value="replacement">Replacement</option><option value="hold_investigate">Hold / investigate</option><option value="no_action">No action</option>
          </select>
          <input disabled={disabled} type="number" min="1" step="1" value={row.approved_remedy_qty} onChange={(event) => update(row.remedy_allocation_id, { approved_remedy_qty: Number(event.target.value) })} className="rounded-lg border border-slate-300 bg-white px-3 py-2" />
          <select disabled={disabled || row.approved_remedy_type !== "replacement"} value={row.supplier_cost_mode} onChange={(event) => update(row.remedy_allocation_id, { supplier_cost_mode: event.target.value as DecisionRow["supplier_cost_mode"] })} className="rounded-lg border border-slate-300 bg-white px-3 py-2 disabled:bg-slate-100">
            <option value="not_applicable">Not applicable</option><option value="free_replacement">Free replacement</option><option value="charged_repurchase">Charged repurchase</option><option value="pending_supplier_evidence">Pending supplier evidence</option>
          </select>
        </div>
      </div>)}
      <p className="text-sm text-amber-800">Refund and replacement quantities must be whole units. A changed split must be returned to the importer; it cannot be invented here.</p>
    </div> : null}

    <label className="block"><span className="text-sm font-semibold">Liable party</span>
      <select name="liable_party" disabled={disabled} className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2">
        <option value="retailer">Retailer</option><option value="shipper">Shipper</option><option value="unknown">Unknown</option><option value="no_liability">No liability</option>
      </select>
    </label>
    <label className="block"><span className="text-sm font-semibold">Decision note</span><textarea name="decision_note" required disabled={disabled} rows={4} className="mt-1 w-full rounded-xl border border-slate-300 px-3 py-2 disabled:bg-slate-100" /></label>
    <button disabled={disabled || invalid} className="rounded-full bg-slate-950 px-5 py-2.5 font-semibold text-white disabled:opacity-40">Record supervisor decision</button>
  </form>;
}
