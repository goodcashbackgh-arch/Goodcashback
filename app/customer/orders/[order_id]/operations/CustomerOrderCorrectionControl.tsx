"use client";

import { useRouter } from "next/navigation";
import { useEffect, useRef, useState, type ChangeEvent, type FormEvent } from "react";
import { createClient } from "@/utils/supabase/client";
import { uploadCorrectionScreenshots } from "./uploadCorrectionScreenshots";

const MAX_ATTACHMENT_BYTES = 3.5 * 1024 * 1024;
const TARGET_ATTACHMENT_BYTES = 3.1 * 1024 * 1024;
const COMPRESSION_TRIGGER_BYTES = 700 * 1024;
const MAX_FILE_TARGET_BYTES = 900 * 1024;
const MIN_FILE_TARGET_BYTES = 300 * 1024;
const MAX_IMAGE_DIMENSIONS = [1800, 1500, 1200];
const JPEG_QUALITIES = [0.86, 0.76, 0.66];

type AttachmentSummary = {
  count: number;
  uploadBytes: number;
  status: "idle" | "optimising" | "ready";
  error: string;
};

type EligibilityState = "loading" | "eligible" | "blocked" | "check_failed";

type EligibleOrder = {
  importerId: string;
  currentQty: number;
  currentAmount: number;
};

function correctionError(message: string) {
  const lower = message.toLowerCase();
  if (lower.includes("processing has started") || lower.includes("downstream evidence")) {
    return "This order can no longer be corrected because processing has started.";
  }
  if (lower.includes("funding") && lower.includes("postcondition failed")) {
    return "This order can no longer be corrected because its funding changed while you were editing.";
  }
  if (lower.includes("credit funding event and ledger position disagree")) {
    return "This order can no longer be corrected because its credit funding records do not agree.";
  }
  if (lower.includes("non-credit funding has started")) {
    return "This order can no longer be corrected because non-credit funding has started.";
  }
  if (lower.includes("does not belong to the active customer/operator assignment") || lower.includes("active customer/operator assignment not found")) {
    return "This order is not available for correction from this customer account.";
  }
  if (lower.includes("corrected value would require credit release or financial-state repair")) {
    return "This goods value would require account credit to be released or repaired. Enter a value that leaves an amount still due, or leave it unchanged.";
  }
  if (lower.includes("fully funded value correction must increase goods value beyond existing credit funding")) {
    return "A fully credit-funded order can only change to a higher goods value that leaves a new amount due.";
  }
  if (lower.includes("replacement screenshot count")) return message;
  return "We could not save this correction. Refresh the order and try again.";
}

function isAuthoritativeBlocker(message: string) {
  const lower = message.toLowerCase();
  return lower.includes("processing has started")
    || lower.includes("downstream evidence")
    || (lower.includes("funding") && lower.includes("postcondition failed"))
    || lower.includes("credit funding event and ledger position disagree")
    || lower.includes("non-credit funding has started")
    || lower.includes("does not belong to the active customer/operator assignment")
    || lower.includes("active customer/operator assignment not found");
}

function eligibilityCheckFailedMessage() {
  return "We could not check whether this order can be corrected. Refresh the order and try again.";
}

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
    image.onload = () => { URL.revokeObjectURL(objectUrl); resolve(image); };
    image.onerror = () => { URL.revokeObjectURL(objectUrl); reject(new Error(`Could not read ${file.name}`)); };
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
  try { image = await loadImage(file); } catch { return file; }
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

