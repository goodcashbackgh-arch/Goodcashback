# Importer Reconciliation Signed Baseline Projection Addendum v1

## Objective

Correct the false **original order baseline exceeded** block when a valid physical supplier-invoice line is accompanied by signed non-physical financial rows such as a retailer discount and delivery charge.

The patch must make the importer reconciliation page and its server-side progression pre-check use the same order-wide accounted position.

This is an application-layer reconciliation-guard correction only. It must not create a new reconciliation workflow, change the order baseline, change database progression rules, or alter downstream accounting/Sage behaviour.

---

## Frozen source baseline

This addendum is written against the current `main` source inspected before implementation:

```text
app/importer/reconciliation/[order_id]/actions.ts
blob sha: 02413cad364e13aaeda814dfc14011ca4cadca8d

app/importer/reconciliation/[order_id]/page.tsx
blob sha: f65fa26cd4775415b6b45dd4ec1a248ea63ac63a
```

Before implementation, fetch these two files again.

If either blob SHA has changed, stop and review the intervening diff before writing code. Do not apply a patch blindly to a moved baseline.

Draft PR #177 is evidence only. It must not be cherry-picked or treated as the implementation baseline because it contains a much wider signed-OCR programme.

---

## Proven current route

### Page/read path

The importer reconciliation page:

```text
app/importer/reconciliation/[order_id]/page.tsx
```

already:

- loads all active supplier invoices for the order;
- excludes `rejected_resubmit_required`, `duplicate_blocked`, and `superseded` invoices;
- loads all supplier invoice lines for those active invoices;
- reads active line resolutions;
- reads open dispute lines;
- treats progressed physical lines and open dispute lines as accounted quantity;
- treats progressed physical lines, open dispute lines, and resolved non-physical rows as accounted value;
- normalises resolved financial signs through `financial_type`:
  - `discount` => negative;
  - `delivery` / `fee` => positive;
  - `zero_value_delivery` => zero;
- excludes obvious non-physical rows from physical line selection.

The current page defect is that its physical selection capacity only uses **already-accounted** financial rows. It does not give provisional value effect to a still-unresolved delivery/discount row on the same invoice even when that row is already proved by the invoice's declared adjustment facts.

### Server/write path

The progression actions are:

```text
markSupplierInvoiceLineProgressedAction
bulkMarkSupplierInvoiceLinesProgressedAction
```

Both call:

```text
enforceProgressionWithinBaseline(...)
```

before invoking the existing database write RPCs:

```text
operator_mark_supplier_invoice_line_progressed
operator_bulk_mark_supplier_invoice_lines_progressed
```

The database RPCs remain the progression write authority and must not be replaced.

The current `enforceProgressionWithinBaseline(...)` defect is narrower but more serious: it rebuilds current order value from progressed physical `Y` lines only. It omits already-Parked financial resolutions and open exception value from the amount projection.

---

## Proven defect on the controlled order

Controlled order:

```text
ORD-1785274708774
```

Declared baseline:

```text
quantity: 4
value:    £701.83
```

Already progressed physical goods:

```text
£179.99
£69.99
£219.99
--------
£469.97
```

Already-Parked financial rows:

```text
discount   -£15.00
delivery   +£11.42
------------------
net         -£3.58
```

Therefore the existing accounted position before the final invoice is:

```text
quantity: 3
value:    £466.39
```

Final invoice:

```text
physical goods            +£249.99
promotion discount         -£22.50
express delivery            +£7.95
----------------------------------
invoice contribution       +£235.44
```

Correct projected order result:

```text
£466.39
+ £249.99
- £22.50
+ £7.95
---------
£701.83
```

and:

```text
3 + 1 = 4 units
```

The current server guard instead sees the physical goods without the complete signed financial position and falsely blocks the order as over baseline.

---

## Required calculation contract

There must be one economic rule, implemented consistently in the page read model and server pre-write guard.

### A. Already-accounted quantity

Count quantity only where a line is:

- already progressed physical; or
- linked to an open exception/dispute under the existing reconciliation model.

Active non-physical financial resolutions contribute **zero physical quantity**.

### B. Already-accounted value

Count value where a line is:

- already progressed physical;
- linked to an open exception/dispute; or
- covered by an active `non_physical_financial` resolution.

For active `non_physical_financial` resolutions, signed value must be derived from the existing `financial_type`:

