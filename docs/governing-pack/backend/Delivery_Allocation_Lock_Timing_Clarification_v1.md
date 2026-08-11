# Delivery Allocation Lock Timing Clarification v1

**Project:** Multi Tenant Platform Build  
**Status:** Governing backend/control clarification  
**Applies to:** `Delivery_Allocation_Export_Evidence_and_Adjustment_Apportionment_Addendum_v1.md`

---

## 1. Purpose

This clarification locks the agreed timing rule for item-to-tracking/package allocation edits.

The goal is to keep shipper operations moving without treating shipper package-level actions as proof of item contents.

---

## 2. Correct rule

Shipper package-level events do **not** lock item-to-tracking allocation.

The following do not, by themselves, lock item allocation:

1. Shipper confirms package receipt.
2. Shipper selects package/tracking ref into a shipment batch.
3. Shipper submits shipment quote.
4. Shipper submits shipment invoice.
5. Shipper enters booking reference.

Reason:

```text
Shipper confirms package movement and package/shipment truth.
Operator/supervisor confirms item-content truth.
```

A shipper may receive or ship tracking ref DHL1234 before the operator has completed allocation of the exact invoice lines inside that package.

That is acceptable, provided downstream sales invoice, Sage readiness, COS/export evidence and final closure do not rely on unresolved item allocation.

---

## 3. Hard lock points

Item-to-tracking allocation becomes hard-locked only when it has been used by downstream financial/export controls, including:

1. Customer/sales invoice release using those allocation values.
2. Draft COS/export evidence pack generation.
3. Sage payload queue or Sage posting.
4. Final export evidence clearance.
5. Explicit export/accounting allocation lock flag.

After hard lock, changes must use controlled reversal, amendment, supplementary invoice, credit note, or supervisor/admin correction route.

Do not silently edit historical allocation truth after hard lock.

---

## 4. UI rule

Fully allocated does not mean locked.

Correct UI behaviour:

```text
Fully allocated + no downstream lock
= complete but still editable/reworkable.

Fully allocated + downstream lock
= no direct edit; correction/amendment route required.
```

Operator/supervisor may clear and rework unlocked allocation rows even when a line is fully allocated.

The page should explain that shipper receipt, package selection, quote, and shipment invoice do not lock item allocation.

---

## 5. Downstream readiness rule

Before sales invoice release, draft COS/export pack generation, Sage queue/posting, or final export clearance, allocation readiness must verify:

```text
sum(qty_allocated for each progressed supplier invoice line)
=
original progressed line quantity
```

unless a supervisor/admin has accepted a controlled uncertainty/estimate route.

---

## 6. Final locked sentence

```text
Shipper actions move package/shipment truth forward, but they do not lock item-content allocation. Item allocation remains editable until it is consumed by sales invoice release, draft COS/export evidence generation, Sage queue/posting, final export evidence clearance, or an explicit export/accounting lock.
```

---

# Governing amendment v1.1 — atomic bulk allocation and exact-provenance rework

**Status:** additive governing amendment to this clarification  
**Effective date:** 11 August 2026  
**Implementation rule:** this section is the governing authority for the bulk delivery-allocation patch. Where this v1.1 section is more specific than sections 2–6 above, this v1.1 section controls. Existing working allocation, replacement, physical-receipt, shipment, customer-sales, Sage, VAT and export-evidence behaviour remains unchanged unless this section explicitly says otherwise.

## 7. Purpose and non-regression boundary

This amendment adds a surgical operator/supervisor convenience flow:

```text
choose one tracking ref/package
-> select several progressed physical supplier-invoice lines
-> explicitly confirm the selected items belong to that package
-> allocate the full current remaining quantity of every selected line atomically
```

The patch must reuse the existing `order_tracking_line_allocations` model. It must not create a second allocation ledger, package model, tracking model, shipper allocation workflow, modal/wizard workflow, or replacement-allocation authority.

The following are protected and must not be redesigned or weakened:

- original supplier-invoice lines;
- partial-quantity allocation through the existing individual line form;
- existing allocation value/apportionment rules;
- same-order free-replacement routing and successor allocation;
- exact shipper physical-receipt workflow;
- exact shipment-batch membership workflow;
- customer review/release, Sage, VAT and export-evidence authorities;
- role boundaries: operator/supervisor owns item-to-tracking truth; shipper owns physical receipt/package-to-shipment truth.

