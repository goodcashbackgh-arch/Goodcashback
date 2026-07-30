# Partial Physical Receipt Residual Final Balance Addendum v1

## Status

Scope-frozen accounting and implementation addendum for the existing 28 July receipt-residual audience overlay.

## Defect

The existing 28 July audience overlay treats an already-received physical receipt residual on an all-or-nothing basis: if the broader attributed receipt fully covers the final sale it suppresses the balance; otherwise it leaves the canonical balance unchanged.

That is incorrect for a partially covering physical receipt residual and is too broad because attributed-receipt totals may include FX/card residual amounts that are not customer payment.

## Accounting rule

The existing pre-overlay canonical balance remains authoritative for all established funding, applied-credit, final-sale, credit-note and prior final-balance-payment arithmetic.

Only the still-order-applied physical receipt residual adjusts that balance:

`still_order_applied_residual = max(active_non_reversed_pending_residual - exact_linked_overfunding_credit_created_from_that_residual, 0)`

`collectible_balance = max(existing_pre_overlay_canonical_balance - still_order_applied_residual, 0)`

No FX/card amount is part of either formula.

## Model treatments

1. No active physical receipt residual: preserve the existing canonical balance unchanged.
2. Partial uncredited residual: reduce the existing balance by the residual.
3. Residual greater than the existing balance: collectible balance floors at zero; no credit is created automatically.
4. Residual partly converted into exact customer overfunding credit: only the uncredited remainder continues to reduce the original order balance.
5. Residual fully converted into exact customer overfunding credit: none of that residual remains available to reduce the original order balance.
6. Linked credit exceeds the residual or fails exact provenance checks: fail closed; no unsupported additional balance reduction.
7. Prior final-balance payment: already reflected in the existing canonical balance and is not recalculated or counted again.
8. Existing account credit applied to the order: already reflected upstream and is not deducted again here.
9. Reversed pending residual: historical only and excluded.
10. De-minimis residual of £0.01 or less: no audience balance adjustment.
11. FX/card differences: excluded entirely from customer collectible-balance arithmetic.

## Controlled live examples

### ORD-1785274708774

- physical customer receipt: £702.76
- cash initially applied to funding: £664.63
- existing account credit applied: £37.20
- funded total: £701.83
- active physical receipt residual: £38.13
- final order value: £749.43
- existing canonical shortfall: £47.60
- collectible balance after this rule: £9.47

The £37.20 applied account credit is already inside the £701.83 funded total and must not be deducted again. The £38.13 physical residual is not FX and is not automatically converted into customer credit.

### ORD-1784976429191

- existing final-sale shortfall: £44.00
- physical receipt residual: £81.20
- exact new customer overfunding credit created from that residual: £37.20
- residual still attached to the original order: £44.00
- collectible balance: £0.00

The £37.20 is new credit for future use; it is not credit applied to the same order.

## Implementation boundary

On current `main`, the 28 July migration made `public.order_audience_status_v1(uuid)` the receipt-residual wrapper and preserved its exact predecessor as `public.order_audience_status_pre_receipt_residual_overlay_v1(uuid)`.

The repair therefore replaces only the current `public.order_audience_status_v1(uuid)` definition created by that 28 July overlay. It must continue to call `public.order_audience_status_pre_receipt_residual_overlay_v1(uuid)` as the authoritative base and adjust only the audience-facing `canonical_balance_due_gbp` plus the same customer/importer status/action suppression already owned by the 28 July overlay when the corrected balance reaches zero.

The migration must fail closed if the current top-level audience function no longer directly contains the 28 July predecessor call. It must not depend on any unmerged or assumed audience-wrapper function.

All supplier-rejection, evidence-query, reconciliation and tracking behaviour already present in the preserved predecessor remains unchanged and passes through normally.

## Explicitly untouched

This addendum authorises no change to:

- order funding or `order_funding_position_vw`;
- `order_funding_events`;
- DVA reconciliation or statement-line allocation logic;
- final-balance allocation RPCs/workbench behaviour;
- importer credit creation/application mechanics;
- pending-surplus creation or confirmation mechanics;
- FX/card classification or accounting;
- Sage posting/accounting/VAT logic;
- supplier invoice/reconciliation logic;
- tracking/shipment logic;
- holds/disputes;
- customer/importer page code, wording, styling or navigation;
- permissions other than preserving the existing execution boundary of `order_audience_status_v1(uuid)`.

## Provenance requirement for carved-out customer credit

A linked credit reduces the active physical residual only when it is the exact established overfunding credit for the same importer and order, including matching ledger identity and the source fields written by the established pending-surplus confirmation route. Otherwise the calculation fails closed and leaves the balance higher rather than granting an unsupported reduction.

## Regression requirements

The regression must prove:

- the repair is in the current 28 July top-level audience wrapper and still calls only `order_audience_status_pre_receipt_residual_overlay_v1(uuid)` as its audience base;
- no assumed/unmerged `order_audience_status_pre_importer_tracking_assignment_v1(uuid)` dependency exists in the repair;
- the repaired audience function contains no write path;
- no FX/card or attributed-receipt field participates in the balance formula;
- no second funding/final-sale calculation is introduced into the audience function;
- the scenario matrix above passes;
- ORD-1785274708774 resolves from £47.60 to £9.47 using the £38.13 active physical residual;
- ORD-1784976429191 resolves its £44.00 shortfall to zero while preserving the £37.20 as separate newly created overfunding credit.

## Scope freeze

Any proposed change outside this one audience function, its regression proof, or this addendum is outside this build and requires a separate diagnosis and explicit approval.