"use server";

import { redirect } from "next/navigation";
import { revalidatePath } from "next/cache";
import { createClient } from "@/utils/supabase/server";

function value(input: unknown): string {
  return typeof input === "string" ? input.trim() : "";
}

function jsonNumber(input: unknown): number {
  if (typeof input === "number" && Number.isFinite(input)) return input;
  if (typeof input === "string" && input.trim()) {
    const parsed = Number(input);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

export async function materialiseVatAdjustmentJournalQueueAction(formData: FormData) {
  const runId = value(formData.get("vat_return_run_id"));
  if (!runId) redirect("/internal/accounting-vat?vatError=Missing%20VAT%20return%20run%20id");

  const supabase = await createClient();
  const { data, error } = await (supabase as any).rpc("staff_materialise_vat_adjustment_journal_proposals_v1", {
    p_vat_return_run_id: runId,
    p_tolerance_gbp: 0.01,
  });

  revalidatePath("/internal/accounting-vat");
  revalidatePath(`/internal/accounting-vat/returns/${runId}`);

  if (error) {
    redirect(`/internal/accounting-vat/returns/${runId}?tab=journals&vatError=${encodeURIComponent(error.message || "VAT adjustment journal queue creation failed")}`);
  }

  const result = data as Record<string, unknown> | null;
  const createdCount = jsonNumber(result?.created_count);
  const status = value(result?.status) || "completed";
  const message = createdCount > 0
    ? `Created ${createdCount} VAT adjustment journal(s). Open each journal to dry-run validate and approve.`
    : `No VAT adjustment journal created: ${status}.`;

  redirect(`/internal/accounting-vat/returns/${runId}?tab=journals&vatSuccess=${encodeURIComponent(message)}`);
}
