"use client";

import { useMemo, useRef, useState } from "react";

type PreviewRow = {
  tracking_submission_id: string | null;
  order_id: string | null;
  order_ref: string | null;
  tracking_ref: string | null;
  supplier_invoice_line_id: string | null;
  item_description: string | null;
  qty_allocated: number | string | null;
  adjusted_net_value_gbp: number | string | null;
  suggested_category_code: string | null;
  blocker: string | null;
};

type RuleRow = {
  rule_code: string;
  label: string;
  default_factor: number | string;
  active: boolean;
};

type Props = {
  rows: PreviewRow[];
  rules: RuleRow[];
  canApprove: boolean;
  sourceCurrency: string;
  sourceTotal: number;
};

function n(value: number | string | null | undefined) {
  const parsed = Number(value ?? 0);
  return Number.isFinite(parsed) ? parsed : 0;
}

function round(value: number, places: number) {
  const factor = 10 ** places;
  return Math.round((value + Number.EPSILON) * factor) / factor;
}

function money(value: number, currency: string) {
  return new Intl.NumberFormat("en-GB", {
    style: "currency",
    currency: currency || "GBP",
  }).format(value);
}

function qty(value: number | string | null | undefined) {
  const parsed = n(value);
  return parsed % 1 === 0
    ? String(Math.trunc(parsed))
    : parsed.toFixed(3).replace(/0+$/, "").replace(/\.$/, "");
}

function friendly(value: string | null | undefined) {
  if (!value) return "—";
  return value.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase());
}

