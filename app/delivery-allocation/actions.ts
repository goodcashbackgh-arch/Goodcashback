"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

function readNumber(formData: FormData, key: string) {
  const raw = readString(formData, key);
  if (!raw) return null;
  const parsed = Number(raw);
  return Number.isFinite(parsed) ? parsed : null;
}

function redirectBack(mode: "operator" | "staff", orderId: string, params: Record<string, string>): never {
  const query = new URLSearchParams(params);
  const base = mode === "staff" ? `/internal/delivery-allocation/${orderId}` : `/importer/delivery-allocation/${orderId}`;
  redirect(`${base}?${query.toString()}`);
}

function isProgressedFlag(value: string | null | undefined) {
  return ["y", "yes", "true", "1"].includes((value ?? "").trim().toLowerCase());
}

function money(value: unknown) {
  const n = Number(value ?? 0);
  return Number.isFinite(n) ? Math.round(n * 100) / 100 : 0;
}

async function refreshInvoiceAdjustmentLedger(params: {
  supabase: Awaited<ReturnType<typeof createClient>>;
  supplierInvoiceId: string | null | undefined;
  mode: "operator" | "staff";
  orderId: string;
}) {
  if (!params.supplierInvoiceId) return { ok: true as const };
  const { error } = await (params.supabase as any).rpc("recalculate_invoice_adjustment_consumption_v1", {
    p_supplier_invoice_id: params.supplierInvoiceId,
  });
  if (error) return { ok: false as const, error: error.message };
  return { ok: true as const };
}

async function getOperatorActor(supabase: Awaited<ReturnType<typeof createClient>>, orderId: string) {
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { ok: false as const, error: "Please sign in again." };

  const { data: operator, error: operatorError } = await supabase
    .from("operators")
    .select("id")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (operatorError || !operator) return { ok: false as const, error: "Active operator account not found." };

  const { data: order, error: orderError } = await supabase
    .from("orders")
    .select("id, importer_id")
    .eq("id", orderId)
    .maybeSingle();

  if (orderError || !order) return { ok: false as const, error: "Order not found." };

  const { data: access, error: accessError } = await supabase
    .from("operator_importers")
    .select("id")
    .eq("operator_id", operator.id)
    .eq("importer_id", order.importer_id)
    .is("revoked_at", null)
    .limit(1)
    .maybeSingle();

  if (accessError || !access) return { ok: false as const, error: "You are not authorised for this order." };
  return { ok: true as const, actorId: operator.id };
}

