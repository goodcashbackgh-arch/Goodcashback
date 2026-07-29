# OCR-Discovered Delivery / Discount Adjustment Lifecycle Addendum v1

## Objective

Correct one narrow lifecycle gap: when OCR identifies a retailer delivery or discount line that was not represented by an existing live `order_value_adjustments` fact, and the operator or supervisor resolves that OCR line as an active `non_physical_financial` delivery/discount line, the platform must materialise the matching existing adjustment fact and keep the existing `delivery_discount_query` review flag open until that adjustment is accepted under the existing adjustment policy.

This addendum does not introduce a new workflow. It connects the already-existing non-physical financial classification path to the already-existing adjustment approval path.

---

## Proven defect

Controlled invoice:

```text
NK-INV-310726-73
supplier_invoice_id: 1bc3543f-05b9-473b-8ba0-47eb8bef43d8
```

The installed database proves:

```text
OCR line:
  Retailer delivery charge £11.42

active line resolution:
  resolution_type = non_physical_financial
  financial_type  = delivery
  amount_gbp      = 11.42
  active          = true

review flag:
  flag_type = delivery_discount_query
  status    = open

order_value_adjustments:
  no row for this supplier invoice
```

Therefore the line classification exists, but the commercial adjustment approval fact does not. The Adjustments queue is bypassed and the open review flag continues to block supplier-invoice approval.

---

## Existing working model to preserve

Live production examples prove the established data shape is:

```text
retailer_delivery adjustment + non_physical_financial delivery resolution
retailer_discount adjustment + non_physical_financial discount resolution
```

Existing policy is preserved:

- retailer delivery at or below the configured delivery auto-approval limit is `auto_approved`;
- retailer delivery above that limit is `pending_supervisor`;
- retailer discount is `pending_supervisor`;
- approved/auto-approved adjustments are the adjustment facts consumed by the existing invoice adjustment basis;
- the non-physical line resolution remains the line-classification fact.

For the controlled £11.42 delivery, the existing £10 default/configured threshold means the materialised adjustment must be `pending_supervisor` and must appear on the existing Adjustments page.

---

## Required flow

```text
OCR raises delivery_discount_query
        ↓
operator/supervisor classifies the OCR line as delivery or discount
        ↓
existing non_physical_financial resolution is written
        ↓
if no live adjustment of that type already exists, materialise the matching
retailer_delivery / retailer_discount adjustment
        ↓
existing adjustment policy determines auto_approved vs pending_supervisor
        ↓
if pending_supervisor, review flag stays open
        ↓
existing Adjustments page approves/rejects as today
        ↓
when all delivery/discount facts represented by the query are accepted,
resolve delivery_discount_query
        ↓
existing supplier-invoice approval guard sees no open flag
```

---

## Mandatory narrow gates

Adjustment materialisation is permitted only when all of the following are true:

1. the supplier invoice has an open or under-review `delivery_discount_query`;
2. the supplier invoice is still `pending_review`;
3. the line has an active `non_physical_financial` resolution;
4. `financial_type` is exactly `delivery` or `discount`;
5. the resolved amount is non-zero;
6. no non-rejected matching adjustment already exists for the same supplier invoice, mapped adjustment type and amount within £0.01;
7. if a non-rejected adjustment of the same mapped type already exists with a different amount, do not create a second adjustment; leave the review flag unresolved for the existing correction route;
8. operator provenance must be available from the resolution or source supplier invoice before a new adjustment is created.

The patch must be idempotent. Re-saving or reclassifying the same resolved fact must not create duplicate adjustments.

---

## Review-flag completion rule

The patch must not close `delivery_discount_query` merely because one line was classified.

The flag may resolve only when:

- the invoice still has the relevant active delivery/discount non-physical resolution facts;
- every non-rejected delivery/discount adjustment for the invoice is accepted (`approved` or `auto_approved`);
- accepted retailer-delivery total agrees with the active resolved delivery total within £0.01;
- accepted retailer-discount total agrees with the absolute active resolved discount total within £0.01;
- no non-zero OCR line that is recognisably delivery/discount remains unclassified as a matching active non-physical financial resolution.

