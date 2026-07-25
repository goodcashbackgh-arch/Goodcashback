"use client";

import { useEffect } from "react";

export type InvoiceTotalPresentation = {
  invoiceId: string;
  invoiceRef: string;
  goodsQty: number;
  lineTotalGbp: number;
  enteredTotalGbp: number | null;
  ocrTotalGbp: number | null;
  deliveryAdjustmentGbp: number;
  discountAdjustmentGbp: number;
};

export type BundleSummary = {
  acceptedEstimateGbp: number;
  activeInvoiceTotalGbp: number;
  activeDeliveryGbp: number;
  activeDiscountGbp: number;
};

type Props = {
  orderId: string;
  fallbackRetailerName?: string;
  invoiceTotals?: InvoiceTotalPresentation[];
  bundleSummary?: BundleSummary | null;
};

function gbp(value: unknown) {
  const amount = Number(value ?? 0);
  return new Intl.NumberFormat("en-GB", {
    style: "currency",
    currency: "GBP",
    minimumFractionDigits: 2,
  }).format(Number.isFinite(amount) ? amount : 0);
}

function findHeading(text: string) {
  return Array.from(document.querySelectorAll("h1,h2,h3")).find((node) => node.textContent?.trim() === text);
}

function setLabelValue(container: Element, label: string, value: string) {
  const labelNode = Array.from(container.querySelectorAll("span")).find((node) => node.textContent?.trim() === label);
  const valueNode = labelNode?.nextElementSibling;
  if (valueNode) valueNode.textContent = value;
}

function closestSupportedInvoiceTotal(invoice: InvoiceTotalPresentation) {
  const canonical = invoice.lineTotalGbp + invoice.deliveryAdjustmentGbp - invoice.discountAdjustmentGbp;
  if (invoice.enteredTotalGbp === null) return canonical;
  const candidates = [
    invoice.lineTotalGbp,
    canonical,
    invoice.lineTotalGbp - invoice.discountAdjustmentGbp,
  ];
  return candidates.reduce((best, candidate) => (
    Math.abs(candidate - Number(invoice.enteredTotalGbp)) < Math.abs(best - Number(invoice.enteredTotalGbp))
      ? candidate
      : best
  ), candidates[0]);
}

