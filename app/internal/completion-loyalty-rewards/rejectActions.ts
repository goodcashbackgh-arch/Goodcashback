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
      // Use fallback below.
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

export async function rejectCompletionLoyaltyRewardAction(formData: FormData) {
  const path = await returnPath();
  const supabase = await requireSupervisorOrAdmin();

  const orderId = readString(formData, "order_id");
  const reasonCode = readString(formData, "rejection_reason_code");
  const notes = readString(formData, "notes") || null;

  if (!orderId) redirectWithResult({ error: "Missing order reference for rejection." }, path);
  if (!reasonCode) redirectWithResult({ error: "Select a rejection reason before rejecting the reward." }, path);

  const { data, error } = await supabase.rpc("staff_reject_completion_loyalty_reward_v1", {
    p_order_id: orderId,
    p_rejection_reason_code: reasonCode,
    p_notes: notes,
  });

  if (error) redirectWithResult({ error: error.message }, path);

  const orderRef = typeof data === "object" && data !== null && "order_ref" in data ? String((data as { order_ref?: unknown }).order_ref ?? "") : "";

  revalidatePath(PAGE_PATH);
  revalidatePath("/customer");
  redirectWithResult({ success: `Completion loyalty reward rejected in principle${orderRef ? ` for ${orderRef}` : ""}.` }, path);
}
