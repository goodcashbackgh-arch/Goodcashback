"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

function redirectWithResult(params: Record<string, string>): never {
  const query = new URLSearchParams(params);
  redirect(`/internal/invoice-review?${query.toString()}`);
}

function money(value: unknown) {
  const n = Number(value ?? 0);
  return Number.isFinite(n) ? n.toFixed(2) : "0.00";
}

export async function approveOrderSupplierPriceIncreaseAction(formData: FormData) {
  const orderId = readString(formData, "order_id");
  const supplierInvoiceId = readString(formData, "supplier_invoice_id");
  const reviewNotes = readString(formData, "review_notes") || null;

  if (!orderId || !supplierInvoiceId) {
    redirectWithResult({ error: "Missing order or supplier invoice reference." });
  }

  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirectWithResult({ error: "Please sign in again." });

  const { data: staff, error: staffError } = await supabase
    .from("staff")
    .select("id, role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (staffError || !staff) {
    redirectWithResult({ error: staffError?.message ?? "Active staff user not found." });
  }
  if (!["admin", "supervisor"].includes(String(staff.role_type))) {
    redirectWithResult({ error: "Only admin or supervisor staff can approve an order price increase." });
  }

  const { data, error } = await supabase.rpc("staff_approve_order_supplier_price_increase_v1", {
    p_order_id: orderId,
    p_supplier_invoice_id: supplierInvoiceId,
    p_review_notes: reviewNotes,
  });

  if (error) redirectWithResult({ error: error.message });

  const row = Array.isArray(data) ? data[0] : data;

  revalidatePath("/internal/invoice-review");
  revalidatePath("/internal/funding");
  revalidatePath("/internal");
  revalidatePath("/customer");
  revalidatePath("/importer");
  revalidatePath(`/internal/evidence/${orderId}`);
  revalidatePath(`/importer/orders/${orderId}/operations`);

  redirectWithResult({
    success: row
      ? `Order price increased from £${money(row.old_order_value_gbp)} to £${money(row.new_order_value_gbp)}. Funding gap: £${money(row.funding_gap_gbp)}.`
      : "Order price increase approved.",
  });
}
