"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

const PAGE_PATH = "/internal/dva-reconciliation/reversal-control";

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

function returnPath(statementLineId: string, status: string) {
  const params = new URLSearchParams();
  if (statementLineId) params.set("line_id", statementLineId);
  if (status) params.set("status", status);
  const query = params.toString();
  return `${PAGE_PATH}${query ? `?${query}` : ""}`;
}

function redirectWithResult(path: string, key: "success" | "error", message: string): never {
  const separator = path.includes("?") ? "&" : "?";
  redirect(`${path}${separator}${key}=${encodeURIComponent(message)}`);
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

export async function reverseTreasuryAllocationAction(formData: FormData) {
  const allocationId = readString(formData, "allocation_id");
  const statementLineId = readString(formData, "dva_statement_line_id");
  const currentStatus = readString(formData, "current_status") || "active";
  const reversalReason = readString(formData, "reversal_reason");
  const path = returnPath(statementLineId, currentStatus);

  if (!allocationId || !statementLineId) {
    redirectWithResult(path, "error", "Missing allocation or statement-line reference.");
  }
  if (reversalReason.length < 8) {
    redirectWithResult(path, "error", "Enter a reversal reason of at least 8 characters.");
  }

  const supabase = await requireSupervisorOrAdmin();

  const { data: allocation, error: allocationError } = await supabase
    .from("dva_statement_line_allocations")
    .select("id, dva_statement_line_id, allocation_status, allocated_gbp_amount")
    .eq("id", allocationId)
    .maybeSingle();

  if (allocationError) redirectWithResult(path, "error", allocationError.message);
  if (!allocation || String(allocation.dva_statement_line_id) !== statementLineId) {
    redirectWithResult(path, "error", "Allocation does not belong to the selected statement line.");
  }
  if (!["confirmed", "held"].includes(String(allocation.allocation_status))) {
    redirectWithResult(path, "error", "Only confirmed or held allocations can be reversed.");
  }

  const { data, error } = await supabase.rpc("staff_reverse_dva_statement_line_allocation", {
    p_allocation_id: allocationId,
    p_reversal_reason: reversalReason,
  });

  if (error) redirectWithResult(path, "error", error.message);

  const result = (data ?? {}) as Record<string, unknown>;
  const reversedAmount = Number(result.reversed_amount_gbp ?? allocation.allocated_gbp_amount ?? 0);
  const remainingAfter = Number(result.confirmed_unallocated_after_gbp ?? 0);

  revalidatePath(PAGE_PATH);
  revalidatePath("/internal/dva-reconciliation/control-summary");
  revalidatePath("/internal/dva-reconciliation/statement-interpretation");
  revalidatePath("/internal/dva-reconciliation/sequential-allocation");
  revalidatePath("/internal/dva-reconciliation/allocations");
  revalidatePath("/internal/dva-reconciliation/workspace");
  revalidatePath("/internal/dva-reconciliation");

  redirectWithResult(
    path,
    "success",
    `Reversed £${Number.isFinite(reversedAmount) ? reversedAmount.toFixed(2) : "0.00"}. Statement confirmed-unallocated balance is now £${Number.isFinite(remainingAfter) ? remainingAfter.toFixed(2) : "0.00"}.`,
  );
}
