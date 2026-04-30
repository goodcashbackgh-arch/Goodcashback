"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { assertInvoiceReadyForCurrentApproval } from "../invoice-review/readiness";

function redirectWithResult(params: Record<string, string>): never {
  const query = new URLSearchParams(params);
  redirect(`/internal/supplier-draft-ready?${query.toString()}`);
}

function readInvoiceIds(formData: FormData) {
  return formData
    .getAll("supplier_invoice_id")
    .filter((value): value is string => typeof value === "string" && value.trim().length > 0)
    .map((value) => value.trim());
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
    return { ok: false as const, supabase, error: "Only admin or supervisor staff can bulk approve supplier invoices." };
  }

  return { ok: true as const, supabase };
}

export async function bulkApproveSupplierInvoicesCurrentAction(formData: FormData) {
  const invoiceIds = Array.from(new Set(readInvoiceIds(formData)));
  if (invoiceIds.length === 0) redirectWithResult({ error: "Select at least one ready supplier invoice." });

  const guard = await requireSupervisorOrAdmin();
  if (!guard.ok) redirectWithResult({ error: guard.error });

  let approvedCount = 0;
  const blocked: string[] = [];

  for (const supplierInvoiceId of invoiceIds) {
    const readinessError = await assertInvoiceReadyForCurrentApproval(guard.supabase, supplierInvoiceId);
    if (readinessError) {
      blocked.push(`${supplierInvoiceId}: ${readinessError}`);
      continue;
    }

    const { data: invoice, error: invoiceError } = await guard.supabase
      .from("supplier_invoices")
      .select("id, invoice_ref, ocr_invoice_ref, ocr_retailer_name, ocr_invoice_date, ocr_invoice_total_gbp, supplier_invoice_financial_summary(invoice_total_gbp)")
      .eq("id", supplierInvoiceId)
      .maybeSingle();

    if (invoiceError || !invoice) {
      blocked.push(`${supplierInvoiceId}: ${invoiceError?.message ?? "Supplier invoice not found."}`);
      continue;
    }

    const summary = firstRelated(invoice.supplier_invoice_financial_summary as { invoice_total_gbp: number | null }[] | { invoice_total_gbp: number | null } | null);
    const acceptedTotal = moneyOrNull(invoice.ocr_invoice_total_gbp) ?? moneyOrNull(summary?.invoice_total_gbp);

    const { error } = await guard.supabase.rpc("staff_approve_supplier_invoice_current", {
      p_supplier_invoice_id: supplierInvoiceId,
      p_corrected_invoice_ref: invoice.ocr_invoice_ref || invoice.invoice_ref,
      p_ocr_invoice_ref: invoice.ocr_invoice_ref || null,
      p_ocr_retailer_name: invoice.ocr_retailer_name || null,
      p_ocr_invoice_date: invoice.ocr_invoice_date || null,
      p_ocr_invoice_total_gbp: acceptedTotal,
      p_review_notes: "Bulk approved from supplier draft ready queue.",
    });

    if (error) {
      blocked.push(`${invoice.invoice_ref ?? supplierInvoiceId}: ${error.message}`);
      continue;
    }

    approvedCount += 1;
  }

  revalidatePath("/internal/supplier-draft-ready");
  revalidatePath("/internal/invoice-review");
  revalidatePath("/internal");

  if (blocked.length > 0) {
    redirectWithResult({
      error: `Approved ${approvedCount}. Blocked ${blocked.length}. First issue: ${blocked[0]}`,
    });
  }

  redirectWithResult({ success: `Approved ${approvedCount} supplier invoice(s) as current.` });
}