No existing table, column, trigger, constraint, working function, permission, UI label or downstream route may be changed merely to implement bulk selection unless this amendment explicitly requires that change.

## 8. Precise lock and provenance rule

The earlier package-level rule remains valid only for package-level events that do not durably consume one exact `order_tracking_line_allocations.id`.

Correct precedence is:

```text
package/header event without exact allocation provenance
!= exact allocation hard lock

immutable downstream row that references order_tracking_line_allocations.id
= that exact allocation identity is no longer eligible for ordinary delete/reassignment
```

Therefore a legacy/header-level shipper receipt, package status, quote, booking reference or other package-level fact does not by itself make every allocation row immutable.

However, ordinary clear/rework must not delete or reassign an exact allocation row once durable downstream provenance references that allocation identity, including as applicable:

1. finalised v2 shipper receipt line disposition;
2. exact shipment-batch line membership;
3. customer-sales release membership;
4. durable customer-review membership that preserves exact allocation provenance;
5. physical-remedy or same-order replacement source/successor provenance;
6. explicit `locked_for_export_pack_at` or `allocation_status = 'locked_for_export_pack'`;
7. another current `ON DELETE RESTRICT` downstream provenance control whose purpose is to preserve exact allocation history.

Do not delete downstream history merely to make allocation deletion succeed.

A supplier-invoice line may contain both immutable existing allocation rows and genuine unallocated quantity. Immutable allocation rows must remain untouched while genuinely unallocated quantity remains eligible for a new ordinary allocation when all other controls permit it.

## 9. Bulk UX contract

The delivery-allocation page must preserve the existing individual forms and running-ledger presentation. Add only a thin bulk-selection layer over progressed physical lines.

Required interaction:

```text
Tracking ref / package
[ existing active tracking ref dropdown ]

[ Select all available ]  [ Clear ]
N of M selected

[checkbox] progressed line A — remaining quantity
[checkbox] progressed line B — remaining quantity
...
```

When at least one eligible line is selected, reuse the existing `FloatingActionBar` pattern. The bar must show:

- selected line count;
- total currently displayed remaining units selected;
- selected tracking/package label;
- explicit confirmation checkbox with wording materially equivalent to: `I confirm these selected items are in this tracking package.`;
- one submit action materially equivalent to `Apply tracking ref`.

Changing the selected tracking ref or changing the selected line set must clear the confirmation checkbox. Submit must be disabled unless at least one line is selected, a tracking ref is selected and the explicit confirmation is checked.

`Select all available` means every progressed physical line with current remaining quantity greater than zero. It may include a partially allocated line with a genuine unallocated remainder. It must not include complete lines or non-physical/non-progressed lines.

Bulk allocation always means the full **current server-authoritative remaining quantity** for each selected line. Bulk must not expose quantity inputs. Partial quantity remains exclusively on the existing individual line allocation path.

## 10. Authoritative write boundary

Create one narrow authenticated database authority, named:

```text
public.delivery_allocate_tracking_lines_v1
```

Both the existing single-line allocation action and the new bulk action must use this same database authority. The application must not retain a competing direct-insert write path for ordinary delivery allocation.

The authority may use a JSON payload so one transaction can support either:

```text
single: one line + explicit exact quantity
bulk: several lines + server-derived full remaining quantity
```

The exact function signature may be chosen to fit current repository conventions, but must include enough information to distinguish actor mode, request kind, order, tracking submission, selected lines, exact-vs-remaining quantity mode, current content/allocation metadata used by the existing single form, and the explicit bulk same-package confirmation.

Bulk requires:

- non-empty unique selected line IDs;
- one non-superseded tracking submission belonging to the same order;
- same-package confirmation = true;
- every selected row using server-derived remaining quantity;
- ordinary confirmed package-content allocation semantics.

One invalid selected row must abort the entire transaction with zero new allocation rows.

## 11. Concurrency and transaction rule

The new ordinary allocation authority must use the same order-level serialization family already used by the same-order free-replacement allocation authority so the two allocation writers cannot race each other.

Required sequence, in one PostgreSQL transaction:

```text
authenticate actor
-> validate actor/order tenancy or staff role
-> lock order
-> acquire pg_advisory_xact_lock(hashtext(order_id::text))
-> validate/lock tracking submission when required
-> lock selected supplier-invoice lines in deterministic order
-> lock relevant existing allocation rows in deterministic order
-> derive current remaining quantities under lock
-> validate every selected line
-> build every allocation row
-> insert all allocation rows
-> recalculate affected invoice-adjustment consumption using existing authority
-> return
-> commit
```

