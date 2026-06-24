"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/utils/supabase/server";

export async function materialiseAppliedLoyaltySettlementAction(formData: FormData) {
  const eventId = String(formData.get("order_funding_event_id") ?? "").trim();
  const notes = String(formData.get("notes") ?? "").trim();

  if (!eventId) {
    throw new Error("Missing order funding event id for completion-loyalty materialisation.");
  }

  const supabase = await createClient();
  const { error } = await (supabase as any).rpc("staff_materialise_completion_loyalty_applied_settlement_v1", {
    p_order_funding_event_id: eventId,
    p_notes: notes || null,
  });

  if (error) {
    throw new Error(error.message || "Could not materialise completion-loyalty Sage posting group.");
  }

  revalidatePath("/internal/accounting-command-centre/loyalty-controls");
}
