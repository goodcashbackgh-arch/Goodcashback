# Hybrid Physical Receipt Same-Order Free Replacement Routing Addendum v1

**Subtitle:** Exact tracking-allocation supersession, effective entitlement preservation, multi-line replacement routing and legacy-child compatibility

**Status:** governing technical specification and non-regression authority

**Effective date:** 3 August 2026

**Verified repository baseline:** `main` at `03dae8521396567fcc2e12c737f5c43bed616fa7`

## 1. Purpose

This addendum governs the narrow correction for a physical item that:

- was already progressed on an authoritative supplier invoice;
- was already charged and commercially recognised on the original order;
- was allocated to an original tracking package;
- later reached the shipper as missing, damaged or wrong; and
- is accepted by the retailer for free physical replacement.

For this exact case, the replacement remains on the same original order and the same authoritative supplier-invoice line.

The required result is:

```text
original supplier invoice quantity and amount remain unchanged;
original failed physical attempt remains immutable audit history;
only the exact failed quantity is transferred out of the original allocation's current entitlement position;
a successor tracking allocation is created on the original order and original supplier-invoice line;
current effective quantity remains equal to the original invoiced quantity;
current effective commercial value remains equal to the original invoiced value;
no new replacement child order is created;
no second supplier invoice, DVA OUT, supplier AP or Sage purchase invoice is created;
Mini Builds 1-4 remain definitionally unchanged.
```

This is not a new receipt, customer-review, shipment, customer-release, refund, accounting, VAT, Sage or settlement workflow. It is an additive routing and entitlement-transfer adapter around the existing order and tracking-allocation path.

A builder must implement from this document and verified source definitions, not from informal recollection. Any mismatch stops the build.

## 2. Authority and precedence

This addendum must be read with:

1. `HYBRID_PHYSICAL_RECEIPT_QUANTITY_FULFILMENT_AND_REMEDY_CONTROL_ADDENDUM_v1.md`;
2. `HYBRID_PHYSICAL_RECEIPT_QUANTITY_FULFILMENT_AND_REMEDY_CONTROL_ADDENDUM_v1_1.md`;
3. `HYBRID_PHYSICAL_RECEIPT_IMPLEMENTATION_ALIGNMENT_ADDENDUM_v1_2.md`;
4. `HYBRID_PHYSICAL_RECEIPT_BUILD_4_LIFECYCLE_AND_RECONCILIATION_ALIGNMENT_ADDENDUM_v1.md`;
5. `MULTI_SUPPLIER_INVOICE_ORDER_CONTROL_ADDENDUM_v1.md`;
6. the current delivery-allocation, customer-review, shipment-membership, customer-sales-release, reconciliation and closure authorities.

Where this addendum is more specific about **new free physical replacements**, it controls.

It supersedes earlier wording that requires a replacement child for every new physical replacement allocation.

It does not rewrite or invalidate historical replacement-child records or their historical governing migrations.

Historical migrations remain immutable. Implementation must use later additive migrations and later versioned functions or wrappers.

## 3. Locked business routing matrix

### 3.1 Invoiced and charged, then physically missing, damaged or wrong

Allowed outcomes:

```text
free replacement on the same original order
or
refund through the existing refund route
```

A free replacement uses the exact original supplier line and a new tracking attempt. It creates no new supplier commercial charge.

### 3.2 Charged but no supplier invoice line is available

This is not the physical-replacement route.

The operator must:

```text
obtain the missing supplier invoice and tracking through the normal multi-invoice/order lane
or
obtain a refund and use the existing settlement-credit route
```

### 3.3 Not charged and not invoiced

This is not the physical-replacement route.

If the customer still wants the goods, use the normal new-order purchase path.

If the customer does not want the goods, conclude through the existing settlement-credit route.

### 3.4 Retailer demands a new payment

This addendum does not convert a paid physical failure into another supplier charge.

If a retailer refuses a free replacement and the customer elects to purchase again, that purchase follows the normal new-order or normal invoiced-order lane. It does not use the same-order free-replacement adapter.

## 4. Verified current repository facts

### 4.1 Tracking allocations have no quantity-level supersession authority

`order_tracking_line_allocations` stores one positive `qty_allocated` and value components for one supplier-invoice line and tracking submission.

