export function prettyStatus(value: string | null | undefined) {
  if (!value) return "In progress";
  return value.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase());
}

export function importerOrderStatusLabel(value: string | null | undefined) {
  if (!value) return "In progress";
  if (value === "partially_progressed") return "Invoice reconciled; tracking open";
  if (value === "pending_dva_funding") return "Payment pending";
  if (value === "reconciling") return "Invoice reconciliation open";
  return prettyStatus(value);
}

export function customerOrderStatusLabel(args: {
  rawStatus?: string | null;
  lifecycleStatus?: string | null;
  thresholdMet?: boolean;
  reviewReady?: boolean;
}) {
  const status = String(args.lifecycleStatus ?? args.rawStatus ?? "").toLowerCase();
  if (args.reviewReady) return "Ready for your review";
  if (!args.thresholdMet) return "Payment required";
  if (["pending_dva_funding", "funding_pending", "draft"].includes(status)) return "Funded; awaiting purchase evidence";
  if (["reconciling", "partially_progressed", "invoice_reconciled_tracking_open"].includes(status)) return "Order being prepared";
  if (["ready_for_shipment", "shipment_booked"].includes(status)) return "Preparing for shipment";
  if (["shipment_dispatched", "awaiting_importer_receipt"].includes(status)) return "Shipment in progress";
  if (["completed", "archived"].includes(status)) return "Completed";
  if (["discrepancy_open", "awaiting_financial_closure"].includes(status)) return "Under review";
  return prettyStatus(args.lifecycleStatus ?? args.rawStatus);
}

export function varianceExplainedByConfirmedCredit(args: {
  qtyVariance: number;
  valueVariance: number;
  creditCreatedGbp: number;
  evidenceStatus?: string | null;
}) {
  return (
    args.qtyVariance === 0 &&
    args.valueVariance < -0.004 &&
    Math.abs(Math.abs(args.valueVariance) - args.creditCreatedGbp) < 0.01 &&
    args.creditCreatedGbp > 0 &&
    args.evidenceStatus === "credit_created"
  );
}