export default function OrderOperationsUxCleanup({
  orderId,
  fallbackRetailerName = "",
  invoiceTotals = [],
  bundleSummary = null,
}: Props) {
  useEffect(() => {
    const listenerCleanups: Array<() => void> = [];
    const uploadWarningSelector = "[data-order-bundle-upload-warning='true']";

    if (bundleSummary) {
      const invoiceTotalInputs = Array.from(document.querySelectorAll<HTMLInputElement>("form input[name='invoice_total_gbp']"));
      for (const input of invoiceTotalInputs) {
        const form = input.closest("form");
        if (!form) continue;

        let warning = form.querySelector<HTMLElement>(uploadWarningSelector);
        if (!warning) {
          warning = document.createElement("div");
          warning.setAttribute("data-order-bundle-upload-warning", "true");
          const submitButton = form.querySelector("button[type='submit'], button:not([type])");
          if (submitButton) submitButton.insertAdjacentElement("beforebegin", warning);
          else form.appendChild(warning);
        }

        const renderWarning = () => {
          const candidate = Number(input.value || 0);
          const safeCandidate = Number.isFinite(candidate) && candidate > 0 ? candidate : 0;
          const remainingBeforeUpload = bundleSummary.acceptedEstimateGbp - bundleSummary.activeInvoiceTotalGbp;
          const projectedTotal = bundleSummary.activeInvoiceTotalGbp + safeCandidate;
          const breach = projectedTotal - bundleSummary.acceptedEstimateGbp;

          warning!.className = `md:col-span-3 rounded-xl border p-3 text-xs ${breach > 0.01 ? "border-amber-300 bg-amber-50 text-amber-950" : "border-sky-200 bg-sky-50 text-sky-950"}`;
          warning!.innerHTML = safeCandidate <= 0
            ? `<span class="font-semibold">Remaining accepted estimate before this upload: ${gbp(remainingBeforeUpload)}</span><br />Enter the full gross supplier invoice total. Delivery and discount are classifications already included in that total.`
            : breach > 0.01
              ? `<span class="font-semibold">Warning: this invoice would exceed the accepted estimate by ${gbp(breach)}.</span><br />Projected active gross invoices: ${gbp(projectedTotal)} against ${gbp(bundleSummary.acceptedEstimateGbp)}. Upload is not blocked, but the new invoice will be flagged in the existing supervisor review queue.`
              : `<span class="font-semibold">Within accepted estimate.</span><br />Projected active gross invoices: ${gbp(projectedTotal)}. Remaining after upload: ${gbp(bundleSummary.acceptedEstimateGbp - projectedTotal)}.`;
        };

        input.addEventListener("input", renderWarning);
        renderWarning();
        listenerCleanups.push(() => input.removeEventListener("input", renderWarning));
      }
    } else {
      document.querySelectorAll(uploadWarningSelector).forEach((node) => node.remove());
    }

    const cleanupListeners = () => listenerCleanups.forEach((cleanup) => cleanup());
    const fundingHeading = findHeading("Funding");
    const fundingSection = fundingHeading?.closest("section");
    const fundingPre = fundingSection?.querySelector("pre");

    if (fundingSection && fundingPre && !fundingSection.querySelector("[data-clean-funding-card='true']")) {
      try {
        const parsed = JSON.parse(fundingPre.textContent || "{}");
        const card = document.createElement("div");
        card.setAttribute("data-clean-funding-card", "true");
        card.className = "rounded-2xl border border-slate-200 bg-white p-4 text-sm shadow-sm";
        card.innerHTML = `
          <div class="grid gap-3 md:grid-cols-4">
            <div><div class="text-slate-500">Funding status</div><div class="font-semibold text-slate-950">${parsed.threshold_met_yn ? "funded" : "funding gap"}</div></div>
            <div><div class="text-slate-500">Funded</div><div class="font-semibold text-slate-950">${gbp(parsed.funded_total_gbp)}</div></div>
            <div><div class="text-slate-500">Required</div><div class="font-semibold text-slate-950">${gbp(parsed.purchase_funding_threshold_gbp)}</div></div>
            <div><div class="text-slate-500">Gap</div><div class="font-semibold text-slate-950">${gbp(parsed.gap_remaining_gbp)}</div></div>
          </div>
        `;
        fundingPre.replaceWith(card);
      } catch {
        // Leave the existing output in place if the current page shape changes.
      }
    }

    if (fallbackRetailerName) {
      for (const node of Array.from(document.querySelectorAll("p"))) {
        const text = node.textContent || "";
        if (text.includes("Order retailer expected for invoice matching:") && text.trim().endsWith("—")) {
          node.innerHTML = `Order retailer expected for invoice matching: <span class="font-semibold text-slate-700">${fallbackRetailerName}</span>`;
        }
      }
    }

    const evidenceHeading = findHeading("Order evidence");
    const evidenceSection = evidenceHeading?.closest("section");
    if (!evidenceHeading || !evidenceSection) return cleanupListeners;

    for (const invoice of invoiceTotals) {
      const referenceNode = Array.from(evidenceSection.querySelectorAll("span")).find(
        (node) => node.textContent?.trim() === invoice.invoiceRef,
      );
      const card = referenceNode?.closest("div.rounded-2xl.border.p-4");
      if (!card) continue;

      const matchLink = Array.from(card.querySelectorAll("a")).find(
        (node) => node.textContent?.trim() === "Match evidence",
      );
      if (matchLink) {
        matchLink.setAttribute("href", `/importer/reconciliation/${orderId}?supplier_invoice_id=${encodeURIComponent(invoice.invoiceId)}`);
      }

      const expectedInvoiceTotal = closestSupportedInvoiceTotal(invoice);
      const enteredVariance = invoice.enteredTotalGbp === null ? null : expectedInvoiceTotal - invoice.enteredTotalGbp;
      const ocrVariance = invoice.enteredTotalGbp === null || invoice.ocrTotalGbp === null
        ? null
        : invoice.enteredTotalGbp - invoice.ocrTotalGbp;

      setLabelValue(card, "Accepted estimate", "Order-level only");
      setLabelValue(card, "Expected total", gbp(expectedInvoiceTotal));
      setLabelValue(card, "Variance", enteredVariance === null ? "—" : `${enteredVariance > 0 ? "+" : ""}${gbp(enteredVariance)}`);

      const statusBadge = Array.from(card.querySelectorAll("span")).find((node) => {
        const text = node.textContent?.trim();
        return text === "Evidence total variance" || text === "Evidence total matched";
      });
      if (statusBadge) {
        const matched = ocrVariance !== null && Math.abs(ocrVariance) < 0.01;
        statusBadge.textContent = invoice.ocrTotalGbp === null
          ? "Awaiting OCR total"
          : matched
            ? "Entered total matches OCR"
            : "Entered/OCR total variance";
        statusBadge.className = `rounded-full px-2.5 py-1 text-xs font-semibold ${matched ? "bg-emerald-100 text-emerald-800" : "bg-amber-100 text-amber-800"}`;
      }
    }

    const bundleSelector = "[data-order-invoice-bundle-total='true']";
    const existingBundleSummaries = Array.from(document.querySelectorAll<HTMLElement>(bundleSelector));

    if (!bundleSummary) {
      existingBundleSummaries.forEach((summary) => summary.remove());
      return cleanupListeners;
    }

    // Each entered supplier invoice total is the full gross invoice amount.
    // Delivery/discount rows classify amounts already contained in that total;
    // adding or subtracting them again creates a false variance.
    const variance = bundleSummary.acceptedEstimateGbp - bundleSummary.activeInvoiceTotalGbp;
    const matched = Math.abs(variance) < 0.01;
    const summary = existingBundleSummaries.shift() ?? document.createElement("div");

    // A prior refresh could leave a manually inserted sibling behind. Reuse one
    // card, remove any stale copies, then refresh it from the current server facts.
    existingBundleSummaries.forEach((duplicate) => duplicate.remove());
    summary.setAttribute("data-order-invoice-bundle-total", "true");
    summary.className = `mt-4 rounded-2xl border p-4 text-sm ${matched ? "border-emerald-200 bg-emerald-50 text-emerald-950" : "border-amber-200 bg-amber-50 text-amber-950"}`;
    summary.innerHTML = `
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div>
          <p class="font-semibold">Order invoice bundle total</p>
          <p class="mt-1 text-xs">The accepted estimate is checked once against the sum of all active gross supplier invoice totals. Delivery and discount below are classifications already included in those invoice totals.</p>
        </div>
        <span class="rounded-full px-3 py-1 text-xs font-semibold ${matched ? "bg-emerald-100 text-emerald-800" : "bg-amber-100 text-amber-800"}">${matched ? "Bundle total matched" : "Bundle total variance"}</span>
      </div>
      <div class="mt-3 grid gap-3 md:grid-cols-5">
        <div><span class="text-xs opacity-70">Accepted estimate</span><div class="font-semibold">${gbp(bundleSummary.acceptedEstimateGbp)}</div></div>
        <div><span class="text-xs opacity-70">Delivery included in invoices</span><div class="font-semibold">${gbp(bundleSummary.activeDeliveryGbp)}</div></div>
        <div><span class="text-xs opacity-70">Discount included in invoices</span><div class="font-semibold">-${gbp(bundleSummary.activeDiscountGbp)}</div></div>
        <div><span class="text-xs opacity-70">Active gross invoice total</span><div class="font-semibold">${gbp(bundleSummary.activeInvoiceTotalGbp)}</div></div>
        <div><span class="text-xs opacity-70">Variance</span><div class="font-semibold">${variance > 0 ? "+" : ""}${gbp(variance)}</div></div>
      </div>
    `;

    // Keep the singleton inside the React-owned evidence section so the same
    // scope that finds it also owns its lifecycle on refresh/navigation.
    if (summary.parentElement !== evidenceSection || summary.previousElementSibling !== evidenceHeading) {
      evidenceHeading.insertAdjacentElement("afterend", summary);
    }

    return cleanupListeners;
  }, [bundleSummary, fallbackRetailerName, invoiceTotals, orderId]);

  return null;
}
