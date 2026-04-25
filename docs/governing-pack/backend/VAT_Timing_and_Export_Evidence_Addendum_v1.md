# VAT Timing & Export Evidence Addendum v1

**Project:** Multi Tenant Platform Build  
**Status:** Governing VAT timing amendment  
**Purpose:** Correct the earlier dispatch-date-only VAT timing rule for the platform's usual known-goods prepayment model.

## 1. Governing effect

This addendum amends the VAT timing sections of:

1. Architecture Completion Addendum v2
2. Canonical Schema Reference v1
3. Master End-to-End Orchestration v3
4. Technical Resource Map by Node v2
5. closure_v2_functions_v2.sql
6. Day 8 VAT smoke tests

Where older documents say that VAT tax point is always the earliest linked shipment `dispatched_at`, this addendum overrides that wording.

## 2. Correct platform VAT timing rule

For the normal platform flow, the importer/customer prepayment is usually for known quoted goods. The order has an order reference, authorisation/payment reference, known submitted items/categories, declared value, and a quoted commercial basis.

Therefore, where a qualifying prepayment/deposit is received before dispatch or final invoice, the VAT timing event is the prepayment/deposit date to the extent covered by the payment.

The shipment dispatch date remains important, but mainly as the export/zero-rating evidence checkpoint and fallback basic timing event where no qualifying prepayment exists.

## 3. Box 6 treatment

The VAT workings must include the supply value in Box 6 in the return period of the qualifying prepayment/deposit tax point, to the extent covered by the payment.

If the final sales invoice is issued in a later VAT period, the later invoice must not duplicate the value already included from the prepayment period.

The VAT reporting pack must therefore show:

- prepayment/deposit value already reported in the earlier period;
- later invoice value excluded or reversed from the later period where it would otherwise duplicate Box 6;
- any remaining unpaid balance, if any, reported in the later period when invoiced or paid.

## 4. Export evidence and zero-rating release

Zero-rating is still conditional. The platform may recognise the VAT timing event from prepayment, but final zero-rating release remains blocked until export/evidence conditions are satisfied.

The evidence checkpoint still requires appropriate export evidence, normally including shipment/export evidence, commercial documentation, and POD or equivalent support according to the project evidence model.

## 5. Export/evidence deadline breach

The export/evidence time limit runs from the time of supply. In the platform's normal prepayment model, that means the time limit usually runs from the qualifying prepayment/deposit tax point.

If the export/evidence conditions are not satisfied by the deadline, the reporting pack must show the breached prepayments/supplies whose deadline expired in the current VAT return period.

The required output is a Box 1 adjustment in the period the deadline expires. The adjustment amount should be the output VAT due, not the gross sale value.

If export evidence is later obtained and reinstatement is supportable, the correction/reversal should be shown in the period in which the evidence/reinstatement condition is met.

## 6. Sage/accounting split

Sage prepayment/deposit posting and final sales invoice posting remain separate accounting events.

- Bank receipt / prepayment: bank to customer account / deposit-prepayment control.
- Final sales invoice: customer account / deposit-prepayment control to sales, as applicable.
- VAT workings: use the tax-point logic above and avoid duplicate Box 6 reporting.

Sage is not the VAT timing authority by itself. VAT workings are the reporting authority for period treatment.

## 7. Required backend controls

The backend must support:

1. Deriving VAT timing from the earliest qualifying prepayment/deposit date where available.
2. Falling back to earliest linked shipment dispatch date only if no qualifying prepayment exists.
3. Preventing replacement child orders from creating a fresh Box 6 event by default.
4. Blocking VAT release while child exceptions, payouts, shipper liabilities, or export evidence gaps remain unresolved.
5. Reporting carry-in/carry-out adjustments to avoid duplicate Box 6 reporting.
6. Reporting Box 1 breach adjustments when export/evidence deadline is missed.
7. Reporting later reinstatement adjustments if evidence is later obtained.

## 8. Plain-English rule

For this platform:

> If the importer/customer prepays for known quoted goods in April and the final invoice is issued in May, the VAT workings should treat April as the primary Box 6 timing period for the prepaid amount. The May invoice should not duplicate the April amount. If the export/evidence deadline is missed, the Box 1 VAT adjustment belongs in the period the deadline expires.
