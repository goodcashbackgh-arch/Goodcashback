"use client";

import { useEffect } from "react";

const UNMATCHED_ACTION_URL = "/internal/dva-reconciliation/unmatched";

function nearestRowContainer(form: HTMLFormElement) {
  return form.closest("article, tr") ?? form.parentElement;
}

function hasNoPrimaryAllocation(container: Element | null) {
  if (!container) return false;
  const content = container.textContent ?? "";
  return /Active allocations:\s*0/i.test(content) || /Confirmed:\s*£0(?:\.00)?/i.test(content);
}

function addPrimaryRequiredNote(container: Element | null, form: HTMLFormElement) {
  if (!container) return;
  if (container.querySelector('[data-residual-primary-required="true"]')) return;

  const note = document.createElement("p");
  note.setAttribute("data-residual-primary-required", "true");
  note.className = "mt-3 text-sm text-slate-500";
  note.textContent = "Generate or allocate the primary supplier/refund/exception match before using FX/card/fee residual allocation.";
  form.insertAdjacentElement("beforebegin", note);
}

function addUnmatchedAction(container: Element | null, form: HTMLFormElement) {
  if (!container) return;
  if (container.querySelector('[data-unmatched-primary-action="true"]')) return;

  const wrapper = document.createElement("div");
  wrapper.setAttribute("data-unmatched-primary-action", "true");
  wrapper.className = "mt-3 flex flex-wrap items-center gap-3";

  const link = document.createElement("a");
  link.href = UNMATCHED_ACTION_URL;
  link.className = "inline-flex rounded-xl bg-sky-600 px-3 py-2 text-sm font-semibold text-white";
  link.textContent = "Open unmatched actions →";

  const hint = document.createElement("span");
  hint.className = "text-sm text-slate-500";
  hint.textContent = "Use this for suggestion generation, manual investigation, hold/query, or void handling.";

  wrapper.appendChild(link);
  wrapper.appendChild(hint);
  form.insertAdjacentElement("beforebegin", wrapper);
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

        addPrimaryRequiredNote(container, form);
        addUnmatchedAction(container, form);
      }
    };

    hideInvalidResidualForms();
    const observer = new MutationObserver(hideInvalidResidualForms);
    observer.observe(document.body, { childList: true, subtree: true });
    return () => observer.disconnect();
  }, []);

  return null;
}
