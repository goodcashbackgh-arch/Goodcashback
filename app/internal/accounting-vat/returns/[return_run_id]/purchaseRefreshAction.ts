"use server";

import { redirect } from "next/navigation";
import { revalidatePath } from "next/cache";
import { createClient } from "@/utils/supabase/server";

function value(input: unknown): string {
  return typeof input === "string" ? input.trim() : "";
}

export async function refreshVatPurchaseSourceLinesAction(formData: FormData) {
  const runId = value(formData.get("vat_return_run_id"));
  if (!runId) redirect("/internal/accounting-vat?vatError=Missing%20VAT%20return%20run%20id");

  const supabase = await createClient();
  const { error } = await (supabase as any).rpc("staff_refresh_vat_purchase_source_lines_v1", {
    p_vat_return_run_id: runId,
  });

  if (error) {
    redirect(`/internal/accounting-vat/returns/${runId}?tab=purchases&vatError=${encodeURIComponent(error.message || "Purchase source refresh failed")}`);
  }

  revalidatePath("/internal/accounting-vat");
  revalidatePath(`/internal/accounting-vat/returns/${runId}`);
  redirect(`/internal/accounting-vat/returns/${runId}?tab=purchases`);
}
