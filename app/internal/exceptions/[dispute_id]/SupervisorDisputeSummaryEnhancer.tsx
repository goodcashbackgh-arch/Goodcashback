"use client";

import { useEffect } from "react";

function readableDisputeRef(disputeId: string) {
  return `DSP-${disputeId.replaceAll("-", "").slice(0, 8).toUpperCase()}`;
}

export default function SupervisorDisputeSummaryEnhancer({
  disputeId,
  disputeAmount,
  affectedLineCount,
  unresolvedLineCount,
}: {
  disputeId: string;
  disputeAmount: number;
  affectedLineCount: number;
  unresolvedLineCount: number;
}) {
  useEffect(() => {
    const heading = Array.from(document.querySelectorAll("h1")).find((node) =>
      node.textContent?.trim().startsWith("Dispute "),
    );
    if (heading) heading.textContent = `Dispute ${readableDisputeRef(disputeId)}`;

    const cards = Array.from(document.querySelectorAll("div.rounded-2xl"));
    for (const card of cards) {
      const label = card.querySelector("p:first-child")?.textContent?.trim().toLowerCase();
      const value = card.querySelector("p:nth-child(2)");
      if (!value) continue;
      if (label === "declared value") {
        card.querySelector("p:first-child")!.textContent = "Dispute amount";
        value.textContent = new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP", minimumFractionDigits: 2 }).format(disputeAmount);
      }
      if (label === "progressed lines") {
        card.querySelector("p:first-child")!.textContent = "Affected lines";
        value.textContent = String(affectedLineCount);
      }
      if (label === "unresolved lines") {
        card.querySelector("p:first-child")!.textContent = "Unresolved dispute lines";
        value.textContent = String(unresolvedLineCount);
      }
    }
  }, [affectedLineCount, disputeAmount, disputeId, unresolvedLineCount]);

  return null;
}
