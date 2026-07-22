"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { headers } from "next/headers";
import { createClient } from "@/utils/supabase/server";

function redirectWithAllocationResult(params: Record<string, string>, path = "/internal/dva-reconciliation"): never {
  const query = new URLSearchParams(params);
  const separator = path.includes("?") ? "&" : "?";
  redirect(`${path}${separator}${query.toString()}`);
}

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

function numeric(value: unknown) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

function booleanish(value: unknown) {
  return value === true || (typeof value === "string" && value.toLowerCase() === "true");
}

async function returnPath(formData: FormData) {
  const requested = readString(formData, "return_path");
  if (requested.startsWith("/internal/dva-reconciliation")) return requested;

  const headerStore = await headers();
  const referer = headerStore.get("referer");
  if (referer) {
    try {
      const url = new URL(referer);
      if (url.pathname.startsWith("/internal/dva-reconciliation")) return `${url.pathname}${url.search}`;
    } catch {
      // Use the stable fallback below.
    }
  }

  const importerId = readString(formData, "current_importer_id");
  const status = readString(formData, "current_status") || "needs";
  const params = new URLSearchParams();
  if (status) params.set("status", status);
  if (importerId) params.set("importer_id", importerId);
  const query = params.toString();
  return query ? `/internal/dva-reconciliation?${query}` : "/internal/dva-reconciliation";
}

export async function generateSupplierInvoiceSuggestionsAction(formData: FormData) {
  const supabase = await createClient();
  const path = await returnPath(formData);
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirectWithAllocationResult({ allocation_error: "Please sign in again before generating suggestions." }, path);

  const tolerance = Number(readString(formData, "tolerance_gbp") || "5");
  const maxDays = Number(readString(formData, "max_days") || "14");
  const statementLineId = readString(formData, "dva_statement_line_id") || null;
  if (!Number.isFinite(tolerance) || tolerance < 0) redirectWithAllocationResult({ allocation_error: "Suggestion tolerance must be zero or greater." }, path);
  if (!Number.isInteger(maxDays) || maxDays < 0) redirectWithAllocationResult({ allocation_error: "Suggestion day window must be a whole number greater than or equal to zero." }, path);

  const { data, error } = await supabase.rpc("staff_generate_supplier_invoice_match_suggestions", {
    p_dva_statement_line_id: statementLineId,
    p_tolerance_gbp: tolerance,
    p_max_days: maxDays,
  });
  if (error) redirectWithAllocationResult({ allocation_error: error.message }, path);

  revalidatePath("/internal/dva-reconciliation");
  revalidatePath("/internal/dva-reconciliation/workspace");
  revalidatePath("/internal/dva-reconciliation/unmatched");
  const insertedCount = typeof data === "object" && data !== null && "inserted_count" in data ? String((data as { inserted_count?: unknown }).inserted_count) : "0";
  redirectWithAllocationResult({ allocation_success: `Generated ${insertedCount} supplier invoice suggestion(s).` }, path);
}

