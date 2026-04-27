"use client";

import { useEffect, useState } from "react";

export function BulkProgressionControls({ selectableCount }: { selectableCount: number }) {
  const [selectedCount, setSelectedCount] = useState(0);

  function getCheckboxes() {
    return Array.from(document.querySelectorAll<HTMLInputElement>("input[data-bulk-progress-line='true']:not(:disabled)"));
  }

  function refreshSelectedCount() {
    setSelectedCount(getCheckboxes().filter((checkbox) => checkbox.checked).length);
  }

  function selectAll() {
    getCheckboxes().forEach((checkbox) => {
      checkbox.checked = true;
    });
    refreshSelectedCount();
  }

  function clearSelection() {
    getCheckboxes().forEach((checkbox) => {
      checkbox.checked = false;
    });
    refreshSelectedCount();
  }

  useEffect(() => {
    const checkboxes = getCheckboxes();
    checkboxes.forEach((checkbox) => checkbox.addEventListener("change", refreshSelectedCount));
    refreshSelectedCount();

    return () => {
      checkboxes.forEach((checkbox) => checkbox.removeEventListener("change", refreshSelectedCount));
    };
  }, []);

  return (
    <div className="mt-3 flex flex-wrap items-center gap-3">
      <button
        type="button"
        onClick={selectAll}
        disabled={selectableCount === 0}
        className="rounded-xl border border-emerald-300 bg-white px-4 py-2 text-sm font-semibold text-emerald-800 hover:bg-emerald-100 disabled:cursor-not-allowed disabled:opacity-50"
      >
        Select all clean lines
      </button>
      <button
        type="button"
        onClick={clearSelection}
        disabled={selectedCount === 0}
        className="rounded-xl border border-slate-300 bg-white px-4 py-2 text-sm font-semibold text-slate-700 hover:bg-slate-100 disabled:cursor-not-allowed disabled:opacity-50"
      >
        Clear selection
      </button>
      <span className="text-sm font-medium text-emerald-900">
        {selectedCount} of {selectableCount} selectable line(s) selected
      </span>
    </div>
  );
}
