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
const migration = read("supabase/migrations/20260725_order_bundle_limit_supervisor_flag_v1.sql");
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
// not rewritten, and are used to separate goods from non-physical invoice rows.
assert(route.includes('.from("order_value_adjustments")'), "OCR route does not read existing adjustment facts.");
assert(route.includes('deliveryOrders.has(line.order)'), "Proven delivery rows are not excluded from stored goods lines.");
assert(route.includes('line.amount >= 0'), "Negative discount rows could enter supplier goods lines.");
assert(route.includes('explainedSignedTotal'), "Signed OCR header reconciliation is missing.");
assert(route.includes('unclearMessages.join(" ")'), "OCR unclear flags are not consolidated to one open type.");
assert(route.includes('adjustmentMessages.join(" ")'), "Delivery/discount flags are not consolidated to one open type.");

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
// existing operator-entered financial-summary seam.
assert(migration.includes("order_bundle_limit_breach"), "New bundle-limit flag type is missing.");
assert(migration.includes("AFTER INSERT ON public.supplier_invoice_financial_summary"), "Bundle check is not attached to the established invoice-total insert seam.");
assert(migration.includes("public.supplier_invoice_review_flags"), "Bundle breach does not use the existing supervisor review lane.");
assert(!migration.match(/UPDATE\s+public\.(orders|supplier_invoices|order_value_adjustments|supplier_invoice_financial_summary)/i), "Bundle-limit migration rewrites financial source rows.");
assert(!migration.match(/\b(bank|treasury|funding|shipment|sage_postings)\b\s+SET/i), "Bundle-limit migration mutates a protected downstream lane.");

// Reset is exact-order, adjustment-only and fail-closed before deleting OCR rows.
assert(reset.includes("abf15b7b-771f-482f-9751-2af0ee0bcbb1"), "Reset is not scoped to the current test order.");
assert(reset.includes("retailer_delivery','retailer_discount"), "Reset is not limited to adjustment-bearing invoices.");
assert(reset.includes("manual or progressed invoice-line work exists"), "Reset lacks human/progression protection.");
assert(reset.includes("supplier-payment allocation"), "Reset lacks payment-allocation protection.");
assert(reset.includes("frozen or posted supplier accounting artefact"), "Reset lacks Sage/accounting protection.");
assert(reset.includes("invoice_pdf_url IS DISTINCT FROM t.invoice_pdf_url"), "Reset does not prove uploaded-file preservation.");
assert(reset.includes("supplier_invoice_financial_summary"), "Reset does not prove operator-total preservation.");
assert(reset.includes("order_value_adjustments"), "Reset does not prove adjustment preservation.");
assert(!reset.match(/DELETE\s+FROM\s+public\.(supplier_invoices|supplier_invoice_financial_summary|order_value_adjustments|mindee_api_calls)/i), "Reset deletes a preserved source/audit relation.");

console.log(JSON.stringify({
  regression_result: "PASS",
  details: "Current-job OCR re-run, signed delivery/discount classification, legacy-safe approval readiness, pre-upload limit warning, existing supervisor flagging and fail-closed adjustment-invoice reset are present without replacing financial or downstream routes.",
}, null, 2));
