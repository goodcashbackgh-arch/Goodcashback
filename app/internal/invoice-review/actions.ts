"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

function readOptionalMoney(formData: FormData, key: string) {
  const raw = readString(formData, key);
  if (!raw) return null;
  const value = Math.round(Number(raw) * 100) / 100;
  return Number.isFinite(value) && value >= 0 ? value : null;
}

function redirectWithResult(params: Record<string, string>): never {
  const query = new URLSearchParams(params);
  redirect(`/internal/invoice-review?${query.toString()}`);
}

async function requireSupervisorOrAdmin() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    return { ok: false as const, supabase, error: "Please sign in again." };
  }

  const { data: staff, error } = await supabase
    .from("staff")
    .select("id, role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (error || !staff) {
    return { ok: false as const, supabase, error: "Active staff user not found." };
  }

  if (!["admin", "supervisor"].includes(String(staff.role_type))) {
    return { ok: false as const, supabase, error: "Only admin or supervisor staff can review invoices." };
  }

  return { ok: true as const, supabase };
}

export async function approveSupplierInvoiceCurrentAction(formData: FormData) {
  const supplierInvoiceId = readString(formData, "supplier_invoice_id");
  const correctedInvoiceRef = readString(formData, "corrected_invoice_ref") || null;
  const ocrInvoiceRef = readString(formData, "ocr_invoice_ref") || null;
  const ocrRetailerName = readString(formData, "ocr_retailer_name") || null;
  const ocrInvoiceDate = readString(formData, "ocr_invoice_date") || null;
  const ocrInvoiceTotal = readOptionalMoney(formData, "ocr_invoice_total_gbp");
  const reviewNotes = readString(formData, "review_notes") || null;

  if (!supplierInvoiceId) redirectWithResult({ error: "Missing supplier invoice reference." });

  const guard = await requireSupervisorOrAdmin();
  if (!guard.ok) redirectWithResult({ error: guard.error });

  const { data, error } = await guard.supabase.rpc("staff_approve_supplier_invoice_current", {
    p_supplier_invoice_id: supplierInvoiceId,
    p_corrected_invoice_ref: correctedInvoiceRef,
    p_ocr_invoice_ref: ocrInvoiceRef,
    p_ocr_retailer_name: ocrRetailerName,
    p_ocr_invoice_date: ocrInvoiceDate,
    p_ocr_invoice_total_gbp: ocrInvoiceTotal,
    p_review_notes: reviewNotes,
  });

  if (error) redirectWithResult({ error: error.message });

  const orderId = Array.isArray(data) && data[0]?.order_id ? String(data[0].order_id) : null;

  revalidatePath("/internal/invoice-review");
  if (orderId) {
    revalidatePath(`/internal/evidence/${orderId}`);
    revalidatePath(`/importer/orders/${orderId}/operations`);
    revalidatePath(`/importer/reconciliation/${orderId}`);
  }
  redirectWithResult({ success: "Supplier invoice approved as current." });
}

export async function rejectSupplierInvoiceRequireResubmissionAction(formData: FormData) {
  const supplierInvoiceId = readString(formData, "supplier_invoice_id");
  const reviewNotes = readString(formData, "review_notes") || null;

  if (!supplierInvoiceId) redirectWithResult({ error: "Missing supplier invoice reference." });

  const guard = await requireSupervisorOrAdmin();
  if (!guard.ok) redirectWithResult({ error: guard.error });

  const { data, error } = await guard.supabase.rpc("staff_reject_supplier_invoice_resubmission", {
    p_supplier_invoice_id: supplierInvoiceId,
    p_review_notes: reviewNotes,
  });

  if (error) redirectWithResult({ error: error.message });

  const orderId = Array.isArray(data) && data[0]?.order_id ? String(data[0].order_id) : null;

  revalidatePath("/internal/invoice-review");
  if (orderId) {
    revalidatePath(`/internal/evidence/${orderId}`);
    revalidatePath(`/importer/orders/${orderId}/operations`);
    revalidatePath(`/importer/reconciliation/${orderId}`);
  }
  redirectWithResult({ success: "Supplier invoice rejected. Resubmission required." });
}