export default function CustomerOrderCorrectionControl({ orderId }: { orderId: string }) {
  const router = useRouter();
  const [eligibleOrder, setEligibleOrder] = useState<EligibleOrder | null>(null);
  const [eligibilityState, setEligibilityState] = useState<EligibilityState>("loading");
  const [eligibilityMessage, setEligibilityMessage] = useState("");
  const [eligibilityAttempt, setEligibilityAttempt] = useState(0);
  const [submitting, setSubmitting] = useState(false);
  const [message, setMessage] = useState("");
  const [isError, setIsError] = useState(false);
  const [isOpen, setIsOpen] = useState(false);
  const preparedFilesRef = useRef<File[]>([]);
  const selectionVersionRef = useRef(0);
  const [attachmentSummary, setAttachmentSummary] = useState<AttachmentSummary>({ count: 0, uploadBytes: 0, status: "idle", error: "" });

  async function handleAttachmentChange(event: ChangeEvent<HTMLInputElement>) {
    const input = event.currentTarget;
    const files = Array.from(input.files ?? []);
    const selectionVersion = ++selectionVersionRef.current;
    preparedFilesRef.current = [];
    if (files.length === 0) {
      setAttachmentSummary({ count: 0, uploadBytes: 0, status: "idle", error: "" });
      return;
    }
    if (files.some((file) => !file.type.startsWith("image/"))) {
      input.value = "";
      setAttachmentSummary({ count: 0, uploadBytes: 0, status: "idle", error: "Replacement attachments must be images." });
      return;
    }
    setAttachmentSummary({ count: files.length, uploadBytes: files.reduce((sum, file) => sum + file.size, 0), status: "optimising", error: "" });
    const targetPerFile = Math.max(MIN_FILE_TARGET_BYTES, Math.min(MAX_FILE_TARGET_BYTES, Math.floor(TARGET_ATTACHMENT_BYTES / files.length)));
    try {
      const preparedFiles: File[] = [];
      for (const file of files) preparedFiles.push(await optimiseImage(file, targetPerFile));
      if (selectionVersionRef.current !== selectionVersion) return;
      const uploadBytes = preparedFiles.reduce((sum, file) => sum + file.size, 0);
      if (uploadBytes > MAX_ATTACHMENT_BYTES) {
        input.value = "";
        preparedFilesRef.current = [];
        setAttachmentSummary({ count: 0, uploadBytes: 0, status: "idle", error: `These attachments remain ${formatMb(uploadBytes)} MB after automatic optimisation. Please remove one attachment and try again.` });
        return;
      }
      preparedFilesRef.current = preparedFiles;
      setAttachmentSummary({ count: preparedFiles.length, uploadBytes, status: "ready", error: "" });
    } catch {
      if (selectionVersionRef.current !== selectionVersion) return;
      input.value = "";
      preparedFilesRef.current = [];
      setAttachmentSummary({ count: 0, uploadBytes: 0, status: "idle", error: "We could not prepare those attachments. Please select them again." });
    }
  }

  useEffect(() => {
    let cancelled = false;
    const supabase = createClient();

    function failCheck() {
      if (cancelled) return;
      setEligibleOrder(null);
      setEligibilityState("check_failed");
      setEligibilityMessage(eligibilityCheckFailedMessage());
    }

    async function loadEligibility() {
      setEligibleOrder(null);
      setEligibilityState("loading");
      setEligibilityMessage("");

      const { data: { user }, error: userError } = await supabase.auth.getUser();
      if (userError || !user || cancelled) {
        failCheck();
        return;
      }

      const { data: order, error: orderError } = await supabase
        .from("orders")
        .select("id, importer_id, total_qty_declared, order_total_gbp_declared")
        .eq("id", orderId)
        .maybeSingle();
      if (orderError || !order || cancelled) {
        failCheck();
        return;
      }

      const currentQty = Number(order.total_qty_declared ?? 0);
      const currentAmount = Number(order.order_total_gbp_declared ?? 0);
      if (!order.importer_id || !Number.isInteger(currentQty) || currentQty <= 0 || !Number.isFinite(currentAmount) || currentAmount <= 0) {
        failCheck();
        return;
      }

      const roundedAmount = Math.round(currentAmount * 100) / 100;
      const { error: eligibilityError } = await (supabase as any).rpc("customer_order_correction_eligibility_v1", {
        p_order_id: orderId,
      });
      if (cancelled) return;
      if (eligibilityError) {
        const rawMessage = eligibilityError.message ?? "Eligibility check failed";
        setEligibleOrder(null);
        if (isAuthoritativeBlocker(rawMessage)) {
          setEligibilityState("blocked");
          setEligibilityMessage(correctionError(rawMessage));
        } else {
          setEligibilityState("check_failed");
          setEligibilityMessage(eligibilityCheckFailedMessage());
        }
        return;
      }

      setEligibleOrder({
        importerId: order.importer_id,
        currentQty,
        currentAmount: roundedAmount,
      });
      setEligibilityState("eligible");
      setEligibilityMessage("");
    }

    void loadEligibility();
    return () => {
      cancelled = true;
    };
  }, [orderId, eligibilityAttempt]);

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const currentEligibleOrder = eligibleOrder;
    if (!currentEligibleOrder || submitting) return;

    const form = event.currentTarget;
    if (!form.reportValidity()) return;

    const formData = new FormData(form);
    const totalQty = Number(formData.get("total_qty_declared"));
    const totalAmount = Number(formData.get("order_total_gbp_declared"));
    const replacementSelected = formData.getAll("replacement_screenshots").some((value) => value instanceof File && value.size > 0);
    const replacementFiles = preparedFilesRef.current;

    if (!Number.isInteger(totalQty) || totalQty <= 0) {
      setIsError(true);
      setMessage("Total quantity declared must be a positive integer.");
      return;
    }
    if (!Number.isFinite(totalAmount) || totalAmount <= 0) {
      setIsError(true);
      setMessage("Order total GBP declared must be greater than 0.");
      return;
    }

    const roundedAmount = Math.round(totalAmount * 100) / 100;

    if (replacementSelected && (attachmentSummary.status !== "ready" || replacementFiles.length < 1)) return;
    if (replacementFiles.length > 0 && replacementFiles.reduce((sum, file) => sum + file.size, 0) > MAX_ATTACHMENT_BYTES) {
      setIsError(true);
      setMessage("Replacement attachments must total no more than 3.5 MB.");
      return;
    }

    setSubmitting(true);
    setMessage("");
    setIsError(false);

    try {
      const replacementUrls = replacementFiles.length > 0
        ? await uploadCorrectionScreenshots({ orderId, importerId: currentEligibleOrder.importerId, files: replacementFiles })
        : null;
      const supabase = createClient();
      const { error } = await (supabase as any).rpc("customer_correct_unprocessed_order_v1", {
        p_order_id: orderId,
        p_total_qty_declared: totalQty,
        p_order_total_gbp_declared: roundedAmount,
        p_replacement_screenshot_urls: replacementUrls,
      });
      if (error) throw new Error(error.message ?? "Correction failed");

      setEligibleOrder((current) => current ? {
        ...current,
        currentQty: totalQty,
        currentAmount: roundedAmount,
      } : current);
      preparedFilesRef.current = [];
      selectionVersionRef.current += 1;
      setAttachmentSummary({ count: 0, uploadBytes: 0, status: "idle", error: "" });
      form.reset();
      setIsOpen(false);
      setMessage("Order correction saved.");
      setIsError(false);
      router.refresh();
    } catch (error) {
      const rawMessage = error instanceof Error ? error.message : "Correction failed";
      if (isAuthoritativeBlocker(rawMessage)) {
        setEligibleOrder(null);
        setEligibilityState("blocked");
        setEligibilityMessage(correctionError(rawMessage));
      } else {
        setIsError(true);
        setMessage(correctionError(rawMessage));
      }
    } finally {
      setSubmitting(false);
    }
  }

  if (eligibilityState === "loading") {
    return (
      <div className="bg-slate-50 px-4 pt-3 xl:px-6">
        <section className="mx-auto rounded-xl border border-slate-200 bg-white px-3 py-2 text-xs font-semibold text-slate-600">
          Checking correction availability…
        </section>
      </div>
    );
  }

  if (eligibilityState === "blocked") {
    return (
      <div className="bg-slate-50 px-4 pt-3 xl:px-6">
        <section className="mx-auto rounded-xl border border-slate-200 bg-white p-3">
          <p className="text-xs font-black uppercase tracking-wide text-slate-500">Order correction</p>
          <p className="mt-1 text-sm font-semibold text-slate-700">{eligibilityMessage}</p>
        </section>
      </div>
    );
  }

  if (eligibilityState === "check_failed" || !eligibleOrder) {
    return (
      <div className="bg-slate-50 px-4 pt-3 xl:px-6">
        <section className="mx-auto rounded-xl border border-amber-200 bg-amber-50 p-3 text-amber-950">
          <p className="text-xs font-black uppercase tracking-wide">Order correction</p>
          <p className="mt-1 text-sm font-semibold">{eligibilityMessage || eligibilityCheckFailedMessage()}</p>
          <button type="button" onClick={() => setEligibilityAttempt((current) => current + 1)} className="mt-2 rounded-lg border border-amber-300 bg-white px-3 py-1.5 text-xs font-black text-amber-950">Check again</button>
        </section>
      </div>
    );
  }

  return (
    <div className="bg-slate-50 px-4 pt-3 xl:px-6">
      <section className="mx-auto">
        <details open={isOpen} onToggle={(event) => setIsOpen(event.currentTarget.open)}>
          <summary className="inline-flex cursor-pointer list-none rounded-lg border border-sky-600 bg-sky-600 px-3 py-1.5 text-xs font-black text-white shadow-sm hover:bg-sky-700">Correct order</summary>
          <div className="mt-3 rounded-2xl border border-slate-200 bg-white p-4 shadow-sm">
            <p className="mt-2 text-sm text-slate-600">You can correct the quantity, goods value or original attachments only before processing starts.</p>
            <form onSubmit={handleSubmit} className="mt-4 grid gap-4" encType="multipart/form-data">
              <div className="grid gap-3 sm:grid-cols-2">
                <label className="text-sm font-semibold text-slate-700">
                  Quantity
                  <input name="total_qty_declared" type="number" min="1" step="1" required defaultValue={eligibleOrder.currentQty} className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-slate-950" />
                </label>
                <label className="text-sm font-semibold text-slate-700">
                  Goods value
                  <div className="mt-1 flex rounded-xl border border-slate-300 bg-white">
                    <span className="px-3 py-2 font-semibold text-slate-500">£</span>
                    <input name="order_total_gbp_declared" type="number" min="0.01" step="0.01" required defaultValue={eligibleOrder.currentAmount.toFixed(2)} className="min-w-0 flex-1 rounded-r-xl px-2 py-2 text-slate-950 outline-none" />
                  </div>
                </label>
              </div>

              <label className="text-sm font-semibold text-slate-700">
                Replace original attachments <span className="font-normal text-slate-500">(optional)</span>
                <input name="replacement_screenshots" type="file" accept="image/*" multiple onChange={handleAttachmentChange} className="mt-1 block w-full rounded-xl border border-slate-300 bg-white p-2 text-sm" />
                <span className="mt-1 block text-xs font-medium text-slate-500">Select one or more images to replace the complete existing set of original attachments. Prepared replacements must total 3.5 MB or less.</span>
                {attachmentSummary.status === "optimising" ? <span className="mt-1 block text-xs text-slate-500">Optimising attachments…</span> : null}
                {attachmentSummary.status === "ready" ? <span className="mt-1 block text-xs text-slate-500">{attachmentSummary.count} {attachmentSummary.count === 1 ? "image" : "images"} ready ({formatMb(attachmentSummary.uploadBytes)} MB).</span> : null}
                {attachmentSummary.error ? <span role="alert" className="mt-1 block text-xs font-semibold text-rose-700">{attachmentSummary.error}</span> : null}
              </label>

              {message ? (
                <p role={isError ? "alert" : "status"} className={`rounded-xl border p-3 text-sm font-semibold ${isError ? "border-rose-200 bg-rose-50 text-rose-800" : "border-emerald-200 bg-emerald-50 text-emerald-800"}`}>{message}</p>
              ) : null}

              <div className="flex justify-end">
                <button type="submit" disabled={submitting || attachmentSummary.status === "optimising" || Boolean(attachmentSummary.error)} className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-black text-white disabled:bg-slate-400">
                  {submitting ? "Saving correction…" : "Save correction"}
                </button>
              </div>
            </form>
          </div>
        </details>
      </section>
    </div>
  );
}
