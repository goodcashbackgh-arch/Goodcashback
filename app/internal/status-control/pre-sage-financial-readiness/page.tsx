import Link from "next/link";
import { createClient } from "@/utils/supabase/server";

type SearchParamsValue = Record<string, string | string[] | undefined>;
type Row = Record<string, unknown>;

type OrderRow = {
  id: string;
  order_ref: string | null;
  importer_id: string | null;
  retailer_id: string | null;
  status: string | null;
  order_type: string | null;
  parent_order_id: string | null;
  created_at: string | null;
};

type ImporterRow = {
  id: string;
  company_name: string | null;
  trading_name: string | null;
};

type RetailerRow = {
  id: string;
  name: string | null;
};

type SupplierInvoiceRow = {
  id: string;
  order_id: string | null;
  invoice_ref: string | null;
  review_status: string | null;
  blocked_from_sage_yn?: boolean | string | null;
  ocr_invoice_total_gbp: number | string | null;
  reconciliation_gbp_total: number | string | null;
};

type DisputeRow = {
  id: string;
  order_id: string | null;
  desired_outcome: string | null;
  status: string | null;
  amount_impact_gbp: number | string | null;
  refund_approved_at: string | null;
  replacement_child_order_id: string | null;
  resolved_at: string | null;
  raised_at: string | null;
};

type DisputeLineRow = {
  dispute_id: string | null;
  conversation_status: string | null;
  resolved_at: string | null;
};

type MessageRow = {
  dispute_id: string | null;
  message_type: string | null;
  counterparty: string | null;
};

type AllocationRow = {
  allocation_id: string | null;
  importer_id: string | null;
  supplier_invoice_id: string | null;
  supplier_invoice_ref: string | null;
  order_id: string | null;
  order_ref: string | null;
  dispute_id: string | null;
  allocation_type: string | null;
  allocation_status: string | null;
  allocated_gbp_amount: number | string | null;
  reversed_yn: boolean | string | null;
};

type StatementSummaryRow = {
  importer_id: string | null;
  match_status: string | null;
  confirmed_balanced_yn: boolean | string | null;
  confirmed_unallocated_gbp: number | string | null;
  supplier_invoice_allocated_gbp: number | string | null;
  retailer_refund_allocated_gbp: number | string | null;
  fx_card_or_fee_allocated_gbp: number | string | null;
  exception_or_hold_allocated_gbp: number | string | null;
};

type SageReadyRow = {
  queue_row_id: string;
  document_lane: string | null;
  document_type: string | null;
  order_id: string | null;
  order_ref: string | null;
  shipment_batch_id: string | null;
  booking_ref: string | null;
  counterparty_name: string | null;
  amount_gbp: number | string | null;
  sage_status: string | null;
  sage_invoice_id: string | null;
  sage_posted_at: string | null;
  readiness_status: string | null;
  blocker: string | null;
  reference_text: string | null;
  detail_href: string | null;
};

type LaneReadiness = {
  label: string;
  ready: boolean;
  blockers: string[];
  warnings: string[];
  rowCount: number;
  href: string;
};

type FixAction = {
  owner: string;
  label: string;
  href: string;
};

const gbpFormatter = new Intl.NumberFormat("en-GB", {
  style: "currency",
  currency: "GBP",
  minimumFractionDigits: 2,
});

const TERMINAL_EXCEPTION_STATUSES = new Set(["replaced", "awaiting_refund_credit", "refunded", "closed", "resolved"]);
const FINALISH_EXCEPTION_STATUSES = new Set(["approved_refund", "awaiting_refund_credit", "refunded", "approved_replacement", "replaced", "closed", "resolved"]);
const EVIDENCE_READY_LINE_STATUSES = new Set(["retailer_response_received", "resolved_refund", "resolved_replacement", "resolved", "closed_no_action"]);
const BLOCKING_SUPPLIER_INVOICE_STATUSES = new Set(["needs_action", "pending_review", "duplicate_blocked", "rejected_resubmit_required"]);

function text(value: unknown) {
  if (Array.isArray(value)) return text(value[0]);
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  if (typeof value === "boolean") return value ? "true" : "false";
  return "";
}

function firstParam(value: unknown) {
  if (Array.isArray(value)) return text(value[0]);
  return text(value);
}

function num(value: unknown) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

function bool(value: unknown) {
  return value === true || text(value).toLowerCase() === "true";
}

function gbp(value: unknown) {
  return gbpFormatter.format(num(value));
}

function pretty(value: unknown) {
  const raw = text(value);
  return raw ? raw.replaceAll("_", " ") : "—";
}

function importerLabel(importer?: ImporterRow) {
  return importer?.trading_name || importer?.company_name || importer?.id || "All importers";
}

