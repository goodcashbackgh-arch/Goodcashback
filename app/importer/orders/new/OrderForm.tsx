"use client";

import { useRef, useState, useTransition, type ChangeEvent, type FormEvent } from "react";

type Option = { id: string; name: string };
type Hub = { id: string; name: string; city?: string | null };
type AttachmentSummary = {
  count: number;
  originalBytes: number;
  uploadBytes: number;
  optimisedCount: number;
  status: "idle" | "optimising" | "ready";
  error: string;
};

const MAX_ATTACHMENT_BYTES = 3.5 * 1024 * 1024;
const TARGET_ATTACHMENT_BYTES = 3.1 * 1024 * 1024;
const COMPRESSION_TRIGGER_BYTES = 700 * 1024;
const MAX_FILE_TARGET_BYTES = 900 * 1024;
const MIN_FILE_TARGET_BYTES = 300 * 1024;
const MAX_IMAGE_DIMENSIONS = [1800, 1500, 1200];
const JPEG_QUALITIES = [0.86, 0.76, 0.66];

function formatMb(bytes: number) {
  return (bytes / 1024 / 1024).toFixed(2);
}

function jpegName(filename: string) {
  const base = filename.replace(/\.[^.]+$/, "") || "screenshot";
  return `${base}.jpg`;
}

function loadImage(file: File) {
  return new Promise<HTMLImageElement>((resolve, reject) => {
    const objectUrl = URL.createObjectURL(file);
    const image = new Image();

    image.onload = () => {
      URL.revokeObjectURL(objectUrl);
      resolve(image);
    };
    image.onerror = () => {
      URL.revokeObjectURL(objectUrl);
      reject(new Error(`Could not read ${file.name}`));
    };
    image.src = objectUrl;
  });
}

function canvasToJpeg(canvas: HTMLCanvasElement, quality: number) {
  return new Promise<Blob>((resolve, reject) => {
    canvas.toBlob((blob) => {
      if (blob) resolve(blob);
      else reject(new Error("Could not optimise screenshot"));
    }, "image/jpeg", quality);
  });
}

