import { createClient } from "@/utils/supabase/server";

export type DeliveryAllocationOrder = {
  id: string;
  order_ref: string | null;
  importer_id: string;
  retailer_id: string | null;
  importer_name: string | null;
  retailer_name: string | null;
};

export type DeliveryAllocationLine = {
  id: string;
  supplier_invoice_id: string;
  line_order: number;
  description: string;
  qty: number;
  amount_inc_vat_gbp: number;
  eligible_for_invoice_yn: string;
};

export type DeliveryAllocationTracking = {
  id: string;
  tracking_ref: string;
  tracking_date: string | null;
  tracking_screenshot_url: string | null;
  note: string | null;
  is_final_delivery_yn: boolean | null;
  courier_name: string | null;
};

export type DeliveryAllocationRow = {
  id: string;
  supplier_invoice_line_id: string;
  tracking_submission_id: string | null;
  qty_allocated: number;
  base_value_gbp: number;
  discount_share_gbp: number;
  retailer_delivery_share_gbp: number;
  adjusted_net_value_gbp: number;
  allocation_status: string;
  allocation_basis: string;
  evidence_url: string | null;
  notes: string | null;
  supervisor_accepted_at: string | null;
  locked_for_export_pack_at: string | null;
};

export type DeliveryAllocationAdjustmentTotals = {
  retailerDeliveryGbp: number;
  retailerDiscountGbp: number;
  pendingCount: number;
};

export type DeliveryAllocationData = {
  order: DeliveryAllocationOrder;
  invoice: { id: string; invoice_ref: string | null; uploaded_at: string | null } | null;
  lines: DeliveryAllocationLine[];
  tracking: DeliveryAllocationTracking[];
  allocations: DeliveryAllocationRow[];
  adjustments: DeliveryAllocationAdjustmentTotals;
};

export function isProgressedFlag(value: string | null | undefined) {
  return ["y", "yes", "true", "1"].includes((value ?? "").trim().toLowerCase());
}

function firstRelated<T>(value: T | T[] | null | undefined): T | null {
  if (!value) return null;
  return Array.isArray(value) ? value[0] ?? null : value;
}

function money(value: unknown) {
  const n = Number(value ?? 0);
  return Number.isFinite(n) ? Math.round(n * 100) / 100 : 0;
}

