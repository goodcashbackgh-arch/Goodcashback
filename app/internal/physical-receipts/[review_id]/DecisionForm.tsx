"use client";

import { useMemo, useState } from "react";
import { decidePhysicalReceiptReviewAction } from "./actions";

type RemedyType = "refund" | "replacement" | "hold_investigate" | "no_action";
type Decision = "approve_existing_exception" | "approve_investigation" | "close_no_action" | "return_for_information" | "reject";
type SupplierCostMode = "not_applicable" | "free_replacement" | "charged_repurchase" | "pending_supplier_evidence";

type Proposal = {
  id: string;
  proposed_remedy_type: string;
  proposed_remedy_qty: number | string;
};

type DecisionRow = {
  remedy_allocation_id: string;
  approved_remedy_type: RemedyType;
  approved_remedy_qty: number;
  supplier_cost_mode: SupplierCostMode;
};

function allTypes(proposals: Proposal[], allowed: RemedyType[]) {
  return proposals.length > 0 && proposals.every((proposal) => allowed.includes(proposal.proposed_remedy_type as RemedyType));
}

function initialDecision(proposals: Proposal[]): Decision {
  if (allTypes(proposals, ["refund", "replacement"])) return "approve_existing_exception";
  if (allTypes(proposals, ["hold_investigate"])) return "approve_investigation";
  if (allTypes(proposals, ["no_action"])) return "close_no_action";
  return "return_for_information";
}

function rowForDecision(proposal: Proposal, decision: Decision): DecisionRow | null {
  const proposedType = proposal.proposed_remedy_type as RemedyType;

  if (decision === "approve_existing_exception") {
    if (proposedType !== "refund" && proposedType !== "replacement") return null;
    return {
      remedy_allocation_id: proposal.id,
      approved_remedy_type: proposedType,
      approved_remedy_qty: Number(proposal.proposed_remedy_qty),
      supplier_cost_mode: proposedType === "replacement" ? "pending_supplier_evidence" : "not_applicable",
    };
  }

  if (decision === "approve_investigation") {
    return {
      remedy_allocation_id: proposal.id,
      approved_remedy_type: "hold_investigate",
      approved_remedy_qty: Number(proposal.proposed_remedy_qty),
      supplier_cost_mode: "not_applicable",
    };
  }

  if (decision === "close_no_action") {
    return {
      remedy_allocation_id: proposal.id,
      approved_remedy_type: "no_action",
      approved_remedy_qty: Number(proposal.proposed_remedy_qty),
      supplier_cost_mode: "not_applicable",
    };
  }

  return null;
}

function rowsForDecision(proposals: Proposal[], decision: Decision) {
  return proposals.map((proposal) => rowForDecision(proposal, decision)).filter((row): row is DecisionRow => row !== null);
}

