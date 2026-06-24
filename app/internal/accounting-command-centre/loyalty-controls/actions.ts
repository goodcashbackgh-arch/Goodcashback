"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

const LOYALTY_CONTROLS_PATH = "/internal/accounting-command-centre/loyalty-controls";

function text(formData: FormData, key: string) {
  return String(formData.get(key) ?? "").trim();
}

function textArray(formData: FormData, key: string) {
  return formData.getAll(key).map((value) => String(value ?? "").trim()).filter(Boolean);
}

async function rpcOrThrow(name: string, args: Record<string, unknown>) {
  const supabase = await createClient();
  const { error } = await (supabase as any).rpc(name, args);

  if (error) {
    throw new Error(error.message || `Could not run ${name}.`);
  }

  revalidatePath(LOYALTY_CONTROLS_PATH);
}

async function rpcDataOrThrow<T = Record<string, unknown>>(name: string, args: Record<string, unknown>) {
  const supabase = await createClient();
  const { data, error } = await (supabase as any).rpc(name, args);

  if (error) {
    throw new Error(error.message || `Could not run ${name}.`);
  }

  revalidatePath(LOYALTY_CONTROLS_PATH);
  return (data ?? {}) as T;
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

export async function createCompletionLoyaltySageBatchAction(formData: FormData) {
  const groupIds = textArray(formData, "posting_group_id");
  const notes = text(formData, "batch_notes");

  if (groupIds.length === 0) {
    throw new Error("Select at least one locally validated completion-loyalty Sage group to batch.");
  }

  const result = await rpcDataOrThrow<{ batch_id?: string }>("staff_create_completion_loyalty_sage_batch_v1", {
    p_posting_group_ids: groupIds,
    p_notes: notes || null,
  });

  const batchId = String(result.batch_id ?? "").trim();
  if (!batchId) {
    throw new Error("Loyalty Sage batch was created but no batch id was returned.");
  }

  revalidatePath(`${LOYALTY_CONTROLS_PATH}/batches/${batchId}`);
  redirect(`${LOYALTY_CONTROLS_PATH}/batches/${batchId}`);
}

export async function approveCompletionLoyaltySageBatchAction(formData: FormData) {
  const batchId = text(formData, "batch_id");
  const notes = text(formData, "approval_notes");

  if (!batchId) {
    throw new Error("Missing completion-loyalty Sage batch id for approval.");
  }

  await rpcOrThrow("staff_approve_completion_loyalty_sage_batch_v1", {
    p_batch_id: batchId,
    p_notes: notes || null,
  });

  revalidatePath(`${LOYALTY_CONTROLS_PATH}/batches/${batchId}`);
}
