"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

function readNumber(formData: FormData, key: string) {
  const value = Number(readString(formData, key));
  return Number.isFinite(value) ? value : null;
}

function readInteger(formData: FormData, key: string) {
  const value = readNumber(formData, key);
  return value !== null && Number.isInteger(value) ? value : null;
}

function readOptionalString(formData: FormData, key: string) {
  const value = readString(formData, key);
  return value.length > 0 ? value : null;
}

function redirectWithResult(orderId: string, params: Record<string, string>): never {
  const query = new URLSearchParams(params);
  redirect(`/importer/reconciliation/${orderId}?${query.toString()}`);
}

async function requireActiveOperator() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    return { supabase, ok: false as const, error: "Please sign in again." };
  }

  const { data: operator } = await supabase
    .from("operators")
    .select("id")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!operator) {
    return { supabase, ok: false as const, error: "Active operator account not found." };
  }

  return { supabase, ok: true as const };
}

export async function updateSupplierInvoiceLineAction(formData: FormData) {
  const orderId = readString(formData, "order_id");
  const lineId = readString(formData, "line_id");
  const qty = readInteger(formData, "qty");
  const amount = readNumber(formData, "amount_inc_vat_gbp");
  const description = readString(formData, "description");
  const size = readOptionalString(formData, "size");
  const retailerSku = readOptionalString(formData, "retailer_sku");

  if (!orderId || !lineId) {
    redirect("/importer");
  }

  if (!description) {
    redirectWithResult(orderId, { error: "Description cannot be blank." });
  }

  if (qty === null || qty < 0) {
    redirectWithResult(orderId, { error: "Quantity must be a valid non-negative integer." });
  }

  if (amount === null || amount < 0) {
    redirectWithResult(orderId, { error: "Amount must be a valid non-negative number." });
  }

  const guard = await requireActiveOperator();
  if (!guard.ok) {
    redirectWithResult(orderId, { error: guard.error });
  }

  const { error } = await guard.supabase.rpc("operator_update_supplier_invoice_line_fields", {
    p_order_id: orderId,
    p_line_id: lineId,
    p_description: description,
    p_qty: qty,
    p_amount_inc_vat_gbp: amount,
    p_size: size,
    p_retailer_sku: retailerSku,
  });

  if (error) {
    redirectWithResult(orderId, { error: error.message });
  }

  revalidatePath(`/importer/reconciliation/${orderId}`);
  redirectWithResult(orderId, { success: "Line updated." });
}

export async function addManualSupplierInvoiceLineAction(formData: FormData) {
  const orderId = readString(formData, "order_id");
  const supplierInvoiceId = readString(formData, "supplier_invoice_id");
  const qty = readInteger(formData, "qty");
  const amount = readNumber(formData, "amount_inc_vat_gbp");
  const description = readString(formData, "description");
  const size = readOptionalString(formData, "size");
  const retailerSku = readOptionalString(formData, "retailer_sku");

  if (!orderId || !supplierInvoiceId) {
    redirect("/importer");
  }

  if (!description) {
    redirectWithResult(orderId, { error: "Description cannot be blank." });
  }

  if (qty === null || qty < 0) {
    redirectWithResult(orderId, { error: "Quantity must be a valid non-negative integer." });
  }

  if (amount === null || amount < 0) {
    redirectWithResult(orderId, { error: "Amount must be a valid non-negative number." });
  }

  const guard = await requireActiveOperator();
  if (!guard.ok) {
    redirectWithResult(orderId, { error: guard.error });
  }

  const { error } = await guard.supabase.rpc("operator_add_manual_supplier_invoice_line", {
    p_order_id: orderId,
    p_supplier_invoice_id: supplierInvoiceId,
    p_description: description,
    p_qty: qty,
    p_amount_inc_vat_gbp: amount,
    p_size: size,
    p_retailer_sku: retailerSku,
  });

  if (error) {
    redirectWithResult(orderId, { error: error.message });
  }

  revalidatePath(`/importer/reconciliation/${orderId}`);
  redirectWithResult(orderId, { success: "Manual line added." });
}

export async function deleteManualSupplierInvoiceLineAction(formData: FormData) {
  const orderId = readString(formData, "order_id");
  const lineId = readString(formData, "line_id");

  if (!orderId || !lineId) {
    redirect("/importer");
  }

  const guard = await requireActiveOperator();
  if (!guard.ok) {
    redirectWithResult(orderId, { error: guard.error });
  }

  const { error } = await guard.supabase.rpc("operator_delete_manual_supplier_invoice_line", {
    p_order_id: orderId,
    p_line_id: lineId,
  });

  if (error) {
    redirectWithResult(orderId, { error: error.message });
  }

  revalidatePath(`/importer/reconciliation/${orderId}`);
  redirectWithResult(orderId, { success: "Manual line deleted." });
}
