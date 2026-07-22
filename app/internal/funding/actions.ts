"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

function redirectWithFundingResult(params: Record<string, string>): never {
  const query = new URLSearchParams(params);
  redirect(`/internal/funding?${query.toString()}`);
}

function redirectWithSurplusResult(params: Record<string, string>): never {
  const query = new URLSearchParams(params);
  redirect(`/internal/funding/surplus-evidence?${query.toString()}`);
}

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

type FundingStaff = { id: string; role_type: string | null };

async function requireFundingStaff(resultTarget: "funding" | "surplus", errorKey: string): Promise<{ supabase: Awaited<ReturnType<typeof createClient>>; staff: FundingStaff }> {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const redirectResult = resultTarget === "surplus" ? redirectWithSurplusResult : redirectWithFundingResult;
  const userId = user?.id;

  if (!userId) {
    redirectResult({ [errorKey]: "Please sign in again." });
  }

  const { data: staffRow, error: staffError } = await supabase
    .from("staff")
    .select("id, role_type")
    .eq("auth_user_id", userId)
    .eq("active", true)
    .maybeSingle();

  if (staffError || !staffRow) {
    redirectResult({ [errorKey]: "Active staff user not found." });
  }

  const staff = staffRow as FundingStaff;

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
  const fxGainConfirmed = readString(formData, "confirm_fx_gain") === "yes" || readString(formData, "confirm_overfunding") === "yes";

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

  const { data, error } = exceedsGap
    ? fxGainConfirmed
      ? await supabase.rpc("staff_reconcile_dva_line_to_order_customer_fx_gain_v1", {
        p_dva_statement_line_id: dvaStatementLineId,
        p_order_id: orderId,
        p_reconciled_gbp_amount: reconciledAmount,
        p_match_suggestion_id: matchSuggestionId,
        p_notes: notes,
      })
      : await supabase.rpc("staff_reconcile_dva_line_to_order_pending_surplus_v1", {
        p_dva_statement_line_id: dvaStatementLineId,
        p_order_id: orderId,
        p_reconciled_gbp_amount: reconciledAmount,
        p_match_suggestion_id: matchSuggestionId,
        p_notes: notes,
      })
    : await supabase.rpc("staff_reconcile_dva_line_to_order", {
        p_dva_statement_line_id: dvaStatementLineId,
        p_order_id: orderId,
        p_reconciled_gbp_amount: reconciledAmount,
        p_allow_overfunding: false,
        p_match_suggestion_id: matchSuggestionId,
        p_notes: notes,
      });

  if (error) {
    redirectWithFundingResult({
      dva_error: error.message,
    });
  }

  revalidatePath("/internal/funding");
  revalidatePath("/internal/accounting-command-centre/cash-posting");
  revalidatePath("/internal/dva-reconciliation/workspace");

  const appliedAmount =
    typeof data === "object" &&
    data !== null &&
    "funding_amount_gbp" in data
      ? String((data as { funding_amount_gbp?: unknown }).funding_amount_gbp)
      : typeof data === "object" &&
          data !== null &&
          "reconciled_gbp_amount" in data
        ? String((data as { reconciled_gbp_amount?: unknown }).reconciled_gbp_amount)
        : reconciledAmount.toFixed(2);

  const fxGainAmount =
    typeof data === "object" &&
    data !== null &&
    "fx_gain_gbp" in data
      ? Number((data as { fx_gain_gbp?: unknown }).fx_gain_gbp)
      : 0;

  const pendingSurplusAmount =
    typeof data === "object" && data !== null && "pending_surplus_gbp" in data
      ? Number((data as { pending_surplus_gbp?: unknown }).pending_surplus_gbp)
      : 0;

  const message = Number.isFinite(pendingSurplusAmount) && pendingSurplusAmount > 0
    ? `Reconciled £${appliedAmount} DVA funding to order and preserved £${pendingSurplusAmount.toFixed(2)} as pending evidence-based surplus.`
    : Number.isFinite(fxGainAmount) && fxGainAmount > 0
    ? `Reconciled £${appliedAmount} DVA funding to order and routed £${fxGainAmount.toFixed(2)} surplus as FX gain.`
    : `Reconciled £${appliedAmount} DVA funding to order.`;

  redirectWithFundingResult({
    dva_success: message,
  });
}

export async function confirmSettlementSurplusCreditAction(formData: FormData) {
  const { supabase } = await requireFundingStaff("surplus", "settlement_error");

  const orderId = readString(formData, "order_id");
  const reason = readString(formData, "reason") || "supervisor_confirmed_credit";
  const notes = readString(formData, "notes") || null;

  if (!orderId) {
    redirectWithSurplusResult({ settlement_error: "Missing order id." });
  }

  const { error } = await supabase.rpc("staff_confirm_surplus_from_evidence_min_v1", {
    p_order_id: orderId,
    p_reason: reason,
    p_notes: notes,
  });

  if (error) {
    redirectWithSurplusResult({ settlement_error: error.message });
  }

  revalidatePath("/internal/funding");
  revalidatePath("/internal/funding/surplus-evidence");
  revalidatePath("/customer");
  redirectWithSurplusResult({ settlement_success: "Settlement surplus converted to customer credit." });
}
