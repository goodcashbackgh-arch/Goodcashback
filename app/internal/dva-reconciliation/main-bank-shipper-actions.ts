"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { headers } from "next/headers";
import { createClient } from "@/utils/supabase/server";

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
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
      // Fall through to the fixed review path.
    }
  }

  return "/internal/dva-reconciliation/allocations";
}

function redirectWithResult(path: string, params: Record<string, string>): never {
  const query = new URLSearchParams(params);
  const separator = path.includes("?") ? "&" : "?";
  redirect(`${path}${separator}${query.toString()}`);
}

export async function reverseMainBankShipperAllocationAction(formData: FormData) {
  const supabase = await createClient();
  const path = await returnPath(formData);

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirectWithResult(path, {
      allocation_error: "Please sign in again before reversing the main-bank shipper allocation.",
    });
  }

  const allocationId = readString(formData, "allocation_id");
  const reversalReason = readString(formData, "reversal_reason");

  if (!allocationId) {
    redirectWithResult(path, { allocation_error: "Missing allocation reference." });
  }

  if (reversalReason.length < 8) {
    redirectWithResult(path, {
      allocation_error: "Enter a reversal reason of at least 8 characters.",
    });
  }

  const { data, error } = await supabase.rpc(
    "staff_reverse_main_bank_shipper_ap_allocation_v1",
    {
      p_allocation_id: allocationId,
      p_reversal_reason: reversalReason,
    }
  );

  if (error) {
    redirectWithResult(path, { allocation_error: error.message });
  }

  revalidatePath("/internal/dva-reconciliation");
  revalidatePath("/internal/dva-reconciliation/main-bank");
  revalidatePath("/internal/dva-reconciliation/allocations");
  revalidatePath("/internal/dva-reconciliation/control-summary");

  const reversedAmount =
    typeof data === "object" &&
    data !== null &&
    "reversed_amount_gbp" in data
      ? String((data as { reversed_amount_gbp?: unknown }).reversed_amount_gbp)
      : "";

  redirectWithResult(path, {
    allocation_success: reversedAmount
      ? `Reversed main-bank shipper allocation of £${reversedAmount}.`
      : "Main-bank shipper allocation reversed.",
  });
}
