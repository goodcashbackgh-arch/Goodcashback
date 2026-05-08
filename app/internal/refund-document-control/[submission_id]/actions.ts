"use server";

import { revalidatePath } from "next/cache";
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

function asNumber(value: FormDataEntryValue | null, fallback = 0) {
  const parsed = asNullableNumber(value);
  return parsed === null ? fallback : parsed;
}

function round2(value: number) {
  return Math.round(value * 100) / 100;
}

function splitGross(grossValue: unknown, rateValue: unknown) {
  const gross = round2(Number(grossValue ?? 0));
  const rate = Number(rateValue ?? 20);
  if (!Number.isFinite(gross)) return { net: 0, vat: 0 };
  if (!Number.isFinite(rate) || rate <= 0) return { net: gross, vat: 0 };
  const net = round2(gross / (1 + rate / 100));
  const vat = round2(gross - net);
  return { net, vat };
}

function taxLabel(rateValue: unknown) {
  const rate = Number(rateValue ?? 0);
  if (rate === 20) return "20% standard";
  if (rate === 5) return "5% reduced";
  return "0% zero/exempt";
}

function taxId(rateValue: unknown) {
  const rate = Number(rateValue ?? 0);
  if (rate === 20) return "STANDARD_20";
  if (rate === 5) return "REDUCED_5";
  return "ZERO_0";
}

function redirectBack(submissionId: string, params: Record<string, string>): never {
  const query = new URLSearchParams(params);
  redirect(`/internal/refund-document-control/${submissionId}?${query.toString()}`);
}

export async function releaseRefundDocumentLinesAction(formData: FormData) {
  const submissionId = asString(formData.get("refund_evidence_submission_id"));
  const lineIds = formData.getAll("line_ids").map((value) => asString(value)).filter(Boolean);
  const notes = asString(formData.get("notes"));

  if (!submissionId) redirect("/internal/supplier-draft-ready?error=Missing+refund+evidence+submission");
  if (lineIds.length === 0) redirectBack(submissionId, { error: "Select at least one line to release." });

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("staff_release_refund_document_lines_to_supplier_control", {
    p_refund_evidence_submission_id: submissionId,
    p_line_ids: lineIds,
    p_notes: notes || null,
  });

  if (error) redirectBack(submissionId, { error: error.message });
  if (!data?.ok) redirectBack(submissionId, { error: "Failed to release refund document lines." });

  revalidatePath(`/internal/refund-document-control/${submissionId}`);
  revalidatePath("/internal/supplier-draft-ready");
  redirectBack(submissionId, { success: "Refund document lines released to supplier control." });
}

export async function saveAllRefundDocumentLineAccountingCodesAction(formData: FormData) {
  const submissionId = asString(formData.get("refund_evidence_submission_id"));
  const lineIds = formData.getAll("line_ids").map((value) => asString(value)).filter(Boolean);

  if (!submissionId) redirect("/internal/supplier-draft-ready?error=Missing+refund+evidence+submission");
  if (lineIds.length === 0) redirectBack(submissionId, { error: "No progressed refund document lines to save." });

  const supabase = await createClient();
  const { data: refundLines, error: refundLinesError } = await supabase
    .from("dispute_refund_document_lines")
    .select("id, amount_gbp")
    .eq("refund_evidence_submission_id", submissionId)
    .in("id", lineIds);

  if (refundLinesError) redirectBack(submissionId, { error: refundLinesError.message });

  const grossByLineId = new Map<string, number>();
  for (const line of refundLines ?? []) {
    grossByLineId.set(String(line.id), Number(line.amount_gbp ?? 0));
  }

  const lines = lineIds.map((lineId) => {
    const rate = asNumber(formData.get(`vat_rate_percent_${lineId}`), 20);
    const gross = grossByLineId.get(lineId);
    if (gross === undefined) {
      redirectBack(submissionId, { error: `Refund document line ${lineId} was not found.` });
    }
    const split = splitGross(gross, rate);

    return {
      refund_document_line_id: lineId,
      description_override: asString(formData.get(`description_override_${lineId}`)),
      sku_override: asString(formData.get(`sku_override_${lineId}`)),
      size_override: asString(formData.get(`size_override_${lineId}`)),
      sage_ledger_account_id: asString(formData.get(`sage_ledger_account_id_${lineId}`)),
      nominal_code: asString(formData.get(`nominal_code_${lineId}`)),
      tax_rate_id: taxId(rate),
      tax_rate_label: taxLabel(rate),
      vat_rate_percent: rate,
      net_amount_gbp: split.net,
      vat_amount_gbp: split.vat,
      admin_review_required_yn: formData.get(`admin_review_required_yn_${lineId}`) === "on",
      review_reason: asString(formData.get(`review_reason_${lineId}`)),
    };
  });

  const { error } = await supabase.rpc("staff_bulk_save_refund_document_line_accounting_codes", {
    p_refund_evidence_submission_id: submissionId,
    p_lines: lines,
  });

  if (error) redirectBack(submissionId, { error: error.message });

  revalidatePath(`/internal/refund-document-control/${submissionId}`);
  revalidatePath("/internal/supplier-draft-ready");
  redirectBack(submissionId, { success: "Refund document coding saved and balanced." });
}

