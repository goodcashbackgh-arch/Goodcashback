# Canonical Settlement Classification and Incremental Resolution Addendum v1

Status: locked corrective governing addendum for implementation. This document does not itself change live database, application, Sage, VAT or accounting data.

Source branch at drafting: `agent/canonical-settlement-classification-v1`

Evidence basis:

- live order `ORD-1784498556959`;
- physical inbound statement value `GBP 900.00`;
- order funding committed `GBP 884.96`;
- original receipt residual `GBP 15.04`;
- posted final order value `GBP 819.97`;
- existing confirmed customer credit `GBP 15.04`;
- confirmed FX/card difference `GBP 0.00`;
- remaining unresolved difference `GBP 64.99`;
- no open dispute and no active hold;
- current inconsistent use of `order_surplus_evidence_position_v2`, `order_surplus_evidence_position_v3`, final-sale settlement status, and the credit ledger across internal, customer and importer pages.

## 1. Purpose

This addendum locks one canonical settlement-resolution position so partial and repeated supervisor decisions remain consistent across:

- internal funding and surplus evidence;
- customer order details;
- importer order dashboard;
- importer invoice reconciliation;
- account-credit balances;
- FX/card-difference allocations;
- later final-sale document changes and reversals.

It corrects the unsafe assumption that the existence of any customer-credit row means the whole settlement difference is resolved.

## 2. Authority and precedence

This addendum extends and must be read with:

1. `docs/governing-pack/CURRENT_LOCKED_PACK.md`;
2. `docs/governing-pack/ui/FINAL_SALE_VALUE_AND_BALANCE_DUE_ADDENDUM_v1.md`;
3. `docs/governing-pack/ui/CANONICAL_AUDIENCE_STATUS_CONTRACT_v1.md`;
4. `docs/governing-pack/accounting/TREASURY_STATEMENT_CONTROL_ROUTING_AND_SEQUENTIAL_ALLOCATION_ADDENDUM_v1.md`;
5. the existing funding, importer-credit, FX/card-difference, statement-line control, reversal, Sage and VAT contracts.

Where an older implementation assumes that any positive approved credit makes the entire difference complete, this addendum controls.

## 3. Existing controls that must remain unchanged

The build must preserve:

- immutable statement files and physical statement-line amounts;
- accepted-estimate funding thresholds;
- `dva_reconciliation` as the existing order-funding write path;
- final-balance payment allocations;
- `importer_credit_ledger` as the available customer-credit ledger;
- `dva_statement_line_allocations` as the FX/card-difference allocation layer;
- pending-surplus reservation and its linked funding identity;
- supplier invoice, customer sales, shipment, dispute and hold controls;
- existing credit application to later orders;
- current Sage, cash-posting and VAT boundaries;
- historical decisions and reversals.

This correction must not rewrite physical receipt evidence, funding events, posted sales documents, approved credits or confirmed FX allocations.

## 4. Canonical internal settlement equation

For every original order with final sale evidence, the internal canonical position must satisfy:

```text
gross_positive_difference_gbp
  = confirmed_customer_credit_gbp
  + confirmed_fx_card_difference_gbp
  + other_governed_resolution_gbp
  + remaining_unresolved_gbp
```

For the current scope, `other_governed_resolution_gbp` is zero unless an existing separately governed reversal/restoration lane applies.

The canonical calculations are:

```text
canonical_order_attributed_receipt_gbp
  = active order-attributed inbound statement value
  + confirmed final-balance payments
  + applied account credit where already governed

final_order_value_gbp
  = signed total of posted customer sale documents

gross_positive_difference_gbp
  = max(canonical_order_attributed_receipt_gbp - final_order_value_gbp, 0)

confirmed_customer_credit_gbp
  = net approved and unlocked order-source credit

confirmed_fx_card_difference_gbp
  = net active confirmed order-linked FX/card-difference allocation

remaining_unresolved_gbp
  = gross_positive_difference_gbp
  - confirmed_customer_credit_gbp
  - confirmed_fx_card_difference_gbp
  - other_governed_resolution_gbp
```

Credit and FX are classifications of the difference. They do not add to the receipt and must never be counted twice.

