"use server";

import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

function asString(value: FormDataEntryValue | null) {
  return typeof value === "string" ? value : "";
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
    p_admin_review_required_yn: formData.get("admin_review_required_yn") === "on",
    p_review_reason: asString(formData.get("review_reason")),
  });

  if (error) {
    redirect(`/internal/reconciliation/${orderId}?error=${encodeURIComponent(error.message)}`);
  }

  redirect(`/internal/reconciliation/${orderId}?success=Accounting+code+saved`);
}
