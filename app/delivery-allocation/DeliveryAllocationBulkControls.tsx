"use client";

import { useEffect, useMemo, useState } from "react";
import { FloatingActionBar } from "@/app/_components/FloatingActionBar";
import { saveBulkDeliveryAllocationAction } from "./actions";

type TrackingOption = {
  id: string;
  label: string;
};

type DeliveryAllocationBulkControlsProps = {
  mode: "operator" | "staff";
  orderId: string;
  selectableCount: number;
  tracking: TrackingOption[];
};

const FORM_ID = "bulk-delivery-allocation-form";

function selectableCheckboxes() {
  return Array.from(
    document.querySelectorAll<HTMLInputElement>(
      `input[name="line_ids"][form="${FORM_ID}"]:not(:disabled)`
    )
  );
}

export default function DeliveryAllocationBulkControls({
  mode,
  orderId,
  selectableCount,
  tracking,
}: DeliveryAllocationBulkControlsProps) {
  const [selectedCount, setSelectedCount] = useState(0);
  const [selectedQty, setSelectedQty] = useState(0);
  const [trackingId, setTrackingId] = useState("");
  const [confirmed, setConfirmed] = useState(false);

  const selectedTracking = useMemo(
    () => tracking.find((row) => row.id === trackingId) ?? null,
    [tracking, trackingId]
  );

  function refreshSelection(resetConfirmation = true) {
    const selected = selectableCheckboxes().filter((checkbox) => checkbox.checked);
    setSelectedCount(selected.length);
    setSelectedQty(
      selected.reduce((sum, checkbox) => {
        const remaining = Number(checkbox.dataset.remainingQty ?? 0);
        return sum + (Number.isFinite(remaining) ? remaining : 0);
      }, 0)
    );
    if (resetConfirmation) setConfirmed(false);
  }

  function setSelection(checked: boolean) {
    selectableCheckboxes().forEach((checkbox) => {
      checkbox.checked = checked;
    });
    refreshSelection(true);
  }

  useEffect(() => {
    const handleChange = (event: Event) => {
      const target = event.target;
      if (
        target instanceof HTMLInputElement &&
        target.name === "line_ids" &&
        target.getAttribute("form") === FORM_ID
      ) {
        refreshSelection(true);
      }
    };

    document.addEventListener("change", handleChange);
    refreshSelection(false);
    return () => document.removeEventListener("change", handleChange);
  }, [selectableCount]);

  return (
    <>
      <form id={FORM_ID} action={saveBulkDeliveryAllocationAction} className="mt-4 rounded-2xl border border-sky-200 bg-sky-50 p-4">
        <input type="hidden" name="mode" value={mode} />
        <input type="hidden" name="order_id" value={orderId} />
        <div className="grid gap-3 md:grid-cols-[minmax(0,1fr)_auto] md:items-end">
          <label className="space-y-1 text-sm">
            <span className="text-xs font-semibold uppercase tracking-wide text-sky-800">Tracking ref / package for selected items</span>
            <select
              name="tracking_submission_id"
              value={trackingId}
              onChange={(event) => {
                setTrackingId(event.target.value);
                setConfirmed(false);
              }}
              className="w-full rounded-xl border border-sky-300 bg-white px-3 py-2 text-slate-900"
            >
              <option value="">Select tracking ref/package</option>
              {tracking.map((row) => <option key={row.id} value={row.id}>{row.label}</option>)}
            </select>
          </label>
          <div className="flex flex-wrap items-center gap-2">
            <button type="button" onClick={() => setSelection(true)} disabled={selectableCount === 0} className="rounded-xl border border-sky-300 bg-white px-3 py-2 text-sm font-semibold text-sky-900 hover:bg-sky-100 disabled:cursor-not-allowed disabled:opacity-50">
              Select all available
            </button>
            <button type="button" onClick={() => setSelection(false)} disabled={selectedCount === 0} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-semibold text-slate-800 hover:bg-slate-100 disabled:cursor-not-allowed disabled:opacity-50">
              Clear
            </button>
          </div>
        </div>
        <p className="mt-3 text-sm font-medium text-sky-950">{selectedCount} of {selectableCount} available item{selectableCount === 1 ? "" : "s"} selected</p>
        <p className="mt-1 text-xs leading-5 text-sky-800">Bulk allocation uses the full current ordinary remaining quantity of every selected item. Use the existing individual item form for a partial quantity.</p>
      </form>

      {selectedCount > 0 ? (
        <FloatingActionBar
          hideWhenVisibleId="delivery-allocation-bulk-hide-sentinel"
          innerClassName="flex w-full max-w-4xl flex-col gap-3 rounded-2xl border border-slate-200 bg-white/95 p-3 shadow-lg backdrop-blur sm:flex-row sm:items-center sm:justify-between"
        >
          <div className="min-w-0 text-sm">
            <p className="font-semibold text-slate-950">{selectedCount} item{selectedCount === 1 ? "" : "s"} · {selectedQty} unit{Math.abs(selectedQty - 1) < 0.0001 ? "" : "s"}</p>
            <p className="truncate text-xs text-slate-600">{selectedTracking?.label ?? "Select a tracking ref/package"}</p>
          </div>
          <label className="flex flex-1 items-start gap-2 text-sm text-slate-800 sm:max-w-md">
            <input form={FORM_ID} type="checkbox" name="confirm_same_package" value="yes" checked={confirmed} onChange={(event) => setConfirmed(event.target.checked)} className="mt-1 h-4 w-4 rounded border-slate-300" />
            <span>I confirm these selected items are in this tracking package.</span>
          </label>
          <button form={FORM_ID} type="submit" disabled={!trackingId || !confirmed || selectedCount === 0} className="w-full rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800 disabled:cursor-not-allowed disabled:bg-slate-300 sm:w-auto">
            Apply tracking ref
          </button>
        </FloatingActionBar>
      ) : null}
    </>
  );
}
