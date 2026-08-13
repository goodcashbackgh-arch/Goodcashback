"use client";

import { useRouter } from "next/navigation";
import { useEffect, useState, type FormEvent } from "react";
import { createClient } from "@/utils/supabase/client";
import { uploadCorrectionScreenshots } from "./uploadCorrectionScreenshots";

const MAX_ATTACHMENT_BYTES = 3.5 * 1024 * 1024;

type EligibleOrder = {
  importerId: string;
  currentQty: number;
  currentAmount: number;
  originalScreenshotCount: number;
};

function correctionError(message: string) {
  const lower = message.toLowerCase();
  if (lower.includes("processing has started") || lower.includes("downstream evidence")) {
    return "This order can no longer be corrected because processing has started.";
  }
  if (lower.includes("replacement screenshot count")) return message;
  return "We could not save this correction. Refresh the order and try again.";
}

export default function CustomerOrderCorrectionControl({ orderId }: { orderId: string }) {
  const router = useRouter();
  const [eligibleOrder, setEligibleOrder] = useState<EligibleOrder | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [message, setMessage] = useState("");
  const [isError, setIsError] = useState(false);

  useEffect(() => {
    let cancelled = false;
    const supabase = createClient();

    async function loadEligibility() {
      const { data: { user } } = await supabase.auth.getUser();
      if (!user || cancelled) return;

      const { data: operator, error: operatorError } = await supabase
        .from("operators")
        .select("id")
        .eq("auth_user_id", user.id)
        .eq("active", true)
        .maybeSingle();
      if (operatorError || !operator || cancelled) return;

      const { data: operatorImporter, error: assignmentError } = await supabase
        .from("operator_importers")
        .select("importer_id")
        .eq("operator_id", operator.id)
        .is("revoked_at", null)
        .order("id", { ascending: false })
        .limit(1)
        .maybeSingle();
      if (assignmentError || !operatorImporter?.importer_id || cancelled) return;

      const { data: order, error: orderError } = await supabase
        .from("orders")
        .select("id, importer_id, operator_id, order_type, status, total_qty_declared, order_total_gbp_declared, content_locked_at, tracking_locked_at, funded_at, completed_at, accounting_release_ready_at, vat_release_approved_at, vat_return_period")
        .eq("id", orderId)
        .maybeSingle();
      if (orderError || !order || cancelled) return;
      if (order.importer_id !== operatorImporter.importer_id || order.operator_id !== operator.id) return;

      const baseEligible =
        order.order_type === "original" &&
        order.status === "pending_dva_funding" &&
        order.content_locked_at == null &&
        order.tracking_locked_at == null &&
        order.funded_at == null &&
        order.completed_at == null &&
        order.accounting_release_ready_at == null &&
        order.vat_release_approved_at == null &&
        order.vat_return_period == null;
      if (!baseEligible) return;

      const [fundingResult, trackingResult, invoiceResult, screenshotResult, childResult] = await Promise.all([
        supabase.from("order_funding_events").select("id").eq("order_id", orderId).limit(1),
        supabase.from("order_tracking_submissions").select("id").eq("order_id", orderId).limit(1),
        supabase.from("supplier_invoices").select("id").eq("order_id", orderId).limit(1),
        supabase.from("order_screenshots").select("id, note, display_order").eq("order_id", orderId).order("display_order").order("id"),
        supabase.from("orders").select("id").eq("parent_order_id", orderId).limit(1),
      ]);

      if (cancelled) return;
      if (fundingResult.error || trackingResult.error || invoiceResult.error || screenshotResult.error || childResult.error) return;
      if ((fundingResult.data ?? []).length > 0 || (trackingResult.data ?? []).length > 0 || (invoiceResult.data ?? []).length > 0 || (childResult.data ?? []).length > 0) return;

      const screenshots = screenshotResult.data ?? [];
      if (screenshots.some((row) => row.note !== "Original order screenshot")) return;

      const currentQty = Number(order.total_qty_declared ?? 0);
      const currentAmount = Number(order.order_total_gbp_declared ?? 0);
      if (!Number.isInteger(currentQty) || currentQty <= 0 || !Number.isFinite(currentAmount) || currentAmount <= 0) return;

      setEligibleOrder({
        importerId: operatorImporter.importer_id,
        currentQty,
        currentAmount,
        originalScreenshotCount: screenshots.length,
      });
    }

    void loadEligibility();
    return () => {
      cancelled = true;
    };
  }, [orderId]);

  if (!eligibleOrder) return null;

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const currentEligibleOrder = eligibleOrder;
    if (!currentEligibleOrder || submitting) return;

    const form = event.currentTarget;
    if (!form.reportValidity()) return;

    const formData = new FormData(form);
    const totalQty = Number(formData.get("total_qty_declared"));
    const totalAmount = Number(formData.get("order_total_gbp_declared"));
    const replacementFiles = formData
      .getAll("replacement_screenshots")
      .filter((value): value is File => value instanceof File && value.size > 0);

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

    if (replacementFiles.length > 0) {
      if (currentEligibleOrder.originalScreenshotCount < 1 || replacementFiles.length !== currentEligibleOrder.originalScreenshotCount) {
        setIsError(true);
        setMessage(`Select exactly ${currentEligibleOrder.originalScreenshotCount} replacement ${currentEligibleOrder.originalScreenshotCount === 1 ? "attachment" : "attachments"}.`);
        return;
      }
      if (replacementFiles.some((file) => !file.type.startsWith("image/"))) {
        setIsError(true);
        setMessage("Replacement attachments must be images.");
        return;
      }
      if (replacementFiles.reduce((sum, file) => sum + file.size, 0) > MAX_ATTACHMENT_BYTES) {
        setIsError(true);
        setMessage("Replacement attachments must total no more than 3.5 MB.");
        return;
      }
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
        p_order_total_gbp_declared: Math.round(totalAmount * 100) / 100,
        p_replacement_screenshot_urls: replacementUrls,
      });
      if (error) throw new Error(error.message ?? "Correction failed");

      setEligibleOrder((current) => current ? { ...current, currentQty: totalQty, currentAmount: Math.round(totalAmount * 100) / 100 } : current);
      setMessage("Order correction saved.");
      setIsError(false);
      router.refresh();
    } catch (error) {
      const rawMessage = error instanceof Error ? error.message : "Correction failed";
      setIsError(true);
      setMessage(correctionError(rawMessage));
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <div className="bg-slate-50 px-4 pt-4 xl:px-6">
      <section className="mx-auto rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
        <details>
          <summary className="cursor-pointer list-none text-sm font-black text-slate-950">Correct order</summary>
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

            {eligibleOrder.originalScreenshotCount > 0 ? (
              <label className="text-sm font-semibold text-slate-700">
                Replace original attachments <span className="font-normal text-slate-500">(optional)</span>
                <input name="replacement_screenshots" type="file" accept="image/*" multiple className="mt-1 block w-full rounded-xl border border-slate-300 bg-white p-2 text-sm" />
                <span className="mt-1 block text-xs font-medium text-slate-500">
                  This order has {eligibleOrder.originalScreenshotCount} original {eligibleOrder.originalScreenshotCount === 1 ? "attachment" : "attachments"}. To replace them, select exactly {eligibleOrder.originalScreenshotCount}. Total replacement size must be 3.5 MB or less.
                </span>
              </label>
            ) : null}

            {message ? (
              <p role={isError ? "alert" : "status"} className={`rounded-xl border p-3 text-sm font-semibold ${isError ? "border-rose-200 bg-rose-50 text-rose-800" : "border-emerald-200 bg-emerald-50 text-emerald-800"}`}>{message}</p>
            ) : null}

            <div className="flex justify-end">
              <button type="submit" disabled={submitting} className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-black text-white disabled:bg-slate-400">
                {submitting ? "Saving correction…" : "Save correction"}
              </button>
            </div>
          </form>
        </details>
      </section>
    </div>
  );
}