function groupBy<T>(rows: T[], keyFn: (row: T) => string) {
  const grouped = new Map<string, T[]>();
  for (const row of rows) {
    const key = keyFn(row);
    if (!key) continue;
    grouped.set(key, [...(grouped.get(key) ?? []), row]);
  }
  return grouped;
}

function amountFromFundingRow(row?: Row) {
  if (!row) return { funded: 0, required: 0, gap: 0, label: "unknown" };

  const required = num(row.purchase_funding_threshold_gbp);
  const funded = num(row.funded_total_gbp);
  const gap = num(row.gap_remaining_gbp);
  const thresholdMet = bool(row.threshold_met_yn) || bool(row.already_funded_yn) || gap <= 0;
  const label = thresholdMet ? "funded" : funded > 0 ? "part funded" : "funding gap";

  return { funded, required, gap, label };
}

function nonReversedAllocations(allocations: AllocationRow[]) {
  return allocations.filter((allocation) => text(allocation.allocation_status) !== "reversed" && !bool(allocation.reversed_yn));
}

function confirmedAllocations(allocations: AllocationRow[]) {
  return nonReversedAllocations(allocations).filter((allocation) => text(allocation.allocation_status) === "confirmed");
}

function lineEvidenceReady(lines: DisputeLineRow[]) {
  const activeLines = lines.filter((line) => !line.resolved_at);
  return activeLines.length > 0 && activeLines.every((line) => EVIDENCE_READY_LINE_STATUSES.has(text(line.conversation_status)));
}

function hasRetailerReply(messages: MessageRow[]) {
  return messages.some((message) => text(message.message_type) === "retailer_reply" || text(message.counterparty) === "retailer");
}

function invoiceReadiness(invoices: SupplierInvoiceRow[], activeSupplierAllocations: AllocationRow[]) {
  if (invoices.length === 0) return { label: "missing", ready: false, blockers: ["No supplier invoice found"], warnings: [] };

  const blockers: string[] = [];
  const warnings: string[] = [];
  const activeSupplierInvoiceIds = new Set(activeSupplierAllocations.map((allocation) => text(allocation.supplier_invoice_id)).filter(Boolean));
  const activeInvoices = invoices.filter((invoice) => activeSupplierInvoiceIds.has(invoice.id));

  if (activeSupplierAllocations.length === 0) {
    blockers.push("No confirmed supplier OUT allocation linked to a supplier invoice");
  }

  if (activeSupplierInvoiceIds.size > 0 && activeInvoices.length === 0) {
    blockers.push("Confirmed supplier OUT allocation points to a supplier invoice that is not visible on this order");
  }

  for (const invoice of activeInvoices) {
    const status = text(invoice.review_status);
    if (bool(invoice.blocked_from_sage_yn)) blockers.push(`Active invoice ${invoice.invoice_ref || invoice.id} is blocked from Sage`);
    if (BLOCKING_SUPPLIER_INVOICE_STATUSES.has(status)) {
      blockers.push(`Active invoice ${invoice.invoice_ref || invoice.id} needs review: ${pretty(status)}`);
    }
  }

  const hasApprovedCurrent = activeInvoices.some((invoice) => text(invoice.review_status) === "approved_current" && !bool(invoice.blocked_from_sage_yn));
  if (!hasApprovedCurrent) blockers.push("No approved-current active supplier invoice found");

  const inactiveProblemInvoices = invoices.filter((invoice) => {
    if (activeSupplierInvoiceIds.has(invoice.id)) return false;
    const status = text(invoice.review_status);
    return bool(invoice.blocked_from_sage_yn) || BLOCKING_SUPPLIER_INVOICE_STATUSES.has(status);
  });

  for (const invoice of inactiveProblemInvoices) {
    warnings.push(`Inactive/superseded invoice ${invoice.invoice_ref || invoice.id} is ${pretty(invoice.review_status)} and is ignored because it is not linked to a confirmed supplier OUT allocation`);
  }

  return {
    label: hasApprovedCurrent && blockers.length === 0 ? "approved current" : "not ready",
    ready: hasApprovedCurrent && blockers.length === 0,
    blockers,
    warnings,
  };
}

