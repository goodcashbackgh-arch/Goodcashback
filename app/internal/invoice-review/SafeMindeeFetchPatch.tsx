"use client";

import { useEffect } from "react";

export default function SafeMindeeFetchPatch() {
  useEffect(() => {
    const buttons = Array.from(document.querySelectorAll<HTMLButtonElement>("button"))
      .filter((button) => button.textContent?.includes("Fetch/save Mindee result"));

    for (const button of buttons) {
      const oldForm = button.closest("form");
      if (!oldForm || oldForm.dataset.safeMindeePatched === "true") continue;

      const supplierInvoiceInput = oldForm.querySelector<HTMLInputElement>('input[name="supplier_invoice_id"]');
      const supplierInvoiceId = supplierInvoiceInput?.value;
      if (!supplierInvoiceId) continue;

      oldForm.dataset.safeMindeePatched = "true";
      oldForm.style.display = "none";

      const form = document.createElement("form");
      form.method = "post";
      form.action = "/internal/invoice-review/safe-fetch-mindee";

      const hidden = document.createElement("input");
      hidden.type = "hidden";
      hidden.name = "supplier_invoice_id";
      hidden.value = supplierInvoiceId;
      form.appendChild(hidden);

      const safeButton = document.createElement("button");
      safeButton.type = "submit";
      safeButton.textContent = "Safe fetch/save Mindee result — no new page";
      safeButton.className = button.className || "w-full rounded-full border border-emerald-200 bg-emerald-50 px-4 py-3 text-sm font-semibold text-emerald-800";
      form.appendChild(safeButton);

      oldForm.insertAdjacentElement("afterend", form);
    }
  }, []);

  return null;
}
