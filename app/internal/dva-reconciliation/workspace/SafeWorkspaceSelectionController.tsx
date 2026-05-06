"use client";

import { useEffect, useMemo, useState } from "react";
import {
  allocateStatementLineToOperationalTargetAction,
  allocateStatementLineToSupplierInvoiceAction,
} from "../actions";
import FxResidualAllocationForm from "./FxResidualAllocationForm";

type Direction = "in" | "out" | "neutral";
type TargetType = "invoice" | "exception" | "unknown";

type PickedItem = {
  id: string;
  label: string;
  amount: number;
  signedAmount: number;
  kind: "statement" | "target";
  direction: Direction;
  targetType?: TargetType;
};

type ClassifiedCard = PickedItem & {
  anchor: HTMLAnchorElement;
};

const gbpFormatter = new Intl.NumberFormat("en-GB", {
  style: "currency",
  currency: "GBP",
  minimumFractionDigits: 2,
});

function gbp(value: number) {
  return gbpFormatter.format(Number.isFinite(value) ? value : 0);
}

function parseGbp(value: string) {
  const match = value.match(/£\s*([\d,]+(?:\.\d{1,2})?)/);
  if (!match) return 0;
  return Number(match[1].replace(/,/g, "")) || 0;
}

function itemLabel(body: string) {
  return (
    body
      .split("\n")
      .map((part) => part.trim())
      .filter(Boolean)[0]
      ?.slice(0, 90) || "Selected item"
  );
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

function inferTargetType(body: string): TargetType {
  if (body.startsWith("Invoice")) return "invoice";
  if (body.startsWith("Exception")) return "exception";
  return "unknown";
}

function hideServerSelectedBadges(anchor: HTMLAnchorElement) {
  const nodes = Array.from(anchor.querySelectorAll<HTMLElement>("*"));
  for (const node of nodes) {
    const text = (node.textContent || "").trim().toLowerCase();
    if (text === "selected target" || text === "selected statement" || text === "selected line") {
      node.style.display = "none";
    }
  }
}

function classifyAnchor(anchor: HTMLAnchorElement): ClassifiedCard | null {
  const body = anchor.innerText.trim();
  if (!body) return null;

  let url: URL;
  try {
    url = new URL(anchor.href, window.location.origin);
  } catch {
    return null;
  }

  if (!url.pathname.includes("/internal/dva-reconciliation/workspace")) return null;

  const lineId = url.searchParams.get("line_id") || "";
  const targetId = url.searchParams.get("target_id") || "";
  const isTargetCard = body.startsWith("Invoice") || body.startsWith("Exception");

  if (targetId && isTargetCard) {
    const direction = inferTargetDirection(body);
    const targetType = inferTargetType(body);
    const amount = parseGbp(body.match(/Amount\s+£[\d,.]+/)?.[0] || body);
    return {
      anchor,
      id: targetId,
      label: itemLabel(body),
      amount,
      signedAmount: signedAmount(direction, amount),
      kind: "target",
      direction,
      targetType,
    };
  }

  if (lineId && !isTargetCard) {
    const direction: Direction = /\bIN\b/.test(body) ? "in" : /\bOUT\b/.test(body) ? "out" : "neutral";
    const amount = parseGbp(body);
    return {
      anchor,
      id: lineId,
      label: itemLabel(body),
      amount,
      signedAmount: signedAmount(direction, amount),
      kind: "statement",
      direction,
    };
  }

  return null;
}

function toggleMap(current: Map<string, PickedItem>, item: PickedItem) {
  const next = new Map(current);
  if (next.has(item.id)) next.delete(item.id);
  else next.set(item.id, item);
  return next;
}

function sum(items: Map<string, PickedItem>, signed = false) {
  return [...items.values()].reduce((total, item) => total + (signed ? item.signedAmount : item.amount), 0);
}

function countDirection(items: Map<string, PickedItem>, direction: Direction) {
  return [...items.values()].filter((item) => item.direction === direction).length;
}

function singleItem(items: Map<string, PickedItem>) {
  const values = [...items.values()];
  return values.length === 1 ? values[0] : null;
}

function resetCardVisual(anchor: HTMLAnchorElement) {
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

function message(statements: Map<string, PickedItem>, targets: Map<string, PickedItem>, net: number) {
  if (statements.size === 0 || targets.size === 0) return "Select bank/card line(s) and operational target(s).";

  const statementIn = countDirection(statements, "in");
  const statementOut = countDirection(statements, "out");
  const targetIn = countDirection(targets, "in");
  const targetOut = countDirection(targets, "out");

  if (statementOut > 0 && targetIn > 0 && targetOut === 0 && statementIn === 0) {
    return "Direction conflict: bank OUT selected against operational IN/refund. Choose the refund IN line or a matching OUT target.";
  }

  if (statementIn > 0 && targetOut > 0 && targetIn === 0 && statementOut === 0) {
    return "Direction conflict: bank IN selected against operational OUT/charge. Choose the matching OUT line or IN target.";
  }

  if (Math.abs(net) < 0.01) return "Net balanced — ready to confirm allocation.";
  return "Net not balanced yet. Confirm the primary allocation first; classify any remaining source balance afterwards.";
}

function operationalAllocationType(statement?: PickedItem | null, target?: PickedItem | null) {
  if (!statement || !target || target.targetType !== "exception") return "";
  if (statement.direction === "in" && target.direction === "in") return "retailer_refund";
  if (statement.direction === "out" && target.direction === "out") return "exception_hold";
  return "";
}

export default function SafeWorkspaceSelectionController() {
  const [cards, setCards] = useState<ClassifiedCard[]>([]);
  const [statements, setStatements] = useState<Map<string, PickedItem>>(new Map());
  const [targets, setTargets] = useState<Map<string, PickedItem>>(new Map());
  const [currentPath, setCurrentPath] = useState("/internal/dva-reconciliation/workspace");

  useEffect(() => {
    const path = `${window.location.pathname}${window.location.search}`;
    setCurrentPath(path);

    const anchors = Array.from(
      document.querySelectorAll<HTMLAnchorElement>('a[href*="/internal/dva-reconciliation/workspace?"]'),
    );
    const classified = anchors.map((anchor) => {
      hideServerSelectedBadges(anchor);
      return classifyAnchor(anchor);
    }).filter((card): card is ClassifiedCard => Boolean(card?.id));
    setCards(classified);

    const params = new URLSearchParams(window.location.search);
    const initialLineId = params.get("line_id") || "";
    const initialTargetId = params.get("target_id") || "";

    if (initialLineId) {
      const line = classified.find((card) => card.kind === "statement" && card.id === initialLineId);
      if (line) setStatements(new Map([[line.id, { ...line, anchor: undefined } as unknown as PickedItem]]));
    }

    if (initialTargetId) {
      const target = classified.find((card) => card.kind === "target" && card.id === initialTargetId);
      if (target) setTargets(new Map([[target.id, { ...target, anchor: undefined } as unknown as PickedItem]]));
    }
  }, []);

  useEffect(() => {
    const cleanupFns: Array<() => void> = [];

    for (const card of cards) {
      const onClick = (event: MouseEvent) => {
        event.preventDefault();
        event.stopPropagation();

        const item: PickedItem = {
          id: card.id,
          label: card.label,
          amount: card.amount,
          signedAmount: card.signedAmount,
          kind: card.kind,
          direction: card.direction,
          targetType: card.targetType,
        };

        if (card.kind === "statement") setStatements((current) => toggleMap(current, item));
        else setTargets((current) => toggleMap(current, item));
      };

      card.anchor.addEventListener("click", onClick);
      cleanupFns.push(() => card.anchor.removeEventListener("click", onClick));
    }

    return () => cleanupFns.forEach((cleanup) => cleanup());
  }, [cards]);

  useEffect(() => {
    for (const card of cards) {
      hideServerSelectedBadges(card.anchor);
      resetCardVisual(card.anchor);
      const selected = card.kind === "statement" ? statements.get(card.id) : targets.get(card.id);
      if (selected) applyCardVisual(card.anchor, selected);
    }
  }, [cards, statements, targets]);

  const statementGross = sum(statements);
  const statementNet = sum(statements, true);
  const targetGross = sum(targets);
  const targetNet = sum(targets, true);
  const netGap = statementNet - targetNet;
  const grossGap = statementGross - targetGross;
  const statement = singleItem(statements);
  const target = singleItem(targets);
  const hasPrimaryTarget = targets.size > 0;
  const canConfirmSupplier = Boolean(statement && target?.targetType === "invoice");
  const operationalType = operationalAllocationType(statement, target);
  const canConfirmOperational = Boolean(statement && target?.targetType === "exception" && operationalType);
  const allocationAmount = Math.min(statement?.amount ?? 0, target?.amount ?? 0);
  const fxResidualAmount = Math.abs(statement?.amount ?? 0);
  const canAllocateFxResidual = Boolean(statement && !hasPrimaryTarget && fxResidualAmount > 0.009);

  const selectedSummary = useMemo(() => message(statements, targets, netGap), [statements, targets, netGap]);

  return (
    <div className="fixed inset-x-0 bottom-0 z-40 border-t border-slate-200 bg-white/95 px-4 py-3 shadow-[0_-10px_30px_rgba(15,23,42,0.12)] backdrop-blur">
      <div className="mx-auto grid max-w-7xl gap-3 lg:grid-cols-[1fr_auto] lg:items-end">
        <div className="space-y-1 text-sm text-slate-700">
          <p className="font-bold text-slate-950">
            Bank selected: {statements.size} · gross {gbp(statementGross)} · net {gbp(statementNet)}
          </p>
          <p>
            Operational selected: {targets.size} · gross {gbp(targetGross)} · net {gbp(targetNet)}
          </p>
          <p className="font-bold text-slate-950">Net position gap: {gbp(netGap)}</p>
          <p className="text-xs text-slate-500">Absolute/gross gap: {gbp(grossGap)}</p>
          <p className="text-xs font-semibold text-amber-700">{selectedSummary}</p>
        </div>

        <div className="flex flex-wrap gap-2 lg:justify-end">
          <button
            type="button"
            onClick={() => {
              setStatements(new Map());
              setTargets(new Map());
            }}
            className="rounded-xl bg-slate-100 px-4 py-2 text-sm font-semibold text-slate-700 hover:bg-slate-200"
          >
            Clear selections
          </button>

          <FxResidualAllocationForm
            canAllocate={canAllocateFxResidual}
            statementLineId={statement?.id ?? ""}
            remainingAmount={fxResidualAmount}
            returnPath={currentPath}
          />

          <form action={allocateStatementLineToOperationalTargetAction}>
            <input type="hidden" name="return_path" value={currentPath} />
            <input type="hidden" name="dva_statement_line_id" value={statement?.id ?? ""} />
            <input type="hidden" name="dispute_id" value={target?.id ?? ""} />
            <input type="hidden" name="allocation_type" value={operationalType} />
            <input type="hidden" name="allocated_gbp_amount" value={allocationAmount ? allocationAmount.toFixed(2) : ""} />
            <input type="hidden" name="notes" value="Allocated from DVA/card matching workspace." />
            <button
              type="submit"
              disabled={!canConfirmOperational}
              className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white disabled:cursor-not-allowed disabled:bg-slate-200 disabled:text-slate-500"
            >
              Confirm operational allocation
            </button>
          </form>

          <form action={allocateStatementLineToSupplierInvoiceAction}>
            <input type="hidden" name="return_path" value={currentPath} />
            <input type="hidden" name="dva_statement_line_id" value={statement?.id ?? ""} />
            <input type="hidden" name="supplier_invoice_id" value={target?.id ?? ""} />
            <input type="hidden" name="allocated_gbp_amount" value={allocationAmount ? allocationAmount.toFixed(2) : ""} />
            <input type="hidden" name="notes" value="Allocated from DVA/card matching workspace." />
            <button
              type="submit"
              disabled={!canConfirmSupplier}
              className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white disabled:cursor-not-allowed disabled:bg-slate-200 disabled:text-slate-500"
            >
              Confirm supplier allocation
            </button>
          </form>
        </div>
      </div>
    </div>
  );
}
