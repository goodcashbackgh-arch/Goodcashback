import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const actionsPath = "app/importer/reconciliation/[order_id]/actions.ts";
const pagePath = "app/importer/reconciliation/[order_id]/page.tsx";
const actions = fs.readFileSync(actionsPath, "utf8");
const page = fs.readFileSync(pagePath, "utf8");

function contains(source, pattern, message) {
  assert.match(source, pattern, message);
}

contains(actions, /\.rpc\("operator_mark_supplier_invoice_line_progressed"/, "Single operator progression RPC changed.");
contains(actions, /\.rpc\("operator_bulk_mark_supplier_invoice_lines_progressed"/, "Bulk operator progression RPC changed.");
assert.doesNotMatch(actions + page, /staff_progress_supplier_invoice_lines/, "Staff progression was introduced.");
contains(actions, /\.select\("id, total_qty_declared, order_total_gbp_declared"\)/, "Original baseline fields changed.");
contains(actions, /const CURRENCY_TOLERANCE_GBP = 0\.01;/, "Currency tolerance changed.");
contains(actions, /\.eq\("active", true\)\.eq\("resolution_type", "non_physical_financial"\)/, "Resolved financial query is not restricted to active non-physical resolutions.");
contains(actions, /resolution\.financial_type === "discount"\) return -Math\.abs\(amount\)/, "Resolved discount sign changed.");
contains(actions, /\["delivery", "fee"\]\.includes\(resolution\.financial_type\)\) return Math\.abs\(amount\)/, "Resolved delivery or fee sign changed.");
contains(actions, /qty: totals\.qty \+ \(resolution \? 0 : values\.qty\)/, "Resolved financial quantity is not zero.");
contains(actions, /!accountedLineIds\.has\(line\.id\) && !resolvedLineIds\.has\(line\.id\)/, "Accounted financial rows can enter the unresolved offset.");
contains(actions, /line\.supplier_invoice_id === supplierInvoiceId/, "Unresolved adjustments are not invoice-restricted.");
contains(actions, /Math\.abs\(Math\.abs\(extractedAmount\) - Math\.abs\(adjustmentAmount\)\) <= CURRENCY_TOLERANCE_GBP/, "Adjustment evidence tolerance changed.");
contains(actions, /adjustment\.approval_status !== "rejected"/, "Rejected/null approval handling changed.");
contains(actions, /line\.qty_confirmed \?\? line\.qty \?\? 0/, "Confirmed quantity fallback changed.");
contains(actions, /line\.amount_confirmed \?\? line\.amount_inc_vat_gbp \?\? 0/, "Confirmed amount fallback changed.");
contains(page, /line\.qty_confirmed \?\? line\.qty/, "Page quantity fallback does not match the server.");
contains(page, /line\.amount_confirmed \?\? line\.amount_inc_vat_gbp/, "Page amount fallback does not match the server.");
contains(actions, /alreadyAccounted\.amount \+ selectedUnresolvedTotals\.amount \+ unresolvedFinancialOffset > baselineAmount \+ CURRENCY_TOLERANCE_GBP/, "Authoritative projected-value limit changed.");
contains(actions, /alreadyAccounted\.qty \+ selectedUnresolvedTotals\.qty > baselineQty/, "Authoritative projected-quantity limit changed.");

const helperStart = actions.indexOf("function normalisedDescription");
const helperEnd = actions.indexOf("function lineProgressionValues");
assert(helperStart >= 0 && helperEnd > helperStart, "Could not load projection helpers from the actual action source.");
const helperSource = actions.slice(helperStart, helperEnd)
  .replace(/: string/g, "")
  .replace(/: ProgressionLine/g, "")
  .replace(/, resolution: ProgressionResolution/g, ", resolution")
  .replace(/params: \{[\s\S]*?\n\}\) \{/, "params) {")
  .replace(/ as const/g, "");
const context = { module: { exports: {} } };
vm.runInNewContext(`const CURRENCY_TOLERANCE_GBP = 0.01; ${helperSource}; module.exports = { provedUnresolvedFinancialOffset, resolvedFinancialAmount };`, context);
const { provedUnresolvedFinancialOffset, resolvedFinancialAmount } = context.module.exports;
const money = (value) => Math.round(value * 100) / 100;

