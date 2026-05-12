"use client";

import { useEffect } from "react";

function normalise(value: string) {
  return value.toLowerCase().replace(/\s+/g, " ").trim();
}

function reviewState(sectionText: string) {
  const text = normalise(sectionText);
  if (text.includes("latest structured return evidence · accepted")) return "accepted";
  if (text.includes("latest structured return evidence · hold")) return "hold";
  if (text.includes("latest structured return evidence · rejected")) return "rejected";
  return "reviewed";
}

function statusLabelForState(state: string) {
  if (state === "accepted") return "Operator return evidence accepted";
  if (state === "hold") return "Operator return evidence held";
  if (state === "rejected") return "Operator return evidence rejected";
  return "Operator return evidence reviewed";
}

function nextStepTextForState(state: string) {
  if (state === "accepted") return "Supervisor accepted the operator’s return/collection instructions. Shipper physical collection proof is reviewed separately. Next: wait for operator refund / credit note evidence.";
  return "Operator return/collection evidence has been reviewed. If it was held or rejected, the operator should submit corrected/additional return evidence as a new row.";
}

function rewriteSubmittedStatusBadge(section: HTMLElement, state: string) {
  const nodes = Array.from(section.querySelectorAll<HTMLElement>("p,span,div"));
  const badge = nodes.find((node) => normalise(node.textContent ?? "") === "return/collection evidence submitted");
  if (!badge) return;

  badge.textContent = statusLabelForState(state);
  if (state === "accepted") {
    badge.className = "rounded-full border border-emerald-200 bg-emerald-50 px-3 py-1 text-sm font-semibold text-emerald-900";
  }
}

function rewriteExistingReviewNotice(section: HTMLElement, state: string) {
  const notices = Array.from(section.querySelectorAll<HTMLElement>("p,div"));
  const existing = notices.find((node) =>
    normalise(node.textContent ?? "").includes("a supervisor return/collection evidence review already exists"),
  );

  if (!existing) return false;

  existing.className = state === "accepted"
    ? "rounded-2xl border border-emerald-200 bg-emerald-50 p-4 text-sm text-emerald-900"
    : "rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-900";
  existing.textContent = nextStepTextForState(state);
  return true;
}

function removeOldLockedNotice(section: HTMLElement) {
  const oldNotices = Array.from(section.querySelectorAll<HTMLElement>("[data-return-review-locked]"));
  for (const notice of oldNotices) notice.remove();
}

function run() {
  const forms = Array.from(document.querySelectorAll<HTMLFormElement>("form"));
  for (const form of forms) {
    const text = form.textContent ?? "";
    if (!text.includes("Save return evidence review")) continue;

    const section = form.closest("section") as HTMLElement | null;
    const sectionText = section?.innerText ?? "";
    const alreadyReviewed =
      sectionText.includes("A supervisor return/collection evidence review already exists") ||
      sectionText.includes("Latest structured return evidence · Hold") ||
      sectionText.includes("Latest structured return evidence · Rejected") ||
      sectionText.includes("Latest structured return evidence · Accepted");

    if (!alreadyReviewed || !section) continue;

    const state = reviewState(sectionText);
    form.style.display = "none";
    removeOldLockedNotice(section);
    rewriteSubmittedStatusBadge(section, state);

    const rewroteExistingNotice = rewriteExistingReviewNotice(section, state);
    if (rewroteExistingNotice) continue;

    if (!section.querySelector("[data-return-review-locked]")) {
      const notice = document.createElement("p");
      notice.setAttribute("data-return-review-locked", "true");
      notice.className = state === "accepted"
        ? "rounded-2xl border border-emerald-200 bg-emerald-50 p-4 text-sm text-emerald-900"
        : "rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-900";
      notice.textContent = nextStepTextForState(state);
      form.insertAdjacentElement("beforebegin", notice);
    }
  }
}

export default function ReturnEvidenceReviewEnhancer() {
  useEffect(() => {
    run();
    const timer = window.setInterval(run, 1000);
    return () => window.clearInterval(timer);
  }, []);

  return null;
}
