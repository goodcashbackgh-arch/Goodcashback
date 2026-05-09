"use client";

import { useEffect } from "react";

function run() {
  const articles = Array.from(document.querySelectorAll<HTMLElement>("article"));

  for (const article of articles) {
    if (article.dataset.returnEvidenceDetailsEnhanced === "true") continue;
    const text = article.innerText ?? "";
    if (!text.includes("Latest structured return evidence")) continue;
    if (!text.includes("Courier:") || !text.includes("Tracking ref:")) continue;

    const title = Array.from(article.querySelectorAll<HTMLElement>("p")).find((node) =>
      (node.innerText ?? "").includes("Latest structured return evidence"),
    );
    if (!title) continue;

    const details = Array.from(article.children).filter((child) => child !== title);
    if (details.length === 0) continue;

    const wrapper = document.createElement("div");
    wrapper.setAttribute("data-return-evidence-details-body", "true");
    wrapper.className = "mt-3 hidden space-y-3";

    for (const child of details) {
      wrapper.appendChild(child);
    }

    const header = document.createElement("div");
    header.className = "flex items-center justify-between gap-3";

    const titleClone = title.cloneNode(true) as HTMLElement;
    title.remove();

    const button = document.createElement("button");
    button.type = "button";
    button.className = "shrink-0 rounded-full bg-slate-100 px-3 py-1 text-xs font-semibold text-slate-700 hover:bg-slate-200";
    button.textContent = "View details";

    button.addEventListener("click", () => {
      const hidden = wrapper.classList.contains("hidden");
      wrapper.classList.toggle("hidden", !hidden);
      button.textContent = hidden ? "Hide details" : "View details";
    });

    header.appendChild(titleClone);
    header.appendChild(button);
    article.prepend(header);
    article.appendChild(wrapper);
    article.dataset.returnEvidenceDetailsEnhanced = "true";
  }
}

export default function ReturnEvidenceSupervisorDetailsEnhancer() {
  useEffect(() => {
    run();
    const timer = window.setInterval(run, 1000);
    return () => window.clearInterval(timer);
  }, []);

  return null;
}
