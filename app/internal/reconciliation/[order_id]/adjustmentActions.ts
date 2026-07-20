"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
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

export async function updateSupplierAccountingAdjustmentLineAction(formData: FormData) {
  const supabase = await createClient();
  const orderId = asString(formData.get("order_id"));
  const invoiceId = asString(formData.get("supplier_invoice_id"));
  const adjustmentLineId = asString(formData.get("adjustment_line_id"));
  const description = asString(formData.get("description"));
  const qty = asNumber(formData.get("qty"), 1);
  const net = asNullableNumber(formData.get("net_amount_gbp"));
  const vat = asNullableNumber(formData.get("vat_amount_gbp"));
  const vatRate = asNullableNumber(formData.get("vat_rate_percent")) ?? 20;

  if (!orderId || !invoiceId || !adjustmentLineId) redirect(`/internal/reconciliation/${orderId || ""}?error=Missing+adjustment+line+id`);
  if (!description.trim()) redirect(supplierInvoiceReconciliationHref(orderId, invoiceId, { error: "Adjustment description is required" }));
  if (!Number.isFinite(qty) || qty <= 0) redirect(supplierInvoiceReconciliationHref(orderId, invoiceId, { error: "Adjustment quantity must be greater than zero" }));
  if (net === null || vat === null) redirect(supplierInvoiceReconciliationHref(orderId, invoiceId, { error: "Adjustment net and VAT are required" }));

  const { error } = await supabase.rpc("staff_update_supplier_invoice_accounting_adjustment_line_v2", {
    p_adjustment_line_id: adjustmentLineId,
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
  redirect(supplierInvoiceReconciliationHref(orderId, invoiceId, { success: "Adjustment line updated" }));
}
