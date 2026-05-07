import { NextResponse } from "next/server";
import { createClient } from "@/utils/supabase/server";

type Row = Record<string, unknown>;

function text(value: unknown) {
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  if (typeof value === "boolean") return value ? "true" : "false";
  return "";
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

function groupBy(rows: Row[], keyFn: (row: Row) => string) {
  const grouped = new Map<string, Row[]>();
  for (const row of rows) {
    const key = keyFn(row);
    if (!key) continue;
    grouped.set(key, [...(grouped.get(key) ?? []), row]);
  }
  return grouped;
}

const TERMINAL_EXCEPTION_STATUSES = new Set(["replaced", "awaiting_refund_credit", "refunded", "closed", "resolved"]);

function messageReferencesDispute(row: Row, disputeId: string) {
  return text(row.dispute_id) === disputeId || text(row.body).includes(`dispute_id: ${disputeId}`);
}

export async function GET(request: Request) {
  const supabase = await createClient();
  const { searchParams } = new URL(request.url);
  const importerId = searchParams.get("importer_id") || "";
  const onlyBlocked = searchParams.get("only_blocked") === "true";

  let orderQuery = supabase
    .from("orders")
    .select("id, order_ref, importer_id, retailer_id, status, order_type, parent_order_id, created_at")
    .order("created_at", { ascending: false })
    .limit(150);

  if (importerId) orderQuery = orderQuery.eq("importer_id", importerId);

  const { data: ordersData, error: ordersError } = await orderQuery;
  if (ordersError) return NextResponse.json({ error: ordersError.message }, { status: 500 });

  const orders = (ordersData ?? []) as Row[];
  const orderIds = new Set(orders.map((order) => text(order.id)));
  const orderRefs = new Set(orders.map((order) => text(order.order_ref)));

  const [fundingResult, invoiceResult, disputeResult, allocationResult, refundApprovalResult] = await Promise.all([
    supabase
      .from("order_funding_position_vw")
      .select("order_id, order_ref, importer_id, purchase_funding_threshold_gbp, confirmed_dva_funding_gbp, applied_credit_gbp, funded_total_gbp, gap_remaining_gbp, threshold_met_yn, already_funded_yn")
      .limit(1000),
    supabase
      .from("supplier_invoices")
      .select("id, order_id, invoice_ref, review_status, blocked_from_sage_yn, ocr_invoice_total_gbp, reconciliation_gbp_total")
      .limit(1000),
    supabase
      .from("disputes")
      .select("id, order_id, desired_outcome, status, amount_impact_gbp, replacement_child_order_id, resolved_at")
      .limit(1000),
    supabase
      .from("dva_statement_line_allocation_detail_vw")
      .select("importer_id, order_ref, dispute_id, allocation_type, allocation_status, allocated_gbp_amount")
      .limit(2000),
    supabase
      .from("dispute_messages")
      .select("id, dispute_id, message_type, body")
      .eq("message_type", "supplier_refund_current_approved")
      .limit(2000),
  ]);

  const firstError = fundingResult.error || invoiceResult.error || disputeResult.error || allocationResult.error || refundApprovalResult.error;
  if (firstError) return NextResponse.json({ error: firstError.message }, { status: 500 });

  const fundingRows = ((fundingResult.data ?? []) as Row[]).filter((row) => orderIds.has(text(row.order_id)));
  const invoicesByOrderId = groupBy(((invoiceResult.data ?? []) as Row[]).filter((row) => orderIds.has(text(row.order_id))), (row) => text(row.order_id));
  const disputesByOrderId = groupBy(((disputeResult.data ?? []) as Row[]).filter((row) => orderIds.has(text(row.order_id))), (row) => text(row.order_id));
  const allocations = ((allocationResult.data ?? []) as Row[]).filter((row) => orderRefs.has(text(row.order_ref)) || text(row.dispute_id));
  const refundApprovalRows = (refundApprovalResult.data ?? []) as Row[];
  const fundingByOrderId = new Map(fundingRows.map((row) => [text(row.order_id), row]));

  const cards = orders.map((order) => {
    const orderId = text(order.id);
    const orderRef = text(order.order_ref);
    const funding = fundingByOrderId.get(orderId);
    const invoices = invoicesByOrderId.get(orderId) ?? [];
    const disputes = disputesByOrderId.get(orderId) ?? [];
    const disputeIds = new Set(disputes.map((dispute) => text(dispute.id)));
    const orderAllocations = allocations.filter((allocation) => text(allocation.order_ref) === orderRef || disputeIds.has(text(allocation.dispute_id)));
    const activeAllocations = orderAllocations.filter((allocation) => !["reversed", "voided"].includes(text(allocation.allocation_status)));
    const confirmedAllocations = activeAllocations.filter((allocation) => text(allocation.allocation_status) === "confirmed");

    const supplierOut = confirmedAllocations
      .filter((allocation) => text(allocation.allocation_type) === "supplier_invoice")
      .reduce((sum, allocation) => sum + num(allocation.allocated_gbp_amount), 0);
    const retailerRefundIn = confirmedAllocations
      .filter((allocation) => text(allocation.allocation_type) === "retailer_refund")
      .reduce((sum, allocation) => sum + num(allocation.allocated_gbp_amount), 0);
    const fxCardFee = confirmedAllocations
      .filter((allocation) => ["fx_card_difference", "bank_fee"].includes(text(allocation.allocation_type)))
      .reduce((sum, allocation) => sum + num(allocation.allocated_gbp_amount), 0);
    const exceptionHold = activeAllocations
      .filter((allocation) => ["exception_hold", "unmatched_hold", "not_charged_closure"].includes(text(allocation.allocation_type)))
      .reduce((sum, allocation) => sum + num(allocation.allocated_gbp_amount), 0);

    const importerFundingIn = num(funding?.confirmed_dva_funding_gbp);
    const creditApplied = num(funding?.applied_credit_gbp);
    const fundedTotal = num(funding?.funded_total_gbp);
    const fundingRequired = num(funding?.purchase_funding_threshold_gbp);
    const fundingGap = num(funding?.gap_remaining_gbp);
    const fundingMet = bool(funding?.threshold_met_yn) || bool(funding?.already_funded_yn) || fundingGap <= 0;

    const unresolvedExceptionImpact = disputes
      .filter((dispute) => !TERMINAL_EXCEPTION_STATUSES.has(text(dispute.status)) && !text(dispute.resolved_at))
      .reduce((sum, dispute) => sum + num(dispute.amount_impact_gbp), 0);

    const acceptedRefundDisputes = disputes.filter((dispute) =>
      text(dispute.desired_outcome) === "refund" && ["approved_refund", "awaiting_refund_credit"].includes(text(dispute.status))
    );

    const refundAwaitingWithoutAllocation = acceptedRefundDisputes.some((dispute) =>
      !confirmedAllocations.some((allocation) => text(allocation.dispute_id) === text(dispute.id) && text(allocation.allocation_type) === "retailer_refund")
    );

    const refundAwaitingWithoutSupplierApproval = acceptedRefundDisputes.some((dispute) =>
      !refundApprovalRows.some((approval) => messageReferencesDispute(approval, text(dispute.id)))
    );

    const approvedCurrentInvoiceCount = invoices.filter((invoice) => text(invoice.review_status) === "approved_current").length;
    const blockedInvoiceCount = invoices.filter((invoice) => bool(invoice.blocked_from_sage_yn) || ["needs_action", "pending_review", "duplicate_blocked", "rejected_resubmit_required"].includes(text(invoice.review_status))).length;
    const supplierInvoiceTotal = invoices.reduce((sum, invoice) => sum + Math.max(num(invoice.reconciliation_gbp_total), num(invoice.ocr_invoice_total_gbp)), 0);
    const supplierAllocationGap = Math.max(0, supplierInvoiceTotal - supplierOut);
    const controlledNet = fundedTotal - supplierOut - fxCardFee + retailerRefundIn;

    const blockers: string[] = [];
    if (!fundingMet) blockers.push("funding gap remains");
    if (approvedCurrentInvoiceCount === 0) blockers.push("no approved-current supplier invoice");
    if (supplierAllocationGap > 0) blockers.push("supplier OUT allocation below invoice total");
    if (refundAwaitingWithoutSupplierApproval) blockers.push("refund accepted but supplier refund/credit evidence not approved current");
    if (refundAwaitingWithoutAllocation) blockers.push("refund accepted but no refund IN allocation");
    if (unresolvedExceptionImpact > 0) blockers.push("unresolved exception impact remains");
    if (blockedInvoiceCount > 0) blockers.push("supplier invoice review blocker exists");

    const warnings: string[] = [];
    if (controlledNet > 0 && unresolvedExceptionImpact === 0) warnings.push("net surplus/credit position exists; confirm credit treatment before posting");
    if (exceptionHold > 0) warnings.push("exception/hold allocation exists; supervisor review needed");

    return {
      order_id: orderId,
      order_ref: orderRef || orderId.slice(0, 8),
      importer_id: text(order.importer_id),
      status: text(order.status),
      order_type: text(order.order_type),
      importer_funding_in_gbp: importerFundingIn,
      credit_applied_gbp: creditApplied,
      funded_total_gbp: fundedTotal,
      funding_required_gbp: fundingRequired,
      funding_gap_gbp: fundingGap,
      supplier_out_gbp: supplierOut,
      supplier_invoice_total_gbp: supplierInvoiceTotal,
      supplier_allocation_gap_gbp: supplierAllocationGap,
      retailer_refund_in_gbp: retailerRefundIn,
      fx_card_fee_gbp: fxCardFee,
      exception_hold_gbp: exceptionHold,
      unresolved_exception_impact_gbp: unresolvedExceptionImpact,
      controlled_net_gbp: controlledNet,
      allocation_count: activeAllocations.length,
      invoice_count: invoices.length,
      approved_current_invoice_count: approvedCurrentInvoiceCount,
      refund_supplier_approval_missing_yn: refundAwaitingWithoutSupplierApproval,
      refund_in_allocation_missing_yn: refundAwaitingWithoutAllocation,
      blocker_count: blockers.length,
      blockers,
      warnings,
      ready_for_sage_preview: blockers.length === 0,
    };
  });

  const visibleCards = onlyBlocked ? cards.filter((card) => !card.ready_for_sage_preview) : cards;
  const totals = visibleCards.reduce(
    (sum, card) => ({
      importer_funding_in_gbp: sum.importer_funding_in_gbp + card.importer_funding_in_gbp,
      credit_applied_gbp: sum.credit_applied_gbp + card.credit_applied_gbp,
      supplier_out_gbp: sum.supplier_out_gbp + card.supplier_out_gbp,
      retailer_refund_in_gbp: sum.retailer_refund_in_gbp + card.retailer_refund_in_gbp,
      controlled_net_gbp: sum.controlled_net_gbp + card.controlled_net_gbp,
      unresolved_exception_impact_gbp: sum.unresolved_exception_impact_gbp + card.unresolved_exception_impact_gbp,
    }),
    { importer_funding_in_gbp: 0, credit_applied_gbp: 0, supplier_out_gbp: 0, retailer_refund_in_gbp: 0, controlled_net_gbp: 0, unresolved_exception_impact_gbp: 0 },
  );

  return NextResponse.json({ cards: visibleCards, totals });
}
