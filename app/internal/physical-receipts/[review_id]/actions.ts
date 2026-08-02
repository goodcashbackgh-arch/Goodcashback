"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

function text(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

type AllocationRow = {
  remedy_allocation_id?: unknown;
  approved_remedy_type?: unknown;
  approved_remedy_qty?: unknown;
  supplier_cost_mode?: unknown;
};

const DECISIONS = new Set(["return_for_information", "reject", "close_no_action", "approve_investigation", "approve_existing_exception"]);
const LIABLE = new Set(["retailer", "shipper", "unknown", "no_liability"]);

function destination(reviewId: string, message: string) {
  return `/internal/physical-receipts/${reviewId}?error=${encodeURIComponent(message)}`;
}

export async function decidePhysicalReceiptReviewAction(formData: FormData) {
  const reviewId = text(formData, "review_id");
  const decision = text(formData, "decision");
  const liableParty = text(formData, "liable_party") || "unknown";
  const decisionNote = text(formData, "decision_note");
  const raw = text(formData, "allocations_json") || "[]";
  if (!reviewId) redirect("/internal/physical-receipts?error=Missing%20review%20identity.");
  if (!DECISIONS.has(decision)) redirect(destination(reviewId, "Unsupported supervisor decision."));
  if (!LIABLE.has(liableParty)) redirect(destination(reviewId, "Invalid liable party."));
  if (!decisionNote) redirect(destination(reviewId, "A factual supervisor decision note is required."));

  let allocations: AllocationRow[];
  try {
    const parsed: unknown = JSON.parse(raw);
    if (!Array.isArray(parsed)) throw new Error("shape");
    allocations = parsed as AllocationRow[];
  } catch {
    redirect(destination(reviewId, "Decision rows are invalid."));
  }

  const noAllocationDecision = decision === "return_for_information" || decision === "reject";
  if (noAllocationDecision && allocations.length !== 0) redirect(destination(reviewId, "Return and reject decisions must not contain allocation approvals."));
  if (!noAllocationDecision && allocations.length === 0) redirect(destination(reviewId, "This decision requires an explicit decision for every importer proposal row."));
  if (decision === "close_no_action" && liableParty !== "no_liability") redirect(destination(reviewId, "Close-no-action requires no liability."));
  if (decision === "approve_existing_exception" && liableParty === "no_liability") redirect(destination(reviewId, "Refund or replacement approval cannot use no liability."));

  const invalid = allocations.some((row) => {
    const remedy = String(row.approved_remedy_type ?? "");
    const quantity = row.approved_remedy_qty;
    const costMode = String(row.supplier_cost_mode ?? "");
    if (typeof row.remedy_allocation_id !== "string" || typeof quantity !== "number" || !Number.isInteger(quantity) || quantity <= 0) return true;
    if (decision === "approve_investigation" && remedy !== "hold_investigate") return true;
    if (decision === "close_no_action" && remedy !== "no_action") return true;
    if (decision === "approve_existing_exception" && !["refund", "replacement"].includes(remedy)) return true;
    if (remedy === "replacement") return !["free_replacement", "charged_repurchase", "pending_supplier_evidence"].includes(costMode);
    return costMode !== "not_applicable";
  });
  if (invalid) redirect(destination(reviewId, "One or more supervisor decision rows are incompatible with the selected decision or are not positive whole units."));

  const supabase = await createClient();
  const { data, error } = await (supabase as any).rpc("staff_decide_physical_receipt_review_v2", {
    p_review_id: reviewId,
    p_decision: decision,
    p_allocations: allocations,
    p_liable_party: liableParty,
    p_decision_note: decisionNote,
  });

  if (error) redirect(destination(reviewId, error.message));

  revalidatePath("/internal");
  revalidatePath("/internal/physical-receipts");
  revalidatePath(`/internal/physical-receipts/${reviewId}`);
  const status = data?.status ? ` Review status: ${data.status}.` : "";
  redirect(`/internal/physical-receipts/${reviewId}?success=${encodeURIComponent(`Supervisor decision recorded.${status}`)}`);
}
