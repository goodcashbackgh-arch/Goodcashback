"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

function redirectWithAllocationResult(params: Record<string, string>, path = "/internal/dva-reconciliation"): never {
  const query = new URLSearchParams(params);
  redirect(`${path}?${query.toString()}`);
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

function returnPath(formData: FormData) {
  const requested = readString(formData, "return_path");
  if (requested.startsWith("/internal/dva-reconciliation")) return requested;
  return "/internal/dva-reconciliation";
}

export async function generateSupplierInvoiceSuggestionsAction(formData: FormData) {
  const supabase = await createClient();
  const path = returnPath(formData);

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirectWithAllocationResult(
      { allocation_error: "Please sign in again before generating suggestions." },
      path
    );
  }

  const toleranceRaw = readString(formData, "tolerance_gbp") || "5";
  const maxDaysRaw = readString(formData, "max_days") || "14";
  const statementLineId = readString(formData, "dva_statement_line_id") || null;
  const tolerance = Number(toleranceRaw);
  const maxDays = Number(maxDaysRaw);

  if (!Number.isFinite(tolerance) || tolerance < 0) {
    redirectWithAllocationResult(
      { allocation_error: "Suggestion tolerance must be zero or greater." },
      path
    );
  }

  if (!Number.isInteger(maxDays) || maxDays < 0) {
    redirectWithAllocationResult(
      { allocation_error: "Suggestion day window must be a whole number greater than or equal to zero." },
      path
    );
  }

  const { data, error } = await supabase.rpc("staff_generate_supplier_invoice_match_suggestions", {
    p_dva_statement_line_id: statementLineId,
    p_tolerance_gbp: tolerance,
    p_max_days: maxDays,
  });

  if (error) {
    redirectWithAllocationResult({ allocation_error: error.message }, path);
  }

  revalidatePath("/internal/dva-reconciliation");
  revalidatePath("/internal/dva-reconciliation/unmatched");

  const insertedCount =
    typeof data === "object" &&
    data !== null &&
    "inserted_count" in data
      ? String((data as { inserted_count?: unknown }).inserted_count)
      : "0";

  redirectWithAllocationResult(
    { allocation_success: `Generated ${insertedCount} supplier invoice suggestion(s).` },
    path
  );
}

export async function allocateStatementLineToFxCardOrFeeAction(formData: FormData) {
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirectWithAllocationResult({
      allocation_error: "Please sign in again before allocating FX/card/fee difference.",
    });
  }

  const statementLineId = readString(formData, "dva_statement_line_id");
  const allocationType = readString(formData, "allocation_type") || "fx_card_difference";
  const amountRaw = readString(formData, "allocated_gbp_amount");
  const notes = readString(formData, "notes") || null;
  const allocatedAmount = Number(amountRaw);

  if (!statementLineId) {
    redirectWithAllocationResult({
      allocation_error: "Missing statement line reference.",
    });
  }

  if (!["fx_card_difference", "bank_fee"].includes(allocationType)) {
    redirectWithAllocationResult({
      allocation_error: "Unsupported allocation type for FX/card/fee allocation.",
    });
  }

  if (!Number.isFinite(allocatedAmount) || allocatedAmount <= 0) {
    redirectWithAllocationResult({
      allocation_error: "Allocation amount must be greater than zero.",
    });
  }

  const { data: summaryRow, error: summaryError } = await supabase
    .from("dva_statement_line_allocation_summary_vw")
    .select("direction, confirmed_allocated_gbp, confirmed_unallocated_gbp, confirmed_balanced_yn")
    .eq("dva_statement_line_id", statementLineId)
    .single();

  if (summaryError) {
    redirectWithAllocationResult({
      allocation_error: summaryError.message,
    });
  }

  if (!summaryRow || summaryRow.direction !== "out") {
    redirectWithAllocationResult({
      allocation_error: "FX/card/fee residual allocation is only allowed for OUT statement lines.",
    });
  }

  if (booleanish(summaryRow.confirmed_balanced_yn)) {
    redirectWithAllocationResult({
      allocation_error: "This statement line is already balanced.",
    });
  }

  if (numeric(summaryRow.confirmed_allocated_gbp) <= 0) {
    redirectWithAllocationResult({
      allocation_error: "Residual allocation is only allowed after a supplier invoice, refund, exception, or hold allocation already exists.",
    });
  }

  if (numeric(summaryRow.confirmed_unallocated_gbp) <= 0) {
    redirectWithAllocationResult({
      allocation_error: "There is no remaining balance to allocate as FX/card/fee.",
    });
  }

  const { data, error } = await supabase.rpc("staff_allocate_statement_line_to_fx_card_or_fee", {
    p_dva_statement_line_id: statementLineId,
    p_allocation_type: allocationType,
    p_allocated_gbp_amount: allocatedAmount,
    p_notes: notes,
  });

  if (error) {
    redirectWithAllocationResult({
      allocation_error: error.message,
    });
  }

  revalidatePath("/internal/dva-reconciliation");

  const appliedAmount =
    typeof data === "object" &&
    data !== null &&
    "allocated_gbp_amount" in data
      ? String((data as { allocated_gbp_amount?: unknown }).allocated_gbp_amount)
      : allocatedAmount.toFixed(2);

  redirectWithAllocationResult({
    allocation_success: `Allocated £${appliedAmount} to ${allocationType.replaceAll("_", " ")}.`,
  });
}

export async function allocateStatementLineToSupplierInvoiceAction(formData: FormData) {
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirectWithAllocationResult({
      allocation_error: "Please sign in again before allocating the statement line.",
    });
  }

  const statementLineId = readString(formData, "dva_statement_line_id");
  const supplierInvoiceId = readString(formData, "supplier_invoice_id");
  const amountRaw = readString(formData, "allocated_gbp_amount");
  const notes = readString(formData, "notes") || null;
  const allocatedAmount = Number(amountRaw);

  if (!statementLineId || !supplierInvoiceId) {
    redirectWithAllocationResult({
      allocation_error: "Missing statement line or supplier invoice reference.",
    });
  }

  if (!Number.isFinite(allocatedAmount) || allocatedAmount <= 0) {
    redirectWithAllocationResult({
      allocation_error: "Allocation amount must be greater than zero.",
    });
  }

  const { data, error } = await supabase.rpc("staff_allocate_statement_line_to_supplier_invoice", {
    p_dva_statement_line_id: statementLineId,
    p_supplier_invoice_id: supplierInvoiceId,
    p_allocated_gbp_amount: allocatedAmount,
    p_notes: notes,
  });

  if (error) {
    redirectWithAllocationResult({
      allocation_error: error.message,
    });
  }

  revalidatePath("/internal/dva-reconciliation");

  const appliedAmount =
    typeof data === "object" &&
    data !== null &&
    "allocated_gbp_amount" in data
      ? String((data as { allocated_gbp_amount?: unknown }).allocated_gbp_amount)
      : allocatedAmount.toFixed(2);

  redirectWithAllocationResult({
    allocation_success: `Allocated £${appliedAmount} to supplier invoice.`,
  });
}
