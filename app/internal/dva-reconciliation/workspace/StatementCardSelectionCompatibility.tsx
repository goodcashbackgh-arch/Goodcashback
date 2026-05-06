"use client";

import { useEffect } from "react";

function addCompatibilityMarkers() {
  const anchors = Array.from(
    document.querySelectorAll<HTMLAnchorElement>('a[href*="/internal/dva-reconciliation/workspace?"][href*="line_id="]'),
  );

  for (const anchor of anchors) {
    if (anchor.dataset.statementSelectionCompat === "true") continue;

    const body = anchor.innerText || "";
    const looksLikeNewStatementCard = body.includes("USED") && body.includes("OPEN");
    const looksLikeLegacyStatementCard = body.includes("Allocated") && body.includes("Remaining");

    if (!looksLikeNewStatementCard || looksLikeLegacyStatementCard) continue;

    const marker = document.createElement("span");
    marker.setAttribute("aria-hidden", "true");
    marker.textContent = " Allocated Remaining";
    marker.style.position = "absolute";
    marker.style.width = "1px";
    marker.style.height = "1px";
    marker.style.margin = "-1px";
    marker.style.padding = "0";
    marker.style.overflow = "hidden";
    marker.style.clipPath = "inset(50%)";
    marker.style.whiteSpace = "nowrap";

    anchor.appendChild(marker);
    anchor.dataset.statementSelectionCompat = "true";
  }
}

export default function StatementCardSelectionCompatibility() {
  useEffect(() => {
    const timers = [
      window.setTimeout(addCompatibilityMarkers, 50),
      window.setTimeout(addCompatibilityMarkers, 250),
      window.setTimeout(addCompatibilityMarkers, 750),
    ];

    return () => {
      for (const timer of timers) window.clearTimeout(timer);
    };
  }, []);

  return null;
}
