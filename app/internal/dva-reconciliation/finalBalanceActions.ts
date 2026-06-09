"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { headers } from "next/headers";
import { createClient } from "@/utils/supabase/server";

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

function redirectWithResult(params: Record<string, string>, path = "/internal/dva-reconciliation/workspace"): never {
  const query = new URLSearchParams(params);
  const separator = path.includes("?") ? "&" : "?";
  redirect(`${path}${separator}${query.toString()}`);
}

async function returnPath(formData: FormData) {
  const requested = readString(formData, "return_path");
  if (requested.startsWith("/internal/dva-reconciliation")) return requested;

  const headerStore = await headers();
  const referer = headerStore.get("referer");
  if (referer) {
    try {
      const url = new URL(referer);
      if (url.pathname.startsWith("/internal/dva-reconciliation")) {
        return `${url.pathname}${url.search}`;
      }
    } catch {
      // Fall through to default workspace path.
    }
  }

  return "/internal/dva-reconciliation/workspace";
}

export async function allocateStatementLineToFinalBalancePaymentAction(formData: FormData) {
  const supabase = await createClient();
  const path = await returnPath(formData);

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirectWithResult({ allocation_error: "Please sign in again before allocating the final balance payment." }, path);
  }

  const statementLineId = readString(formData, "dva_statement_line_id");
  const orderId = readString(formData, "order_id");
  const classifyFxExcess = readString(formData, "classify_fx_excess") !== "false";
  const notes = readString(formData, "notes") || null;

  if (!statementLineId || !orderId) {
    redirectWithResult({ allocation_error: "Missing statement line or order reference for final balance allocation." }, path);
  }

  const { data, error } = await supabase.rpc("staff_allocate_statement_line_to_final_balance_payment_v1", {
    p_dva_statement_line_id: statementLineId,
    p_order_id: orderId,
    p_classify_fx_excess: classifyFxExcess,
    p_notes: notes,
  });

  if (error) {
    redirectWithResult({ allocation_error: error.message }, path);
  }

  revalidatePath("/internal/dva-reconciliation");
  revalidatePath("/internal/dva-reconciliation/workspace");
  revalidatePath("/internal/dva-reconciliation/allocations");

  const amountToBalance =
    typeof data === "object" && data !== null && "amount_to_final_balance_gbp" in data
      ? String((data as { amount_to_final_balance_gbp?: unknown }).amount_to_final_balance_gbp)
      : "0.00";

  const fxClassified =
    typeof data === "object" && data !== null && "fx_excess_classified_gbp" in data
      ? Number((data as { fx_excess_classified_gbp?: unknown }).fx_excess_classified_gbp)
      : 0;

  redirectWithResult(
    {
      allocation_success:
        fxClassified > 0
          ? `Allocated £${amountToBalance} to final balance and £${fxClassified.toFixed(2)} as FX/card difference.`
          : `Allocated £${amountToBalance} to final balance.`,
    },
    path
  );
}