function exceptionReadiness(
  disputes: DisputeRow[],
  linesByDisputeId: Map<string, DisputeLineRow[]>,
  messagesByDisputeId: Map<string, MessageRow[]>,
  allocations: AllocationRow[],
) {
  const blockers: string[] = [];
  const warnings: string[] = [];
  const activeAllocations = nonReversedAllocations(allocations);
  const activeConfirmedAllocations = confirmedAllocations(allocations);

  for (const dispute of disputes) {
    const status = text(dispute.status);
    const outcome = text(dispute.desired_outcome);
    const lines = linesByDisputeId.get(dispute.id) ?? [];
    const messages = messagesByDisputeId.get(dispute.id) ?? [];
    const evidenceReady = lineEvidenceReady(lines);
    const retailerReply = hasRetailerReply(messages);
    const disputeAllocations = activeAllocations.filter((allocation) => allocation.dispute_id === dispute.id);
    const disputeConfirmedAllocations = activeConfirmedAllocations.filter((allocation) => allocation.dispute_id === dispute.id);
    const hasRefundAllocation = disputeConfirmedAllocations.some((allocation) => text(allocation.allocation_type) === "retailer_refund");
    const hasSupplierChargeAllocation = disputeConfirmedAllocations.some((allocation) => text(allocation.allocation_type) === "supplier_invoice");
    const hasExceptionHold = disputeAllocations.some((allocation) => ["exception_hold", "unmatched_hold"].includes(text(allocation.allocation_type)));

    if (!TERMINAL_EXCEPTION_STATUSES.has(status) && !dispute.resolved_at) {
      blockers.push(`${pretty(outcome)} exception is still open: ${pretty(status)}`);
    }

    if (FINALISH_EXCEPTION_STATUSES.has(status) && (!evidenceReady || !retailerReply) && status !== "closed" && status !== "resolved") {
      warnings.push(`${pretty(outcome)} exception ${dispute.id.slice(0, 8)} has later-stage status ${pretty(status)} but incomplete retailer evidence.`);
    }

    if (outcome === "refund" && ["approved_refund", "awaiting_refund_credit"].includes(status) && !hasRefundAllocation) {
      blockers.push("Refund outcome accepted/awaiting credit but no DVA/card IN refund allocation is linked");
    }

    if (outcome === "replacement" && status === "replaced" && !dispute.replacement_child_order_id) {
      blockers.push("Replacement marked replaced but no replacement child order is linked");
    }

    if (outcome === "replacement" && ["approved_replacement", "replaced"].includes(status) && !hasSupplierChargeAllocation && !hasExceptionHold) {
      warnings.push("Replacement is accepted/replaced; check whether it was free, charged again, or refund+repurchase before Sage readiness.");
    }
  }

  if (disputes.length === 0) return { label: "none", ready: true, blockers, warnings };
  return { label: blockers.length === 0 ? "controlled" : "blocked", ready: blockers.length === 0, blockers, warnings };
}

function allocationMatchesOrderOrDispute(allocation: AllocationRow, order: OrderRow, disputes: DisputeRow[]) {
  return allocation.order_id === order.id || allocation.order_ref === order.order_ref || disputes.some((dispute) => dispute.id === allocation.dispute_id);
}

function activeSupplierAllocationsForOrder(order: OrderRow, disputes: DisputeRow[], allocationRows: AllocationRow[]) {
  return confirmedAllocations(allocationRows).filter((allocation) => {
    return allocationMatchesOrderOrDispute(allocation, order, disputes) && text(allocation.allocation_type) === "supplier_invoice" && Boolean(text(allocation.supplier_invoice_id));
  });
}

function dvaReadiness(order: OrderRow, disputes: DisputeRow[], statementRows: StatementSummaryRow[], allocationRows: AllocationRow[]) {
  const blockers: string[] = [];
  const warnings: string[] = [];
  const orderAllocations = nonReversedAllocations(allocationRows).filter((allocation) => allocationMatchesOrderOrDispute(allocation, order, disputes));
  const orderConfirmedAllocations = confirmedAllocations(orderAllocations);
  const hasSupplierAllocation = orderConfirmedAllocations.some((allocation) => text(allocation.allocation_type) === "supplier_invoice");
  const hasRefundNeeded = disputes.some((dispute) => text(dispute.desired_outcome) === "refund" && ["approved_refund", "awaiting_refund_credit"].includes(text(dispute.status)));
  const hasRefundAllocation = orderConfirmedAllocations.some((allocation) => text(allocation.allocation_type) === "retailer_refund");
  const hasHold = orderAllocations.some((allocation) => ["exception_hold", "unmatched_hold"].includes(text(allocation.allocation_type)));
  const importerRows = statementRows.filter((row) => row.importer_id === order.importer_id);
  const importerOpen = importerRows.reduce((sum, row) => sum + num(row.confirmed_unallocated_gbp), 0);

  if (!hasSupplierAllocation) blockers.push("No confirmed supplier OUT charge allocation found for this order/invoice");
  if (hasRefundNeeded && !hasRefundAllocation) blockers.push("Refund accepted/awaiting credit but no confirmed refund IN allocation found");
  if (hasHold) warnings.push("Order/dispute has an exception/unmatched hold allocation that needs supervisor review");
  if (importerRows.length === 0) warnings.push("No committed DVA/card statement lines found for this importer in summary view");
  if (importerOpen > 0) warnings.push(`Importer-level warning: ${gbp(importerOpen)} open/unallocated statement value across visible statement lines`);

  return { label: blockers.length === 0 ? "explained enough" : "blocked", ready: blockers.length === 0, blockers, warnings, allocationCount: orderAllocations.length };
}

