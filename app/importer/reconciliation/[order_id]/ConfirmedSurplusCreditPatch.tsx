"use client";

import { useEffect } from "react";

function patchConfirmedSurplusCredit() {
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  const nodes: Text[] = [];
  while (walker.nextNode()) {
    if (walker.currentNode instanceof Text) nodes.push(walker.currentNode);
  }

  for (const node of nodes) {
    if ((node.nodeValue ?? "").trim() === "Variance needs review") {
      node.nodeValue = "Variance explained by confirmed credit";
      const el = node.parentElement;
      if (el) {
        el.classList.remove("bg-amber-100", "text-amber-800");
        el.classList.add("bg-emerald-100", "text-emerald-800");
      }
    }
  }
}

export default function ConfirmedSurplusCreditPatch() {
  useEffect(() => {
    patchConfirmedSurplusCredit();
    const observer = new MutationObserver(() => patchConfirmedSurplusCredit());
    observer.observe(document.body, { childList: true, subtree: true, characterData: true });
    return () => observer.disconnect();
  }, []);

  return null;
}
