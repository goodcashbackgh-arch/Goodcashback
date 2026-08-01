"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

function text(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

type ProposalRow = {
  receipt_line_disposition_id?: unknown;
  proposed_remedy_type?: unknown;
  proposed_remedy_qty?: unknown;
};

const REMEDIES = new Set(["refund", "replacement", "hold_investigate", "no_action"]);

export async function submitPhysicalReceiptProposalAction(formData: FormData) {
  const reviewId = text(formData, "review_id");
  const proposalNote = text(formData, "proposal_note");
  const raw = text(formData, "proposals_json");
  if (!reviewId) redirect("/importer/physical-receipts?error=Missing%20review%20identity.");

  let proposals: ProposalRow[];
  try {
    const parsed: unknown = JSON.parse(raw);
    if (!Array.isArray(parsed) || parsed.length === 0) throw new Error("empty");
    proposals = parsed as ProposalRow[];
  } catch {
    redirect(`/importer/physical-receipts/${reviewId}?error=${encodeURIComponent("Proposal rows are invalid.")}`);
  }

  const invalid = proposals.some((row) =>
    typeof row.receipt_line_disposition_id !== "string"
    || !REMEDIES.has(String(row.proposed_remedy_type ?? ""))
    || typeof row.proposed_remedy_qty !== "number"
    || !Number.isInteger(row.proposed_remedy_qty)
    || row.proposed_remedy_qty <= 0
  );
  if (invalid) {
    redirect(`/importer/physical-receipts/${reviewId}?error=${encodeURIComponent("Every physical remedy proposal quantity must be a positive whole unit.")}`);
  }
  if (!proposalNote) {
    redirect(`/importer/physical-receipts/${reviewId}?error=${encodeURIComponent("A factual proposal note is required.")}`);
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
