"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

const PAGE_PATH = "/internal/dva-reconciliation/statement-interpretation";
const SUMMARY_PATH = "/internal/dva-reconciliation/control-summary";

const DIRECTIONS = new Set(["in", "out"]);
const CLASSIFICATIONS = new Set([
  "unclassified",
  "customer_order_funding",
  "supplier_payment",
  "retailer_refund",
  "final_balance_payment",
  "bank_fee",
  "fx_card_difference",
  "completion_loyalty_source_transfer",
  "completion_loyalty_destination_transfer",
  "main_bank_shipper_ap",
  "exception_control",
]);

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

function redirectWithResult(statementLineId: string, params: Record<string, string>): never {
  const query = new URLSearchParams({ line_id: statementLineId, ...params });
  redirect(`${PAGE_PATH}?${query.toString()}`);
}

async function requireSupervisorOrAdmin() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) redirect("/login");

  const { data: staff, error } = await supabase
    .from("staff")
    .select("id, role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (error || !staff) redirect("/auth/check");
  if (!["admin", "supervisor"].includes(String(staff.role_type))) redirect("/internal");

  return supabase;
}

export async function correctStatementLineInterpretationAction(formData: FormData) {
  const statementLineId = readString(formData, "dva_statement_line_id");
  const effectiveDirection = readString(formData, "effective_direction").toLowerCase();
  const economicClassification = readString(formData, "economic_classification").toLowerCase();
  const correctedDisplayDescription = readString(formData, "corrected_display_description") || null;
  const correctionReason = readString(formData, "correction_reason");

  if (!statementLineId) redirect(`${PAGE_PATH}?error=${encodeURIComponent("Missing statement-line ID.")}`);
  if (!DIRECTIONS.has(effectiveDirection)) {
    redirectWithResult(statementLineId, { error: "Effective direction must be IN or OUT." });
  }
  if (!CLASSIFICATIONS.has(economicClassification)) {
    redirectWithResult(statementLineId, { error: "Select a supported economic classification." });
  }
  if (correctionReason.length < 8) {
    redirectWithResult(statementLineId, { error: "Correction reason must contain at least 8 characters." });
  }

  const supabase = await requireSupervisorOrAdmin();
  const { error } = await (supabase as any).rpc("staff_correct_statement_line_interpretation_v1", {
    p_dva_statement_line_id: statementLineId,
    p_effective_direction: effectiveDirection,
    p_economic_classification: economicClassification,
    p_corrected_display_description: correctedDisplayDescription,
    p_correction_reason: correctionReason,
  });

  if (error) redirectWithResult(statementLineId, { error: error.message });

  revalidatePath(PAGE_PATH);
  revalidatePath(SUMMARY_PATH);
  revalidatePath("/internal/dva-reconciliation");
  revalidatePath("/internal/funding");
  revalidatePath("/internal/dva-reconciliation/workspace");
  revalidatePath("/internal/dva-reconciliation/main-bank");

  redirectWithResult(statementLineId, {
    success: "Effective statement interpretation recorded. Raw bank evidence and amount were not changed.",
  });
}
