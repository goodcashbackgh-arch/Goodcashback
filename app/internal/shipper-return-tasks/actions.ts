"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

export async function reviewShipperReturnTaskConfirmationAction(formData: FormData) {
  const supabase = await createClient();
  const confirmationId = readString(formData, "confirmation_id");
  const decision = readString(formData, "decision");
  const reviewNotes = readString(formData, "review_notes");

  if (!confirmationId) {
    redirect("/internal/shipper-return-tasks?error=Missing%20shipper%20return%20confirmation.");
  }

  if (!["accepted", "hold", "rejected"].includes(decision)) {
    redirect("/internal/shipper-return-tasks?error=Choose%20a%20valid%20review%20decision.");
  }

  const { error } = await (supabase as any).rpc("staff_review_shipper_return_task_confirmation_v1", {
    p_confirmation_id: confirmationId,
    p_review_decision: decision,
    p_review_notes: reviewNotes || null,
  });

  if (error) {
    redirect(`/internal/shipper-return-tasks?error=${encodeURIComponent(error.message)}`);
  }

  revalidatePath("/internal/shipper-return-tasks");
  revalidatePath("/shipper/return-tasks");
  redirect("/internal/shipper-return-tasks?success=Shipper%20return%20proof%20review%20saved.");
}
