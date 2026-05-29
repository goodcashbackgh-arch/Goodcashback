"use server";

import { redirect } from "next/navigation";
import { reconstructSageVatDraftBackendCheckAction } from "./actions";

export async function runVatReconstructionForRunAction(formData: FormData) {
  const runId = String(formData.get("vat_return_run_id") ?? "").trim();
  if (!runId) {
    redirect("/internal/accounting-vat?tab=sage&vatError=Choose%20a%20VAT%20return%20run%20first");
  }

  try {
    const result = await reconstructSageVatDraftBackendCheckAction(runId);
    redirect(`/internal/accounting-vat?tab=sage&vatReconstructed=${encodeURIComponent(result.snapshotId || "1")}`);
  } catch (error) {
    const message = error instanceof Error ? error.message : "VAT reconstruction failed.";
    redirect(`/internal/accounting-vat?tab=sage&vatError=${encodeURIComponent(message)}`);
  }
}
