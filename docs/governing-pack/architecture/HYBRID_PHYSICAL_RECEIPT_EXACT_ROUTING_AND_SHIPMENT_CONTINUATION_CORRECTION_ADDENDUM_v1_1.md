# Hybrid Physical Receipt Exact Routing and Shipment Continuation Correction Addendum v1.1

**Status:** governing correction to v1  
**Effective date:** 4 August 2026

This correction must be read with:

- `HYBRID_PHYSICAL_RECEIPT_EXACT_ROUTING_AND_SHIPMENT_CONTINUATION_CORRECTION_ADDENDUM_v1.md`;
- `HYBRID_PHYSICAL_RECEIPT_IMPLEMENTATION_ALIGNMENT_ADDENDUM_v1_2.md`;
- `HYBRID_PHYSICAL_RECEIPT_SAME_ORDER_FREE_REPLACEMENT_ROUTING_ADDENDUM_v1.md`;
- `HYBRID_PHYSICAL_RECEIPT_SAME_ORDER_FREE_REPLACEMENT_ROUTING_ADDENDUM_v1_1.md`;
- `HYBRID_PHYSICAL_RECEIPT_OUTCOME_LANE_GROUPING_ADDENDUM_v1.md`.

Where this correction is more specific, it controls.

## 1. Absolute replacement-model correction

The routing build must not use a replacement child order, child invoice route, child lifecycle, child status or child blocker for any new governed free physical replacement.

For new free physical replacements:

```text
original order remains the operational order;
original supplier-invoice line remains authoritative;
failed source allocation remains immutable history;
exact failed quantity and value are superseded in the effective position;
same-order successor tracking allocation carries the replacement attempt;
no new child order is created.
```

Legacy child-related rows and functions may remain installed for historical records, but they are outside this routing build and must not be read as the source of current routing truth.

## 2. Correct meaning of diverted replacement quantity

The v1 phrase that replacement quantity “remains diverted” applies only to the failed source quantity and its approved replacement remedy.

It means:

```text
no failed source quantity is released into customer review;
no failed source quantity becomes shipment-ready;
no failed source quantity is inserted into shipment membership;
the approved replacement remedy remains outside the clean lane while its same-order route is unresolved.
```

It does not mean that the replacement can never progress.

Once a valid same-order successor tracking allocation exists, that successor allocation is a new physical attempt and enters the ordinary tracking, receipt, customer-review, hold and shipment pipeline under its own exact identity.

## 3. Exact technical handoff

The routing authority must distinguish three different things:

```text
1. failed source allocation;
2. approved physical replacement remedy / same-order route;
3. successor tracking allocation.
```

### 3.1 Failed source allocation

Source records:

- authoritative final receipt disposition;
- physical receipt review;
- approved replacement remedy allocation;
- same-order route source allocation identity.

Required result:

```text
source effective shipment quantity = 0 for the exact failed quantity;
source failed quantity remains diverted;
source receipt and evidence remain immutable;
source quantity/value are superseded only in the effective entitlement layer.
```

### 3.2 Same-order replacement route

Source records:

- exact approved physical replacement remedy allocation;
- exact same-order route row;
- route status;
- transferred quantity and value;
- source tracking allocation;
- original order and supplier-invoice line.

Required result:

```text
route unresolved or not allocated to successor tracking
→ failed quantity remains diverted
→ shipment-ready quantity remains zero
```

Routing must never infer completion from dispute status, lane status, notes or evidence alone.

### 3.3 Successor tracking allocation

Source records:

- same-order route successor allocation identity;
- new tracking submission;
- new tracking-line allocation;
- original order;
- original supplier-invoice line;
- exact transferred quantity and value.

Required result:

```text
successor allocation
→ normal receipt entry
→ exact clean/affected disposition
→ normal customer review
→ normal customer hold treatment
→ normal shipment eligibility
```

The successor is not released merely because the replacement was accepted. It must satisfy the same physical-receipt and customer-review conditions as any other allocation.

## 4. Correct routing matrix

```text
originally clean quantity on finalised receipt
→ customer review

review status rejected
→ exact affected source quantity becomes review-eligible

review status closed_no_action
→ exact approved no_action quantity becomes review-eligible

approved refund quantity
→ remains in refund lane
→ no customer-review or shipment release

approved replacement source quantity
→ remains diverted from source customer review and source shipment

valid same-order successor allocation
→ enters normal receipt/customer-review/hold/shipment routing under successor identity

approved investigation or unresolved quantity
→ remains diverted and shipment-ready quantity is zero
```

