"use client";

import { useEffect } from "react";

function textOf(node: Element | null) {
  return node?.textContent?.replace(/\s+/g, " ").trim() ?? "";
}

function valueAfterLabel(article: HTMLElement, label: string) {
  const nodes = Array.from(article.querySelectorAll<HTMLElement>("p, dt"));
  const target = nodes.find((node) => textOf(node).toLowerCase() === label.toLowerCase());
  if (!target) return "—";

  const sibling = target.nextElementSibling;
  const siblingText = textOf(sibling);
  if (siblingText) return siblingText;

  const parentText = textOf(target.parentElement);
  const cleaned = parentText.replace(new RegExp(`^${label}\\s*`, "i"), "").trim();
  return cleaned || "—";
}

function findDecisionText(article: HTMLElement) {
  const panel = Array.from(article.querySelectorAll<HTMLElement>("div"))
    .find((node) => textOf(node).includes("Matching / routing decision"));
  if (!panel) return "—";

  const decision = Array.from(panel.querySelectorAll<HTMLElement>("p"))
    .map((node) => textOf(node))
    .filter(Boolean)
    .find((value) => !value.toLowerCase().includes("matching / routing decision"));

  return decision || "—";
}

function isInvoiceArticle(article: HTMLElement) {
  return Boolean(article.querySelector("a[href*='/internal/evidence/']")) && textOf(article).includes("Header comparison");
}

function compactArticle(article: HTMLElement) {
  if (article.dataset.compactInvoiceReviewApplied === "true") return;
  if (!isInvoiceArticle(article)) return;

  article.dataset.compactInvoiceReviewApplied = "true";
  article.classList.add("gcb-invoice-review-card");

  const header = article.firstElementChild as HTMLElement | null;
  const body = header?.nextElementSibling as HTMLElement | null;
  if (!header || !body) return;

  body.classList.add("gcb-invoice-review-detail-body");
  body.hidden = true;

  const summary = document.createElement("div");
  summary.className = "gcb-invoice-review-summary";

  const operatorRef = valueAfterLabel(article, "Operator ref");
  const ocrRef = valueAfterLabel(article, "OCR ref");
  const operatorTotal = valueAfterLabel(article, "Operator total");
  const ocrTotal = valueAfterLabel(article, "OCR total");
  const ocrRetailer = valueAfterLabel(article, "OCR retailer / supplier");
  const ocrDate = valueAfterLabel(article, "OCR date");
  const reason = findDecisionText(article);

  summary.innerHTML = `
    <div class="gcb-invoice-review-summary-grid">
      <div><span>Operator ref</span><strong>${operatorRef}</strong></div>
      <div><span>OCR ref</span><strong>${ocrRef}</strong></div>
      <div><span>Operator total</span><strong>${operatorTotal}</strong></div>
      <div><span>OCR total</span><strong>${ocrTotal}</strong></div>
      <div><span>OCR retailer</span><strong>${ocrRetailer}</strong></div>
      <div><span>OCR date</span><strong>${ocrDate}</strong></div>
    </div>
    <p class="gcb-invoice-review-reason">${reason}</p>
  `;

  const toggle = document.createElement("button");
  toggle.type = "button";
  toggle.className = "gcb-invoice-review-toggle";
  toggle.textContent = "Open review actions";
  toggle.addEventListener("click", () => {
    const isHidden = body.hidden;
    body.hidden = !isHidden;
    toggle.textContent = isHidden ? "Hide review actions" : "Open review actions";
    article.classList.toggle("gcb-invoice-review-card-open", isHidden);
  });

  const compactBar = document.createElement("div");
  compactBar.className = "gcb-invoice-review-compact-bar";
  compactBar.appendChild(summary);
  compactBar.appendChild(toggle);

  header.insertAdjacentElement("afterend", compactBar);
}

function applyCompactInvoiceReview() {
  const articles = Array.from(document.querySelectorAll<HTMLElement>("article"));
  for (const article of articles) compactArticle(article);
}

export default function CompactInvoiceReviewPatch() {
  useEffect(() => {
    applyCompactInvoiceReview();
    const observer = new MutationObserver(applyCompactInvoiceReview);
    observer.observe(document.body, { childList: true, subtree: true });
    return () => observer.disconnect();
  }, []);

  return (
    <style jsx global>{`
      .gcb-invoice-review-card {
        border-radius: 1.35rem !important;
      }

      .gcb-invoice-review-card > div:first-child {
        padding: 1rem !important;
      }

      .gcb-invoice-review-card h2 {
        margin-top: 0.55rem !important;
        font-size: 1.35rem !important;
        line-height: 1.2 !important;
      }

      .gcb-invoice-review-card a,
      .gcb-invoice-review-card button {
        min-height: 2.25rem !important;
      }

      .gcb-invoice-review-compact-bar {
        border-top: 1px solid rgb(226 232 240);
        background: rgb(248 250 252);
        padding: 0.85rem 1rem 1rem;
      }

      .gcb-invoice-review-summary-grid {
        display: grid;
        grid-template-columns: repeat(6, minmax(0, 1fr));
        gap: 0.55rem;
      }

      .gcb-invoice-review-summary-grid > div {
        border: 1px solid rgb(226 232 240);
        border-radius: 0.85rem;
        background: white;
        padding: 0.6rem 0.7rem;
        min-width: 0;
      }

      .gcb-invoice-review-summary-grid span {
        display: block;
        color: rgb(100 116 139);
        font-size: 0.66rem;
        font-weight: 700;
        letter-spacing: 0.08em;
        text-transform: uppercase;
      }

      .gcb-invoice-review-summary-grid strong {
        display: block;
        margin-top: 0.18rem;
        color: rgb(15 23 42);
        font-size: 0.88rem;
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
      }

      .gcb-invoice-review-reason {
        margin-top: 0.65rem;
        color: rgb(71 85 105);
        font-size: 0.86rem;
        line-height: 1.45;
        display: -webkit-box;
        -webkit-line-clamp: 2;
        -webkit-box-orient: vertical;
        overflow: hidden;
      }

      .gcb-invoice-review-toggle {
        margin-top: 0.75rem;
        border-radius: 999px;
        background: rgb(15 23 42);
        color: white;
        padding: 0.55rem 0.9rem;
        font-size: 0.86rem;
        font-weight: 700;
      }

      .gcb-invoice-review-detail-body[hidden] {
        display: none !important;
      }

      .gcb-invoice-review-card-open .gcb-invoice-review-reason {
        -webkit-line-clamp: unset;
      }

      @media (max-width: 1023px) {
        .gcb-invoice-review-summary-grid {
          grid-template-columns: repeat(2, minmax(0, 1fr));
        }
      }

      @media (max-width: 640px) {
        .gcb-invoice-review-card > div:first-child {
          padding: 0.9rem !important;
        }

        .gcb-invoice-review-card > div:first-child > div {
          gap: 0.75rem !important;
        }

        .gcb-invoice-review-card h2 {
          font-size: 1.55rem !important;
        }

        .gcb-invoice-review-compact-bar {
          padding: 0.75rem 0.85rem 0.9rem;
        }

        .gcb-invoice-review-summary-grid {
          grid-template-columns: 1fr 1fr;
          gap: 0.45rem;
        }

        .gcb-invoice-review-summary-grid > div {
          padding: 0.55rem 0.6rem;
        }

        .gcb-invoice-review-summary-grid span {
          font-size: 0.58rem;
        }

        .gcb-invoice-review-summary-grid strong {
          font-size: 0.82rem;
        }
      }
    `}</style>
  );
}
