"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { allocateStatementLineToFxCardOrFeeAction as allocateExistingOutResidualAction } from "./actions";

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

function safeReturnPath(formData: FormData) {
  const requested = readString(formData, "return_path");
  return requested.startsWith("/internal/dva-reconciliation")
    ? requested
    : "/internal/dva-reconciliation/workspace";
}

function redirectWithResult(params: Record<string, string>, path: string): never {
  const query = new URLSearchParams(params);
  const separator = path.includes("?") ? "&" : "?";
  redirect(`${path}${separator}${query.toString()}`);
}

export async function allocateStatementLineFxResidualAction(formData: FormData) {
  const supabase = await createClient();
  const path = safeReturnPath(formData);

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirectWithResult(
      { allocation_error: "Please sign in again before allocating FX/card difference." },
      path,
    );
  }

  const statementLineId = readString(formData, "dva_statement_line_id");
  const allocationType = readString(formData, "allocation_type") || "fx_card_difference";
  const amountRaw = readString(formData, "allocated_gbp_amount");
  const notes = readString(formData, "notes") || null;
  const expectedResidual = Number(amountRaw);

  if (!statementLineId) {
    redirectWithResult({ allocation_error: "Missing statement line reference." }, path);
  }

  const { data: summaryRow, error: summaryError } = await supabase
    .from("dva_statement_line_allocation_summary_vw")
    .select("direction")
    .eq("dva_statement_line_id", statementLineId)
    .single();

  if (summaryError) {
    redirectWithResult({ allocation_error: summaryError.message }, path);
  }

  // Preservation rule: OUT lines continue through the exact existing action and
  // therefore retain all existing OUT-only guards and RPC behaviour unchanged.
  if (summaryRow?.direction === "out") {
    return allocateExistingOutResidualAction(formData);
  }

  if (summaryRow?.direction !== "in") {
    redirectWithResult(
      { allocation_error: "Residual allocation requires an IN or OUT statement line." },
      path,
    );
  }

  // The new sibling route is intentionally FX-only. It is not a general IN
  // residual classifier and does not broaden bank-fee/hold behaviour.
  if (allocationType !== "fx_card_difference") {
    redirectWithResult(
      {
        allocation_error:
          "Final-balance IN residuals can only be classified as FX/card difference in this controlled path.",
      },
      path,
    );
  }

  if (!Number.isFinite(expectedResidual) || expectedResidual <= 0) {
    redirectWithResult(
      { allocation_error: "FX/card residual amount must be greater than zero." },
      path,
    );
  }

  const { data, error } = await supabase.rpc("staff_classify_final_balance_in_fx_residual_v1", {
    p_dva_statement_line_id: statementLineId,
    p_expected_residual_gbp: expectedResidual,
    p_notes: notes,
  });

  if (error) {
    redirectWithResult({ allocation_error: error.message }, path);
  }

  revalidatePath("/internal/dva-reconciliation");
  revalidatePath("/internal/dva-reconciliation/workspace");
  revalidatePath("/internal/dva-reconciliation/allocations");

  const appliedAmount =
    typeof data === "object" &&
    data !== null &&
    "allocated_gbp_amount" in data
      ? String((data as { allocated_gbp_amount?: unknown }).allocated_gbp_amount)
      : expectedResidual.toFixed(2);

  redirectWithResult(
    { allocation_success: `Allocated £${appliedAmount} to FX/card difference.` },
    path,
  );
}