The browser must never be authoritative for remaining quantity. If the page was stale, the database recomputes current remaining quantity under the transaction lock.

No generic table-wide trigger enforcing raw `SUM(qty_allocated) <= supplier line qty` may be added. Same-order free-replacement successor allocations intentionally retain separate raw provenance and must continue to rely on the existing effective-entitlement controls.

## 12. Exact package mutation gate

Ordinary package-content allocation must not silently mutate a package after an exact downstream snapshot has captured the package allocation set.

For ordinary allocation to a tracking submission, block new allocation rows when the tracking package has already been consumed by either:

1. a finalised receipt-model-v2 exact physical receipt for that tracking submission; or
2. exact shipment-batch line membership for that tracking submission.

Legacy/header-level package receipt alone must not be treated as this exact mutation gate unless it has exact allocation provenance.

This gate is package-set integrity. It is separate from line-level reworkability and does not change the controlled exact receipt-correction or shipment-correction authorities.

## 13. Effective quantity/value rule

The read UI and authoritative write path must use the same effective supplier-line basis:

```text
effective quantity = COALESCE(qty_confirmed, qty, 0)
effective line value = COALESCE(amount_confirmed, amount_inc_vat_gbp, 0)
```

The delivery-allocation loader must therefore include confirmed quantity/value fields needed to calculate displayed original, allocated and remaining positions consistently with the database write authority.

For ordinary allocation, preserve the existing value rule and existing adjustment-recalculation authority. Do not create a new monetary apportionment algorithm for bulk.

## 14. Rework authority

Create one narrow authenticated ordinary-rework authority, named:

```text
public.delivery_clear_tracking_allocations_v1
```

The existing `clearDeliveryAllocationForLineAction` must call this authority rather than directly deleting rows.

The clear authority must use the same actor validation and order advisory transaction lock as ordinary allocation. It must delete only allocation rows that are currently eligible for ordinary clear and must leave immutable sibling allocation rows on the same supplier line untouched.

A row is not eligible for ordinary clear when exact/durable downstream provenance blocks deletion as described in section 8. The function must not delete or alter downstream provenance to manufacture eligibility.

After deleting eligible rows, the same transaction must invoke the existing invoice-adjustment recalculation for every affected supplier invoice. Recalculation failure must roll back the deletion.

If no editable allocation rows remain, return a controlled error suitable for user display rather than a raw foreign-key error.

## 15. Control-state read

Add one narrow role-scoped read authority, named:

```text
public.delivery_allocation_control_state_v1
```

It must expose only operational facts required by the delivery-allocation page, including:

- whether a tracking package currently accepts ordinary new allocations under the exact-package mutation gate;
- whether an existing allocation row is eligible for ordinary simple clear;
- a stable blocker code suitable for UI explanation.

It must authenticate the current operator/order tenancy or active supervisor/admin staff and must not broaden shipper or cross-tenant access.

Blocked tracking packages should remain visible in the tracking selector but disabled with an operational explanation rather than silently disappearing.

## 16. Application wiring

Required application changes are limited to the existing delivery-allocation surface:

```text
app/delivery-allocation/actions.ts
app/delivery-allocation/data.ts
app/delivery-allocation/DeliveryAllocationWorkspace.tsx
app/delivery-allocation/DeliveryAllocationBulkControls.tsx   -- new, small client component
```

Reuse the existing shared `app/_components/FloatingActionBar.tsx` unchanged.

The existing `saveDeliveryAllocationAction` remains as the form-facing server action but becomes a thin wrapper around `delivery_allocate_tracking_lines_v1` using one exact-quantity item payload.

Add `saveBulkDeliveryAllocationAction` as a thin wrapper around the same RPC using unique selected line IDs and `remaining` quantity mode. It must not calculate values or remaining quantities in TypeScript and must not loop one database write per line.

The existing clear action becomes a thin wrapper around `delivery_clear_tracking_allocations_v1`.

Do not convert the whole workspace into a client component. The new client component owns only temporary selection, selected count/unit summary, tracking choice interaction required for the bulk bar, confirmation state, Select All and Clear.

## 17. UI allocation/rework state refinement

Do not equate `one existing allocation row is immutable` with `the entire supplier line has no allocatable remainder`.