The current table has no fields or linked authority for:

- partially transferred failed quantity;
- source-to-successor allocation identity;
- transferred quantity or value;
- same-order physical-replacement route identity.

### 4.2 The current delivery-allocation action counts raw historical allocations

`app/delivery-allocation/actions.ts` loads every `order_tracking_line_allocations.qty_allocated` row for the supplier-invoice line and rejects a new allocation when the raw total would exceed the line quantity.

Therefore:

```text
invoice quantity = 4
existing raw allocations = 4
replacement successor allocation = 1
current raw test = 5 and rejects the allocation
```

### 4.3 Current audience tracking coverage also consumes raw allocation quantity

The current `order_audience_status_v1` chain derives active tracking allocation coverage from `order_tracking_line_allocations.qty_allocated` joined to active tracking submissions.

Without an effective-entitlement layer, a same-order successor can appear as excess tracking quantity.

### 4.4 Invoice-adjustment consumption currently reads raw allocation quantity

`recalculate_invoice_adjustment_consumption_v1` rebuilds mutable progressed-allocation consumption from `order_tracking_line_allocations.qty_allocated`.

A successor allocation must not create a second commercial consumption of the original supplier-line basis.

### 4.5 Commercial reconciliation is already separate and must remain unchanged

`order_reconciliation_vw` uses authoritative supplier-invoice lines and checks both quantity and amount.

For a free same-order replacement:

```text
qty target remains unchanged;
progressed authoritative invoice quantity remains unchanged;
amount target remains unchanged;
progressed authoritative invoice amount remains unchanged;
```

No replacement supplier invoice is inserted, so commercial reconciliation must continue to clear from the original invoice facts.

### 4.6 Mini Build physical fulfilment is already allocation-scoped

The existing physical-receipt quantity model stores exact clean and affected quantities against the exact tracking allocation.

The failed source allocation can therefore remain historical with its exact affected quantity, while the successor allocation later receives its own normal tracking and receipt facts.

Customer review, held-item handling, shipment membership and customer release already operate from exact allocation/receipt membership. Those authorities are not redesigned by this addendum.

### 4.7 Current Build 4 completion is child-specific

The current physical-remedy guard requires a completed replacement remedy to carry `replacement_child_tracking_allocation_id`, and requires that allocation to belong to `replacement_child_order_id`.

The current parent blocker treats a physical remedy as open unless its status is `completed`, `rerouted` or `closed_no_action`.

Therefore a same-order replacement cannot be truthfully closed merely by inserting another tracking allocation while leaving all Build 4 callers unchanged.

The implementation must solve this through an additive same-order route and a later compatibility overlay. It must not weaken, replace or edit the Mini Build 1-4 guard and blocker definitions.

## 5. Mini Builds 1-4 are frozen

The implementation must not replace, edit or weaken the definitions, grants, owners, security attributes or trigger bindings of the Mini Build 1-4 authorities, including at minimum:

```text
shipper_record_package_receipt_v2(...)
operator_submit_physical_receipt_proposal_v1(...)
staff_decide_physical_receipt_review_v1(...)
staff_decide_physical_receipt_review_v2(...)
internal_tracking_allocation_fulfilment_position_v1(...)
tracking_allocation_fulfilment_position_v1
customer-review materialisation and membership authorities
customer-hold membership and conversion authorities
shipment candidate, batch and line-membership authorities
customer-sales release authorities
physical_remedy_allocation_guard_v2()
physical_remedy_sequence_guard_v1()
physical_receipt_review_guard_v1()
order_has_open_child_exceptions_v2(uuid)
create_replacement_child_order_v2(uuid,uuid,uuid,text)
staff_accept_replacement_outcome_v1(uuid,uuid,text)
```

The old functions remain installed for legacy records.

Any implementation that edits one of those protected definitions is outside this addendum and must stop.

## 6. Core quantity and value invariant

The system must distinguish:

```text
raw physical attempts
from
current effective commercial entitlement
```

Example:

```text
supplier invoice line quantity: 4
original tracking allocation quantity: 4
physical receipt: 3 clean + 1 affected
same-order replacement successor: 1

raw historical attempts: 5
effective entitlement quantity: 4
```

