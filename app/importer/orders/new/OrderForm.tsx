"use client";

import { useState, type ChangeEvent } from "react";

type Option = { id: string; name: string };
type Hub = { id: string; name: string; city?: string | null };

const MAX_ATTACHMENT_BYTES = 3.5 * 1024 * 1024;

function formatMb(bytes: number) {
  return (bytes / 1024 / 1024).toFixed(2);
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
  const [attachmentSummary, setAttachmentSummary] = useState({ count: 0, totalBytes: 0, error: "" });

  function handleAttachmentChange(event: ChangeEvent<HTMLInputElement>) {
    const files = Array.from(event.currentTarget.files ?? []);
    const totalBytes = files.reduce((sum, file) => sum + file.size, 0);

    if (totalBytes > MAX_ATTACHMENT_BYTES) {
      event.currentTarget.value = "";
      setAttachmentSummary({
        count: 0,
        totalBytes: 0,
        error: `Attachments total ${formatMb(totalBytes)} MB. The maximum allowed is 3.50 MB. Please select smaller files.`,
      });
      return;
    }

    setAttachmentSummary({ count: files.length, totalBytes, error: "" });
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
          <span className="text-xs font-semibold text-slate-700" aria-live="polite">
            {attachmentSummary.count} {attachmentSummary.count === 1 ? "attachment" : "attachments"} · {formatMb(attachmentSummary.totalBytes)} MB
          </span>
        </div>
        <input
          id="screenshots"
          name="screenshots"
          type="file"
          accept="image/*"
          multiple
          required
          className="border p-2 w-full"
          onChange={handleAttachmentChange}
          aria-describedby="attachment-guidance attachment-error"
        />
        <p id="attachment-guidance" className="text-xs text-slate-600">Select all required screenshots in one selection. Maximum combined size: 3.50 MB.</p>
        {attachmentSummary.error ? (
          <p id="attachment-error" role="alert" className="rounded border border-red-300 bg-red-50 p-2 text-sm font-medium text-red-800">
            {attachmentSummary.error}
          </p>
        ) : null}
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
      <button className="rounded bg-sky-600 text-white px-4 py-2 disabled:bg-slate-300" disabled={retailers.length === 0 || !assignedHub || Boolean(attachmentSummary.error)}>Create order / Goods Pro Forma Estimate</button>
    </form>
  );
}
