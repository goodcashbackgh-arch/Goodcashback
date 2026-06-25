"use client";

import { useEffect } from "react";

const BULK_SUMMARY_MARKER = "data-loyalty-bulk-summary-card";

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
    "Single rewards and bulk pots are shown separately. Use the purple bulk button for grouped rewards.",
  "Single reward cards and bulk funding pots are separate. Single counts do not include the grouped rewards shown in the bulk pot section.":
    "Single rewards and bulk pots are shown separately. Use the purple bulk button for grouped rewards.",
  "Single exact": "Single exact reward",
  "Single strong": "Single strong reward",
  "Funding pot view": "Bulk pot group view",
  "Same-importer bulk funding pots detected": "Bulk reward groups detected",
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

function findTextNode(root: ParentNode, needle: string) {
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  while (walker.nextNode()) {
    const node = walker.currentNode;
    if (node instanceof Text && (node.nodeValue ?? "").includes(needle)) return node;
  }
  return null;
}

function makeSummaryCard(label: string, value: string, tone: "indigo" | "emerald") {
  const card = document.createElement("div");
  card.setAttribute(BULK_SUMMARY_MARKER, "true");
  card.className = tone === "indigo"
    ? "rounded-xl border border-indigo-200 bg-white px-3 py-2 text-indigo-900"
    : "rounded-xl border border-emerald-200 bg-white px-3 py-2 text-emerald-900";

  const labelSpan = document.createElement("span");
  labelSpan.textContent = label;
  card.appendChild(labelSpan);
  card.appendChild(document.createElement("br"));

  const valueSpan = document.createElement("span");
  valueSpan.className = "text-lg";
  valueSpan.textContent = value;
  card.appendChild(valueSpan);

  return card;
}

function patchLoyaltyBulkSummary(root: ParentNode) {
  if (!(root instanceof HTMLElement) && root !== document.body) return;

  document.querySelectorAll(`[${BULK_SUMMARY_MARKER}="true"]`).forEach((node) => node.remove());

  const singleExactNode = findTextNode(document.body, "Single exact reward");
  if (!singleExactNode?.parentElement?.parentElement) return;

  const bulkHeadingNode = findTextNode(document.body, "Bulk reward groups detected");
  const bulkSection = bulkHeadingNode?.parentElement?.closest('[class*="border-indigo-200"]') as HTMLElement | null;
  if (!bulkSection) return;

  const bulkText = bulkSection.innerText || "";
  const rewardMatches = Array.from(bulkText.matchAll(/\b(\d+)\s+rewards\b/g));
  const bulkGroups = rewardMatches.length;
  const bulkRewards = rewardMatches.reduce((sum, match) => sum + Number(match[1] || 0), 0);

  if (bulkGroups <= 0 || bulkRewards <= 0) return;

  const summaryGrid = singleExactNode.parentElement.parentElement;
  summaryGrid.appendChild(makeSummaryCard("Bulk exact pots", String(bulkGroups), "indigo"));
  summaryGrid.appendChild(makeSummaryCard("Bulk rewards", String(bulkRewards), "emerald"));
}

function patchPage(root: ParentNode) {
  patchStatusText(root);
  patchLoyaltyBulkSummary(root);
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
      patchLoyaltyBulkSummary(document.body);
    });
    observer.observe(document.body, { childList: true, subtree: true, characterData: true });
    return () => observer.disconnect();
  }, []);

  return null;
}
