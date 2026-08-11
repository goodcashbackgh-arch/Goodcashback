"use client";

import { useEffect } from "react";

function clarifyPaymentAppliedLabel() {
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  const nodes: Text[] = [];

  while (walker.nextNode()) {
    if (walker.currentNode instanceof Text) nodes.push(walker.currentNode);
  }

  for (const node of nodes) {
    const value = (node.nodeValue ?? "").trim();
    if (value !== "Amount received" && value !== "Payment applied to this order") continue;

    if (value === "Amount received") {
      node.nodeValue = "Payment applied to this order";
    }

    const card = node.parentElement?.parentElement;
    if (!card) continue;

    const cardWalker = document.createTreeWalker(card, NodeFilter.SHOW_TEXT);
    while (cardWalker.nextNode()) {
      const cardNode = cardWalker.currentNode;
      if (!(cardNode instanceof Text)) continue;
      const cardValue = (cardNode.nodeValue ?? "").trim();
      if (cardValue.startsWith("Account credit applied:")) {
        cardNode.nodeValue = cardValue.replace("Account credit applied:", "Includes account credit:");
      }
    }
  }
}

export default function SettlementCustomerPatch() {
  useEffect(() => {
    clarifyPaymentAppliedLabel();
    const observer = new MutationObserver(() => clarifyPaymentAppliedLabel());
    observer.observe(document.body, { childList: true, subtree: true, characterData: true });
    return () => observer.disconnect();
  }, []);

  return null;
}
