"use client";

import { useEffect } from "react";

type Direction = "IN" | "OUT" | "UNKNOWN";

function cardText(anchor: HTMLAnchorElement) {
  return (anchor.innerText || "").trim();
}

function isStatementCard(anchor: HTMLAnchorElement) {
  const body = cardText(anchor);
  return /\b(IN|OUT)\b/.test(body) && !body.startsWith("Invoice") && !body.startsWith("Exception");
}

function isTargetCard(anchor: HTMLAnchorElement) {
  const body = cardText(anchor);
  return body.startsWith("Invoice") || body.startsWith("Exception");
}

function statementDirection(anchor: HTMLAnchorElement): Direction {
  const body = cardText(anchor);
  if (/\bIN\b/.test(body)) return "IN";
  if (/\bOUT\b/.test(body)) return "OUT";
  return "UNKNOWN";
}

function targetDirection(anchor: HTMLAnchorElement): Direction {
  const body = cardText(anchor).toLowerCase();

  if (body.startsWith("invoice")) return "OUT";
  if (body.startsWith("exception") && body.includes("refund")) return "IN";
  if (body.startsWith("exception") && body.includes("replacement") && body.includes("raised")) return "OUT";
  if (body.startsWith("exception") && body.includes("replacement") && body.includes("replaced")) return "UNKNOWN";
  if (body.startsWith("exception") && body.includes("awaiting_refund_credit")) return "IN";
  if (body.startsWith("exception") && body.includes("approved_refund")) return "IN";

  return "UNKNOWN";
}

function targetStatus(anchor: HTMLAnchorElement) {
  const body = cardText(anchor).toLowerCase();
  if (body.includes("replaced")) return "replaced";
  if (body.includes("resolved")) return "resolved";
  if (body.includes("closed")) return "closed";
  return "open";
}

function disableCandidate(anchor: HTMLAnchorElement, reason: string, hide: boolean) {
  anchor.dataset.directionGuardDisabled = "true";
  anchor.setAttribute("aria-disabled", "true");
  anchor.style.opacity = "0.42";
  anchor.style.background = "#f8fafc";
  anchor.style.borderColor = "#cbd5e1";
  anchor.style.boxShadow = "none";
  anchor.style.cursor = "not-allowed";

  if (hide) {
    anchor.style.display = "none";
  } else if (!anchor.querySelector("[data-direction-guard-badge='true']")) {
    const badge = document.createElement("div");
    badge.dataset.directionGuardBadge = "true";
    badge.textContent = reason;
    badge.style.marginTop = "10px";
    badge.style.borderRadius = "999px";
    badge.style.border = "1px solid #cbd5e1";
    badge.style.background = "#f1f5f9";
    badge.style.color = "#475569";
    badge.style.padding = "8px 12px";
    badge.style.fontSize = "12px";
    badge.style.fontWeight = "700";
    badge.style.display = "inline-block";
    anchor.appendChild(badge);
  }

  if (anchor.dataset.directionGuardClickGuard !== "true") {
    anchor.addEventListener(
      "click",
      (event) => {
        event.preventDefault();
        event.stopPropagation();
        if (typeof event.stopImmediatePropagation === "function") event.stopImmediatePropagation();
      },
      true,
    );
    anchor.dataset.directionGuardClickGuard = "true";
  }
}

function activeSelectedStatementDirection() {
  const selected = Array.from(
    document.querySelectorAll<HTMLAnchorElement>('a[href*="/internal/dva-reconciliation/workspace?"]'),
  ).find((anchor) => isStatementCard(anchor) && /ring-2|border-sky|border-orange|border-amber|border-emerald/.test(anchor.className + " " + anchor.getAttribute("style")));

  if (selected) return statementDirection(selected);

  const params = new URLSearchParams(window.location.search);
  const lineId = params.get("line_id") || "";
  if (!lineId) return "UNKNOWN";

  const byUrl = Array.from(
    document.querySelectorAll<HTMLAnchorElement>('a[href*="/internal/dva-reconciliation/workspace?"][href*="line_id="]'),
  ).find((anchor) => {
    try {
      return new URL(anchor.href, window.location.origin).searchParams.get("line_id") === lineId && isStatementCard(anchor);
    } catch {
      return false;
    }
  });

  return byUrl ? statementDirection(byUrl) : "UNKNOWN";
}

function applyCandidateDirectionGuard() {
  const selectedDirection = activeSelectedStatementDirection();
  if (selectedDirection === "UNKNOWN") return;

  const params = new URLSearchParams(window.location.search);
  const rightStatus = params.get("right_status") || "usable";
  const hideFromUsable = rightStatus === "usable";

  const targets = Array.from(
    document.querySelectorAll<HTMLAnchorElement>('a[href*="/internal/dva-reconciliation/workspace?"][href*="target_id="]'),
  ).filter(isTargetCard);

  for (const target of targets) {
    const direction = targetDirection(target);
    const status = targetStatus(target);

    if (status === "replaced" || status === "resolved" || status === "closed") {
      disableCandidate(target, "Not a live cash target", hideFromUsable);
      continue;
    }

    if (selectedDirection === "OUT" && direction === "IN") {
      disableCandidate(target, "Hidden: OUT line cannot match refund IN target", hideFromUsable);
      continue;
    }

    if (selectedDirection === "IN" && direction === "OUT") {
      disableCandidate(target, "Hidden: IN line cannot match supplier OUT target", hideFromUsable);
    }
  }
}

export default function CandidateDirectionGuard() {
  useEffect(() => {
    const timers = [
      window.setTimeout(applyCandidateDirectionGuard, 50),
      window.setTimeout(applyCandidateDirectionGuard, 250),
      window.setTimeout(applyCandidateDirectionGuard, 750),
    ];

    return () => {
      for (const timer of timers) window.clearTimeout(timer);
    };
  }, []);

  return null;
}