If a supervisor corrects an adjustment to an amount that no longer agrees with the classified OCR facts, the review flag remains open. Existing reconciliation/correction controls remain authoritative.

---

## Historical repair boundary

The migration may repair only the exact orphan lifecycle shape described by this addendum:

- pending-review supplier invoice;
- open/under-review `delivery_discount_query`;
- active delivery/discount `non_physical_financial` resolution;
- no non-rejected adjustment of the mapped type.

No other historical adjustment, resolution, review flag, invoice state or downstream artefact may be rewritten.

---

## Required production change

Production code may change only through one additive database migration:

```text
supabase/migrations/20260729_ocr_discovered_adjustment_lifecycle_v1.sql
```

The migration may add only:

- an internal helper that materialises the missing adjustment under the gates above;
- an internal helper that resolves `delivery_discount_query` only when the acceptance contract above is satisfied;
- a narrow trigger on `supplier_invoice_line_resolutions` to invoke those helpers after a qualifying delivery/discount non-physical resolution is inserted or materially updated;
- a narrow trigger on `order_value_adjustments` to re-evaluate the review flag when a relevant adjustment becomes accepted or its amount/status changes;
- the exact guarded historical repair described above.

A regression file may be added under `docs/testing/`.

No application file is in scope.

If implementation appears to require an application/UI change or replacement of an existing RPC, stop and amend this addendum before proceeding.

---

## Explicitly untouched

This patch must not alter:

- `operator_resolve_supplier_invoice_line_non_physical(...)`;
- `staff_resolve_supplier_invoice_line_non_physical(...)`;
- the existing Adjustments page UI or actions;
- adjustment threshold configuration or the £10 fallback;
- discount approval policy;
- supplier invoice approval RPCs or approval guards;
- `staff_finalize_order_supplier_invoices_v1(...)`;
- Supplier Draft Ready logic;
- supplier invoice OCR extraction or flag creation;
- supplier invoice line source values;
- physical-line progression;
- accounting coding or VAT calculations;
- Sage supplier AP readiness, payloads, snapshots or posting;
- invoice adjustment basis formulae or allocation maths;
- funding, banking or treasury;
- tracking, shipment allocation or receipt;
- export evidence or POD;
- customer sales;
- exceptions, disputes, holds, refunds or replacements;
- platform order status;
- permissions, roles, navigation, styling or wording;
- existing adjustment rows except the narrow approval action a supervisor already performs through the existing UI.

No new status vocabulary, page, queue, role or workflow is permitted.

---

## Fail-closed requirements

The patch must not:

- invent an adjustment from OCR description alone;
- create an adjustment without an active explicit non-physical financial resolution;
- create a duplicate adjustment when a live same-type adjustment already exists with a conflicting amount;
- auto-approve an over-limit delivery;
- auto-approve a retailer discount;
- resolve the review flag while a relevant adjustment remains pending or rejected;
- resolve the review flag when accepted adjustment totals do not agree with active resolved financial totals;
- alter any immutable export/customer-release history;
- rewrite a locked adjustment basis as part of this defect fix.

---

## Regression requirements

The regression must prove at minimum:

1. both existing non-physical resolution RPC definitions are unchanged;
2. the new resolution trigger is restricted to active `non_physical_financial` delivery/discount facts;
3. materialisation requires an open/under-review `delivery_discount_query` and a pending-review invoice;
4. existing matching live adjustments are reused, not duplicated;
5. conflicting same-type live adjustments do not cause another row to be created;
6. delivery uses the existing configured shipper/global threshold with £10 fallback;
7. discounts remain supervisor-required;
8. the controlled £11.42 orphan becomes exactly one `retailer_delivery` `pending_supervisor` adjustment;
9. the controlled open flag remains open before supervisor approval;
10. within a rollback-only approval simulation, accepting that £11.42 adjustment resolves the query flag;
11. rejecting or leaving the adjustment pending does not resolve the flag;
12. no supplier invoice approval/Sage/funding/tracking/shipping/customer-sales object is changed by the migration.

---

## Scope rule

This addendum is the scope boundary.

Do not use this defect to redesign adjustments, reconciliation, review flags, invoice approval or accounting. The only production change is the missing lifecycle bridge between an already-classified OCR delivery/discount fact and the already-existing adjustment approval control.