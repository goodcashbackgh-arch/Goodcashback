import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const read = (relative) => fs.readFileSync(path.join(root, relative), "utf8");
const assert = (condition, message) => {
  if (!condition) throw new Error(message);
};

const route = read("app/internal/invoice-review/safe-fetch-mindee/route.ts");
const readiness = read("app/internal/invoice-review/readiness.ts");
const cleanup = read("app/importer/orders/[order_id]/operations/OrderOperationsUxCleanup.tsx");
const limitMigration = read("supabase/migrations/20260725_order_bundle_limit_supervisor_flag_v1.sql");
const grossupMigration = read("supabase/migrations/20260725_mindee_adjustment_grossup_guard_v1.sql");
const grossupSuppressionMigration = read("supabase/migrations/20260725b_mindee_grossup_flag_suppression_alignment_v1.sql");
const reset = read("docs/testing/20260725_reset_adjustment_invoices_to_uploaded_ocr_v1.sql");
const reviewPage = read("app/internal/invoice-review/page.tsx");

// Current operational fetch/save path must remain the route used by the existing
// supervisor screen. This prevents the older unused server action from silently
// becoming authoritative again.
assert(
  reviewPage.includes('action="/internal/invoice-review/safe-fetch-mindee"'),
  "Invoice-review page no longer uses the guarded safe-fetch Mindee route.",
);

// Re-OCR must never read a completed response from a previous job retained for
// audit. Cache lookup is deliberately scoped to the current invoice job id.
assert(
  route.includes('.eq("mindee_job_id", jobId).eq("action_type", "get_job")'),
  "Mindee cache lookup is not scoped to the current job id.",
);

// Delivery/discount facts are existing upload classifications. They are read,
// not rewritten, and are used to separate goods from proven non-physical rows.
assert(route.includes('.from("order_value_adjustments")'), "OCR route does not read existing adjustment facts.");
assert(route.includes('deliveryOrders.has(line.order)'), "Proven delivery rows are not excluded from stored goods lines.");
assert(route.includes('isDiscountDescription'), "Negative OCR rows are not description-checked before discount classification.");
assert(route.includes('unclassifiedNegativeGbp'), "Unclassified negative OCR rows do not fail closed to supervisor review.");
assert(route.includes('line.amount >= 0'), "Negative adjustment rows could enter supplier goods lines.");
assert(route.includes('explainedSignedTotal'), "Signed OCR header reconciliation is missing.");
assert(route.includes('unclearMessages.join(" ")'), "OCR unclear flags are not consolidated to one open type.");
assert(route.includes('adjustmentMessages.join(" ")'), "Delivery/discount flags are not consolidated to one open type.");

// The established database line-save implementation remains authoritative. The
// legacy 20% heuristic is disabled only for adjustment-bearing invoices, while
// its existing false-mismatch suppression remains effective for ordinary invoices
// under both old and new parser wording.
assert(grossupMigration.includes('CREATE OR REPLACE FUNCTION public.staff_save_mindee_invoice_ocr_result'), "Canonical Mindee save function is not preserved.");
assert(grossupMigration.includes('v_has_active_adjustment'), "Adjustment-bearing OCR save guard is missing.");
assert(grossupMigration.includes('IF NOT v_has_active_adjustment'), "VAT gross-up is not disabled for active adjustment invoices.");
assert(grossupMigration.includes('v_raw_line_total * 1.20'), "Existing no-adjustment VAT gross-up behaviour was not preserved.");
assert(grossupSuppressionMigration.includes("v_auto_gross_up_yn"), "Gross-up suppression is not tied to the established heuristic result.");
assert(grossupSuppressionMigration.includes("ocr lines plus declared delivery/discount explain"), "New OCR mismatch wording is not aligned with established gross-up suppression.");
assert(grossupSuppressionMigration.includes("Expected established gross-up flag-suppression clause was not found"), "Gross-up suppression alignment is not fail-closed.");
assert(!grossupMigration.match(/UPDATE\s+public\.(orders|order_value_adjustments|supplier_invoice_financial_summary)/i), "OCR storage guard rewrites protected financial source rows.");
assert(!grossupSuppressionMigration.match(/UPDATE\s+public\.(orders|supplier_invoices|order_value_adjustments|supplier_invoice_financial_summary)/i), "Gross-up suppression alignment rewrites protected source rows.");

