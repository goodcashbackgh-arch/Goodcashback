"use client";

import { useEffect } from "react";

function relabelControlPostingStatus() {
  const rows = document.querySelectorAll<HTMLTableRowElement>("tbody tr");
  rows.forEach((row) => {
    const cells = row.querySelectorAll<HTMLTableCellElement>("td");
    if (cells.length < 10) return;

    const categoryText = cells[2]?.textContent?.toLowerCase() ?? "";
    const isControlPostableRow = categoryText.includes("bank fee") || categoryText.includes("fx/card difference");
    if (!isControlPostableRow) return;

    const statusPill = cells[9]?.querySelector<HTMLSpanElement>("span");
    if (statusPill?.textContent?.trim().toLowerCase() !== "blocked endpoint prove required") return;

    statusPill.textContent = "Control-postable";
    statusPill.title = "Selectable for controlled freeze, batch and batch-detail Sage posting.";
  });
}

export default function SelectionControls() {
  useEffect(() => {
    relabelControlPostingStatus();
  }, []);

  function setVisibleSelections(checked: boolean) {
    const boxes = document.querySelectorAll<HTMLInputElement>('input[data-accounting-row-select="true"]');
    boxes.forEach((box) => {
      if (!box.disabled) box.checked = checked;
    });
  }

  return (
    <div className="flex flex-wrap items-center gap-2 rounded-2xl border border-slate-200 bg-slate-50 px-3 py-2 text-xs font-semibold text-slate-700">
      <span className="font-bold text-slate-900">Selection</span>
      <button
        type="button"
        onClick={() => setVisibleSelections(true)}
        className="rounded-lg border border-slate-300 bg-white px-2.5 py-1 font-bold text-slate-800 hover:bg-slate-100"
      >
        Select all visible
      </button>
      <button
        type="button"
        onClick={() => setVisibleSelections(false)}
        className="rounded-lg border border-slate-300 bg-white px-2.5 py-1 font-bold text-slate-800 hover:bg-slate-100"
      >
        Unselect all visible
      </button>
      <span className="text-slate-500">Row checkboxes control selected-visible freeze actions only.</span>
    </div>
  );
}