export async function loadDeliveryAllocationData(
  supabase: Awaited<ReturnType<typeof createClient>>,
  orderId: string
): Promise<{ data: DeliveryAllocationData | null; error: string | null }> {
  const db = supabase as any;

  const { data: order, error: orderError } = await db
    .from("orders")
    .select("id, order_ref, importer_id, retailer_id, importers(company_name, trading_name), retailers(name)")
    .eq("id", orderId)
    .maybeSingle();

  if (orderError || !order) {
    return { data: null, error: orderError?.message ?? "Order not found." };
  }

  const importer = firstRelated(order.importers as { company_name?: string | null; trading_name?: string | null }[] | { company_name?: string | null; trading_name?: string | null } | null);
  const retailer = firstRelated(order.retailers as { name?: string | null }[] | { name?: string | null } | null);

  const { data: invoice, error: invoiceError } = await db
    .from("supplier_invoices")
    .select("id, invoice_ref, uploaded_at")
    .eq("order_id", orderId)
    .order("uploaded_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (invoiceError) {
    return { data: null, error: invoiceError.message };
  }

  const { data: lines, error: linesError } = invoice
    ? await db
        .from("supplier_invoice_lines")
        .select("id, supplier_invoice_id, line_order, description, qty, amount_inc_vat_gbp, eligible_for_invoice_yn")
        .eq("supplier_invoice_id", invoice.id)
        .order("line_order", { ascending: true })
    : { data: [], error: null };

  if (linesError) {
    return { data: null, error: linesError.message };
  }

  const { data: trackingRows, error: trackingError } = await db
    .from("order_tracking_submissions")
    .select("id, tracking_ref, tracking_date, tracking_screenshot_url, note, is_final_delivery_yn, couriers(name)")
    .eq("order_id", orderId)
    .is("superseded_at", null)
    .order("tracking_date", { ascending: true })
    .order("submitted_at", { ascending: true });

  if (trackingError) {
    return { data: null, error: trackingError.message };
  }

  const { data: allocationRows, error: allocationError } = await db
    .from("order_tracking_line_allocations")
    .select("id, supplier_invoice_line_id, tracking_submission_id, qty_allocated, base_value_gbp, discount_share_gbp, retailer_delivery_share_gbp, adjusted_net_value_gbp, allocation_status, allocation_basis, evidence_url, notes, supervisor_accepted_at, locked_for_export_pack_at")
    .eq("order_id", orderId)
    .order("created_at", { ascending: true });

  if (allocationError) {
    return { data: null, error: allocationError.message };
  }

  const { data: adjustmentRows, error: adjustmentError } = await db
    .from("order_value_adjustments")
    .select("adjustment_type, amount_gbp, approval_status")
    .eq("order_id", orderId);

  if (adjustmentError) {
    return { data: null, error: adjustmentError.message };
  }

  const approvedAdjustments = (adjustmentRows ?? []).filter((row: any) => ["approved", "auto_approved"].includes(String(row.approval_status ?? "")));
  const pendingAdjustments = (adjustmentRows ?? []).filter((row: any) => String(row.approval_status ?? "") === "pending_supervisor");

  const data: DeliveryAllocationData = {
    order: {
      id: order.id,
      order_ref: order.order_ref ?? null,
      importer_id: order.importer_id,
      retailer_id: order.retailer_id ?? null,
      importer_name: importer?.trading_name || importer?.company_name || null,
      retailer_name: retailer?.name ?? null,
    },
    invoice: invoice ? { id: invoice.id, invoice_ref: invoice.invoice_ref ?? null, uploaded_at: invoice.uploaded_at ?? null } : null,
    lines: ((lines ?? []) as any[]).map((line) => ({
      id: line.id,
      supplier_invoice_id: line.supplier_invoice_id,
      line_order: Number(line.line_order ?? 0),
      description: String(line.description ?? ""),
      qty: Number(line.qty ?? 0),
      amount_inc_vat_gbp: money(line.amount_inc_vat_gbp),
      eligible_for_invoice_yn: String(line.eligible_for_invoice_yn ?? "N"),
    })),
    tracking: ((trackingRows ?? []) as any[]).map((row) => {
      const courier = firstRelated(row.couriers as { name?: string | null }[] | { name?: string | null } | null);
      return {
        id: row.id,
        tracking_ref: String(row.tracking_ref ?? ""),
        tracking_date: row.tracking_date ?? null,
        tracking_screenshot_url: row.tracking_screenshot_url ?? null,
        note: row.note ?? null,
        is_final_delivery_yn: row.is_final_delivery_yn ?? null,
        courier_name: courier?.name ?? null,
      };
    }),
    allocations: ((allocationRows ?? []) as any[]).map((row) => ({
      id: row.id,
      supplier_invoice_line_id: row.supplier_invoice_line_id,
      tracking_submission_id: row.tracking_submission_id ?? null,
      qty_allocated: Number(row.qty_allocated ?? 0),
      base_value_gbp: money(row.base_value_gbp),
      discount_share_gbp: money(row.discount_share_gbp),
      retailer_delivery_share_gbp: money(row.retailer_delivery_share_gbp),
      adjusted_net_value_gbp: money(row.adjusted_net_value_gbp),
      allocation_status: String(row.allocation_status ?? "allocated"),
      allocation_basis: String(row.allocation_basis ?? "operator_declaration"),
      evidence_url: row.evidence_url ?? null,
      notes: row.notes ?? null,
      supervisor_accepted_at: row.supervisor_accepted_at ?? null,
      locked_for_export_pack_at: row.locked_for_export_pack_at ?? null,
    })),
    adjustments: {
      retailerDeliveryGbp: approvedAdjustments
        .filter((row: any) => row.adjustment_type === "retailer_delivery")
        .reduce((sum: number, row: any) => sum + money(row.amount_gbp), 0),
      retailerDiscountGbp: approvedAdjustments
        .filter((row: any) => row.adjustment_type === "retailer_discount")
        .reduce((sum: number, row: any) => sum + money(row.amount_gbp), 0),
      pendingCount: pendingAdjustments.length,
    },
  };

  return { data, error: null };
}
