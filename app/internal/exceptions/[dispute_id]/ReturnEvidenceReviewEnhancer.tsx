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

function rewriteExistingReviewNotice(section: HTMLElement, state: string) {
  const notices = Array.from(section.querySelectorAll<HTMLElement>("p,div"));
  const existing = notices.find((node) =>
    normalise(node.textContent ?? "").includes("a supervisor return/collection evidence review already exists"),
  );

  if (!existing) return false;

  existing.className = state === "accepted"
    ? "rounded-2xl border border-emerald-200 bg-emerald-50 p-4 text-sm text-emerald-900"
    : "rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-900";
  existing.textContent = state === "accepted"
    ? "Return/collection evidence accepted. Next: wait for operator refund / credit note evidence."
    : "Return/collection evidence has been reviewed. If it was held or rejected, the operator should submit corrected/additional return evidence as a new row.";
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

    const rewroteExistingNotice = rewriteExistingReviewNotice(section, state);
    if (rewroteExistingNotice) continue;

    if (!section.querySelector("[data-return-review-locked]")) {
      const notice = document.createElement("p");
      notice.setAttribute("data-return-review-locked", "true");
      notice.className = state === "accepted"
        ? "rounded-2xl border border-emerald-200 bg-emerald-50 p-4 text-sm text-emerald-900"
        : "rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-900";
      notice.textContent = state === "accepted"
        ? "Return/collection evidence accepted. Next: wait for operator refund / credit note evidence."
        : "Return/collection evidence has been reviewed. If it was held or rejected, the operator should submit corrected/additional return evidence as a new row.";
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