```text
discount              => -abs(source amount)
delivery              => +abs(source amount)
fee                   => +abs(source amount)
zero_value_delivery   => 0
rounding / other      => preserve source signed amount
```

Do not treat an arbitrary active resolution type as non-physical financial value.

### C. Selected physical proposal

For selected, not-yet-accounted physical lines, use the existing progression value fallback:

```text
qty_confirmed ?? qty
amount_confirmed ?? amount_inc_vat_gbp
```

This fallback is frozen and must not be replaced with raw values only.

### D. Provisional unresolved same-invoice financial offset

A still-unresolved row may affect the physical capacity calculation only when all of the following are true:

1. the row belongs to the same supplier invoice as the selected physical line;
2. it is not already progressed, disputed, or resolved;
3. it is source-positive and recognised as delivery, or source-negative and recognised as discount;
4. recognition uses the existing page vocabulary only:

```text
delivery|shipping|postage|freight|carriage
discount|promotion|promotional|promo|voucher|coupon|saving|savings
```

5. the aggregate extracted delivery or discount for that invoice agrees with the existing declared `order_value_adjustments` fact for that same invoice within the existing £0.01 tolerance;
6. rejected adjustment facts are excluded;
7. null approval status must not be accidentally excluded.

No OCR description alone may create extra capacity.

### E. Projected baseline check

The authoritative server pre-check becomes:

```text
projected_qty
  = already_accounted_qty
  + selected_unaccounted_physical_qty

projected_value
  = already_accounted_value
  + selected_unaccounted_physical_value
  + proved_unresolved_same_invoice_financial_offset
```

Then preserve the existing limits:

```text
projected_qty <= total_qty_declared

projected_value <= order_total_gbp_declared + £0.01
```

The original order baseline is not changed or expanded.

---

## Sequence independence requirement

The result must be identical whether the operator:

### Sequence 1 — goods first

Progresses the physical line while its proved delivery/discount rows are still unresolved.

or:

### Sequence 2 — Park first

Parks the delivery/discount rows first and then progresses the physical line.

An already-accounted financial row must never also be included in the provisional unresolved offset.

For the controlled order both sequences must resolve to:

```text
quantity: 4
value:    £701.83
```

---

## Required production changes

Production code may change only:

```text
app/importer/reconciliation/[order_id]/actions.ts
app/importer/reconciliation/[order_id]/page.tsx
```

A regression file may be added under:

```text
docs/testing/
```

This addendum may be added under:

```text
docs/governing-pack/ui/
```

No other production file is in scope.

If implementation appears to require a third production file, stop. Do not expand scope without a new evidence review and an amended addendum.

---

## `actions.ts` permitted changes

Inside `enforceProgressionWithinBaseline(...)` only, the patch may:

- extend the existing line read with the line's `supplier_invoice_id` and `description`;
- read active `non_physical_financial` resolutions for live lines, including `financial_type`;
- read open dispute membership needed to preserve existing exception accounting;
- read existing `order_value_adjustments` for the represented live supplier invoices;
- calculate already-accounted quantity/value under this addendum;
- calculate the proved unresolved same-invoice delivery/discount offset;
- block attempted physical progression of a row already proved to be financial, enforcing the page's existing non-physical selection rule;
- replace only the incomplete projected quantity/value arithmetic with the contract above.

The existing single and bulk progression action functions and RPC names must remain unchanged.

Do not alter manual add/edit guards as part of this patch.

---

## `page.tsx` permitted changes

The page may:

- add the existing invoice adjustment facts to its read set;
- derive proved same-invoice unresolved delivery/discount rows using the exact contract above;
- adjust only the physical remaining-value capacity so a legitimate physical line is selectable when its proved signed invoice adjustments make it fit;
- continue excluding financial rows from physical selection;
- preserve the existing accounted quantity/value display semantics.

No layout, labels, styling, button names, navigation, selection-control design, exception UI, or Park workflow may be changed.

---

## Mandatory fail-closed behaviour

The patch must not manufacture baseline capacity from:

- a description match without matching declared invoice adjustment evidence;
- an adjustment from another supplier invoice;
- a rejected adjustment;
- an already-accounted financial row;
- an arbitrary active resolution type;
- a discount stored with the wrong commercial sign unless its `financial_type` proves it is a discount;
- a delivery row stored with the wrong commercial sign unless its `financial_type` proves it is delivery;
- an exception line being double-counted as selected physical;
- retired/rejected/superseded invoice evidence.

