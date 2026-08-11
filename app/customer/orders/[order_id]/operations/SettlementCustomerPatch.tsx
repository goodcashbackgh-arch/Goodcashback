"use client";

import { useEffect } from "react";

function money(value: number) {
  return new Intl.NumberFormat("en-GB", {
    style: "currency",
    currency: "GBP",
    minimumFractionDigits: 2,
  }).format(value);
}

function clarifyPaymentAppliedLabel(args: {
  finalSaleValueConfirmed: boolean;
  confirmedPaymentGbp: number;
}) {
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  const nodes: Text[] = [];

  while (walker.nextNode()) {
    if (walker.currentNode instanceof Text) nodes.push(walker.currentNode);
  }

  for (const node of nodes) {
    const value = (node.nodeValue ?? "").trim();
    if (value !== "Amount received" && value !== "Payment applied to this order") continue;

    if (value === "Amount received") {
      node.nodeValue = "Payment applied to this order";
    }

    if (!args.finalSaleValueConfirmed) {
      const labelElement = node.parentElement;
      const amountElement = labelElement?.nextElementSibling;
      const expectedAmount = money(args.confirmedPaymentGbp);

      if (amountElement && amountElement.textContent?.trim() !== expectedAmount) {
        amountElement.textContent = expectedAmount;
      }
    }
  }
}

export default function SettlementCustomerPatch({
  finalSaleValueConfirmed,
  confirmedPaymentGbp,
}: {
  finalSaleValueConfirmed: boolean;
  confirmedPaymentGbp: number;
}) {
  useEffect(() => {
    const applyPatch = () =>
      clarifyPaymentAppliedLabel({ finalSaleValueConfirmed, confirmedPaymentGbp });

    applyPatch();
    const observer = new MutationObserver(applyPatch);
    observer.observe(document.body, { childList: true, subtree: true, characterData: true });
    return () => observer.disconnect();
  }, [finalSaleValueConfirmed, confirmedPaymentGbp]);

  return null;
}
