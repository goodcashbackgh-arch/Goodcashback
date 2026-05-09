"use client";

import { useEffect } from "react";

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

    if (!alreadyReviewed) continue;

    form.style.display = "none";

    if (!section?.querySelector("[data-return-review-locked]")) {
      const notice = document.createElement("p");
      notice.setAttribute("data-return-review-locked", "true");
      notice.className = "rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-700";
      notice.textContent = "This return/collection evidence row has already been reviewed. If it was held or rejected, the operator should submit corrected/additional return evidence as a new row.";
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
