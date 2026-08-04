# Hybrid Physical Receipt Same-Order Free Replacement Routing Addendum v1.1

**Status:** governing correction to v1

**Effective date:** 3 August 2026

This correction must be read with `HYBRID_PHYSICAL_RECEIPT_SAME_ORDER_FREE_REPLACEMENT_ROUTING_ADDENDUM_v1.md`. Where this correction is more specific, it controls.

## 1. Absolute Mini Build freeze

“Mini Builds 1–4 remain untouched” means exactly:

- do not alter their tables;
- do not alter their columns or constraints;
- do not alter their functions;
- do not alter their views;
- do not alter their triggers or trigger bindings;
- do not alter their grants, owners, RLS policies or security attributes;
- do not alter their status families or lifecycle rules;
- do not alter customer review, held-item, shipment, customer-release, reconciliation or remedy behaviour;
- do not replace their authorities with edited copies under the same name;
- do not add a bypass inside their guards.

The same-order solution may read their existing outputs and exact provenance. It may not change how Mini Builds 1–4 work.

## 2. No new child orders

For every new free physical replacement governed by this addendum:

```text
replacement_child_order_id = null
resolved_via_child_order_id = null
no replacement_child order is inserted
no replacement child invoice route is used
```

Existing child-order functions and rows remain installed only for historical and legacy records. They are not part of the new same-order replacement route.

## 3. Correction to the v1 closure prescription

The v1 document over-prescribed the following objects:

```text
order_has_open_child_exceptions_v3(uuid)
recompute_order_status_v2(uuid)
```

Those names and that exact implementation are withdrawn from the approved build specification.

The repository proves only these facts:

1. the current delivery-allocation action counts raw historical allocations;
2. the current active status recompute calls the existing child/physical-remedy blocker;
3. the existing blocker treats an unresolved physical remedy as open;
4. the existing Build 4 completion guard is child-specific.

Those facts prove that closure must be checked carefully. They do not prove that a new child-named blocker or a replacement recompute function is the correct implementation.

No builder may add such an overlay merely because it appears convenient.

## 4. Correct locked solution boundary

The confirmed implementation scope is:

```text
original order remains the operational order;
original supplier invoice quantity and amount remain unchanged;
failed source allocation remains immutable history;
exact failed quantity and value are superseded in the current effective position;
successor tracking allocation is created on the same order and same supplier-invoice line;
effective quantity remains the original invoiced quantity;
effective amount remains the original invoiced amount;
customer review and held-item handling continue unchanged;
shipment and customer release continue unchanged;
Mini Builds 1–4 remain completely untouched;
no new child order is created.
```

## 5. Closure verification is a mandatory preflight, not a guessed build

Before implementing any closure adapter, produce an exact call graph from the installed repository and live database for:

```text
recompute_order_status(uuid)
order_has_open_child_exceptions(uuid)
order_has_open_child_exceptions_v2(uuid)
mark_order_accounting_release_ready(...)
VAT/accounting/final-closure authorities
tracking, receipt, customer-review, shipment and release triggers that can change order status
```

Then prove one of the following:

### Outcome A — existing downstream flow already completes correctly

If the original order progresses correctly after the successor allocation is received, reviewed, shipped and released, add no closure adapter.

### Outcome B — one exact active gate remains blocked

If an exact active authority remains blocked solely because it reads the old unresolved physical-remedy row, stop implementation and document:

- the exact function or trigger;
- the exact input rows;
- the exact incorrect result;
- the exact correct same-order result;
- every caller and downstream consumer.

Only then may a separate, narrowly approved same-order completion adapter be specified.

That future adapter must:

- be outside Mini Builds 1–4;
- contain no child-order routing for new cases;
- not edit or bypass an existing Mini Build guard;
- not change any Mini Build object;
- apply only to an exact, fulfilled same-order replacement route;
- preserve every legacy child and non-replacement condition;
- be approved before implementation.

## 6. Supersession remains the current confirmed technical fix

The current confirmed technical gap is the allocation total:

```text
raw historical source quantity
+ successor quantity
```

must not be treated as current commercial entitlement.

The required effective calculation remains:

```text
effective source quantity
= original source quantity - exact superseded quantity

effective line quantity
= effective source quantity + successor quantity + other unsuperseded allocations
```

For quantity 4 with one failed unit and one successor:

```text
source raw quantity = 4
superseded source quantity = 1
source effective quantity = 3
successor effective quantity = 1
line effective quantity = 4
```

The original amount and all transferred value components must reconcile identically.

## 7. Multi-item replacements

The same-order route must support:

- one line with replacement quantity greater than one;
- several affected supplier-invoice lines;
- several supplier invoices belonging to the same original order;
- one replacement tracking reference carrying several exact successor allocations;
- partial failure within an original allocation.

Supersession is quantity-scoped and value-scoped. It must never supersede an entire allocation when only part failed.

Each successor allocation retains its own exact:

```text
order_id
supplier_invoice_line_id
source_tracking_line_allocation_id
physical remedy identity
replacement quantity
transferred value
tracking submission
```

## 8. Required regressions

Before merge, prove:

1. Mini Builds 1–4 fingerprints are unchanged;
2. no Mini Build schema, function, trigger, grant, RLS or behaviour changed;
3. no new replacement child is created;
4. quantity 4 remains effective quantity 4 after one or more retries;
5. original amount remains unchanged;
6. multi-unit and multi-line replacement allocations work atomically;
7. customer review and held-item paths behave exactly as before;
8. shipment and customer release behave exactly as before;
9. raw audit history retains every physical attempt;
10. no unproven closure adapter is installed.

## 9. Final corrected instruction

Implement only the same-order allocation supersession and successor-tracking path that is proven necessary.

Do not touch Mini Builds 1–4.

Do not create new replacement child orders.

Do not add a child-blocker v3 or replacement recompute function unless a later, separately approved, exact closure proof requires a narrowly specified external adapter.