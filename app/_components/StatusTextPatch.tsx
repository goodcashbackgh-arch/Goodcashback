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
  "Exact pots can be released in one controlled staff action. The action preserves the existing single-row validations for every selected reward and does not post to Sage.":
    "Exact and single strong sufficient-IN pots can be released in one controlled staff action. The action preserves the existing validations and does not post to Sage.",
  "Release selected IN for exact pot": "Release selected IN for pot",
  "Only exact same-importer pots are bulk-enabled; strong/review pots remain manual.":
    "Exact and single strong same-importer sufficient-IN pots are bulk-enabled; review pots remain manual. Any excess remains on the DVA/card line; no loyalty FX is posted.",
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

function patchSufficientInPotButtons(root: ParentNode) {
  const scope = root instanceof Element || root instanceof Document ? root : document;
  const buttons = Array.from(scope.querySelectorAll("button"));

  for (const button of buttons) {
    if (!button.textContent?.includes("Release selected IN for pot")) continue;

    const article = button.closest("article");
    const articleText = article?.textContent ?? "";
    const isBulkExactOrStrongPot = articleText.includes("Exact pot") || articleText.includes("Strong pot");

    if (!isBulkExactOrStrongPot) continue;

    button.removeAttribute("disabled");
    button.disabled = false;
  }
}

function patchPage(root: ParentNode) {
  patchStatusText(root);
  patchSufficientInPotButtons(root);
}

export default function StatusTextPatch() {
  useEffect(() => {
    patchPage(document.body);
    const observer = new MutationObserver((mutations) => {
      for (const mutation of mutations) {
        if (mutation.target instanceof Text) replaceTextNode(mutation.target);
        else if (mutation.target instanceof HTMLElement) patchPage(mutation.target);

        for (const node of Array.from(mutation.addedNodes)) {
          if (node instanceof Text) replaceTextNode(node);
          else if (node instanceof HTMLElement) patchPage(node);
        }
      }
    });
    observer.observe(document.body, { childList: true, subtree: true, characterData: true });
    return () => observer.disconnect();
  }, []);

  return null;
}
