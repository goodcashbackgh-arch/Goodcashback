# Hybrid Physical Receipt Routing, Exception Bridge and Same-Order Outcome Intersection Addendum v1

**Status:** governing integration and non-interference specification  
**Effective date:** 4 August 2026

This addendum must be read with:

- `HYBRID_PHYSICAL_RECEIPT_EXACT_ROUTING_AND_SHIPMENT_CONTINUATION_CORRECTION_ADDENDUM_v1.md`;
- `HYBRID_PHYSICAL_RECEIPT_EXACT_ROUTING_AND_SHIPMENT_CONTINUATION_CORRECTION_ADDENDUM_v1_1.md`;
- `HYBRID_PHYSICAL_RECEIPT_IMPLEMENTATION_ALIGNMENT_ADDENDUM_v1_2.md`;
- `HYBRID_PHYSICAL_RECEIPT_SAME_ORDER_FREE_REPLACEMENT_ROUTING_ADDENDUM_v1.md`;
- `HYBRID_PHYSICAL_RECEIPT_SAME_ORDER_FREE_REPLACEMENT_ROUTING_ADDENDUM_v1_1.md`;
- `HYBRID_PHYSICAL_RECEIPT_OUTCOME_LANE_GROUPING_ADDENDUM_v1.md`.

Where this document is more specific about the integration boundary, it controls.

## 1. Governing model

New governed free physical replacements do not use replacement child orders.

```text
original order remains the operational order;
original supplier-invoice line remains authoritative;
failed source allocation remains immutable history;
exact failed quantity and value are superseded in the effective position;
same-order successor tracking allocation carries the replacement attempt;
no new child order or child invoice route is used.
```

Child-order terminology, status, lifecycle, invoice, tracking and blocker logic are not part of this routing specification.

Legacy child-related records and functions may remain installed for historical cases, but routing must not read them as current truth and must not alter them.

## 2. Separation of responsibility

### Physical-receipt exception bridge owns

- exact affected quantity from the final receipt;
- importer proposal and supervisor decision;
- exact approved remedy allocation;
- exact customer commercial value;
- refund dispute partitioning;
- exact replacement dispute/remedy shape;
- physical review and dispute compatibility links;
- original-item return or collection records where applicable.

### Outcome-lane and same-order replacement build owns

- separate refund and replacement lanes;
- grouped operator and supervisor actions over exact lane items;
- refund continuation through existing refund and settlement authorities;
- same-order replacement route creation;
- quantity/value supersession of the failed source allocation;
- successor tracking allocation on the original order and supplier-invoice line.

### Exact routing build owns

- originally clean quantity entering customer review;
- `rejected` quantity entering customer review;
- approved `no_action` quantity entering customer review;
- failed refund/replacement/investigation source quantity remaining diverted;
- per-allocation review timing;
- exact hold subtraction;
- exact shipment-ready quantity;
- normal routing of a later same-order successor allocation after its own receipt finalises.

## 3. Exact handoffs

### 3.1 Supervisor outcome handoff

The routing build reads the final committed physical review and remedy-allocation state:

```text
review status rejected
→ exact affected source quantity becomes customer-review eligible

review status closed_no_action
→ exact approved no_action quantity becomes customer-review eligible

approved refund allocation
→ source quantity remains in refund lane and outside shipment

approved replacement allocation
→ failed source quantity remains diverted
→ no source customer-review membership
→ no source shipment membership

approved investigation or unresolved state
→ source quantity remains diverted
```

The routing build must not infer the remedy from a dispute header, compatibility link, UI label or later evidence record.

### 3.2 Same-order replacement handoff

The replacement build provides an exact same-order route and, later, an exact successor tracking allocation.

The routing build reads:

```text
same-order route id
physical remedy allocation id
source tracking-line allocation id
successor tracking-line allocation id
order id
supplier-invoice line id
transferred quantity
transferred value
route status
```

Required behavior:

```text
route unresolved or no successor allocation
→ failed source quantity remains diverted

valid successor tracking allocation exists
→ successor is treated as a new physical attempt
→ successor must receive its own final receipt
→ successor clean quantity enters normal customer review
→ successor affected quantity follows the normal exception bridge
```

Acceptance of replacement alone does not create customer-review or shipment eligibility.

## 4. Shared-object access

### Receipt and disposition records

- Exception bridge: reads exact affected source and issue type.
- Routing: reads exact clean and affected quantity.
- Same-order replacement: retains source identity for supersession and successor provenance.
- No build may rewrite final receipt facts or dispositions.

### Physical reviews and remedy allocations

- Exception bridge owns all workflow writes, route, quantity, value and dispute linkage.
- Routing reads exact final state only.
- Same-order outcome authorities consume exact approved replacement or refund items.
- Routing must not mutate review or remedy records.

### Refund records

