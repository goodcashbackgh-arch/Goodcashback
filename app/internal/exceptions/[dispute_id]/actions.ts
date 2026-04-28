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

async function requireActiveStaff() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    return { supabase, ok: false as const, error: "Please sign in again." };
  }

  const { data: staff } = await supabase
    .from("staff")
    .select("id")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!staff) {
    return { supabase, ok: false as const, error: "Active staff account not found." };
  }

  return { supabase, ok: true as const, staffId: staff.id };
}

async function requireRetailerMessageAndAcceptedOutcome(supabase: Awaited<ReturnType<typeof createClient>>, disputeId: string) {
  const { count, error } = await supabase
    .from("dispute_messages")
    .select("id", { count: "exact", head: true })
    .eq("dispute_id", disputeId)
    .eq("message_type", "retailer_reply")
    .eq("counterparty", "retailer");

  if (error) {
    return { ok: false as const, error: error.message };
  }

  if (Number(count ?? 0) < 1) {
    return { ok: false as const, error: "At least one retailer reply is required before accepting final outcome." };
  }

  const { data: lines, error: linesError } = await supabase
    .from("dispute_lines")
    .select("id, conversation_status")
    .eq("dispute_id", disputeId)
    .is("resolved_at", null);

  if (linesError) {
    return { ok: false as const, error: linesError.message };
  }

  if ((lines ?? []).length < 1) {
    return { ok: false as const, error: "No active dispute lines found." };
  }

  const hasAcceptedOutcome = (lines ?? []).every((line) => line.conversation_status === "retailer_response_received");
  if (!hasAcceptedOutcome) {
    return { ok: false as const, error: "Retailer outcome must be marked as accepted before final outcome acceptance." };
  }

  return { ok: true as const };
}

export async function addDisputeInternalNoteAction(formData: FormData) {
  const disputeId = readString(formData, "dispute_id");
  const body = readString(formData, "body");

  if (!disputeId) redirect("/internal/exceptions");
  if (!body) redirectWithResult(disputeId, { error: "Note body cannot be blank." });

  const guard = await requireActiveStaff();
  if (!guard.ok) redirectWithResult(disputeId, { error: guard.error });

  const { error } = await guard.supabase
    .from("dispute_messages")
    .insert({
      dispute_id: disputeId,
      message_type: "supervisor_note",
      counterparty: "internal",
      body,
      generated_by: "manual",
    });

  if (error) redirectWithResult(disputeId, { error: error.message });

  revalidatePath(`/internal/exceptions/${disputeId}`);
  revalidatePath(`/importer/exceptions/${disputeId}`);
  redirectWithResult(disputeId, { success: "Internal note added." });
}

export async function approveRefundPursuitAction(formData: FormData) {
  const disputeId = readString(formData, "dispute_id");
  if (!disputeId) redirect("/internal/exceptions");

  const guard = await requireActiveStaff();
  if (!guard.ok) redirectWithResult(disputeId, { error: guard.error });

  const { data: dispute, error: disputeError } = await guard.supabase
    .from("disputes")
    .select("id, desired_outcome, refund_approved_at")
    .eq("id", disputeId)
    .maybeSingle();

  if (disputeError || !dispute) redirectWithResult(disputeId, { error: "Dispute not found." });
  if (dispute.desired_outcome !== "refund") redirectWithResult(disputeId, { error: "Refund approval is only available for refund disputes." });
  if (dispute.refund_approved_at) redirectWithResult(disputeId, { error: "Refund pursuit is already approved." });

  const { error } = await guard.supabase
    .from("disputes")
    .update({ refund_approved_by_staff_id: guard.staffId, refund_approved_at: new Date().toISOString() })
    .eq("id", disputeId);

  if (error) redirectWithResult(disputeId, { error: error.message });

  revalidatePath(`/internal/exceptions/${disputeId}`);
  revalidatePath(`/importer/exceptions/${disputeId}`);
  redirectWithResult(disputeId, { success: "Refund pursuit approved." });
}

export async function acceptFinalRefundOutcomeAction(formData: FormData) {
  const disputeId = readString(formData, "dispute_id");
  if (!disputeId) redirect("/internal/exceptions");

  const guard = await requireActiveStaff();
  if (!guard.ok) redirectWithResult(disputeId, { error: guard.error });

  const { data: dispute, error: disputeError } = await guard.supabase
    .from("disputes")
    .select("id, desired_outcome")
    .eq("id", disputeId)
    .maybeSingle();

  if (disputeError || !dispute) redirectWithResult(disputeId, { error: "Dispute not found." });
  if (dispute.desired_outcome !== "refund") redirectWithResult(disputeId, { error: "Final refund outcome is only available for refund disputes." });

  const finalOutcomeGuard = await requireRetailerMessageAndAcceptedOutcome(guard.supabase, disputeId);
  if (!finalOutcomeGuard.ok) redirectWithResult(disputeId, { error: finalOutcomeGuard.error });

  const { error } = await guard.supabase
    .from("disputes")
    .update({ status: "resolved", resolved_at: new Date().toISOString() })
    .eq("id", disputeId);

  if (error) redirectWithResult(disputeId, { error: error.message });

  revalidatePath(`/internal/exceptions/${disputeId}`);
  revalidatePath(`/importer/exceptions/${disputeId}`);
  redirectWithResult(disputeId, { success: "Final refund outcome accepted." });
}

