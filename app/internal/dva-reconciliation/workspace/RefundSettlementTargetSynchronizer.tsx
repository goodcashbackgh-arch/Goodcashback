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

function synchroniseRefundTargets(acceptedRefundByDisputeId: Record<string, number>) {
  const anchors = Array.from(
    document.querySelectorAll<HTMLAnchorElement>(
      'a[href*="/internal/dva-reconciliation/workspace?"][href*="target_id="]',
    ),
  );

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

    const amountLine = Array.from(anchor.querySelectorAll<HTMLParagraphElement>("p")).find((node) =>
      node.innerText.trim().startsWith("Amount £"),
    );
    if (!amountLine) continue;

    const operationalExceptionAmount =
      Number(anchor.dataset.operationalExceptionAmountGbp) || parseDisplayedAmount(amountLine.innerText);

    anchor.dataset.operationalExceptionAmountGbp = operationalExceptionAmount.toFixed(2);
    anchor.dataset.acceptedSupplierCreditGbp = acceptedSupplierCredit.toFixed(2);
    anchor.dataset.refundSettlementTargetGbp = acceptedSupplierCredit.toFixed(2);

    amountLine.textContent = [
      `Amount ${gbpFormatter.format(acceptedSupplierCredit)}`,
      `Operational exception ${gbpFormatter.format(operationalExceptionAmount)}`,
      `Accepted supplier credit ${gbpFormatter.format(acceptedSupplierCredit)}`,
    ].join(" · ");
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