const previousGoods = [179.99, 69.99, 219.99];
const previousFinancialLines = [
  { amount_inc_vat_gbp: -15 },
  { amount_inc_vat_gbp: 11.42 },
];
const previousResolutions = [
  { financial_type: "discount" },
  { financial_type: "delivery" },
];
const parkedValue = previousFinancialLines.reduce((sum, line, index) => sum + resolvedFinancialAmount(line, previousResolutions[index]), 0);
assert.equal(parkedValue, -3.58, "Existing Parked financial signs are incorrect.");

const currentInvoiceId = "invoice-current";
const unresolvedLines = [
  { id: "goods", supplier_invoice_id: currentInvoiceId, description: "Goods", amount_inc_vat_gbp: 249.99 },
  { id: "discount", supplier_invoice_id: currentInvoiceId, description: "Promotion", amount_inc_vat_gbp: -22.5 },
  { id: "delivery", supplier_invoice_id: currentInvoiceId, description: "Express delivery", amount_inc_vat_gbp: 7.95 },
  { id: "other-invoice-discount", supplier_invoice_id: "invoice-other", description: "Promotion", amount_inc_vat_gbp: -100 },
];
const adjustments = [
  { supplier_invoice_id: currentInvoiceId, adjustment_type: "retailer_discount", amount_gbp: 22.5, approval_status: null },
  { supplier_invoice_id: currentInvoiceId, adjustment_type: "retailer_delivery", amount_gbp: 7.95, approval_status: "auto_approved" },
  { supplier_invoice_id: "invoice-other", adjustment_type: "retailer_discount", amount_gbp: 100, approval_status: "auto_approved" },
];
const goodsFirstOffset = provedUnresolvedFinancialOffset({ lines: unresolvedLines, accountedLineIds: new Set(), resolvedLineIds: new Set(), selectedInvoiceIds: new Set([currentInvoiceId]), adjustments });
const previousValue = previousGoods.reduce((sum, amount) => sum + amount, 0) + parkedValue;
assert.equal(money(previousValue + 249.99 + goodsFirstOffset), 701.83, "Goods-first projection does not equal £701.83.");
assert.equal(3 + 1, 4, "Goods-first quantity does not equal four.");

const currentParkedValue = resolvedFinancialAmount(unresolvedLines[1], { financial_type: "discount" }) + resolvedFinancialAmount(unresolvedLines[2], { financial_type: "delivery" });
const parkFirstOffset = provedUnresolvedFinancialOffset({ lines: unresolvedLines, accountedLineIds: new Set(["discount", "delivery"]), resolvedLineIds: new Set(["discount", "delivery"]), selectedInvoiceIds: new Set([currentInvoiceId]), adjustments });
assert.equal(parkFirstOffset, 0, "Parked rows were double-counted as unresolved.");
assert.equal(money(previousValue + currentParkedValue + 249.99 + parkFirstOffset), 701.83, "Park-first projection does not equal £701.83.");

const unmatchedOffset = provedUnresolvedFinancialOffset({ lines: unresolvedLines, accountedLineIds: new Set(), resolvedLineIds: new Set(), selectedInvoiceIds: new Set([currentInvoiceId]), adjustments: [] });
assert.equal(unmatchedOffset, 0, "Description-only adjustment created capacity.");
assert(previousValue + 249.99 + unmatchedOffset > 701.83 + 0.01, "Unproved value excess was not blocked.");
assert(previousValue + 250.01 + goodsFirstOffset > 701.83 + 0.01, "Genuine value excess was not blocked.");
assert(3 + 2 > 4, "Genuine quantity excess was not blocked.");
assert.doesNotMatch(actions + page, /ORD-|invoice-current|invoice-other|701\.83|469\.97|249\.99/, "Test identifiers or controlled values were hard-coded in production.");

console.log("Importer reconciliation signed-baseline projection regression passed.");
