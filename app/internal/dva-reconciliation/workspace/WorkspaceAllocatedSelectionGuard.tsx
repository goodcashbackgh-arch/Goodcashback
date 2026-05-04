"use client";

import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { createClient } from "@/utils/supabase/client";

type AllocationRow = {
  dva_statement_line_id?: string | null;
  supplier_invoice_id?: string | null;
  allocation_type?: string | null;
  allocation_status?: string | null;
  allocated_gbp_amount?: number | string | null;
};

type AllocationMaps = {
  byStatementLine: Map<string, number>;
  bySupplierInvoice: Map<string, number>;
};

function numeric(value: unknown) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

function parseGbp(value: string) {
  const match = value.match(/£\s*([\d,]+(?:\.\d{1,2})?)/);
  if (!match) return 0;
  return Number(match[1].replace(/,/g, "")) || 0;
}

function addMapTotal(map: Map<string, number>, key: string | null | undefined, value: unknown) {
  if (!key) return;
  map.set(key, (map.get(key) ?? 0) + numeric(value));
}

function classifyWorkspaceCard(anchor: HTMLAnchorElement) {
  const body = anchor.innerText.trim();
  const href = new URL(anchor.href, window.location.origin);

  if (!href.pathname.includes("/internal/dva-reconciliation/workspace")) return null;
  if (!body) return null;

  if (body.startsWith("Invoice")) {
    return {
      side: "supplier_invoice" as const,
      id: href.searchParams.get("target_id") || "",
      amount: parseGbp(body.match(/Amount\s+£[\d,.]+/)?.[0] || body),
    };
  }

  if (body.includes("Allocated") && body.includes("Remaining")) {
    return {
      side: "statement_line" as const,
      id: href.searchParams.get("line_id") || "",
      amount: parseGbp(body),
    };
  }

  return null;
}

function isFullyAllocated(anchor: HTMLAnchorElement, maps: AllocationMaps) {
  const classified = classifyWorkspaceCard(anchor);
  if (!classified?.id || classified.amount <= 0) return false;

  if (classified.side === "statement_line") {
    return (maps.byStatementLine.get(classified.id) ?? 0) >= classified.amount - 0.009;
  }

  return (maps.bySupplierInvoice.get(classified.id) ?? 0) >= classified.amount - 0.009;
}

function markFullyAllocatedCards(maps: AllocationMaps) {
  const anchors = Array.from(document.querySelectorAll<HTMLAnchorElement>('a[href*="/internal/dva-reconciliation/workspace?"]'));

  for (const anchor of anchors) {
    if (!isFullyAllocated(anchor, maps)) {
      if (anchor.dataset.allocationLocked === "true") {
        anchor.dataset.allocationLocked = "false";
        anchor.style.opacity = "";
        anchor.style.cursor = "";
        anchor.title = "";
        anchor.removeAttribute("aria-disabled");
      }
      continue;
    }

    anchor.dataset.allocationLocked = "true";
    anchor.style.opacity = "0.58";
    anchor.style.cursor = "not-allowed";
    anchor.title = "Already fully allocated. Use completed/balanced review or reversal, not new allocation.";
    anchor.setAttribute("aria-disabled", "true");
  }
}

export default function WorkspaceAllocatedSelectionGuard() {
  const mapsRef = useRef<AllocationMaps>({
    byStatementLine: new Map(),
    bySupplierInvoice: new Map(),
  });
  const [loadedAt, setLoadedAt] = useState(0);

  useEffect(() => {
    let cancelled = false;

    async function loadConfirmedAllocations() {
      const supabase = createClient();
      const { data, error } = await supabase
        .from("dva_statement_line_allocations")
        .select("dva_statement_line_id, supplier_invoice_id, allocation_type, allocation_status, allocated_gbp_amount")
        .eq("allocation_status", "confirmed")
        .limit(2000);

      if (cancelled || error) return;

      const byStatementLine = new Map<string, number>();
      const bySupplierInvoice = new Map<string, number>();

      for (const row of (data ?? []) as AllocationRow[]) {
        addMapTotal(byStatementLine, row.dva_statement_line_id, row.allocated_gbp_amount);
        if (row.allocation_type === "supplier_invoice") {
          addMapTotal(bySupplierInvoice, row.supplier_invoice_id, row.allocated_gbp_amount);
        }
      }

      mapsRef.current = { byStatementLine, bySupplierInvoice };
      setLoadedAt(Date.now());
    }

    void loadConfirmedAllocations();

    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => {
    markFullyAllocatedCards(mapsRef.current);
  }, [loadedAt]);

  useLayoutEffect(() => {
    const handleClick = (event: MouseEvent) => {
      const anchor = (event.target as HTMLElement | null)?.closest("a") as HTMLAnchorElement | null;
      if (!anchor) return;

      if (!isFullyAllocated(anchor, mapsRef.current)) return;

      event.preventDefault();
      event.stopPropagation();
      event.stopImmediatePropagation();
      markFullyAllocatedCards(mapsRef.current);
    };

    document.addEventListener("click", handleClick, true);
    return () => document.removeEventListener("click", handleClick, true);
  }, []);

  return null;
}
