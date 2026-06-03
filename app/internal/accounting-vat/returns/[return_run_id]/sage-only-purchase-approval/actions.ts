"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

function text(value: unknown): string {
  return typeof value === "string" ? value.trim() : typeof value === "number" && Number.isFinite(value) ? String(value) : "";
}

function selectedLineIndexes(formData: FormData): number[] {
  return formData.getAll("selected_line_indexes").flatMap((value) => text(value).split(",")).map((value) => Number(value.trim())).filter((value) => Number.isInteger(value) && value >= 0);
}

export async function approveDirectSagePurchasePostingLinesAction(formData: FormData) {
  const runId = text(formData.get("vat_return_run_id"));
  const snapshotId = text(formData.get("sage_snapshot_id"));
  const indexes = selectedLineIndexes(formData);

  if (!runId) redirect("/internal/accounting-vat?vatError=Missing%20VAT%20return%20run%20id");

  const base = `/internal/accounting-vat/returns/${runId}/sage-only-purchase-approval`;
  const selectedParam = indexes.join(",");
  const retryUrl = `${base}?sage_snapshot_id=${encodeURIComponent(snapshotId)}&selected_line_indexes=${encodeURIComponent(selectedParam)}`;

  if (!snapshotId || indexes.length === 0) {
    redirect(`${base}?vatError=${encodeURIComponent("Select at least one direct Sage posting line to approve.")}`);
  }

  const supabase = await createClient();
  const { error } = await (supabase as any).rpc("staff_approve_direct_sage_purchase_lines_v1", {
    p_vat_return_run_id: runId,
    p_sage_snapshot_id: snapshotId,
    p_selected_line_indexes: indexes,
  });

  if (error) {
    redirect(`${retryUrl}&vatError=${encodeURIComponent(error.message || "Direct Sage posting line approval failed.")}`);
  }

  revalidatePath("/internal/accounting-vat");
  revalidatePath(`/internal/accounting-vat/returns/${runId}`);
  revalidatePath(base);

  redirect(`/internal/accounting-vat/returns/${runId}?tab=purchases&directSageApproved=1`);
}
