"use client";

import { useEffect } from "react";

const STALE_STATUS = "Replacement accepted — awaiting successor tracking";

export default function ReplacementStatusEnhancer({ statusLabel }: { statusLabel: string | null }) {
  useEffect(() => {
    if (!statusLabel || statusLabel === STALE_STATUS) return;

    const replaceStatus = () => {
      const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
      let node = walker.nextNode();
      while (node) {
        if (node.textContent?.includes(STALE_STATUS)) {
          node.textContent = node.textContent.replace(STALE_STATUS, statusLabel);
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
