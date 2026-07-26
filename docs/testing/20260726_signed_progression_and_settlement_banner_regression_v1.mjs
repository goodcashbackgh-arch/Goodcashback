import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const layout = readFileSync(
  "app/importer/reconciliation/[order_id]/layout.tsx",
  "utf8",
);

assert.match(
  layout,
  /\.from\("supplier_invoices"\)[\s\S]*\.select\("review_status, blocked_from_sage_yn"\)[\s\S]*\.eq\("order_id", orderId\)/,
  "settlement readiness must read only the supplier-invoice state for the current order",
);
assert.match(
  layout,
  /const retiredSupplierInvoiceStatuses = new Set\(\[\s*"rejected_resubmit_required",\s*"superseded",\s*"duplicate_blocked",\s*\]\)/,
  "rejected, superseded and duplicate-blocked invoices must be retired",
);
assert.match(
  layout,
  /const approvedSupplierInvoiceStatuses = new Set\(\[\s*"approved_current",\s*"ref_corrected_approved",\s*\]\)/,
  "both proven approved states must close invoice review",
);
assert.match(
  layout,
  /supplierInvoiceStateError\s*\? true\s*:/,
  "invoice-state read errors must fail closed",
);
assert.match(
  layout,
  /!retiredSupplierInvoiceStatuses\.has\(reviewStatus\)[\s\S]*&& \(!approvedSupplierInvoiceStatuses\.has\(reviewStatus\) \|\| invoice\.blocked_from_sage_yn === true\)/,
  "any active unapproved or Sage-blocked invoice must keep the cycle open",
);
assert.match(
  layout,
  /const showSettlement = totalDifference > 0\.01\s*&& !supplierInvoiceCycleOpen\s*&& settlement\?\.resolution_status !== "not_ready_no_final_sale"/,
  "the banner must require a closed invoice cycle and a final sale",
);

assert.equal(
  (layout.match(/\.rpc\("order_settlement_audience_v1", \{ p_order_id: orderId \}\)/g) ?? []).length,
  1,
  "the existing canonical settlement RPC must remain the sole settlement source",
);
assert.match(layout, /const totalDifference = credit \+ otherAdjustment \+ pending;/);
assert.match(layout, /const fullyResolved = settlement\?\.resolution_status === "fully_resolved" && pending <= 0\.01;/);
assert.match(layout, /const overResolved = settlement\?\.resolution_status === "over_resolved_review";/);
assert.match(layout, /Total difference \{money\(totalDifference\)\}\. Credit added \{money\(credit\)\}\. Other settlement adjustment \{money\(otherAdjustment\)\}\. Pending supervisor review \{money\(pending\)\}\./);

for (const forbidden of ["insert(", "update(", "upsert(", "delete("]) {
  assert.doesNotMatch(layout, new RegExp(`\\.${forbidden.replace("(", "\\(")}`));
}

console.log(
  "PASS: active unapproved or Sage-blocked supplier invoices fail closed and hide the unchanged canonical settlement banner until the invoice cycle is ready.",
);
