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
    if (value === "Amount received") {
      node.nodeValue = "Payment applied to this order";
      continue;
    }

    if (value.startsWith("Account credit applied:")) {
      node.nodeValue = value.replace("Account credit applied:", "Includes account credit:");
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
