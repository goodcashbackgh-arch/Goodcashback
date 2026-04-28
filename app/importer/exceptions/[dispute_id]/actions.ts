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
  redirect(`/importer/exceptions/${disputeId}?${query.toString()}`);
}

const OUTCOME_TO_STATUS: Record<string, string> = {
  still_waiting: "retailer_contacted",
  retailer_accepted: "retailer_response_received",
  retailer_disputed: "awaiting_retailer_resolution",
  more_info_requested: "retailer_draft_ready",
};

async function requireActiveOperator() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    return { supabase, ok: false as const, error: "Please sign in again." };
  }

  const { data: operator } = await supabase
    .from("operators")
    .select("id")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!operator) {
    return { supabase, ok: false as const, error: "Active operator account not found." };
  }

  return { supabase, ok: true as const, operatorId: operator.id };
}

async function requireDisputeAccess(supabase: Awaited<ReturnType<typeof createClient>>, operatorId: string, disputeId: string) {
  const { data: dispute, error: disputeError } = await supabase
    .from("disputes")
    .select("id, order_id")
    .eq("id", disputeId)
    .maybeSingle();

  if (disputeError || !dispute) {
    return { ok: false as const, error: "Dispute not found." };
  }

  const { data: order, error: orderError } = await supabase
    .from("orders")
    .select("id, importer_id")
    .eq("id", dispute.order_id)
    .maybeSingle();

  if (orderError || !order?.importer_id) {
    return { ok: false as const, error: "Dispute order importer could not be resolved." };
  }

  const { data: importerAccess, error: importerAccessError } = await supabase
    .from("operator_importers")
    .select("id")
    .eq("operator_id", operatorId)
    .eq("importer_id", order.importer_id)
    .is("revoked_at", null)
    .limit(1)
    .maybeSingle();

  if (importerAccessError || !importerAccess) {
    return { ok: false as const, error: "You are not authorised to update this dispute." };
  }

  return { ok: true as const };
}

export async function saveRetailerUpdateAction(formData: FormData) {
  const disputeId = readString(formData, "dispute_id");
  const outcome = readString(formData, "retailer_outcome");
  const response = readString(formData, "retailer_response");

  if (!disputeId) redirect("/importer");
  if (!OUTCOME_TO_STATUS[outcome]) redirectWithResult(disputeId, { error: "Invalid retailer outcome selection." });

  const guard = await requireActiveOperator();
  if (!guard.ok) redirectWithResult(disputeId, { error: guard.error });

  const accessGuard = await requireDisputeAccess(guard.supabase, guard.operatorId, disputeId);
  if (!accessGuard.ok) redirectWithResult(disputeId, { error: accessGuard.error });

  const { data, error } = await guard.supabase.rpc("operator_update_dispute_retailer_update", {
    p_dispute_id: disputeId,
    p_retailer_response: response,
    p_retailer_outcome: outcome,
  });

  if (error) redirectWithResult(disputeId, { error: error.message });
  if (!data?.ok) redirectWithResult(disputeId, { error: "Failed to save retailer update." });

  revalidatePath(`/importer/exceptions/${disputeId}`);
  revalidatePath(`/internal/exceptions/${disputeId}`);
  redirectWithResult(disputeId, { success: "Retailer update saved." });
}
