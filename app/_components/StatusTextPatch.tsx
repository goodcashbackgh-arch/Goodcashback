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

function parseSignedNumber(value: string | null | undefined) {
  const match = (value ?? "").replace(/,/g, "").match(/([+-]?\d+(?:\.\d+)?)/);
  return match ? Number(match[1]) : null;
}

function parseQtyVariance(section: Element) {
  const qtyCard = Array.from(section.querySelectorAll("div")).find((element) =>
    (element.textContent ?? "").includes("QTY VARIANCE")
  );
  if (!qtyCard) return { qtyCard: null, qtyVariance: null };
  const raw = (qtyCard.textContent ?? "").replace(/\s+/g, " ");
  const qtyVariance = parseSignedNumber(raw.replace("QTY VARIANCE", ""));
  return { qtyCard, qtyVariance };
}

function hasZeroValueVariance(section: Element) {
  const valueCard = Array.from(section.querySelectorAll("div")).find((element) =>
    (element.textContent ?? "").includes("VALUE VARIANCE")
  );
  if (!valueCard) return false;
  const text = (valueCard.textContent ?? "").replace(/\s+/g, " ");
  return /VALUE VARIANCE\s*[+-]?£0\.00\b/i.test(text);
}

function sumParkedNonPhysicalQty(scope: ParentNode) {
  let total = 0;
  for (const article of Array.from(scope.querySelectorAll("article"))) {
    const text = article.textContent ?? "";
    if (!text.includes("Parked as")) continue;
    const qtyInput = article.querySelector<HTMLInputElement>('input[name="qty"]');
    total += Number(qtyInput?.value ?? 0);
  }
  return total;
}

function replaceExactText(root: ParentNode, from: string, to: string) {
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  const textNodes: Text[] = [];
  while (walker.nextNode()) {
    if (walker.currentNode instanceof Text) textNodes.push(walker.currentNode);
  }
  for (const node of textNodes) {
    if ((node.nodeValue ?? "").trim() === from) node.nodeValue = (node.nodeValue ?? "").replace(from, to);
  }
}

function makeEmerald(element: Element | null) {
  if (!(element instanceof HTMLElement)) return;
  element.classList.remove("bg-amber-100", "text-amber-800", "border-amber-200", "bg-amber-50", "text-amber-900");
  element.classList.add("bg-emerald-100", "text-emerald-800");
  if (element.className.includes("border")) element.classList.add("border-emerald-200");
}

function makeCardEmerald(element: Element | null) {
  if (!(element instanceof HTMLElement)) return;
  element.classList.remove("border-amber-200", "bg-amber-50");
  element.classList.add("border-emerald-200", "bg-emerald-50");
}

function patchReconciledNonPhysicalQtyVariance(root: ParentNode) {
  const sections = Array.from(root.querySelectorAll("section"));
  for (const section of sections) {
    const sectionText = section.textContent ?? "";
    if (!sectionText.includes("Baseline check") || !sectionText.includes("Original order vs invoice lines")) continue;
    if (!sectionText.includes("Variance needs review")) continue;
    if (!hasZeroValueVariance(section)) continue;

    const { qtyCard, qtyVariance } = parseQtyVariance(section);
    if (!qtyCard || qtyVariance === null || Math.abs(qtyVariance) < 0.001) continue;

    const pageScope = section.closest("main") ?? document.body;
    const parkedQty = sumParkedNonPhysicalQty(pageScope);
    if (parkedQty <= 0 || Math.abs(Math.abs(qtyVariance) - parkedQty) > 0.001) continue;

    replaceExactText(section, "Variance needs review", "Qty/value accounted for");
    replaceExactText(qtyCard, `${qtyVariance > 0 ? "+" : ""}${qtyVariance}`, "0");

    const badge = Array.from(section.querySelectorAll("span")).find((element) =>
      (element.textContent ?? "").includes("Qty/value accounted for")
    );
    makeEmerald(badge ?? null);
    makeCardEmerald(qtyCard);
  }
}

export default function StatusTextPatch() {
  useEffect(() => {
    patchStatusText(document.body);
    patchReconciledNonPhysicalQtyVariance(document.body);
    const observer = new MutationObserver((mutations) => {
      for (const mutation of mutations) {
        for (const node of Array.from(mutation.addedNodes)) {
          if (node instanceof Text) replaceTextNode(node);
          else if (node instanceof HTMLElement) {
            patchStatusText(node);
            patchReconciledNonPhysicalQtyVariance(document.body);
          }
        }
      }
    });
    observer.observe(document.body, { childList: true, subtree: true, characterData: true });
    return () => observer.disconnect();
  }, []);

  return null;
}
