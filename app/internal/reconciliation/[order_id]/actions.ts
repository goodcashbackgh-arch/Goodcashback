"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { assertInvoiceReadyForCurrentApproval } from "../../invoice-review/readiness";
import { supplierInvoiceReconciliationHref } from "../reconciliationHref";

function asString(value: FormDataEntryValue | null) {
  return typeof value === "string" ? value : "";
}

function asNullableNumber(value: FormDataEntryValue | null) {
  const raw = asString(value).trim();
  if (!raw) return null;
  const parsed = Number(raw);
  return Number.isFinite(parsed) ? parsed : null;
}

function asNumber(value: FormDataEntryValue | null, fallback = 0) {
  const parsed = asNullableNumber(value);
  return parsed === null ? fallback : parsed;
}

function firstRelated<T>(value: T | T[] | null | undefined): T | null {
  if (!value) return null;
  return Array.isArray(value) ? value[0] ?? null : value;
}

function moneyOrNull(value: unknown) {
  if (value === null || value === undefined || value === "") return null;
  const n = Number(value);
  return Number.isFinite(n) ? Math.round(n * 100) / 100 : null;
}

async function requireSupervisorOrAdmin() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();

  if (!user) return { ok: false as const, supabase, error: "Please sign in again." };

  const { data: staff, error } = await supabase
    .from("staff")
    .select("id, role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (error || !staff) return { ok: false as const, supabase, error: "Active staff user not found." };
  if (!["admin", "supervisor"].includes(String(staff.role_type))) {
    return { ok: false as const, supabase, error: "Only admin or supervisor staff can approve supplier invoices." };
  }

  return { ok: true as const, supabase };
}

export async function supervisorProgressSupplierInvoiceLinesAction(formData: FormData) {
  const orderId = asString(formData.get("order_id"));
  const invoiceId = asString(formData.get("supplier_invoice_id"));
  const lineIds = formData.getAll("line_ids").map((value) => asString(value)).filter(Boolean);
  const progressNotes = asString(formData.get("progress_notes")).trim();

  if (!orderId || !invoiceId) redirect(`/internal/reconciliation/${orderId || ""}?error=Missing+invoice+or+order+id`);
  if (lineIds.length === 0) redirect(supplierInvoiceReconciliationHref(orderId, invoiceId, { error: "Select at least one blocked line to progress" }));

  const guard = await requireSupervisorOrAdmin();
  if (!guard.ok) redirect(supplierInvoiceReconciliationHref(orderId, invoiceId, { error: guard.error }));

  const { data, error } = await guard.supabase.rpc("staff_progress_supplier_invoice_lines", {
    p_order_id: orderId,
    p_supplier_invoice_id: invoiceId,
    p_line_ids: lineIds,
    p_progress_notes: progressNotes || null,
  });

  if (error) redirect(supplierInvoiceReconciliationHref(orderId, invoiceId, { error: error.message }));

  const count = Number(data ?? lineIds.length);

  revalidatePath(`/internal/reconciliation/${orderId}`);
  revalidatePath("/internal/supplier-draft-ready");
  revalidatePath("/internal/invoice-review");
  revalidatePath("/internal");

  redirect(supplierInvoiceReconciliationHref(orderId, invoiceId, { success: `${count} line(s) progressed by supervisor takeover. Continue accounting coding.` }));
}

