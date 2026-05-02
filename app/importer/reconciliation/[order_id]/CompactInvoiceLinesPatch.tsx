"use client";

import { useEffect } from "react";

function normaliseSkuInputs(root: ParentNode = document) {
  const inputs = Array.from(root.querySelectorAll<HTMLInputElement>("input"));
  for (const input of inputs) {
    const name = `${input.name ?? ""} ${input.placeholder ?? ""}`.toLowerCase();
    if (!name.includes("sku") && !name.includes("retailer_sku")) continue;
    if (input.value === "[object Object]" || input.defaultValue === "[object Object]") {
      input.value = "";
      input.defaultValue = "";
      input.setAttribute("value", "");
    }
  }
}

function findSectionByHeading(text: string) {
  const headings = Array.from(document.querySelectorAll("h2"));
  const heading = headings.find((node) => node.textContent?.trim().toLowerCase() === text.toLowerCase());
  return heading?.closest("section") as HTMLElement | null;
}

function applyCompactInvoiceLineUi() {
  normaliseSkuInputs();

  const section = findSectionByHeading("Supplier invoice lines");
  if (!section || section.dataset.compactInvoiceLinesApplied === "true") return;
  section.dataset.compactInvoiceLinesApplied = "true";
  section.classList.add("gcb-compact-lines-section");

  const lineArticles = Array.from(section.querySelectorAll<HTMLElement>("article"));
  for (const article of lineArticles) {
    const headerText = article.textContent ?? "";
    if (!headerText.includes("Line ") || !headerText.includes("ocr_extracted")) continue;

    article.classList.add("gcb-compact-line-card");

    const firstInput = article.querySelector<HTMLInputElement>('input[name="line_ids"]');
    if (firstInput) firstInput.classList.add("gcb-compact-line-select");

    const descriptionInput = article.querySelector<HTMLInputElement>('input[name="description"]');
    const qtyInput = article.querySelector<HTMLInputElement>('input[name="qty"]');
    const sizeInput = article.querySelector<HTMLInputElement>('input[name="size"]');
    const skuInput = article.querySelector<HTMLInputElement>('input[name="retailer_sku"]');
    const amountInput = article.querySelector<HTMLInputElement>('input[name="amount_inc_vat_gbp"]');

    if (descriptionInput) descriptionInput.classList.add("gcb-compact-description");
    if (qtyInput) qtyInput.classList.add("gcb-compact-small-field");
    if (sizeInput) sizeInput.classList.add("gcb-compact-small-field");
    if (skuInput) {
      skuInput.classList.add("gcb-compact-small-field");
      if (skuInput.value === "[object Object]") skuInput.value = "";
    }
    if (amountInput) amountInput.classList.add("gcb-compact-money-field");

    const detailGrid = article.querySelector<HTMLElement>(".grid");
    if (detailGrid) detailGrid.classList.add("gcb-compact-line-grid");

    const sourceNote = Array.from(article.querySelectorAll<HTMLElement>("span, p"))
      .find((node) => node.textContent?.includes("OCR source description is preserved"));
    if (sourceNote) sourceNote.classList.add("gcb-compact-audit-note");
  }
}

export default function CompactInvoiceLinesPatch() {
  useEffect(() => {
    applyCompactInvoiceLineUi();

    const observer = new MutationObserver(() => {
      normaliseSkuInputs();
    });

    observer.observe(document.body, { childList: true, subtree: true });
    return () => observer.disconnect();
  }, []);

  return (
    <style jsx global>{`
      .gcb-compact-lines-section {
        padding: 1.25rem !important;
      }

      .gcb-compact-lines-section > div:last-child,
      .gcb-compact-lines-section .space-y-4,
      .gcb-compact-lines-section .space-y-4 > .space-y-4 {
        gap: 0.5rem !important;
      }

      .gcb-compact-line-card {
        border-radius: 1rem !important;
        padding: 0.75rem !important;
      }

      .gcb-compact-line-card > div:first-child {
        margin-bottom: 0.5rem !important;
      }

      .gcb-compact-line-card label,
      .gcb-compact-line-card .space-y-1 {
        gap: 0.15rem !important;
      }

      .gcb-compact-line-card .gcb-compact-line-grid {
        display: grid !important;
        grid-template-columns: minmax(220px, 4fr) 70px 90px 120px 120px auto !important;
        gap: 0.5rem !important;
        align-items: end !important;
      }

      .gcb-compact-line-card input {
        min-height: 2.25rem !important;
        padding: 0.4rem 0.55rem !important;
        border-radius: 0.65rem !important;
        font-size: 0.875rem !important;
      }

      .gcb-compact-description {
        width: 100% !important;
      }

      .gcb-compact-small-field {
        width: 100% !important;
      }

      .gcb-compact-money-field {
        width: 100% !important;
        font-weight: 600 !important;
      }

      .gcb-compact-audit-note {
        display: none !important;
      }

      .gcb-compact-line-card span[class*="uppercase"] {
        font-size: 0.65rem !important;
        letter-spacing: 0.06em !important;
      }

      .gcb-compact-line-card button {
        min-height: 2.25rem !important;
        padding: 0.45rem 0.75rem !important;
        border-radius: 0.75rem !important;
        font-size: 0.8rem !important;
      }

      @media (max-width: 767px) {
        .gcb-compact-lines-section {
          padding: 1rem !important;
        }

        .gcb-compact-line-card {
          padding: 0.7rem !important;
        }

        .gcb-compact-line-card .gcb-compact-line-grid {
          grid-template-columns: minmax(0, 1fr) 64px 76px !important;
          gap: 0.45rem !important;
        }

        .gcb-compact-line-card .gcb-compact-line-grid > label:first-child {
          grid-column: 1 / -1 !important;
        }

        .gcb-compact-line-card .gcb-compact-line-grid > label:nth-child(5) {
          grid-column: 1 / -1 !important;
        }

        .gcb-compact-line-card .gcb-compact-line-grid > div:last-child,
        .gcb-compact-line-card .gcb-compact-line-grid > form:last-child {
          grid-column: 1 / -1 !important;
        }
      }
    `}</style>
  );
}