## 5. Required exact joins

All source-release decisions must be tied to the same:

```text
order_id
tracking_submission_id
tracking_line_allocation_id
receipt_id
receipt line disposition
physical_receipt_review_id
physical_remedy_allocation_id, when applicable
```

All successor decisions must be tied to the same:

```text
same-order replacement route id
source tracking-line allocation id
successor tracking-line allocation id
order_id
supplier_invoice_line_id
transferred quantity
transferred value
```

Cross-order, cross-line, cross-review, cross-remedy or dispute-header inference is prohibited.

## 6. Automatic materialisation hooks

### 6.1 Receipt-finalisation hook

The v1 requirement remains:

```text
AFTER a v2 receipt changes to finalised
→ call the existing customer-review materialiser
```

This applies independently to:

- originally clean quantity on an original allocation;
- clean quantity on a later same-order successor allocation.

No special replacement-specific customer-review workflow is authorised.

### 6.2 Supervisor-release hook

Materialisation after `reject` or `close_no_action` must use a separate deferred post-decision mechanism after the full review/remedy/dispute transaction is internally consistent.

It must:

- call only the existing customer-review materialiser;
- run only for exact released source quantity;
- do nothing for refund, replacement or investigation outcomes;
- be idempotent;
- create no membership after rollback;
- not rewrite the supervisor RPCs.

### 6.3 Same-order successor allocation

No supervisor-release hook creates customer-review membership for a replacement successor.

The successor enters customer review only through its own later finalised receipt and the ordinary receipt-finalisation hook.

## 7. Effective quantity and value boundary

The routing build must consume the approved same-order effective position rather than raw historical allocation totals.

For an original quantity of four with one failed unit and one successor:

```text
raw source allocation quantity = 4
superseded source quantity = 1
effective source quantity = 3
successor quantity = 1
effective line quantity = 4
```

The routing and shipment build must not ship the superseded source unit and must not treat source plus successor as five current units.

The same rule applies to value.

The routing build must read the same-order effective-position authority supplied by the replacement build. It must not independently reproduce or mutate supersession records.

## 8. Refund integration

Refund quantity never receives a successor tracking allocation.

It remains outside customer review and shipment and continues through the existing refund evidence, settlement-credit, accounting, VAT and reconciliation paths.

The routing build may read the exact approved refund quantity only to prove that it remains diverted. It must not write refund evidence, settlement or accounting records.

## 9. Shipment conditions

A row may enter shipment only when the exact allocation currently being shipped satisfies all of the following:

```text
position_valid_yn = true;
effective clean quantity exists on that allocation;
its own customer review is complete;
its own active hold quantity does not consume it;
it has not already been shipped;
it is not superseded source quantity.
```

For a same-order replacement, only the successor allocation can eventually satisfy these conditions. The failed source allocation cannot.

## 10. Prohibited dependencies

The routing implementation must contain no dependency on:

```text
replacement child order identity;
child-order status;
child invoice upload;
child tracking allocation;
child lifecycle completion;
child blocker or child-specific recompute result.
```

No new child-named function, view, column, trigger or routing status is authorised.

## 11. Mandatory regressions

Before merge, prove:

1. originally clean quantity still progresses independently;
2. rejected and approved no-action quantity enters customer review exactly once;
3. refund quantity remains outside customer review and shipment;
4. approved replacement source quantity remains outside source customer review and source shipment;
5. no successor customer-review membership exists before successor receipt finalisation;
6. successor clean quantity enters the ordinary customer-review path after its own receipt finalisation;
7. successor held quantity remains diverted;
8. successor completed-review unheld quantity becomes shipment-ready;
9. superseded source quantity never enters shipment;
10. source plus successor effective quantity and value equal the original entitlement;
11. no new child order, child link, child invoice route or child lifecycle dependency is created;
12. refund, replacement lane and same-order route authorities are unchanged;
13. Mini Builds 1–4 remain unchanged;
14. all writes roll back atomically on an invalid route or mismatched provenance.

## 12. Final corrected instruction

```text
Route original clean and supervisor-released quantity through the existing customer-review path.
Keep refund quantity in the refund path.
Keep failed replacement source quantity diverted and superseded.
Route only the same-order successor allocation through normal receipt, review, hold and shipment.
Never use a child replacement order for new governed replacements.
```
