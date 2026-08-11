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

# Governing amendment v1.3 — bulk assignment wrapper only

**Status:** governing correction and replacement for all earlier branch-only bulk specifications  
**Effective date:** 11 August 2026  
**Implementation rule:** sections 1–6 above remain unchanged. This v1.3 amendment is the sole authority for the delivery-allocation bulk-assignment patch. It replaces the branch-only v1.1 and v1.2 bulk specifications in full.

## 7. Purpose

Add one convenience to the existing delivery-allocation page:

```text
select one existing tracking ref/package
-> tick several lines that the existing individual assignment UI already allows to be assigned
-> confirm that those selected items are in that package
-> assign the existing displayed remaining quantity for all selected lines in one atomic submit
```

This is a wrapper over the existing delivery-allocation lane. It is not a new allocation lane and must not reinterpret the lane.

## 8. Frozen existing behaviour

The patch must not change the existing meaning, visibility, calculation or lifecycle of:

- which supplier-invoice lines appear on the delivery-allocation page;
- progressed-line eligibility;
- non-physical-line handling;
- original quantity, allocated quantity or remaining quantity presentation;
- confirmed/raw supplier-line quantity or value handling already used by the page and single action;
- downstream-lock behaviour;
- clear/unassign/rework behaviour;
- individual partial allocation;
- unknown-content, evidence, notes, basis or supervisor-estimate flows;
- replacement routing, replacement tracking handoff or replacement successor allocation;
- physical receipt or receipt correction;
- shipment or package membership;
- customer review/release;
- invoice-adjustment monetary rules;
- Sage, VAT, COS or export-evidence authorities;
- RLS, grants or unrelated shared components.

No existing page/read authority may be broadened or corrected as part of this feature.

If a pre-existing concern is discovered while implementing bulk assignment, record it separately. Do not fold the correction into this patch.

## 9. Bulk eligibility

Bulk eligibility must be derived from the exact same server-rendered state that already controls the existing individual assignment form.

On the current page that means a bulk checkbox may be rendered only where the existing individual assignment form is rendered:

```text
!complete && !hasDownstreamLock
```

The patch must not add a new eligibility query, a new non-physical filter, a new downstream-lock rule, a replacement-aware eligibility rule or any other second eligibility model.

`Select all available` means all currently rendered/enabled bulk checkboxes. Nothing else.

## 10. Existing single path is byte-for-byte frozen

The existing `saveDeliveryAllocationAction` remains on its pre-patch implementation.

The existing `clearDeliveryAllocationForLineAction` remains on its pre-patch implementation.

The existing helpers used by those actions remain unchanged except for purely unavoidable import placement if required by the new bulk action.

The existing `app/delivery-allocation/data.ts` remains byte-for-byte unchanged.

The bulk patch must not route the existing single action through a new RPC and must not change the single action's current validation, quantity/value calculation, insert payload, ledger refresh or redirect behaviour.

## 11. Bulk-only UI

Add one small client component, `DeliveryAllocationBulkControls.tsx`, and make only the minimum workspace edits required to attach it.

Required interaction:

```text
Tracking ref / package
[ active tracking dropdown ]

[ Select all available ] [ Clear ]
N selected

[checkbox] existing assignable line A
[checkbox] existing assignable line B
```

When at least one line is selected, reuse the existing `FloatingActionBar` unchanged to show:

- selected item count;
- total of the currently displayed remaining quantities for those selected lines, for operator information only;
- selected tracking/package label;
- confirmation checkbox materially equivalent to `I confirm these selected items are in this tracking package.`;
- `Apply tracking ref` submit button.

Changing tracking selection or line selection resets confirmation.

Bulk has no quantity input. Partial quantity remains exclusively in the existing individual form.

The browser's displayed remaining quantity is not authoritative for the database write.

## 12. Bulk-only server action

Add `saveBulkDeliveryAllocationAction` to the existing actions file without rewriting the existing functions.

It must:

- read `mode`, `order_id`, `tracking_submission_id`, selected `line_ids` and the confirmation checkbox;
- require at least one selected line;
- require one tracking ref/package;
- require explicit same-package confirmation;
- call one bulk-only RPC once;
- not loop one existing single action per line;
- revalidate the same delivery-allocation/reconciliation paths after success;
- redirect back with a concise success/error message.

## 13. Bulk-only atomic database authority

Create one additive function:

```text
public.delivery_allocate_tracking_lines_bulk_v1(
  p_order_id uuid,
  p_actor_mode text,
  p_tracking_submission_id uuid,
  p_line_ids uuid[],
  p_confirm_same_package boolean
) returns jsonb
```

This function exists only for bulk submission. It must not replace or be called by the existing single action.

For each selected line, the function must reproduce the existing single-action allocation rules as they exist at the patch baseline:

