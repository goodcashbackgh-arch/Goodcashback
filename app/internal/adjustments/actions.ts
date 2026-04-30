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
  const parsed = Math.round(Number(raw) * 100) / 100;
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : null;
}

function redirectWithResult(params: Record<string, string>): never {
  const query = new URLSearchParams(params);
  redirect(`/internal/adjustments?${query.toString()}`);
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
    return { ok: false as const, supabase, error: "Only admin or supervisor staff can approve adjustments." };
  }

  return { ok: true as const, supabase, staffId: staff.id };
}

export async function approveOrderValueAdjustmentAction(formData: FormData) {
  const adjustmentId = readString(formData, "adjustment_id");
  const correctedAmount = readOptionalMoney(formData, "corrected_amount_gbp");
  const correctedInvoiceTotal = readOptionalMoney(formData, "corrected_invoice_total_gbp");
  const correctionNote = readString(formData, "correction_note");

  if (!adjustmentId) {
    redirectWithResult({ error: "Missing adjustment reference." });
  }

  const guard = await requireSupervisorOrAdmin();
  if (!guard.ok) {
    redirectWithResult({ error: guard.error });
  }

  const { data: existing, error: readError } = await guard.supabase
    .from("order_value_adjustments")
    .select("id, order_id, supplier_invoice_id, amount_gbp, notes")
    .eq("id", adjustmentId)
    .eq("approval_status", "pending_supervisor")
    .maybeSingle();

  if (readError || !existing) {
    redirectWithResult({ error: readError?.message ?? "Pending adjustment not found." });
  }

  const now = new Date().toISOString();
  const notes = [
    existing.notes,
    correctedAmount !== null && correctedAmount !== Number(existing.amount_gbp)
      ? `Supervisor corrected adjustment amount from ${existing.amount_gbp} to ${correctedAmount}.`
      : null,
    correctedInvoiceTotal !== null
      ? `Supervisor confirmed/corrected supplier invoice final total to ${correctedInvoiceTotal}.`
      : null,
    correctionNote || null,
  ].filter(Boolean).join("\n");

  if (correctedInvoiceTotal !== null && existing.supplier_invoice_id) {
    const { error: summaryError } = await guard.supabase
      .from("supplier_invoice_financial_summary")
      .upsert({
        supplier_invoice_id: existing.supplier_invoice_id,
        invoice_total_gbp: correctedInvoiceTotal,
        source: "supervisor_entered",
        confidence: "high",
        entered_by_staff_id: guard.staffId,
        notes: "Supplier invoice total confirmed/corrected by supervisor during adjustment review.",
        updated_at: now,
      }, { onConflict: "supplier_invoice_id" });

    if (summaryError) {
      redirectWithResult({ error: summaryError.message });
    }
  }

  const updatePayload: Record<string, unknown> = {
    approval_status: "approved",
    approved_by_staff_id: guard.staffId,
    approved_at: now,
    updated_at: now,
    notes: notes || existing.notes,
  };

  if (correctedAmount !== null) {
    updatePayload.amount_gbp = correctedAmount;
  }

  const { error } = await guard.supabase
    .from("order_value_adjustments")
    .update(updatePayload)
    .eq("id", adjustmentId)
    .eq("approval_status", "pending_supervisor");

  if (error) {
    redirectWithResult({ error: error.message });
  }

  revalidatePath("/internal/adjustments");
  revalidatePath(`/internal/evidence/${existing.order_id}`);
  revalidatePath(`/importer/orders/${existing.order_id}/operations`);
  revalidatePath(`/importer/reconciliation/${existing.order_id}`);
  revalidatePath("/importer");
  redirectWithResult({ success: "Adjustment approved." });
}

export async function rejectOrderValueAdjustmentAction(formData: FormData) {
  const adjustmentId = readString(formData, "adjustment_id");
  const note = readString(formData, "note");
  if (!adjustmentId) {
    redirectWithResult({ error: "Missing adjustment reference." });
  }

  const guard = await requireSupervisorOrAdmin();
  if (!guard.ok) {
    redirectWithResult({ error: guard.error });
  }

  const { data: existing } = await guard.supabase
    .from("order_value_adjustments")
    .select("order_id")
    .eq("id", adjustmentId)
    .maybeSingle();

  const { error } = await guard.supabase
    .from("order_value_adjustments")
    .update({
      approval_status: "rejected",
      approved_by_staff_id: null,
      approved_at: null,
      notes: note || "Rejected by supervisor.",
      updated_at: new Date().toISOString(),
    })
    .eq("id", adjustmentId)
    .eq("approval_status", "pending_supervisor");

  if (error) {
    redirectWithResult({ error: error.message });
  }

  revalidatePath("/internal/adjustments");
  if (existing?.order_id) {
    revalidatePath(`/internal/evidence/${existing.order_id}`);
    revalidatePath(`/importer/orders/${existing.order_id}/operations`);
    revalidatePath(`/importer/reconciliation/${existing.order_id}`);
  }
  revalidatePath("/importer");
  redirectWithResult({ success: "Adjustment rejected." });
}