export default function LiveApportionmentPreview({
  rows,
  rules,
  canApprove,
  sourceCurrency,
  sourceTotal,
}: Props) {
  const [categoryCodes, setCategoryCodes] = useState(() =>
    rows.map((row) => row.suggested_category_code ?? "unclassified"),
  );
  const [selectedIndexes, setSelectedIndexes] = useState<Set<number>>(() => new Set());
  const [bulkCategoryCode, setBulkCategoryCode] = useState("");
  const [bulkReason, setBulkReason] = useState("");
  const [bulkError, setBulkError] = useState<string | null>(null);
  const overrideReasonRefs = useRef<Array<HTMLInputElement | null>>([]);
  const bulkReasonIndexesRef = useRef<Set<number>>(new Set());

  const ruleMap = useMemo(
    () => new Map(rules.map((rule) => [rule.rule_code, n(rule.default_factor)])),
    [rules],
  );

  const calculated = useMemo(() => {
    const weightedRows = rows.map((row, index) => {
      const factor = ruleMap.get(categoryCodes[index]) ?? 1;
      const weightedBasis = round(n(row.adjusted_net_value_gbp) * factor, 4);
      return { factor, weightedBasis };
    });

    const totalWeightedBasis = weightedRows.reduce(
      (sum, row, index) => sum + (rows[index].blocker ? 0 : row.weightedBasis),
      0,
    );

    const roughAmounts = weightedRows.map((row, index) =>
      rows[index].blocker || totalWeightedBasis <= 0
        ? 0
        : round((sourceTotal * row.weightedBasis) / totalWeightedBasis, 2),
    );

    const eligibleIndexes = weightedRows
      .map((row, index) => ({ index, weightedBasis: row.weightedBasis, description: rows[index].item_description ?? "" }))
      .filter(({ index }) => !rows[index].blocker)
      .sort((a, b) => b.weightedBasis - a.weightedBasis || a.description.localeCompare(b.description));

    if (eligibleIndexes.length > 0) {
      const balancingIndex = eligibleIndexes[0].index;
      const otherTotal = roughAmounts.reduce(
        (sum, amount, index) => (index === balancingIndex ? sum : sum + amount),
        0,
      );
      roughAmounts[balancingIndex] = round(sourceTotal - otherTotal, 2);
    }

    return {
      rows: weightedRows.map((row, index) => ({
        ...row,
        allocatedAmount: roughAmounts[index],
      })),
      totalWeightedBasis,
      previewTotal: roughAmounts.reduce((sum, amount) => sum + amount, 0),
    };
  }, [categoryCodes, rows, ruleMap, sourceTotal]);

  const itemQty = rows.reduce((sum, row) => sum + n(row.qty_allocated), 0);
  const selectableIndexes = rows
    .map((row, index) => ({ row, index }))
    .filter(({ row }) => canApprove && !row.blocker)
    .map(({ index }) => index);
  const selectedCount = selectedIndexes.size;
  const allSelectableSelected =
    selectableIndexes.length > 0 && selectableIndexes.every((index) => selectedIndexes.has(index));
  const bulkWouldOverride =
    bulkCategoryCode !== "" &&
    Array.from(selectedIndexes).some(
      (index) => bulkCategoryCode !== (rows[index].suggested_category_code ?? "unclassified"),
    );

  function setRowSelected(index: number, checked: boolean) {
    setBulkError(null);
    setSelectedIndexes((current) => {
      const next = new Set(current);
      if (checked) next.add(index);
      else next.delete(index);
      return next;
    });
  }

  function selectAll() {
    setBulkError(null);
    setSelectedIndexes(new Set(selectableIndexes));
  }

  function unselectAll() {
    setBulkError(null);
    setSelectedIndexes(new Set());
  }

  function applyBulkCategory() {
    if (selectedCount === 0) {
      setBulkError("Select at least one item.");
      return;
    }
    if (!bulkCategoryCode) {
      setBulkError("Choose a category / weight.");
      return;
    }

    const reason = bulkReason.trim();
    if (bulkWouldOverride && !reason) {
      setBulkError("Enter an override reason for the selected category change.");
      return;
    }

    setCategoryCodes((current) =>
      current.map((categoryCode, index) =>
        selectedIndexes.has(index) ? bulkCategoryCode : categoryCode,
      ),
    );

    selectedIndexes.forEach((index) => {
      const input = overrideReasonRefs.current[index];
      if (!input) return;
      const suggestedCategoryCode = rows[index].suggested_category_code ?? "unclassified";
      if (bulkCategoryCode === suggestedCategoryCode) {
        input.value = "";
        bulkReasonIndexesRef.current.delete(index);
      } else {
        input.value = reason;
        bulkReasonIndexesRef.current.add(index);
      }
    });

    setSelectedIndexes(new Set());
    setBulkCategoryCode("");
    setBulkReason("");
    setBulkError(null);
  }

  return (
    <>
      <div className="flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
        <div>
          <h2 className="text-xl font-semibold">Category-weighted allocation preview</h2>
          <p className="mt-2 text-sm leading-6 text-slate-600">
            Default method uses adjusted shipped value × category factor. Supervisor can override category with a reason before approval.
          </p>
        </div>
        <div className="grid gap-2 text-sm sm:grid-cols-3">
          <div className="rounded-2xl bg-slate-50 p-3">
            <p className="text-xs uppercase tracking-wide text-slate-500">Item qty</p>
            <p className="font-semibold">{qty(itemQty)}</p>
          </div>
          <div className="rounded-2xl bg-slate-50 p-3">
            <p className="text-xs uppercase tracking-wide text-slate-500">Weighted basis</p>
            <p className="font-semibold">{calculated.totalWeightedBasis.toFixed(4)}</p>
          </div>
          <div className="rounded-2xl bg-slate-50 p-3">
            <p className="text-xs uppercase tracking-wide text-slate-500">Preview total</p>
            <p className="font-semibold">{money(calculated.previewTotal, sourceCurrency)}</p>
          </div>
        </div>
      </div>

      <div className="mt-5 rounded-2xl border border-slate-200 bg-slate-50 p-3">
        <div className="flex flex-wrap items-end gap-3">
          <div className="flex flex-wrap items-center gap-2">
            <button
              type="button"
              onClick={selectAll}
              disabled={!canApprove || selectableIndexes.length === 0 || allSelectableSelected}
              className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-semibold text-slate-700 hover:bg-slate-100 disabled:cursor-not-allowed disabled:opacity-50"
            >
              Select all
            </button>
            <button
              type="button"
              onClick={unselectAll}
              disabled={selectedCount === 0}
              className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-semibold text-slate-700 hover:bg-slate-100 disabled:cursor-not-allowed disabled:opacity-50"
            >
              Unselect all
            </button>
            <span className="text-sm font-semibold text-slate-700">
              {selectedCount} selected
            </span>
          </div>

          <label className="min-w-56 flex-1 text-sm">
            <span className="text-xs font-semibold uppercase tracking-wide text-slate-500">Category / weight</span>
            <select
              value={bulkCategoryCode}
              onChange={(event) => {
                setBulkCategoryCode(event.target.value);
                setBulkError(null);
              }}
              disabled={!canApprove || selectedCount === 0}
              className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm"
            >
              <option value="">Choose category</option>
              {rules.map((rule) => (
                <option key={rule.rule_code} value={rule.rule_code}>
                  {rule.label} × {n(rule.default_factor).toFixed(1)}
                </option>
              ))}
            </select>
          </label>

          <label className="min-w-64 flex-[2] text-sm">
            <span className="text-xs font-semibold uppercase tracking-wide text-slate-500">Bulk override reason</span>
            <input
              value={bulkReason}
              onChange={(event) => {
                setBulkReason(event.target.value);
                setBulkError(null);
              }}
              placeholder={bulkWouldOverride ? "Required for category override" : "Only required for an override"}
              disabled={!canApprove || selectedCount === 0}
              className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm"
            />
          </label>

          <button
            type="button"
            onClick={applyBulkCategory}
            disabled={!canApprove || selectedCount === 0 || !bulkCategoryCode}
            className="rounded-xl bg-sky-700 px-4 py-2 text-sm font-semibold text-white hover:bg-sky-800 disabled:cursor-not-allowed disabled:bg-slate-300"
          >
            Apply to selected
          </button>
        </div>
        {bulkError ? <p className="mt-2 text-sm font-semibold text-rose-700">{bulkError}</p> : null}
      </div>

      <div className="mt-5 overflow-x-auto rounded-2xl border border-slate-200">
        <table className="min-w-full divide-y divide-slate-200 text-sm">
          <thead className="bg-slate-100 text-xs uppercase tracking-wide text-slate-500">
            <tr>
              <th className="px-3 py-2 text-left">Order / package</th>
              <th className="px-3 py-2 text-left">Item</th>
              <th className="px-3 py-2 text-right">Qty</th>
              <th className="px-3 py-2 text-right">Adjusted value</th>
              <th className="px-3 py-2 text-left">Category</th>
              <th className="px-3 py-2 text-right">Factor</th>
              <th className="px-3 py-2 text-right">Allocated shipping</th>
              <th className="px-3 py-2 text-left">Override reason</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-100 bg-white">
            {rows.map((row, index) => (
              <tr key={`${row.tracking_submission_id}-${row.supplier_invoice_line_id}-${index}`}>
                <td className="px-3 py-3 align-top">
                  <label className="mb-2 flex items-center gap-2 text-xs font-semibold text-slate-600">
                    <input
                      type="checkbox"
                      checked={selectedIndexes.has(index)}
                      onChange={(event) => setRowSelected(index, event.target.checked)}
                      disabled={!canApprove || !!row.blocker}
                      className="h-4 w-4 rounded border-slate-300"
                    />
                    Select
                  </label>
                  <p className="font-semibold">{row.order_ref ?? row.order_id ?? "—"}</p>
                  <p className="text-xs text-slate-500">{row.tracking_ref ?? row.tracking_submission_id ?? "—"}</p>
                </td>
                <td className="px-3 py-3 align-top">
                  <p className="font-medium">{row.item_description ?? "Unlabelled item"}</p>
                  {row.blocker ? <p className="mt-1 text-xs font-semibold text-amber-700">{friendly(row.blocker)}</p> : null}
                </td>
                <td className="px-3 py-3 text-right align-top">{qty(row.qty_allocated)}</td>
                <td className="px-3 py-3 text-right align-top">{money(n(row.adjusted_net_value_gbp), "GBP")}</td>
                <td className="px-3 py-3 align-top">
                  <input type="hidden" name="tracking_submission_id" value={row.tracking_submission_id ?? ""} />
                  <input type="hidden" name="supplier_invoice_line_id" value={row.supplier_invoice_line_id ?? ""} />
                  <select
                    name="category_code"
                    value={categoryCodes[index]}
                    onChange={(event) => {
                      const nextCategoryCode = event.target.value;
                      const next = [...categoryCodes];
                      next[index] = nextCategoryCode;
                      setCategoryCodes(next);

                      const suggestedCategoryCode = rows[index].suggested_category_code ?? "unclassified";
                      if (
                        nextCategoryCode === suggestedCategoryCode &&
                        bulkReasonIndexesRef.current.has(index)
                      ) {
                        const input = overrideReasonRefs.current[index];
                        if (input) input.value = "";
                        bulkReasonIndexesRef.current.delete(index);
                      }
                    }}
                    className="w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm"
                    disabled={!canApprove}
                  >
                    {rules.map((rule) => (
                      <option key={rule.rule_code} value={rule.rule_code}>
                        {rule.label} × {n(rule.default_factor).toFixed(1)}
                      </option>
                    ))}
                  </select>
                </td>
                <td className="px-3 py-3 text-right align-top">{calculated.rows[index].factor.toFixed(3)}</td>
                <td className="px-3 py-3 text-right align-top font-semibold">
                  {money(calculated.rows[index].allocatedAmount, sourceCurrency)}
                </td>
                <td className="px-3 py-3 align-top">
                  <input
                    ref={(element) => {
                      overrideReasonRefs.current[index] = element;
                    }}
                    name="override_reason"
                    onChange={() => {
                      bulkReasonIndexesRef.current.delete(index);
                    }}
                    placeholder="Required if changing category"
                    className="w-56 rounded-xl border border-slate-300 px-3 py-2 text-sm"
                    disabled={!canApprove}
                  />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}