- authenticate operator/importer access or active supervisor/admin staff;
- require the tracking submission to belong to the order;
- require the supplier line to belong to the order and be progressed;
- reject an active `non_physical_financial` resolution exactly as the existing single action does;
- derive line quantity as `COALESCE(qty_confirmed, qty, 0)`;
- derive line amount as `COALESCE(amount_confirmed, amount_inc_vat_gbp, 0)`;
- calculate existing allocated quantity using the same raw `SUM(qty_allocated)` basis as the existing single action;
- derive current remaining quantity on the server;
- reject zero/negative remaining quantity;
- allocate the full current server-derived remaining quantity;
- derive base value proportionally using the same existing single-action formula;
- write the same ordinary confirmed allocation shape used by the existing operator/staff flow, with zero discount/delivery shares and adjusted net equal to base value;
- use `operator_declaration` for operator bulk assignment and `supervisor_estimate` for staff bulk assignment, matching the current form defaults.

No replacement-specific arithmetic or replacement-route lookup belongs in this function.

## 14. Atomicity and concurrency

The bulk RPC must be one transaction.

It must:

```text
validate payload
-> lock order
-> authenticate actor
-> acquire the established order advisory transaction lock
-> lock the selected supplier lines in deterministic order
-> lock relevant existing allocation rows in deterministic order
-> calculate every selected line's current remaining quantity
-> validate every selected line before inserting any allocation
-> insert all selected allocations
-> call the existing recalculate_invoice_adjustment_consumption_v1 for each affected supplier invoice
-> return success
```

One invalid selected line, one failed insert or one failed ledger recalculation must roll back the entire bulk operation.

The advisory lock is writer serialization only. It does not alter replacement behaviour or make replacement part of this feature.

Do not add a generic cumulative-allocation trigger or constraint.

## 15. Permitted implementation files

Application changes are limited to:

```text
app/delivery-allocation/actions.ts
app/delivery-allocation/DeliveryAllocationWorkspace.tsx
app/delivery-allocation/DeliveryAllocationBulkControls.tsx
```

Database/test/governing changes are limited to:

```text
docs/governing-pack/backend/Delivery_Allocation_Lock_Timing_Clarification_v1.md
supabase/migrations/<one additive bulk-only migration>.sql
docs/testing/<bulk source regression>.mjs
docs/testing/<bulk rollback/postflight regression>.sql
```

`app/delivery-allocation/data.ts` is explicitly out of scope and must equal the pre-patch baseline.

`app/_components/FloatingActionBar.tsx` must be reused unchanged.

No replacement, shipper, customer, reconciliation, Sage, VAT, COS or export implementation file may change.

## 16. Migration contract

Use one additive migration. Do not edit deployed migrations.

The migration must install only `delivery_allocate_tracking_lines_bulk_v1` plus exact execution grants.

It must not create or alter:

- a single-allocation RPC;
- a clear/rework RPC;
- a control-state RPC;
- allocation tables or triggers;
- replacement functions/tables;
- receipt/shipment/customer/accounting/export authorities.

Revoke execution from `PUBLIC` and `anon`; grant to `authenticated` consistent with application use.

## 17. Mandatory regression proof

Before merge, prove:

### Frozen baseline
- `app/delivery-allocation/data.ts` is byte-identical to the branch base;
- the existing `saveDeliveryAllocationAction` body is unchanged from the branch base;
- the existing `clearDeliveryAllocationForLineAction` body is unchanged from the branch base;
- replacement implementation files are unchanged;
- shipper/customer/accounting/export implementation files are unchanged;
- `FloatingActionBar.tsx` is unchanged.

### Bulk UI
- checkbox rendering uses the same `!complete && !hasDownstreamLock` gate as the individual assignment form;
- Select all acts only on those rendered/enabled checkboxes;
- tracking change resets confirmation;
- line-selection change resets confirmation;
- submit requires selection + tracking + confirmation;
- no bulk quantity input exists;
- existing individual partial form is unchanged and still present.

### Bulk database behaviour
- one selected line succeeds;
- several selected lines succeed atomically;
- a partially allocated selected line receives only its current server-derived remaining quantity;
- duplicate line IDs fail;
- wrong-order tracking fails;
- non-progressed line fails;
- active non-physical financial line fails using the existing rule;
- stale browser state cannot over-allocate;
- one invalid line causes zero bulk inserts;
- recalculation failure rolls back every bulk insert;
- no replacement row/function is mutated;
- no generic allocation trigger/constraint is introduced.

## 18. Acceptance example

Given the existing page currently renders three individually assignable lines:

```text
A remaining 1
B remaining 2
C remaining 1
```

The operator selects `DHL123`, ticks A/B/C, confirms the selected items are in that package and presses `Apply tracking ref`.

One atomic bulk transaction creates the same ordinary allocations that three current full-remaining individual submissions would create:

```text
A -> DHL123 qty 1
B -> DHL123 qty 2
C -> DHL123 qty 1
```

The existing individual forms, line visibility, line arithmetic, rework behaviour and all downstream/replacement workflows remain unchanged.

## 19. Final governing sentence

```text
This patch is only a bulk-assignment wrapper around the existing delivery-allocation lane: it adds checkboxes, one shared package confirmation and one atomic bulk-only write, while leaving the existing single assignment, data loader, eligibility meaning, quantity/value presentation, rework, replacement and downstream workflows unchanged.
```