function rowRefs(row: SageReadyRow) {
  return text(row.order_ref)
    .split(",")
    .map((value) => value.trim())
    .filter(Boolean);
}

function sageRowMatchesOrder(row: SageReadyRow, order: OrderRow) {
  const orderRef = text(order.order_ref);
  if (row.order_id && row.order_id === order.id) return true;
  if (!orderRef) return false;
  return rowRefs(row).includes(orderRef) || text(row.reference_text) === orderRef;
}

function sageLaneReadiness(rows: SageReadyRow[], lane: "customer_sales" | "shipper_ap", missingBlocker: string, href: string): LaneReadiness {
  const laneRows = rows.filter((row) => row.document_lane === lane);
  if (laneRows.length === 0) {
    return { label: "not in queue", ready: false, blockers: [missingBlocker], warnings: [], rowCount: 0, href };
  }

  const blockers: string[] = [];
  const warnings: string[] = [];
  let hasReadyRow = false;

  for (const row of laneRows) {
    const readiness = text(row.readiness_status);
    const sageStatus = text(row.sage_status);
    const hasSageConfirmation = sageStatus === "posted" && Boolean(row.sage_invoice_id || row.sage_posted_at);
    const isReady = readiness.startsWith("ready") || readiness === "sage_confirmation_recorded" || hasSageConfirmation;
    const isLegacyPostedOnly = readiness === "internally_marked_posted_no_sage_confirmation" || (sageStatus === "posted" && !row.sage_invoice_id && !row.sage_posted_at);

    if (isReady) hasReadyRow = true;
    if (readiness.startsWith("blocked")) blockers.push(`${pretty(row.document_type)} blocked: ${pretty(row.blocker || readiness)}`);
    if (isLegacyPostedOnly) blockers.push(`${pretty(row.document_type)} has internal posted flag only, with no Sage confirmation`);
    if (!isReady && !readiness.startsWith("blocked") && !isLegacyPostedOnly) warnings.push(`${pretty(row.document_type)} status: ${pretty(readiness || sageStatus)}`);
  }

  return {
    label: blockers.length > 0 ? "blocked" : hasReadyRow ? "ready" : "review",
    ready: hasReadyRow && blockers.length === 0,
    blockers,
    warnings,
    rowCount: laneRows.length,
    href,
  };
}

function deferredLaneReadiness(lane: LaneReadiness, upstreamReady: boolean): LaneReadiness {
  if (upstreamReady) return lane;

  if (lane.rowCount === 0) {
    return { ...lane, label: "not reached yet", blockers: [], warnings: [] };
  }

  return { ...lane, label: `${lane.label} downstream`, blockers: [], warnings: [] };
}

function statusTone(ready: boolean, warnings: string[]) {
  if (ready && warnings.length === 0) return "border-emerald-200 bg-emerald-50 text-emerald-800";
  if (ready) return "border-sky-200 bg-sky-50 text-sky-800";
  return "border-amber-200 bg-amber-50 text-amber-800";
}

function readinessPill(label: string, ready: boolean, warnings: string[]) {
  return <span className={`rounded-full border px-3 py-1 text-xs font-bold ${statusTone(ready, warnings)}`}>{label}</span>;
}

