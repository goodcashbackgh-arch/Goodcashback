"use client";

import { useEffect } from "react";

function readableDisputeRef(disputeId: string) {
  return `DSP-${disputeId.replaceAll("-", "").slice(0, 8).toUpperCase()}`;
}

export default function ReadableDisputeReferenceEnhancer({ disputeId }: { disputeId: string }) {
  useEffect(() => {
    const heading = Array.from(document.querySelectorAll("h1")).find((element) =>
      element.textContent?.trim().startsWith("Dispute "),
    );

    if (heading) heading.textContent = `Dispute ${readableDisputeRef(disputeId)}`;
  }, [disputeId]);

  return null;
}
