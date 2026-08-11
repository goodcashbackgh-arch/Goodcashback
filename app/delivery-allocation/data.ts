import { createClient } from "@/utils/supabase/server";

export type DeliveryAllocationOrder = {
  id: string;
  order_ref: string | null;
  importer_id: string;
  retailer_id: string | null;
  importer_name: string | null;
  retailer_name: string | null;
};

export type DeliveryAllocationInvoice = {
  id: string;
  invoice_ref: string | null;
  uploaded_at: string | null;
  review_status: string | null;
};

export type DeliveryAllocationLine = {
  id: string;
  supplier_invoice_id: string;
  supplier_invoice_ref: string | null;
  line_order: number;
  description: string;
  qty: number;
  qty_confirmed: number | null;
  amount_inc_vat_gbp: number;
  amount_confirmed: number | null;
  eligible_for_invoice_yn: string;
};

export type DeliveryAllocationTracking = {
  id: string;
  tracking_ref: string;
  tracking_date: string | null;
  courier_tracking_url: string | null;
  tracking_evidence_url: string | null;
  tracking_screenshot_url: string | null;
  note: string | null;
  is_final_delivery_yn: boolean | null;
  courier_name: string | null;
  accepts_new_allocations: boolean;
  allocation_blocker: string | null;
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
  counts_toward_ordinary_remaining: boolean;
  can_simple_clear: boolean;
  clear_blocker: string | null;
};

export type DeliveryAllocationAdjustmentTotals = {
  retailerDeliveryGbp: number;
  retailerDiscountGbp: number;
  pendingCount: number;
};

export type DeliveryAllocationData = {
  order: DeliveryAllocationOrder;
  invoice: DeliveryAllocationInvoice | null;
  invoices: DeliveryAllocationInvoice[];
  lines: DeliveryAllocationLine[];
  tracking: DeliveryAllocationTracking[];
  allocations: DeliveryAllocationRow[];
  adjustments: DeliveryAllocationAdjustmentTotals;
};

const retiredInvoiceStatuses = new Set(["rejected_resubmit_required", "duplicate_blocked", "superseded"]);

export function isProgressedFlag(value: string | null | undefined) {
  return ["y", "yes", "true", "1"].includes((value ?? "").trim().toLowerCase());
}

export function effectiveLineQty(line: Pick<DeliveryAllocationLine, "qty" | "qty_confirmed">) {
  return Number(line.qty_confirmed ?? line.qty ?? 0);
}

export function effectiveLineAmount(line: Pick<DeliveryAllocationLine, "amount_inc_vat_gbp" | "amount_confirmed">) {
  return money(line.amount_confirmed ?? line.amount_inc_vat_gbp);
}

function firstRelated<T>(value: T | T[] | null | undefined): T | null {
  if (!value) return null;
  return Array.isArray(value) ? value[0] ?? null : value;
}

function money(value: unknown) {
  const n = Number(value ?? 0);
  return Number.isFinite(n) ? Math.round(n * 100) / 100 : 0;
}

type ControlTrackingRow = {
  tracking_submission_id?: string;
  accepts_new_allocations?: boolean;
  blocker?: string | null;
};

type ControlAllocationRow = {
  allocation_id?: string;
  counts_toward_ordinary_remaining?: boolean;
  can_simple_clear?: boolean;
  blocker?: string | null;
};

