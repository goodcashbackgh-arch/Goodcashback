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

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
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

function bodyValue(body: string | null | undefined, key: string) {
  const line = (body ?? "").split("\n").find((row) => row.startsWith(`${key}:`));
  return line ? line.slice(key.length + 1).trim() : "";
}

function evidenceNeedsSupervisorReview(body: string | null | undefined) {
  const text = body ?? "";
  return (
    text.includes("variance_supervisor_review_required") ||
    text.includes("no_document_supervisor_review_required") ||
    text.includes("supplier_refund_adjustment_review_required")
  );
}

async function requireSupervisorOrAdmin() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    return { ok: false as const, supabase, staffId: "", error: "Please sign in again." };
  }

  const { data: staff, error } = await supabase
    .from("staff")
    .select("id, role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (error || !staff) {
    return { ok: false as const, supabase, staffId: "", error: "Active staff user not found." };
  }

  if (!["admin", "supervisor"].includes(String(staff.role_type))) {
    return { ok: false as const, supabase, staffId: "", error: "Only admin or supervisor staff can approve supplier records." };
  }

  return { ok: true as const, supabase, staffId: String(staff.id) };
}

async function assertAccountingCodingReadyForApproval(supabase: Awaited<ReturnType<typeof createClient>>, supplierInvoiceId: string) {
  const { data: totals, error } = await supabase
    .from("supplier_invoice_accounting_coding_totals_vw")
    .select("all_progressed_lines_coded_yn, net_reconciled_to_invoice_yn, vat_reconciled_to_invoice_yn, gross_reconciled_to_invoice_yn, net_variance_gbp, vat_variance_gbp, gross_variance_gbp")
    .eq("supplier_invoice_id", supplierInvoiceId)
    .maybeSingle();

  if (error) return error.message;
  if (!totals) return "Accounting coding totals not found. Open reconciliation and save coding first.";
  if (!totals.all_progressed_lines_coded_yn) return "All progressed lines must be accounting coded before approval.";
  if (!totals.net_reconciled_to_invoice_yn || !totals.vat_reconciled_to_invoice_yn || !totals.gross_reconciled_to_invoice_yn) {
    return `Net/VAT/Gross coding does not reconcile. Net variance ${totals.net_variance_gbp ?? 0}, VAT variance ${totals.vat_variance_gbp ?? 0}, gross variance ${totals.gross_variance_gbp ?? 0}.`;
  }
  return null;
}

async function approveOneSupplierInvoiceCurrent(
  supabase: Awaited<ReturnType<typeof createClient>>,
  supplierInvoiceId: string,
  reviewNotes: string,
) {
  const readinessError = await assertInvoiceReadyForCurrentApproval(supabase, supplierInvoiceId);
  if (readinessError) return readinessError;

  const codingError = await assertAccountingCodingReadyForApproval(supabase, supplierInvoiceId);
  if (codingError) return codingError;

  const { data: invoice, error: invoiceError } = await supabase
    .from("supplier_invoices")
    .select("id, invoice_ref, ocr_invoice_ref, ocr_retailer_name, ocr_invoice_date, ocr_invoice_total_gbp, supplier_invoice_financial_summary(invoice_total_gbp)")
    .eq("id", supplierInvoiceId)
    .maybeSingle();

  if (invoiceError || !invoice) return invoiceError?.message ?? "Supplier invoice not found.";

  const summary = firstRelated(invoice.supplier_invoice_financial_summary as { invoice_total_gbp: number | null }[] | { invoice_total_gbp: number | null } | null);
  const acceptedTotal = moneyOrNull(invoice.ocr_invoice_total_gbp) ?? moneyOrNull(summary?.invoice_total_gbp);

  const { error } = await supabase.rpc("staff_approve_supplier_invoice_current", {
    p_supplier_invoice_id: supplierInvoiceId,
    p_corrected_invoice_ref: invoice.ocr_invoice_ref || invoice.invoice_ref,
    p_ocr_invoice_ref: invoice.ocr_invoice_ref || null,
    p_ocr_retailer_name: invoice.ocr_retailer_name || null,
    p_ocr_invoice_date: invoice.ocr_invoice_date || null,
    p_ocr_invoice_total_gbp: acceptedTotal,
    p_review_notes: reviewNotes,
  });

  return error?.message ?? null;
}

async function latestAcceptedSupervisorReviewExists(supabase: Awaited<ReturnType<typeof createClient>>, disputeId: string, evidenceMessageId: string) {
  const { data, error } = await supabase
    .from("dispute_messages")
    .select("id, body")
    .eq("dispute_id", disputeId)
    .eq("message_type", "refund_evidence_review")
    .order("created_at", { ascending: false })
    .limit(5);

  if (error) return { ok: false as const, error: error.message };

  const accepted = (data ?? []).some((message) => {
    const body = String(message.body ?? "");
    return body.includes("review_decision: accepted") && body.includes(`source_evidence_message_id: ${evidenceMessageId}`);
  });

  return { ok: true as const, accepted };
}

async function alreadyApprovedRefundEvidenceCurrent(supabase: Awaited<ReturnType<typeof createClient>>, disputeId: string, evidenceMessageId: string) {
  const { data, error } = await supabase
    .from("dispute_messages")
    .select("id, body")
    .eq("dispute_id", disputeId)
    .eq("message_type", "supplier_refund_current_approved")
    .limit(20);

  if (error) return { ok: false as const, error: error.message };

  const existing = (data ?? []).some((message) => String(message.body ?? "").includes(`source_evidence_message_id: ${evidenceMessageId}`));
  return { ok: true as const, existing };
}

