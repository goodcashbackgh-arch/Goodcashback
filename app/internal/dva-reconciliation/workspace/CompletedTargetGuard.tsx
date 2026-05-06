"use client";

import { useEffect } from "react";

type CompletionPayload = {
  supplierInvoiceAllocatedByRef?: Record<string, number>;
  exceptionAllocatedByDisputeId?: Record<string, number>;
};

function parseGbp(value: string) {
  const match = value.match(/Amount\s+£\s*([\d,]+(?:\.\d{1,2})?)/i) || value.match(/£\s*([\d,]+(?:\.\d{1,2})?)/);
  if (!match) return 0;
  return Number(match[1].replace(/,/g, "")) || 0;
}

function firstLine(value: string) {
  return (
    value
      .split("\n")
      .map((part) => part.trim())
      .filter(Boolean)[0] || ""
  );
}

function invoiceRefFromBody(body: string) {
  const line = firstLine(body);
  if (!line.toLowerCase().startsWith("invoice")) return "";
  return line.replace(/^invoice\s*[·:-]?\s*/i, "").trim();
}

function isTargetAnchor(anchor: HTMLAnchorElement) {
  const body = anchor.innerText.trim();
  return body.startsWith("Invoice") || body.startsWith("Exception");
}

function addCompletedBadge(anchor: HTMLAnchorElement, hiddenFromUsable: boolean) {
  if (anchor.querySelector("[data-completed-target-badge='true']")) return;

  const badge = document.createElement("div");
  badge.dataset.completedTargetBadge = "true";
  badge.textContent = hiddenFromUsable ? "Already fully allocated — hidden from usable queue" : "Already fully allocated";
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

function disableAnchor(anchor: HTMLAnchorElement, hiddenFromUsable: boolean) {
  anchor.dataset.completedTargetDisabled = "true";
  anchor.setAttribute("aria-disabled", "true");
  anchor.style.opacity = "0.46";
  anchor.style.background = "#f8fafc";
  anchor.style.borderColor = "#cbd5e1";
  anchor.style.boxShadow = "none";
  anchor.style.cursor = "not-allowed";

  if (hiddenFromUsable) {
    anchor.style.display = "none";
  } else {
    addCompletedBadge(anchor, hiddenFromUsable);
  }

  const stopClick = (event: Event) => {
    event.preventDefault();
    event.stopPropagation();
    if (typeof event.stopImmediatePropagation === "function") event.stopImmediatePropagation();
  };

  if (anchor.dataset.completedTargetClickGuard !== "true") {
    anchor.addEventListener("click", stopClick, true);
    anchor.dataset.completedTargetClickGuard = "true";
  }
}

function applyCompletedTargetGuard(payload: CompletionPayload) {
  const params = new URLSearchParams(window.location.search);
  const rightStatus = params.get("right_status") || "usable";
  const hideFromUsable = rightStatus === "usable";
  const anchors = Array.from(
    document.querySelectorAll<HTMLAnchorElement>('a[href*="/internal/dva-reconciliation/workspace?"][href*="target_id="]'),
  );

  for (const anchor of anchors) {
    if (!isTargetAnchor(anchor)) continue;

    let targetId = "";
    try {
      targetId = new URL(anchor.href, window.location.origin).searchParams.get("target_id") || "";
    } catch {
      targetId = "";
    }

    const body = anchor.innerText.trim();
    const amount = parseGbp(body);
    if (amount <= 0) continue;

    let allocated = 0;
    if (body.startsWith("Invoice")) {
      allocated = Number(payload.supplierInvoiceAllocatedByRef?.[invoiceRefFromBody(body)] ?? 0);
    } else if (body.startsWith("Exception")) {
      allocated = Number(payload.exceptionAllocatedByDisputeId?.[targetId] ?? 0);
    }

    if (allocated + 0.009 >= amount) {
      disableAnchor(anchor, hideFromUsable);
    }
  }
}

export default function CompletedTargetGuard() {
  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    const importerId = params.get("importer_id") || "";
    const url = `/internal/dva-reconciliation/workspace/completion-data${importerId ? `?importer_id=${encodeURIComponent(importerId)}` : ""}`;

    let cancelled = false;

    fetch(url)
      .then((response) => response.json())
      .then((payload: CompletionPayload) => {
        if (cancelled) return;
        const timers = [
          window.setTimeout(() => applyCompletedTargetGuard(payload), 50),
          window.setTimeout(() => applyCompletedTargetGuard(payload), 250),
          window.setTimeout(() => applyCompletedTargetGuard(payload), 750),
        ];
        window.setTimeout(() => timers.forEach(window.clearTimeout), 1200);
      })
      .catch(() => {
        // Non-blocking guard. Backend over-allocation protection remains final.
      });

    return () => {
      cancelled = true;
    };
  }, []);

  return null;
}
