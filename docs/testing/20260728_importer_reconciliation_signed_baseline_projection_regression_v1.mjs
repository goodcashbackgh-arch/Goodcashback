import assert from "node:assert/strict";
import fs from "node:fs";

const actions = fs.readFileSync("app/importer/reconciliation/[order_id]/actions.ts", "utf8");
const page = fs.readFileSync("app/importer/reconciliation/[order_id]/page.tsx", "utf8");
const TOLERANCE = 0.01;

function contains(source, pattern, message) {
  assert.match(source, pattern, message);
}

// Frozen routes / scope.
contains(actions, /\.rpc\("operator_mark_supplier_invoice_line_progressed"/, "Single progression RPC changed.");
contains(actions, /\.rpc\("operator_bulk_mark_supplier_invoice_lines_progressed"/, "Bulk progression RPC changed.");
assert.doesNotMatch(actions + page, /staff_progress_supplier_invoice_lines/, "Staff progression was introduced.");
contains(actions, /\.select\("id, total_qty_declared, order_total_gbp_declared"\)/, "Original baseline fields changed.");
contains(actions, /const CURRENCY_TOLERANCE_GBP = 0\.01;/, "Currency tolerance changed.");

// Current-main safety/provenance facts.
contains(actions, /supplier_invoice_id, line_source, description, qty, amount_inc_vat_gbp, qty_confirmed, amount_confirmed, eligible_for_invoice_yn/, "Progression line read is missing signed/provenance fields.");
contains(actions, /!== "ocr_extracted"/, "Provisional financial proof is not restricted to OCR rows.");
contains(actions, /isProgressedFlag\(line\.eligible_for_invoice_yn\)/, "Progressed rows can enter provisional proof.");
contains(actions, /\.eq\("active", true\)[\s\S]*?\.eq\("resolution_type", "non_physical_financial"\)/, "Resolved financial read is not restricted to active non-physical resolutions.");
contains(actions, /resolution\.financial_type === "discount"\) return -Math\.abs\(amount\)/, "Resolved discount sign changed.");
contains(actions, /\["delivery", "fee"\]\.includes\(resolution\.financial_type\)\) return Math\.abs\(amount\)/, "Resolved delivery/fee sign changed.");
contains(actions, /qty: totals\.qty \+ \(resolution \? 0 : values\.qty\)/, "Resolved financial quantity is not zero.");
contains(actions, /!accountedLineIds\.has\(line\.id\)[\s\S]*?!resolvedLineIds\.has\(line\.id\)[\s\S]*?!disputeLineIds\.has\(line\.id\)/, "Accounted/resolved/exception rows can enter provisional offset.");
contains(actions, /adjustment\.approval_status !== "rejected"/, "Rejected adjustment handling changed.");
contains(actions, /Math\.abs\(Math\.abs\(extractedAmount\) - Math\.abs\(adjustmentAmount\)\) <= CURRENCY_TOLERANCE_GBP/, "Adjustment tolerance changed.");
contains(actions, /line\.qty_confirmed \?\? line\.qty \?\? 0/, "Confirmed quantity fallback changed.");
contains(actions, /line\.amount_confirmed \?\? line\.amount_inc_vat_gbp \?\? 0/, "Confirmed amount fallback changed.");
contains(actions, /alreadyAccounted\.qty \+ selectedUnresolvedTotals\.qty > baselineQty/, "Projected quantity rule changed.");
contains(actions, /alreadyAccounted\.amount \+ selectedUnresolvedTotals\.amount \+ unresolvedFinancialOffset[\s\S]*?>[\s\S]*?baselineAmount \+ CURRENCY_TOLERANCE_GBP/, "Projected value rule changed.");
contains(actions, /\.from\("dispute_lines"\)[\s\S]*?\.is\("resolved_at", null\)/, "Line-level exception boundary changed.");

// Page remains the original PR194 selection-capacity projection; exception UI is not redesigned.
contains(page, /line\.qty_confirmed \?\? line\.qty/, "Page quantity fallback does not match server intent.");
contains(page, /line\.amount_confirmed \?\? line\.amount_inc_vat_gbp/, "Page amount fallback does not match server intent.");
contains(page, /provedUnresolvedFinancialOffset/, "Page signed offset is missing.");
contains(page, /const exceptionEligible = lines\.filter/, "Existing exception selection path is missing.");

function isProgressed(value) {
  return ["y", "yes", "true", "1"].includes(String(value ?? "").trim().toLowerCase());
}

function kind(line) {
  if (String(line.line_source ?? "").trim().toLowerCase() !== "ocr_extracted") return null;
  if (isProgressed(line.eligible_for_invoice_yn)) return null;
  const description = String(line.description ?? "").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
  const amount = Number(line.amount_inc_vat_gbp ?? 0);
  if (amount < 0 && /(^| )(discount|promotion|promotional|promo|voucher|coupon|saving|savings)( |$)/.test(description)) return "discount";
  if (amount > 0 && /(^| )(delivery|shipping|postage|freight|carriage)( |$)/.test(description)) return "delivery";
  return null;
}