- Existing refund, evidence, settlement-credit, accounting, VAT and reconciliation authorities remain authoritative.
- Routing has read-only visibility sufficient to prove refund quantity remains outside shipment.

### Same-order replacement routes

- Same-order replacement authorities own route, supersession, transferred quantity/value and successor-allocation writes.
- Routing reads the effective result and successor identity only.
- Routing must not reproduce or mutate supersession calculations.

### Customer review, hold and shipment

- Routing owns the exact corrections specified in the routing addenda.
- Successor allocations use these existing authorities without a replacement-specific parallel workflow.

## 5. Trigger and materialisation specification

### Receipt finalisation

Use one narrow trigger:

```text
AFTER a v2 receipt changes to finalised
→ call the existing customer-review materialiser
```

This applies to any exact allocation, including a same-order replacement successor.

For a successor allocation, this trigger is the only automatic entry into customer review. Replacement acceptance or route creation must not materialise customer review.

### Supervisor release

Use a separate deferred post-decision mechanism after the full physical review/remedy/dispute transaction is consistent.

It calls the existing materialiser only for:

```text
rejected
closed_no_action with exact approved no_action quantity
```

It does nothing for refund, replacement or investigation outcomes.

The supervisor RPCs must not be rewritten for this routing build.

## 6. Effective quantity and shipment boundary

Routing and shipment must use the approved effective position, not raw historical allocation totals.

Example:

```text
original allocation quantity = 4
failed/superseded source quantity = 1
effective source quantity = 3
successor allocation quantity = 1
effective line quantity = 4
```

Shipment conditions for any exact allocation are:

```text
position is valid;
quantity is effective clean quantity on that allocation;
that allocation's customer review is complete;
active holds do not consume it;
it has not already been shipped;
it is not superseded source quantity.
```

The failed source replacement quantity can never satisfy these conditions. A later successor allocation may satisfy them after its own receipt and review.

## 7. End-to-end example

```text
Package contains:
Product B clean qty 1
Product A damaged qty 1
```

Product B:

```text
final receipt clean
→ customer review
→ hold or review completion
→ shipment-ready when valid
```

Product A approved refund:

```text
exception bridge creates exact refund item
→ refund lane
→ existing refund/evidence/settlement path
→ no customer review or shipment
```

Product A approved free replacement:

```text
exception bridge creates exact replacement item
→ replacement lane
→ same-order route
→ source qty/value superseded in effective position
→ successor tracking allocation on original order and supplier line
→ successor receipt finalises
→ successor clean qty enters normal customer review
→ hold or review completion
→ shipment-ready when valid
```

Product A rejected by supervisor:

```text
final rejected review state
→ deferred routing materialisation
→ original affected quantity enters customer review
```

## 8. Prohibited implementation

The routing implementation must not depend on or introduce:

```text
replacement child order identity;
child-order status;
child invoice upload;
child tracking allocation;
child lifecycle completion;
child blocker;
child-specific order recompute;
parallel replacement customer-review workflow.
```

It must also not:

- mutate refund settlement records;
- mutate same-order route or supersession records;
- infer successor readiness from lane or dispute status;
- release the failed source allocation because a successor exists.

## 9. Mandatory non-interference regressions

Prove:

1. exception-bridge definitions, guards, owners, ACLs and bindings are unchanged;
2. refund grouping, values and settlement path remain unchanged;
3. same-order route, supersession and successor-allocation authorities remain unchanged;
4. no new child order or child dependency is created;
5. originally clean quantity continues independently;
6. rejected and approved no-action quantity materialises exactly once;
7. refund source quantity remains outside review and shipment;
8. replacement failed source quantity remains outside source review and shipment;
9. replacement acceptance alone creates no customer-review membership;
10. successor allocation enters customer review only after its own receipt finalises;
11. superseded source quantity never enters shipment;
12. source plus successor effective quantity and value equal original entitlement;
13. successor review, hold and shipment behavior matches an ordinary allocation;
14. a failed or rolled-back transaction creates no partial membership or route effect;
15. Mini Builds 1–4 remain unchanged.

## 10. Build order

1. Start from a fresh branch containing the approved exception-bridge and same-order outcome work.
2. Capture exact protected definitions, ACLs, owners and trigger bindings.
3. Identify and consume the approved effective-position and successor-allocation reads.
4. Implement exact routing position and per-membership review timing.
5. Add receipt-finalisation materialisation.
6. Add the deferred rejected/no-action materialisation hook.
7. Correct shipment candidates and shipment creation.
8. Run routing, refund-lane, replacement-lane and same-order regressions unchanged.
9. Verify no protected authority changed.

## 11. Final ownership rule

```text
The exception bridge decides the exact approved remedy.
The refund lane continues through the existing refund core path.
The same-order replacement build supersedes the failed source and creates the successor allocation.
The routing build routes clean or released source quantity and later routes the successor allocation through normal fulfilment.
No new governed replacement uses a child order.
```