## 5. Canonical receipt attribution

The canonical resolver must calculate receipt attribution from active economic-use records, not from one UI view.

At statement-line level it must:

- include active order-funding reconciliation amounts;
- include active order-linked neutral pending-surplus reservations;
- include active inbound residual amounts already classified as FX/card difference;
- include confirmed final-balance payments;
- retain credit-confirmed pending-surplus rows as receipt attribution evidence;
- exclude credit-ledger rows from receipt totals because they classify surplus rather than create receipt;
- cap attributable use by the immutable physical statement-line amount;
- avoid double counting a legacy row where the full physical receipt was already included in funding;
- respect statement-line reversals and inactive/historical rows.

Applied account credit remains governed by the existing credit-application and reversal controls. It must not create a second new credit merely because the final sale value later falls.

## 6. Independent status dimensions

One field must not combine economic resolution and operational blockers.

The canonical position must expose at least:

```text
resolution_status
operational_blocked_yn
operational_blocker
credit_action_allowed_yn
credit_action_blocker
fx_action_allowed_yn
fx_action_blocker
```

Permitted `resolution_status` values:

```text
no_positive_difference
ready_for_resolution
partially_resolved
fully_resolved
over_resolved_review
```

Rules:

- `ready_for_resolution`: positive difference and nothing classified;
- `partially_resolved`: positive difference, some amount classified, and remaining unresolved is positive;
- `fully_resolved`: remaining unresolved is zero within GBP 0.01 tolerance;
- `over_resolved_review`: classifications exceed the current gross difference by more than GBP 0.01;
- an open dispute or hold may block a new customer-credit action but must not rename the position as financially resolved;
- an incompatible statement-line use may block FX action but must not hide the unresolved amount.

## 7. Incremental supervisor decisions

The supervisor/admin action must support repeated and mixed decisions:

- credit then credit;
- FX then FX;
- credit then FX;
- FX then credit;
- one action split between credit and FX;
- partial action followed by a later action.

Each action may submit:

```text
new_customer_credit_gbp >= 0
new_fx_card_difference_gbp >= 0
```

At least one amount must be greater than zero.

The action total must not exceed the locked current `remaining_unresolved_gbp` by more than GBP 0.01.

After every action:

```text
new remaining unresolved
  = previous remaining unresolved
  - new customer credit
  - new FX/card difference
```

The action must:

- take an order-level transaction/advisory lock;
- re-read the canonical position inside the transaction;
- reject stale or excessive submissions;
- create only the incremental customer-credit amount requested;
- create only the incremental FX/card-difference amount requested;
- preserve the same importer, order and source statement identities;
- require a reason and notes;
- return the new canonical totals;
- be idempotent for the same submitted action identity.

It must never create the full gross difference when part of that difference has already been classified.

## 8. Reversal and later evidence changes

Historical classification rows are immutable.

Corrections use existing surgical reversal paths or additive reversal rows. No confirmed credit or FX record may be silently edited or deleted.

When final sale evidence or active receipt attribution changes:

- if the gross difference increases, the position reopens with the additional unresolved amount;
- if the gross difference decreases but remains above existing classifications, the remaining amount is recalculated;
- if existing classifications exceed the new gross difference, status becomes `over_resolved_review`;
- no further positive classification is allowed while over-resolved;
- a targeted reversal must reduce the excess before normal resolution continues;
- shipment, supplier, Sage and VAT records remain unchanged unless their own governing controls require a separate action.

## 9. Internal funding and surplus-evidence UI

The internal page must show the complete canonical position:

```text
Order-attributed receipt
Final order value
Gross positive difference
Customer credit confirmed
FX/card difference confirmed
Remaining unresolved
Resolution status
Operational blocker, if any
```

Queue separation is mandatory:

- Ready/partially resolved;
- Operationally blocked;
- Fully resolved;
- Over-resolved review.

A row must never be labelled `credit created GBP X` when `GBP X` is actually the gross difference.

For `ORD-1784498556959` before further action, the page must show:

```text
Order-attributed receipt       GBP 900.00
Final order value              GBP 819.97
Gross difference               GBP 80.03
Customer credit confirmed      GBP 15.04
FX/card difference confirmed   GBP 0.00
Remaining unresolved           GBP 64.99
Status                         Partially resolved
Operational blocker            None
```