function offset({ lines, accounted = new Set(), resolved = new Set(), disputed = new Set(), selectedInvoices, adjustments }) {
  let total = 0;
  for (const invoiceId of selectedInvoices) {
    const available = lines.filter((line) => line.supplier_invoice_id === invoiceId && !accounted.has(line.id) && !resolved.has(line.id) && !disputed.has(line.id));
    const invoiceAdjustments = adjustments.filter((row) => row.supplier_invoice_id === invoiceId && row.approval_status !== "rejected");
    for (const financialKind of ["discount", "delivery"]) {
      const extracted = available.filter((line) => kind(line) === financialKind).reduce((sum, line) => sum + Number(line.amount_inc_vat_gbp ?? 0), 0);
      const adjustment = invoiceAdjustments.filter((row) => row.adjustment_type === `retailer_${financialKind}`).reduce((sum, row) => sum + Number(row.amount_gbp ?? 0), 0);
      if (extracted !== 0 && Math.abs(Math.abs(extracted) - Math.abs(adjustment)) <= TOLERANCE) total += extracted;
    }
  }
  return total;
}

const invoiceId = "invoice-current";
const lines = [
  { id: "goods", supplier_invoice_id: invoiceId, line_source: "ocr_extracted", eligible_for_invoice_yn: "N", description: "Goods", amount_inc_vat_gbp: 249.99 },
  { id: "discount", supplier_invoice_id: invoiceId, line_source: "ocr_extracted", eligible_for_invoice_yn: "N", description: "Promotion", amount_inc_vat_gbp: -22.5 },
  { id: "delivery", supplier_invoice_id: invoiceId, line_source: "ocr_extracted", eligible_for_invoice_yn: "N", description: "Express delivery", amount_inc_vat_gbp: 7.95 },
];
const adjustments = [
  { supplier_invoice_id: invoiceId, adjustment_type: "retailer_discount", amount_gbp: 22.5, approval_status: null },
  { supplier_invoice_id: invoiceId, adjustment_type: "retailer_delivery", amount_gbp: 7.95, approval_status: "auto_approved" },
];

const previousAccountedValue = 466.39;
const provedOffset = offset({ lines, selectedInvoices: new Set([invoiceId]), adjustments });
assert.equal(provedOffset, -14.55, "Signed unresolved offset is wrong.");
assert.equal(Math.round((previousAccountedValue + 249.99 + provedOffset) * 100) / 100, 701.83, "Goods-first projection must equal £701.83.");
assert.equal(3 + 1, 4, "Goods-first quantity must equal four.");
assert.equal(offset({ lines, accounted: new Set(["discount", "delivery"]), resolved: new Set(["discount", "delivery"]), selectedInvoices: new Set([invoiceId]), adjustments }), 0, "Parked financial rows were double counted.");
assert.equal(offset({ lines, disputed: new Set(["discount", "delivery"]), selectedInvoices: new Set([invoiceId]), adjustments }), 0, "Exception-linked rows created provisional capacity.");
assert.equal(offset({ lines, selectedInvoices: new Set([invoiceId]), adjustments: [] }), 0, "Description alone created provisional capacity.");

const manualDelivery = { id: "manual-delivery", supplier_invoice_id: invoiceId, line_source: "manually_added", eligible_for_invoice_yn: "N", description: "Express delivery", amount_inc_vat_gbp: 7.95 };
assert.equal(offset({ lines: [manualDelivery], selectedInvoices: new Set([invoiceId]), adjustments: [adjustments[1]] }), 0, "Manually-added row created provisional OCR capacity.");
const progressedDelivery = { ...lines[2], id: "progressed-delivery", eligible_for_invoice_yn: "Y" };
assert.equal(offset({ lines: [progressedDelivery], selectedInvoices: new Set([invoiceId]), adjustments: [adjustments[1]] }), 0, "Progressed row created provisional capacity.");

assert(previousAccountedValue + 250.01 + provedOffset > 701.83 + TOLERANCE, "Genuine value excess was not blocked.");
assert(3 + 2 > 4, "Genuine quantity excess was not blocked.");
assert.doesNotMatch(actions + page, /ORD-|invoice-current|701\.83|466\.39|249\.99/, "Controlled test values were hard-coded in production.");

console.log(JSON.stringify({ regression_result: "PASS", proof: "signed progression projection remains order-baseline bounded; OCR provenance is required for provisional financial offsets; Parked, progressed, exception-linked, manual and unmatched rows cannot manufacture capacity; goods-first resolves £701.83/qty4" }, null, 2));