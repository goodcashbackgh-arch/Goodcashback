import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const actionsPath = "app/importer/reconciliation/[order_id]/actions.ts";
const layoutPath = "app/importer/reconciliation/[order_id]/layout.tsx";

const actions = readFileSync(actionsPath, "utf8");
const layout = readFileSync(layoutPath, "utf8");

// Repository-source regression only. This file performs no database writes and
// does not replace the live database proof already captured for the target order.

// Progression guard: preserve the existing write route and add only the
// order-wide read inputs needed to mirror the importer page calculation.
assert.match(actions, /operator_mark_supplier_invoice_line_progressed/, "single progression RPC must remain unchanged");
assert.match(actions, /operator_bulk_mark_supplier_invoice_lines_progressed/, "bulk progression RPC must remain unchanged");
assert.match(actions, /from\("supplier_invoice_line_resolutions"\)[\s\S]*?eq\("active", true\)/, "active Parked financial rows must be read");
assert.match(actions, /from\("dispute_lines"\)[\s\S]*?disputes!inner\(resolved_at\)/, "open physical exceptions must be read");
assert.match(actions, /from\("order_value_adjustments"\)[\s\S]*?adjustment_type, amount_gbp, approval_status/, "declared delivery and discount facts must be read");
assert.match(actions, /const targetInvoiceIds = new Set\(selectedLines\.map\(\(line\) => line\.supplier_invoice_id\)\)/, "signed allowance must be restricted to represented supplier invoices");
assert.match(actions, /adjustment\.supplier_invoice_id === invoiceId/, "adjustments must be matched to the same supplier invoice");
assert.match(actions, /delivery\|shipping\|postage\|freight\|carriage/, "delivery vocabulary must remain aligned with the importer page");
assert.match(actions, /discount\|promotion\|promotional\|promo\|voucher\|coupon\|saving\|savings/, "discount vocabulary must remain aligned with the importer page");
assert.match(actions, /Math\.abs\(extractedDelivery - declaredDelivery\) <= CURRENCY_TOLERANCE_GBP/, "delivery requires exact aggregate agreement within tolerance");
assert.match(actions, /Math\.abs\(extractedDiscount - declaredDiscount\) <= CURRENCY_TOLERANCE_GBP/, "discount requires exact aggregate agreement within tolerance");
assert.match(actions, /qty: totals\.qty \+ \(progressed \|\| disputed \? values\.qty : 0\)/, "Parked financial rows must not increase physical quantity");
assert.match(actions, /amount: totals\.amount \+ \(progressed \|\| disputed \|\| resolved \? values\.amount : 0\)/, "Parked financial rows must contribute signed accounted value");
assert.match(actions, /projectedAmount = round2\(accounted\.amount \+ selectedUnresolvedTotals\.amount \+ unresolvedMatchedFinancialOffset\)/, "projected value must include the signed unresolved same-invoice offset");
assert.match(actions, /NON_PHYSICAL_PROGRESSION_ERROR/, "financial rows must remain blocked from physical progression");
assert.doesNotMatch(actions, /abf15b7b-771f-482f-9751-2af0ee0bcbb1|NIN-240726-[ABC]|e4fd64f3-03e8-4bc1-8ed1-24e3e22569b9/, "production progression logic must not hard-code the proof order, invoice or line");

