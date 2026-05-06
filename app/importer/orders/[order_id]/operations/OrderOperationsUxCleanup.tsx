"use client";

import { useEffect } from "react";

type Props = {
  fallbackRetailerName?: string;
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

export default function OrderOperationsUxCleanup({ fallbackRetailerName = "" }: Props) {
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
  }, [fallbackRetailerName]);

  return null;
}
