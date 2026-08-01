"use client";

import { useRef, useState, useTransition, type ChangeEvent, type FormEvent } from "react";
import { recordExactPackageReceiptV2Action } from "./actions";

type EntryRow = {
  tracking_line_allocation_id: string;
  supplier_invoice_line_id: string;
  item_description: string | null;
  qty_allocated: number | string;
};

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

function formatQty(value: number | string | null | undefined) {
  const number = Number(value ?? 0);
  if (!Number.isFinite(number)) return "0";
  return number.toFixed(3).replace(/0+$/, "").replace(/\.$/, "");
}

function formatMb(bytes: number) {
  return (bytes / 1024 / 1024).toFixed(2);
}

function jpegName(filename: string) {
  const base = filename.replace(/\.[^.]+$/, "") || "evidence";
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
      else reject(new Error("Could not optimise evidence image"));
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
        return new File([blob], jpegName(file.name), { type: "image/jpeg", lastModified: file.lastModified });
      }
    }
  }

  if (!smallestBlob || smallestBlob.size >= file.size) return file;
  return new File([smallestBlob], jpegName(file.name), { type: "image/jpeg", lastModified: file.lastModified });
}

export default function ExactPhysicalReceiptForm({
  rows,
  trackingSubmissionId,
  trackingLabel,
  latestReceiptId,
  correctionAllowed,
  submissionId,
}: {
  rows: EntryRow[];
  trackingSubmissionId: string;
  trackingLabel: string;
  latestReceiptId: string | null;
  correctionAllowed: boolean;
  submissionId: string;
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
    setAttachmentSummary({ count: files.length, originalBytes, uploadBytes: originalBytes, optimisedCount: 0, status: "optimising", error: "" });

    const targetPerFile = Math.max(MIN_FILE_TARGET_BYTES, Math.min(MAX_FILE_TARGET_BYTES, Math.floor(TARGET_ATTACHMENT_BYTES / files.length)));

    try {
      const preparedFiles: File[] = [];
      for (const file of files) preparedFiles.push(await optimiseImage(file, targetPerFile));
      if (selectionVersionRef.current !== selectionVersion) return;

      const uploadBytes = preparedFiles.reduce((sum, file) => sum + file.size, 0);
      const optimisedCount = preparedFiles.reduce((count, file, index) => count + (file !== files[index] ? 1 : 0), 0);
      if (uploadBytes > MAX_ATTACHMENT_BYTES) {
        input.value = "";
        preparedFilesRef.current = [];
        setAttachmentSummary({ count: 0, originalBytes: 0, uploadBytes: 0, optimisedCount: 0, status: "idle", error: `These files remain ${formatMb(uploadBytes)} MB after automatic optimisation. Remove one file and try again.` });
        return;
      }

      preparedFilesRef.current = preparedFiles;
      setAttachmentSummary({ count: preparedFiles.length, originalBytes, uploadBytes, optimisedCount, status: "ready", error: "" });
    } catch {
      if (selectionVersionRef.current !== selectionVersion) return;
      input.value = "";
      preparedFilesRef.current = [];
      setAttachmentSummary({ count: 0, originalBytes: 0, uploadBytes: 0, optimisedCount: 0, status: "idle", error: "We could not prepare those evidence files. Select them again." });
    }
  }

  function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const form = event.currentTarget;
    if (!form.reportValidity() || attachmentSummary.status === "optimising" || isSubmitting) return;

    const formData = new FormData(form);
    formData.delete("receipt_evidence_files");
    for (const file of preparedFilesRef.current) formData.append("receipt_evidence_files", file, file.name);

    startSubmitTransition(() => {
      void recordExactPackageReceiptV2Action(formData);
    });
  }

  const hasPriorReceipt = Boolean(latestReceiptId);
  const attachmentsBusy = attachmentSummary.status === "optimising";
  const submitDisabled = (hasPriorReceipt && !correctionAllowed) || attachmentsBusy || Boolean(attachmentSummary.error) || isSubmitting;

  return (
    <form action={recordExactPackageReceiptV2Action} onSubmit={handleSubmit} className="space-y-6" encType="multipart/form-data">
      <input type="hidden" name="tracking_submission_id" value={trackingSubmissionId} />
      <input type="hidden" name="receipt_submission_id" value={submissionId} />
      {hasPriorReceipt && correctionAllowed ? <input type="hidden" name="correction_of_receipt_id" value={latestReceiptId ?? ""} /> : null}

      <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
        <h2 className="text-xl font-semibold">Package allocation lines</h2>
        <p className="mt-1 text-sm text-slate-600">Tracking package {trackingLabel}</p>
        <div className="mt-5 space-y-4">
          {rows.map((row, index) => {
            const allocated = formatQty(row.qty_allocated);
            return (
              <article key={row.tracking_line_allocation_id} className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
                <input type="hidden" name="allocation_id" value={row.tracking_line_allocation_id} />
                <input type="hidden" name={`supplier_invoice_line_id_${row.tracking_line_allocation_id}`} value={row.supplier_invoice_line_id} />
                <input type="hidden" name={`allocated_qty_${row.tracking_line_allocation_id}`} value={allocated} />
                <p className="text-xs uppercase tracking-wide text-slate-500">Line {index + 1}</p>
                <h3 className="mt-1 font-semibold">{row.item_description ?? "Unlabelled supplier invoice line"}</h3>
                <span className="mt-2 inline-block rounded-full bg-white px-3 py-1 text-sm font-semibold text-slate-900">Allocated {allocated}</span>
                <div className="mt-4 grid gap-3 md:grid-cols-2">
                  <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-slate-500">Clean quantity</span><input type="number" name={`clean_qty_${row.tracking_line_allocation_id}`} defaultValue={allocated} min="0" step="0.001" required className="w-full rounded-xl border border-slate-300 px-3 py-2" /></label>
                  <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-slate-500">Affected quantity</span><input type="number" name={`affected_qty_${row.tracking_line_allocation_id}`} defaultValue="0" min="0" step="0.001" required className="w-full rounded-xl border border-slate-300 px-3 py-2" /></label>
                  <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-slate-500">Affected disposition</span><select name={`affected_type_${row.tracking_line_allocation_id}`} defaultValue="" className="w-full rounded-xl border border-slate-300 px-3 py-2"><option value="">Not applicable — clean</option><option value="damaged">Damaged</option><option value="missing">Missing</option><option value="wrong">Wrong item</option><option value="held">Held / query</option></select></label>
                  <label className="space-y-1 text-sm"><span className="text-xs uppercase tracking-wide text-slate-500">Condition note for affected quantity</span><input name={`condition_note_${row.tracking_line_allocation_id}`} className="w-full rounded-xl border border-slate-300 px-3 py-2" placeholder="Required only when affected quantity is above zero" /></label>
                </div>
                <p className="mt-3 text-xs text-slate-500">Clean plus affected must equal exactly {allocated}. Choose an affected disposition only when affected quantity is above zero.</p>
              </article>
            );
          })}
        </div>
      </section>

      <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
        <h2 className="text-xl font-semibold">Evidence and correction</h2>
        <div className="mt-4 grid gap-4 md:grid-cols-2">
          <label className="space-y-1 text-sm md:col-span-2">
            <span className="text-xs uppercase tracking-wide text-slate-500">Receipt evidence files</span>
            <input name="receipt_evidence_files" type="file" multiple accept=".pdf,image/*,.png,.jpg,.jpeg,.webp" onChange={handleAttachmentChange} className="w-full rounded-xl border border-slate-300 px-3 py-2" />
            <span className="block text-xs text-slate-500">Required when any line has affected quantity. Large images are automatically optimised before upload.</span>
          </label>
          <p className="text-xs font-semibold text-slate-700 md:col-span-2" aria-live="polite">
            {attachmentsBusy ? `Optimising ${attachmentSummary.count} file${attachmentSummary.count === 1 ? "" : "s"}…` : attachmentSummary.count > 0 ? `${attachmentSummary.count} file${attachmentSummary.count === 1 ? "" : "s"} · ${formatMb(attachmentSummary.uploadBytes)} MB ready` : "No evidence selected"}
          </p>
          {attachmentSummary.optimisedCount > 0 && !attachmentsBusy ? <p className="rounded border border-emerald-200 bg-emerald-50 p-2 text-xs font-medium text-emerald-800 md:col-span-2">Reduced from {formatMb(attachmentSummary.originalBytes)} MB to {formatMb(attachmentSummary.uploadBytes)} MB.</p> : null}
          {attachmentSummary.error ? <p role="alert" className="rounded border border-red-300 bg-red-50 p-2 text-sm font-medium text-red-800 md:col-span-2">{attachmentSummary.error}</p> : null}
          {hasPriorReceipt ? correctionAllowed ? <label className="space-y-1 text-sm md:col-span-2"><span className="text-xs uppercase tracking-wide text-slate-500">Correction reason</span><textarea name="correction_reason" rows={3} required className="w-full rounded-xl border border-slate-300 px-3 py-2" placeholder="Explain the factual correction to the latest receipt" /><span className="block text-xs text-slate-500">This submission will be a complete replacement snapshot of receipt {latestReceiptId}.</span></label> : <p className="rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-900 md:col-span-2">Correction is blocked because the latest physical review is terminal or retailer-linked.</p> : null}
        </div>
      </section>

      <section className="rounded-3xl border border-slate-900 bg-slate-900 p-5 text-white shadow-sm sm:p-6">
        <h2 className="text-xl font-semibold">Final submission</h2>
        <p className="mt-2 text-sm text-slate-300">This writes one immutable finalised receipt snapshot. Review every line before submitting.</p>
        <button type="submit" disabled={submitDisabled} className="mt-4 rounded-xl bg-white px-4 py-2 text-sm font-semibold text-slate-950 disabled:cursor-not-allowed disabled:bg-slate-500 disabled:text-slate-200">{isSubmitting ? "Submitting receipt…" : attachmentsBusy ? "Optimising evidence…" : hasPriorReceipt ? "Submit corrected exact receipt" : "Submit exact physical receipt"}</button>
      </section>
    </form>
  );
}
