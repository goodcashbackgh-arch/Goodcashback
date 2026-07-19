"use client";

import { useEffect } from "react";

export type InvoiceTotalPresentation = {
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

export default function OrderOperationsUxCleanup({
  fallbackRetailerName = "",
  invoiceTotals = [],
  bundleSummary = null,
}: Props) {
  useEffect(() => {
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
    if (!evidenceSection) return;

    for (const invoice of invoiceTotals) {
      const referenceNode = Array.from(evidenceSection.querySelectorAll("span")).find(
        (node) => node.textContent?.trim() === invoice.invoiceRef,
      );
      const card = referenceNode?.closest("div.rounded-2xl.border.p-4");
      if (!card) continue;

      const expectedInvoiceTotal = invoice.lineTotalGbp;
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

    if (bundleSummary && !evidenceSection.querySelector("[data-order-invoice-bundle-total='true']")) {
      const expectedBundleTotal = bundleSummary.acceptedEstimateGbp
        + bundleSummary.activeDeliveryGbp
        - bundleSummary.activeDiscountGbp;
      const variance = expectedBundleTotal - bundleSummary.activeInvoiceTotalGbp;
      const matched = Math.abs(variance) < 0.01;
      const summary = document.createElement("div");
      summary.setAttribute("data-order-invoice-bundle-total", "true");
      summary.className = `mt-4 rounded-2xl border p-4 text-sm ${matched ? "border-emerald-200 bg-emerald-50 text-emerald-950" : "border-amber-200 bg-amber-50 text-amber-950"}`;
      summary.innerHTML = `
        <div class="flex flex-wrap items-center justify-between gap-3">
          <div>
            <p class="font-semibold">Order invoice bundle total</p>
            <p class="mt-1 text-xs">The accepted estimate is checked once against the sum of all active supplier invoices, not repeated against every invoice.</p>
          </div>
          <span class="rounded-full px-3 py-1 text-xs font-semibold ${matched ? "bg-emerald-100 text-emerald-800" : "bg-amber-100 text-amber-800"}">${matched ? "Bundle total matched" : "Bundle total variance"}</span>
        </div>
        <div class="mt-3 grid gap-3 md:grid-cols-5">
          <div><span class="text-xs opacity-70">Accepted estimate</span><div class="font-semibold">${gbp(bundleSummary.acceptedEstimateGbp)}</div></div>
          <div><span class="text-xs opacity-70">Delivery</span><div class="font-semibold">${gbp(bundleSummary.activeDeliveryGbp)}</div></div>
          <div><span class="text-xs opacity-70">Discount</span><div class="font-semibold">-${gbp(bundleSummary.activeDiscountGbp)}</div></div>
          <div><span class="text-xs opacity-70">Active invoice total</span><div class="font-semibold">${gbp(bundleSummary.activeInvoiceTotalGbp)}</div></div>
          <div><span class="text-xs opacity-70">Variance</span><div class="font-semibold">${variance > 0 ? "+" : ""}${gbp(variance)}</div></div>
        </div>
      `;
      evidenceHeading?.parentElement?.insertAdjacentElement("afterend", summary);
    }
  }, [bundleSummary, fallbackRetailerName, invoiceTotals]);

  return null;
}