export default function DecisionForm({ reviewId, proposals, disabled }: { reviewId: string; proposals: Proposal[]; disabled?: boolean }) {
  const canApproveExisting = allTypes(proposals, ["refund", "replacement"]);
  const startingDecision = initialDecision(proposals);
  const [decision, setDecision] = useState<Decision>(startingDecision);
  const [rows, setRows] = useState<DecisionRow[]>(rowsForDecision(proposals, startingDecision));
  const [liableParty, setLiableParty] = useState(startingDecision === "close_no_action" ? "no_liability" : "retailer");

  const allocationDecision = !["return_for_information", "reject"].includes(decision);
  const allowedTypes: RemedyType[] = decision === "approve_investigation"
    ? ["hold_investigate"]
    : decision === "close_no_action"
      ? ["no_action"]
      : ["refund", "replacement"];

  const invalid = useMemo(() => {
    if (!allocationDecision) return false;
    if (rows.length !== proposals.length) return true;
    if (decision === "approve_existing_exception" && !canApproveExisting) return true;
    if (decision === "close_no_action" && liableParty !== "no_liability") return true;
    if (decision === "approve_existing_exception" && liableParty === "no_liability") return true;
    return rows.some((row, index) => {
      const proposed = Number(proposals[index]?.proposed_remedy_qty ?? 0);
      return !allowedTypes.includes(row.approved_remedy_type)
        || !Number.isInteger(row.approved_remedy_qty)
        || row.approved_remedy_qty <= 0
        || row.approved_remedy_qty > proposed
        || (row.approved_remedy_type === "replacement" && row.supplier_cost_mode === "not_applicable")
        || (row.approved_remedy_type !== "replacement" && row.supplier_cost_mode !== "not_applicable");
    });
  }, [allocationDecision, allowedTypes, canApproveExisting, decision, liableParty, proposals, rows]);

  function changeDecision(next: Decision) {
    if (next === "approve_existing_exception" && !canApproveExisting) return;
    setDecision(next);
    setRows(rowsForDecision(proposals, next));
    if (next === "close_no_action") setLiableParty("no_liability");
    else if (liableParty === "no_liability") setLiableParty("unknown");
  }

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
      <select name="decision" value={decision} onChange={(event) => changeDecision(event.target.value as Decision)} disabled={disabled} className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2">
        <option value="approve_existing_exception" disabled={!canApproveExisting}>Approve existing exception route</option>
        <option value="approve_investigation">Approve investigation</option>
        <option value="close_no_action">Close — no action</option>
        <option value="return_for_information">Return for information</option>
        <option value="reject">Reject</option>
      </select>
    </label>

    {!canApproveExisting ? <p className="rounded-xl bg-amber-50 p-3 text-sm text-amber-900">Approve existing exception is unavailable because at least one importer proposal is hold/investigate or no action. Choose an explicit compatible decision or return the review for correction.</p> : null}

    {allocationDecision ? <div className="space-y-3">
      {rows.map((row, index) => <div key={row.remedy_allocation_id} className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
        <div className="text-sm text-slate-600">Importer proposed {proposals[index]?.proposed_remedy_type.replaceAll("_", " ")} · {Number(proposals[index]?.proposed_remedy_qty)}</div>
        <div className="mt-3 grid gap-3 md:grid-cols-3">
          <select disabled={disabled || allowedTypes.length === 1} value={row.approved_remedy_type} onChange={(event) => update(row.remedy_allocation_id, { approved_remedy_type: event.target.value as RemedyType })} className="rounded-lg border border-slate-300 bg-white px-3 py-2 disabled:bg-slate-100">
            {allowedTypes.includes("refund") ? <option value="refund">Refund</option> : null}
            {allowedTypes.includes("replacement") ? <option value="replacement">Replacement</option> : null}
            {allowedTypes.includes("hold_investigate") ? <option value="hold_investigate">Hold / investigate</option> : null}
            {allowedTypes.includes("no_action") ? <option value="no_action">No action</option> : null}
          </select>
          <input disabled={disabled} type="number" min="1" step="1" inputMode="numeric" value={row.approved_remedy_qty} onChange={(event) => update(row.remedy_allocation_id, { approved_remedy_qty: Number(event.target.value) })} className="rounded-lg border border-slate-300 bg-white px-3 py-2" />
          <select disabled={disabled || row.approved_remedy_type !== "replacement"} value={row.supplier_cost_mode} onChange={(event) => update(row.remedy_allocation_id, { supplier_cost_mode: event.target.value as SupplierCostMode })} className="rounded-lg border border-slate-300 bg-white px-3 py-2 disabled:bg-slate-100">
            {row.approved_remedy_type !== "replacement" ? <option value="not_applicable">Not applicable</option> : null}
            <option value="free_replacement">Free replacement</option>
            <option value="charged_repurchase">Charged repurchase</option>
            <option value="pending_supplier_evidence">Pending supplier evidence</option>
          </select>
        </div>
      </div>)}
      <p className="text-sm text-amber-800">Every physical remedy quantity must be a whole unit. A changed split must be returned to the importer; it cannot be invented here.</p>
    </div> : null}

    <label className="block"><span className="text-sm font-semibold">Liable party</span>
      <select name="liable_party" value={liableParty} onChange={(event) => setLiableParty(event.target.value)} disabled={disabled || decision === "close_no_action" || decision === "return_for_information" || decision === "reject"} className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 disabled:bg-slate-100">
        <option value="retailer">Retailer</option><option value="shipper">Shipper</option><option value="unknown">Unknown</option><option value="no_liability">No liability</option>
      </select>
    </label>
    <label className="block"><span className="text-sm font-semibold">Decision note</span><textarea name="decision_note" required disabled={disabled} rows={4} className="mt-1 w-full rounded-xl border border-slate-300 px-3 py-2 disabled:bg-slate-100" /></label>
    <button disabled={disabled || invalid} className="rounded-full bg-slate-950 px-5 py-2.5 font-semibold text-white disabled:opacity-40">Record supervisor decision</button>
  </form>;
}
