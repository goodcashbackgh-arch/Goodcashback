# Pre-Final-Sale Payment Presentation Addendum v1

Status: locked corrective governing addendum for implementation.

## 1. Purpose

Correct a customer-facing presentation defect where the canonical final-sale settlement amount is surfaced before any posted customer sale document exists, causing applied account credit to appear additive even though it is already included in the canonical settlement amount.

## 2. Existing authorities preserved

This addendum extends and must not alter:

- `FINAL_SALE_VALUE_AND_BALANCE_DUE_ADDENDUM_v1.md`;
- `CANONICAL_SETTLEMENT_CLASSIFICATION_AND_INCREMENTAL_RESOLUTION_ADDENDUM_v1.md`;
- `order_funding_position_vw`;
- `order_audience_status_v1(uuid)`;
- DVA reconciliation and statement-line control;
- importer credit ledger application/reversal;
- FX/card-difference classification;
- final-balance payment allocation;
- Sage, VAT, shipment, supplier and accounting controls.

No database object or economic amount is changed by this patch.

## 3. Locked phase boundary

### Pre-final-sale phase

Where no posted customer sale document exists for the order:

- accepted estimate remains the commercial reference;
- initial funding presentation is sourced from `order_funding_position_vw`;
- confirmed cash payment is `confirmed_dva_funding_gbp`;
- applied account credit is `applied_credit_gbp`;
- total accepted-estimate funding may remain available for status/gating but must not be presented as a separate settlement amount in a way that duplicates the displayed account-credit component;
- canonical final-sale settlement fields remain backend truth but are not used as the customer payment headline.

### Final-sale phase

Once at least one posted customer sale document exists:

- canonical settlement presentation becomes authoritative;
- `canonical_amount_received_gbp`, `final_sale_value_gbp`, `canonical_balance_due_gbp`, final-balance payments and pending-credit presentation remain governed by the existing final-sale settlement contracts.

## 4. Existing presentation boundary

The customer operations route already includes:

- `app/customer/orders/[order_id]/operations/layout.tsx`;
- `app/customer/orders/[order_id]/operations/SettlementCustomerPatch.tsx`.

That existing wrapper is the surgical presentation boundary for this correction. The large customer operations page must remain unchanged.

The layout may read only the existing phase/funding authorities required to tell the presentation patch:

- whether final-sale customer documents are posted;
- the confirmed DVA cash payment amount.

The client presentation patch may then:

- keep the existing `Amount received` -> `Payment applied to this order` wording correction;
- before final-sale confirmation, replace only the displayed amount paired with that label with confirmed DVA cash payment;
- after final-sale confirmation, leave the existing canonical amount untouched.

It must not alter hidden data, status, calculations, links, actions, account-credit values, final-balance values, or any other text/value.

## 5. Importer operations dependency

The importer operations page consumes the same canonical and funding sources but already exposes explicit `Confirmed payment` and `Applied credit` component cards. This corrective build does not change importer runtime presentation. Any importer simplification is a separate UI decision and is out of scope.

## 6. Acceptance cases

### A. No posted customer sale document; cash plus applied credit

Given:

- accepted estimate £740.00;
- confirmed DVA funding £739.21;
- applied account credit £0.79;
- no posted customer sale document.

Customer payment presentation must show:

- Payment applied to this order: £739.21;
- Account credit applied: £0.79.

It must not present £740.00 as the payment row while also separately displaying £0.79 credit.

### B. Posted customer sale document exists

When final-sale evidence exists, the displayed payment amount remains the existing canonical settlement amount without modification.

### C. No account credit

Where applied credit is zero, existing display conditions remain unchanged.

## 7. No-impact boundary

Do not change:

- `app/customer/orders/[order_id]/operations/page.tsx`;
- database functions/views/tables;
- DVA funding amounts;
- funding completion threshold;
- account-credit application;
- canonical settlement arithmetic;
- FX/card-difference handling;
- supplier allocation;
- final-balance allocation;
- Sage/VAT/accounting;
- importer operations runtime;
- unrelated customer UI.