"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

function value(formData: FormData, key: string) {
  const entry = formData.get(key);
  return typeof entry === "string" ? entry.trim() : "";
}

export async function allocateSupplierPaymentBundleAction(formData: FormData) {
  const statementLineId = value(formData, "dva_statement_line_id");
  const orderId = value(formData, "order_id");
  const notes = value(formData, "notes") || null;
  const invoiceIds = formData.getAll("supplier_invoice_ids").map(String).filter(Boolean);

  const back = new URLSearchParams();
  if (statementLineId) back.set("line_id", statementLineId);
  if (orderId) back.set("order_id", orderId);
  const returnPath = `/internal/dva-reconciliation/multi-invoice?${back.toString()}`;

  if (!statementLineId || !orderId || invoiceIds.length === 0) {
    redirect(`${returnPath}&error=${encodeURIComponent("Select a statement OUT, order and at least one invoice allocation.")}`);
  }

  const allocations = invoiceIds.flatMap((supplierInvoiceId) => {
    const raw = value(formData, `amount_${supplierInvoiceId}`);
    const amount = Number(raw);
    return Number.isFinite(amount) && amount > 0
      ? [{ supplier_invoice_id: supplierInvoiceId, allocated_gbp_amount: Math.round(amount * 100) / 100 }]
      : [];
  });

  if (allocations.length === 0) {
    redirect(`${returnPath}&error=${encodeURIComponent("Enter a positive amount against at least one invoice.")}`);
  }

  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data, error } = await supabase.rpc(
    "staff_allocate_statement_line_to_supplier_invoice_bundle",
    {
      p_dva_statement_line_id: statementLineId,
      p_allocations: allocations,
      p_notes: notes,
    },
  );

  if (error) {
    redirect(`${returnPath}&error=${encodeURIComponent(error.message)}`);
  }

  const allocated =
    typeof data === "object" && data && "allocated_gbp_amount" in data
      ? Number(data.allocated_gbp_amount ?? 0)
      : allocations.reduce((sum, row) => sum + row.allocated_gbp_amount, 0);

  revalidatePath("/internal/dva-reconciliation");
  revalidatePath("/internal/dva-reconciliation/workspace");
  revalidatePath("/internal/dva-reconciliation/multi-invoice");
  revalidatePath("/internal/dva-reconciliation/allocations");
  redirect(`${returnPath}&success=${encodeURIComponent(`Allocated £${allocated.toFixed(2)} across ${allocations.length} supplier invoice(s).`)}`);
}
