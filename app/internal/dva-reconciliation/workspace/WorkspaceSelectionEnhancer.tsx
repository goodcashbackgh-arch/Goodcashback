"use client";

import { useEffect, useMemo, useState } from "react";

type Direction = "in" | "out" | "neutral";

type PickedItem = {
  id: string;
  label: string;
  amount: number;
  signedAmount: number;
  kind: "statement" | "target";
  direction: Direction;
};

type SelectionMessage = {
  tone: "green" | "amber" | "rose";
  text: string;
};

const gbpFormatter = new Intl.NumberFormat("en-GB", {
  style: "currency",
  currency: "GBP",
  minimumFractionDigits: 2,
});

function gbp(value: number) {
  return gbpFormatter.format(value || 0);
}

function parseGbp(value: string) {
  const match = value.match(/£\s*([\d,]+(?:\.\d{1,2})?)/);
  if (!match) return 0;
  return Number(match[1].replace(/,/g, "")) || 0;
}

function itemLabel(text: string) {
  return text
    .split("\n")
    .map((part) => part.trim())
    .filter(Boolean)[0]
    ?.slice(0, 90) || "Selected item";
}

function signedAmount(direction: Direction, amount: number) {
  if (direction === "in") return amount;
  if (direction === "out") return -amount;
  return 0;
}

function inferTargetDirection(body: string): Direction {
  const lower = body.toLowerCase();

  if (lower.startsWith("invoice")) return "out";
  if (lower.startsWith("exception") && lower.includes("refund")) return "in";
  if (lower.startsWith("exception") && lower.includes("not charged")) return "neutral";
  if (lower.startsWith("exception") && lower.includes("replacement")) return "out";
  if (lower.includes("retailer refund")) return "in";

  return "neutral";
}

function classifyCard(anchor: HTMLAnchorElement) {
  const body = anchor.innerText.trim();
  const href = new URL(anchor.href, window.location.origin);

  if (!href.pathname.includes("/internal/dva-reconciliation/workspace")) return null;
  if (!body) return null;

  if (body.startsWith("Invoice") || body.startsWith("Exception")) {
    const direction = inferTargetDirection(body);
    const amount = parseGbp(body.match(/Amount\s+£[\d,.]+/)?.[0] || body);
    return {
      side: "target" as const,
      id: href.searchParams.get("target_id") || "",
      amount,
      signedAmount: signedAmount(direction, amount),
      direction,
      label: itemLabel(body),
    };
  }

  if (body.includes("Allocated") && body.includes("Remaining")) {
    const direction: Direction = /\bIN\b/.test(body) ? "in" : /\bOUT\b/.test(body) ? "out" : "neutral";
    const amount = parseGbp(body);
    return {
      side: "statement" as const,
      id: href.searchParams.get("line_id") || "",
      amount,
      signedAmount: signedAmount(direction, amount),
      direction,
      label: itemLabel(body),
    };
  }

  return null;
}

function toggleMap(current: Map<string, PickedItem>, item: PickedItem) {
  const next = new Map(current);
  if (next.has(item.id)) {
    next.delete(item.id);
  } else {
    next.set(item.id, item);
  }
  return next;
}

function sum(items: Map<string, PickedItem>, signed = false) {
  return [...items.values()].reduce((total, item) => total + (signed ? item.signedAmount : item.amount), 0);
}

function countDirection(items: Map<string, PickedItem>, direction: Direction) {
  return [...items.values()].filter((item) => item.direction === direction).length;
}

function resetCardVisual(anchor: HTMLAnchorElement) {
  anchor.classList.remove(
    "ring-2",
    "ring-4",
    "ring-sky-200",
    "ring-sky-400",
    "ring-emerald-400",
    "ring-rose-400",
    "border-sky-500",
    "border-sky-600",
    "border-emerald-600",
    "border-rose-600",
    "bg-sky-50",
    "bg-emerald-50",
    "bg-rose-50",
    "shadow-lg"
  );
  anchor.style.borderColor = "#e2e8f0";
  anchor.style.borderWidth = "1px";
  anchor.style.backgroundColor = "#ffffff";
  anchor.style.boxShadow = "none";
}

function applyCardVisual(anchor: HTMLAnchorElement, item: PickedItem) {
  const palette =
    item.direction === "in"
      ? { border: "#059669", bg: "#ecfdf5", shadow: "rgba(5, 150, 105, 0.28)" }
      : item.direction === "out"
        ? { border: "#d97706", bg: "#fffbeb", shadow: "rgba(217, 119, 6, 0.28)" }
        : { border: "#0284c7", bg: "#f0f9ff", shadow: "rgba(2, 132, 199, 0.28)" };

  anchor.style.borderColor = palette.border;
  anchor.style.borderWidth = "2px";
  anchor.style.backgroundColor = palette.bg;
  anchor.style.boxShadow = `0 0 0 4px ${palette.shadow}`;
}

