"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

function redirectWithResult(evidenceId: string, params: Record<string, string>): never {
  const query = new URLSearchParams(params);
  redirect(`/importer/refund-evidence-review/${evidenceId}?${query.toString()}`);
}

async function requireActiveOperator() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) return { supabase, ok: false as const, error: "Please sign in again." };

  const { data: operator, error } = await supabase
    .from("operators")
    .select("id")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (error || !operator) return { supabase, ok: false as const, error: error?.message ?? "Active operator account not found." };
  return { supabase, ok: true as const };
}

export async function confirmRefundEvidenceOperatorReviewAction(formData: FormData) {
  const evidenceId = readString(formData, "evidence_id");
  const disputeId = readString(formData, "dispute_id");
  const reviewDecision = readString(formData, "review_decision") || "confirmed_clean";
  const notes = readString(formData, "notes");

  if (!evidenceId || !disputeId) redirect("/importer");
  if (!["confirmed_clean", "needs_supervisor_review"].includes(reviewDecision)) {
    redirectWithResult(evidenceId, { error: "Invalid review decision." });
  }

  const guard = await requireActiveOperator();
  if (!guard.ok) redirectWithResult(evidenceId, { error: guard.error });

  const { data: evidence, error: evidenceError } = await guard.supabase
    .from("dispute_messages")
    .select("id, dispute_id, message_type")
    .eq("id", evidenceId)
    .eq("dispute_id", disputeId)
    .maybeSingle();

  if (evidenceError || !evidence) redirectWithResult(evidenceId, { error: evidenceError?.message ?? "Refund evidence not found." });
  if (!["credit_note_evidence", "refund_evidence"].includes(String(evidence.message_type))) {
    redirectWithResult(evidenceId, { error: "Only refund or credit-note evidence can be reviewed here." });
  }

  const { data, error } = await guard.supabase.rpc("operator_confirm_refund_evidence_review", {
    p_source_dispute_message_id: evidenceId,
    p_review_decision: reviewDecision,
    p_notes: notes || null,
  });

  if (error) redirectWithResult(evidenceId, { error: error.message });
  if (!data?.ok) redirectWithResult(evidenceId, { error: "Failed to save operator refund evidence review." });

  revalidatePath(`/importer/refund-evidence-review/${evidenceId}`);
  revalidatePath(`/importer/exceptions/${disputeId}`);
  revalidatePath("/internal/supplier-draft-ready");
  redirectWithResult(evidenceId, {
    success:
      reviewDecision === "confirmed_clean"
        ? "Refund evidence confirmed clean and released for supplier current-control review."
        : "Refund evidence marked for supervisor review.",
  });
}
