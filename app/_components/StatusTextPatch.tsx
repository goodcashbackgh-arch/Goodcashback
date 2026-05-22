"use client";

import { useEffect } from "react";

const replacements: Record<string, string> = {
  "Partially progressed": "Invoice reconciled; tracking open",
  "Raw: Partially progressed": "System: Invoice reconciled; tracking open",
  "Pending dva funding": "Payment pending",
  "Raw: Pending dva funding": "System: Payment pending",
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
    observer.observe(document.body, { childList: true, subtree: true });
    return () => observer.disconnect();
  }, []);

  return null;
}
