"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

function redirectWithAllocationResult(params: Record<string, string>): never {
  const query = new URLSearchParams(params);
  redirect(`/internal/dva-reconciliation?${query.toString()}`);
}

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
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