The server action remains authoritative. If the new server reads needed for the guard fail, progression must fail closed rather than silently assume zero accounted value.

---

## Explicitly untouched

This patch must not alter:

- `orders.total_qty_declared`;
- `orders.order_total_gbp_declared`;
- order funding or DVA reconciliation;
- supplier invoice OCR save/materialisation;
- supplier invoice line source values;
- `operator_mark_supplier_invoice_line_progressed`;
- `operator_bulk_mark_supplier_invoice_lines_progressed`;
- `staff_progress_supplier_invoice_lines`;
- non-physical Park RPCs;
- `supplier_invoice_line_resolutions` schema or write behaviour;
- `order_value_adjustments` schema or write behaviour;
- dispute creation, rescission, refund, replacement or exception semantics;
- manual supplier-line add/edit/delete rules;
- supplier invoice approval/current-state logic;
- supplier accounting coding;
- VAT calculations;
- supplier AP;
- customer sales release;
- Sage payloads, snapshots or posting;
- funding, banking or treasury;
- tracking;
- shipment allocation or receipt;
- export evidence or POD;
- customer review/hold logic;
- platform order status;
- permissions or roles;
- UI wording, styling or navigation.

No database migration is permitted for this defect.

---

## Regression requirements

A post-change regression must inspect the **actual patched production source**, not merely test a standalone arithmetic imitation.

It must prove at minimum:

1. the single progression RPC name is unchanged;
2. the bulk progression RPC name is unchanged;
3. no `staff_progress_supplier_invoice_lines` route is introduced;
4. the original order baseline fields remain authoritative;
5. the £0.01 tolerance is unchanged;
6. only active `non_physical_financial` resolutions contribute resolved financial value;
7. resolved discounts are negative;
8. resolved delivery/fees are positive;
9. resolved financial rows do not add physical quantity;
10. already-accounted financial rows are not included again in the provisional offset;
11. unresolved offset is restricted to the same supplier invoice;
12. delivery/discount offset requires aggregate agreement with declared invoice adjustments within £0.01;
13. the existing confirmed-value fallback remains intact;
14. the controlled £701.83 / quantity-4 case passes;
15. the controlled case also passes when current financial rows are Parked first;
16. the same physical line without proved unresolved adjustments remains blocked;
17. a genuine value excess above the existing £0.01 tolerance remains blocked;
18. a genuine quantity excess remains blocked;
19. no controlled-order UUID, order reference or invoice reference is hard-coded in production code;
20. only the two frozen production files changed.

---

## Build and validation procedure

Implementation must follow this order:

1. Re-fetch the two frozen `main` source files.
2. Confirm the blob SHAs or review any intervening changes.
3. Copy the exact current files into a clean working branch.
4. Modify the complete source files — do not hand-author a patch file.
5. Generate the diff from Git after the complete files are changed.
6. Run `git diff --check`.
7. Run the source regression against the actual changed files.
8. Run the repository TypeScript/build checks available in the environment.
9. Review the final Git diff against this addendum.
10. Stop if any production file outside the two-file scope changed.
11. Only then create/open the PR.
12. Do not merge until the controlled UI case has been smoke-tested.

---

## Acceptance criteria

The patch is acceptable only if all of the following are true:

- the £249.99 physical line on the controlled final invoice can progress when the complete signed order position is exactly £701.83;
- the order quantity becomes exactly 4, not more;
- previously Parked -£15.00 / +£11.42 rows are counted exactly once;
- current -£22.50 / +£7.95 rows are counted exactly once whether Parked before or after physical progression;
- unmatched or unproved adjustments create no capacity;
- real over-baseline goods remain blocked;
- physical/non-physical selection behaviour remains unchanged;
- existing progression RPCs remain unchanged;
- no database object is changed;
- no downstream accounting, Sage, shipment, funding or status behaviour is modified.

---

## Scope-change stop rule

Any proposed change outside the exact contract above is **not part of this fix**.

If evidence shows another defect while implementing this addendum:

```text
STOP
record the separate defect
do not fix it in this patch
```

A separate defect requires a separate addendum or explicit amendment before implementation.
