type SupabaseLike = {
  from: (table: string) => any;
};

const SAFE_EXCEPTION_REMEDIES = new Set(["refund", "replacement"]);

const SERIOUS_OPEN_FLAG_TYPES = new Set([
  "wrong_invoice",
  "ocr_unclear",
  "invoice_total_mismatch",
  "delivery_discount_query",
  "manual_line_needed",
  "order_bundle_limit_breach",
]);

function asNumber(value: unknown) {
  const n = Number(value ?? 0);
  return Number.isFinite(n) ? n : 0;
}

function isPositiveNumber(value: unknown) {
  const n = Number(value ?? 0);
  return Number.isFinite(n) && n > 0;
}

function isProgressedLine(line: any) {
  return line.eligible_for_invoice_yn === "Y" && line.qty_confirmed !== null && line.amount_confirmed !== null;
}

function exceptionRemedyForRow(row: any) {
  const dispute = Array.isArray(row.disputes) ? row.disputes[0] : row.disputes;
  return String(row.intended_remedy ?? dispute?.desired_outcome ?? "").trim().toLowerCase();
}

function hasPostingAccount(row: any) {
  return String(row?.nominal_code ?? "").trim().length > 0 || String(row?.sage_ledger_account_id ?? "").trim().length > 0;
}

async function assertVerifiedSupplierBundleWithinOrderValue(
  supabase: SupabaseLike,
  orderId: string,
) {
  const { data: position, error } = await supabase
    .from("order_supplier_price_position_v1")
    .select("order_id, order_type, current_order_value_gbp, accepted_supplier_bundle_gbp, over_limit_yn, missing_accepted_total_count, unverified_invoice_count")
    .eq("order_id", orderId)
    .maybeSingle();

  if (error) {
    return `Cannot approve current invoice yet. Live supplier price position is unavailable: ${error.message}`;
  }
  if (!position) {
    return "Cannot approve current invoice yet. Live supplier price position is missing.";
  }
  if (String(position.order_type) !== "original" || !position.over_limit_yn) return null;

  // Existing document/header/adjustment controls remain authoritative until the
  // whole live supplier bundle is price-verified. The database transition guard
  // independently protects the approved/current state after the invoice update.
  if (Number(position.missing_accepted_total_count ?? 0) > 0 || Number(position.unverified_invoice_count ?? 0) > 0) {
    return null;
  }

  return `Cannot approve current invoice yet. Verified supplier bundle £${asNumber(position.accepted_supplier_bundle_gbp).toFixed(2)} exceeds accepted order value £${asNumber(position.current_order_value_gbp).toFixed(2)}. Approve the order price increase first.`;
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

  const { data: adjustmentRows, error: adjustmentError } = await supabase
    .from("order_value_adjustments")
    .select("id, adjustment_type, amount_gbp, approval_status")
    .eq("supplier_invoice_id", supplierInvoiceId)
    .neq("approval_status", "rejected");

  if (adjustmentError) return adjustmentError.message;
  if ((adjustmentRows ?? []).some((row: any) => row.approval_status === "pending_supervisor")) {
    return "Cannot approve current invoice yet. Pending delivery/discount adjustments must be approved or rejected first.";
  }

  const deliveryGbp = (adjustmentRows ?? [])
    .filter((row: any) => row.adjustment_type === "retailer_delivery")
    .reduce((sum: number, row: any) => sum + asNumber(row.amount_gbp), 0);
  const discountGbp = (adjustmentRows ?? [])
    .filter((row: any) => row.adjustment_type === "retailer_discount")
    .reduce((sum: number, row: any) => sum + asNumber(row.amount_gbp), 0);

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

  // Preserve every established representation while moving new OCR runs to the
  // documented canonical equation: goods + delivery - discount = gross invoice.
  // 1) raw lines already equal gross (legacy/all-inclusive);
  // 2) adjustments sit outside goods lines (canonical);
  // 3) legacy OCR retained delivery but filtered the negative discount row.
  const supportedTotals = [
    invoiceLineTotal,
    invoiceLineTotal + deliveryGbp - discountGbp,
    invoiceLineTotal - discountGbp,
  ];
  const lineTotalReconciled = supportedTotals.some((candidate) => Math.abs(candidate - invoiceTotal) < 0.01);

  if (!lineTotalReconciled) {
    return `Cannot approve current invoice yet. Goods lines ${invoiceLineTotal.toFixed(2)}, delivery ${deliveryGbp.toFixed(2)} and discount ${discountGbp.toFixed(2)} do not reconcile to invoice total ${invoiceTotal.toFixed(2)}.`;
  }

  const unsettledLineIds = (lines ?? [])
    .filter((line: any) => !isProgressedLine(line))
    .map((line: any) => String(line.id));

  if (unsettledLineIds.length === 0) {
    return assertVerifiedSupplierBundleWithinOrderValue(supabase, String(invoice.order_id));
  }

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

  const { data: nonPhysicalResolutions, error: resolutionError } = await supabase
    .from("supplier_invoice_line_resolutions")
    .select("supplier_invoice_line_id")
    .eq("supplier_invoice_id", supplierInvoiceId)
    .eq("resolution_type", "non_physical_financial")
    .eq("active", true)
    .in("supplier_invoice_line_id", unsettledLineIds);

  if (resolutionError) return resolutionError.message;

  const nonPhysicalResolvedLineIds = new Set(
    (nonPhysicalResolutions ?? []).map((row: any) => String(row.supplier_invoice_line_id)),
  );

  const unbranchedCount = unsettledLineIds.filter(
    (lineId: string) => !safelyBranchedLineIds.has(lineId) && !nonPhysicalResolvedLineIds.has(lineId),
  ).length;
  if (unbranchedCount > 0) {
    return `Cannot approve current invoice yet. ${unbranchedCount} invoice line(s) are not progressed, not branched into refund/replacement exception handling, and not parked as non-physical financial lines.`;
  }

  return assertVerifiedSupplierBundleWithinOrderValue(supabase, String(invoice.order_id));
}

