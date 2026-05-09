"use client";

import { useEffect } from "react";

type LineMeta = {
  id: string;
  retailer_sku: string | null;
  size: string | null;
  qty: number | null;
};

type AuditStatus = {
  auditOnly?: boolean;
};

function parseMoney(text: string | null | undefined) {
  const parsed = Number(String(text ?? "").replace(/[^0-9.-]/g, ""));
  return Number.isFinite(parsed) ? parsed : 0;
}

function splitGross(grossValue: number, rateValue: number) {
  const rate = Number.isFinite(rateValue) ? rateValue : 20;
  const net = Math.round((grossValue / (1 + rate / 100)) * 100) / 100;
  const vat = Math.round((grossValue - net) * 100) / 100;
  return { net, vat };
}

function taxLabel(rate: number) {
  if (rate === 20) return "20% standard";
  if (rate === 5) return "5% reduced";
  return "0% zero/exempt";
}

function taxId(rate: number) {
  if (rate === 20) return "STANDARD_20";
  if (rate === 5) return "REDUCED_5";
  return "ZERO_0";
}

function setInputValue(input: HTMLInputElement | null, value: string, onlyIfEmpty = false) {
  if (!input) return;
  if (onlyIfEmpty && input.value.trim()) return;
  input.value = value;
  input.dispatchEvent(new Event("input", { bubbles: true }));
  input.dispatchEvent(new Event("change", { bubbles: true }));
}

function nearestSection(element: Element | null) {
  return element?.closest("section") as HTMLElement | null;
}

function hideActiveControlSections() {
  const sections = Array.from(document.querySelectorAll<HTMLElement>("section"));
  for (const section of sections) {
    const title = section.querySelector("h2")?.textContent?.trim().toLowerCase() ?? "";
    if (
      title.includes("supplier credit document lines") ||
      title.includes("accounting coding") ||
      title.includes("manual accounting adjustment") ||
      title.includes("approve supplier credit")
    ) {
      section.style.display = "none";
    }
  }

  const releaseForms = Array.from(document.querySelectorAll<HTMLFormElement>('form[action]'));
  for (const form of releaseForms) {
    const text = form.textContent?.toLowerCase() ?? "";
    if (text.includes("release selected lines") || text.includes("save all coding") || text.includes("approve current")) {
      const section = nearestSection(form);
      if (section) section.style.display = "none";
      else form.style.display = "none";
    }
  }
}

function insertAuditOnlyBanner() {
  if (document.querySelector("[data-refund-audit-only-banner]")) return;
  const mainContainer = document.querySelector("main .mx-auto") ?? document.querySelector("main");
  if (!mainContainer) return;

  const banner = document.createElement("section");
  banner.setAttribute("data-refund-audit-only-banner", "true");
  banner.className = "rounded-3xl border border-rose-200 bg-rose-50 p-5 text-sm text-rose-900 shadow-sm";
  banner.innerHTML = `
    <h2 class="text-lg font-semibold text-rose-950">Rejected refund document — audit only</h2>
    <p class="mt-2">This submission was rejected and removed from the active refund-control path. It cannot be released, coded, adjusted, approved, or used for Sage readiness.</p>
    <p class="mt-2 font-semibold">The operator must submit corrected refund evidence. The corrected upload starts the refund-document flow again from step 1.</p>
  `;

  const firstChild = mainContainer.children[1] ?? mainContainer.firstChild;
  mainContainer.insertBefore(banner, firstChild);
}

function enhanceReleaseTable(metaById: Map<string, LineMeta>) {
  const releaseCheckboxes = Array.from(document.querySelectorAll<HTMLInputElement>('input[name="line_ids"]'));
  const releaseTable = releaseCheckboxes
    .map((input) => input.closest("table"))
    .find((table) => table?.textContent?.includes("Gross credit value"));

  if (!releaseTable || releaseTable.dataset.skuSizeEnhanced === "true") return;

  const headerRow = releaseTable.querySelector("thead tr");
  if (!headerRow) return;
  const headerCells = Array.from(headerRow.children).map((cell) => cell.textContent?.trim().toLowerCase());
  if (!headerCells.includes("sku")) {
    const descriptionHeader = Array.from(headerRow.children).find((cell) => cell.textContent?.trim().toLowerCase() === "description");
    if (descriptionHeader) {
      descriptionHeader.insertAdjacentHTML("afterend", '<th class="p-3">SKU</th><th class="p-3">Size</th>');
    }
  }

  for (const row of Array.from(releaseTable.querySelectorAll("tbody tr"))) {
    const checkbox = row.querySelector<HTMLInputElement>('input[name="line_ids"]');
    if (!checkbox) continue;
    const meta = metaById.get(checkbox.value);
    const cells = Array.from(row.children);
    if (cells.some((cell) => cell.getAttribute("data-refund-meta") === "sku")) continue;
    const descriptionCell = cells[3];
    if (!descriptionCell) continue;
    const sku = meta?.retailer_sku?.trim() || "—";
    const size = meta?.size?.trim() || "—";
    descriptionCell.insertAdjacentHTML(
      "afterend",
      `<td class="p-3" data-refund-meta="sku">${sku}</td><td class="p-3" data-refund-meta="size">${size}</td>`,
    );
  }

  releaseTable.dataset.skuSizeEnhanced = "true";
}

