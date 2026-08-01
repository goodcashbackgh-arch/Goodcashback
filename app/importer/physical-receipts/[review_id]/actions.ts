"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

function text(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

export async function submitPhysicalReceiptProposalAction(formData: FormData) {
  const reviewId = text(formData, "review_id");
  const proposalNote = text(formData, "proposal_note");
  const raw = text(formData, "proposals_json");
  if (!reviewId) redirect("/importer/physical-receipts?error=Missing%20review%20identity.");

  let proposals: unknown;
  try {
    proposals = JSON.parse(raw);
  } catch {
    redirect(`/importer/physical-receipts/${reviewId}?error=${encodeURIComponent("Proposal rows are invalid.")}`);
  }

  const supabase = await createClient();
  const { error } = await (supabase as any).rpc("operator_submit_physical_receipt_proposal_v1", {
    p_physical_receipt_review_id: reviewId,
    p_proposals: proposals,
    p_proposal_note: proposalNote,
  });

  if (error) redirect(`/importer/physical-receipts/${reviewId}?error=${encodeURIComponent(error.message)}`);

  revalidatePath("/importer");
  revalidatePath("/importer/physical-receipts");
  revalidatePath(`/importer/physical-receipts/${reviewId}`);
  redirect(`/importer/physical-receipts/${reviewId}?success=${encodeURIComponent("Proposal submitted for supervisor review.")}`);
}
