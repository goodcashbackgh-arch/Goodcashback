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

  return { ok: true as const, supabase, staffId: staff.id };
}

export async function approveSupplierInvoiceCurrentAction(formData: FormData) {
  const supplierInvoiceId = readString(formData, "supplier_invoice_id");
  const correctedInvoiceRef = readString(formData, "corrected_invoice_ref");
  const ocrInvoiceRef = readString(formData, "ocr_invoice_ref");
  const ocrRetailerName = readString(formData, "ocr_retailer_name");
  const ocrInvoiceDate = readString(formData, "ocr_invoice_date");
  const ocrInvoiceTotal = readOptionalMoney(formData, "ocr_invoice_total_gbp");
  const reviewNotes = readString(formData, "review_notes");

  if (!supplierInvoiceId) redirectWithResult({ error: "Missing supplier invoice reference." });

  const guard = await requireSupervisorOrAdmin();
  if (!guard.ok) redirectWithResult({ error: guard.error });

  const { data: invoice, error: invoiceError } = await guard.supabase
    .from("supplier_invoices")
    .select("id, order_id, invoice_ref")
    .eq("id", supplierInvoiceId)
    .maybeSingle();

  if (invoiceError || !invoice) {
    redirectWithResult({ error: invoiceError?.message ?? "Supplier invoice not found." });
  }

  const now = new Date().toISOString();

  const { error: supersedeError } = await guard.supabase
    .from("supplier_invoices")
    .update({
      review_status: "superseded",
      blocked_from_sage_yn: true,
      is_current_for_order: false,
      reviewed_by_staff_id: guard.staffId,
      reviewed_at: now,
      review_notes: "Superseded because another invoice was approved as current for this order.",
      superseded_by_supplier_invoice_id: supplierInvoiceId,
    })
    .eq("order_id", invoice.order_id)
    .neq("id", supplierInvoiceId)
    .eq("is_current_for_order", true);

  if (supersedeError) redirectWithResult({ error: supersedeError.message });

  const nextInvoiceRef = correctedInvoiceRef || String(invoice.invoice_ref ?? "");
  const status = correctedInvoiceRef && correctedInvoiceRef !== invoice.invoice_ref ? "ref_corrected_approved" : "approved_current";

  const updatePayload: Record<string, unknown> = {
    invoice_ref: nextInvoiceRef,
    review_status: status,
    blocked_from_sage_yn: false,
    is_current_for_order: true,
    reviewed_by_staff_id: guard.staffId,
    reviewed_at: now,
    review_notes: reviewNotes || "Approved as current supplier invoice for this order.",
  };

  if (ocrInvoiceRef) updatePayload.ocr_invoice_ref = ocrInvoiceRef;
  if (ocrRetailerName) updatePayload.ocr_retailer_name = ocrRetailerName;
  if (ocrInvoiceDate) updatePayload.ocr_invoice_date = ocrInvoiceDate;
  if (ocrInvoiceTotal !== null) updatePayload.ocr_invoice_total_gbp = ocrInvoiceTotal;
  if (correctedInvoiceRef && !ocrInvoiceRef) updatePayload.ocr_invoice_ref = correctedInvoiceRef;

  const { error } = await guard.supabase
    .from("supplier_invoices")
    .update(updatePayload)
    .eq("id", supplierInvoiceId);

  if (error) redirectWithResult({ error: error.message });

  const { error: flagUpdateError } = await guard.supabase
    .from("supplier_invoice_review_flags")
    .update({
      status: "resolved",
      resolved_by_staff_id: guard.staffId,
      resolved_at: now,
      resolution_notes: reviewNotes || "Invoice approved as current.",
      updated_at: now,
    })
    .eq("supplier_invoice_id", supplierInvoiceId)
    .in("status", ["open", "under_review"]);

  if (flagUpdateError) redirectWithResult({ error: flagUpdateError.message });

  revalidatePath("/internal/invoice-review");
  revalidatePath(`/internal/evidence/${invoice.order_id}`);
  revalidatePath(`/importer/orders/${invoice.order_id}/operations`);
  revalidatePath(`/importer/reconciliation/${invoice.order_id}`);
  redirectWithResult({ success: "Supplier invoice approved as current." });
}

export async function rejectSupplierInvoiceRequireResubmissionAction(formData: FormData) {
  const supplierInvoiceId = readString(formData, "supplier_invoice_id");
  const reviewNotes = readString(formData, "review_notes");

  if (!supplierInvoiceId) redirectWithResult({ error: "Missing supplier invoice reference." });

  const guard = await requireSupervisorOrAdmin();
  if (!guard.ok) redirectWithResult({ error: guard.error });

  const { data: invoice, error: invoiceError } = await guard.supabase
    .from("supplier_invoices")
    .select("id, order_id")
    .eq("id", supplierInvoiceId)
    .maybeSingle();

  if (invoiceError || !invoice) {
    redirectWithResult({ error: invoiceError?.message ?? "Supplier invoice not found." });
  }

  const now = new Date().toISOString();
  const notes = reviewNotes || "Rejected. Operator must resubmit the correct invoice evidence.";

  const { error } = await guard.supabase
    .from("supplier_invoices")
    .update({
      review_status: "rejected_resubmit_required",
      blocked_from_sage_yn: true,
      is_current_for_order: false,
      reviewed_by_staff_id: guard.staffId,
      reviewed_at: now,
      review_notes: notes,
    })
    .eq("id", supplierInvoiceId);

  if (error) redirectWithResult({ error: error.message });

  const { error: flagUpdateError } = await guard.supabase
    .from("supplier_invoice_review_flags")
    .update({
      status: "resolved",
      resolved_by_staff_id: guard.staffId,
      resolved_at: now,
      resolution_notes: notes,
      updated_at: now,
    })
    .eq("supplier_invoice_id", supplierInvoiceId)
    .in("status", ["open", "under_review"]);

  if (flagUpdateError) redirectWithResult({ error: flagUpdateError.message });

  revalidatePath("/internal/invoice-review");
  revalidatePath(`/internal/evidence/${invoice.order_id}`);
  revalidatePath(`/importer/orders/${invoice.order_id}/operations`);
  revalidatePath(`/importer/reconciliation/${invoice.order_id}`);
  redirectWithResult({ success: "Supplier invoice rejected. Resubmission required." });
}
