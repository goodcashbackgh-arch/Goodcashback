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

function revalidateDeliveryAllocation(orderId: string) {
  revalidatePath(`/importer/delivery-allocation/${orderId}`);
  revalidatePath(`/internal/delivery-allocation/${orderId}`);
  revalidatePath(`/importer/reconciliation/${orderId}`);
  revalidatePath(`/internal/reconciliation/${orderId}`);
}

function rpcErrorMessage(error: { message?: string } | null | undefined, fallback: string) {
  return error?.message?.trim() || fallback;
}

export async function saveDeliveryAllocationAction(formData: FormData) {
  const supabase = await createClient();
  const mode = readString(formData, "mode") === "staff" ? "staff" : "operator";
  const orderId = readString(formData, "order_id");
  const lineId = readString(formData, "supplier_invoice_line_id");
  const trackingSubmissionId = readString(formData, "tracking_submission_id") || null;
  const qtyAllocated = readNumber(formData, "qty_allocated");
  const allocationBasis = readString(formData, "allocation_basis") || "operator_declaration";
  const evidenceUrl = readString(formData, "evidence_url") || null;
  const notes = readString(formData, "notes") || null;
  const contentState = readString(formData, "content_state") || "confirmed";

  if (!orderId || !lineId) redirect("/importer");
  if (qtyAllocated === null || qtyAllocated <= 0) {
    redirectBack(mode, orderId, { error: "Allocated quantity must be greater than zero." });
  }

  const { data, error } = await (supabase as any).rpc("delivery_allocate_tracking_lines_v1", {
    p_order_id: orderId,
    p_actor_mode: mode,
    p_request_kind: "single",
    p_tracking_submission_id: trackingSubmissionId,
    p_items: [{ supplier_invoice_line_id: lineId, quantity_mode: "exact", qty: qtyAllocated }],
    p_content_state: contentState,
    p_allocation_basis: allocationBasis,
    p_evidence_url: evidenceUrl,
    p_notes: notes,
    p_confirm_same_package: false,
  });

  if (error) {
    redirectBack(mode, orderId, { error: rpcErrorMessage(error, "Package allocation could not be saved.") });
  }

  const qty = Number(data?.total_qty_allocated ?? qtyAllocated);
  revalidateDeliveryAllocation(orderId);
  redirectBack(mode, orderId, {
    success: `${qty} unit${Math.abs(qty - 1) < 0.0001 ? "" : "s"} allocated. Invoice adjustment ledger refreshed atomically from locked basis.`,
  });
}

export async function saveBulkDeliveryAllocationAction(formData: FormData) {
  const supabase = await createClient();
  const mode = readString(formData, "mode") === "staff" ? "staff" : "operator";
  const orderId = readString(formData, "order_id");
  const trackingSubmissionId = readString(formData, "tracking_submission_id");
  const confirmed = readString(formData, "confirm_same_package") === "yes";
  const lineIds = formData
    .getAll("line_ids")
    .filter((value): value is string => typeof value === "string")
    .map((value) => value.trim())
    .filter(Boolean);

  if (!orderId) redirect("/importer");
  if (lineIds.length === 0) redirectBack(mode, orderId, { error: "Select at least one item." });
  if (!trackingSubmissionId) redirectBack(mode, orderId, { error: "Select a tracking ref/package." });
  if (!confirmed) {
    redirectBack(mode, orderId, { error: "Confirm that the selected items are in this tracking package." });
  }

  const { data, error } = await (supabase as any).rpc("delivery_allocate_tracking_lines_v1", {
    p_order_id: orderId,
    p_actor_mode: mode,
    p_request_kind: "bulk",
    p_tracking_submission_id: trackingSubmissionId,
    p_items: lineIds.map((lineId) => ({ supplier_invoice_line_id: lineId, quantity_mode: "remaining" })),
    p_content_state: "confirmed",
    p_allocation_basis: mode === "staff" ? "supervisor_estimate" : "operator_declaration",
    p_evidence_url: null,
    p_notes: null,
    p_confirm_same_package: true,
  });

  if (error) {
    redirectBack(mode, orderId, { error: rpcErrorMessage(error, "Bulk package allocation could not be saved.") });
  }

  const allocationCount = Number(data?.allocation_count ?? lineIds.length);
  const totalQty = Number(data?.total_qty_allocated ?? 0);
  revalidateDeliveryAllocation(orderId);
  redirectBack(mode, orderId, {
    success: `${totalQty} unit${Math.abs(totalQty - 1) < 0.0001 ? "" : "s"} across ${allocationCount} item${allocationCount === 1 ? "" : "s"} allocated to the selected tracking package.`,
  });
}

// Existing ordinary clear/rework path intentionally preserved by the bulk patch.
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
  const { data: operator, error: operatorError } = await supabase.from("operators").select("id").eq("auth_user_id", user.id).eq("active", true).maybeSingle();
  if (operatorError || !operator) return { ok: false as const, error: "Active operator account not found." };
  const { data: order, error: orderError } = await supabase.from("orders").select("id, importer_id").eq("id", orderId).maybeSingle();
  if (orderError || !order) return { ok: false as const, error: "Order not found." };
  const { data: access, error: accessError } = await supabase.from("operator_importers").select("id").eq("operator_id", operator.id).eq("importer_id", order.importer_id).is("revoked_at", null).limit(1).maybeSingle();
  if (accessError || !access) return { ok: false as const, error: "You are not authorised for this order." };
  return { ok: true as const };
}

async function getStaffActor(supabase: Awaited<ReturnType<typeof createClient>>) {
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { ok: false as const, error: "Please sign in again." };
  const { data: staff, error } = await supabase.from("staff").select("id, role_type").eq("auth_user_id", user.id).eq("active", true).maybeSingle();
  if (error || !staff) return { ok: false as const, error: "Active staff account not found." };
  if (!["admin", "supervisor"].includes(String(staff.role_type))) return { ok: false as const, error: "Only supervisor/admin staff can use the internal allocation workspace." };
  return { ok: true as const };
}

async function requireActor(params: { supabase: Awaited<ReturnType<typeof createClient>>; mode: "operator" | "staff"; orderId: string }) {
  return params.mode === "staff" ? getStaffActor(params.supabase) : getOperatorActor(params.supabase, params.orderId);
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

  const refresh = await refreshInvoiceAdjustmentLedger({ supabase, supplierInvoiceId: lineBeforeClear?.supplier_invoice_id });
  if (!refresh.ok) redirectBack(mode, orderId, { error: refresh.error });

  revalidatePath(`/importer/delivery-allocation/${orderId}`);
  revalidatePath(`/internal/delivery-allocation/${orderId}`);
  redirectBack(mode, orderId, { success: "Unlocked package allocations cleared and invoice adjustment ledger refreshed." });
}