export async function approveCurrentSupplierInvoiceFromReconciliationAction(formData: FormData) {
  const orderId = asString(formData.get("order_id"));
  const invoiceId = asString(formData.get("supplier_invoice_id"));

  if (!orderId || !invoiceId) redirect(`/internal/reconciliation/${orderId || ""}?error=Missing+invoice+or+order+id`);

  const guard = await requireSupervisorOrAdmin();
  if (!guard.ok) redirect(supplierInvoiceReconciliationHref(orderId, invoiceId, { error: guard.error }));

  const readinessError = await assertInvoiceReadyForCurrentApproval(guard.supabase, invoiceId);
  if (readinessError) redirect(supplierInvoiceReconciliationHref(orderId, invoiceId, { error: readinessError }));

  const { data: totals, error: totalsError } = await guard.supabase
    .from("supplier_invoice_accounting_coding_totals_vw")
    .select("all_progressed_lines_coded_yn, net_reconciled_to_invoice_yn, vat_reconciled_to_invoice_yn, gross_reconciled_to_invoice_yn, net_variance_gbp, vat_variance_gbp, gross_variance_gbp")
    .eq("supplier_invoice_id", invoiceId)
    .maybeSingle();

  if (totalsError || !totals) {
    redirect(supplierInvoiceReconciliationHref(orderId, invoiceId, { error: totalsError?.message ?? "Accounting coding totals not found." }));
  }

  if (!totals.all_progressed_lines_coded_yn) {
    redirect(supplierInvoiceReconciliationHref(orderId, invoiceId, { error: "All progressed lines must be accounting coded before approval" }));
  }

  if (!totals.net_reconciled_to_invoice_yn || !totals.vat_reconciled_to_invoice_yn || !totals.gross_reconciled_to_invoice_yn) {
    const msg = `Net/VAT/Gross coding does not reconcile. Net variance ${totals.net_variance_gbp ?? 0}, VAT variance ${totals.vat_variance_gbp ?? 0}, gross variance ${totals.gross_variance_gbp ?? 0}.`;
    redirect(supplierInvoiceReconciliationHref(orderId, invoiceId, { error: msg }));
  }

  const { data: invoice, error: invoiceError } = await guard.supabase
    .from("supplier_invoices")
    .select("id, invoice_ref, ocr_invoice_ref, ocr_retailer_name, ocr_invoice_date, ocr_invoice_total_gbp, supplier_invoice_financial_summary(invoice_total_gbp)")
    .eq("id", invoiceId)
    .maybeSingle();

  if (invoiceError || !invoice) {
    redirect(supplierInvoiceReconciliationHref(orderId, invoiceId, { error: invoiceError?.message ?? "Supplier invoice not found." }));
  }

  const summary = firstRelated(invoice.supplier_invoice_financial_summary as { invoice_total_gbp: number | null }[] | { invoice_total_gbp: number | null } | null);
  const acceptedTotal = moneyOrNull(invoice.ocr_invoice_total_gbp) ?? moneyOrNull(summary?.invoice_total_gbp);

  const { error } = await guard.supabase.rpc("staff_approve_supplier_invoice_current", {
    p_supplier_invoice_id: invoiceId,
    p_corrected_invoice_ref: invoice.ocr_invoice_ref || invoice.invoice_ref,
    p_ocr_invoice_ref: invoice.ocr_invoice_ref || null,
    p_ocr_retailer_name: invoice.ocr_retailer_name || null,
    p_ocr_invoice_date: invoice.ocr_invoice_date || null,
    p_ocr_invoice_total_gbp: acceptedTotal,
    p_review_notes: "Approved from supervisor reconciliation accounting coding page.",
  });

  if (error) redirect(supplierInvoiceReconciliationHref(orderId, invoiceId, { error: error.message }));

  revalidatePath(`/internal/reconciliation/${orderId}`);
  revalidatePath("/internal/supplier-draft-ready");
  revalidatePath("/internal/invoice-review");
  revalidatePath("/internal");

  redirect(`/internal/supplier-draft-ready?success=${encodeURIComponent("Supplier invoice approved as current. Ready for Sage draft preparation.")}`);
}

export async function saveAllSupplierLineAccountingCodesAction(formData: FormData) {
  const supabase = await createClient();
  const orderId = asString(formData.get("order_id"));
  const invoiceId = asString(formData.get("supplier_invoice_id"));
  const lineIds = formData.getAll("line_ids").map((value) => asString(value)).filter(Boolean);

  if (!orderId || !invoiceId) redirect(`/internal/reconciliation/${orderId || ""}?error=Missing+invoice+or+order+id`);
  if (lineIds.length === 0) redirect(supplierInvoiceReconciliationHref(orderId, invoiceId, { error: "No codable lines to save" }));

  const lines = lineIds.map((lineId) => ({
    supplier_invoice_line_id: lineId,
    description_override: asString(formData.get(`description_override_${lineId}`)),
    sku_override: asString(formData.get(`sku_override_${lineId}`)),
    size_override: asString(formData.get(`size_override_${lineId}`)),
    sage_ledger_account_id: asString(formData.get(`sage_ledger_account_id_${lineId}`)),
    nominal_code: asString(formData.get(`nominal_code_${lineId}`)),
    tax_rate_id: asString(formData.get(`tax_rate_id_${lineId}`)),
    tax_rate_label: asString(formData.get(`tax_rate_label_${lineId}`)),
    vat_rate_percent: asNumber(formData.get(`vat_rate_percent_${lineId}`), 20),
    net_amount_gbp: asNumber(formData.get(`net_amount_gbp_${lineId}`), 0),
    vat_amount_gbp: asNumber(formData.get(`vat_amount_gbp_${lineId}`), 0),
    admin_review_required_yn: formData.get(`admin_review_required_yn_${lineId}`) === "on",
    review_reason: asString(formData.get(`review_reason_${lineId}`)),
  }));

  const { error } = await supabase.rpc("staff_bulk_save_supplier_invoice_line_accounting_codes_v2", {
    p_supplier_invoice_id: invoiceId,
    p_lines: lines,
  });

  if (error) redirect(supplierInvoiceReconciliationHref(orderId, invoiceId, { error: error.message }));
  revalidatePath(`/internal/reconciliation/${orderId}`);
  revalidatePath("/internal/supplier-draft-ready");
  redirect(supplierInvoiceReconciliationHref(orderId, invoiceId, { success: "All codable supplier invoice lines saved and balanced" }));
}