export async function allocateStatementLineToFxCardOrFeeAction(formData: FormData) {
  const supabase = await createClient();
  const path = await returnPath(formData);
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirectWithAllocationResult({ allocation_error: "Please sign in again before allocating FX/card/fee difference." }, path);

  const statementLineId = readString(formData, "dva_statement_line_id");
  const allocationType = readString(formData, "allocation_type") || "fx_card_difference";
  const allocatedAmount = Number(readString(formData, "allocated_gbp_amount"));
  const notes = readString(formData, "notes") || null;
  if (!statementLineId) redirectWithAllocationResult({ allocation_error: "Missing statement line reference." }, path);
  if (!["fx_card_difference", "bank_fee"].includes(allocationType)) redirectWithAllocationResult({ allocation_error: "Unsupported allocation type for FX/card/fee allocation." }, path);
  if (!Number.isFinite(allocatedAmount) || allocatedAmount <= 0) redirectWithAllocationResult({ allocation_error: "Allocation amount must be greater than zero." }, path);

  const { data: summaryRow, error: summaryError } = await supabase
    .from("dva_statement_line_allocation_summary_vw")
    .select("direction, confirmed_allocated_gbp, confirmed_unallocated_gbp, confirmed_balanced_yn")
    .eq("dva_statement_line_id", statementLineId)
    .single();
  if (summaryError) redirectWithAllocationResult({ allocation_error: summaryError.message }, path);
  if (!summaryRow || summaryRow.direction !== "out") redirectWithAllocationResult({ allocation_error: "FX/card/fee residual allocation is only allowed for OUT statement lines." }, path);
  if (booleanish(summaryRow.confirmed_balanced_yn)) redirectWithAllocationResult({ allocation_error: "This statement line is already balanced." }, path);
  if (allocationType === "fx_card_difference" && numeric(summaryRow.confirmed_allocated_gbp) <= 0) redirectWithAllocationResult({ allocation_error: "FX/card residual allocation is only allowed after a supplier invoice, refund, exception, or hold allocation already exists. Use bank fee for standalone bank/card charges." }, path);
  if (numeric(summaryRow.confirmed_unallocated_gbp) <= 0) redirectWithAllocationResult({ allocation_error: "There is no remaining balance to allocate as FX/card/fee." }, path);

  const { data, error } = await supabase.rpc("staff_allocate_statement_line_to_fx_card_or_fee", {
    p_dva_statement_line_id: statementLineId,
    p_allocation_type: allocationType,
    p_allocated_gbp_amount: allocatedAmount,
    p_notes: notes,
  });
  if (error) redirectWithAllocationResult({ allocation_error: error.message }, path);

  revalidatePath("/internal/dva-reconciliation");
  revalidatePath("/internal/dva-reconciliation/workspace");
  revalidatePath("/internal/dva-reconciliation/allocations");
  const appliedAmount = typeof data === "object" && data !== null && "allocated_gbp_amount" in data ? String((data as { allocated_gbp_amount?: unknown }).allocated_gbp_amount) : allocatedAmount.toFixed(2);
  redirectWithAllocationResult({ allocation_success: `Allocated £${appliedAmount} to ${allocationType.replaceAll("_", " ")}.` }, path);
}

export async function allocateStatementLineToOperationalTargetAction(formData: FormData) {
  const supabase = await createClient();
  const path = await returnPath(formData);
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirectWithAllocationResult({ allocation_error: "Please sign in again before allocating the operational target." }, path);

  const statementLineId = readString(formData, "dva_statement_line_id");
  const disputeId = readString(formData, "dispute_id") || null;
  const allocationType = readString(formData, "allocation_type");
  const allocatedAmount = Number(readString(formData, "allocated_gbp_amount"));
  const notes = readString(formData, "notes") || null;
  if (!statementLineId) redirectWithAllocationResult({ allocation_error: "Missing statement line reference." }, path);
  if (!["retailer_refund", "exception_hold", "not_charged_closure", "unmatched_hold"].includes(allocationType)) redirectWithAllocationResult({ allocation_error: "Unsupported operational allocation type." }, path);
  if (allocationType !== "unmatched_hold" && !disputeId) redirectWithAllocationResult({ allocation_error: "A dispute/exception reference is required for this operational allocation." }, path);
  if (!Number.isFinite(allocatedAmount) || allocatedAmount <= 0) redirectWithAllocationResult({ allocation_error: "Allocation amount must be greater than zero." }, path);

  const { data, error } = await supabase.rpc("staff_allocate_statement_line_to_dispute_or_hold", {
    p_dva_statement_line_id: statementLineId,
    p_allocation_type: allocationType,
    p_dispute_id: disputeId,
    p_allocated_gbp_amount: allocatedAmount,
    p_notes: notes,
  });
  if (error) redirectWithAllocationResult({ allocation_error: error.message }, path);

  revalidatePath("/internal/dva-reconciliation");
  revalidatePath("/internal/dva-reconciliation/workspace");
  revalidatePath("/internal/dva-reconciliation/allocations");
  const appliedAmount = typeof data === "object" && data !== null && "allocated_gbp_amount" in data ? String((data as { allocated_gbp_amount?: unknown }).allocated_gbp_amount) : allocatedAmount.toFixed(2);
  redirectWithAllocationResult({ allocation_success: `Allocated £${appliedAmount} to ${allocationType.replaceAll("_", " ")}.` }, path);
}

