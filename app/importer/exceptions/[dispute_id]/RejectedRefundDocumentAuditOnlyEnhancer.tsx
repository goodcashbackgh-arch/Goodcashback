"use client";

import { useEffect } from "react";

const REJECTED_TEXT = "This submission was rejected by supervisor";

function closestCard(element: HTMLElement) {
  let current: HTMLElement | null = element;
  for (let depth = 0; current && depth < 8; depth += 1) {
    const classes = current.getAttribute("class") ?? "";
    if (classes.includes("rounded") && classes.includes("border")) return current;
    current = current.parentElement;
  }
  return element;
}

export default function RejectedRefundDocumentAuditOnlyEnhancer() {
  useEffect(() => {
    const nodes = Array.from(document.querySelectorAll<HTMLElement>("p, div, article"));
    const seen = new Set<HTMLElement>();

    for (const node of nodes) {
      const text = node.innerText ?? "";
      if (!text.includes(REJECTED_TEXT)) continue;

      const card = closestCard(node);
      if (seen.has(card)) continue;
      seen.add(card);

      const reviewLink = Array.from(card.querySelectorAll<HTMLAnchorElement>("a")).find((link) =>
        (link.textContent ?? "").toLowerCase().includes("review refund document lines"),
      );

      if (reviewLink) {
        reviewLink.style.pointerEvents = "none";
        reviewLink.style.color = "#9f1239";
        reviewLink.textContent = "Review disabled — rejected/audit only";
        reviewLink.removeAttribute("href");
      }
    }
  }, []);

  return null;
}
