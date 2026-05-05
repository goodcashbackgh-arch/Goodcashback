"use client";

import { useEffect } from "react";

const FINALISH_STATUSES = [
  "approved_refund",
  "awaiting_refund_credit",
  "refunded",
  "closed",
  "resolved",
  "approved_replacement",
  "replaced",
];

function normalise(value: string) {
  return value.toLowerCase().replace(/\s+/g, " ");
}

function pageHasFinalishStatus(text: string) {
  return FINALISH_STATUSES.some((status) => text.includes(`status ${status}`));
}

function insertWarning(actionCard: HTMLElement, statusText: string) {
  if (actionCard.querySelector("[data-exception-status-guard-warning='true']")) return;

  const warning = document.createElement("div");
  warning.setAttribute("data-exception-status-guard-warning", "true");
  warning.className = "mt-3 rounded-xl border border-amber-200 bg-amber-50 p-3 text-sm font-semibold text-amber-900";
  warning.textContent = statusText.includes("status approved_refund")
    ? "Status mismatch review: this dispute is already marked approved_refund, so refund pursuit must not be approved again. Review retailer evidence/status before further action."
    : "Later-stage exception status detected. Early-stage refund pursuit approval has been disabled for status integrity.";

  const heading = Array.from(actionCard.querySelectorAll("h1,h2,h3,p,strong")).find((node) =>
    normalise(node.textContent ?? "").includes("supervisor actions"),
  );

  if (heading?.parentElement) {
    heading.parentElement.appendChild(warning);
  } else {
    actionCard.prepend(warning);
  }
}

function disableInvalidRefundButtons() {
  const bodyText = normalise(document.body.textContent ?? "");
  if (!pageHasFinalishStatus(bodyText)) return;

  const buttons = Array.from(document.querySelectorAll<HTMLButtonElement>("button"));
  const invalidButtons = buttons.filter((button) => normalise(button.textContent ?? "").includes("approve refund pursuit"));

  for (const button of invalidButtons) {
    button.disabled = true;
    button.setAttribute("aria-disabled", "true");
    button.setAttribute("data-status-guard-disabled", "true");
    button.textContent = "Refund pursuit already passed";
    button.className = "rounded-xl bg-slate-300 px-4 py-3 text-sm font-semibold text-white opacity-70";

    const actionCard = button.closest("section, article, div") as HTMLElement | null;
    if (actionCard) insertWarning(actionCard, bodyText);
  }
}

export default function ExceptionStatusGuard() {
  useEffect(() => {
    disableInvalidRefundButtons();

    const observer = new MutationObserver(() => disableInvalidRefundButtons());
    observer.observe(document.body, { childList: true, subtree: true, characterData: true });

    return () => observer.disconnect();
  }, []);

  return null;
}