function uniqueFixActions(actions: FixAction[]) {
  const seen = new Set<string>();
  return actions.filter((action) => {
    const key = `${action.owner}|${action.label}|${action.href}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

export default async function PreSageFinancialReadinessPage({
  searchParams,
}: {
  searchParams?: SearchParamsValue | Promise<SearchParamsValue>;
}) {
  const params = searchParams ? await Promise.resolve(searchParams) : {};
  const importerId = firstParam(params.importer_id);
  const onlyBlocked = firstParam(params.only_blocked) === "true";
  const supabase = await createClient();

  const [importersResult, retailersResult] = await Promise.all([
    supabase.from("importers").select("id, company_name, trading_name").order("company_name", { ascending: true }).limit(200),
    supabase.from("retailers").select("id, name").limit(500),
  ]);

  const importers = (importersResult.data ?? []) as unknown as ImporterRow[];
  const selectedImporter = importers.find((importer) => importer.id === importerId);
  const retailersById = new Map(((retailersResult.data ?? []) as unknown as RetailerRow[]).map((retailer) => [retailer.id, retailer]));

  let orderQuery = supabase
    .from("orders")
    .select("id, order_ref, importer_id, retailer_id, status, order_type, parent_order_id, created_at")
    .order("created_at", { ascending: false })
    .limit(150);

  if (importerId) orderQuery = orderQuery.eq("importer_id", importerId);

  const { data: orderData, error: orderError } = await orderQuery;
  const orders = (orderData ?? []) as unknown as OrderRow[];
  const orderIds = new Set(orders.map((order) => order.id));

  const [invoiceResult, disputeResult, disputeLineResult, messageResult, allocationResult, statementResult, fundingResult, sageReadyResult] = await Promise.all([
    supabase.from("supplier_invoices").select("id, order_id, invoice_ref, review_status, blocked_from_sage_yn, ocr_invoice_total_gbp, reconciliation_gbp_total").limit(1000),
    supabase.from("disputes").select("id, order_id, desired_outcome, status, amount_impact_gbp, refund_approved_at, replacement_child_order_id, resolved_at, raised_at").limit(1000),
    supabase.from("dispute_lines").select("dispute_id, conversation_status, resolved_at").limit(2000),
    supabase.from("dispute_messages").select("dispute_id, message_type, counterparty").limit(2000),
    supabase.from("dva_statement_line_allocation_detail_vw").select("allocation_id, importer_id, supplier_invoice_id, supplier_invoice_ref, order_id, order_ref, dispute_id, allocation_type, allocation_status, allocated_gbp_amount, reversed_yn").limit(2000),
    supabase.from("dva_statement_line_allocation_summary_vw").select("importer_id, match_status, confirmed_balanced_yn, confirmed_unallocated_gbp, supplier_invoice_allocated_gbp, retailer_refund_allocated_gbp, fx_card_or_fee_allocated_gbp, exception_or_hold_allocated_gbp").limit(2000),
    supabase.from("order_funding_position_vw").select("*").limit(1000),
    (supabase as any).rpc("internal_ready_for_sage_queue_v2"),
  ]);

  const invoicesByOrderId = groupBy(((invoiceResult.data ?? []) as unknown as SupplierInvoiceRow[]).filter((invoice) => !invoice.order_id || orderIds.has(invoice.order_id)), (invoice) => invoice.order_id ?? "");
  const disputesByOrderId = groupBy(((disputeResult.data ?? []) as unknown as DisputeRow[]).filter((dispute) => !dispute.order_id || orderIds.has(dispute.order_id)), (dispute) => dispute.order_id ?? "");
  const linesByDisputeId = groupBy((disputeLineResult.data ?? []) as unknown as DisputeLineRow[], (line) => line.dispute_id ?? "");
  const messagesByDisputeId = groupBy((messageResult.data ?? []) as unknown as MessageRow[], (message) => message.dispute_id ?? "");
  const allocationRows = ((allocationResult.data ?? []) as unknown as AllocationRow[]).filter((allocation) => !importerId || allocation.importer_id === importerId);
  const statementRows = ((statementResult.data ?? []) as unknown as StatementSummaryRow[]).filter((row) => !importerId || row.importer_id === importerId);
  const sageReadyRows = ((sageReadyResult.data ?? []) as SageReadyRow[]).filter((row) => {
    if (!importerId) return true;
    return orders.some((order) => order.importer_id === importerId && sageRowMatchesOrder(row, order));
  });
  const fundingRows = (fundingResult.data ?? []) as Row[];
  const fundingByOrderId = new Map<string, Row>();
  for (const row of fundingRows) {
    const orderId = text(row.order_id) || text(row.id);
    if (orderId) fundingByOrderId.set(orderId, row);
  }

  const cards = orders.map((order) => {
    const invoices = invoicesByOrderId.get(order.id) ?? [];
    const disputes = disputesByOrderId.get(order.id) ?? [];
    const funding = amountFromFundingRow(fundingByOrderId.get(order.id));
    const activeSupplierAllocations = activeSupplierAllocationsForOrder(order, disputes, allocationRows);
    const invoice = invoiceReadiness(invoices, activeSupplierAllocations);
    const dva = dvaReadiness(order, disputes, statementRows, allocationRows);
    const exception = exceptionReadiness(disputes, linesByDisputeId, messagesByDisputeId, allocationRows);
    const upstreamBlockers = [
      ...(funding.gap > 0 ? [`Funding gap remains: ${gbp(funding.gap)}`] : []),
      ...invoice.blockers,
      ...dva.blockers,
      ...exception.blockers,
    ];
    const upstreamReady = upstreamBlockers.length === 0 && funding.gap <= 0 && invoice.ready && dva.ready && exception.ready;
    const orderSageRows = sageReadyRows.filter((row) => sageRowMatchesOrder(row, order));
    const rawCustomerSales = sageLaneReadiness(
      orderSageRows,
      "customer_sales",
      "Customer sales / AR row is not yet in the Ready for Sage queue",
      "/internal/shipping-control/customer-invoice-release",
    );
    const rawShipperAp = sageLaneReadiness(
      orderSageRows,
      "shipper_ap",
      "Shipper AP row is not yet in the Ready for Sage queue",
      "/internal/shipping-control",
    );
    const customerSales = deferredLaneReadiness(rawCustomerSales, upstreamReady);
    const shipperAp = deferredLaneReadiness(rawShipperAp, upstreamReady);
    const blockers = [
      ...upstreamBlockers,
      ...(upstreamReady ? rawCustomerSales.blockers : []),
      ...(upstreamReady ? rawShipperAp.blockers : []),
    ];
    const warnings = [
      ...invoice.warnings,
      ...dva.warnings,
      ...exception.warnings,
      ...(upstreamReady ? rawCustomerSales.warnings : []),
      ...(upstreamReady ? rawShipperAp.warnings : []),
    ];
    const ready = upstreamReady && rawCustomerSales.ready && rawShipperAp.ready;
    const fixActions = uniqueFixActions([
      ...(funding.gap > 0 ? [{ owner: "Supervisor", label: "Match/apply importer funding", href: "/internal/funding" }] : []),
      ...(invoice.blockers.length > 0 ? [{ owner: invoices.length === 0 ? "Operator" : "Supervisor", label: invoices.length === 0 ? "Upload supplier invoice" : "Resolve supplier invoice approval", href: invoices.length === 0 ? `/importer/orders/${order.id}/operations#invoice` : "/internal/invoice-review" }] : []),
      ...(dva.blockers.length > 0 ? [{ owner: "Supervisor", label: "Balance DVA/card allocation", href: "/internal/dva-reconciliation/workspace" }] : []),
      ...(exception.blockers.length > 0 ? [{ owner: "Supervisor", label: "Resolve exception outcome", href: "/internal/dva-reconciliation/exception-actions" }] : []),
      ...(upstreamReady && rawCustomerSales.blockers.length > 0 ? [{ owner: "Supervisor", label: "Release customer sales draft", href: rawCustomerSales.href }] : []),
      ...(upstreamReady && rawShipperAp.blockers.length > 0 ? [{ owner: "Supervisor", label: "Complete shipping AP readiness", href: rawShipperAp.href }] : []),
      ...(blockers.length === 0 && warnings.length > 0 ? [{ owner: "Supervisor", label: "Review warnings before Sage preview", href: "/internal/dva-reconciliation/review-pack" }] : []),
    ] as FixAction[]);

    return { order, retailer: order.retailer_id ? retailersById.get(order.retailer_id) : undefined, funding, invoice, dva, exception, customerSales, shipperAp, blockers, warnings, ready, fixActions };
  });

  const visibleCards = onlyBlocked ? cards.filter((card) => !card.ready || card.warnings.length > 0) : cards;
  const readyCount = cards.filter((card) => card.ready && card.warnings.length === 0).length;
  const warningReadyCount = cards.filter((card) => card.ready && card.warnings.length > 0).length;
  const blockedCount = cards.filter((card) => !card.ready).length;
  const customerSalesReadyCount = cards.filter((card) => card.customerSales.ready).length;
  const shipperApReadyCount = cards.filter((card) => card.shipperAp.ready).length;

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 lg:px-8">
      <div className="mx-auto max-w-7xl space-y-5">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <Link href="/internal/status-control" className="text-sm font-semibold text-sky-600">← Back to status control</Link>
          <p className="mt-5 text-xs font-bold uppercase tracking-[0.25em] text-sky-600">Pre-Sage financial readiness</p>
          <h1 className="mt-2 text-3xl font-bold tracking-tight sm:text-4xl">All roads to Sage readiness control pack</h1>
          <p className="mt-3 max-w-4xl text-sm leading-6 text-slate-600 sm:text-base">
            Read-only blocker view before Sage payload preview. It does not replace the DVA workspace, review pack, shipping control, customer invoice release or exception actions. It pulls their signals together to show funding, supplier AP, refund IN, DVA/card residuals, customer sales/AR, shipper AP, owner and fix link.
          </p>
          <div className="mt-4 flex flex-wrap gap-2">
            <Link href="/internal/dva-reconciliation/workspace" className="rounded-xl border border-slate-200 bg-white px-4 py-2 text-sm font-semibold text-slate-700">DVA workspace</Link>
            <Link href="/internal/dva-reconciliation/review-pack" className="rounded-xl border border-slate-200 bg-white px-4 py-2 text-sm font-semibold text-slate-700">DVA review pack</Link>
            <Link href="/internal/dva-reconciliation/exception-actions" className="rounded-xl border border-slate-200 bg-white px-4 py-2 text-sm font-semibold text-slate-700">Exception actions</Link>
            <Link href="/internal/shipping-control" className="rounded-xl border border-slate-200 bg-white px-4 py-2 text-sm font-semibold text-slate-700">Shipping control</Link>
            <Link href="/internal/sage-ready" className="rounded-xl border border-slate-200 bg-white px-4 py-2 text-sm font-semibold text-slate-700">Ready for Sage queue</Link>
          </div>
        </section>

        <section className="grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
          <div className="rounded-2xl border border-emerald-200 bg-emerald-50 p-4"><p className="text-xs font-bold uppercase tracking-wide text-emerald-700">Clean ready</p><p className="mt-2 text-2xl font-extrabold text-emerald-950">{readyCount}</p></div>
          <div className="rounded-2xl border border-sky-200 bg-sky-50 p-4"><p className="text-xs font-bold uppercase tracking-wide text-sky-700">Ready with warnings</p><p className="mt-2 text-2xl font-extrabold text-sky-950">{warningReadyCount}</p></div>
          <div className="rounded-2xl border border-amber-200 bg-amber-50 p-4"><p className="text-xs font-bold uppercase tracking-wide text-amber-700">Blocked</p><p className="mt-2 text-2xl font-extrabold text-amber-950">{blockedCount}</p></div>
          <div className="rounded-2xl border border-slate-200 bg-white p-4"><p className="text-xs font-bold uppercase tracking-wide text-slate-500">Customer sales ready</p><p className="mt-2 text-2xl font-extrabold text-slate-950">{customerSalesReadyCount}</p></div>
          <div className="rounded-2xl border border-slate-200 bg-white p-4"><p className="text-xs font-bold uppercase tracking-wide text-slate-500">Shipper AP ready</p><p className="mt-2 text-2xl font-extrabold text-slate-950">{shipperApReadyCount}</p></div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
          <form className="grid gap-3 md:grid-cols-[1fr_auto_auto] md:items-end" action="/internal/status-control/pre-sage-financial-readiness">
            <label className="grid gap-1 text-xs font-semibold text-slate-600">
              Importer
              <select name="importer_id" defaultValue={importerId} className="rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm text-slate-900">
                <option value="">All importers</option>
                {importers.map((importer) => <option key={importer.id} value={importer.id}>{importerLabel(importer)}</option>)}
              </select>
            </label>
            <label className="flex items-center gap-2 rounded-xl border border-slate-200 px-3 py-2 text-sm font-semibold text-slate-700">
              <input type="checkbox" name="only_blocked" value="true" defaultChecked={onlyBlocked} />
              Blocked/warnings only
            </label>
            <button className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white" type="submit">Apply</button>
          </form>
        </section>

        {orderError ? <section className="rounded-3xl border border-rose-200 bg-rose-50 p-5 text-sm font-semibold text-rose-800">Orders: {orderError.message}</section> : null}
        {invoiceResult.error ? <section className="rounded-3xl border border-rose-200 bg-rose-50 p-5 text-sm font-semibold text-rose-800">Supplier invoices: {invoiceResult.error.message}</section> : null}
        {allocationResult.error ? <section className="rounded-3xl border border-rose-200 bg-rose-50 p-5 text-sm font-semibold text-rose-800">DVA allocation detail: {allocationResult.error.message}</section> : null}
        {statementResult.error ? <section className="rounded-3xl border border-rose-200 bg-rose-50 p-5 text-sm font-semibold text-rose-800">DVA statement summary: {statementResult.error.message}</section> : null}
        {fundingResult.error ? <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm font-semibold text-amber-900">Funding position unavailable: {fundingResult.error.message}</section> : null}
        {sageReadyResult.error ? <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm font-semibold text-amber-900">Ready for Sage queue unavailable: {sageReadyResult.error.message}</section> : null}

        <section className="rounded-3xl border border-slate-200 bg-white shadow-sm">
          <div className="border-b border-slate-100 px-4 py-3 text-sm font-semibold text-slate-700">Showing {visibleCards.length} order readiness card(s) for {importerLabel(selectedImporter)}</div>
          {visibleCards.length === 0 ? (
            <div className="p-8 text-center text-sm text-slate-500">No orders match this filter.</div>
          ) : (
            <div className="divide-y divide-slate-100">
              {visibleCards.map((card) => (
                <article key={card.order.id} className="p-4">
                  <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm">
                    <div className="flex flex-wrap items-start justify-between gap-3">
                      <div>
                        <p className="text-lg font-bold text-slate-950">{card.order.order_ref || card.order.id}</p>
                        <p className="mt-1 text-sm text-slate-600">
                          {card.retailer?.name || "No retailer"} · Operational status {card.ready ? (card.warnings.length > 0 ? "ready with audit warning" : "ready for Sage preview") : "blocked before Sage preview"} · Raw DB status {pretty(card.order.status)} · Type {pretty(card.order.order_type)}
                        </p>
                      </div>
                      {readinessPill(card.ready ? "Ready for Sage preview" : "Blocked before Sage preview", card.ready, card.warnings)}
                    </div>

                    <div className="mt-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-6">
                      <div className="rounded-xl bg-slate-50 p-3 ring-1 ring-slate-200"><p className="text-[11px] font-bold uppercase tracking-wide text-slate-500">Funding</p><p className="mt-1 font-extrabold text-slate-950">{card.funding.label}</p><p className="mt-1 text-xs text-slate-500">Funded {gbp(card.funding.funded)} / Required {gbp(card.funding.required)} / Gap {gbp(card.funding.gap)}</p></div>
                      <div className="rounded-xl bg-slate-50 p-3 ring-1 ring-slate-200"><p className="text-[11px] font-bold uppercase tracking-wide text-slate-500">Supplier invoice</p><p className="mt-1 font-extrabold text-slate-950">{card.invoice.label}</p></div>
                      <div className="rounded-xl bg-slate-50 p-3 ring-1 ring-slate-200"><p className="text-[11px] font-bold uppercase tracking-wide text-slate-500">DVA/card</p><p className="mt-1 font-extrabold text-slate-950">{card.dva.label}</p><p className="mt-1 text-xs text-slate-500">Allocations: {card.dva.allocationCount}</p></div>
                      <div className="rounded-xl bg-slate-50 p-3 ring-1 ring-slate-200"><p className="text-[11px] font-bold uppercase tracking-wide text-slate-500">Exceptions</p><p className="mt-1 font-extrabold text-slate-950">{card.exception.label}</p></div>
                      <div className="rounded-xl bg-slate-50 p-3 ring-1 ring-slate-200"><p className="text-[11px] font-bold uppercase tracking-wide text-slate-500">Customer sales / AR</p><p className="mt-1 font-extrabold text-slate-950">{card.customerSales.label}</p><p className="mt-1 text-xs text-slate-500">Rows: {card.customerSales.rowCount}</p></div>
                      <div className="rounded-xl bg-slate-50 p-3 ring-1 ring-slate-200"><p className="text-[11px] font-bold uppercase tracking-wide text-slate-500">Shipper AP</p><p className="mt-1 font-extrabold text-slate-950">{card.shipperAp.label}</p><p className="mt-1 text-xs text-slate-500">Rows: {card.shipperAp.rowCount}</p></div>
                    </div>

                    {card.fixActions.length > 0 ? (
                      <div className="mt-4 rounded-xl border border-slate-200 bg-slate-50 p-3 text-sm text-slate-800">
                        <p className="font-bold">Next owner / fix link</p>
                        <div className="mt-2 flex flex-wrap gap-2">
                          {card.fixActions.map((action) => (
                            <Link key={`${action.owner}-${action.label}-${action.href}`} href={action.href} className="rounded-full border border-slate-200 bg-white px-3 py-1 text-xs font-semibold text-slate-700 hover:bg-slate-100">
                              {action.owner}: {action.label}
                            </Link>
                          ))}
                        </div>
                      </div>
                    ) : null}

                    {card.blockers.length > 0 ? (
                      <div className="mt-4 rounded-xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">
                        <p className="font-bold">Blockers</p>
                        <ul className="mt-2 list-disc space-y-1 pl-5">{card.blockers.map((blocker) => <li key={blocker}>{blocker}</li>)}</ul>
                      </div>
                    ) : null}

                    {card.warnings.length > 0 ? (
                      <div className="mt-4 rounded-xl border border-sky-200 bg-sky-50 p-3 text-sm text-sky-900">
                        <p className="font-bold">Warnings</p>
                        <ul className="mt-2 list-disc space-y-1 pl-5">{card.warnings.map((warning) => <li key={warning}>{warning}</li>)}</ul>
                      </div>
                    ) : null}
                  </div>
                </article>
              ))}
            </div>
          )}
        </section>
      </div>
    </main>
  );
}
