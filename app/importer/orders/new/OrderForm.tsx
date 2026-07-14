"use client";

import { useRef, useState } from "react";

type Option = { id: string; name: string };
type Hub = { id: string; name: string; city?: string | null };

function fileKey(file: File) {
  return `${file.name}-${file.size}-${file.lastModified}`;
}

export default function OrderForm({
  retailers,
  shipperName,
  assignedHub,
  emptyMessages,
  action,
}: {
  retailers: Option[];
  shipperName: string;
  assignedHub: Hub | null;
  emptyMessages: string[];
  action: (formData: FormData) => void;
}) {
  const screenshotsInputRef = useRef<HTMLInputElement>(null);
  const [screenshots, setScreenshots] = useState<File[]>([]);

  function syncScreenshots(nextFiles: File[]) {
    const input = screenshotsInputRef.current;
    if (!input) return;

    const transfer = new DataTransfer();
    nextFiles.forEach((file) => transfer.items.add(file));
    input.files = transfer.files;
    setScreenshots(nextFiles);
  }

  function addScreenshots(selectedFiles: FileList | null) {
    if (!selectedFiles?.length) return;

    const existingKeys = new Set(screenshots.map(fileKey));
    const newFiles = Array.from(selectedFiles).filter((file) => !existingKeys.has(fileKey(file)));
    syncScreenshots([...screenshots, ...newFiles]);
  }

  function removeScreenshot(indexToRemove: number) {
    syncScreenshots(screenshots.filter((_, index) => index !== indexToRemove));
  }

  return (
    <form action={action} className="space-y-4 max-w-3xl" encType="multipart/form-data">
      {emptyMessages.length > 0 && <div className="rounded border border-amber-500 bg-amber-50 p-3 text-sm">{emptyMessages.join(" ")}</div>}
      <select name="retailer_id" className="border p-2 w-full" required disabled={retailers.length === 0}>
        <option value="">Select retailer</option>
        {retailers.map((r) => (
          <option key={r.id} value={r.id}>{r.name}</option>
        ))}
      </select>

      <div className="grid gap-2 md:grid-cols-2">
        <div className="rounded border p-3 text-sm"><span className="font-semibold">Assigned shipper:</span> {shipperName}</div>
        <div className="rounded border p-3 text-sm"><span className="font-semibold">Assigned destination hub/city:</span> {assignedHub ? `${assignedHub.name}${assignedHub.city ? ` (${assignedHub.city})` : ""}` : "Not assigned"}</div>
      </div>
      <input type="hidden" name="destination_hub_id" value={assignedHub?.id ?? ""} />

      <div className="space-y-2 rounded border p-3">
        <div className="flex items-center justify-between gap-3">
          <label htmlFor="screenshots" className="text-sm font-medium">Order attachments</label>
          <span className="rounded-full bg-sky-100 px-2.5 py-1 text-xs font-semibold text-sky-800" aria-live="polite">
            {screenshots.length} {screenshots.length === 1 ? "attachment" : "attachments"}
          </span>
        </div>
        <input
          ref={screenshotsInputRef}
          id="screenshots"
          name="screenshots"
          type="file"
          accept="image/*"
          multiple
          required
          className="border p-2 w-full"
          onChange={(event) => addScreenshots(event.currentTarget.files)}
        />
        <p className="text-xs text-slate-600">You can choose more files again; they will be added to the existing selection.</p>

        {screenshots.length > 0 && (
          <ul className="divide-y rounded border text-sm">
            {screenshots.map((file, index) => (
              <li key={fileKey(file)} className="flex items-center justify-between gap-3 px-3 py-2">
                <span className="min-w-0 truncate">{index + 1}. {file.name}</span>
                <button
                  type="button"
                  className="shrink-0 rounded px-2 py-1 text-xs font-medium text-red-700 hover:bg-red-50"
                  onClick={() => removeScreenshot(index)}
                  aria-label={`Remove ${file.name}`}
                >
                  Remove
                </button>
              </li>
            ))}
          </ul>
        )}
      </div>

      <div className="grid grid-cols-1 gap-2 md:grid-cols-2">
        <div>
          <label className="mb-1 block text-sm font-medium">Total quantity declared</label>
          <input className="border p-2 w-full" name="total_qty_declared" type="number" min="1" step="1" required />
        </div>
        <div>
          <label className="mb-1 block text-sm font-medium">Order total GBP declared</label>
          <input className="border p-2 w-full" name="order_total_gbp_declared" type="number" min="0.01" step="0.01" required />
        </div>
      </div>

      <div className="rounded border p-3 text-sm space-y-2">
        <p className="font-semibold">Product confirmation</p>
        <p>I confirm this order does not include children’s clothing, infant clothing, school uniform, or similar restricted items. If restricted items are found, the order may be rejected or refunded, and an admin charge may apply.</p>
        <label className="flex items-center gap-2"><input type="checkbox" name="product_confirmed" value="yes" required /> I confirm and accept</label>
      </div>

      <div className="rounded border p-3 text-sm space-y-1">
        <p className="font-semibold">Goods Pro Forma Estimate</p>
        <p>This estimate is based on the goods value you submitted. Shipping is excluded at this stage. Shipping will be quoted separately after goods are received and checked by the shipper.</p>
      </div>
      <button className="rounded bg-sky-600 text-white px-4 py-2" disabled={retailers.length === 0 || !assignedHub}>Create order / Goods Pro Forma Estimate</button>
    </form>
  );
}
