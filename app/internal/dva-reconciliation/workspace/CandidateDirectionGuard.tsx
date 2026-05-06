"use client";

import { useEffect } from "react";

type Direction = "IN" | "OUT" | "MIXED" | "UNKNOWN";

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
  if (body.startsWith("exception") && body.includes("awaiting_refund_credit")) return "IN";
  if (body.startsWith("exception") && body.includes("approved_refund")) return "IN";
  if (body.startsWith("exception") && body.includes("replacement") && body.includes("raised")) return "OUT";
  if (body.startsWith("exception") && body.includes("replacement") && body.includes("replaced")) return "UNKNOWN";

  return "UNKNOWN";
}

function targetStatus(anchor: HTMLAnchorElement) {
  const body = cardText(anchor).toLowerCase();
  if (body.includes("replaced")) return "replaced";
  if (body.includes("resolved")) return "resolved";
  if (body.includes("closed")) return "closed";
  return "open";
}

function isSelectedByClient(anchor: HTMLAnchorElement) {
  const style = anchor.getAttribute("style") || "";
  const klass = anchor.className || "";
  return (
    style.includes("border-width: 2px") ||
    style.includes("box-shadow") ||
    klass.includes("ring-2") ||
    klass.includes("border-sky")
  );
}

function clearDirectionGuard() {
  const guarded = Array.from(document.querySelectorAll<HTMLAnchorElement>("a[data-direction-guard-disabled='true']"));

  for (const anchor of guarded) {
    if (anchor.dataset.completedTargetDisabled === "true") continue;

    anchor.removeAttribute("aria-disabled");
    delete anchor.dataset.directionGuardDisabled;
    delete anchor.dataset.directionGuardReason;

    if (anchor.dataset.directionGuardHidden === "true") {
      anchor.style.display = "";
      delete anchor.dataset.directionGuardHidden;
    }

    anchor.style.opacity = "";
    anchor.style.cursor = "";

    const badge = anchor.querySelector("[data-direction-guard-badge='true']");
    if (badge) badge.remove();
  }
}

function disableCandidate(anchor: HTMLAnchorElement, reason: string, hide: boolean) {
  anchor.dataset.directionGuardDisabled = "true";
  anchor.dataset.directionGuardReason = reason;
  anchor.setAttribute("aria-disabled", "true");
  anchor.style.opacity = "0.42";
  anchor.style.background = "#f8fafc";
  anchor.style.borderColor = "#cbd5e1";
  anchor.style.boxShadow = "none";
  anchor.style.cursor = "not-allowed";

  if (hide) {
    anchor.dataset.directionGuardHidden = "true";
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
        if (anchor.dataset.directionGuardDisabled !== "true") return;
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
  const statementAnchors = Array.from(
    document.querySelectorAll<HTMLAnchorElement>('a[href*="/internal/dva-reconciliation/workspace?"][href*="line_id="]'),
  ).filter(isStatementCard);

  const selected = statementAnchors.filter(isSelectedByClient);
  const selectedDirections = new Set(selected.map(statementDirection).filter((direction) => direction === "IN" || direction === "OUT"));

  if (selectedDirections.size === 1) return [...selectedDirections][0];
  if (selectedDirections.size > 1) return "MIXED";

  const params = new URLSearchParams(window.location.search);
  const lineId = params.get("line_id") || "";
  if (!lineId) return "UNKNOWN";

  const byUrl = statementAnchors.find((anchor) => {
    try {
      return new URL(anchor.href, window.location.origin).searchParams.get("line_id") === lineId;
    } catch {
      return false;
    }
  });

  return byUrl ? statementDirection(byUrl) : "UNKNOWN";
}

function applyCandidateDirectionGuard() {
  clearDirectionGuard();

  const selectedDirection = activeSelectedStatementDirection();
  if (selectedDirection === "UNKNOWN" || selectedDirection === "MIXED") return;

  const params = new URLSearchParams(window.location.search);
  const rightStatus = params.get("right_status") || "usable";
  const hideFromUsable = rightStatus === "usable";

  const targets = Array.from(
    document.querySelectorAll<HTMLAnchorElement>('a[href*="/internal/dva-reconciliation/workspace?"][href*="target_id="]'),
  ).filter(isTargetCard);

  for (const target of targets) {
    if (target.dataset.completedTargetDisabled === "true") continue;

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
    const runSoon = () => {
      window.setTimeout(applyCandidateDirectionGuard, 0);
      window.setTimeout(applyCandidateDirectionGuard, 75);
    };

    const timers = [
      window.setTimeout(applyCandidateDirectionGuard, 50),
      window.setTimeout(applyCandidateDirectionGuard, 250),
      window.setTimeout(applyCandidateDirectionGuard, 750),
    ];

    document.addEventListener("click", runSoon, true);

    return () => {
      for (const timer of timers) window.clearTimeout(timer);
      document.removeEventListener("click", runSoon, true);
    };
  }, []);

  return null;
}
