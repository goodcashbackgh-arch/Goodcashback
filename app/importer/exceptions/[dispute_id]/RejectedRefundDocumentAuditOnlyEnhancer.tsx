"use client";

import { useEffect } from "react";

const REJECTED_TEXT = "This submission was rejected by supervisor";

function run() {
  const cards = Array.from(document.querySelectorAll<HTMLElement>("article"));

  for (const card of cards) {
    const cardText = card.innerText ?? "";
    if (!cardText.includes(REJECTED_TEXT) && !cardText.includes("Review: Rejected")) continue;

    const links = Array.from(card.querySelectorAll<HTMLAnchorElement>("a"));
    for (const link of links) {
      const label = (link.textContent ?? "").toLowerCase();
      if (!label.includes("review refund document lines")) continue;

      const span = document.createElement("span");
      span.className = "font-semibold text-rose-700";
      span.textContent = "Review disabled — rejected/audit only";
      link.replaceWith(span);
    }
  }
}

export default function RejectedRefundDocumentAuditOnlyEnhancer() {
  useEffect(() => {
    run();
    const timer = window.setInterval(run, 1000);
    return () => window.clearInterval(timer);
  }, []);

  return null;
}