export async function reverseDvaStatementLineAllocationAction(formData: FormData) {
  const supabase = await createClient();
  const path = await returnPath(formData);
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirectWithAllocationResult({ allocation_error: "Please sign in again before reversing the allocation." }, path);

  const allocationId = readString(formData, "allocation_id");
  const reversalReason = readString(formData, "reversal_reason");
  if (!allocationId) redirectWithAllocationResult({ allocation_error: "Missing allocation reference." }, path);
  if (reversalReason.length < 8) redirectWithAllocationResult({ allocation_error: "Enter a reversal reason of at least 8 characters." }, path);

  const { data, error } = await supabase.rpc("staff_reverse_dva_statement_line_allocation", {
    p_allocation_id: allocationId,
    p_reversal_reason: reversalReason,
  });
  if (error) redirectWithAllocationResult({ allocation_error: error.message }, path);

  revalidatePath("/internal/dva-reconciliation");
  revalidatePath("/internal/dva-reconciliation/workspace");
  revalidatePath("/internal/dva-reconciliation/allocations");
  const reversedAmount = typeof data === "object" && data !== null && "reversed_amount_gbp" in data ? String((data as { reversed_amount_gbp?: unknown }).reversed_amount_gbp) : "";
  redirectWithAllocationResult({ allocation_success: reversedAmount ? `Reversed allocation of £${reversedAmount}.` : "Allocation reversed." }, path);
}

export async function allocateStatementLineToSupplierInvoiceAction(formData: FormData) {
  const supabase = await createClient();
  const path = await returnPath(formData);
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirectWithAllocationResult({ allocation_error: "Please sign in again before allocating the statement line." }, path);

  const statementLineId = readString(formData, "dva_statement_line_id");
  const supplierInvoiceId = readString(formData, "supplier_invoice_id");
  const notes = readString(formData, "notes") || null;
  if (!statementLineId || !supplierInvoiceId) redirectWithAllocationResult({ allocation_error: "Missing statement line or supplier invoice reference." }, path);

  const [{ data: summary, error: summaryError }, { data: invoice, error: invoiceError }] = await Promise.all([
    supabase.from("dva_statement_line_allocation_summary_vw").select("confirmed_unallocated_gbp").eq("dva_statement_line_id", statementLineId).single(),
    supabase.from("supplier_payment_candidate_status_vw").select("remaining_unmatched_gbp").eq("supplier_invoice_id", supplierInvoiceId).single(),
  ]);
  if (summaryError) redirectWithAllocationResult({ allocation_error: summaryError.message }, path);
  if (invoiceError) redirectWithAllocationResult({ allocation_error: invoiceError.message }, path);

  const allocatedAmount = Math.min(numeric(summary?.confirmed_unallocated_gbp), numeric(invoice?.remaining_unmatched_gbp));
  if (!Number.isFinite(allocatedAmount) || allocatedAmount <= 0) redirectWithAllocationResult({ allocation_error: "No remaining statement or supplier-invoice value is available to allocate." }, path);

  const { data, error } = await supabase.rpc("staff_allocate_statement_line_to_supplier_invoice_incremental_v1", {
    p_dva_statement_line_id: statementLineId,
    p_supplier_invoice_id: supplierInvoiceId,
    p_allocated_gbp_amount: allocatedAmount,
    p_notes: notes,
  });
  if (error) redirectWithAllocationResult({ allocation_error: error.message }, path);

  revalidatePath("/internal/dva-reconciliation");
  revalidatePath("/internal/dva-reconciliation/workspace");
  revalidatePath("/internal/dva-reconciliation/allocations");
  const appliedAmount = typeof data === "object" && data !== null && "allocated_gbp_amount" in data ? String((data as { allocated_gbp_amount?: unknown }).allocated_gbp_amount) : allocatedAmount.toFixed(2);
  redirectWithAllocationResult({ allocation_success: `Allocated £${appliedAmount} to supplier invoice.` }, path);
}
