"use client";

import { useEffect } from "react";

function remainingAmount(body: string) {
  const marker = "Remaining £";
  const index = body.indexOf(marker);
  if (index < 0) return null;
  const tail = body.slice(index + marker.length).trim();
  const raw = tail.split(" ")[0]?.split("·")[0]?.replaceAll(",", "");
  const amount = Number(raw);
  return Number.isFinite(amount) ? amount : null;
}

function isStatementCard(anchor: HTMLAnchorElement) {
  const body = anchor.innerText || "";
  let url: URL;
  try {
    url = new URL(anchor.href, window.location.origin);
  } catch {
    return false;
  }

  return (
    url.pathname.includes("/internal/dva-reconciliation/workspace") &&
    Boolean(url.searchParams.get("line_id")) &&
    body.includes("Allocated") &&
    body.includes("Remaining") &&
    !body.startsWith("Invoice") &&
    !body.startsWith("Exception")
  );
}

function isBalanced(anchor: HTMLAnchorElement) {
  const body = anchor.innerText || "";
  const remaining = remainingAmount(body);
  return body.toLowerCase().includes("balanced") || (remaining !== null && remaining <= 0.009);
}

function markDisabled(anchor: HTMLAnchorElement) {
  anchor.setAttribute("aria-disabled", "true");
  anchor.setAttribute("data-balanced-selection-disabled", "true");
  anchor.style.cursor = "not-allowed";
  anchor.style.opacity = "0.72";
  anchor.style.boxShadow = "none";
}

export default function BalancedStatementSelectionGuard() {
  useEffect(() => {
    const markExisting = () => {
      const anchors = Array.from(document.querySelectorAll<HTMLAnchorElement>('a[href*="/internal/dva-reconciliation/workspace?"]'));
      for (const anchor of anchors) {
        if (isStatementCard(anchor) && isBalanced(anchor)) markDisabled(anchor);
      }
    };

    const blockBalancedSelection = (event: MouseEvent) => {
      const anchor = (event.target as HTMLElement | null)?.closest("a") as HTMLAnchorElement | null;
      if (!anchor || !isStatementCard(anchor) || !isBalanced(anchor)) return;

      event.preventDefault();
      event.stopPropagation();
      markDisabled(anchor);
    };

    markExisting();
    document.addEventListener("click", blockBalancedSelection, true);
    return () => document.removeEventListener("click", blockBalancedSelection, true);
  }, []);

  return null;
}
