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

  return { supabase, ok: true as const, operatorId: operator.id };
}

export async function updateSupplierInvoiceLineAction(formData: FormData) {
  const orderId = readString(formData, "order_id");
  const lineId = readString(formData, "line_id");
  const qty = readNumber(formData, "qty");
  const amount = readNumber(formData, "amount_inc_vat_gbp");
  const description = readString(formData, "description");

  if (!orderId || !lineId) {
    redirect("/importer");
  }

  if (!description) {
    redirectWithResult(orderId, { error: "Description cannot be blank." });
  }

  if (qty === null || qty < 0) {
    redirectWithResult(orderId, { error: "Quantity must be a valid non-negative number." });
  }

  if (amount === null || amount < 0) {
    redirectWithResult(orderId, { error: "Amount must be a valid non-negative number." });
  }

  const guard = await requireActiveOperator();
  if (!guard.ok) {
    redirectWithResult(orderId, { error: guard.error });
  }

  const { error } = await guard.supabase
    .from("supplier_invoice_lines")
    .update({
      qty,
      description,
      amount_inc_vat_gbp: amount,
    })
    .eq("id", lineId);

  if (error) {
    redirectWithResult(orderId, { error: error.message });
  }

  revalidatePath(`/importer/reconciliation/${orderId}`);
  redirectWithResult(orderId, { success: "Line updated." });
}

export async function addManualSupplierInvoiceLineAction(formData: FormData) {
  const orderId = readString(formData, "order_id");
  const supplierInvoiceId = readString(formData, "supplier_invoice_id");
  const qty = readNumber(formData, "qty");
  const amount = readNumber(formData, "amount_inc_vat_gbp");
  const description = readString(formData, "description");

  if (!orderId || !supplierInvoiceId) {
    redirect("/importer");
  }

  if (!description) {
    redirectWithResult(orderId, { error: "Description cannot be blank." });
  }

  if (qty === null || qty < 0) {
    redirectWithResult(orderId, { error: "Quantity must be a valid non-negative number." });
  }

  if (amount === null || amount < 0) {
    redirectWithResult(orderId, { error: "Amount must be a valid non-negative number." });
  }

  const guard = await requireActiveOperator();
  if (!guard.ok) {
    redirectWithResult(orderId, { error: guard.error });
  }

  const { data: lines, error: linesError } = await guard.supabase
    .from("supplier_invoice_lines")
    .select("line_order")
    .eq("supplier_invoice_id", supplierInvoiceId)
    .order("line_order", { ascending: false })
    .limit(1);

  if (linesError) {
    redirectWithResult(orderId, { error: linesError.message });
  }

  const nextLineOrder = (lines?.[0]?.line_order ?? 0) + 1;

  const { error } = await guard.supabase.from("supplier_invoice_lines").insert({
    supplier_invoice_id: supplierInvoiceId,
    line_source: "manually_added",
    line_order: nextLineOrder,
    description,
    qty,
    amount_inc_vat_gbp: amount,
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

  const { data: line, error: lineError } = await guard.supabase
    .from("supplier_invoice_lines")
    .select("id, line_source")
    .eq("id", lineId)
    .maybeSingle();

  if (lineError) {
    redirectWithResult(orderId, { error: lineError.message });
  }

  if (!line) {
    redirectWithResult(orderId, { error: "Line not found." });
  }

  if (line.line_source !== "manually_added") {
    redirectWithResult(orderId, { error: "Only manually added lines can be deleted." });
  }

  const { error } = await guard.supabase.from("supplier_invoice_lines").delete().eq("id", lineId);

  if (error) {
    redirectWithResult(orderId, { error: error.message });
  }

  revalidatePath(`/importer/reconciliation/${orderId}`);
  redirectWithResult(orderId, { success: "Manual line deleted." });
}
