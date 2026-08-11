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
    p_items: [
      {
        supplier_invoice_line_id: lineId,
        quantity_mode: "exact",
        qty: qtyAllocated,
      },
    ],
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
    p_items: lineIds.map((lineId) => ({
      supplier_invoice_line_id: lineId,
      quantity_mode: "remaining",
    })),
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

export async function clearDeliveryAllocationForLineAction(formData: FormData) {
  const supabase = await createClient();
  const mode = readString(formData, "mode") === "staff" ? "staff" : "operator";
  const orderId = readString(formData, "order_id");
  const lineId = readString(formData, "supplier_invoice_line_id");

  if (!orderId || !lineId) redirect("/importer");

  const { data, error } = await (supabase as any).rpc("delivery_clear_tracking_allocations_v1", {
    p_order_id: orderId,
    p_actor_mode: mode,
    p_supplier_invoice_line_id: lineId,
  });

  if (error) {
    redirectBack(mode, orderId, {
      error: rpcErrorMessage(
        error,
        "This allocation has downstream history and cannot be cleared here. Use the controlled correction route.",
      ),
    });
  }

  const deletedCount = Number(data?.deleted_allocation_count ?? 0);
  revalidateDeliveryAllocation(orderId);
  redirectBack(mode, orderId, {
    success: `${deletedCount} editable package allocation${deletedCount === 1 ? "" : "s"} cleared and the invoice adjustment ledger refreshed atomically.`,
  });
}
