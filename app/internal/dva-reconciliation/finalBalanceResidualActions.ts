"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { allocateStatementLineToFxCardOrFeeAction as allocateExistingOutResidualAction } from "./actions";

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

function redirectWithResult(params: Record<string, string>, path: string): never {
  const safePath = path.startsWith("/internal/dva-reconciliation")
    ? path
    : "/internal/dva-reconciliation/workspace";
  const query = new URLSearchParams(params);
  const separator = safePath.includes("?") ? "&" : "?";
  redirect(`${safePath}${separator}${query.toString()}`);
}

export async function allocateStatementLineResidualAction(formData: FormData) {
  const supabase = await createClient();
  const returnPath = readString(formData, "return_path");
  const statementLineId = readString(formData, "dva_statement_line_id");
  const allocationType = readString(formData, "allocation_type") || "fx_card_difference";
  const amountRaw = readString(formData, "allocated_gbp_amount");
  const notes = readString(formData, "notes") || null;
  const allocatedAmount = Number(amountRaw);

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirectWithResult(
      { allocation_error: "Please sign in again before allocating FX/card/fee difference." },
      returnPath,
    );
  }

  if (!statementLineId) {
    redirectWithResult({ allocation_error: "Missing statement line reference." }, returnPath);
  }

  if (!["fx_card_difference", "bank_fee"].includes(allocationType)) {
    redirectWithResult(
      { allocation_error: "Unsupported allocation type for FX/card/fee allocation." },
      returnPath,
    );
  }

  if (!Number.isFinite(allocatedAmount) || allocatedAmount <= 0) {
    redirectWithResult(
      { allocation_error: "Allocation amount must be greater than zero." },
      returnPath,
    );
  }

  const { data: summaryRow, error: summaryError } = await supabase
    .from("dva_statement_line_allocation_summary_vw")
    .select("direction")
    .eq("dva_statement_line_id", statementLineId)
    .single();

  if (summaryError) {
    redirectWithResult({ allocation_error: summaryError.message }, returnPath);
  }

  // Preserve the established OUT residual path exactly. All its existing
  // server-side guards and RPC behaviour remain authoritative.
  if (summaryRow?.direction === "out") {
    return allocateExistingOutResidualAction(formData);
  }

  if (summaryRow?.direction !== "in") {
    redirectWithResult(
      { allocation_error: "Residual allocation requires an IN or OUT statement line." },
      returnPath,
    );
  }

  // IN residuals are only allowed by the dedicated DB classifier, which proves
  // this line already has exactly one confirmed final_balance_payment, the
  // linked order final balance is zero, and canonical remaining is sufficient.
  const { data, error } = await supabase.rpc("staff_classify_final_balance_in_residual_v1", {
    p_dva_statement_line_id: statementLineId,
    p_allocation_type: allocationType,
    p_allocated_gbp_amount: allocatedAmount,
    p_notes: notes,
  });

  if (error) {
    redirectWithResult({ allocation_error: error.message }, returnPath);
  }

  revalidatePath("/internal/dva-reconciliation");
  revalidatePath("/internal/dva-reconciliation/workspace");
  revalidatePath("/internal/dva-reconciliation/allocations");

  const appliedAmount =
    typeof data === "object" &&
    data !== null &&
    "allocated_gbp_amount" in data
      ? String((data as { allocated_gbp_amount?: unknown }).allocated_gbp_amount)
      : allocatedAmount.toFixed(2);

  redirectWithResult(
    { allocation_success: `Allocated £${appliedAmount} to ${allocationType.replaceAll("_", " ")}.` },
    returnPath,
  );
}
