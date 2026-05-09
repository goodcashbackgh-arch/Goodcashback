"use client";

import { useEffect } from "react";

const REQUEST_MARKER = "[REFUND_DOCUMENT_OPERATOR_REJECTION_REQUESTED_V1]";
const APPROVED_MARKER = "[REFUND_DOCUMENT_STAFF_RESUBMISSION_APPROVED_V1]";
const BUTTON_MARKER = "data-refund-resubmission-note-action";
const COMPACTED_MARKER = "data-refund-log-compacted";

function extractSubmissionId(text: string) {
  const match = text.match(/refund_evidence_submission_id:\s*([0-9a-fA-F-]{36})/);
  return match?.[1] ?? null;
}

function extractSourceSubmissionId(text: string) {
  const match = text.match(/source_evidence_submission_id:\s*([0-9a-fA-F-]{36})/);
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

function isSmallestMarkerElement(element: HTMLElement, marker: string) {
  return !Array.from(element.children).some((child) => {
    const childText = (child as HTMLElement).innerText ?? "";
    return childText.includes(marker);
  });
}

function approvedSubmissionIds() {
  const ids = new Set<string>();
  const candidates = Array.from(document.querySelectorAll<HTMLElement>("div, article, section, p"));
  for (const element of candidates) {
    const text = element.innerText ?? "";
    if (!text.includes(APPROVED_MARKER)) continue;
    const id = extractSourceSubmissionId(text);
    if (id) ids.add(id);
  }
  return ids;
}

function compactCompletedApprovalLogs() {
  const candidates = Array.from(document.querySelectorAll<HTMLElement>("div, article, section, p"));
  for (const element of candidates) {
    const text = element.innerText ?? "";
    if (!text.includes(APPROVED_MARKER)) continue;
    if (!isSmallestMarkerElement(element, APPROVED_MARKER)) continue;

    const card = findMessageCard(element);
    if (card.hasAttribute(COMPACTED_MARKER)) continue;
    card.setAttribute(COMPACTED_MARKER, "true");

    const reason = text.split("\n").map((line) => line.trim()).filter(Boolean).at(-2) || "Approved; resubmit";
    card.innerHTML = `
      <p class="font-semibold text-slate-900">Resubmission request approved</p>
      <p class="mt-1 text-sm text-slate-600">Operator should submit corrected refund evidence.</p>
      <p class="mt-2 text-sm text-slate-700">${reason}</p>
    `;
  }
}

export default function RefundResubmissionNoteEnhancer() {
  useEffect(() => {
    const run = () => {
      document.querySelectorAll(`[${BUTTON_MARKER}]`).forEach((node) => node.remove());
      compactCompletedApprovalLogs();

      const completedSubmissionIds = approvedSubmissionIds();
      const seenSubmissionIds = new Set<string>();
      const candidates = Array.from(document.querySelectorAll<HTMLElement>("div, article, section, p"));

      for (const element of candidates) {
        const text = element.innerText ?? "";
        if (!text.includes(REQUEST_MARKER)) continue;
        if (!isSmallestMarkerElement(element, REQUEST_MARKER)) continue;

        const submissionId = extractSubmissionId(text);
        if (!submissionId || seenSubmissionIds.has(submissionId)) continue;
        seenSubmissionIds.add(submissionId);
        if (completedSubmissionIds.has(submissionId)) continue;

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
        help.textContent = "Approve the send-back and require corrected evidence.";

        const link = document.createElement("a");
        link.href = `/internal/refund-document-control/${submissionId}/request-resubmission`;
        link.className = "mt-3 inline-flex rounded-xl bg-amber-700 px-4 py-2 font-semibold text-white hover:bg-amber-600";
        link.textContent = "Approve resubmission request";

        panel.appendChild(copy);
        panel.appendChild(help);
        panel.appendChild(link);
        card.appendChild(panel);
      }
    };

    run();
    const timer = window.setInterval(run, 1000);
    return () => window.clearInterval(timer);
  }, []);

  return null;
}