export async function saveSupplierLineAccountingCodeAction(formData: FormData) {
  const supabase = await createClient();
  const orderId = asString(formData.get("order_id"));
  const lineId = asString(formData.get("supplier_invoice_line_id"));
  const vatRateRaw = asString(formData.get("vat_rate_percent"));

  if (!orderId || !lineId) redirect(`/internal/reconciliation/${orderId || ""}?error=Missing+line+or+order+id`);

  const vatRate = Number(vatRateRaw || 20);
  if (!Number.isFinite(vatRate) || vatRate < 0) redirect(`/internal/reconciliation/${orderId}?error=Invalid+VAT+rate`);

  const { error } = await supabase.rpc("staff_upsert_supplier_invoice_line_accounting_code", {
    p_supplier_invoice_line_id: lineId,
    p_description_override: asString(formData.get("description_override")),
    p_sku_override: asString(formData.get("sku_override")),
    p_size_override: asString(formData.get("size_override")),
    p_sage_ledger_account_id: asString(formData.get("sage_ledger_account_id")),
    p_nominal_code: asString(formData.get("nominal_code")),
    p_tax_rate_id: asString(formData.get("tax_rate_id")),
    p_tax_rate_label: asString(formData.get("tax_rate_label")),
    p_vat_rate_percent: vatRate,
    p_net_amount_gbp: asNullableNumber(formData.get("net_amount_gbp")),
    p_vat_amount_gbp: asNullableNumber(formData.get("vat_amount_gbp")),
    p_admin_review_required_yn: formData.get("admin_review_required_yn") === "on",
    p_review_reason: asString(formData.get("review_reason")),
  });

  if (error) redirect(`/internal/reconciliation/${orderId}?error=${encodeURIComponent(error.message)}`);
  revalidatePath(`/internal/reconciliation/${orderId}`);
  revalidatePath("/internal/supplier-draft-ready");
  redirect(`/internal/reconciliation/${orderId}?success=Accounting+code+saved`);
}

export async function addSupplierAccountingAdjustmentLineAction(formData: FormData) {
  const supabase = await createClient();
  const orderId = asString(formData.get("order_id"));
  const invoiceId = asString(formData.get("supplier_invoice_id"));
  const description = asString(formData.get("description"));
  const qty = asNumber(formData.get("qty"), 1);
  const net = asNullableNumber(formData.get("net_amount_gbp"));
  const vat = asNullableNumber(formData.get("vat_amount_gbp"));
  const vatRate = asNullableNumber(formData.get("vat_rate_percent")) ?? 20;

  if (!orderId || !invoiceId) redirect(`/internal/reconciliation/${orderId || ""}?error=Missing+invoice+or+order+id`);
  if (!description.trim()) redirect(supplierInvoiceReconciliationHref(orderId, invoiceId, { error: "Adjustment description is required" }));
  if (!Number.isFinite(qty) || qty <= 0) redirect(supplierInvoiceReconciliationHref(orderId, invoiceId, { error: "Adjustment quantity must be greater than zero" }));
  if (net === null || vat === null) redirect(supplierInvoiceReconciliationHref(orderId, invoiceId, { error: "Adjustment net and VAT are required" }));

  const { error } = await supabase.rpc("staff_create_supplier_invoice_accounting_adjustment_line_v2", {
    p_supplier_invoice_id: invoiceId,
    p_description: description,
    p_qty: qty,
    p_sku: asString(formData.get("sku")),
    p_size: asString(formData.get("size")),
    p_sage_ledger_account_id: asString(formData.get("sage_ledger_account_id")),
    p_nominal_code: asString(formData.get("nominal_code")),
    p_tax_rate_id: asString(formData.get("tax_rate_id")),
    p_tax_rate_label: asString(formData.get("tax_rate_label")),
    p_vat_rate_percent: vatRate,
    p_net_amount_gbp: net,
    p_vat_amount_gbp: vat,
  });

  if (error) redirect(supplierInvoiceReconciliationHref(orderId, invoiceId, { error: error.message }));
  revalidatePath(`/internal/reconciliation/${orderId}`);
  revalidatePath("/internal/supplier-draft-ready");
  redirect(supplierInvoiceReconciliationHref(orderId, invoiceId, { success: "Adjustment line added" }));
}

export async function deleteSupplierAccountingAdjustmentLineAction(formData: FormData) {
  const supabase = await createClient();
  const orderId = asString(formData.get("order_id"));
  const invoiceId = asString(formData.get("supplier_invoice_id"));
  const adjustmentLineId = asString(formData.get("adjustment_line_id"));

  if (!orderId || !invoiceId || !adjustmentLineId) redirect(`/internal/reconciliation/${orderId || ""}?error=Missing+adjustment+line+id`);

  const { error } = await supabase
    .from("supplier_invoice_accounting_adjustment_lines")
    .delete()
    .eq("id", adjustmentLineId);

  if (error) redirect(supplierInvoiceReconciliationHref(orderId, invoiceId, { error: error.message }));
  revalidatePath(`/internal/reconciliation/${orderId}`);
  revalidatePath("/internal/supplier-draft-ready");
  redirect(supplierInvoiceReconciliationHref(orderId, invoiceId, { success: "Adjustment line deleted" }));
}
