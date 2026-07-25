"use client";

import { useEffect } from "react";

function normalise(value: string | null | undefined) {
  return String(value ?? "").trim().replace(/\s+/g, " ").toLowerCase();
}

function applyRefundInCopyFix() {
  document
    .querySelectorAll<HTMLAnchorElement>('a[href*="category=retailer_refund_received"]')
    .forEach((link) => {
      const labels = link.querySelectorAll("p");
      const detail = labels.item(1);
      if (detail && normalise(detail.textContent) === "endpoint prove required") {
        detail.textContent = "Posts after supplier credit";
      }
    });

  document.querySelectorAll<HTMLTableRowElement>("tr").forEach((row) => {
    const isRetailerRefundRow = Array.from(row.querySelectorAll("td")).some((cell) =>
      normalise(cell.textContent).includes("retailer refund received"),
    );
    if (!isRetailerRefundRow) return;

    row.querySelectorAll<HTMLElement>("span").forEach((status) => {
      if (normalise(status.textContent) === "blocked endpoint prove required") {
        status.textContent = "waiting for supplier credit";
      }
    });

    row.querySelectorAll<HTMLParagraphElement>("p").forEach((message) => {
      const current = normalise(message.textContent);
      if (current.includes("endpoint prove required") || current.includes("endpoint proof")) {
        message.textContent = "Supplier credit/equivalent must post to Sage first.";
      }
    });
  });
}

export default function RefundInLegacyStatusCopyFix() {
  useEffect(() => {
    let frame = 0;
    const schedule = () => {
      window.cancelAnimationFrame(frame);
      frame = window.requestAnimationFrame(applyRefundInCopyFix);
    };

    schedule();
    const observer = new MutationObserver(schedule);
    observer.observe(document.body, { childList: true, subtree: true });

    return () => {
      observer.disconnect();
      window.cancelAnimationFrame(frame);
    };
  }, []);

  return null;
}
