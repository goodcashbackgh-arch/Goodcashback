"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

function redirectWithFundingResult(params: Record<string, string>): never {
  const query = new URLSearchParams(params);
  redirect(`/internal/funding?${query.toString()}`);
}

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

export async function applyImporterCreditAction(formData: FormData) {
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirectWithFundingResult({
      credit_error: "Please sign in again before applying credit.",
    });
  }

  const { data: staff, error: staffError } = await supabase
    .from("staff")
    .select("id, role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (staffError || !staff) {
    redirectWithFundingResult({
      credit_error: "Active staff user not found.",
    });
  }

  if (!["admin", "supervisor"].includes(String(staff.role_type))) {
    redirectWithFundingResult({
      credit_error: "Only admin or supervisor staff can apply importer credit.",
    });
  }

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

  const { data, error } = await supabase.rpc("apply_importer_credit_to_order", {
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