The invariant is:

```text
effective allocation quantity
= raw allocation quantity
- exact quantity transferred out from failed source allocations
```

Because the successor allocation remains part of raw allocation quantity, the source transfer subtraction prevents the false fifth unit.

The value invariant is identical:

```text
effective allocation value
= raw allocation value
- exact value transferred out from failed source allocations
```

The successor allocation must receive exactly the transferred quantity and transferred value. Therefore the order's current effective quantity and current effective value remain unchanged.

No original allocation, receipt, disposition, evidence, supplier invoice or supplier-invoice line is deleted or rewritten.

## 7. New sidecar table

Add one new table:

```text
physical_replacement_same_order_routes
```

One row represents one exact approved physical replacement remedy allocation routed to the same original order.

Required columns:

```text
id uuid primary key
physical_remedy_allocation_id uuid not null unique
physical_receipt_review_id uuid not null
dispute_id uuid not null
dispute_line_id uuid not null unique
order_id uuid not null
supplier_invoice_line_id uuid not null
source_tracking_line_allocation_id uuid not null
source_receipt_line_disposition_id uuid not null
replacement_qty numeric(12,3) not null
transferred_base_value_gbp numeric(14,2) not null
transferred_discount_share_gbp numeric(14,2) not null
transferred_retailer_delivery_share_gbp numeric(14,2) not null
transferred_adjusted_net_value_gbp numeric(14,2) not null
route_status text not null
successor_tracking_submission_id uuid null
successor_tracking_line_allocation_id uuid null unique
accepted_by_staff_id uuid not null
accepted_at timestamptz not null
tracking_allocated_by_operator_id uuid null
tracking_allocated_by_staff_id uuid null
tracking_allocated_at timestamptz null
cancelled_by_staff_id uuid null
cancelled_at timestamptz null
cancellation_reason text null
notes text null
created_at timestamptz not null
updated_at timestamptz not null
```

Allowed persisted route statuses:

```text
approved_waiting_tracking
tracking_allocated
cancelled
```

`fulfilled_clean` is a derived operational state from the successor allocation's existing finalised physical-receipt facts. It is not a replacement for those receipt facts.

Required uniqueness and shape rules:

```text
one route per physical remedy allocation;
one route per dispute line;
one route per successor tracking allocation;
replacement_qty > 0 and is a whole unit;
transferred adjusted value > 0;
tracking_allocated requires both successor IDs and exactly one allocation actor;
approved_waiting_tracking requires both successor IDs to be null;
cancelled requires cancellation actor, time and reason;
replacement_child_order_id remains null in the existing remedy and dispute;
resolved_via_child_order_id remains null on the dispute line.
```

Direct browser writes are prohibited.

## 8. Exact route identity checks

Before creating a route, require all of the following under deterministic row locks:

```text
dispute desired_outcome = replacement;
dispute is unresolved and has no replacement child;
exactly one active physical remedy-linked dispute line belongs to the dispute;
retailer reply exists;
all active dispute lines have retailer_response_received;
remedy approved type = replacement;
remedy approved quantity is a positive whole unit;
remedy status is approved or linked_to_exception;
remedy replacement child fields are null;
review order = dispute order;
source disposition belongs to the review receipt;
source disposition type is missing, damaged or wrong;
source disposition tracking allocation = remedy tracking allocation;
source disposition supplier line = remedy supplier line;
source tracking allocation belongs to the same order and supplier line;
replacement quantity <= affected disposition quantity;
replacement quantity <= source tracking allocation quantity;
customer commercial value is proven and positive;
no existing same-order route or replacement child has consumed the remedy.
```

Any mismatch rolls back the entire action.

## 9. Explicit final supplier-cost classification

The same-order adapter is available only for:

```text
supplier_cost_mode = free_replacement
```

If the current mode is `pending_supplier_evidence`, the final supervisor action must require an explicit confirmation that the retailer is supplying the replacement free of charge and atomically set the mode to `free_replacement` before route creation.

The action must not silently infer free replacement merely from the desired outcome.

If the final mode is `charged_repurchase`, the same-order free-replacement action rejects the case. The case must be routed to the normal paid purchase/invoice path.

