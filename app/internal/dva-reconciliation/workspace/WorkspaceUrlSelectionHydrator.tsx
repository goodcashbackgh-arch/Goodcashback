"use client";

import { useEffect, useRef } from "react";

function clickMatchingSelectionAnchor(kind: "target_id" | "line_id", id: string) {
  const anchors = Array.from(
    document.querySelectorAll<HTMLAnchorElement>('a[href*="/internal/dva-reconciliation/workspace?"]'),
  );

  const match = anchors.find((anchor) => {
    try {
      const url = new URL(anchor.href, window.location.origin);
      return url.searchParams.get(kind) === id;
    } catch {
      return false;
    }
  });

  if (!match) return false;

  match.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, view: window }));
  return true;
}

export default function WorkspaceUrlSelectionHydrator() {
  const hydratedKeyRef = useRef("");

  useEffect(() => {
    const hydrateFromUrl = () => {
      const params = new URLSearchParams(window.location.search);
      const targetId = params.get("target_id") || "";
      const lineId = params.get("line_id") || "";
      const hydrateKey = `${lineId}|${targetId}|${window.location.search}`;

      if (!targetId && !lineId) return true;
      if (hydratedKeyRef.current === hydrateKey) return true;

      let didEverything = true;
      if (targetId) didEverything = clickMatchingSelectionAnchor("target_id", targetId) && didEverything;
      if (lineId) didEverything = clickMatchingSelectionAnchor("line_id", lineId) && didEverything;

      if (didEverything) hydratedKeyRef.current = hydrateKey;
      return didEverything;
    };

    const timers = [
      window.setTimeout(hydrateFromUrl, 150),
      window.setTimeout(hydrateFromUrl, 500),
      window.setTimeout(hydrateFromUrl, 1000),
    ];

    return () => {
      for (const timer of timers) window.clearTimeout(timer);
    };
  }, []);

  return null;
}
