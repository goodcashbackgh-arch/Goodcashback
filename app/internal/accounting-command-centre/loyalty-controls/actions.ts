"use server";

import { revalidatePath } from "next/cache";
import { headers } from "next/headers";
import { redirect } from "next/navigation";
import { postCompletionLoyaltySageBatchToSage } from "@/lib/sage/completionLoyaltyBatchPosting";
import { createClient } from "@/utils/supabase/server";

const LOYALTY_CONTROLS_PATH = "/internal/accounting-command-centre/loyalty-controls";
const INTERNAL_TRANSFER_MATERIALISE_RPC = "staff_materialise_completion_loyalty_internal_transfer_journal_";

function text(formData: FormData, key: string) {
  return String(formData.get(key) ?? "").trim();
}

function textArray(formData: FormData, key: string) {
  return formData.getAll(key).map((value) => String(value ?? "").trim()).filter(Boolean);
}

function unique(values: string[]) {
  return Array.from(new Set(values.map((value) => value.trim()).filter(Boolean)));
}

function actionMessage(error: unknown, fallback: string) {
  return error instanceof Error ? error.message : fallback;
}

function controlsActionRedirect(kind: "success" | "error", message: string, anchor = "step-3-lifecycle") {
  redirect(`${LOYALTY_CONTROLS_PATH}?${kind}=${encodeURIComponent(message)}#${anchor}`);
}

function hasAccountingAdminTesting(value: unknown) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const permissions = value as Record<string, unknown>;
  return permissions.accounting_admin_testing === true || permissions.admin_testing === true;
}

async function originFromHeaders() {
  const headerStore = await headers();
  const host = headerStore.get("x-forwarded-host") || headerStore.get("host") || "";
  const proto = headerStore.get("x-forwarded-proto") || "https";
  return host ? `${proto}://${host}` : "";
}

async function requireAccountingAdminAccess(returnPath = LOYALTY_CONTROLS_PATH) {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff, error: staffError } = await supabase
    .from("staff")
    .select("id, role_type, permissions_json")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (staffError || !staff) {
    redirect(`${returnPath}?error=${encodeURIComponent(staffError?.message || "Active staff account required")}`);
  }

  const canAccess = String(staff.role_type ?? "") === "admin" || hasAccountingAdminTesting((staff as Record<string, unknown>).permissions_json);
  if (!canAccess) {
    redirect(`${returnPath}?error=${encodeURIComponent("Accounting admin access required")}`);
  }

  return { supabase, staffId: String(staff.id) };
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
    controlsActionRedirect("error", "Missing order funding event id for completion-loyalty materialisation.", "step-3-lifecycle");
  }

  try {
    await rpcOrThrow("staff_materialise_completion_loyalty_applied_settlement_v1", {
      p_order_funding_event_id: eventId,
      p_notes: notes || null,
    });
  } catch (error) {
    controlsActionRedirect("error", actionMessage(error, "Could not materialise applied-loyalty settlement."), "step-3-lifecycle");
  }

  controlsActionRedirect("success", "Applied-loyalty settlement materialised/frozen locally. No Sage API call was made.", "step-3-lifecycle");
}

export async function materialiseSelectedAppliedLoyaltySettlementsAction(formData: FormData) {
  const eventIds = unique(textArray(formData, "order_funding_event_id"));
  const notes = text(formData, "notes");

  if (eventIds.length === 0) {
    controlsActionRedirect("error", "Select at least one applied-loyalty candidate to materialise/freeze.", "step-3-lifecycle");
  }

  const { supabase } = await requireAccountingAdminAccess();
  let materialisedCount = 0;
  let blockedCount = 0;
  let firstBlocker = "";

  for (const eventId of eventIds) {
    const { error } = await (supabase as any).rpc("staff_materialise_completion_loyalty_applied_settlement_v1", {
      p_order_funding_event_id: eventId,
      p_notes: notes || "Bulk materialised from applied-loyalty controls. No Sage API call.",
    });

    if (error) {
      blockedCount += 1;
      if (!firstBlocker) firstBlocker = error.message;
    } else {
      materialisedCount += 1;
    }
  }

  revalidatePath(LOYALTY_CONTROLS_PATH);

  const message = blockedCount > 0
    ? `Applied-loyalty materialise/freeze: materialised ${materialisedCount}, blocked ${blockedCount}${firstBlocker ? ` — ${firstBlocker}` : ""}. No Sage API call was made.`
    : `Applied-loyalty materialise/freeze: materialised ${materialisedCount}. No Sage API call was made.`;
  controlsActionRedirect(blockedCount > 0 ? "error" : "success", message, "step-3-lifecycle");
}

