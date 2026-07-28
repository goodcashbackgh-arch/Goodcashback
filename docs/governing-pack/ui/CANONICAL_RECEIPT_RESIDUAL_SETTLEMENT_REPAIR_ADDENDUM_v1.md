# CANONICAL RECEIPT RESIDUAL SETTLEMENT REPAIR ADDENDUM v1

**Status:** LOCKED  
**Target:** Platform-wide behaviour for the proven settlement state represented by `ORD-1784976429191`. No order-specific code.  
**Purpose:** Restore the existing receipt-residual settlement workflow and prevent a false final-balance collection target. No new settlement architecture.

## 1. Proven baseline — must not be reinterpreted

For the controlled order, live DB evidence proves:

- Physical customer receipt: **£886.13**
- Cash applied as order funding: **£804.93**
- Previously available account credit applied to order: **£80.03**
- Accepted estimate fully funded: **£884.96**
- Original receipt residual preserved as `pending_evidence`: **£81.20**
- Final posted customer sale: **£928.96**
- Effective receipt recognised by the pending-aware evidence model: **£966.16**
- Final settlement surplus: **£37.20**
- Correct final customer balance due: **£0.00**

`order_surplus_evidence_position_v3` independently proves:

`£966.16 - £928.96 = £37.20`

The existing `staff_confirm_surplus_from_evidence_min_v1` therefore creates **£37.20**, not £81.20, as customer credit and transitions the original £81.20 pending-surplus row to `credit_confirmed`.

The existing £80.03 applied account credit has already funded this order and **must never be credited again**.

## 2. Proven defect

There are exactly **two affected interfaces**.

### A. Settlement Resolution

The current page reads the canonical settlement position but only exposes the later `staff_resolve_order_settlement_v1` workflow.

That RPC correctly refuses execution while:

`pending_evidence_count > 0`

with:

`classify_original_receipt_residual_first`

However, the page no longer exposes the already-existing action that actually performs that required first classification:

`staff_confirm_surplus_from_evidence_min_v1(uuid,text,text)`

Result: the platform identifies the correct **£37.20** but leaves the supervisor in a dead end.

### B. DVA/card Matching Workbench

The workbench constructs final-balance targets from:

`internal_order_final_sale_settlement_v2`

That older read model sees **£884.96 received against £928.96 final sale** and therefore generates a false:

**Final balance payment — £44.00**

It does not account for the existing £81.20 pending original-receipt residual even though the canonical pending-aware settlement models already prove that receipt covers the £44.

## 3. Required fix — exact scope

### Change 1 — restore the existing receipt-residual action

On the existing Settlement Resolution route only:

When an order has an original pending receipt residual and the **existing** `order_surplus_evidence_position_v3` says that surplus evidence is ready, expose a supervisor action using the existing:

`staff_confirm_surplus_from_evidence_min_v1`

Do **not** reproduce its accounting logic in TypeScript or create a new RPC.

For the proven case, the action must therefore confirm **£37.20 customer credit** and transition the existing £81.20 pending row according to the deployed RPC.

The later incremental resolver remains unchanged and remains available only when its existing eligibility rules allow it.

### Change 2 — remove false final-balance workbench targets

The DVA/card Matching Workbench must not present a final-balance collection target where the canonical pending-aware settlement position proves that already-attributed customer receipt is sufficient to cover the final sale.

For the proven state:

- Final sale: **£928.96**
- Attributed customer receipt: **£966.16**

there must be **no £44 final-balance collection card**.

Do not create a new settlement calculation. Reuse the canonical existing settlement evidence/read state.

## 4. Required platform presentation

### Before supervisor confirms the residual

Settlement Resolution must show an actionable receipt-residual settlement for:

- effective receipt **£966.16**
- final order value **£928.96**
- credit available to confirm **£37.20**

It must no longer leave the supervisor with only an unactionable `classify original receipt residual first` blocker.

DVA/card Matching Workbench must show **no £44 final-balance payment target** for this state.

### After supervisor confirms

The existing database route must produce:

- customer settlement credit: **£37.20**
- original £81.20 pending-surplus row: `credit_confirmed`
- remaining unresolved settlement: **£0.00**
- final customer balance due: **£0.00**
- no DVA final-balance collection target for the order

## 5. Explicitly untouched

This patch must **not** modify:

- the £80.03 previously applied account credit
- order funding totals or funding threshold logic
- physical DVA statement evidence
- DVA reconciliation records
- supplier invoice allocations
- supplier invoices or their amounts/statuses
- customer sales invoices
- posted Sage documents
- Sage posting logic
- VAT treatment or snapshots
- shipment, tracking, holds or disputes
- retailer refund handling
- FX/card classification rules
- credit application rules
- settlement-resolution arithmetic in `order_settlement_resolution_position_v1`
- the accounting logic inside `staff_confirm_surplus_from_evidence_min_v1`
- the accounting logic inside `staff_resolve_order_settlement_v1`
- styling, navigation or unrelated workbench behaviour

No new financial ledger type, new settlement route, new accounting concept or order-specific exception is permitted.

## 6. Regression requirements

Implementation is not complete unless regression proves:

1. A pending £81.20 receipt with final-sale evidence leaving £37.20 surplus exposes the existing confirmation action.
2. Confirmation creates exactly **£37.20**, never £81.20.
3. The pending row transitions correctly to `credit_confirmed`.
4. The same action is idempotent under the existing RPC behaviour.
5. No £44 final-balance workbench target is generated while the pending-aware receipt already covers the final sale.
6. A genuine final-balance shortfall **still produces a final-balance workbench target**.
7. Orders without a pending receipt residual remain unchanged.
8. Existing confirmed final-balance payments remain unchanged.
9. Existing £80.03 applied credit is neither recreated nor reclassified.
10. Protected funding, supplier allocation, customer sales, Sage and VAT fingerprints remain unchanged.

## Locked implementation rule

> **Restore access to the existing pending-surplus confirmation route and make the workbench respect the existing canonical pending-aware settlement position. Nothing else.**

Any implementation requiring broader accounting, funding, customer-page, Sage, supplier, shipment or ledger changes is **outside this addendum and must stop for review before proceeding**.
