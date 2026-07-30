# Partial Physical Receipt Residual Final Balance Addendum v2

## Status

Scope-frozen implementation and release-verification addendum. This v2 supersedes v1 for PR #206 and incorporates the proven release-audit compatibility dependency discovered during verification.

The authorised implementation has been applied to the target database and the dedicated audience, drift-audit and retained 28 July settlement regressions have passed. The PR remains draft pending final branch/release review.

## Defect

The 28 July audience overlay treats an already-received physical receipt residual on an all-or-nothing basis. That can leave a customer-visible final balance overstated when a physical receipt residual only partially covers the remaining canonical shortfall.

The target case is `ORD-1785274708774`:

- final order value: £749.43
- funded/payment-applied total: £701.83
- existing canonical shortfall before receipt-residual overlay: £47.60
- active physical receipt residual still belonging to the order: £38.13
- correct collectible balance: £9.47

The £37.20 account credit already applied to the order is already included in the £701.83 funded total and must not be counted again. FX/card amounts are excluded from customer collectible-balance arithmetic.

## Accounting rule

The pre-overlay canonical balance remains authoritative for established funding, applied-credit, final-sale, credit-note and confirmed final-balance-payment arithmetic.

Only the physical receipt residual still belonging to the order may reduce that balance:

`still_order_applied_residual = max(active_non_reversed_pending_residual - exact_linked_overfunding_credit_created_from_that_residual, 0)`

`collectible_balance = max(existing_pre_overlay_canonical_balance - still_order_applied_residual, 0)`

No FX/card amount or broader attributed-receipt total participates in either formula.

## Controlled cases

### Target order — ORD-1785274708774

Expected result:

`£47.60 - £38.13 = £9.47`

Required protections:

- the existing £37.20 applied account credit is not deducted again;
- the £38.13 physical residual is not treated as FX;
- no automatic customer credit is created from the £38.13;
- no funding or final-sale figure is recomputed in the audience layer.

### Partial residual conversion model — ORD-1784976429191

Known state:

- existing canonical shortfall: £44.00
- active physical receipt residual: £81.20
- exact linked overfunding credit created from that residual: £37.20
- residual still belonging to the original order: £44.00
- expected collectible balance: £0.00

This case exists only to prove that an exact newly-created overfunding credit is carved out once and the remaining physical residual is not double-counted.

## Proven dependency discovered during verification

`public.internal_order_status_drift_audit_v1()` is a release-blocking audit and calls `public.order_audience_status_v1(NULL)`.

Its pre-alignment expected-audience comparison assumed the old canonical balance formula and did not account for the valid physical receipt residual overlay.

This was proven by live DB output for `ORD-1784976429191` before alignment:

- expected canonical balance: £44.00
- canonical status balance: £44.00
- audience balance: £0.00
- audit result: `AUDIENCE_STATUS_DRIFT`

Therefore a corrected audience balance can be valid while the pre-alignment release audit still reports a false drift.

## Implementation boundary

This build may change only the following contracts:

1. `public.order_audience_status_v1(uuid)`
   - replace only the defective 28 July receipt-residual treatment;
   - preserve the same public function name and return signature;
   - continue to call `public.order_audience_status_pre_receipt_residual_overlay_v1(uuid)` as the authoritative predecessor;
   - change only `canonical_balance_due_gbp` and the same customer/importer status/action suppression already owned by the 28 July overlay when the corrected balance reaches zero.

2. `public.internal_order_status_drift_audit_v1()`
   - preserve the same public function name, return signature, `SECURITY DEFINER` and release-blocking purpose;
   - preserve the existing canonical-status drift check against the established canonical formula;
   - change only the expected **audience** balance comparison so a valid receipt-residual overlay is not reported as drift;
   - expected audience balance must be derived from canonical status less only the same still-order-applied physical residual defined above;
   - exact linked overfunding-credit provenance rules must match the audience repair;
   - no FX/card or attributed-receipt amount may enter the audience expectation;
   - enforce the intended execution boundary: `authenticated` retains `EXECUTE`; `anon` has no `EXECUTE` grant.

3. Regression contracts
   - the new 30 July regression may be extended to prove the release-audit alignment;
   - the 28 July regression may be changed only where it explicitly requires the obsolete all-or-nothing implementation;
   - its settlement, funding, credit, final-sale and no-false-final-balance-payment protections must remain intact.

4. This addendum.

No other production function, page, view, table, trigger, RPC or workflow is authorised to change in this build.

## Explicitly untouched

This addendum authorises no change to:

