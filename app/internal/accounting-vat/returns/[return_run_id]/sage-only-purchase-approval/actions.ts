"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

function text(value: unknown): string {
  return typeof value === "string" ? value.trim() : typeof value === "number" && Number.isFinite(value) ? String(value) : "";
}

export async function approveSageOnlyPurchaseBucketsAction(formData: FormData) {
  const runId = text(formData.get("vat_return_run_id"));
  const snapshotId = text(formData.get("sage_snapshot_id"));
  const bucketKeys = formData.getAll("bucket_keys").map(text).filter(Boolean);

  if (!runId) redirect("/internal/accounting-vat?vatError=Missing%20VAT%20return%20run%20id");

  const base = `/internal/accounting-vat/returns/${runId}/sage-only-purchase-approval`;

  if (!snapshotId || bucketKeys.length === 0) {
    redirect(`${base}?vatError=${encodeURIComponent("Select at least one Sage-only bucket to approve.")}`);
  }

  const supabase = await createClient();
  const { error } = await (supabase as any).rpc("staff_approve_sage_only_purchase_buckets_into_vat_return_v1", {
    p_vat_return_run_id: runId,
    p_sage_snapshot_id: snapshotId,
    p_bucket_keys: bucketKeys,
  });

  if (error) {
    redirect(`${base}?vatError=${encodeURIComponent(error.message || "Sage-only purchase approval failed.")}`);
  }

  revalidatePath("/internal/accounting-vat");
  revalidatePath(`/internal/accounting-vat/returns/${runId}`);
  revalidatePath(base);

  redirect(`/internal/accounting-vat/returns/${runId}?tab=purchases&sageOnlyApproved=1`);
}