A completed same-order route can never retain `pending_supplier_evidence`.

## 10. New final-acceptance authority

Add:

```text
staff_accept_same_order_free_replacement_v1(
  p_dispute_id uuid,
  p_staff_id uuid,
  p_confirmed_supplier_cost_mode text,
  p_notes text default null
)
returns uuid
```

The function must:

1. authenticate the active supervisor/admin through `auth.uid()`;
2. lock the dispute, active dispute line, physical remedy, review, source disposition, source allocation and supplier line in deterministic order;
3. require the exact checks in sections 8 and 9;
4. calculate and store the exact transferred quantity and value components;
5. insert one `physical_replacement_same_order_routes` row in `approved_waiting_tracking`;
6. progress the existing physical remedy only to `in_progress`;
7. resolve the retailer-facing dispute and line as replacement accepted while keeping all child-order fields null;
8. write an audit event identifying the original order, source allocation, remedy, route and approved quantity;
9. call the later same-order-aware order-status recompute authority;
10. return the route ID.

It must not call:

```text
staff_accept_replacement_outcome_v1
create_replacement_child_order_v2
```

Those functions remain unchanged for legacy/manual child cases.

## 11. Deterministic transferred value

The successor allocation is a physical retry of the same commercial entitlement. Its value is transferred, not newly created.

For one source allocation, calculate all active same-order replacement route slices together.

Create buckets for:

- every same-order route quantity against the source allocation; and
- one synthetic retained-source remainder when source quantity exceeds transferred route quantity.

Apply the existing deterministic proportional and penny-residual principles separately to:

```text
base_value_gbp
discount_share_gbp
retailer_delivery_share_gbp
adjusted_net_value_gbp
```

Required postconditions:

```text
sum of transferred quantity <= source qty_allocated;
sum of transferred base <= source base;
sum of transferred discount <= source discount;
sum of transferred delivery <= source delivery;
sum of transferred adjusted net <= source adjusted net;
retained source slice + every transferred slice = exact original component total;
route transferred adjusted net = remedy customer_commercial_value_gbp;
no route receives zero or negative adjusted value;
repeated calculation against identical locked facts is deterministic.
```

No penny or quantity may move between different source allocations or different supplier-invoice lines.

## 12. New tracking-allocation authority

Add one atomic multi-route function:

```text
operator_allocate_same_order_replacement_tracking_v1(
  p_order_id uuid,
  p_tracking_submission_id uuid,
  p_route_ids uuid[],
  p_note text default null
)
returns jsonb
```

A staff-equivalent wrapper may be added only if the existing internal allocation workspace requires it.

The operator function must:

1. authenticate an active operator with current access to the order importer;
2. lock the order and tracking submission;
3. require the tracking submission to belong to the same original order and remain active;
4. reject an empty array or duplicate route IDs;
5. lock all route rows and source allocations in UUID order;
6. require every route to be `approved_waiting_tracking` for the same order;
7. create one ordinary `order_tracking_line_allocations` successor row per route;
8. use the route's exact original supplier-invoice line;
9. set successor quantity and value components exactly to the transferred slice;
10. link every route to the shared tracking submission and its exact successor allocation;
11. set each route to `tracking_allocated`;
12. prove the effective line quantity and value invariants before commit;
13. refresh only the later effective invoice-adjustment authority;
14. call the later same-order-aware status recompute;
15. return all created successor allocation IDs.

A single replacement tracking reference may therefore carry several successor allocations from several supplier-invoice lines.

The function must not insert or update:

```text
supplier_invoices
supplier_invoice_lines
orders as replacement children
order_category_lines for a replacement child
DVA/card funding rows
supplier AP rows
Sage purchase-invoice rows
```

## 13. Multi-unit and multi-line support

### 13.1 One line, quantity greater than one

Example:

```text
source allocation quantity = 4
physical result = 2 clean + 2 damaged
approved free replacement quantity = 2
```

Required result:

```text
source raw quantity = 4
source transferred-out quantity = 2
source effective quantity = 2
successor quantity = 2
line effective total = 4
```

### 13.2 Several supplier-invoice lines on one tracking reference

Example:

```text
line A missing quantity = 1
line B damaged quantity = 2
one retailer replacement shipment contains both lines
```