export async function approveSupplierInvoiceCurrentAction(formData: FormData) {
  const supplierInvoiceId = String(formData.get("single_supplier_invoice_id") ?? "").trim();
  if (!supplierInvoiceId) redirectWithResult({ error: "Missing supplier invoice id." });

  const guard = await requireSupervisorOrAdmin();
  if (!guard.ok) redirectWithResult({ error: guard.error });

  const error = await approveOneSupplierInvoiceCurrent(
    guard.supabase,
    supplierInvoiceId,
    "Approved from supplier draft ready queue.",
  );

  revalidatePath("/internal/supplier-draft-ready");
  revalidatePath("/internal/invoice-review");
  revalidatePath("/internal");

  if (error) redirectWithResult({ error });
  redirectWithResult({ success: "Approved 1 supplier invoice as current." });
}

export async function bulkApproveSupplierInvoicesCurrentAction(formData: FormData) {
  const invoiceIds = Array.from(new Set(readInvoiceIds(formData)));
  if (invoiceIds.length === 0) redirectWithResult({ error: "Select at least one ready supplier invoice." });

  const guard = await requireSupervisorOrAdmin();
  if (!guard.ok) redirectWithResult({ error: guard.error });

  let approvedCount = 0;
  const blocked: string[] = [];

  for (const supplierInvoiceId of invoiceIds) {
    const error = await approveOneSupplierInvoiceCurrent(
      guard.supabase,
      supplierInvoiceId,
      "Bulk approved from supplier draft ready queue.",
    );

    if (error) {
      blocked.push(`${supplierInvoiceId}: ${error}`);
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

export async function approveSupplierRefundEvidenceCurrentAction(formData: FormData) {
  const evidenceMessageId = readString(formData, "evidence_message_id");
  const disputeId = readString(formData, "dispute_id");
  if (!evidenceMessageId || !disputeId) redirectWithResult({ error: "Missing refund evidence approval context." });

  const guard = await requireSupervisorOrAdmin();
  if (!guard.ok) redirectWithResult({ error: guard.error });

  const { data: evidence, error: evidenceError } = await guard.supabase
    .from("dispute_messages")
    .select("id, dispute_id, message_type, body")
    .eq("id", evidenceMessageId)
    .eq("dispute_id", disputeId)
    .maybeSingle();

  if (evidenceError || !evidence) redirectWithResult({ error: evidenceError?.message ?? "Refund evidence message not found." });
  if (!["credit_note_evidence", "refund_evidence"].includes(String(evidence.message_type))) {
    redirectWithResult({ error: "Only refund or credit-note evidence can be approved here." });
  }

  const body = String(evidence.body ?? "");
  const documentMode = bodyValue(body, "document_mode");
  const route = bodyValue(body, "supplier_readiness_route");
  const controlStatus = bodyValue(body, "evidence_control_status");

  if (documentMode === "credit_note" || route === "supplier_credit_note_readiness_pending_ocr" || controlStatus === "credit_note_uploaded_pending_ocr_compare") {
    redirectWithResult({ error: "Credit-note evidence needs OCR/compare before supplier credit-note current approval." });
  }

  const reviewRequired = evidenceNeedsSupervisorReview(body);
  if (reviewRequired) {
    const review = await latestAcceptedSupervisorReviewExists(guard.supabase, disputeId, evidenceMessageId);
    if (!review.ok) redirectWithResult({ error: review.error });
    if (!review.accepted) redirectWithResult({ error: "This refund evidence needs an accepted supervisor exception review before approval." });
  }

  const duplicateGuard = await alreadyApprovedRefundEvidenceCurrent(guard.supabase, disputeId, evidenceMessageId);
  if (!duplicateGuard.ok) redirectWithResult({ error: duplicateGuard.error });
  if (duplicateGuard.existing) redirectWithResult({ error: "This refund evidence has already been approved current." });

  const approvalBody = [
    "[SUPPLIER_REFUND_CURRENT_APPROVAL_V1]",
    `approved_by_staff_id: ${guard.staffId}`,
    `source_evidence_message_id: ${evidenceMessageId}`,
    `dispute_id: ${disputeId}`,
    `document_mode: ${documentMode || "—"}`,
    `supplier_readiness_route: ${route || "—"}`,
    `evidence_control_status: ${controlStatus || "—"}`,
    `captured_refund_amount_abs_gbp: ${bodyValue(body, "captured_refund_amount_abs_gbp") || "—"}`,
    `expected_exception_amount_abs_gbp: ${bodyValue(body, "expected_exception_amount_abs_gbp") || "—"}`,
    `variance_abs_gbp: ${bodyValue(body, "variance_abs_gbp") || "—"}`,
    "",
    "Approved current from supplier draft ready queue. Sage posting remains a later controlled step. DVA/card refund IN still needs matching for money clearance.",
  ].join("\n");

  const { error: insertError } = await guard.supabase.from("dispute_messages").insert({
    dispute_id: disputeId,
    message_type: "supplier_refund_current_approved",
    counterparty: "internal",
    body: approvalBody,
    generated_by: "supplier_draft_ready",
  });

  if (insertError) redirectWithResult({ error: insertError.message });

  revalidatePath("/internal/supplier-draft-ready");
  revalidatePath(`/internal/exceptions/${disputeId}`);
  revalidatePath("/internal/status-control/pre-sage-financial-readiness");
  redirectWithResult({ success: "Approved refund adjustment evidence as supplier-side current." });
}
