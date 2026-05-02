"use server";

import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

function asString(value: FormDataEntryValue | null) {
  return typeof value === "string" ? value : "";
}

function asNullableNumber(value: FormDataEntryValue | null) {
  const raw = asString(value).trim();
  if (!raw) return null;
  const parsed = Number(raw);
  return Number.isFinite(parsed) ? parsed : null;
}

export async function saveSupplierLineAccountingCodeAction(formData: FormData) {
  const supabase = await createClient();
  const orderId = asString(formData.get("order_id"));
  const lineId = asString(formData.get("supplier_invoice_line_id"));
  const vatRateRaw = asString(formData.get("vat_rate_percent"));

  if (!orderId || !lineId) {
    redirect(`/internal/reconciliation/${orderId || ""}?error=Missing+line+or+order+id`);
  }

  const vatRate = Number(vatRateRaw || 20);
  if (!Number.isFinite(vatRate) || vatRate < 0) {
    redirect(`/internal/reconciliation/${orderId}?error=Invalid+VAT+rate`);
  }

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

  if (error) {
    redirect(`/internal/reconciliation/${orderId}?error=${encodeURIComponent(error.message)}`);
  }

  redirect(`/internal/reconciliation/${orderId}?success=Accounting+code+saved`);
}

export async function addSupplierAccountingAdjustmentLineAction(formData: FormData) {
  const supabase = await createClient();
  const orderId = asString(formData.get("order_id"));
  const invoiceId = asString(formData.get("supplier_invoice_id"));
  const description = asString(formData.get("description"));
  const net = asNullableNumber(formData.get("net_amount_gbp"));
  const vat = asNullableNumber(formData.get("vat_amount_gbp"));
  const vatRate = asNullableNumber(formData.get("vat_rate_percent")) ?? 20;

  if (!orderId || !invoiceId) redirect(`/internal/reconciliation/${orderId || ""}?error=Missing+invoice+or+order+id`);
  if (!description.trim()) redirect(`/internal/reconciliation/${orderId}?error=Adjustment+description+is+required`);
  if (net === null || vat === null) redirect(`/internal/reconciliation/${orderId}?error=Adjustment+net+and+VAT+are+required`);

  const { error } = await supabase.rpc("staff_create_supplier_invoice_accounting_adjustment_line", {
    p_supplier_invoice_id: invoiceId,
    p_description: description,
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

  if (error) redirect(`/internal/reconciliation/${orderId}?error=${encodeURIComponent(error.message)}`);
  redirect(`/internal/reconciliation/${orderId}?success=Adjustment+line+added`);
}

export async function deleteSupplierAccountingAdjustmentLineAction(formData: FormData) {
  const supabase = await createClient();
  const orderId = asString(formData.get("order_id"));
  const adjustmentLineId = asString(formData.get("adjustment_line_id"));

  if (!orderId || !adjustmentLineId) redirect(`/internal/reconciliation/${orderId || ""}?error=Missing+adjustment+line+id`);

  const { error } = await supabase.rpc("staff_delete_supplier_invoice_accounting_adjustment_line", {
    p_adjustment_line_id: adjustmentLineId,
  });

  if (error) redirect(`/internal/reconciliation/${orderId}?error=${encodeURIComponent(error.message)}`);
  redirect(`/internal/reconciliation/${orderId}?success=Adjustment+line+deleted`);
}
