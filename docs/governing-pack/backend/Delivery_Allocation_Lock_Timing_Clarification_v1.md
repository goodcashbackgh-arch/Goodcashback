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

# Governing amendment v1.2 — narrow atomic bulk ordinary allocation

**Status:** governing correction and replacement for the branch-only v1.1 bulk specification  
**Effective date:** 11 August 2026  
**Implementation rule:** this v1.2 amendment is the sole governing authority for the bulk delivery-allocation patch. It replaces the earlier branch-only v1.1 bulk/rework expansion in full. Sections 1–6 above remain unchanged. Existing working replacement, rework, physical-receipt, shipment, customer-review/release, Sage, VAT and export-evidence behaviour must remain unchanged.

## 7. Purpose

Add one surgical convenience to the existing ordinary delivery-allocation workflow:

```text
choose one existing tracking ref/package
-> select several progressed physical supplier-invoice lines
-> explicitly confirm that the selected items are in that package
-> allocate the full current ordinary remaining quantity of every selected line atomically
```

This is not a redesign of delivery allocation. It is a bulk submit layer over the existing ordinary allocation ledger.

The existing individual line form remains authoritative for partial quantities, unknown contents, evidence, notes, unusual basis and supervisor-estimate cases.

## 8. Absolute non-regression boundary

The patch must not change, replace, broaden or reinterpret:

- same-order free-replacement route creation;
- the replacement tracking handoff UI;
- `operator_allocate_same_order_replacement_tracking_v1`;
- `physical_replacement_same_order_routes`;
- `tracking_allocation_effective_entitlement_v1`;
- physical receipt or receipt correction;
- shipment candidates, package membership or exact line membership;
- customer review, customer hold or customer sales release;
- supplier invoice source facts;
- invoice-adjustment monetary rules or the existing recalculation authority;
- Sage, VAT, COS or export-evidence authorities;
- existing ordinary clear/rework behaviour;
- existing permissions, RLS policies, shared components or unrelated UI routes.

No new package model, allocation ledger, replacement authority, rework authority, control-state read authority, package-freeze rule, shipper workflow, modal or wizard may be introduced by this patch.

The shared `app/_components/FloatingActionBar.tsx` must be reused unchanged.

## 9. Replacement lane boundary

Same-order free replacement is a separate physical retry lane.

The replacement lane already works as:

```text
failed original physical attempt remains raw immutable history
-> approved replacement route carries exact replacement quantity/value
-> importer selects one or more waiting replacement routes in the replacement handoff
-> dedicated replacement RPC assigns successor tracking
-> successor allocation is created on the same original order and supplier-invoice line
-> effective entitlement remains unchanged
```

A replacement successor allocation is therefore a physical retry, not another unit of ordinary commercial allocation capacity.

This bulk patch must not expose replacement routes on the ordinary delivery-allocation bulk selector and must not submit replacement route IDs to the ordinary allocation RPC.

The only replacement awareness required by ordinary delivery allocation is current-position arithmetic and writer serialization:

1. replacement **successor** allocations must not consume ordinary remaining quantity a second time;
2. failed/source allocations remain ordinary historical allocations and continue to count toward ordinary allocated quantity;
3. ordinary allocation and replacement successor allocation must share the existing order advisory-lock family so the two writers cannot race.

Do not delete, reopen, rewrite or reclassify replacement rows to achieve this result.

## 10. Ordinary remaining quantity

For delivery-allocation display and ordinary allocation validation:

```text
effective supplier-line quantity
= COALESCE(qty_confirmed, qty, 0)

ordinary allocated quantity
= SUM(qty_allocated)
  for allocation rows on the supplier line
  excluding rows that are successor_tracking_line_allocation_id
  of a committed same-order replacement route

ordinary remaining quantity
= effective supplier-line quantity - ordinary allocated quantity
```

The exclusion applies only to committed replacement successor rows. Raw allocation history remains visible in the allocation-history table.

Example:

```text
supplier line effective qty = 2
original ordinary allocation = 2
one unit fails
replacement successor allocation = 1

raw physical attempts = 3
ordinary allocated quantity = 2
ordinary remaining quantity = 0
```

If the original ordinary allocation had been only 1 before the retry:

```text
supplier line effective qty = 2
original ordinary allocation = 1
replacement successor allocation = 1

raw physical attempts = 2
ordinary allocated quantity = 1
ordinary remaining quantity = 1
```

The normal delivery-allocation page must still show that genuine ordinary remainder of 1.

## 11. Authoritative ordinary allocation RPC

Create one narrow authenticated database authority:

```text
public.delivery_allocate_tracking_lines_v1
```

Both the existing single-line ordinary allocation action and the new bulk action must use this same authority. This removes the existing application-level read-then-insert race between ordinary writers.

The function supports exactly two request kinds:

```text
single
bulk
```

`single` contract:

- exactly one item;
- `quantity_mode = 'exact'` is mandatory;
- positive explicit quantity is mandatory;
- preserves the existing content-state, basis, evidence and notes semantics;
- tracking may remain nullable only for the existing unknown/needs-evidence states.

`bulk` contract:

- at least one unique item;
- every item must use `quantity_mode = 'remaining'`;
- no browser quantity is accepted as authoritative;
- one non-superseded tracking submission belonging to the order is mandatory;
- `content_state = 'confirmed'`;
- explicit `p_confirm_same_package = true` is mandatory;
- every selected line receives its full current server-derived ordinary remaining quantity.

One invalid selected item aborts the entire transaction with zero new allocation rows.

## 12. Transaction and concurrency contract

The ordinary allocation RPC must execute one transaction with this order:

```text
authenticate actor
-> validate operator/importer access or active supervisor/admin staff
-> lock order
-> acquire pg_advisory_xact_lock(hashtext(order_id::text))
-> validate and lock tracking submission when supplied
-> lock selected supplier-invoice lines in deterministic order
-> lock relevant existing allocation rows in deterministic order
-> derive committed replacement successor identities for the selected lines
-> calculate server-authoritative ordinary remaining quantity
-> validate every selected line and request mode
-> insert every ordinary allocation row
-> call the existing recalculate_invoice_adjustment_consumption_v1 for each affected supplier invoice
-> return result
-> commit
```

The same order advisory lock is already used by `operator_allocate_same_order_replacement_tracking_v1`; this is coordination only. The replacement function itself must remain byte-for-byte unchanged.

Do not add a generic table trigger or constraint based on raw `SUM(qty_allocated) <= supplier line qty`. Raw allocation history may legitimately exceed supplier-line quantity because same-order replacement successors are retained as physical-attempt history.

## 13. Existing monetary behaviour

For ordinary allocation, preserve the existing basis:

```text
effective line value = COALESCE(amount_confirmed, amount_inc_vat_gbp, 0)
base value for the new ordinary allocation
= proportional effective line value for the quantity being allocated
```

Do not create a new monetary algorithm for bulk.

After successful inserts, call the existing `recalculate_invoice_adjustment_consumption_v1` inside the same RPC transaction for every unique affected supplier invoice.

This amendment does not authorise replacement or redesign of that recalculation function. Any separate concern in that downstream authority must be handled independently under its own governing change.

## 14. Loader/read changes

The delivery-allocation loader may be changed only as required to make the existing page agree with the authoritative ordinary allocation RPC.

Required additions:

- load `qty_confirmed` and `amount_confirmed`;
- derive effective line quantity/value from confirmed values when present;
- identify committed same-order replacement successor allocation IDs for the current order;
- expose a narrow boolean such as `counts_toward_ordinary_remaining` on loaded allocation rows.

No new general-purpose control-state RPC is required.

The page must calculate:

- ordinary allocated quantity;
- ordinary remaining quantity;
- bulk selectability;
- individual form `max` and default remaining quantity;

using only allocation rows where `counts_toward_ordinary_remaining = true`.

The raw allocation-history table continues to display every allocation row, including replacement successors.

## 15. Bulk UI contract

Add one small client component on the existing delivery-allocation page.

Required interaction:

```text
Tracking ref / package
[ active tracking dropdown ]

[ Select all available ] [ Clear ]
N of M selected

[checkbox] line A — Remaining X
[checkbox] line B — Remaining Y
```

When one or more lines are selected, reuse `FloatingActionBar` unchanged to show:

- selected item count;
- total currently displayed ordinary remaining units selected;
- selected tracking/package label;
- confirmation checkbox materially equivalent to `I confirm these selected items are in this tracking package.`;
- `Apply tracking ref` submit button.

Changing the tracking selection or selected line set must reset confirmation.

Submit is disabled unless:

- at least one line is selected;
- a tracking ref is selected;
- confirmation is checked.

Bulk has no quantity input. Partial allocation remains on the existing individual form.

`Select all available` selects every progressed physical line whose current ordinary remaining quantity is greater than zero.

## 16. Application wiring

Permitted application changes are limited to:

```text
app/delivery-allocation/actions.ts
app/delivery-allocation/data.ts
app/delivery-allocation/DeliveryAllocationWorkspace.tsx
app/delivery-allocation/DeliveryAllocationBulkControls.tsx
```

