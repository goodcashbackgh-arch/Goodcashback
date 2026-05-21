"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

function redirectWithResult(disputeId: string, params: Record<string, string>): never {
  const query = new URLSearchParams(params);
  redirect(`/internal/exceptions/${disputeId}?${query.toString()}`);
}

export async function closeRefundExceptionAsSettlementCreditAction(formData: FormData) {
  const disputeId = readString(formData, "dispute_id");
  const reason = readString(formData, "reason") || "not_charged_closure";
  const notes = readString(formData, "notes") || null;

  if (!disputeId) redirect("/internal/exceptions");

  const supabase = await createClient();
  const { error } = await supabase.rpc("staff_close_refund_exception_as_settlement_credit_v1", {
    p_dispute_id: disputeId,
    p_reason: reason,
    p_notes: notes,
  });

  if (error) redirectWithResult(disputeId, { error: error.message });

  revalidatePath(`/internal/exceptions/${disputeId}`);
  revalidatePath("/internal/exceptions");
  revalidatePath("/customer");
  redirectWithResult(disputeId, { success: "Exception closed as no-refund customer credit." });
}
