"use client";

import { useEffect, useMemo, useState } from "react";

type PickedItem = {
  id: string;
  label: string;
  amount: number;
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

function classifyCard(anchor: HTMLAnchorElement) {
  const body = anchor.innerText.trim();
  const href = new URL(anchor.href, window.location.origin);

  if (!href.pathname.includes("/internal/dva-reconciliation/workspace")) return null;
  if (!body) return null;

  if (body.startsWith("Invoice") || body.startsWith("Exception")) {
    return {
      side: "target" as const,
      id: href.searchParams.get("target_id") || "",
      amount: parseGbp(body.match(/Amount\s+£[\d,.]+/)?.[0] || body),
      label: itemLabel(body),
    };
  }

  if (body.includes("Allocated") && body.includes("Remaining")) {
    return {
      side: "statement" as const,
      id: href.searchParams.get("line_id") || "",
      amount: parseGbp(body),
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

function sum(items: Map<string, PickedItem>) {
  return [...items.values()].reduce((total, item) => total + item.amount, 0);
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

      const item = {
        id: classified.id,
        label: classified.label,
        amount: classified.amount,
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

      const selected = classified.side === "statement" ? statements.has(classified.id) : targets.has(classified.id);
      anchor.classList.toggle("ring-4", selected);
      anchor.classList.toggle("ring-sky-400", selected);
      anchor.classList.toggle("border-sky-600", selected);
      anchor.classList.toggle("bg-sky-50", selected);
      anchor.setAttribute("aria-pressed", selected ? "true" : "false");
    }
  }, [statements, targets]);

  const statementTotal = useMemo(() => sum(statements), [statements]);
  const targetTotal = useMemo(() => sum(targets), [targets]);
  const difference = statementTotal - targetTotal;

  return (
    <aside className="fixed inset-x-0 bottom-0 z-40 border-t border-slate-200 bg-white/95 px-4 py-3 shadow-2xl backdrop-blur">
      <div className="mx-auto flex max-w-7xl flex-wrap items-center justify-between gap-3 text-sm">
        <div>
          <p className="font-semibold text-slate-950">
            Selected statement lines: {statements.size} · {gbp(statementTotal)}
          </p>
          <p className="text-slate-600">
            Selected targets: {targets.size} · {gbp(targetTotal)}
          </p>
        </div>

        <div className="grid gap-1 text-right">
          <p className="font-semibold text-slate-950">Difference: {gbp(difference)}</p>
          <p className={Math.abs(difference) < 0.01 && statements.size > 0 && targets.size > 0 ? "text-xs font-semibold text-emerald-700" : "text-xs font-semibold text-amber-700"}>
            {Math.abs(difference) < 0.01 && statements.size > 0 && targets.size > 0
              ? "Balanced selection — ready for allocation wiring."
              : "Click cards to select/unselect. No page refresh."}
          </p>
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
