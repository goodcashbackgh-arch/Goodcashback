"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/utils/supabase/server";

const LOYALTY_CONTROLS_PATH = "/internal/accounting-command-centre/loyalty-controls";

function text(formData: FormData, key: string) {
  return String(formData.get(key) ?? "").trim();
}

async function rpcOrThrow(name: string, args: Record<string, unknown>) {
  const supabase = await createClient();
  const { error } = await (supabase as any).rpc(name, args);

  if (error) {
    throw new Error(error.message || `Could not run ${name}.`);
  }

  revalidatePath(LOYALTY_CONTROLS_PATH);
}

export async function materialiseAppliedLoyaltySettlementAction(formData: FormData) {
  const eventId = text(formData, "order_funding_event_id");
  const notes = text(formData, "notes");

  if (!eventId) {
    throw new Error("Missing order funding event id for completion-loyalty materialisation.");
  }

  await rpcOrThrow("staff_materialise_completion_loyalty_applied_settlement_v1", {
    p_order_funding_event_id: eventId,
    p_notes: notes || null,
  });
}

export async function validateCompletionLoyaltySageGroupAction(formData: FormData) {
  const groupId = text(formData, "posting_group_id");

  if (!groupId) {
    throw new Error("Missing completion-loyalty Sage posting group id for validation.");
  }

  await rpcOrThrow("staff_validate_completion_loyalty_sage_group_v1", {
    p_posting_group_id: groupId,
  });
}

export async function approveCompletionLoyaltySageGroupAction(formData: FormData) {
  const groupId = text(formData, "posting_group_id");
  const notes = text(formData, "approval_notes");

  if (!groupId) {
    throw new Error("Missing completion-loyalty Sage posting group id for approval.");
  }

  await rpcOrThrow("staff_approve_completion_loyalty_sage_group_v1", {
    p_posting_group_id: groupId,
    p_notes: notes || null,
  });
}

export async function supersedeCompletionLoyaltySageGroupAction(formData: FormData) {
  const groupId = text(formData, "posting_group_id");
  const reason = text(formData, "supersede_reason");

  if (!groupId) {
    throw new Error("Missing completion-loyalty Sage posting group id for supersede.");
  }

  await rpcOrThrow("staff_supersede_completion_loyalty_sage_group_v1", {
    p_posting_group_id: groupId,
    p_reason: reason || "Superseded from loyalty controls page before Sage posting.",
  });
}
