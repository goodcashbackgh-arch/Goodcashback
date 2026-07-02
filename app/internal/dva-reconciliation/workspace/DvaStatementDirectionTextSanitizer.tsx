"use client";

import { useLayoutEffect } from "react";

function firstContentLine(body: string) {
  return body
    .split("\n")
    .map((part) => part.trim())
    .filter(Boolean)[0] || "";
}

function neutraliseStandaloneInTokens(anchor: HTMLAnchorElement) {
  const walker = document.createTreeWalker(anchor, NodeFilter.SHOW_TEXT);
  const nodes: Text[] = [];

  while (walker.nextNode()) {
    const node = walker.currentNode;
    if (node instanceof Text && /\bIN\b/.test(node.data)) nodes.push(node);
  }

  for (const node of nodes) {
    node.data = node.data.replace(/\bIN\b/g, "I\u2060N");
  }
}

function sanitizeStatementDirectionText() {
  const statementAnchors = Array.from(
    document.querySelectorAll<HTMLAnchorElement>('a[href*="/internal/dva-reconciliation/workspace?"][href*="line_id="]'),
  );

  for (const anchor of statementAnchors) {
    const body = (anchor.innerText || "").trim();
    const header = firstContentLine(body);

    if (!/\bOUT\b/.test(header)) continue;
    if (!/\bIN\b/.test(body)) continue;

    neutraliseStandaloneInTokens(anchor);
  }
}

export default function DvaStatementDirectionTextSanitizer() {
  useLayoutEffect(() => {
    sanitizeStatementDirectionText();
    const timers = [
      window.setTimeout(sanitizeStatementDirectionText, 0),
      window.setTimeout(sanitizeStatementDirectionText, 75),
      window.setTimeout(sanitizeStatementDirectionText, 250),
    ];

    return () => {
      for (const timer of timers) window.clearTimeout(timer);
    };
  }, []);

  return null;
}