The UI must distinguish conceptually:

```text
canAllocateRemaining
hasReworkableAllocations
hasImmutableAllocations
```

A partially allocated line may therefore keep an immutable existing allocation and still permit allocation of a genuine remaining quantity.

The old broad sentence that package receipt/selection never locks contents must be rendered more precisely on the delivery-allocation page. User-facing wording should state materially:

```text
Editable allocations can be cleared and redone until the exact allocation has been captured by immutable receipt, shipment, customer-release or export/accounting history.
```

Blocked ordinary clear should state materially:

```text
This allocation has downstream history and cannot be cleared here. Use the controlled correction route.
```

## 18. Database migration contract

Implementation must be additive. Do not edit deployed migrations.

Create one later migration that:

1. starts with `BEGIN`;
2. sets finite `lock_timeout` and the repository-standard statement timeout;
3. preflights required tables/functions/columns and aborts on missing prerequisites;
4. installs only the three narrow authorities in sections 10, 14 and 15 plus their exact grants;
5. revokes `PUBLIC`/`anon` execution and grants only the roles consistent with current authenticated application use;
6. does not replace same-order replacement, physical receipt, shipment, customer-sales, Sage, VAT or export-evidence authorities;
7. issues `NOTIFY pgrst, 'reload schema'`;
8. commits only after postflight checks succeed.

No destructive data repair is part of this migration.

## 19. Mandatory regression proof

The implementation is incomplete unless tests prove at least:

### Existing single path
- existing exact single allocation still succeeds;
- partial quantity remains supported;
- existing unknown/needs-evidence semantics remain supported;
- wrong-order tracking and ordinary over-allocation fail closed.

### Bulk
- one and several selected lines succeed;
- partially allocated line receives only current remaining quantity;
- duplicate line IDs fail;
- missing confirmation fails;
- one invalid selected row causes zero writes;
- stale browser remainder cannot cause an over-allocation;
- affected invoice-adjustment recalculation succeeds inside the same transaction;
- recalculation failure causes complete rollback.

### Exact package mutation
- package with no exact snapshot accepts allocation;
- legacy/header package activity alone does not incorrectly block;
- finalised v2 exact receipt blocks ordinary new contents;
- exact shipment membership blocks ordinary new contents.

### Rework
- editable allocation clears;
- exact-receipt/shipment/customer-release/remedy/replacement-linked allocation is not silently deleted;
- line containing immutable and editable allocations clears only editable rows;
- recalculation is atomic with clear.

### Replacement non-regression
- existing same-order free-replacement regressions pass unchanged;
- successor allocation still succeeds;
- no new raw cumulative trigger blocks it;
- effective quantity/value conservation remains authoritative.

### Shipper/downstream non-regression
- bulk-created rows appear under the existing tracking package;
- existing exact shipper receipt sees every positive allocation for that package;
- exact receipt balancing remains unchanged;
- no new supplier/customer/VAT/Sage values are exposed to shipper.

### UI
- tracking/selection changes reset confirmation;
- submit requires selection + tracking + confirmation;
- bulk has no quantity inputs;
- partial quantity remains on the existing individual form;
- blocked tracking package is visible but disabled/explained;
- success navigation clears temporary client selection state.

## 20. Locked acceptance example

Given:

```text
A qty 1, remaining 1
B qty 3, existing allocation qty 1, remaining 2
C qty 1, remaining 1
```

The operator selects tracking package `DHL123`, selects A/B/C, explicitly confirms they are in that package and submits bulk allocation.

One atomic transaction must create:

```text
A -> DHL123 qty 1
B -> DHL123 qty 2
C -> DHL123 qty 1
```

The pre-existing B allocation remains untouched.

The existing shipper exact-receipt route must subsequently see A qty 1, B qty 2 and C qty 1 under DHL123 without any shipper workflow rewrite.

If any validation, insert or invoice-adjustment recalculation fails, none of the three new allocation rows may remain committed.

## 21. Final governing sentence

```text
Bulk delivery allocation is only a safe convenience over the existing allocation ledger: choose one package, select progressed physical lines, explicitly confirm they belong together, and atomically allocate each line's current server-authoritative remaining quantity through the same database authority used by the existing single-line path. Preserve partial allocation, replacement effective-entitlement semantics, exact downstream provenance, shipper workflow and every unrelated working control unchanged.
```
