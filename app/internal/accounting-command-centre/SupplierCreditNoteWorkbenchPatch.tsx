"use client";

import { useEffect } from "react";

function currentAccountingParams() {
  const params = new URLSearchParams(window.location.search);
  return {
    queue: params.get("queue") || "actionable",
    lane: params.get("lane") || "supplier_goods_ap",
    postingGate: params.get("posting_gate") || "all",
    search: params.get("q") || "",
    pageSize: params.get("page_size") || "50",
  };
}

function hiddenInput(name: string, value: string) {
  const input = document.createElement("input");
  input.type = "hidden";
  input.name = name;
  input.value = value;
  return input;
}

function syncSupplierCreditNoteForms() {
  const params = currentAccountingParams();
  const forms = Array.from(
    document.querySelectorAll<HTMLFormElement>('form[action="/internal/accounting-command-centre/freeze-supplier-credit-note"]'),
  );

  for (const form of forms) {
    const values: Record<string, string> = {
      bulk_queue: params.queue,
      bulk_lane: "supplier_credit_note",
      bulk_posting_gate: params.postingGate,
      bulk_q: params.search,
      bulk_page_size: params.pageSize,
    };

    for (const [name, value] of Object.entries(values)) {
      let input = form.querySelector<HTMLInputElement>(`input[name="${name}"]`);
      if (!input) {
        input = hiddenInput(name, value);
        form.appendChild(input);
      }
      input.value = value;
    }

    form.addEventListener("submit", () => {
      const includeWarnings = document.querySelector<HTMLInputElement>('input[name="bulk_include_warnings"]');
      let warningInput = form.querySelector<HTMLInputElement>('input[name="bulk_include_warnings"]');
      if (includeWarnings?.checked) {
        if (!warningInput) {
          warningInput = hiddenInput("bulk_include_warnings", "true");
          form.appendChild(warningInput);
        }
        warningInput.value = "true";
      } else {
        warningInput?.remove();
      }
    });
  }
}

function ensureLaneOption() {
  const selects = Array.from(document.querySelectorAll<HTMLSelectElement>('select[name="lane"]'));
  for (const select of selects) {
    if (!Array.from(select.options).some((option) => option.value === "supplier_credit_note")) {
      const option = document.createElement("option");
      option.value = "supplier_credit_note";
      option.textContent = "Supplier credit note";
      const allOption = Array.from(select.options).find((existing) => existing.value === "all");
      select.insertBefore(option, allOption ?? null);
    }
    if (new URLSearchParams(window.location.search).get("lane") === "supplier_credit_note") {
      select.value = "supplier_credit_note";
    }
  }
}

function injectFreezeButton() {
  const params = currentAccountingParams();
  if (params.lane !== "supplier_credit_note") return;
  if (document.querySelector('[data-supplier-credit-note-freeze-button="true"]')) return;

  const buttonBar = Array.from(document.querySelectorAll<HTMLDivElement>("div.flex.flex-wrap.gap-2"))
    .find((div) => div.textContent?.includes("Revalidate matching frozen") && div.textContent?.includes("Create posting batch"));

  if (!buttonBar) return;

  const form = document.createElement("form");
  form.method = "post";
  form.action = "/internal/accounting-command-centre/freeze-supplier-credit-note";
  form.dataset.supplierCreditNoteFreezeButton = "true";
  form.className = "inline";

  form.appendChild(hiddenInput("bulk_queue", params.queue));
  form.appendChild(hiddenInput("bulk_lane", "supplier_credit_note"));
  form.appendChild(hiddenInput("bulk_posting_gate", params.postingGate));
  form.appendChild(hiddenInput("bulk_q", params.search));
  form.appendChild(hiddenInput("bulk_page_size", params.pageSize));

  const button = document.createElement("button");
  button.type = "submit";
  button.textContent = params.search ? "Freeze matching supplier credit note" : "Freeze all matching supplier credit notes";
  button.className = "rounded-lg bg-amber-700 px-3 py-1.5 text-[11px] font-bold text-white hover:bg-amber-800";
  form.appendChild(button);

  form.addEventListener("submit", () => {
    const includeWarnings = document.querySelector<HTMLInputElement>('input[name="bulk_include_warnings"]');
    if (includeWarnings?.checked) {
      form.appendChild(hiddenInput("bulk_include_warnings", "true"));
    }
  });

  buttonBar.prepend(form);
}

export default function SupplierCreditNoteWorkbenchPatch() {
  useEffect(() => {
    const run = () => {
      ensureLaneOption();
      syncSupplierCreditNoteForms();
      injectFreezeButton();
    };

    run();
    const observer = new MutationObserver(run);
    observer.observe(document.body, { childList: true, subtree: true });
    return () => observer.disconnect();
  }, []);

  return null;
}
