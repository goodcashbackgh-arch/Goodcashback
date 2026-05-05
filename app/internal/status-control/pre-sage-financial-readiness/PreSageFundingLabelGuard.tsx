"use client";

import { useEffect } from "react";

function replaceText(node: Node) {
  if (node.nodeType === Node.TEXT_NODE && node.textContent) {
    node.textContent = node.textContent
      .replaceAll("not proven", "funding gap")
      .replaceAll("Funding shown as not proven", "Funding shown as funding gap")
      .replaceAll(
        "Importer has £154.65 open/unallocated statement value across visible statement lines",
        "Importer-level warning: £154.65 open/unallocated statement value across visible statement lines",
      );
  }

  for (const child of Array.from(node.childNodes)) replaceText(child);
}

function run() {
  replaceText(document.body);
}

export default function PreSageFundingLabelGuard() {
  useEffect(() => {
    run();
    const observer = new MutationObserver(run);
    observer.observe(document.body, { childList: true, subtree: true, characterData: true });
    return () => observer.disconnect();
  }, []);

  return null;
}
