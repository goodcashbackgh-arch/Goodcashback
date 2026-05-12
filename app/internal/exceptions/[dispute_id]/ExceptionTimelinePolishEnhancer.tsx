"use client";

import { useEffect } from "react";

function normalise(value: string) {
  return value.toLowerCase().replace(/\s+/g, " ").trim();
}

function rewriteRefundEvidenceLabels() {
  const nodes = Array.from(document.querySelectorAll<HTMLElement>("span,p,div"));
  for (const node of nodes) {
    const text = normalise(node.textContent ?? "");
    if (text === "waiting for operator evidence") {
      node.textContent = "Waiting for operator refund / credit note evidence";
    }
    if (text === "return/collection evidence submitted") {
      const section = node.closest("section") as HTMLElement | null;
      const sectionText = normalise(section?.innerText ?? "");
      if (sectionText.includes("latest structured return evidence · accepted")) {
        node.textContent = "Return/collection evidence accepted";
      }
    }
  }
}

function cleanConversationLog() {
  const headings = Array.from(document.querySelectorAll<HTMLElement>("h1,h2,h3"));
  const heading = headings.find((node) => normalise(node.textContent ?? "") === "conversation log");
  if (!heading) return;

  const section = heading.closest("section") as HTMLElement | null;
  if (!section || section.dataset.exceptionTimelinePolished === "true") return;

  const cards = Array.from(section.querySelectorAll<HTMLElement>("article, div"));
  for (const card of cards) {
    const text = card.innerText ?? "";
    const normalised = normalise(text);

    if (normalised.includes("[return_collection_evidence_review_v1]") || normalised.includes("reviewed_by_staff_id")) {
      const accepted = normalised.includes("review_decision: accepted");
      const held = normalised.includes("review_decision: hold");
      const rejected = normalised.includes("review_decision: rejected");
      const dateMatch = text.match(/\d{4}-\d{2}-\d{2}T[^\s]+/);

      card.className = "rounded-2xl border border-emerald-200 bg-emerald-50 p-4 text-sm text-emerald-900";
      card.innerHTML = `
        <p class="font-semibold">Supervisor reviewed return/collection evidence</p>
        <p class="mt-1">Decision: ${accepted ? "Accepted" : held ? "Held / resubmission requested" : rejected ? "Rejected" : "Reviewed"}</p>
        <p class="mt-1 text-xs text-emerald-800">${dateMatch?.[0] ?? ""}</p>
      `;
      continue;
    }

    if (normalised.includes("retailer_reply") && normalised.includes("generated_by_retailer_paste")) {
      const dateMatch = text.match(/\d{4}-\d{2}-\d{2}T[^\s]+/);
      const body = text
        .replace(/retailer_reply\s*·\s*retailer\s*·\s*generated_by_retailer_paste/i, "")
        .replace(dateMatch?.[0] ?? "", "")
        .trim();

      card.className = "rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-800";
      card.innerHTML = `
        <p class="font-semibold">Retailer reply</p>
        <p class="mt-1">${body || "Reply recorded."}</p>
        <p class="mt-1 text-xs text-slate-500">${dateMatch?.[0] ?? ""}</p>
      `;
    }
  }

  section.dataset.exceptionTimelinePolished = "true";
}

function run() {
  rewriteRefundEvidenceLabels();
  cleanConversationLog();
}

export default function ExceptionTimelinePolishEnhancer() {
  useEffect(() => {
    run();
    const timer = window.setInterval(run, 1000);
    return () => window.clearInterval(timer);
  }, []);

  return null;
}
