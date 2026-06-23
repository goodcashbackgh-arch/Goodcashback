"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { headers } from "next/headers";
import { createClient } from "@/utils/supabase/server";

const PAGE_PATH = "/internal/completion-loyalty-rewards";

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

function readPositiveAmount(formData: FormData, key: string, label: string) {
  const raw = readString(formData, key);
  const value = Number(raw);
  if (!Number.isFinite(value) || value <= 0) {
    redirectWithResult({ error: `${label} must be greater than zero.` });
  }
  return value;
}

function redirectWithResult(params: Record<string, string>, path = PAGE_PATH): never {
  const query = new URLSearchParams(params);
  const separator = path.includes("?") ? "&" : "?";
  redirect(`${path}${separator}${query.toString()}`);
}

async function returnPath() {
  const headerStore = await headers();
  const referer = headerStore.get("referer");
  if (referer) {
    try {
      const url = new URL(referer);
      if (url.pathname === PAGE_PATH) return `${url.pathname}${url.search}`;
    } catch {
      // Ignore malformed referers and use the fixed fallback.
    }
  }
  return PAGE_PATH;
}

async function requireSupervisorOrAdmin() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) redirectWithResult({ error: "Please sign in again before using the completion loyalty reward workbench." });

  const { data: staff, error } = await supabase
    .from("staff")
    .select("id, role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (error || !staff) redirectWithResult({ error: "Active staff access is required for this workbench." });
  if (!["admin", "supervisor"].includes(String(staff.role_type))) {
    redirectWithResult({ error: "Supervisor access is required for this workbench." });
  }

  return supabase;
}

export async function approveCompletionLoyaltyRewardAction(formData: FormData) {
  const path = await returnPath();
  const supabase = await requireSupervisorOrAdmin();

  const orderId = readString(formData, "order_id");
  const approvedAmount = readPositiveAmount(formData, "approved_amount_gbp", "Approved amount");
  const rewardRate = readPositiveAmount(formData, "reward_rate_pct", "Reward rate");
  const notes = readString(formData, "notes") || null;

  if (!orderId) redirectWithResult({ error: "Missing order reference for approval-in-principle." }, path);

  const { error } = await supabase.rpc("staff_approve_completion_loyalty_reward_v1", {
    p_order_id: orderId,
    p_approved_amount_gbp: approvedAmount,
    p_reward_rate_pct: rewardRate,
    p_reason: "completion_loyalty_reward",
    p_notes: notes,
  });

  if (error) redirectWithResult({ error: error.message }, path);

  revalidatePath(PAGE_PATH);
  redirectWithResult({ success: "Completion loyalty reward approval-in-principle recorded." }, path);
}

export async function confirmCompletionLoyaltyRewardFundingAction(formData: FormData) {
  const path = await returnPath();
  const supabase = await requireSupervisorOrAdmin();

  const approvalId = readString(formData, "approval_id");
  const amountFunded = readPositiveAmount(formData, "amount_funded_gbp", "Funded amount");
  const amountReleasedRaw = readString(formData, "amount_released_gbp");
  const amountReleased = amountReleasedRaw ? Number(amountReleasedRaw) : null;
  const dvaStatementLineId = readString(formData, "dva_statement_line_id") || null;
  const fundingEvidenceRef = readString(formData, "funding_evidence_ref") || null;
  const notes = readString(formData, "notes") || null;

  if (!approvalId) redirectWithResult({ error: "Missing approval reference for funding confirmation." }, path);
  if (amountReleased !== null && (!Number.isFinite(amountReleased) || amountReleased <= 0)) {
    redirectWithResult({ error: "Released amount must be greater than zero when provided." }, path);
  }
  if (!dvaStatementLineId && !fundingEvidenceRef) {
    redirectWithResult({ error: "Funding proof required: enter a DVA statement line ID or a funding evidence reference." }, path);
  }

  const { error } = await supabase.rpc("staff_confirm_completion_loyalty_reward_funding_v1", {
    p_approval_id: approvalId,
    p_amount_funded_gbp: amountFunded,
    p_amount_released_gbp: amountReleased,
    p_dva_statement_line_id: dvaStatementLineId,
    p_funding_evidence_ref: fundingEvidenceRef,
    p_notes: notes,
  });

  if (error) redirectWithResult({ error: error.message }, path);

  revalidatePath(PAGE_PATH);
  redirectWithResult({ success: "Funding proof accepted and dashboard credit released." }, path);
}

export async function applyCompletionLoyaltyToOrderAction(formData: FormData) {
  const path = await returnPath();
  const supabase = await requireSupervisorOrAdmin();

  const orderId = readString(formData, "target_order_id");
  const amount = readPositiveAmount(formData, "amount_gbp", "Loyalty amount");
  const notes = readString(formData, "notes") || "Staff applied completion loyalty reward to order balance.";

  if (!orderId) redirectWithResult({ error: "Select the order that should receive the loyalty reward." }, path);

  const { data, error } = await supabase.rpc("staff_apply_completion_loyalty_to_order_v1", {
    p_order_id: orderId,
    p_amount_gbp: amount,
    p_notes: notes,
  });

  if (error) redirectWithResult({ error: error.message }, path);

  const applied = typeof data === "object" && data !== null && "applied_gbp" in data ? Number((data as { applied_gbp?: unknown }).applied_gbp ?? 0) : amount;

  revalidatePath(PAGE_PATH);
  revalidatePath("/customer");
  revalidatePath(`/customer/orders/${orderId}/operations`);
  redirectWithResult({ success: `Completion loyalty reward applied to order balance: £${Number.isFinite(applied) ? applied.toFixed(2) : amount.toFixed(2)}.` }, path);
}