- `order_funding_position_vw` or funding arithmetic;
- `order_funding_events`;
- DVA reconciliation logic;
- DVA statement-line allocation logic;
- final-balance allocator/workbench logic;
- pending-surplus creation or confirmation mechanics;
- importer/customer credit creation or application mechanics;
- FX/card classification;
- supplier invoice or supplier reconciliation logic;
- supplier rejection logic;
- tracking or shipment logic;
- evidence logic;
- Sage/accounting/VAT logic;
- holds/disputes;
- customer page code;
- importer page code;
- internal evidence page code;
- wording, styling or navigation;
- database table data.

## Drift-audit alignment rule

The release audit must continue to answer two separate questions:

1. Is canonical status itself wrong?
2. Is the audience wrapper wrong relative to the valid audience overlay?

Therefore:

`expected_canonical_balance = existing canonical audit formula`

`expected_audience_balance = max(canonical_status_balance - still_order_applied_residual, 0)`

The audit must still emit `CANONICAL_STATUS_BALANCE_DRIFT` when canonical status differs from its existing expected canonical balance.

It must emit audience drift only when the live audience balance differs from `expected_audience_balance`.

It must not redefine canonical settlement arithmetic merely to make the audience layer pass.

## Required regression proof

Before merge, all of the following must be proven:

### Audience repair

- public function name remains `order_audience_status_v1(uuid)`;
- return signature is unchanged;
- direct predecessor remains `order_audience_status_pre_receipt_residual_overlay_v1(uuid)`;
- no write path exists;
- no alternate funding/final-sale recomputation exists;
- no FX/card or attributed-receipt value enters collectible balance;
- no-residual orders pass through unchanged;
- partial residual reduces balance correctly;
- residual greater than balance floors at zero without creating credit;
- partial exact-credit conversion subtracts the linked credit once;
- full exact-credit conversion leaves no residual available against the original order;
- reversed residual is excluded;
- existing applied account credit is not counted twice;
- prior confirmed final-balance payments are not counted twice.

### Release drift audit

- public function name remains `internal_order_status_drift_audit_v1()`;
- return signature, `SECURITY DEFINER` and fixed `search_path` boundary remain unchanged;
- `authenticated` has `EXECUTE` and `anon` does not;
- canonical-status drift formula remains unchanged;
- expected audience balance uses canonical status less only still-order-applied physical residual;
- exact linked credit is deduplicated by credit-ledger identity;
- exact credit provenance matches the established overfunding confirmation route;
- no FX/card or attributed-receipt amount enters the audit expectation;
- no business-data writes exist;
- `ORD-1784976429191` is no longer falsely returned as `AUDIENCE_STATUS_DRIFT` when its audience balance is £0.00 and canonical balance is £44.00;
- after the audience migration, `ORD-1785274708774` is not reported as drift when its audience balance is £9.47 and canonical balance remains £47.60.

### Existing regression compatibility

The 28 July regression must retain its existing proofs for:

- settlement position values;
- £80.03 pre-existing applied credit on the controlled previous order;
- zero false final-balance allocations;
- posted final-sales fingerprint;
- pending-surplus classification.

Only assertions that require the obsolete 28 July implementation may be replaced.

### Wider unchanged gates

Existing unrelated regressions must be run unchanged. A failure in supplier, tracking, evidence, funding, DVA, accounting or other unrelated behaviour is a stop condition, not authority to broaden this PR.

## Deployment order

1. Verify live DB function signatures and dependency chain still match this addendum.
2. Apply the audience repair migration.
3. Apply the drift-audit alignment migration.
4. Run the dedicated audience regression.
5. Run the dedicated drift-audit regression.
6. Run the retained 28 July settlement regression.
7. Run existing wider unchanged regression checks.
8. Verify live target output for `ORD-1785274708774` is £9.47.
9. Verify the release drift audit does not falsely flag either controlled order.
10. Only then consider merge/release.

Any failed step stops the release. No compensating change outside this scope is authorised.

## Current branch caution

Implementation commits were added to the branch before this expanded scope was formally documented. Their presence did not constitute approval; the live migrations and directly corresponding regressions were subsequently reviewed and executed against the target database.

Anything not authorised above remains outside scope and must be removed or separately approved before merge.

## Scope freeze

Any proposed change outside:

- `order_audience_status_v1(uuid)` receipt-residual overlay;
- `internal_order_status_drift_audit_v1()` audience-expectation compatibility only;
- the directly corresponding regression assertions;
- this addendum;

is outside this build and requires a new diagnosis and explicit approval before implementation.