function selectionMessage(statements: Map<string, PickedItem>, targets: Map<string, PickedItem>, netDifference: number): SelectionMessage {
  if (statements.size === 0 || targets.size === 0) {
    return { tone: "amber", text: "Select bank line(s) and operational target(s)." };
  }

  const statementIn = countDirection(statements, "in");
  const statementOut = countDirection(statements, "out");
  const targetIn = countDirection(targets, "in");
  const targetOut = countDirection(targets, "out");

  if (statementOut > 0 && targetIn > 0 && targetOut === 0 && statementIn === 0) {
    return {
      tone: "rose",
      text: "Direction conflict: bank OUT selected against operational IN/refund. Add the related charge target or choose an IN bank line.",
    };
  }

  if (statementIn > 0 && targetOut > 0 && targetIn === 0 && statementOut === 0) {
    return {
      tone: "rose",
      text: "Direction conflict: bank IN selected against operational OUT/charge. Add the matching OUT bank line or choose an IN target.",
    };
  }

  if (Math.abs(netDifference) < 0.01) {
    return { tone: "green", text: "Net balanced — ready for allocation wiring." };
  }

  return {
    tone: "amber",
    text: "Net not balanced yet. Add the related charge/refund/exception line, or leave residual for FX/card/fee handling.",
  };
}

function messageClass(tone: SelectionMessage["tone"]) {
  if (tone === "green") return "text-xs font-semibold text-emerald-700";
  if (tone === "rose") return "text-xs font-semibold text-rose-700";
  return "text-xs font-semibold text-amber-700";
}

export default function WorkspaceSelectionEnhancer() {
  const [statements, setStatements] = useState<Map<string, PickedItem>>(new Map());
  const [targets, setTargets] = useState<Map<string, PickedItem>>(new Map());

  useEffect(() => {
    const handleClick = (event: MouseEvent) => {
      const anchor = (event.target as HTMLElement | null)?.closest("a") as HTMLAnchorElement | null;
      if (!anchor) return;

      const classified = classifyCard(anchor);
      if (!classified || !classified.id) return;

      event.preventDefault();
      event.stopPropagation();

      const item: PickedItem = {
        id: classified.id,
        label: classified.label,
        amount: classified.amount,
        signedAmount: classified.signedAmount,
        direction: classified.direction,
        kind: classified.side === "statement" ? "statement" : "target",
      };

      if (classified.side === "statement") {
        setStatements((current) => toggleMap(current, item));
      } else {
        setTargets((current) => toggleMap(current, item));
      }
    };

    document.addEventListener("click", handleClick, true);
    return () => document.removeEventListener("click", handleClick, true);
  }, []);

  useEffect(() => {
    const anchors = Array.from(document.querySelectorAll<HTMLAnchorElement>('a[href*="/internal/dva-reconciliation/workspace?"]'));

    for (const anchor of anchors) {
      const classified = classifyCard(anchor);
      if (!classified?.id) continue;

      const selectedItem = classified.side === "statement" ? statements.get(classified.id) : targets.get(classified.id);
      resetCardVisual(anchor);

      if (selectedItem) {
        applyCardVisual(anchor, selectedItem);
        anchor.setAttribute("aria-pressed", "true");
      } else {
        anchor.setAttribute("aria-pressed", "false");
      }
    }
  }, [statements, targets]);

  const statementAbsTotal = useMemo(() => sum(statements), [statements]);
  const targetAbsTotal = useMemo(() => sum(targets), [targets]);
  const statementSignedTotal = useMemo(() => sum(statements, true), [statements]);
  const targetSignedTotal = useMemo(() => sum(targets, true), [targets]);
  const netDifference = statementSignedTotal - targetSignedTotal;
  const absoluteDifference = statementAbsTotal - targetAbsTotal;
  const statusMessage = selectionMessage(statements, targets, netDifference);

  return (
    <aside className="fixed inset-x-0 bottom-0 z-40 border-t border-slate-200 bg-white/95 px-4 py-3 shadow-2xl backdrop-blur">
      <div className="mx-auto flex max-w-7xl flex-wrap items-center justify-between gap-3 text-sm">
        <div>
          <p className="font-semibold text-slate-950">
            Bank selected: {statements.size} · gross {gbp(statementAbsTotal)} · net {gbp(statementSignedTotal)}
          </p>
          <p className="text-slate-600">
            Operational selected: {targets.size} · gross {gbp(targetAbsTotal)} · net {gbp(targetSignedTotal)}
          </p>
        </div>

        <div className="grid max-w-xl gap-1 text-right">
          <p className="font-semibold text-slate-950">Net position gap: {gbp(netDifference)}</p>
          <p className="text-xs text-slate-500">Absolute/gross gap: {gbp(absoluteDifference)}</p>
          <p className={messageClass(statusMessage.tone)}>{statusMessage.text}</p>
        </div>

        <div className="flex flex-wrap gap-2">
          <button
            className="rounded-xl bg-slate-100 px-4 py-2 font-semibold text-slate-700"
            type="button"
            onClick={() => {
              setStatements(new Map());
              setTargets(new Map());
            }}
          >
            Clear selections
          </button>
          <button className="rounded-xl bg-slate-200 px-4 py-2 font-semibold text-slate-500" type="button" disabled>
            Confirm allocation next
          </button>
        </div>
      </div>
    </aside>
  );
}