export async function addRefundDocumentAccountingAdjustmentLineAction(formData: FormData) {
  const submissionId = asString(formData.get("refund_evidence_submission_id"));
  const description = asString(formData.get("description"));
  const net = asNullableNumber(formData.get("net_amount_gbp"));
  const vatRate = asNullableNumber(formData.get("vat_rate_percent")) ?? 20;

  if (!submissionId) redirect("/internal/supplier-draft-ready?error=Missing+refund+evidence+submission");
  if (!description.trim()) redirectBack(submissionId, { error: "Adjustment description is required." });
  if (net === null) redirectBack(submissionId, { error: "Adjustment net is required." });

  const vat = round2(net * vatRate / 100);

  const supabase = await createClient();
  const { error } = await supabase.rpc("staff_create_refund_document_accounting_adjustment_line", {
    p_refund_evidence_submission_id: submissionId,
    p_description: description,
    p_sku: asString(formData.get("sku")),
    p_size: asString(formData.get("size")),
    p_sage_ledger_account_id: asString(formData.get("sage_ledger_account_id")),
    p_nominal_code: asString(formData.get("nominal_code")),
    p_tax_rate_id: taxId(vatRate),
    p_tax_rate_label: taxLabel(vatRate),
    p_vat_rate_percent: vatRate,
    p_net_amount_gbp: net,
    p_vat_amount_gbp: vat,
  });

  if (error) redirectBack(submissionId, { error: error.message });

  revalidatePath(`/internal/refund-document-control/${submissionId}`);
  redirectBack(submissionId, { success: "Refund document adjustment line added." });
}

export async function deleteRefundDocumentAccountingAdjustmentLineAction(formData: FormData) {
  const submissionId = asString(formData.get("refund_evidence_submission_id"));
  const adjustmentLineId = asString(formData.get("adjustment_line_id"));

  if (!submissionId) redirect("/internal/supplier-draft-ready?error=Missing+refund+evidence+submission");
  if (!adjustmentLineId) redirectBack(submissionId, { error: "Missing adjustment line id." });

  const supabase = await createClient();
  const { error } = await supabase.rpc("staff_delete_refund_document_accounting_adjustment_line", {
    p_adjustment_line_id: adjustmentLineId,
  });

  if (error) redirectBack(submissionId, { error: error.message });

  revalidatePath(`/internal/refund-document-control/${submissionId}`);
  redirectBack(submissionId, { success: "Refund document adjustment line deleted." });
}

export async function approveRefundDocumentCurrentAction(formData: FormData) {
  const submissionId = asString(formData.get("refund_evidence_submission_id"));
  const notes = asString(formData.get("review_notes"));

  if (!submissionId) redirect("/internal/supplier-draft-ready?error=Missing+refund+evidence+submission");

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("staff_approve_refund_document_current", {
    p_refund_evidence_submission_id: submissionId,
    p_review_notes: notes || null,
  });

  if (error) redirectBack(submissionId, { error: error.message });
  if (!data?.ok) redirectBack(submissionId, { error: "Failed to approve refund document current." });

  revalidatePath(`/internal/refund-document-control/${submissionId}`);
  revalidatePath("/internal/supplier-draft-ready");
  revalidatePath("/internal/status-control/pre-sage-financial-readiness");
  redirect(`/internal/supplier-draft-ready?success=${encodeURIComponent("Refund document approved current for supplier credit/adjustment control.")}`);
}
