"use client";

import { useEffect } from "react";

const STALE_STATUSES = [
  "Replacement accepted — awaiting successor tracking",
  "Replacement accepted — child order created",
];

export default function ReplacementStatusEnhancer({ statusLabel }: { statusLabel: string | null }) {
  useEffect(() => {
    if (!statusLabel || STALE_STATUSES.includes(statusLabel)) return;

    const replaceStatus = () => {
      const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
      let node = walker.nextNode();
      while (node) {
        const current = node.textContent;
        if (current) {
          const staleStatus = STALE_STATUSES.find((candidate) => current.includes(candidate));
          if (staleStatus) node.textContent = current.replace(staleStatus, statusLabel);
        }
        node = walker.nextNode();
      }
    };

    replaceStatus();
    const observer = new MutationObserver(replaceStatus);
    observer.observe(document.body, { childList: true, subtree: true });
    return () => observer.disconnect();
  }, [statusLabel]);

  return null;
}
