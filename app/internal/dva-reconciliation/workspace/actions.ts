"use server";

import { headers } from "next/headers";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

async function returnPath(formData: FormData) {
  const requested = readString(formData, "return_path");
  if (requested.startsWith("/internal/dva-reconciliation/workspace")) return requested;

  const headerStore = await headers();
  const referer = headerStore.get("referer");
  if (referer) {
    try {
      const url = new URL(referer);
      if (url.pathname === "/internal/dva-reconciliation/workspace") {
        return `${url.pathname}${url.search}`;
      }
    } catch {
      // Fall through to the stable workspace route.
    }
  }

  return "/internal/dva-reconciliation/workspace";
}

function redirectWithResult(path: string, params: Record<string, string>): never {
  const query = new URLSearchParams(params);
  const separator = path.includes("?") ? "&" : "?";
  redirect(`${path}${separator}${query.toString()}`);
}

export async function allocateWorkspaceSupplierInvoiceAction(formData: FormData) {
  const supabase = await createClient();
  const path = await returnPath(formData);

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirectWithResult(path, { allocation_error: "Please sign in again before allocating the statement line." });
  }

  const statementLineId = readString(formData, "dva_statement_line_id");
  const supplierInvoiceId = readString(formData, "supplier_invoice_id");
  const allocatedAmount = Number(readString(formData, "allocated_gbp_amount"));
  const notes = readString(formData, "notes") || null;

  if (!statementLineId || !supplierInvoiceId) {
    redirectWithResult(path, { allocation_error: "Missing statement line or supplier invoice reference." });
  }

  if (!Number.isFinite(allocatedAmount) || allocatedAmount <= 0) {
    redirectWithResult(path, { allocation_error: "Allocation amount must be greater than zero." });
  }

  const { data, error } = await supabase.rpc("staff_allocate_statement_line_to_supplier_invoice_incremental_v1", {
    p_dva_statement_line_id: statementLineId,
    p_supplier_invoice_id: supplierInvoiceId,
    p_allocated_gbp_amount: allocatedAmount,
    p_notes: notes,
  });

  if (error) {
    redirectWithResult(path, { allocation_error: error.message });
  }

  revalidatePath("/internal/dva-reconciliation");
  revalidatePath("/internal/dva-reconciliation/workspace");
  revalidatePath("/internal/dva-reconciliation/allocations");

  const appliedAmount =
    typeof data === "object" && data !== null && "allocated_gbp_amount" in data
      ? String((data as { allocated_gbp_amount?: unknown }).allocated_gbp_amount)
      : allocatedAmount.toFixed(2);

  redirectWithResult(path, { allocation_success: `Allocated £${appliedAmount} to supplier invoice.` });
}
