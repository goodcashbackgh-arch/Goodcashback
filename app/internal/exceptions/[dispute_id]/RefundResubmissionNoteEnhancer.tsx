"use client";

import { useEffect } from "react";

const REQUEST_MARKER = "[REFUND_DOCUMENT_OPERATOR_REJECTION_REQUESTED_V1]";
const BUTTON_MARKER = "data-refund-resubmission-note-action";

function extractSubmissionId(text: string) {
  const match = text.match(/refund_evidence_submission_id:\s*([0-9a-fA-F-]{36})/);
  return match?.[1] ?? null;
}

function findMessageCard(element: HTMLElement) {
  let current: HTMLElement | null = element;
  for (let depth = 0; current && depth < 5; depth += 1) {
    const classes = current.getAttribute("class") ?? "";
    if (classes.includes("rounded") && classes.includes("border")) return current;
    current = current.parentElement;
  }
  return element;
}

export default function RefundResubmissionNoteEnhancer() {
  useEffect(() => {
    const cards = Array.from(document.querySelectorAll<HTMLElement>("div, article, section, p"));

    for (const element of cards) {
      const text = element.innerText ?? "";
      if (!text.includes(REQUEST_MARKER)) continue;

      const submissionId = extractSubmissionId(text);
      if (!submissionId) continue;

      const card = findMessageCard(element);
      if (card.querySelector(`[${BUTTON_MARKER}]`)) continue;

      const panel = document.createElement("div");
      panel.setAttribute(BUTTON_MARKER, "true");
      panel.className = "mt-3 rounded-2xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-950";

      const copy = document.createElement("p");
      copy.className = "font-semibold";
      copy.textContent = "Operator has requested resubmission approval for this refund document.";

      const help = document.createElement("p");
      help.className = "mt-1 text-amber-900";
      help.textContent = "Open the control page to approve the send-back and require corrected evidence.";

      const link = document.createElement("a");
      link.href = `/internal/refund-document-control/${submissionId}/request-resubmission`;
      link.className = "mt-3 inline-flex rounded-xl bg-amber-700 px-4 py-2 font-semibold text-white hover:bg-amber-600";
      link.textContent = "Approve resubmission request";

      panel.appendChild(copy);
      panel.appendChild(help);
      panel.appendChild(link);
      card.appendChild(panel);
    }
  }, []);

  return null;
}
