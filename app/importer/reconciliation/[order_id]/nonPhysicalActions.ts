"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

function redirectWithResult(orderId: string, params: Record<string, string>): never {
  const query = new URLSearchParams(params);
  redirect(`/importer/reconciliation/${orderId}?${query.toString()}`);
}

const ALLOWED_FINANCIAL_TYPES = new Set([
  "delivery",
  "discount",
  "fee",
  "zero_value_delivery",
  "rounding",
  "other_non_physical",
]);

export async function resolveSupplierInvoiceLineNonPhysicalAction(formData: FormData) {
  const orderId = readString(formData, "order_id");
  const lineId = readString(formData, "line_id");
  const financialType = readString(formData, "financial_type");
  const notes = readString(formData, "notes") || null;

  if (!orderId || !lineId) {
    redirect("/importer");
  }

  if (!ALLOWED_FINANCIAL_TYPES.has(financialType)) {
    redirectWithResult(orderId, { error: "Select a valid non-physical financial type." });
  }

  const supabase = await createClient();
  const { error } = await supabase.rpc("operator_resolve_supplier_invoice_line_non_physical", {
    p_order_id: orderId,
    p_supplier_invoice_line_id: lineId,
    p_financial_type: financialType,
    p_notes: notes,
  });

  if (error) {
    redirectWithResult(orderId, { error: error.message });
  }

  revalidatePath(`/importer/reconciliation/${orderId}`);
  revalidatePath(`/internal/reconciliation/${orderId}`);
  revalidatePath("/internal/supplier-draft-ready");
  redirectWithResult(orderId, { success: "Line parked as non-physical financial line." });
}