function enhanceCodingRows(metaById: Map<string, LineMeta>) {
  const lineInputs = Array.from(document.querySelectorAll<HTMLInputElement>('input[name="line_ids"]'));
  for (const lineInput of lineInputs) {
    const lineId = lineInput.value;
    const row = lineInput.closest("tr");
    if (!row) continue;
    const meta = metaById.get(lineId);
    if (meta) {
      setInputValue(row.querySelector<HTMLInputElement>(`input[name="sku_override_${lineId}"]`), meta.retailer_sku ?? "", true);
      setInputValue(row.querySelector<HTMLInputElement>(`input[name="size_override_${lineId}"]`), meta.size ?? "", true);
    }
  }
}

function attachLineVatCalculator() {
  const selects = Array.from(document.querySelectorAll<HTMLSelectElement>('select[name^="vat_rate_percent_"]'));

  for (const select of selects) {
    if (select.dataset.vatCalculatorAttached === "true") continue;
    const lineId = select.name.replace("vat_rate_percent_", "");
    const row = select.closest("tr");
    if (!row) continue;

    const recalc = () => {
      const rate = Number(select.value || 20);
      const grossCell = row.children[4] as HTMLElement | undefined;
      const gross = parseMoney(grossCell?.textContent);
      const split = splitGross(gross, rate);
      setInputValue(row.querySelector<HTMLInputElement>(`input[name="net_amount_gbp_${lineId}"]`), split.net.toFixed(2));
      setInputValue(row.querySelector<HTMLInputElement>(`input[name="vat_amount_gbp_${lineId}"]`), split.vat.toFixed(2));
      setInputValue(row.querySelector<HTMLInputElement>(`input[name="tax_rate_label_${lineId}"]`), taxLabel(rate));
      setInputValue(row.querySelector<HTMLInputElement>(`input[name="tax_rate_id_${lineId}"]`), taxId(rate));
    };

    select.addEventListener("change", recalc);
    select.dataset.vatCalculatorAttached = "true";
  }
}

function attachAdjustmentVatCalculator() {
  const forms = Array.from(document.querySelectorAll<HTMLFormElement>("form"));
  const adjustmentForm = forms.find((form) => form.querySelector('input[name="net_amount_gbp"]') && form.querySelector('select[name="vat_rate_percent"]'));
  if (!adjustmentForm || adjustmentForm.dataset.vatCalculatorAttached === "true") return;

  const rateSelect = adjustmentForm.querySelector<HTMLSelectElement>('select[name="vat_rate_percent"]');
  const netInput = adjustmentForm.querySelector<HTMLInputElement>('input[name="net_amount_gbp"]');
  const vatInput = adjustmentForm.querySelector<HTMLInputElement>('input[name="vat_amount_gbp"]');
  const taxLabelInput = adjustmentForm.querySelector<HTMLInputElement>('input[name="tax_rate_label"]');
  const taxIdInput = adjustmentForm.querySelector<HTMLInputElement>('input[name="tax_rate_id"]');

  const recalc = () => {
    const rate = Number(rateSelect?.value || 20);
    const net = Number(netInput?.value || 0);
    const vat = Math.round((net * rate / 100) * 100) / 100;
    setInputValue(vatInput, vat.toFixed(2));
    setInputValue(taxLabelInput, taxLabel(rate));
    setInputValue(taxIdInput, taxId(rate));
  };

  rateSelect?.addEventListener("change", recalc);
  netInput?.addEventListener("input", recalc);
  adjustmentForm.dataset.vatCalculatorAttached = "true";
}

export default function RefundDocumentControlEnhancer({ submissionId }: { submissionId: string }) {
  useEffect(() => {
    let cancelled = false;

    async function run() {
      const statusResponse = await fetch(`/internal/refund-document-control/${submissionId}/audit-status`, { cache: "no-store" });
      if (statusResponse.ok) {
        const status = (await statusResponse.json()) as AuditStatus;
        if (cancelled) return;
        if (status.auditOnly) {
          insertAuditOnlyBanner();
          hideActiveControlSections();
          return;
        }
      }

      const response = await fetch(`/internal/refund-document-control/${submissionId}/line-metadata`, { cache: "no-store" });
      if (!response.ok) return;
      const payload = (await response.json()) as { lines?: LineMeta[] };
      if (cancelled) return;
      const metaById = new Map((payload.lines ?? []).map((line) => [line.id, line]));

      enhanceReleaseTable(metaById);
      enhanceCodingRows(metaById);
      attachLineVatCalculator();
      attachAdjustmentVatCalculator();
    }

    run().catch(() => undefined);
    const timer = window.setInterval(() => run().catch(() => undefined), 1200);

    return () => {
      cancelled = true;
      window.clearInterval(timer);
    };
  }, [submissionId]);

  return null;
}
