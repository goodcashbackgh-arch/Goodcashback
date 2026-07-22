"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

const PAGE_PATH = "/internal/dva-reconciliation/sequential-allocation";

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

function returnPath(statementLineId: string, orderId: string) {
  const params = new URLSearchParams();
  if (statementLineId) params.set("line_id", statementLineId);
  if (orderId) params.set("order_id", orderId);
  const query = params.toString();
  return `${PAGE_PATH}${query ? `?${query}` : ""}`;
}

function redirectWithResult(path: string, params: Record<string, string>): never {
  const separator = path.includes("?") ? "&" : "?";
  redirect(`${path}${separator}${new URLSearchParams(params).toString()}`);
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

export async function allocateNextSupplierInvoiceAction(formData: FormData) {
  const statementLineId = readString(formData, "dva_statement_line_id");
  const supplierInvoiceId = readString(formData, "supplier_invoice_id");
  const orderId = readString(formData, "order_id");
  const amountRaw = readString(formData, "allocated_gbp_amount");
  const notes = readString(formData, "notes") || null;
  const amount = Number(amountRaw);
  const path = returnPath(statementLineId, orderId);

  if (!statementLineId || !supplierInvoiceId) {
    redirectWithResult(path, { error: "Select a statement OUT and supplier invoice." });
  }
  if (!Number.isFinite(amount) || amount <= 0) {
    redirectWithResult(path, { error: "Allocation amount must be greater than zero." });
  }

  const supabase = await requireSupervisorOrAdmin();
  const { data, error } = await (supabase as any).rpc(
    "staff_allocate_statement_line_to_supplier_invoice_incremental_v1",
    {
      p_dva_statement_line_id: statementLineId,
      p_supplier_invoice_id: supplierInvoiceId,
      p_allocated_gbp_amount: Math.round(amount * 100) / 100,
      p_notes: notes,
    },
  );

  if (error) redirectWithResult(path, { error: error.message });

  const result = (data ?? {}) as Record<string, unknown>;
  const allocated = Number(result.allocated_gbp_amount ?? amount);
  const lineRemaining = Number(result.statement_remaining_after_gbp ?? 0);
  const invoiceRemaining = Number(result.invoice_remaining_after_gbp ?? 0);
  const invoiceRef = String(result.invoice_ref ?? supplierInvoiceId);

  revalidatePath(PAGE_PATH);
  revalidatePath("/internal/dva-reconciliation/control-summary");
  revalidatePath("/internal/dva-reconciliation");
  revalidatePath("/internal/dva-reconciliation/workspace");
  revalidatePath("/internal/dva-reconciliation/multi-invoice");
  revalidatePath("/internal/dva-reconciliation/allocations");

  redirectWithResult(path, {
    success: `Allocated £${Number.isFinite(allocated) ? allocated.toFixed(2) : amount.toFixed(2)} to invoice ${invoiceRef}. Statement remaining £${Number.isFinite(lineRemaining) ? lineRemaining.toFixed(2) : "0.00"}; invoice remaining £${Number.isFinite(invoiceRemaining) ? invoiceRemaining.toFixed(2) : "0.00"}.`,
  });
}