export async function acceptReplacementOutcomeAction(formData: FormData) {
  const disputeId = readString(formData, "dispute_id");
  if (!disputeId) redirect("/internal/exceptions");

  const guard = await requireActiveStaff();
  if (!guard.ok) redirectWithResult(disputeId, { error: guard.error });

  const { data: dispute, error: disputeError } = await guard.supabase
    .from("disputes")
    .select("id, order_id, desired_outcome, replacement_child_order_id")
    .eq("id", disputeId)
    .maybeSingle();

  if (disputeError || !dispute) redirectWithResult(disputeId, { error: "Dispute not found." });
  if (dispute.desired_outcome !== "replacement") redirectWithResult(disputeId, { error: "Replacement outcome is only available for replacement disputes." });
  if (dispute.replacement_child_order_id) redirectWithResult(disputeId, { error: "Replacement child order already exists." });

  const finalOutcomeGuard = await requireRetailerMessageAndAcceptedOutcome(guard.supabase, disputeId);
  if (!finalOutcomeGuard.ok) redirectWithResult(disputeId, { error: finalOutcomeGuard.error });

  const { data: parentOrder, error: parentOrderError } = await guard.supabase
    .from("orders")
    .select("id, order_ref, importer_id, operator_id, shipper_id, retailer_id, destination_hub_id, sop_version")
    .eq("id", dispute.order_id)
    .maybeSingle();

  if (parentOrderError || !parentOrder) redirectWithResult(disputeId, { error: "Parent order not found." });

  const { count: childCount, error: childCountError } = await guard.supabase
    .from("orders")
    .select("id", { count: "exact", head: true })
    .eq("parent_order_id", parentOrder.id);

  if (childCountError) redirectWithResult(disputeId, { error: childCountError.message });

  let sequence = Number(childCount ?? 0) + 1;
  let childOrderRef = `${parentOrder.order_ref}-R${sequence}`;

  while (true) {
    const { data: existingRef, error: existingRefError } = await guard.supabase
      .from("orders")
      .select("id")
      .eq("order_ref", childOrderRef)
      .limit(1)
      .maybeSingle();

    if (existingRefError) redirectWithResult(disputeId, { error: existingRefError.message });
    if (!existingRef) break;

    sequence += 1;
    childOrderRef = `${parentOrder.order_ref}-R${sequence}`;
  }

  const { data: childOrder, error: childInsertError } = await guard.supabase
    .from("orders")
    .insert({
      order_ref: childOrderRef,
      importer_id: parentOrder.importer_id,
      operator_id: parentOrder.operator_id,
      shipper_id: parentOrder.shipper_id,
      retailer_id: parentOrder.retailer_id,
      destination_hub_id: parentOrder.destination_hub_id,
      parent_order_id: parentOrder.id,
      order_type: "replacement_child",
      order_total_gbp_declared: 0,
      total_qty_declared: 0,
      status: "evidence_collecting",
      sop_version: parentOrder.sop_version,
    })
    .select("id")
    .single();

  if (childInsertError || !childOrder) redirectWithResult(disputeId, { error: childInsertError?.message ?? "Failed to create replacement child order." });

  const now = new Date().toISOString();
  const { error: disputeUpdateError } = await guard.supabase
    .from("disputes")
    .update({ replacement_child_order_id: childOrder.id, status: "resolved", resolved_at: now })
    .eq("id", disputeId);

  if (disputeUpdateError) redirectWithResult(disputeId, { error: disputeUpdateError.message });

  const { error: resolveLinesError } = await guard.supabase
    .from("dispute_lines")
    .update({
      resolved_via_child_order_id: childOrder.id,
      conversation_status: "resolved_replacement",
      resolution_method: "replacement",
      resolved_at: now,
    })
    .eq("dispute_id", disputeId)
    .is("resolved_at", null);

  if (resolveLinesError) redirectWithResult(disputeId, { error: resolveLinesError.message });

  revalidatePath(`/internal/exceptions/${disputeId}`);
  revalidatePath(`/importer/exceptions/${disputeId}`);
  revalidatePath("/internal/exceptions");
  redirectWithResult(disputeId, { success: "Replacement outcome accepted and child order created." });
}
