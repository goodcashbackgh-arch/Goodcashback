"use client";

import { useEffect } from "react";

const replacements: Record<string, string> = {
  "Raw DB status partially progressed": "System status invoice reconciled; tracking open",
  "Raw DB status pending dva funding": "System status payment pending",
  "Raw DB status reconciling": "System status invoice reconciliation open",
  "Raw: Partially progressed": "System: Invoice reconciled; tracking open",
  "Raw: Pending dva funding": "System: Payment pending",
  "Partially progressed": "Invoice reconciled; tracking open",
  "partially progressed": "invoice reconciled; tracking open",
  "Pending dva funding": "Payment pending",
  "pending dva funding": "payment pending",
  "not built yet": "not assessed in this control",
  "Ready to release queue": "Ready to release",
  "Ready to release: single rewards and bulk pots": "Ready to release",
  "Each single-row card is an already reserved main-bank OUT that is not part of a bulk pot. Funding-pot rows are grouped separately and use the bulk pot action.":
    "Single rewards and bulk pots are shown separately. Review the selected DVA/card IN before grouped release.",
  "Single reward cards and bulk funding pots are separate. Single counts do not include the grouped rewards shown in the bulk pot section.":
    "Single rewards and bulk pots are shown separately. Review the selected DVA/card IN before grouped release.",
  "Single exact": "Single exact reward",
  "Single strong": "Single strong reward",
  "Funding pot view": "Bulk pot group view",
  "Same-importer bulk funding pots detected": "Bulk reward groups detected",
  "Suggested same-importer DVA/card IN": "Selected same-importer DVA/card IN",
  "Bulk release exact pot": "Release selected IN for exact pot",
  "funding-pot groups:": "bulk pot groups:",
};

function replaceTextNode(node: Text) {
  const original = node.nodeValue ?? "";
  let next = original;
  for (const [from, to] of Object.entries(replacements)) {
    next = next.replaceAll(from, to);
  }
  if (next !== original) node.nodeValue = next;
}

function patchStatusText(root: ParentNode) {
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  const textNodes: Text[] = [];
  while (walker.nextNode()) {
    if (walker.currentNode instanceof Text) textNodes.push(walker.currentNode);
  }
  for (const node of textNodes) replaceTextNode(node);
}

function addVisibleBulkInSelectors() {
  for (const form of Array.from(document.forms)) {
    if (form.dataset.loyaltyBulkInVisible === "true") continue;

    const matchIdsControl = form.elements.namedItem("loyalty_match_ids");
    const topUpControl = form.elements.namedItem("top_up_statement_line_id");
    if (!(matchIdsControl instanceof HTMLInputElement)) continue;
    if (!(topUpControl instanceof HTMLInputElement)) continue;
    if (!matchIdsControl.value || !topUpControl.value) continue;

    const button = form.querySelector("button");
    if (!(button instanceof HTMLButtonElement)) continue;

    const previousText = form.previousElementSibling instanceof HTMLElement ? form.previousElementSibling.innerText.trim() : "";
    const optionText = previousText || "Selected same-importer DVA/card IN";

    const wrapper = document.createElement("label");
    wrapper.className = "grid gap-1 text-xs font-bold uppercase tracking-wide text-slate-500";

    const title = document.createElement("span");
    title.textContent = "Select same-importer DVA/card IN";

    const select = document.createElement("select");
    select.name = "top_up_statement_line_id";
    select.className = "w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal normal-case tracking-normal text-slate-950";

    const option = document.createElement("option");
    option.value = topUpControl.value;
    option.textContent = optionText;
    option.selected = true;
    select.appendChild(option);

    wrapper.appendChild(title);
    wrapper.appendChild(select);
    form.insertBefore(wrapper, form.firstChild);
    form.dataset.loyaltyBulkInVisible = "true";
  }
}

function patchPage(root: ParentNode) {
  patchStatusText(root);
  addVisibleBulkInSelectors();
}

export default function StatusTextPatch() {
  useEffect(() => {
    patchPage(document.body);
    const observer = new MutationObserver((mutations) => {
      for (const mutation of mutations) {
        for (const node of Array.from(mutation.addedNodes)) {
          if (node instanceof Text) replaceTextNode(node);
          else if (node instanceof HTMLElement) patchPage(node);
        }
      }
      addVisibleBulkInSelectors();
    });
    observer.observe(document.body, { childList: true, subtree: true, characterData: true });
    return () => observer.disconnect();
  }, []);

  return null;
}
