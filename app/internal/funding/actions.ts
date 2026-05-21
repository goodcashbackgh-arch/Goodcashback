"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

function redirectWithFundingResult(params: Record<string, string>): never {
  const query = new URLSearchParams(params);
  redirect(`/internal/funding?${query.toString()}`);
}

function redirectWithSettlementResult(params: Record<string, string>): never {
  const query = new URLSearchParams(params);
  redirect(`/internal/funding/settlement-surplus?${query.toString()}`);
}

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

async function requireFundingStaff(resultTarget: "funding" | "settlement", errorKey: string) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const redirectResult = resultTarget === "settlement" ? redirectWithSettlementResult : redirectWithFundingResult;
  const userId = user?.id;

  if (!userId) {
    redirectResult({ [errorKey]: "Please sign in again." });
  }

  const { data: staff, error: staffError } = await supabase
    .from("staff")
    .select("id, role_type")
    .eq("auth_user_id", userId)
    .eq("active", true)
    .maybeSingle();

  if (staffError || !staff) {
    redirectResult({ [errorKey]: "Active staff user not found." });
  }

  if (!["admin", "supervisor"].includes(String(staff.role_type))) {
    redirectResult({ [errorKey]: "Only admin or supervisor staff can perform this funding action." });
  }

  return { supabase, staff };
}

export async function applyImporterCreditAction(formData: FormData) {
  const { supabase, staff } = await requireFundingStaff("funding", "credit_error");

  const importerId = readString(formData, "importer_id");
  const orderId = readString(formData, "order_id");
  const amountGbp = Number(readString(formData, "amount_gbp"));

  if (!importerId || !orderId) {
    redirectWithFundingResult({
      credit_error: "Missing importer or order reference.",
    });
  }

  if (!Number.isFinite(amountGbp) || amountGbp <= 0) {
    redirectWithFundingResult({
      credit_error: "Credit amount must be greater than zero.",
    });
  }

  const { data, error } = await supabase.rpc("staff_apply_importer_credit_to_order", {
    p_importer_id: importerId,
    p_order_id: orderId,
    p_amount_gbp: amountGbp,
    p_staff_id: staff.id,
  });

  if (error) {
    redirectWithFundingResult({
      credit_error: error.message,
    });
  }

  revalidatePath("/internal/funding");

  const appliedAmount =
    typeof data === "object" &&
    data !== null &&
    "applied_amount_gbp" in data
      ? String((data as { applied_amount_gbp?: unknown }).applied_amount_gbp)
      : amountGbp.toFixed(2);

  redirectWithFundingResult({
    credit_success: `Applied £${appliedAmount} importer credit.`,
  });
}

export async function reconcileDvaLineToOrderAction(formData: FormData) {
  const { supabase } = await requireFundingStaff("funding", "dva_error");

  const dvaStatementLineId = readString(formData, "dva_statement_line_id");
  const orderId = readString(formData, "order_id");
  const parsedAmount = readString(formData, "reconciled_gbp_amount");
  const parsedGap = Number(readString(formData, "gap_remaining_gbp"));
  const matchSuggestionId = readString(formData, "match_suggestion_id") || null;
  const notes = readString(formData, "notes") || null;
  const overfundingConfirmed = readString(formData, "confirm_overfunding") === "yes";

  if (!dvaStatementLineId || !orderId) {
    redirectWithFundingResult({
      dva_error: "Missing DVA statement line or order reference.",
    });
  }

  const reconciledAmount = parsedAmount === "" ? Number.NaN : Number(parsedAmount);
  if (!Number.isFinite(reconciledAmount) || reconciledAmount <= 0) {
    redirectWithFundingResult({
      dva_error: "Reconcile amount must be greater than zero.",
    });
  }

  const exceedsGap =
    Number.isFinite(parsedGap) && parsedGap >= 0 && reconciledAmount > parsedGap;
  const allowOverfunding = exceedsGap ? overfundingConfirmed : false;

  if (exceedsGap && !overfundingConfirmed) {
    redirectWithFundingResult({
      dva_error:
        "Amount exceeds remaining gap. Confirm overfunding before reconciliation.",
    });
  }

  const { data, error } = await supabase.rpc("staff_reconcile_dva_line_to_order", {
    p_dva_statement_line_id: dvaStatementLineId,
    p_order_id: orderId,
    p_reconciled_gbp_amount: reconciledAmount,
    p_allow_overfunding: allowOverfunding,
    p_match_suggestion_id: matchSuggestionId,
    p_notes: notes,
  });

  if (error) {
    redirectWithFundingResult({
      dva_error: error.message,
    });
  }

  revalidatePath("/internal/funding");

  const appliedAmount =
    typeof data === "object" &&
    data !== null &&
    "reconciled_gbp_amount" in data
      ? String((data as { reconciled_gbp_amount?: unknown }).reconciled_gbp_amount)
      : reconciledAmount.toFixed(2);

  redirectWithFundingResult({
    dva_success: `Reconciled £${appliedAmount} DVA funding to order.`,
  });
}

export async function confirmSettlementSurplusCreditAction(formData: FormData) {
  const { supabase } = await requireFundingStaff("settlement", "settlement_error");

  const orderId = readString(formData, "order_id");
  const reason = readString(formData, "reason") || "supervisor_confirmed_credit";
  const notes = readString(formData, "notes") || null;

  if (!orderId) {
    redirectWithSettlementResult({ settlement_error: "Missing order id." });
  }

  const { error } = await supabase.rpc("staff_confirm_surplus_from_evidence_min_v1", {
    p_order_id: orderId,
    p_reason: reason,
    p_notes: notes,
  });

  if (error) {
    redirectWithSettlementResult({ settlement_error: error.message });
  }

  revalidatePath("/internal/funding");
  revalidatePath("/internal/funding/settlement-surplus");
  revalidatePath("/internal/funding/surplus-evidence");
  revalidatePath("/customer");
  redirectWithSettlementResult({ settlement_success: "Settlement surplus converted to customer credit." });
}
