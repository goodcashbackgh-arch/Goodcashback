"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

function redirectWithResult(params: Record<string, string>): never {
  const query = new URLSearchParams(params);
  redirect(`/internal/adjustments?${query.toString()}`);
}

async function requireSupervisorOrAdmin() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    return { ok: false as const, supabase, error: "Please sign in again." };
  }

  const { data: staff, error } = await supabase
    .from("staff")
    .select("id, role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (error || !staff) {
    return { ok: false as const, supabase, error: "Active staff user not found." };
  }

  if (!["admin", "supervisor"].includes(String(staff.role_type))) {
    return { ok: false as const, supabase, error: "Only admin or supervisor staff can approve adjustments." };
  }

  return { ok: true as const, supabase, staffId: staff.id };
}

export async function approveOrderValueAdjustmentAction(formData: FormData) {
  const adjustmentId = readString(formData, "adjustment_id");
  if (!adjustmentId) {
    redirectWithResult({ error: "Missing adjustment reference." });
  }

  const guard = await requireSupervisorOrAdmin();
  if (!guard.ok) {
    redirectWithResult({ error: guard.error });
  }

  const { error } = await guard.supabase
    .from("order_value_adjustments")
    .update({
      approval_status: "approved",
      approved_by_staff_id: guard.staffId,
      approved_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    })
    .eq("id", adjustmentId)
    .eq("approval_status", "pending_supervisor");

  if (error) {
    redirectWithResult({ error: error.message });
  }

  revalidatePath("/internal/adjustments");
  revalidatePath("/importer");
  redirectWithResult({ success: "Adjustment approved." });
}

export async function rejectOrderValueAdjustmentAction(formData: FormData) {
  const adjustmentId = readString(formData, "adjustment_id");
  const note = readString(formData, "note");
  if (!adjustmentId) {
    redirectWithResult({ error: "Missing adjustment reference." });
  }

  const guard = await requireSupervisorOrAdmin();
  if (!guard.ok) {
    redirectWithResult({ error: guard.error });
  }

  const { error } = await guard.supabase
    .from("order_value_adjustments")
    .update({
      approval_status: "rejected",
      approved_by_staff_id: null,
      approved_at: null,
      notes: note || "Rejected by supervisor.",
      updated_at: new Date().toISOString(),
    })
    .eq("id", adjustmentId)
    .eq("approval_status", "pending_supervisor");

  if (error) {
    redirectWithResult({ error: error.message });
  }

  revalidatePath("/internal/adjustments");
  revalidatePath("/importer");
  redirectWithResult({ success: "Adjustment rejected." });
}
