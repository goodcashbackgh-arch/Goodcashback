"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

function redirectWithResult(params: Record<string, string>): never {
  const query = new URLSearchParams(params);
  redirect(`/internal/dva-reconciliation/main-bank?${query.toString()}`);
}

export async function allocateMainBankLineToShipperApAction(formData: FormData) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirectWithResult({ error: "Please sign in again before allocating the main bank line." });
  }

  const statementLineId = readString(formData, "dva_statement_line_id");
  const shippingDocumentId = readString(formData, "shipping_document_id");
  const amountRaw = readString(formData, "allocated_gbp_amount");
  const notes = readString(formData, "notes") || null;
  const amount = amountRaw ? Number(amountRaw) : null;

  if (!statementLineId || !shippingDocumentId) {
    redirectWithResult({ error: "Select a main-bank OUT line and a posted shipper AP invoice." });
  }

  if (amountRaw && (!Number.isFinite(amount) || Number(amount) <= 0)) {
    redirectWithResult({ error: "Allocation amount must be greater than zero." });
  }

  const { data, error } = await supabase.rpc("staff_allocate_main_bank_line_to_shipper_ap_v1", {
    p_dva_statement_line_id: statementLineId,
    p_shipping_document_id: shippingDocumentId,
    p_allocated_gbp_amount: amount,
    p_notes: notes,
  });

  if (error) {
    redirectWithResult({ error: error.message });
  }

  revalidatePath("/internal/dva-reconciliation/main-bank");
  revalidatePath("/internal/accounting-command-centre/cash-posting");

  const allocatedAmount =
    typeof data === "object" && data !== null && "allocated_gbp_amount" in data
      ? String((data as { allocated_gbp_amount?: unknown }).allocated_gbp_amount)
      : amountRaw || "";

  redirectWithResult({ success: `Allocated £${allocatedAmount} to shipper AP invoice.` });
}