Required result:

```text
one successor tracking submission
one successor allocation for line A quantity 1
one successor allocation for line B quantity 2
exact route and source provenance retained per line
no cross-line value apportionment
```

### 13.3 Partial failure inside one original allocation

The implementation must never supersede the entire original allocation when only part failed.

The sidecar records exact transferred quantity. The original allocation remains unchanged as raw audit evidence; only its effective position is reduced.

### 13.4 Atomicity

When several route IDs are allocated to one tracking reference, the operation is all-or-nothing.

One invalid line, value or provenance mismatch rolls back every successor allocation in that request.

## 14. Effective entitlement resolver

Add:

```text
tracking_allocation_effective_entitlement_v1(
  p_order_id uuid default null,
  p_supplier_invoice_line_id uuid default null
)
```

It must expose at least:

```text
allocation_id
order_id
supplier_invoice_line_id
tracking_submission_id
raw_qty_allocated
transferred_out_qty
effective_qty_allocated
raw_base_value_gbp
transferred_out_base_value_gbp
effective_base_value_gbp
raw_discount_share_gbp
transferred_out_discount_share_gbp
effective_discount_share_gbp
raw_retailer_delivery_share_gbp
transferred_out_retailer_delivery_share_gbp
effective_retailer_delivery_share_gbp
raw_adjusted_net_value_gbp
transferred_out_adjusted_net_value_gbp
effective_adjusted_net_value_gbp
is_same_order_successor
source_allocation_id
replacement_route_id
```

For source allocations:

```text
transferred_out = sum of non-cancelled route slices with a committed successor allocation
```

For successor allocations:

```text
transferred_out = 0
effective = raw
```

Required invariants:

```text
effective quantity >= 0;
effective monetary components >= 0;
source transfer never exceeds raw source quantity or component value;
line-level effective quantity never exceeds authoritative supplier-line quantity;
line-level effective adjusted value never exceeds the original authoritative allocation value basis;
successor route identity is unique;
cancelled routes with no committed successor do not affect effective entitlement.
```

The resolver is the only authority for current entitlement totals after this build.

## 15. Raw history versus effective current position

Do not apply the effective filter indiscriminately.

### 15.1 Readers that must remain raw

The following must continue showing actual physical attempts and exact package history:

- original and successor package contents;
- receipt headers and line dispositions;
- receipt evidence;
- return/collection evidence;
- audit reports;
- physical-attempt history by tracking submission.

It is correct for audit history to show five physical attempts where four commercial units required one retry.

### 15.2 Readers that must use effective entitlement

The following current-position calculations must use the new resolver or a versioned wrapper over it:

- delivery-allocation over-allocation validation;
- tracking-allocation completeness by supplier-invoice line;
- importer audience/status tracking-assignment coverage;
- mutable invoice-adjustment consumption and value basis consumption;
- any current order-level quantity or value projection that sums allocation rows as commercial entitlement.

### 15.3 Readers that remain allocation-scoped and unchanged

Mini Build physical receipt, customer review, holds, shipment availability, shipment membership and customer-sales release remain allocation-scoped.

They continue to process:

```text
failed source allocation according to its exact clean/affected facts
and
successor allocation according to its own later receipt facts
```

No Mini Build definition is changed merely to hide historical attempts.

## 16. Derived same-order route position

Add:

```text
physical_replacement_same_order_position_v1
```

For each route derive:

```text
approved_waiting_tracking
tracking_allocated_waiting_receipt
fulfilled_clean
successor_exception_open
cancelled
invalid
```

Use the existing exact physical-receipt position for the successor allocation.

`fulfilled_clean` requires:

```text
route is not cancelled;
successor allocation exists;
latest authoritative finalised receipt exists for the successor package/allocation;
physical clean quantity for the successor allocation >= replacement quantity;
physical exception quantity consuming that replacement quantity = 0;
position is valid and has no invariant blocker.
```

If the successor is missing, damaged, wrong or held, the route is not fulfilled. The normal physical-review process handles that successor attempt.

The original retailer dispute may be resolved as replacement accepted while the same-order route remains operationally open until `fulfilled_clean`.

## 17. Additive closure compatibility without changing Mini Builds

