"use client";

import { useEffect } from "react";

function nearestRowContainer(form: HTMLFormElement) {
  return form.closest("article, tr") ?? form.parentElement;
}

function hasNoPrimaryAllocation(container: Element | null) {
  if (!container) return false;
  const content = container.textContent ?? "";
  return /Active allocations:\s*0/i.test(content) || /Confirmed:\s*£0(?:\.00)?/i.test(content);
}

export default function ResidualAllocationUiGuard() {
  useEffect(() => {
    const hideInvalidResidualForms = () => {
      const buttons = Array.from(document.querySelectorAll("button"));
      for (const button of buttons) {
        if (!button.textContent?.toLowerCase().includes("allocate residual")) continue;
        const form = button.closest("form") as HTMLFormElement | null;
        if (!form) continue;
        const container = nearestRowContainer(form);
        if (!hasNoPrimaryAllocation(container)) continue;

        form.style.display = "none";
        form.setAttribute("data-residual-hidden-until-primary-allocation", "true");

        if (form.previousElementSibling?.getAttribute("data-residual-primary-required") === "true") continue;

        const note = document.createElement("p");
        note.setAttribute("data-residual-primary-required", "true");
        note.className = "mt-3 text-sm text-slate-500";
        note.textContent = "Generate or allocate the primary supplier/refund/exception match before using FX/card/fee residual allocation.";
        form.insertAdjacentElement("beforebegin", note);
      }
    };

    hideInvalidResidualForms();
    const observer = new MutationObserver(hideInvalidResidualForms);
    observer.observe(document.body, { childList: true, subtree: true });
    return () => observer.disconnect();
  }, []);

  return null;
}