export async function assertSupplierInvoiceAccountingCodingReady(
  supabase: SupabaseLike,
  supplierInvoiceId: string,
) {
  const { data: totals, error } = await supabase
    .from("supplier_invoice_accounting_coding_totals_vw")
    .select("accepted_invoice_net_gbp, accepted_invoice_vat_gbp, accepted_invoice_gross_gbp, total_coded_net_gbp, total_coded_vat_gbp, total_coded_gross_gbp, progressed_line_count, coded_line_count, all_progressed_lines_coded_yn, net_reconciled_to_invoice_yn, vat_reconciled_to_invoice_yn, gross_reconciled_to_invoice_yn, net_variance_gbp, vat_variance_gbp, gross_variance_gbp")
    .eq("supplier_invoice_id", supplierInvoiceId)
    .maybeSingle();

  if (error) return error.message;
  if (!totals) return "Accounting coding totals not found. Open reconciliation and save coding first.";

  if (!isPositiveNumber(totals.accepted_invoice_gross_gbp)) {
    return "Cannot approve current invoice yet. Accepted invoice gross total is missing from OCR/operator upload.";
  }

  if (Number(totals.progressed_line_count ?? 0) < 1) {
    return "Cannot approve current invoice yet. No progressed supplier invoice lines exist for current approval.";
  }

  if (Number(totals.coded_line_count ?? 0) < 1) {
    return "Cannot approve current invoice yet. No accounting coding has been saved for progressed lines.";
  }

  if (!totals.all_progressed_lines_coded_yn) return "All progressed lines must be accounting coded before approval.";

  const { data: missingLinePostingAccounts, error: missingLinePostingAccountsError } = await supabase
    .from("supplier_invoice_line_accounting_coding_vw")
    .select("supplier_invoice_line_id, source_description, nominal_code, sage_ledger_account_id")
    .eq("supplier_invoice_id", supplierInvoiceId);

  if (missingLinePostingAccountsError) return missingLinePostingAccountsError.message;

  const lineMissingPostingAccountCount = (missingLinePostingAccounts ?? []).filter((row: any) => !hasPostingAccount(row)).length;
  if (lineMissingPostingAccountCount > 0) {
    return `Cannot approve current invoice yet. ${lineMissingPostingAccountCount} coded supplier line(s) are missing both nominal code and Sage ledger account id.`;
  }

  const { data: missingAdjustmentPostingAccounts, error: missingAdjustmentPostingAccountsError } = await supabase
    .from("supplier_invoice_accounting_adjustment_lines")
    .select("id, description, nominal_code, sage_ledger_account_id")
    .eq("supplier_invoice_id", supplierInvoiceId);

  if (missingAdjustmentPostingAccountsError) return missingAdjustmentPostingAccountsError.message;

  const adjustmentMissingPostingAccountCount = (missingAdjustmentPostingAccounts ?? []).filter((row: any) => !hasPostingAccount(row)).length;
  if (adjustmentMissingPostingAccountCount > 0) {
    return `Cannot approve current invoice yet. ${adjustmentMissingPostingAccountCount} supplier adjustment line(s) are missing both nominal code and Sage ledger account id.`;
  }

  if (!isPositiveNumber(totals.total_coded_gross_gbp)) {
    return "Cannot approve current invoice yet. Coded gross total is zero or missing.";
  }

  if (!totals.net_reconciled_to_invoice_yn || !totals.vat_reconciled_to_invoice_yn || !totals.gross_reconciled_to_invoice_yn) {
    return `Net/VAT/Gross coding does not reconcile. Net variance ${totals.net_variance_gbp ?? 0}, VAT variance ${totals.vat_variance_gbp ?? 0}, gross variance ${totals.gross_variance_gbp ?? 0}.`;
  }
  return null;
}
