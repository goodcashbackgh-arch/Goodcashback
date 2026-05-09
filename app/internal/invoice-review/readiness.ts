type SupabaseLike = {
  from: (table: string) => any;
};

const SAFE_EXCEPTION_REMEDIES = new Set(["refund", "replacement"]);

const SERIOUS_OPEN_FLAG_TYPES = new Set([
  "wrong_invoice",
  "ocr_unclear",
  "invoice_total_mismatch",
  "manual_line_needed",
]);

function asNumber(value: unknown) {
  const n = Number(value ?? 0);
  return Number.isFinite(n) ? n : 0;
}

function isProgressedLine(line: any) {
  return line.eligible_for_invoice_yn === "Y" && line.qty_confirmed !== null && line.amount_confirmed !== null;
}

function exceptionRemedyForRow(row: any) {
  const dispute = Array.isArray(row.disputes) ? row.disputes[0] : row.disputes;
  return String(row.intended_remedy ?? dispute?.desired_outcome ?? "").trim().toLowerCase();
}

export async function assertInvoiceReadyForCurrentApproval(
  supabase: SupabaseLike,
  supplierInvoiceId: string,
) {
  const { data: invoice, error: invoiceError } = await supabase
    .from("supplier_invoices")
    .select("id, order_id, invoice_ref, ocr_invoice_total_gbp")
    .eq("id", supplierInvoiceId)
    .maybeSingle();

  if (invoiceError || !invoice) {
    return invoiceError?.message ?? "Supplier invoice not found.";
  }

  const { data: seriousFlags, error: flagsError } = await supabase
    .from("supplier_invoice_review_flags")
    .select("flag_type")
    .eq("supplier_invoice_id", supplierInvoiceId)
    .in("status", ["open", "under_review"])
    .in("flag_type", Array.from(SERIOUS_OPEN_FLAG_TYPES))
    .limit(1);

  if (flagsError) return flagsError.message;
  if ((seriousFlags ?? []).length > 0) {
    return "Cannot approve current invoice yet. Serious invoice review flags remain open or under review.";
  }

  const { data: pendingAdjustments, error: adjustmentError } = await supabase
    .from("order_value_adjustments")
    .select("id")
    .eq("supplier_invoice_id", supplierInvoiceId)
    .eq("approval_status", "pending_supervisor")
    .limit(1);

  if (adjustmentError) return adjustmentError.message;
  if ((pendingAdjustments ?? []).length > 0) {
    return "Cannot approve current invoice yet. Pending delivery/discount adjustments must be approved or rejected first.";
  }

  const { data: lines, error: linesError } = await supabase
    .from("supplier_invoice_lines")
    .select("id, eligible_for_invoice_yn, qty_confirmed, amount_confirmed, amount_inc_vat_gbp")
    .eq("supplier_invoice_id", supplierInvoiceId);

  if (linesError) return linesError.message;
  if ((lines ?? []).length === 0) {
    return "Cannot approve current invoice yet. No OCR/manual invoice lines exist for reconciliation.";
  }

  const { data: summary, error: summaryError } = await supabase
    .from("supplier_invoice_financial_summary")
    .select("invoice_total_gbp")
    .eq("supplier_invoice_id", supplierInvoiceId)
    .maybeSingle();

  if (summaryError) return summaryError.message;

  const invoiceTotal = invoice.ocr_invoice_total_gbp !== null && invoice.ocr_invoice_total_gbp !== undefined
    ? asNumber(invoice.ocr_invoice_total_gbp)
    : asNumber(summary?.invoice_total_gbp);

  if (invoiceTotal <= 0) {
    return "Cannot approve current invoice yet. Invoice total is missing from OCR or operator upload.";
  }

  const invoiceLineTotal = (lines ?? []).reduce(
    (sum: number, line: any) => sum + asNumber(line.amount_inc_vat_gbp),
    0,
  );

  if (Math.abs(invoiceLineTotal - invoiceTotal) >= 0.01) {
    return `Cannot approve current invoice yet. Invoice line total ${invoiceLineTotal.toFixed(2)} does not match invoice total ${invoiceTotal.toFixed(2)}.`;
  }

  const unsettledLineIds = (lines ?? [])
    .filter((line: any) => !isProgressedLine(line))
    .map((line: any) => String(line.id));

  if (unsettledLineIds.length === 0) return null;

  const { data: disputeLines, error: disputeError } = await supabase
    .from("dispute_lines")
    .select("supplier_invoice_line_id, intended_remedy, resolved_at, disputes(status, desired_outcome, resolved_at)")
    .in("supplier_invoice_line_id", unsettledLineIds);

  if (disputeError) return disputeError.message;

  const safelyBranchedLineIds = new Set(
    (disputeLines ?? [])
      .filter((row: any) => {
        const remedy = exceptionRemedyForRow(row);
        return SAFE_EXCEPTION_REMEDIES.has(remedy);
      })
      .map((row: any) => String(row.supplier_invoice_line_id)),
  );

  const unbranchedCount = unsettledLineIds.filter((lineId: string) => !safelyBranchedLineIds.has(lineId)).length;
  if (unbranchedCount > 0) {
    return `Cannot approve current invoice yet. ${unbranchedCount} invoice line(s) are not progressed and not branched into refund/replacement exception handling.`;
  }

  return null;
}

export async function assertSupplierInvoiceAccountingCodingReady(
  supabase: SupabaseLike,
  supplierInvoiceId: string,
) {
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
