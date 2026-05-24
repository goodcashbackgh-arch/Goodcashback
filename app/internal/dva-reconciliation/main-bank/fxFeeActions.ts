"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

function redirectBack(params: Record<string, string>): never {
  const query = new URLSearchParams(params);
  redirect(`/internal/dva-reconciliation/main-bank?${query.toString()}`);
}

export async function allocateMainBankFxFeeAction(formData: FormData) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) redirectBack({ error: "Please sign in again before saving the FX or fee allocation." });

  const statementLineId = readString(formData, "dva_statement_line_id");
  const allocationType = readString(formData, "residual_allocation_type");
  const amountRaw = readString(formData, "residual_gbp_amount");
  const notes = readString(formData, "notes") || "Main bank FX or fee allocation.";
  const amount = amountRaw ? Number(amountRaw) : 0;

  if (!statementLineId) redirectBack({ error: "Select one main-bank statement line first." });
  if (allocationType !== "fx_card_difference" && allocationType !== "bank_fee") redirectBack({ error: "Choose FX/card difference or bank fee." });
  if (!Number.isFinite(amount) || amount <= 0) redirectBack({ error: "Amount must be greater than zero." });

  const { data, error } = await supabase.rpc("staff_allocate_statement_line_to_fx_card_or_fee", {
    p_dva_statement_line_id: statementLineId,
    p_allocation_type: allocationType,
    p_allocated_gbp_amount: amount,
    p_notes: notes,
  });

  if (error) redirectBack({ error: error.message });

  revalidatePath("/internal/dva-reconciliation/main-bank");
  revalidatePath("/internal/dva-reconciliation/allocations");
  revalidatePath("/internal/accounting-command-centre/cash-posting");

  const allocatedAmount =
    typeof data === "object" && data !== null && "allocated_gbp_amount" in data
      ? Number((data as { allocated_gbp_amount?: unknown }).allocated_gbp_amount ?? amount)
      : amount;

  redirectBack({ success: `Saved ${allocationType.replace(/_/g, " ")} allocation £${allocatedAmount.toFixed(2)}.` });
}