export async function loadDeliveryAllocationData(
  supabase: Awaited<ReturnType<typeof createClient>>,
  orderId: string,
  mode: "operator" | "staff" = "operator"
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

  const { data: invoiceRows, error: invoiceError } = await db
    .from("supplier_invoices")
    .select("id, invoice_ref, uploaded_at, review_status")
    .eq("order_id", orderId)
    .order("uploaded_at", { ascending: true });

  if (invoiceError) {
    return { data: null, error: invoiceError.message };
  }

  const invoices: DeliveryAllocationInvoice[] = ((invoiceRows ?? []) as any[])
    .filter((row) => !retiredInvoiceStatuses.has(String(row.review_status ?? "pending_review")))
    .map((row) => ({
      id: String(row.id),
      invoice_ref: row.invoice_ref ?? null,
      uploaded_at: row.uploaded_at ?? null,
      review_status: row.review_status ?? null,
    }));
  const invoiceIds = invoices.map((invoice) => invoice.id);
  const invoiceRefById = new Map(invoices.map((invoice) => [invoice.id, invoice.invoice_ref]));

  const { data: lines, error: linesError } = invoiceIds.length > 0
    ? await db
        .from("supplier_invoice_lines")
        .select("id, supplier_invoice_id, line_order, description, qty, qty_confirmed, amount_inc_vat_gbp, amount_confirmed, eligible_for_invoice_yn")
        .in("supplier_invoice_id", invoiceIds)
        .order("supplier_invoice_id", { ascending: true })
        .order("line_order", { ascending: true })
    : { data: [], error: null };

  if (linesError) {
    return { data: null, error: linesError.message };
  }

  const { data: trackingRows, error: trackingError } = await db
    .from("order_tracking_submissions")
    .select("id, tracking_ref, tracking_date, courier_tracking_url, tracking_evidence_url, tracking_screenshot_url, note, is_final_delivery_yn, couriers(name)")
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

  const { data: controlState, error: controlError } = await db.rpc("delivery_allocation_control_state_v1", {
    p_order_id: orderId,
    p_actor_mode: mode,
  });

  if (controlError) {
    return { data: null, error: controlError.message };
  }

  const trackingControlRows = Array.isArray(controlState?.tracking_packages)
    ? (controlState.tracking_packages as ControlTrackingRow[])
    : [];
  const allocationControlRows = Array.isArray(controlState?.allocations)
    ? (controlState.allocations as ControlAllocationRow[])
    : [];
  const trackingControlById = new Map(
    trackingControlRows.map((row) => [String(row.tracking_submission_id ?? ""), row])
  );
  const allocationControlById = new Map(
    allocationControlRows.map((row) => [String(row.allocation_id ?? ""), row])
  );

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
    invoice: invoices[0] ?? null,
    invoices,
    lines: ((lines ?? []) as any[]).map((line) => ({
      id: line.id,
      supplier_invoice_id: line.supplier_invoice_id,
      supplier_invoice_ref: invoiceRefById.get(String(line.supplier_invoice_id)) ?? null,
      line_order: Number(line.line_order ?? 0),
      description: String(line.description ?? ""),
      qty: Number(line.qty ?? 0),
      qty_confirmed: line.qty_confirmed == null ? null : Number(line.qty_confirmed),
      amount_inc_vat_gbp: money(line.amount_inc_vat_gbp),
      amount_confirmed: line.amount_confirmed == null ? null : money(line.amount_confirmed),
      eligible_for_invoice_yn: String(line.eligible_for_invoice_yn ?? "N"),
    })),
    tracking: ((trackingRows ?? []) as any[]).map((row) => {
      const courier = firstRelated(row.couriers as { name?: string | null }[] | { name?: string | null } | null);
      const control = trackingControlById.get(String(row.id));
      return {
        id: row.id,
        tracking_ref: String(row.tracking_ref ?? ""),
        tracking_date: row.tracking_date ?? null,
        courier_tracking_url: row.courier_tracking_url ?? null,
        tracking_evidence_url: row.tracking_evidence_url ?? null,
        tracking_screenshot_url: row.tracking_screenshot_url ?? null,
        note: row.note ?? null,
        is_final_delivery_yn: row.is_final_delivery_yn ?? null,
        courier_name: courier?.name ?? null,
        accepts_new_allocations: control?.accepts_new_allocations !== false,
        allocation_blocker: control?.blocker ?? null,
      };
    }),
    allocations: ((allocationRows ?? []) as any[]).map((row) => {
      const control = allocationControlById.get(String(row.id));
      return {
        id: row.id,
        supplier_invoice_line_id: row.supplier_invoice_line_id,
        tracking_submission_id: row.tracking_submission_id ?? null,
        qty_allocated: Number(row.qty_allocated ?? 0),
        base_value_gbp: money(row.base_value_gbp),
        discount_share_gbp: money(row.discount_share_gbp),
        retailer_delivery_share_gbp: money(row.retailer_delivery_share_gbp),
        adjusted_net_value_gbp: money(row.adjusted_net_value_gbp),
        allocation_status: String(row.allocation_status ?? "unknown_contents"),
        allocation_basis: String(row.allocation_basis ?? "operator_declared"),
        evidence_url: row.evidence_url ?? null,
        notes: row.notes ?? null,
        supervisor_accepted_at: row.supervisor_accepted_at ?? null,
        locked_for_export_pack_at: row.locked_for_export_pack_at ?? null,
        counts_toward_ordinary_remaining: control?.counts_toward_ordinary_remaining !== false,
        can_simple_clear: control?.can_simple_clear === true,
        clear_blocker: control?.blocker ?? null,
      };
    }),
    adjustments: {
      retailerDeliveryGbp: approvedAdjustments.filter((row: any) => row.adjustment_type === "retailer_delivery").reduce((sum: number, row: any) => sum + money(row.amount_gbp), 0),
      retailerDiscountGbp: approvedAdjustments.filter((row: any) => row.adjustment_type === "retailer_discount").reduce((sum: number, row: any) => sum + money(row.amount_gbp), 0),
      pendingCount: pendingAdjustments.length,
    },
  };

  return { data, error: null };
}