## 10. Customer-order projection

Customer pages must remain customer-safe.

They may show:

- accepted estimate;
- payment applied to this order;
- final order value;
- credit added to account from this order;
- potential additional account credit pending review;
- overall available account credit.

They must not expose raw treasury classifications or FX accounting detail.

`potential additional account credit pending review` equals the positive unresolved amount that has not yet been classified. It is explicitly potential, not available credit.

After a supervisor action:

- the portion classified as customer credit increases account credit;
- the portion classified as FX does not increase account credit;
- the pending amount reduces by the total newly classified amount;
- shipment and delivery status remain independent.

## 11. Importer dashboard projection

Importer pages must show the order-operational consequence without exposing staff-only controls.

They may show:

- accepted estimate;
- final order value;
- credit already added to account from this order;
- potential additional credit pending supervisor review;
- `No importer action required` where the decision belongs to staff.

They must not present unresolved supervisor classification as an importer evidence issue or importer action.

## 12. Importer reconciliation projection

The reconciliation page must stop reading a legacy surplus status as the sole truth.

It must show an audience-safe projection from the canonical position:

- `Partially accounted for` while unresolved is positive and some amount is classified;
- `Pending supervisor review` when unresolved is positive and nothing is classified;
- `Accounted for` only when unresolved is zero;
- `Review required` when over-resolved.

Invoice-line variance remains visible for audit, but the banner must state separately:

- account credit already confirmed from this order;
- potential additional credit still pending;
- whether no importer action is required.

## 13. Canonical read model and write boundary

Implementation must add one authoritative read model, named:

```text
public.order_settlement_resolution_position_v1
```

or an equivalent short name if an existing deployed object requires compatibility.

All four relevant surfaces must consume this read model directly or through the canonical audience-status wrapper. No page may recompute the position independently.

The incremental staff write boundary must be one short staff-only RPC, named:

```text
public.staff_resolve_order_settlement_v1(...)
```

The RPC must reuse existing funding, credit-ledger, FX-allocation and reversal primitives wherever they already satisfy the locked rules.

## 14. No-impact boundaries

The patch must be additive and must not:

- alter accepted-estimate funding completion;
- alter physical statement amounts or direction;
- rematch supplier payments;
- alter customer sale document totals;
- release shipment or bypass holds;
- change existing customer credit application rules;
- change Sage account mappings or live gates;
- change VAT recognition or return snapshots;
- backfill or rewrite historical credit/FX decisions without explicit migration evidence;
- infer FX merely because a difference exists.

## 15. Required regression scenarios

The implementation is not complete until regression proves at least:

1. no difference;
2. full credit in one action;
3. full FX in one action;
4. credit then credit;
5. FX then FX;
6. credit then FX;
7. FX then credit;
8. split credit and FX in one action;
9. partial action leaves a positive unresolved amount;
10. stale concurrent action is rejected;
11. duplicate/idempotent submission creates no duplicate rows;
12. open dispute blocks credit but leaves amounts visible;
13. active hold blocks credit but leaves amounts visible;
14. incompatible statement-line use blocks FX but leaves amounts visible;
15. later final sale decrease reopens resolution;
16. later final sale increase creates over-resolved review where required;
17. credit reversal recalculates remaining;
18. FX reversal recalculates remaining;
19. customer available credit changes only by confirmed credit;
20. FX never changes customer available credit;
21. internal, customer, importer and reconciliation pages agree with their audience projections;
22. legacy full-funding/automatic-credit rows are not double counted;
23. `ORD-1784498556959` resolves from GBP 15.04 confirmed credit plus GBP 64.99 unresolved without creating duplicate GBP 80.03 credit.

## 16. Build order

Implementation must proceed in this order:

1. canonical read model and diagnostic regression;
2. incremental staff RPC and reversal guards;
3. canonical audience-status projection;
4. internal funding/surplus page;
5. customer order page;
6. importer dashboard;
7. importer reconciliation page;
8. cross-surface regression and live SQL verification.

Backend truth must be deployed before UI wording is treated as complete.
