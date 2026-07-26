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

async function requireSupervisorOrAdmin() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { ok: false as const, error: "You must sign in again." };

  const { data: staff, error } = await supabase
    .from("staff")
    .select("id, role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (error || !staff || !["admin", "supervisor"].includes(String(staff.role_type))) {
    return { ok: false as const, error: "Only an active supervisor or admin can classify an invoice rejection." };
  }

  return { ok: true as const, supabase };
}

export async function excludeSupplierInvoiceNoResubmissionAction(formData: FormData) {
  const supplierInvoiceId = readString(formData, "supplier_invoice_id");
  const reviewNotes = readString(formData, "review_notes");

  if (!supplierInvoiceId) redirectWithResult({ error: "Missing supplier invoice reference." });
  if (!reviewNotes) redirectWithResult({ error: "A reason is required before excluding an invoice from the order." });

  const guard = await requireSupervisorOrAdmin();
  if (!guard.ok) redirectWithResult({ error: guard.error });

  const { data, error } = await guard.supabase.rpc("staff_exclude_supplier_invoice_no_resubmission_v1", {
    p_supplier_invoice_id: supplierInvoiceId,
    p_review_notes: reviewNotes,
  });

  if (error) redirectWithResult({ error: error.message });

  const orderId = Array.isArray(data) && data[0]?.order_id ? String(data[0].order_id) : null;

  revalidatePath("/internal/invoice-review");
  revalidatePath("/importer");
  if (orderId) {
    revalidatePath(`/internal/evidence/${orderId}`);
    revalidatePath(`/importer/orders/${orderId}/operations`);
    revalidatePath(`/importer/reconciliation/${orderId}`);
  }

  redirectWithResult({ success: "Supplier invoice excluded from this order. No corrected evidence is required." });
}
