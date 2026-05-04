"use client";

import { useEffect, useMemo, useState } from "react";
import { createClient } from "@/utils/supabase/client";
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

type AllocationRow = {
  dva_statement_line_id?: string | null;
  supplier_invoice_id?: string | null;
  dispute_id?: string | null;
  allocation_type?: string | null;
  allocation_status?: string | null;
  allocated_gbp_amount?: number | string | null;
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

function numeric(value: unknown) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
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

function inferTargetType(body: string): TargetType {
  if (body.startsWith("Invoice")) return "invoice";
  if (body.startsWith("Exception")) return "exception";
  return "unknown";
}

function classifyCard(anchor: HTMLAnchorElement) {
  const body = anchor.innerText.trim();
  const href = new URL(anchor.href, window.location.origin);

  if (!href.pathname.includes("/internal/dva-reconciliation/workspace")) return null;
  if (!body) return null;

  if (body.startsWith("Invoice") || body.startsWith("Exception")) {
    const direction = inferTargetDirection(body);
    const targetType = inferTargetType(body);
    const amount = parseGbp(body.match(/Amount\s+£[\d,.]+/)?.[0] || body);
    return {
      side: "target" as const,
      id: href.searchParams.get("target_id") || "",
      amount,
      signedAmount: signedAmount(direction, amount),
      direction,
      targetType,
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
  if (statements.size === 0 || targets.size === 0) return { tone: "amber", text: "Select bank line(s) and operational target(s)." };

  const statementIn = countDirection(statements, "in");
  const statementOut = countDirection(statements, "out");
  const targetIn = countDirection(targets, "in");
  const targetOut = countDirection(targets, "out");

  if (statementOut > 0 && targetIn > 0 && targetOut === 0 && statementIn === 0) {
    return { tone: "rose", text: "Direction conflict: bank OUT selected against operational IN/refund. Add the related charge target or choose an IN bank line." };
  }

  if (statementIn > 0 && targetOut > 0 && targetIn === 0 && statementOut === 0) {
    return { tone: "rose", text: "Direction conflict: bank IN selected against operational OUT/charge. Add the matching OUT bank line or choose an IN target." };
  }

  if (Math.abs(netDifference) < 0.01) return { tone: "green", text: "Net balanced — ready for allocation wiring." };

  return { tone: "amber", text: "Net not balanced yet. Add the related charge/refund/exception line, or leave residual for FX/card/fee handling." };
}

function messageClass(tone: SelectionMessage["tone"]) {
  if (tone === "green") return "text-xs font-semibold text-emerald-700";
  if (tone === "rose") return "text-xs font-semibold text-rose-700";
  return "text-xs font-semibold text-amber-700";
}

function singleItem(items: Map<string, PickedItem>) {
  const values = [...items.values()];
  return values.length === 1 ? values[0] : null;
}

function addMapTotal(map: Map<string, number>, key: string | null | undefined, value: unknown) {
  if (!key) return;
  map.set(key, (map.get(key) ?? 0) + numeric(value));
}

function operationalAllocationType(statement?: PickedItem | null, target?: PickedItem | null) {
  if (!statement || !target || target.targetType !== "exception") return "";
  if (statement.direction === "in" && target.direction === "in") return "retailer_refund";
  if (statement.direction === "out" && target.direction === "out") return "exception_hold";
  return "";
}

export default function WorkspaceSelectionEnhancer() {
  const [statements, setStatements] = useState<Map<string, PickedItem>>(new Map());
  const [targets, setTargets] = useState<Map<string, PickedItem>>(new Map());
  const [currentPath, setCurrentPath] = useState("/internal/dva-reconciliation/workspace");
  const [allocatedByStatementLine, setAllocatedByStatementLine] = useState<Map<string, number>>(new Map());
  const [allocatedBySupplierInvoice, setAllocatedBySupplierInvoice] = useState<Map<string, number>>(new Map());
  const [allocatedByOperationalTarget, setAllocatedByOperationalTarget] = useState<Map<string, number>>(new Map());

  useEffect(() => {
    setCurrentPath(`${window.location.pathname}${window.location.search}`);
  }, []);

  useEffect(() => {
    let cancelled = false;

    async function loadConfirmedAllocations() {
      const supabase = createClient();
      const { data, error } = await supabase
        .from("dva_statement_line_allocations")
        .select("dva_statement_line_id, supplier_invoice_id, dispute_id, allocation_type, allocation_status, allocated_gbp_amount")
        .eq("allocation_status", "confirmed")
        .limit(2000);

      if (cancelled || error) return;

      const lineMap = new Map<string, number>();
      const invoiceMap = new Map<string, number>();
      const operationalMap = new Map<string, number>();

      for (const row of (data ?? []) as AllocationRow[]) {
        addMapTotal(lineMap, row.dva_statement_line_id, row.allocated_gbp_amount);
        if (row.allocation_type === "supplier_invoice") addMapTotal(invoiceMap, row.supplier_invoice_id, row.allocated_gbp_amount);
        if (row.dispute_id) addMapTotal(operationalMap, row.dispute_id, row.allocated_gbp_amount);
      }

      setAllocatedByStatementLine(lineMap);
      setAllocatedBySupplierInvoice(invoiceMap);
      setAllocatedByOperationalTarget(operationalMap);
    }

    void loadConfirmedAllocations();

    return () => {
      cancelled = true;
    };
  }, []);

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
        targetType: classified.side === "target" ? classified.targetType : undefined,
      };

      if (classified.side === "statement") setStatements((current) => toggleMap(current, item));
      else setTargets((current) => toggleMap(current, item));
    };

    document.addEventListener("click", handleClick, true);
    return () => document.removeEventListener("click", handleClick, true);
  }, []);

  useEffect(() => {
    const searchParams = new URLSearchParams(window.location.search);
    const leftStatus = searchParams.get("left_status") || "unmatched";
    const rightStatus = searchParams.get("right_status") || "usable";
    const anchors = Array.from(document.querySelectorAll<HTMLAnchorElement>('a[href*="/internal/dva-reconciliation/workspace?"]'));

    for (const anchor of anchors) {
      const classified = classifyCard(anchor);
      if (!classified?.id) continue;

      anchor.style.display = "";

      const isAllocatedStatementInUnmatchedView =
        classified.side === "statement" &&
        leftStatus === "unmatched" &&
        (allocatedByStatementLine.get(classified.id) ?? 0) > 0.009;

      const isFullyAllocatedInvoiceInUsableView =
        classified.side === "target" &&
        classified.targetType === "invoice" &&
        rightStatus === "usable" &&
        classified.amount > 0 &&
        (allocatedBySupplierInvoice.get(classified.id) ?? 0) >= classified.amount - 0.009;

      const isFullyAllocatedOperationalInUsableView =
        classified.side === "target" &&
        classified.targetType === "exception" &&
        rightStatus === "usable" &&
        classified.amount > 0 &&
        (allocatedByOperationalTarget.get(classified.id) ?? 0) >= classified.amount - 0.009;

      if (isAllocatedStatementInUnmatchedView || isFullyAllocatedInvoiceInUsableView || isFullyAllocatedOperationalInUsableView) {
        anchor.style.display = "none";
        continue;
      }

      const selectedItem = classified.side === "statement" ? statements.get(classified.id) : targets.get(classified.id);
      resetCardVisual(anchor);

      if (selectedItem) {
        applyCardVisual(anchor, selectedItem);
        anchor.setAttribute("aria-pressed", "true");
      } else {
        anchor.setAttribute("aria-pressed", "false");
      }
    }
  }, [statements, targets, allocatedByStatementLine, allocatedBySupplierInvoice, allocatedByOperationalTarget]);

  const statementAbsTotal = useMemo(() => sum(statements), [statements]);
  const targetAbsTotal = useMemo(() => sum(targets), [targets]);
  const statementSignedTotal = useMemo(() => sum(statements, true), [statements]);
  const targetSignedTotal = useMemo(() => sum(targets, true), [targets]);
  const netDifference = statementSignedTotal - targetSignedTotal;
  const absoluteDifference = statementAbsTotal - targetAbsTotal;
  const statusMessage = selectionMessage(statements, targets, netDifference);
  const selectedStatement = singleItem(statements);
  const selectedTarget = singleItem(targets);
  const selectedStatementAlreadyAllocated = selectedStatement ? allocatedByStatementLine.get(selectedStatement.id) ?? 0 : 0;
  const selectedTargetAlreadyAllocated =
    selectedTarget?.targetType === "invoice"
      ? allocatedBySupplierInvoice.get(selectedTarget.id) ?? 0
      : selectedTarget?.targetType === "exception"
        ? allocatedByOperationalTarget.get(selectedTarget.id) ?? 0
        : 0;
  const selectedStatementAvailable = selectedStatement ? Math.max(0, selectedStatement.amount - selectedStatementAlreadyAllocated) : 0;
  const selectedTargetAvailable = selectedTarget ? Math.max(0, selectedTarget.amount - selectedTargetAlreadyAllocated) : 0;
  const canConfirmSupplierInvoice =
    Boolean(selectedStatement) &&
    Boolean(selectedTarget) &&
    selectedStatement?.direction === "out" &&
    selectedTarget?.direction === "out" &&
    selectedTarget?.targetType === "invoice" &&
    selectedStatementAvailable > 0.009 &&
    selectedTargetAvailable > 0.009;
  const supplierInvoiceAllocationAmount = canConfirmSupplierInvoice ? Math.min(selectedStatementAvailable, selectedTargetAvailable) : 0;
  const operationalType = operationalAllocationType(selectedStatement, selectedTarget);
  const canConfirmOperationalAllocation =
    Boolean(operationalType) &&
    Boolean(selectedStatement) &&
    Boolean(selectedTarget) &&
    selectedStatementAvailable > 0.009 &&
    selectedTargetAvailable > 0.009;
  const operationalAllocationAmount = canConfirmOperationalAllocation ? Math.min(selectedStatementAvailable, selectedTargetAvailable) : 0;
  const canClassifyFxCardResidual =
    Boolean(selectedStatement) &&
    statements.size === 1 &&
    targets.size === 0 &&
    selectedStatement?.direction === "out" &&
    selectedStatementAlreadyAllocated > 0.009 &&
    selectedStatementAvailable > 0.009;

  const disabledReason = !selectedStatement
    ? "Select one bank/card statement line."
    : !selectedTarget
      ? canClassifyFxCardResidual
        ? `Residual available for FX/card/fee classification: ${gbp(selectedStatementAvailable)}.`
        : "Select one supplier invoice, refund, replacement, or exception target."
      : selectedTarget.targetType === "exception" && canConfirmOperationalAllocation
        ? `Ready to confirm ${operationalType.replaceAll("_", " ")} allocation of ${gbp(operationalAllocationAmount)}.`
        : selectedTarget.targetType === "exception"
          ? "This exception target needs matching direction: OUT→replacement/exception, IN→refund."
          : selectedStatement.direction !== "out"
            ? "Supplier invoice allocation requires an OUT statement line."
            : selectedTarget.targetType !== "invoice"
              ? "Select a supplier invoice or supported exception target."
              : selectedTarget.direction !== "out"
                ? "Supplier invoice target must be an OUT/charge target."
                : canConfirmSupplierInvoice
                  ? `Ready to confirm supplier allocation of ${gbp(supplierInvoiceAllocationAmount)}.`
                  : "No remaining amount is available on the selected statement line or target.";

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
          {selectedStatement ? (
            <p className="text-xs text-slate-500">
              Selected bank remaining: {gbp(selectedStatementAvailable)} · already allocated: {gbp(selectedStatementAlreadyAllocated)}
            </p>
          ) : null}
        </div>

        <div className="grid max-w-xl gap-1 text-right">
          <p className="font-semibold text-slate-950">Net position gap: {gbp(netDifference)}</p>
          <p className="text-xs text-slate-500">Absolute/gross gap: {gbp(absoluteDifference)}</p>
          <p className={messageClass(statusMessage.tone)}>{statusMessage.text}</p>
          <p className="text-xs text-slate-500">{disabledReason}</p>
        </div>

        <div className="flex flex-wrap justify-end gap-2">
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

          <FxResidualAllocationForm
            canAllocate={canClassifyFxCardResidual}
            statementLineId={selectedStatement?.id ?? ""}
            remainingAmount={selectedStatementAvailable}
            returnPath={currentPath}
          />

          <form action={allocateStatementLineToOperationalTargetAction}>
            <input type="hidden" name="dva_statement_line_id" value={selectedStatement?.id ?? ""} />
            <input type="hidden" name="dispute_id" value={selectedTarget?.targetType === "exception" ? selectedTarget.id : ""} />
            <input type="hidden" name="allocation_type" value={operationalType} />
            <input type="hidden" name="allocated_gbp_amount" value={canConfirmOperationalAllocation ? operationalAllocationAmount.toFixed(2) : ""} />
            <input type="hidden" name="notes" value="Allocated from DVA/card matching workspace operational target." />
            <input type="hidden" name="return_path" value={currentPath} />
            <button
              className={
                canConfirmOperationalAllocation
                  ? "rounded-xl bg-sky-700 px-4 py-2 font-semibold text-white shadow-sm hover:bg-sky-800"
                  : "rounded-xl bg-slate-200 px-4 py-2 font-semibold text-slate-500"
              }
              type="submit"
              disabled={!canConfirmOperationalAllocation}
            >
              Confirm operational allocation
            </button>
          </form>

          <form action={allocateStatementLineToSupplierInvoiceAction}>
            <input type="hidden" name="dva_statement_line_id" value={selectedStatement?.id ?? ""} />
            <input type="hidden" name="supplier_invoice_id" value={selectedTarget?.targetType === "invoice" ? selectedTarget.id : ""} />
            <input type="hidden" name="allocated_gbp_amount" value={canConfirmSupplierInvoice ? supplierInvoiceAllocationAmount.toFixed(2) : ""} />
            <input type="hidden" name="notes" value="Allocated from DVA/card matching workspace." />
            <input type="hidden" name="return_path" value={currentPath} />
            <button
              className={
                canConfirmSupplierInvoice
                  ? "rounded-xl bg-slate-950 px-4 py-2 font-semibold text-white shadow-sm hover:bg-slate-800"
                  : "rounded-xl bg-slate-200 px-4 py-2 font-semibold text-slate-500"
              }
              type="submit"
              disabled={!canConfirmSupplierInvoice}
            >
              Confirm supplier allocation
            </button>
          </form>
        </div>
      </div>
    </aside>
  );
}