Because the existing Build 4 blocker treats the source remedy as open and the existing guard requires child provenance for `completed`, this addendum must not pretend that setting the existing remedy to `completed` is available.

Add:

```text
order_has_open_child_exceptions_v3(uuid)
```

It must preserve every branch of `order_has_open_child_exceptions_v2` exactly, except that an otherwise-open physical replacement remedy is treated as operationally satisfied when an exact same-order route for that remedy is derived as `fulfilled_clean`.

Legacy disputes, legacy replacement children, cancelled-child reroute rules, refund remedies, no-action remedies and every non-same-order case remain identical to v2.

Do not replace or edit `order_has_open_child_exceptions_v2`.

Add later versioned closure callers that use v3, including at minimum:

```text
recompute_order_status_v2(uuid)
```

and every proven active accounting/final-closure caller that directly invokes a prior child-exception blocker.

The existing functions remain installed and unchanged for compatibility. Application and new same-order authorities must use the new versioned callers.

Before implementation, produce a complete database and repository call graph for:

```text
order_has_open_child_exceptions(...)
order_has_open_child_exceptions_v2(...)
recompute_order_status(...)
mark_order_accounting_release_ready(...)
```

Only proven active callers may be adapted. Any hidden dynamic caller or drift stops implementation.

## 18. Existing order completion and reconciliation

Commercial reconciliation remains based on authoritative supplier-invoice quantity and amount.

The same-order retry must not change `order_reconciliation_vw`.

Operational progression is:

```text
retailer accepts free replacement
-> same-order route approved
-> successor tracking allocated on original order
-> shipper records successor receipt
-> route derives fulfilled_clean
-> same-order-aware blocker clears the physical replacement route
-> original order continues through existing review, shipment, customer release, POD and accounting gates
```

No new parent-child recomputation is needed because the original order is the operational order.

The new acceptance and allocation authorities must explicitly call `recompute_order_status_v2` after successful writes. The implementation must also prove by regression that later existing triggers cannot regress the order solely because v2 still sees the historical in-progress remedy.

If that regression fails, implementation stops for an explicit caller-overlay decision. Do not edit Mini Build definitions ad hoc.

## 19. Existing replacement children remain legacy-supported

This addendum applies prospectively to new physical free-replacement cases.

Existing `replacement_child` orders remain valid historical records.

The following legacy compatibility defects remain in scope:

1. the shared child operations page must not block solely because `order_audience_status_v1(child_id)` returns no row;
2. the duplicate replacement-specific invoice upload form in `app/importer/orders/[order_id]/operations/layout.tsx` must be removed;
3. legacy charged replacement children must use the normal shared operations invoice, tracking and reconciliation controls;
4. no fake or zero-value supplier invoice may be required for a legacy free child;
5. legacy child functions and database records must not be rewritten into same-order routes.

Add an audience/status compatibility version that returns an authorised row for legacy replacement children while preserving the original parent commercial ownership rules.

Do not use the legacy child UI repair as justification for creating new children.

## 20. Application routing

### 20.1 Supervisor final replacement acceptance

In `app/internal/exceptions/[dispute_id]/actions.ts`, the final replacement action must branch from server-derived facts:

```text
physical remedy-linked dispute
+ free replacement confirmed
+ no existing child
-> staff_accept_same_order_free_replacement_v1

legacy manual replacement dispute
-> existing staff_accept_replacement_outcome_v1
```

The client must not choose the route from a hidden field alone.

The page must clearly state:

```text
Free replacement: continues on the original order; no new supplier invoice or child order.
```

### 20.2 Importer tracking allocation

After same-order acceptance, the original order operations/delivery-allocation page must show the open replacement route quantities and allow one tracking reference to be assigned to one or more route rows.

The UI submits route IDs, not arbitrary source line IDs or values.

### 20.3 Legacy child operations

Remove the layout-level duplicate replacement invoice component.

Restore the existing shared operations page for authorised legacy children through the audience/status compatibility read.

## 21. Permissions and RLS

Enable RLS on `physical_replacement_same_order_routes`.

Authenticated read access:

- active supervisor/admin staff;
- active operators with current importer access to the original order;
- active shipper users only when the successor tracking submission belongs to their shipper and only for operational facts needed by their existing package route.