export async function materialiseInternalTransferJournalAction(formData: FormData) {
  const sourceOutStatementLineId = text(formData, "source_out_statement_line_id");
  const destinationInStatementLineId = text(formData, "destination_in_statement_line_id");
  const notes = text(formData, "notes");

  if (!sourceOutStatementLineId || !destinationInStatementLineId) {
    controlsActionRedirect("error", "Missing source OUT or destination IN statement line id for internal-transfer materialisation.", "step-3-internal-transfer");
  }

  try {
    await rpcOrThrow(INTERNAL_TRANSFER_MATERIALISE_RPC, {
      p_source_out_statement_line_id: sourceOutStatementLineId,
      p_destination_in_statement_line_id: destinationInStatementLineId,
      p_notes: notes || null,
    });
  } catch (error) {
    controlsActionRedirect("error", actionMessage(error, "Could not materialise internal-transfer journal."), "step-3-internal-transfer");
  }

  controlsActionRedirect("success", "Internal-transfer journal materialised/frozen locally. No Sage API call was made.", "step-3-internal-transfer");
}

function parseInternalTransferCandidateKey(value: string) {
  const [sourceOutStatementLineId = "", destinationInStatementLineId = ""] = value.split("|").map((part) => part.trim());
  return { sourceOutStatementLineId, destinationInStatementLineId };
}

export async function materialiseSelectedInternalTransferJournalsAction(formData: FormData) {
  const selectedPairs = unique(textArray(formData, "internal_transfer_candidate_key"))
    .map(parseInternalTransferCandidateKey)
    .filter((pair) => pair.sourceOutStatementLineId && pair.destinationInStatementLineId);
  const notes = text(formData, "notes");

  if (selectedPairs.length === 0) {
    controlsActionRedirect("error", "Select at least one internal-transfer candidate to materialise/freeze.", "step-3-internal-transfer");
  }

  const { supabase } = await requireAccountingAdminAccess();
  let materialisedCount = 0;
  let blockedCount = 0;
  let firstBlocker = "";

  for (const pair of selectedPairs) {
    const { error } = await (supabase as any).rpc(INTERNAL_TRANSFER_MATERIALISE_RPC, {
      p_source_out_statement_line_id: pair.sourceOutStatementLineId,
      p_destination_in_statement_line_id: pair.destinationInStatementLineId,
      p_notes: notes || "Bulk materialised from internal-transfer controls. No Sage API call.",
    });

    if (error) {
      blockedCount += 1;
      if (!firstBlocker) firstBlocker = error.message;
    } else {
      materialisedCount += 1;
    }
  }

  revalidatePath(LOYALTY_CONTROLS_PATH);

  const message = blockedCount > 0
    ? `Internal-transfer materialise/freeze: materialised ${materialisedCount}, blocked ${blockedCount}${firstBlocker ? ` — ${firstBlocker}` : ""}. No Sage API call was made.`
    : `Internal-transfer materialise/freeze: materialised ${materialisedCount}. No Sage API call was made.`;
  controlsActionRedirect(blockedCount > 0 ? "error" : "success", message, "step-3-internal-transfer");
}

export async function validateCompletionLoyaltySageGroupAction(formData: FormData) {
  const groupId = text(formData, "posting_group_id");

  if (!groupId) {
    controlsActionRedirect("error", "Missing completion-loyalty Sage posting group id for validation.");
  }

  try {
    await rpcOrThrow("staff_validate_completion_loyalty_sage_group_v1", {
      p_posting_group_id: groupId,
    });
  } catch (error) {
    controlsActionRedirect("error", actionMessage(error, "Could not revalidate completion-loyalty Sage group."));
  }

  controlsActionRedirect("success", "Completion-loyalty Sage group revalidated.");
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

export async function postCompletionLoyaltySageBatchAction(formData: FormData) {
  const batchId = text(formData, "batch_id");
  if (!batchId) redirect(`${LOYALTY_CONTROLS_PATH}?error=${encodeURIComponent("Missing completion-loyalty Sage batch id")}`);

  const batchPath = `${LOYALTY_CONTROLS_PATH}/batches/${batchId}`;
  const { staffId } = await requireAccountingAdminAccess(batchPath);
  const origin = await originFromHeaders();

  let result: Awaited<ReturnType<typeof postCompletionLoyaltySageBatchToSage>>;
  try {
    result = await postCompletionLoyaltySageBatchToSage({ batchId, staffId, origin });
  } catch (error) {
    const message = error instanceof Error ? error.message : "Completion-loyalty Sage batch posting failed.";
    revalidatePath(batchPath);
    redirect(`${batchPath}?error=${encodeURIComponent(message)}`);
  }

  revalidatePath(LOYALTY_CONTROLS_PATH);
  revalidatePath(batchPath);
  redirect(`${batchPath}?success=${encodeURIComponent(`Completion-loyalty Sage posting finished: ${result.posted} posted, ${result.failed} failed, ${result.needsReview} needs review, ${result.total} total. Endpoint ${result.endpoint}.`)}`);
}
