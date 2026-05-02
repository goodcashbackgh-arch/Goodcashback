import { NextResponse } from "next/server";
import { createClient } from "@/utils/supabase/server";
import { assertInvoiceReadyForCurrentApproval } from "../../../invoice-review/readiness";

function firstRelated<T>(value: T | T[] | null | undefined): T | null {
  if (!value) return null;
  return Array.isArray(value) ? value[0] ?? null : value;
}

function moneyOrNull(value: unknown) {
  if (value === null || value === undefined || value === "") return null;
  const n = Number(value);
  return Number.isFinite(n) ? Math.round(n * 100) / 100 : null;
}

function redirectTo(url: URL, path: string, params: Record<string, string>) {
  const next = new URL(path, url.origin);
  for (const [key, value] of Object.entries(params)) next.searchParams.set(key, value);
  return NextResponse.redirect(next, { status: 303 });
}

export async function POST(request: Request, { params }: { params: Promise<{ order_id: string }> }) {
  const { order_id: orderId } = await params;
  const url = new URL(request.url);
  const formData = await request.formData();
  const invoiceId = String(formData.get("supplier_invoice_id") ?? "").trim();

  if (!invoiceId) {
    return redirectTo(url, `/internal/reconciliation/${orderId}`, { error: "Missing supplier invoice id." });
  }

  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return redirectTo(url, "/login", {});

  const { data: staff, error: staffError } = await supabase
    .from("staff")
    .select("id, role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (staffError || !staff || !["admin", "supervisor"].includes(String(staff.role_type))) {
    return redirectTo(url, `/internal/reconciliation/${orderId}`, { error: "Only admin/supervisor staff can approve supplier invoices." });
  }

  const readinessError = await assertInvoiceReadyForCurrentApproval(supabase, invoiceId);
  if (readinessError) {
    return redirectTo(url, `/internal/reconciliation/${orderId}`, { error: readinessError });
  }

  const { data: totals, error: totalsError } = await supabase
    .from("supplier_invoice_accounting_coding_totals_vw")
    .select("all_progressed_lines_coded_yn, net_reconciled_to_invoice_yn, vat_reconciled_to_invoice_yn, gross_reconciled_to_invoice_yn, net_variance_gbp, vat_variance_gbp, gross_variance_gbp")
    .eq("supplier_invoice_id", invoiceId)
    .maybeSingle();

  if (totalsError || !totals) {
    return redirectTo(url, `/internal/reconciliation/${orderId}`, { error: totalsError?.message ?? "Accounting coding totals not found." });
  }

  if (!totals.all_progressed_lines_coded_yn) {
    return redirectTo(url, `/internal/reconciliation/${orderId}`, { error: "All progressed lines must be accounting coded before approval." });
  }

  if (!totals.net_reconciled_to_invoice_yn || !totals.vat_reconciled_to_invoice_yn || !totals.gross_reconciled_to_invoice_yn) {
    return redirectTo(url, `/internal/reconciliation/${orderId}`, {
      error: `Net/VAT/Gross coding does not reconcile. Net variance ${totals.net_variance_gbp ?? 0}, VAT variance ${totals.vat_variance_gbp ?? 0}, gross variance ${totals.gross_variance_gbp ?? 0}.`,
    });
  }

  const { data: invoice, error: invoiceError } = await supabase
    .from("supplier_invoices")
    .select("id, invoice_ref, ocr_invoice_ref, ocr_retailer_name, ocr_invoice_date, ocr_invoice_total_gbp, supplier_invoice_financial_summary(invoice_total_gbp)")
    .eq("id", invoiceId)
    .maybeSingle();

  if (invoiceError || !invoice) {
    return redirectTo(url, `/internal/reconciliation/${orderId}`, { error: invoiceError?.message ?? "Supplier invoice not found." });
  }

  const summary = firstRelated(invoice.supplier_invoice_financial_summary as { invoice_total_gbp: number | null }[] | { invoice_total_gbp: number | null } | null);
  const acceptedTotal = moneyOrNull(invoice.ocr_invoice_total_gbp) ?? moneyOrNull(summary?.invoice_total_gbp);

  const { error } = await supabase.rpc("staff_approve_supplier_invoice_current", {
    p_supplier_invoice_id: invoiceId,
    p_corrected_invoice_ref: invoice.ocr_invoice_ref || invoice.invoice_ref,
    p_ocr_invoice_ref: invoice.ocr_invoice_ref || null,
    p_ocr_retailer_name: invoice.ocr_retailer_name || null,
    p_ocr_invoice_date: invoice.ocr_invoice_date || null,
    p_ocr_invoice_total_gbp: acceptedTotal,
    p_review_notes: "Approved from supervisor reconciliation accounting coding page.",
  });

  if (error) return redirectTo(url, `/internal/reconciliation/${orderId}`, { error: error.message });

  return redirectTo(url, "/internal/supplier-draft-ready", {
    success: "Supplier invoice approved as current. Ready for Sage draft preparation.",
  });
}
