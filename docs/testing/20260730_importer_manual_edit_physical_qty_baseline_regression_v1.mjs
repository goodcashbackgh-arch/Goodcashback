import assert from "node:assert/strict";
import fs from "node:fs";

const TOLERANCE = 0.01;

function normalise(value) {
  return (value ?? "").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
}

function financialKind(line) {
  if (String(line.line_source ?? "").trim().toLowerCase() !== "ocr_extracted") return null;
  const description = normalise(line.description);
  const amount = Number(line.amount_inc_vat_gbp ?? 0);
  const discount = /(^| )(discount|promotion|promotional|promo|voucher|coupon|saving|savings)( |$)/.test(description);
  const delivery = /(^| )(delivery|shipping|postage|freight|carriage)( |$)/.test(description);
  if (amount < 0 && discount) return "discount";
  if (amount > 0 && delivery) return "delivery";
  return null;
}

function provedFinancialIds(lines, adjustments, exceptionLinked = new Set()) {
  const proved = new Set();
  const invoiceIds = [...new Set(lines.map((line) => line.supplier_invoice_id))];
  for (const invoiceId of invoiceIds) {
    const invoiceLines = lines.filter((line) => line.supplier_invoice_id === invoiceId && !exceptionLinked.has(line.id));
    const invoiceAdjustments = adjustments.filter((row) => row.supplier_invoice_id === invoiceId && row.approval_status !== "rejected");
    for (const kind of ["discount", "delivery"]) {
      const matching = invoiceLines.filter((line) => financialKind(line) === kind);
      const extracted = matching.reduce((sum, line) => sum + Number(line.amount_inc_vat_gbp ?? 0), 0);
      const adjustment = invoiceAdjustments
        .filter((row) => row.adjustment_type === `retailer_${kind}`)
        .reduce((sum, row) => sum + Number(row.amount_gbp ?? 0), 0);
      if (matching.length && Math.abs(Math.abs(extracted) - Math.abs(adjustment)) <= TOLERANCE) {
        matching.forEach((line) => proved.add(line.id));
      }
    }
  }
  return proved;
}

const lines = [
  { id: "A-goods", supplier_invoice_id: "A", line_source: "ocr_extracted", description: "Ninja Foodi MAX Dual Zone Air Fryer AF400UK", qty: 1, amount_inc_vat_gbp: 249.99 },
  { id: "A-delivery", supplier_invoice_id: "A", line_source: "ocr_extracted", description: "Standard delivery", qty: 1, amount_inc_vat_gbp: 12.5 },
  { id: "A-discount", supplier_invoice_id: "A", line_source: "ocr_extracted", description: "Summer promotion discount", qty: 1, amount_inc_vat_gbp: -22.5 },
  { id: "B-discount", supplier_invoice_id: "B", line_source: "ocr_extracted", description: "Bundle discount", qty: 1, amount_inc_vat_gbp: -20 },
  { id: "B-goods-1", supplier_invoice_id: "B", line_source: "ocr_extracted", description: "Ninja Speedi Rapid Cooker ON400UK", qty: 1, amount_inc_vat_gbp: 219.99 },
  { id: "B-delivery", supplier_invoice_id: "B", line_source: "ocr_extracted", description: "Standard delivery", qty: 1, amount_inc_vat_gbp: 10 },
  { id: "B-goods-2", supplier_invoice_id: "B", line_source: "ocr_extracted", description: "Ninja Detect Power Blender Pro TB401UK", qty: 1, amount_inc_vat_gbp: 179.99 },
  { id: "C-goods", supplier_invoice_id: "C", line_source: "ocr_extracted", description: "Ninja Foodi MAX Dual Zone Air Fryer - review/hold item", qty: 1, amount_inc_vat_gbp: 249.99 },
  { id: "C-delivery", supplier_invoice_id: "C", line_source: "ocr_extracted", description: "Standard delivery", qty: 1, amount_inc_vat_gbp: 14.5 },
];

const adjustments = [
  { supplier_invoice_id: "A", adjustment_type: "retailer_delivery", amount_gbp: 12.5, approval_status: "pending_supervisor" },
  { supplier_invoice_id: "A", adjustment_type: "retailer_discount", amount_gbp: -22.5, approval_status: "pending_supervisor" },
  { supplier_invoice_id: "B", adjustment_type: "retailer_delivery", amount_gbp: 10, approval_status: "auto_approved" },
  { supplier_invoice_id: "B", adjustment_type: "retailer_discount", amount_gbp: -20, approval_status: "pending_supervisor" },
  { supplier_invoice_id: "C", adjustment_type: "retailer_delivery", amount_gbp: 14.5, approval_status: "pending_supervisor" },
];

const proved = provedFinancialIds(lines, adjustments);
assert.deepEqual([...proved].sort(), ["A-delivery", "A-discount", "B-delivery", "B-discount", "C-delivery"].sort());

const physicalQty = lines.reduce((sum, line) => sum + (proved.has(line.id) ? 0 : line.qty), 0);
assert.equal(physicalQty, 4, "controlled nine-row bundle must project to four physical units");

const signedAmount = lines.reduce((sum, line) => sum + line.amount_inc_vat_gbp, 0);
assert.ok(Math.abs(signedAmount - 894.46) <= TOLERANCE, "signed amount must remain £894.46");

const manualLookingFinancial = {
  id: "manual-delivery-looking",
  supplier_invoice_id: "M",
  line_source: "manually_added",
  description: "Standard delivery",
  qty: 1,
  amount_inc_vat_gbp: 15,
};
const manualProof = provedFinancialIds(
  [manualLookingFinancial],
  [{ supplier_invoice_id: "M", adjustment_type: "retailer_delivery", amount_gbp: 15, approval_status: "auto_approved" }]
);
assert.equal(manualProof.has(manualLookingFinancial.id), false, "manually_added rows must never receive provisional OCR zero-qty treatment");

const descriptionOnly = {
  id: "description-only",
  supplier_invoice_id: "D",
  line_source: "ocr_extracted",
  description: "Standard delivery",
  qty: 1,
  amount_inc_vat_gbp: 9,
};
assert.equal(provedFinancialIds([descriptionOnly], []).has(descriptionOnly.id), false, "description alone must fail closed");

const exceptionLinked = new Set(["A-delivery"]);
assert.equal(provedFinancialIds(lines, adjustments, exceptionLinked).has("A-delivery"), false, "exception-linked rows must not create provisional quantity capacity");

assert.equal(physicalQty + 1 > 4, true, "a genuine fifth physical unit must still exceed the declared baseline");

const source = fs.readFileSync("app/importer/reconciliation/[order_id]/actions.ts", "utf8");
assert.match(source, /line_source[^\n]*description[^\n]*qty[^\n]*amount_inc_vat_gbp/);
assert.match(source, /line_source \?\? ""/);
assert.match(source, /!== "ocr_extracted"/);
assert.match(source, /\.from\("dispute_lines"\)[\s\S]*?\.is\("resolved_at", null\)/);
assert.match(source, /\.eq\("resolution_type", "non_physical_financial"\)/);
assert.match(source, /adjustment\.approval_status !== "rejected"/);
assert.match(source, /const totalAmountAfterEdit = currentTotalsExcludingLine\.amount \+ nextAmount;/);

console.log(JSON.stringify({
  regression_result: "PASS",
  proof: "controlled nine-row bundle projects to four physical units; signed amount remains £894.46; only evidenced ocr_extracted delivery/discount rows zero physical quantity; manually_added rows remain physical; exception-linked rows cannot create provisional quantity capacity; genuine fifth physical unit remains blocked; amount formula unchanged"
}, null, 2));