Direct authenticated insert, update and delete are prohibited.

For every new function:

```sql
REVOKE ALL ON FUNCTION ... FROM PUBLIC;
REVOKE ALL ON FUNCTION ... FROM anon;
GRANT EXECUTE ON FUNCTION ... TO authenticated;
```

Grant `service_role` only where the exact current equivalent requires it and the need is proven.

Every `SECURITY DEFINER` function performs its own actor, tenant, order and source-provenance checks.

## 22. Locking, idempotency and concurrency

Use the current order/tracking advisory-lock convention.

Required lock order:

```text
order
dispute
dispute line
physical review
physical remedy allocation
source receipt disposition
source tracking allocation
same-order route
successor tracking submission
successor allocation
```

Rows within one class are locked in UUID order.

Required concurrency behaviour:

- two final-acceptance calls create at most one route;
- child acceptance and same-order acceptance serialize, and only one may consume the remedy;
- two tracking-allocation calls create at most one successor per route;
- a route cannot be assigned to two tracking submissions;
- multi-line allocation is atomic;
- cancellation cannot race with successor creation;
- a source quantity/value slice cannot be transferred twice;
- retries with the same route set and tracking submission return the existing committed result when payload identity matches, and reject changed retries.

## 23. Required migration sequence

### Migration A — sidecar and effective entitlement foundation

Add:

```text
physical_replacement_same_order_routes
tracking_allocation_effective_entitlement_v1(...)
physical_replacement_same_order_position_v1
RLS, indexes, constraints and read grants
```

No existing function is replaced.

### Migration B — same-order acceptance and allocation authorities

Add:

```text
staff_accept_same_order_free_replacement_v1(...)
operator_allocate_same_order_replacement_tracking_v1(...)
optional proven staff allocation wrapper
```

### Migration C — effective current-position adapters

Add versioned effective readers/functions for the proven raw commercial-entitlement consumers, including:

```text
tracking-allocation completeness
audience/status tracking coverage
invoice-adjustment consumption
```

Do not change raw package/history readers.

### Migration D — closure compatibility overlay

Add:

```text
order_has_open_child_exceptions_v3(uuid)
recompute_order_status_v2(uuid)
versioned active closure callers proven by the call-graph audit
```

Do not modify the Mini Build v2 blocker, guard or child authorities.

### Application patch

Limit the first patch to:

```text
internal replacement final-acceptance action and page
original-order replacement tracking allocation panel/action
active audience/status caller versioning
legacy child operations read compatibility
removal of duplicate replacement invoice layout component
tests and implementation documentation
```

Any additional file requires an amended impact map.

## 24. Required database regressions

All write simulations run in transactions and end with `ROLLBACK` unless validating an isolated applied migration.

### 24.1 One of four replaced

```text
invoice qty 4
source allocation qty 4
receipt 3 clean + 1 missing
successor qty 1
```

Assert:

```text
raw qty = 5
effective qty = 4
effective value = original value
source receipt/evidence unchanged
no child order
no new supplier invoice
```

### 24.2 Two of four replaced

Assert exact partial transfer and effective total 4.

### 24.3 One route quantity greater than one

One remedy quantity 3 creates one successor allocation quantity 3 and preserves exact line value.

### 24.4 Several line items on one replacement tracking reference

At least two supplier-invoice lines and two route rows share one successor tracking submission. Assert exact per-line provenance and all-or-nothing creation.

### 24.5 Several original supplier invoices on the same order

Routes may share a successor tracking submission, but each successor allocation retains its own exact original supplier-invoice line. No value crosses invoices.

### 24.6 Penny apportionment

Use a partial quantity and values producing rounding residuals. Assert exact component conservation and deterministic output.

### 24.7 Duplicate and concurrency rejection

Test duplicate acceptance, duplicate route allocation, competing child acceptance and competing tracking submissions.

### 24.8 Successor clean receipt

Assert route position becomes `fulfilled_clean`, v3 blocker clears that remedy and the original order can progress without changing the original invoice.

### 24.9 Successor affected receipt

Assert route remains open and the normal physical-review queue receives the successor affected facts. No false completion.

### 24.10 Customer review and hold non-regression