// Settlement banner: retain the audience RPC and existing presentation while
// adding only the proved readiness/open-cycle display gates.
assert.match(layout, /rpc\("order_settlement_audience_v1"/, "existing settlement audience RPC must remain authoritative");
assert.match(layout, /select\("review_status, blocked_from_sage_yn"\)/, "banner gate must read only the live invoice state it needs");
assert.match(layout, /RETIRED_INVOICE_REVIEW_STATUSES/, "retired invoices must not keep the cycle open");
assert.match(layout, /APPROVED_INVOICE_REVIEW_STATUSES/, "approved-current statuses must be explicit");
assert.match(layout, /invoiceStateError\s*\? true/, "invoice-state read failure must fail closed");
assert.match(layout, /settlement\?\.resolution_status !== "not_ready_no_final_sale"/, "initial no-final-sale cycle must suppress the banner");
assert.match(layout, /!openSupplierInvoiceCycle/, "later open supplier-invoice cycles must suppress the banner");
assert.match(layout, /Settlement difference partially accounted for/, "existing banner wording must remain unchanged");
assert.doesNotMatch(layout, /\.insert\(|\.update\(|\.delete\(/, "banner patch must remain read-only");

const round2 = (value) => Math.round(value * 100) / 100;
const projectedValue = ({ accounted, selectedGoods, unresolvedSignedOffset }) =>
  round2(accounted + selectedGoods + unresolvedSignedOffset);

// Live proved A calculation.
assert.equal(
  projectedValue({ accounted: 434.98, selectedGoods: 499.99, unresolvedSignedOffset: -50.01 }),
  884.96,
  "A must progress exactly to the £884.96 order baseline"
);

// Generic signed variations.
assert.equal(projectedValue({ accounted: 100, selectedGoods: 90, unresolvedSignedOffset: 10 }), 200, "delivery-only variation must add delivery");
assert.equal(projectedValue({ accounted: 100, selectedGoods: 110, unresolvedSignedOffset: -10 }), 200, "discount-only variation must subtract discount");
assert.equal(projectedValue({ accounted: 100, selectedGoods: 100, unresolvedSignedOffset: 10 - 10 }), 200, "combined delivery and discount must preserve their signs");
assert.equal(projectedValue({ accounted: 100, selectedGoods: 100, unresolvedSignedOffset: 5 + 5 - 3 - 7 }), 200, "multiple rows must aggregate by signed type totals");
assert.equal(projectedValue({ accounted: 434.98, selectedGoods: 499.99, unresolvedSignedOffset: 0 }), 934.97, "an unmatched discount must not create capacity");

const accountedPosition = (lines) =>
  lines.reduce(
    (totals, line) => ({
      qty: totals.qty + (line.progressed || line.disputed ? line.qty : 0),
      amount: totals.amount + (line.progressed || line.disputed || line.resolved ? line.amount : 0),
    }),
    { qty: 0, amount: 0 }
  );

assert.deepEqual(
  accountedPosition([
    { qty: 1, amount: 179.99, progressed: true, disputed: false, resolved: false },
    { qty: 1, amount: -10, progressed: false, disputed: false, resolved: true },
    { qty: 1, amount: 10.01, progressed: false, disputed: false, resolved: true },
  ]),
  { qty: 1, amount: 180 },
  "Parked delivery/discount rows must affect value but not physical quantity"
);

const retired = new Set(["rejected_resubmit_required", "superseded", "duplicate_blocked"]);
const approved = new Set(["approved_current", "ref_corrected_approved"]);
const hasOpenInvoiceCycle = (invoices, readFailed = false) =>
  readFailed ||
  invoices.some((invoice) => {
    const status = invoice.review_status ?? "";
    if (retired.has(status)) return false;
    return !approved.has(status) || invoice.blocked_from_sage_yn !== false;
  });
const showSettlement = ({ totalDifference, resolutionStatus, invoices, readFailed = false }) =>
  totalDifference > 0.01 &&
  resolutionStatus !== "not_ready_no_final_sale" &&
  !hasOpenInvoiceCycle(invoices, readFailed);

assert.equal(
  showSettlement({ totalDifference: 80.03, resolutionStatus: "not_ready_no_final_sale", invoices: [] }),
  false,
  "the proved £80.03 initial-cycle banner must be hidden"
);
assert.equal(
  showSettlement({
    totalDifference: 80.03,
    resolutionStatus: "partially_resolved",
    invoices: [{ review_status: "pending_review", blocked_from_sage_yn: true }],
  }),
  false,
  "a later open supplier-invoice cycle must hide the banner"
);
assert.equal(
  showSettlement({
    totalDifference: 80.03,
    resolutionStatus: "partially_resolved",
    invoices: [{ review_status: "approved_current", blocked_from_sage_yn: false }],
  }),
  true,
  "the existing banner must return after settlement readiness and invoice closure"
);
assert.equal(
  showSettlement({
    totalDifference: 80.03,
    resolutionStatus: "partially_resolved",
    invoices: [{ review_status: "rejected_resubmit_required", blocked_from_sage_yn: true }],
  }),
  true,
  "retired invoices must not keep the cycle open"
);
assert.equal(
  showSettlement({ totalDifference: 80.03, resolutionStatus: "partially_resolved", invoices: [], readFailed: true }),
  false,
  "invoice-state read failure must hide rather than prematurely show the banner"
);
assert.equal(
  showSettlement({ totalDifference: 0.01, resolutionStatus: "fully_resolved", invoices: [] }),
  false,
  "the existing £0.01 display tolerance must remain unchanged"
);

console.log(JSON.stringify({
  regression_result: "PASS",
  details: "Signed same-invoice progression capacity and settlement-banner readiness gates are locked without replacing progression RPCs or mutating settlement data.",
}, null, 2));
