"use client";

import { useEffect, useState } from "react";

type BulkLineSelectionControlsProps = {
  selectableCount: number;
};

function selectableCheckboxes() {
  return Array.from(
    document.querySelectorAll<HTMLInputElement>(
      'input[name="line_ids"][data-bulk-line-checkbox="true"]:not(:disabled)'
    )
  );
}

export default function BulkLineSelectionControls({ selectableCount }: BulkLineSelectionControlsProps) {
  const [selectedCount, setSelectedCount] = useState(0);

  function refreshSelectedCount() {
    setSelectedCount(selectableCheckboxes().filter((checkbox) => checkbox.checked).length);
  }

  function selectAllUnresolvedProgressableLines() {
    selectableCheckboxes().forEach((checkbox) => {
      checkbox.checked = true;
    });
    refreshSelectedCount();
  }

  function clearSelection() {
    selectableCheckboxes().forEach((checkbox) => {
      checkbox.checked = false;
    });
    refreshSelectedCount();
  }

  useEffect(() => {
    const checkboxes = selectableCheckboxes();
    checkboxes.forEach((checkbox) => checkbox.addEventListener("change", refreshSelectedCount));
    const timer = window.setTimeout(() => {
      refreshSelectedCount();
    }, 0);

    return () => {
      window.clearTimeout(timer);
      checkboxes.forEach((checkbox) => checkbox.removeEventListener("change", refreshSelectedCount));
    };
  }, [selectableCount]);

  return (
    <div className="mt-3 flex flex-wrap items-center gap-3">
      <button
        type="button"
        onClick={selectAllUnresolvedProgressableLines}
        className="rounded-xl border border-emerald-300 bg-white px-3 py-2 text-sm font-semibold text-emerald-900 hover:bg-emerald-100"
      >
        Select all unresolved progressable lines
      </button>
      <button
        type="button"
        onClick={clearSelection}
        className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-semibold text-slate-800 hover:bg-slate-100"
      >
        Clear selection
      </button>
      <span className="text-sm font-medium text-emerald-900">
        {selectedCount} of {selectableCount} selected
      </span>
    </div>
  );
}
