"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

export async function confirmOrderSettlementCreditFromReconciliationAction(formData: FormData) {
  const orderId = readString(formData, "order_id");
  const reason = readString(formData, "reason") || "supervisor_confirmed_credit";
  const notes = readString(formData, "notes") || null;

  if (!orderId) redirect("/internal/supplier-draft-ready?error=Missing+order+id");

  const supabase = await createClient();
  const { error } = await supabase.rpc("staff_confirm_order_settlement_credit_v1", {
    p_order_id: orderId,
    p_reason: reason,
    p_notes: notes,
  });

  if (error) {
    redirect(`/internal/reconciliation/${orderId}?error=${encodeURIComponent(error.message)}`);
  }

  revalidatePath(`/internal/reconciliation/${orderId}`);
  revalidatePath("/internal/supplier-draft-ready");
  revalidatePath("/internal/status-control/pre-sage-financial-readiness");
  revalidatePath("/customer");
  redirect(`/internal/reconciliation/${orderId}?success=${encodeURIComponent("Settlement credit created and order surplus closed.")}`);
}