The existing `saveDeliveryAllocationAction` becomes a thin wrapper around `delivery_allocate_tracking_lines_v1` with one `exact` item.

Add `saveBulkDeliveryAllocationAction` as a thin wrapper around the same RPC with selected line IDs in `remaining` mode.

The browser must not calculate allocation values and must not loop one write per selected line.

The existing `clearDeliveryAllocationForLineAction` remains on its pre-patch implementation. No clear/rework authority is added by this patch.

Do not convert the whole workspace to a client component.

## 17. Migration contract

Use one additive, later migration. Do not edit any deployed migration.

The migration must:

1. `BEGIN`;
2. use repository-standard finite `lock_timeout` and statement timeout;
3. preflight required tables, columns and `recalculate_invoice_adjustment_consumption_v1`;
4. preflight `physical_replacement_same_order_routes` and its successor allocation column because ordinary remaining depends on that established architecture;
5. install **only** `delivery_allocate_tracking_lines_v1` and its exact grants;
6. not alter `order_tracking_line_allocations`, replacement functions/tables, receipt, shipment, customer, Sage, VAT or export authorities;
7. revoke execution from `PUBLIC` and `anon` and grant authenticated execution consistent with current application use;
8. `NOTIFY pgrst, 'reload schema'`;
9. commit only after postflight confirms the authority exists.

No data repair, cleanup, reclassification or trigger installation is part of this migration.

## 18. Mandatory regression proof

Before merge, prove at least:

### Existing single ordinary allocation
- exact single allocation succeeds;
- partial quantity still succeeds;
- unknown/needs-evidence semantics remain available;
- wrong-order tracking fails;
- non-progressed and active non-physical financial lines fail;
- over-allocation fails;
- a direct `single` RPC call using `quantity_mode = 'remaining'` fails.

### Bulk
- one selected line succeeds;
- several selected lines succeed atomically;
- partially allocated line receives only current ordinary remainder;
- duplicate line IDs fail;
- missing same-package confirmation fails;
- stale browser quantity cannot over-allocate;
- one invalid selected line leaves zero new allocation rows;
- multiple affected invoices are recalculated inside the same transaction;
- recalculation failure rolls back all inserted rows.

### Replacement non-regression
- existing replacement panel and replacement RPC files are unchanged;
- existing same-order replacement regressions still pass;
- replacement successor creation still succeeds;
- no new raw cumulative trigger exists;
- a replacement successor does not consume ordinary remaining a second time;
- raw allocation history still includes the successor row;
- effective-entitlement quantity/value conservation remains unchanged.

### UI
- confirmed quantity/value drives displayed effective quantity/value;
- ordinary remaining excludes replacement successor rows;
- raw history still displays replacement successor rows;
- Select all includes every line with positive ordinary remainder;
- tracking change resets confirmation;
- line-selection change resets confirmation;
- submit requires selection + tracking + confirmation;
- bulk exposes no quantity field;
- existing individual partial form remains available.

### Downstream smoke
- bulk-created ordinary rows appear under the selected tracking submission exactly like individually created ordinary rows;
- existing shipper receipt/shipment readers require no code change;
- no replacement, shipper, customer, Sage, VAT or export file is changed by the patch.

## 19. Locked acceptance examples

### Ordinary bulk

Given:

```text
A effective qty 1, ordinary remaining 1
B effective qty 3, existing ordinary allocation qty 1, ordinary remaining 2
C effective qty 1, ordinary remaining 1
```

Choose `DHL123`, select A/B/C, confirm and submit.

One transaction creates:

```text
A -> DHL123 qty 1
B -> DHL123 qty 2
C -> DHL123 qty 1
```

The existing B allocation remains untouched.

### Replacement separation

Given:

```text
supplier line effective qty = 2
existing original ordinary allocation = 1
same-order replacement successor = 1
```

The ordinary delivery-allocation page must show:

```text
ordinary allocated = 1
ordinary remaining = 1
```

while the raw allocation history may show both physical attempts.

The replacement successor is created and managed only through the existing replacement lane.

## 20. Final governing sentence

```text
This patch does one thing: add atomic bulk submission to the existing ordinary delivery-allocation lane. Single and bulk ordinary writes share one transaction-safe RPC; bulk uses current server-authoritative ordinary remaining quantity; replacement successor rows are excluded only from ordinary-remaining arithmetic and otherwise remain untouched raw history; the existing replacement, rework, shipper, customer, accounting and export workflows are not redesigned or replaced.
```