async function getStaffActor(supabase: Awaited<ReturnType<typeof createClient>>) {
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { ok: false as const, error: "Please sign in again." };

  const { data: staff, error } = await supabase
    .from("staff")
    .select("id, role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (error || !staff) return { ok: false as const, error: "Active staff account not found." };
  if (!["admin", "supervisor"].includes(String(staff.role_type))) {
    return { ok: false as const, error: "Only supervisor/admin staff can use the internal allocation workspace." };
  }

  return { ok: true as const, actorId: staff.id };
}

async function requireActor(params: {
  supabase: Awaited<ReturnType<typeof createClient>>;
  mode: "operator" | "staff";
  orderId: string;
}) {
  return params.mode === "staff"
    ? getStaffActor(params.supabase)
    : getOperatorActor(params.supabase, params.orderId);
}

async function calculateAllocationValues(params: {
  supabase: Awaited<ReturnType<typeof createClient>>;
  orderId: string;
  lineId: string;
  qtyAllocated: number;
}) {
  const db = params.supabase as any;
  const { data: line, error: lineError } = await db
    .from("supplier_invoice_lines")
    .select("id, supplier_invoice_id, qty, amount_inc_vat_gbp, qty_confirmed, amount_confirmed, eligible_for_invoice_yn, supplier_invoices!inner(order_id)")
    .eq("id", params.lineId)
    .eq("supplier_invoices.order_id", params.orderId)
    .maybeSingle();

  if (lineError || !line) return { ok: false as const, error: lineError?.message ?? "Invoice line not found for this order." };
  if (!isProgressedFlag(line.eligible_for_invoice_yn)) return { ok: false as const, error: "Only progressed lines can be allocated to tracking refs." };

  const lineQty = Number(line.qty_confirmed ?? line.qty ?? 0);
  const lineAmount = money(line.amount_confirmed ?? line.amount_inc_vat_gbp);
  if (lineQty <= 0 || lineAmount < 0) return { ok: false as const, error: "Line quantity/value is not valid for allocation." };
  if (params.qtyAllocated <= 0 || params.qtyAllocated > lineQty) return { ok: false as const, error: "Allocated quantity must be greater than zero and no more than the line quantity." };

  const { data: existingAllocations, error: existingError } = await db
    .from("order_tracking_line_allocations")
    .select("qty_allocated")
    .eq("supplier_invoice_line_id", params.lineId);

  if (existingError) return { ok: false as const, error: existingError.message };
  const alreadyAllocatedQty = (existingAllocations ?? []).reduce((sum: number, row: any) => sum + Number(row.qty_allocated ?? 0), 0);
  if (alreadyAllocatedQty + params.qtyAllocated > lineQty + 0.0001) {
    return { ok: false as const, error: "Allocation would exceed the progressed line quantity. Clear unlocked allocations or review locked export allocations first." };
  }

  const baseValue = money((lineAmount / lineQty) * params.qtyAllocated);

  return {
    ok: true as const,
    supplierInvoiceId: line.supplier_invoice_id as string,
    baseValue,
    discountShare: 0,
    deliveryShare: 0,
    adjustedNet: baseValue,
  };
}

function deriveAllocationStatus(params: { mode: "operator" | "staff"; contentState: string }) {
  if (params.contentState === "unknown_contents") return "unknown_contents";
  if (params.contentState === "needs_operator_evidence") return "needs_operator_evidence";
  if (params.mode === "staff" && params.contentState === "supervisor_accepted_estimate") {
    return "supervisor_accepted_estimate";
  }
  return "allocated";
}

export async function saveDeliveryAllocationAction(formData: FormData) {
  const supabase = await createClient();
  const mode = readString(formData, "mode") === "staff" ? "staff" : "operator";
  const orderId = readString(formData, "order_id");
  const lineId = readString(formData, "supplier_invoice_line_id");
  const trackingSubmissionIdRaw = readString(formData, "tracking_submission_id");
  const qtyAllocated = readNumber(formData, "qty_allocated");
  const allocationBasis = readString(formData, "allocation_basis") || "operator_declaration";
  const evidenceUrl = readString(formData, "evidence_url") || null;
  const notes = readString(formData, "notes") || null;
  const contentState = readString(formData, "content_state") || "confirmed";
  const allocationStatus = deriveAllocationStatus({ mode, contentState });

  if (!orderId || !lineId) redirect("/importer");
  if (qtyAllocated === null || qtyAllocated <= 0) redirectBack(mode, orderId, { error: "Allocated quantity must be greater than zero." });

  const trackingSubmissionId = trackingSubmissionIdRaw || null;
  if (!["unknown_contents", "needs_operator_evidence"].includes(allocationStatus) && !trackingSubmissionId) {
    redirectBack(mode, orderId, { error: "Select a tracking ref/package, or mark the contents as unknown/needs evidence." });
  }

  const actor = await requireActor({ supabase, mode, orderId });
  if (!actor.ok) redirectBack(mode, orderId, { error: actor.error });

  if (trackingSubmissionId) {
    const { data: tracking, error: trackingError } = await (supabase as any)
      .from("order_tracking_submissions")
      .select("id")
      .eq("id", trackingSubmissionId)
      .eq("order_id", orderId)
      .maybeSingle();
    if (trackingError || !tracking) redirectBack(mode, orderId, { error: trackingError?.message ?? "Tracking ref not found for this order." });
  }

  const values = await calculateAllocationValues({ supabase, orderId, lineId, qtyAllocated });
  if (!values.ok) redirectBack(mode, orderId, { error: values.error });

  const insertPayload: Record<string, unknown> = {
    order_id: orderId,
    supplier_invoice_line_id: lineId,
    tracking_submission_id: trackingSubmissionId,
    qty_allocated: qtyAllocated,
    base_value_gbp: values.baseValue,
    discount_share_gbp: values.discountShare,
    retailer_delivery_share_gbp: values.deliveryShare,
    adjusted_net_value_gbp: values.adjustedNet,
    allocation_status: allocationStatus,
    allocation_basis: allocationBasis,
    evidence_url: evidenceUrl,
    notes,
  };

  if (mode === "staff") {
    insertPayload.allocated_by_staff_id = actor.actorId;
    if (allocationStatus === "supervisor_accepted_estimate") {
      insertPayload.supervisor_accepted_by_staff_id = actor.actorId;
      insertPayload.supervisor_accepted_at = new Date().toISOString();
    }
  } else {
    insertPayload.allocated_by_operator_id = actor.actorId;
  }

  const { error } = await (supabase as any).from("order_tracking_line_allocations").insert(insertPayload);
  if (error) redirectBack(mode, orderId, { error: error.message });

  const refresh = await refreshInvoiceAdjustmentLedger({
    supabase,
    supplierInvoiceId: values.supplierInvoiceId,
    mode,
    orderId,
  });
  if (!refresh.ok) redirectBack(mode, orderId, { error: refresh.error });

  revalidatePath(`/importer/delivery-allocation/${orderId}`);
  revalidatePath(`/internal/delivery-allocation/${orderId}`);
  revalidatePath(`/importer/reconciliation/${orderId}`);
  revalidatePath(`/internal/reconciliation/${orderId}`);
  redirectBack(mode, orderId, { success: "Package allocation saved. Invoice adjustment ledger refreshed from locked basis." });
}

export async function clearDeliveryAllocationForLineAction(formData: FormData) {
  const supabase = await createClient();
  const mode = readString(formData, "mode") === "staff" ? "staff" : "operator";
  const orderId = readString(formData, "order_id");
  const lineId = readString(formData, "supplier_invoice_line_id");

  if (!orderId || !lineId) redirect("/importer");

  const actor = await requireActor({ supabase, mode, orderId });
  if (!actor.ok) redirectBack(mode, orderId, { error: actor.error });

  const { data: lineBeforeClear, error: lineBeforeClearError } = await (supabase as any)
    .from("supplier_invoice_lines")
    .select("supplier_invoice_id")
    .eq("id", lineId)
    .maybeSingle();

  if (lineBeforeClearError) redirectBack(mode, orderId, { error: lineBeforeClearError.message });

  const { error } = await (supabase as any)
    .from("order_tracking_line_allocations")
    .delete()
    .eq("order_id", orderId)
    .eq("supplier_invoice_line_id", lineId)
    .is("locked_for_export_pack_at", null);

  if (error) redirectBack(mode, orderId, { error: error.message });

  const refresh = await refreshInvoiceAdjustmentLedger({
    supabase,
    supplierInvoiceId: lineBeforeClear?.supplier_invoice_id,
    mode,
    orderId,
  });
  if (!refresh.ok) redirectBack(mode, orderId, { error: refresh.error });

  revalidatePath(`/importer/delivery-allocation/${orderId}`);
  revalidatePath(`/internal/delivery-allocation/${orderId}`);
  redirectBack(mode, orderId, { success: "Unlocked package allocations cleared and invoice adjustment ledger refreshed." });
}
