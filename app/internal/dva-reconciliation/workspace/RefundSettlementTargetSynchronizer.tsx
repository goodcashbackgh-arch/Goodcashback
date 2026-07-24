"use client";

import { useLayoutEffect } from "react";
import { usePathname, useSearchParams } from "next/navigation";

type Props = {
  acceptedRefundByDisputeId: Record<string, number>;
};

const gbpFormatter = new Intl.NumberFormat("en-GB", {
  style: "currency",
  currency: "GBP",
  minimumFractionDigits: 2,
});

function parseDisplayedAmount(value: string) {
  const match = value.match(/Amount\s+£([\d,.]+)/i);
  if (!match) return 0;
  const parsed = Number(match[1].replaceAll(",", ""));
  return Number.isFinite(parsed) ? parsed : 0;
}

function currentStatementAmount() {
  const lineId = new URLSearchParams(window.location.search).get("line_id") || "";
  if (!lineId) return 0;
  const anchors = Array.from(document.querySelectorAll<HTMLAnchorElement>('a[href*="/internal/dva-reconciliation/workspace?"][href*="line_id="]'));
  const selected = anchors.find((anchor) => {
    try {
      return new URL(anchor.href, window.location.origin).searchParams.get("line_id") === lineId;
    } catch {
      return false;
    }
  });
  if (!selected) return 0;
  const header = selected.innerText.split("\n").map((part) => part.trim()).find(Boolean) || "";
  const match = header.match(/\b(?:IN|OUT)\b\s*·\s*£([\d,.]+)/i);
  if (!match) return 0;
  const parsed = Number(match[1].replaceAll(",", ""));
  return Number.isFinite(parsed) ? parsed : 0;
}

function score(statementAmount: number, targetAmount: number) {
  if (statementAmount <= 0 || targetAmount <= 0) return 0;
  const difference = Math.abs(statementAmount - targetAmount);
  if (difference < 0.01) return 100;
  if (difference <= 2) return 75;
  if (difference <= 5) return 50;
  if (difference <= 15) return 25;
  return 0;
}

function synchroniseRefundTargets(acceptedRefundByDisputeId: Record<string, number>) {
  const statementAmount = currentStatementAmount();
  const anchors = Array.from(document.querySelectorAll<HTMLAnchorElement>('a[href*="/internal/dva-reconciliation/workspace?"][href*="target_id="]'));

  for (const anchor of anchors) {
    const body = anchor.innerText.trim();
    if (!body.startsWith("Exception") || !body.toLowerCase().includes("refund")) continue;

    let disputeId = "";
    try {
      disputeId = new URL(anchor.href, window.location.origin).searchParams.get("target_id") || "";
    } catch {
      continue;
    }

    const acceptedSupplierCredit = acceptedRefundByDisputeId[disputeId] ?? 0;
    if (acceptedSupplierCredit <= 0) continue;

    const paragraphs = Array.from(anchor.querySelectorAll<HTMLParagraphElement>("p"));
    const amountLine = paragraphs.find((node) => node.innerText.trim().startsWith("Amount £"));
    if (!amountLine) continue;

    const operationalExceptionAmount = Number(anchor.dataset.operationalExceptionAmountGbp) || parseDisplayedAmount(amountLine.innerText);
    anchor.dataset.operationalExceptionAmountGbp = operationalExceptionAmount.toFixed(2);
    anchor.dataset.acceptedSupplierCreditGbp = acceptedSupplierCredit.toFixed(2);
    anchor.dataset.refundSettlementTargetGbp = acceptedSupplierCredit.toFixed(2);

    amountLine.textContent = `Amount ${gbpFormatter.format(acceptedSupplierCredit)} · Operational exception ${gbpFormatter.format(operationalExceptionAmount)} · Accepted supplier credit ${gbpFormatter.format(acceptedSupplierCredit)}`;

    const scoreLine = paragraphs.find((node) => node.innerText.trim().startsWith("Amount closeness score:"));
    if (scoreLine && statementAmount > 0) {
      scoreLine.textContent = `Amount closeness score: ${score(statementAmount, acceptedSupplierCredit)}`;
    }
  }
}

export default function RefundSettlementTargetSynchronizer({ acceptedRefundByDisputeId }: Props) {
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const routeKey = `${pathname}?${searchParams.toString()}`;

  useLayoutEffect(() => {
    synchroniseRefundTargets(acceptedRefundByDisputeId);
  }, [acceptedRefundByDisputeId, routeKey]);

  return null;
}