// Preserve both canonical and established legacy invoice-line representations.
assert(readiness.includes('invoiceLineTotal + deliveryGbp - discountGbp'), "Canonical goods + delivery - discount readiness equation is missing.");
assert(readiness.includes('invoiceLineTotal - discountGbp'), "Legacy delivery-in-lines compatibility is missing.");
assert(readiness.includes('order_bundle_limit_breach'), "Bundle-limit flag is not in the approval blocker set.");
assert(readiness.includes('delivery_discount_query'), "Unresolved adjustment query is not in the approval blocker set.");

// Importer warning is presentation-only and does not disable or replace upload.
assert(cleanup.includes("data-order-bundle-upload-warning"), "Pre-upload bundle warning is missing.");
assert(cleanup.includes("Upload is not blocked"), "Warning does not preserve the existing upload route.");
assert(!cleanup.includes("disabled = true"), "Warning unexpectedly disables the existing upload control.");

// Supervisor alert extends the existing flag table and is created only from the
// existing operator-entered financial-summary seam. The exact deployed decision
// view is preserved under a stable name and wrapped rather than reimplemented.
assert(limitMigration.includes("order_bundle_limit_breach"), "New bundle-limit flag type is missing.");
assert(limitMigration.includes("Expected exactly one single-column flag_type check"), "Flag-type schema change is not fail-closed.");
assert(limitMigration.includes("supplier_invoice_match_decision_pre_bundle_limit_v1"), "Existing invoice-decision view is not preserved behind a wrapper.");
assert(limitMigration.includes("FROM public.supplier_invoice_match_decision_pre_bundle_limit_v1 base"), "Bundle flag routing does not reuse the exact preserved decision view.");
assert(limitMigration.includes("AFTER INSERT ON public.supplier_invoice_financial_summary"), "Bundle check is not attached to the established invoice-total insert seam.");
assert(limitMigration.includes("pg_advisory_xact_lock"), "Concurrent order uploads are not serialised before server-side bundle validation.");
assert(limitMigration.includes("public.supplier_invoice_review_flags"), "Bundle breach does not use the existing supervisor review lane.");
assert(limitMigration.includes("abf15b7b-771f-482f-9751-2af0ee0bcbb1"), "One-time breach backfill is not restricted to the current test order.");
assert(!limitMigration.includes("FROM public.orders o\n  JOIN public.supplier_invoices si ON si.order_id = o.id\n  JOIN public.supplier_invoice_financial_summary fs ON fs.supplier_invoice_id = si.id\n  WHERE COALESCE"), "Bundle migration appears to backfill unrelated historical orders.");
assert(!limitMigration.match(/UPDATE\s+public\.(orders|supplier_invoices|order_value_adjustments|supplier_invoice_financial_summary)/i), "Bundle-limit migration rewrites financial source rows.");
assert(!limitMigration.match(/\b(bank|treasury|funding|shipment|sage_postings)\b\s+SET/i), "Bundle-limit migration mutates a protected downstream lane.");

// Reset is exact-order, adjustment-only and fail-closed before deleting OCR rows.
assert(reset.includes("abf15b7b-771f-482f-9751-2af0ee0bcbb1"), "Reset is not scoped to the current test order.");
assert(reset.includes("retailer_delivery','retailer_discount"), "Reset is not limited to adjustment-bearing invoices.");
assert(reset.includes("manual or progressed invoice-line work exists"), "Reset lacks human/progression protection.");
assert(reset.includes("supplier-payment allocation or draft allocation work"), "Reset lacks payment/allocation-work protection.");
assert(reset.includes("frozen or posted supplier accounting artefact"), "Reset lacks Sage/accounting protection.");
assert(reset.includes("is_current_for_order"), "Reset does not protect approved/current invoice identity.");
assert(reset.includes("invoice_pdf_url IS DISTINCT FROM t.invoice_pdf_url"), "Reset does not prove uploaded-file preservation.");
assert(reset.includes("supplier_invoice_financial_summary"), "Reset does not prove operator-total preservation.");
assert(reset.includes("order_value_adjustments"), "Reset does not prove adjustment preservation.");
assert(reset.includes("mindee_api_calls"), "Reset does not preserve/prove OCR API audit history.");
assert(!reset.match(/DELETE\s+FROM\s+public\.(supplier_invoices|supplier_invoice_financial_summary|order_value_adjustments|mindee_api_calls)/i), "Reset deletes a preserved source/audit relation.");

console.log(JSON.stringify({
  regression_result: "PASS",
  details: "Current-job OCR re-run, labelled signed adjustments, adjustment-safe OCR storage, preserved ordinary-invoice gross-up, legacy-safe approval readiness, pre-upload limit warning, preserved-view supervisor routing and fail-closed adjustment-invoice reset are present without replacing financial or downstream routes.",
}, null, 2));