Assert the existing review/hold functions and fingerprints are unchanged and that successor clean quantity enters the same existing review path.

### 24.11 Shipment and customer-release non-regression

Assert only clean available quantity is shipped and released. The failed source quantity is never shipped/released, and the successor is never released twice.

### 24.12 Invoice-adjustment non-regression

Assert effective mutable consumption equals the original supplier-line basis, not raw historical attempt quantity.

### 24.13 Reconciliation non-regression

Assert original quantity and amount clear exactly as before and no second invoice value appears.

### 24.14 Refund, charged-not-invoiced and new-order routes

Assert those cases do not enter the same-order free-replacement authority.

### 24.15 Legacy child compatibility

Assert existing child records remain unchanged, shared operations load, normal charged-child invoice controls remain available, and no duplicate invoice form appears.

### 24.16 Security

Assert anonymous, wrong-tenant, inactive operator, wrong shipper and non-supervisor final acceptance fail closed.

## 25. Source and fingerprint regressions

Before and after implementation, fingerprint every Mini Build 1-4 protected authority listed in section 5.

They must remain unchanged.

Source tests must prove:

- new physical free replacements do not call child creation;
- legacy manual replacements still call the existing child acceptance function;
- no migration edits a deployed migration;
- raw history readers remain raw;
- current entitlement readers use the effective resolver;
- no new invoice, DVA OUT, AP or Sage purchase path is introduced;
- duplicate child invoice UI is removed;
- all UUID identities remain authoritative.

Run TypeScript checking, production build and authenticated browser tests for operator, supervisor and shipper roles.

## 26. Stop conditions

Implementation stops when:

- live schema or function fingerprints differ from the reviewed baseline;
- an existing constraint prevents truthful dispute resolution with child fields null;
- the exact source allocation/disposition/remedy identity cannot be proven;
- source quantity or value cannot be apportioned deterministically;
- a current raw allocation consumer cannot be classified as history or entitlement;
- the closure call graph is incomplete;
- an existing trigger regresses the original order after same-order fulfilment;
- any Mini Build 1-4 definition would need modification;
- a successor clean receipt cannot be proven from existing exact physical facts;
- multi-line atomicity cannot be guaranteed;
- legacy child behaviour changes;
- quantity or value differs before and after effective transfer.

The builder reports the exact mismatch and obtains an amended governing decision. No quantity, value, status or route may be guessed.

## 27. Non-goals

This addendum does not create or change:

- Mini Builds 1-4;
- supplier invoice OCR or approval;
- a new receipt workflow;
- a new customer-review or hold workflow;
- a new shipment workflow;
- a new customer-sales release workflow;
- a new refund workflow;
- supplier credit or customer settlement;
- DVA/card matching;
- VAT or Sage posting;
- supplier AP or shipping AP;
- a paid repurchase workflow;
- a replacement-only invoice form;
- a replacement child for new free physical cases;
- automatic deletion or conversion of legacy child records.

## 28. Final acceptance criteria

The build is accepted only when:

```text
new free physical replacements stay on the original order;
replacement_child_order_id remains null for those new routes;
failed physical history remains immutable;
partial and multi-line replacement quantities are supported;
raw history may show additional attempts;
effective current quantity remains exactly the authoritative invoiced quantity;
effective current value remains exactly the authoritative original value;
no second supplier invoice or supplier charge is created;
original reconciliation remains quantity-and-amount correct;
existing customer review, holds, shipment and release work unchanged;
Mini Builds 1-4 fingerprints remain unchanged;
fulfilled same-order routes clear through the additive v3 closure overlay;
legacy replacement children remain supported;
the duplicate replacement invoice workaround is removed;
all security, concurrency, quantity, value and regression gates pass.
```

## 29. Locked implementation instruction

The approved implementation boundary is exactly:

```text
one same-order replacement sidecar
+ one effective quantity/value resolver
+ one explicit free-replacement final-acceptance authority
+ one atomic multi-line successor-allocation authority
+ narrow versioned current-position adapters
+ one additive closure compatibility overlay
+ legacy child operations compatibility
+ regression and fingerprint protection
```

A builder, including Codex, must not broaden this into a redesign of Mini Builds 1-4 or any downstream operational lane.