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

export default function StatusTextPatch() {
  useEffect(() => {
    patchStatusText(document.body);
    const observer = new MutationObserver((mutations) => {
      for (const mutation of mutations) {
        for (const node of Array.from(mutation.addedNodes)) {
          if (node instanceof Text) replaceTextNode(node);
          else if (node instanceof HTMLElement) patchStatusText(node);
        }
      }
    });
    observer.observe(document.body, { childList: true, subtree: true, characterData: true });
    return () => observer.disconnect();
  }, []);

  return null;
}
