"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

const BASE_PATH = "/internal/accounting-command-centre/loyalty-controls";

export async function reopenCompletionLoyaltySageBatchAction(formData: FormData) {
  const batchId = String(formData.get("batch_id") ?? "").trim();
  const note = String(formData.get("note") ?? "").trim();

  if (!batchId) {
    throw new Error("Missing batch id.");
  }

  const retirePath = `${BASE_PATH}/batches/${batchId}/retire`;
  const supabase = await createClient();
  const { data, error } = await (supabase as any).rpc("staff_supersede_completion_loyalty_sage_batch_resetless_v1", {
    p_batch_id: batchId,
    p_reason: note || "Retired from batch detail before any Sage object was created.",
  });

  if (error) {
    revalidatePath(retirePath);
    redirect(`${retirePath}?error=${encodeURIComponent(error.message || "Could not retire loyalty Sage batch.")}`);
  }

  const result = (data ?? {}) as Record<string, unknown>;
  const batchRef = String(result.batch_ref ?? batchId);

  revalidatePath(BASE_PATH);
  revalidatePath(`${BASE_PATH}/batches/${batchId}`);
  redirect(`${BASE_PATH}?success=${encodeURIComponent(`Retired loyalty Sage batch ${batchRef}. Create a fresh freeze from Step 3.`)}#step-3-lifecycle`);
}