async function optimiseImage(file: File, targetBytes: number) {
  const canOptimise = file.type.startsWith("image/") && !["image/gif", "image/svg+xml"].includes(file.type);
  if (!canOptimise || file.size <= COMPRESSION_TRIGGER_BYTES) return file;

  let image: HTMLImageElement;
  try {
    image = await loadImage(file);
  } catch {
    return file;
  }

  const originalWidth = image.naturalWidth || image.width;
  const originalHeight = image.naturalHeight || image.height;
  if (!originalWidth || !originalHeight) return file;

  let smallestBlob: Blob | null = null;

  for (const maxDimension of MAX_IMAGE_DIMENSIONS) {
    const scale = Math.min(1, maxDimension / Math.max(originalWidth, originalHeight));
    const width = Math.max(1, Math.round(originalWidth * scale));
    const height = Math.max(1, Math.round(originalHeight * scale));
    const canvas = document.createElement("canvas");
    canvas.width = width;
    canvas.height = height;

    const context = canvas.getContext("2d");
    if (!context) return file;

    context.fillStyle = "#ffffff";
    context.fillRect(0, 0, width, height);
    context.drawImage(image, 0, 0, width, height);

    for (const quality of JPEG_QUALITIES) {
      const blob = await canvasToJpeg(canvas, quality);
      if (!smallestBlob || blob.size < smallestBlob.size) smallestBlob = blob;
      if (blob.size <= targetBytes) {
        return new File([blob], jpegName(file.name), {
          type: "image/jpeg",
          lastModified: file.lastModified,
        });
      }
    }
  }

  if (!smallestBlob || smallestBlob.size >= file.size) return file;
  return new File([smallestBlob], jpegName(file.name), {
    type: "image/jpeg",
    lastModified: file.lastModified,
  });
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
  action: (formData: FormData) => Promise<void>;
}) {
  const preparedFilesRef = useRef<File[]>([]);
  const selectionVersionRef = useRef(0);
  const [isSubmitting, startSubmitTransition] = useTransition();
  const [attachmentSummary, setAttachmentSummary] = useState<AttachmentSummary>({
    count: 0,
    originalBytes: 0,
    uploadBytes: 0,
    optimisedCount: 0,
    status: "idle",
    error: "",
  });

  async function handleAttachmentChange(event: ChangeEvent<HTMLInputElement>) {
    const input = event.currentTarget;
    const files = Array.from(input.files ?? []);
    const selectionVersion = selectionVersionRef.current + 1;
    selectionVersionRef.current = selectionVersion;
    preparedFilesRef.current = [];

    if (files.length === 0) {
      setAttachmentSummary({ count: 0, originalBytes: 0, uploadBytes: 0, optimisedCount: 0, status: "idle", error: "" });
      return;
    }

    const originalBytes = files.reduce((sum, file) => sum + file.size, 0);
    setAttachmentSummary({
      count: files.length,
      originalBytes,
      uploadBytes: originalBytes,
      optimisedCount: 0,
      status: "optimising",
      error: "",
    });

    const targetPerFile = Math.max(
      MIN_FILE_TARGET_BYTES,
      Math.min(MAX_FILE_TARGET_BYTES, Math.floor(TARGET_ATTACHMENT_BYTES / files.length)),
    );

    try {
      const preparedFiles: File[] = [];
      for (const file of files) preparedFiles.push(await optimiseImage(file, targetPerFile));
      if (selectionVersionRef.current !== selectionVersion) return;

      const uploadBytes = preparedFiles.reduce((sum, file) => sum + file.size, 0);
      const optimisedCount = preparedFiles.reduce((count, file, index) => count + (file !== files[index] ? 1 : 0), 0);

      if (uploadBytes > MAX_ATTACHMENT_BYTES) {
        input.value = "";
        preparedFilesRef.current = [];
        setAttachmentSummary({
          count: 0,
          originalBytes: 0,
          uploadBytes: 0,
          optimisedCount: 0,
          status: "idle",
          error: `These screenshots remain ${formatMb(uploadBytes)} MB after automatic optimisation. Please remove one screenshot and try again.`,
        });
        return;
      }

      preparedFilesRef.current = preparedFiles;
      setAttachmentSummary({
        count: preparedFiles.length,
        originalBytes,
        uploadBytes,
        optimisedCount,
        status: "ready",
        error: "",
      });
    } catch {
      if (selectionVersionRef.current !== selectionVersion) return;
      input.value = "";
      preparedFilesRef.current = [];
      setAttachmentSummary({
        count: 0,
        originalBytes: 0,
        uploadBytes: 0,
        optimisedCount: 0,
        status: "idle",
        error: "We could not prepare those screenshots. Please select them again.",
      });
    }
  }

  function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const form = event.currentTarget;

    if (!form.reportValidity() || attachmentSummary.status === "optimising" || preparedFilesRef.current.length === 0) return;

    const formData = new FormData(form);
    formData.delete("screenshots");
    for (const file of preparedFilesRef.current) formData.append("screenshots", file, file.name);

    startSubmitTransition(() => {
      void action(formData);
    });
  }

  const attachmentsBusy = attachmentSummary.status === "optimising";
  const submitDisabled = retailers.length === 0 || !assignedHub || attachmentsBusy || Boolean(attachmentSummary.error) || isSubmitting;

  return (
    <form action={action} onSubmit={handleSubmit} className="space-y-4 max-w-3xl" encType="multipart/form-data">
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
            {attachmentsBusy
              ? `Optimising ${attachmentSummary.count} ${attachmentSummary.count === 1 ? "attachment" : "attachments"}…`
              : `${attachmentSummary.count} ${attachmentSummary.count === 1 ? "attachment" : "attachments"} · ${formatMb(attachmentSummary.uploadBytes)} MB`}
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
          aria-describedby="attachment-guidance attachment-status attachment-error"
        />
        <p id="attachment-guidance" className="text-xs text-slate-600">Select all required screenshots in one selection. Large screenshots are automatically optimised before upload.</p>
        {attachmentSummary.optimisedCount > 0 && !attachmentsBusy ? (
          <p id="attachment-status" className="rounded border border-emerald-200 bg-emerald-50 p-2 text-xs font-medium text-emerald-800">
            Ready to upload: reduced from {formatMb(attachmentSummary.originalBytes)} MB to {formatMb(attachmentSummary.uploadBytes)} MB.
          </p>
        ) : null}
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
      <button className="rounded bg-sky-600 text-white px-4 py-2 disabled:bg-slate-300" disabled={submitDisabled}>
        {isSubmitting ? "Creating order…" : attachmentsBusy ? "Optimising screenshots…" : "Create order / Goods Pro Forma Estimate"}
      </button>
    </form>
  );
}
