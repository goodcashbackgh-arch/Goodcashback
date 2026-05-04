"use client";

import { allocateStatementLineToFxCardOrFeeAction } from "../actions";

type FxResidualAllocationFormProps = {
  canAllocate: boolean;
  statementLineId: string;
  remainingAmount: number;
  returnPath: string;
};

export default function FxResidualAllocationForm({
  canAllocate,
  statementLineId,
  remainingAmount,
  returnPath,
}: FxResidualAllocationFormProps) {
  return (
    <form action={allocateStatementLineToFxCardOrFeeAction} className="flex flex-wrap gap-2">
      <input type="hidden" name="dva_statement_line_id" value={canAllocate ? statementLineId : ""} />
      <input type="hidden" name="notes" value="Classified from DVA/card matching workspace residual." />
      <input type="hidden" name="return_path" value={returnPath} />

      <select
        className="rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm font-semibold text-slate-700 disabled:bg-slate-100 disabled:text-slate-400"
        name="allocation_type"
        defaultValue="fx_card_difference"
        disabled={!canAllocate}
      >
        <option value="fx_card_difference">FX/card diff</option>
        <option value="bank_fee">Bank fee</option>
      </select>

      <input
        className="w-28 rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm font-semibold text-slate-700 disabled:bg-slate-100 disabled:text-slate-400"
        name="allocated_gbp_amount"
        type="number"
        step="0.01"
        min="0.01"
        defaultValue={canAllocate ? remainingAmount.toFixed(2) : ""}
        placeholder="0.00"
        disabled={!canAllocate}
      />

      <button
        className={
          canAllocate
            ? "rounded-xl bg-amber-600 px-4 py-2 font-semibold text-white shadow-sm hover:bg-amber-700"
            : "rounded-xl bg-slate-200 px-4 py-2 font-semibold text-slate-500"
        }
        type="submit"
        disabled={!canAllocate}
      >
        Add FX/card residual
      </button>
    </form>
  );
}
