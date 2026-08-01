"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

function text(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

export async function decidePhysicalReceiptReviewAction(formData: FormData) {
  const reviewId = text(formData, "review_id");
  const decision = text(formData, "decision");
  const liableParty = text(formData, "liable_party") || "unknown";
  const decisionNote = text(formData, "decision_note");
  const raw = text(formData, "allocations_json") || "[]";
  if (!reviewId) redirect("/internal/physical-receipts?error=Missing%20review%20identity.");

  let allocations: unknown;
  try {
    allocations = JSON.parse(raw);
  } catch {
    redirect(`/internal/physical-receipts/${reviewId}?error=${encodeURIComponent("Decision rows are invalid.")}`);
  }

  const supabase = await createClient();
  const { data, error } = await (supabase as any).rpc("staff_decide_physical_receipt_review_v1", {
    p_review_id: reviewId,
    p_decision: decision,
    p_allocations: allocations,
    p_liable_party: liableParty,
    p_decision_note: decisionNote,
  });

  if (error) redirect(`/internal/physical-receipts/${reviewId}?error=${encodeURIComponent(error.message)}`);

  revalidatePath("/internal");
  revalidatePath("/internal/physical-receipts");
  revalidatePath(`/internal/physical-receipts/${reviewId}`);
  const status = data?.status ? ` Review status: ${data.status}.` : "";
  redirect(`/internal/physical-receipts/${reviewId}?success=${encodeURIComponent(`Supervisor decision recorded.${status}`)}`);
}
