"use client";

import { useEffect, useRef, useState } from "react";

type Props = {
  formId: string;
  selectableCount: number;
};

function shipmentCheckboxes(form: HTMLFormElement) {
  return Array.from(
    form.querySelectorAll<HTMLInputElement>(
      'input[type="checkbox"][name="tracking_submission_ids"][data-shipment-batch-select="true"]'
    )
  );
}

function isRendered(input: HTMLInputElement) {
  return input.getClientRects().length > 0;
}

export default function ShipmentSelectionControls({ formId, selectableCount }: Props) {
  const selectedIdsRef = useRef<Set<string>>(new Set());
  const [selectedCount, setSelectedCount] = useState(0);

  function syncResponsiveCopies(form: HTMLFormElement) {
    const boxes = shipmentCheckboxes(form);

    for (const box of boxes) {
      const visible = isRendered(box);
      box.disabled = !visible;
      box.checked = visible && selectedIdsRef.current.has(box.value);
    }

    setSelectedCount(selectedIdsRef.current.size);
  }

  function setSelection(checked: boolean) {
    const form = document.getElementById(formId) as HTMLFormElement | null;
    if (!form) return;

    if (checked) {
      selectedIdsRef.current = new Set(
        shipmentCheckboxes(form).map((box) => box.value).filter(Boolean)
      );
    } else {
      selectedIdsRef.current = new Set();
    }

    syncResponsiveCopies(form);
  }

  useEffect(() => {
    const form = document.getElementById(formId) as HTMLFormElement | null;
    if (!form) return;

    selectedIdsRef.current = new Set(
      shipmentCheckboxes(form)
        .filter((box) => isRendered(box) && box.checked)
        .map((box) => box.value)
        .filter(Boolean)
    );
    syncResponsiveCopies(form);

    const handleChange = (event: Event) => {
      const target = event.target;
      if (!(target instanceof HTMLInputElement)) return;
      if (target.dataset.shipmentBatchSelect !== "true") return;
      if (target.name !== "tracking_submission_ids") return;

      const next = new Set(selectedIdsRef.current);
      if (target.checked) next.add(target.value);
      else next.delete(target.value);
      selectedIdsRef.current = next;
      syncResponsiveCopies(form);
    };

    const handleResponsiveChange = () => {
      syncResponsiveCopies(form);
    };

    const handleSubmit = () => {
      syncResponsiveCopies(form);
    };

    form.addEventListener("change", handleChange);
    form.addEventListener("submit", handleSubmit);
    window.addEventListener("resize", handleResponsiveChange);
    window.addEventListener("orientationchange", handleResponsiveChange);

    return () => {
      form.removeEventListener("change", handleChange);
      form.removeEventListener("submit", handleSubmit);
      window.removeEventListener("resize", handleResponsiveChange);
      window.removeEventListener("orientationchange", handleResponsiveChange);
    };
  }, [formId, selectableCount]);

  return (
    <div className="flex flex-wrap items-center gap-3 rounded-2xl border border-slate-200 bg-slate-50 px-3 py-2">
      <button
        type="button"
        onClick={() => setSelection(true)}
        className="rounded-xl border border-emerald-300 bg-white px-3 py-2 text-sm font-semibold text-emerald-900 hover:bg-emerald-50"
      >
        Select all
      </button>
      <button
        type="button"
        onClick={() => setSelection(false)}
        className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-semibold text-slate-800 hover:bg-slate-100"
      >
        Clear selection
      </button>
      <span className="text-sm font-medium text-slate-700">
        {selectedCount} of {selectableCount} selected
      </span>
    </div>
  );
}
