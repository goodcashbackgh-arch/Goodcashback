# Hybrid Physical Receipt Routing and v1.2 Exception Bridge Intersection Addendum v1

Status: Corrected locked integration and non-interference specification  
Date: 4 August 2026

This addendum must be read with:

- `HYBRID_PHYSICAL_RECEIPT_EXACT_ROUTING_AND_SHIPMENT_CONTINUATION_CORRECTION_ADDENDUM_v1.md`;
- `HYBRID_PHYSICAL_RECEIPT_IMPLEMENTATION_ALIGNMENT_ADDENDUM_v1_2.md`;
- `HYBRID_PHYSICAL_RECEIPT_QUANTITY_FULFILMENT_AND_REMEDY_CONTROL_ADDENDUM_v1.md`;
- the current customer-review, customer-hold, shipment, refund and replacement authorities on `main`.

## 1. Correction to the earlier intersection statement

The earlier statement that v1.2 owns a replacement-child lifecycle was wrong and is superseded.

The v1.2 addendum does not introduce or govern a child lifecycle. It repairs the physical-receipt-to-exception bridge and preserves the already established downstream refund and replacement authorities unchanged.

Its governed scope is:

```text
exact affected receipt quantity
→ importer proposal
→ supervisor decision
→ exact customer commercial value
→ downstream-compatible refund dispute partition
   or one-line replacement dispute shape
→ optional original-item return/collection action where applicable
```

For replacement, v1.2 stops at producing the exact dispute/remedy shape required by the existing replacement acceptance and child-creation authorities. It does not create a new parent/child lifecycle, terminal progression model or child-status authority.

## 2. Correct separation of responsibility

### v1.2 exception-bridge addendum owns

- exact affected-quantity bridge from receipt review into existing disputes;
- supervisor-approved remedy allocation shape;
- deterministic customer commercial value on the physical remedy and dispute;
- refund partitioning by downstream-compatible supplier-invoice and issue grouping;
- one physical replacement allocation per replacement dispute line;
- compatibility links between the physical review and its disputes;
- additive original-item return/collection adapters for damaged or wrong replacement items where the retailer requires return;
- preservation of all existing downstream replacement, refund, settlement and accounting authorities.

### Routing addendum owns

- originally clean quantity continuing independently;
- supervisor-released `rejected` quantity entering customer review;
- approved `no_action` quantity entering customer review;
- refund, replacement and investigation quantity remaining diverted;
- exact customer-review timing and memberships;
- exact customer holds;
- exact shipment eligibility and shipment quantity;
- package-routing and immutable receipt displays.

### Existing downstream replacement authorities own

These are outside both addenda and remain protected:

- `staff_accept_replacement_outcome_v1`;
- `create_replacement_child_order_v2`;
- whatever existing parent/child linkage those authorities already perform;
- child invoice, tracking and reconciliation through existing order routes.

Neither addendum is authority to add a child lifecycle or terminal lifecycle that does not already exist.

## 3. Exact intersection and handoff

The intersection is the final committed physical-review and remedy-allocation state.

The v1.2 bridge writes:

- `physical_receipt_reviews.status` and supervisor decision provenance;
- exact `physical_exception_remedy_allocations` route, quantity and commercial value;
- exact refund/replacement dispute headers and lines;
- `physical_receipt_review_dispute_links` and the compatibility primary dispute link.

The routing authority then reads only the exact final outcome:

```text
review status rejected
→ release exact affected quantity into customer review

review status closed_no_action
→ release only exact approved no_action quantity into customer review

approved refund allocation
→ remain diverted

approved replacement allocation
→ remain diverted

approved investigation or unresolved quantity
→ remain diverted
```

The routing build must not infer a route from a child order, dispute status, UI label or later replacement activity. Its handoff source is the exact physical review and remedy-allocation state.

## 4. Shared objects and permitted access

### `shipper_package_receipts`

- v1.2: reads receipt identity and provenance.
- routing: reads finalised receipt and may attach a narrow finalisation materialisation trigger.
- routing must not rewrite receipt facts.

### `shipper_package_receipt_line_dispositions`

- v1.2: reads affected issue type and exact source.
- routing: reads exact clean and affected quantities.
- neither build may mutate stored dispositions.

### `physical_receipt_reviews`

- v1.2: owns importer/supervisor workflow writes, final decision and dispute linkage.
- routing: reads final status and `supervisor_decided_at`; may attach only a deferred post-decision materialisation trigger.
- routing must not alter status, liability, notes, linked dispute or decision sequence.

### `physical_exception_remedy_allocations`

- v1.2: owns proposal, approval, exact route, quantity, commercial value and dispute-line linkage.
- routing: read-only for deriving released versus diverted quantity.
- routing must not change remedy status, quantity, value or links.

### Disputes and dispute lines

- v1.2: owns bridge-created grouping, values and line shape.
- routing: no write ownership.

### Customer-review, hold and shipment authorities

- routing owns the corrections described in its governing addendum.
- v1.2 has no write ownership over those routes.

## 5. Protected authorities

The routing build must capture and preserve the exact current definitions, owners, ACLs and trigger bindings of:

```text
staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text)
staff_decide_physical_receipt_review_v2(...current exact signature...)
physical_remedy_allocation_guard_v2()
physical_remedy_sequence_guard_v1()
physical_receipt_review_guard_v1()
staff_accept_replacement_outcome_v1(uuid,uuid,text)
create_replacement_child_order_v2(uuid,uuid,uuid,text)
```

The last two are protected existing downstream authorities, not v1.2-owned lifecycle functions.

The routing migration must fail before writing if the approved current-main baseline differs.

## 6. Safe supervisor integration

The routing build must not rewrite either supervisor-decision RPC.

Materialisation after `rejected` or `closed_no_action` must use a deferred post-decision mechanism that runs only after the v1.2 review, remedy, dispute and link writes are complete.

It must:

- call only the existing customer-review materialiser;
- do nothing for refund, replacement or investigation outcomes;
- be idempotent;
- create no membership after a failed or rolled-back supervisor transaction;
- never change dispute partitioning, commercial value, replacement line shape or remedy state.

## 7. Correct journey

```text
Shipper finalises mixed receipt
        |
        +-- Product B clean qty 1
        |       → routing addendum
        |       → customer review
        |       → hold or completion
        |       → exact shipment eligibility
        |
        +-- Product A damaged qty 1
                → v1.2 bridge
                → importer proposal
                → supervisor approves replacement
                → exact commercial value
                → one-line replacement dispute/remedy shape
                → remains diverted under routing
                → existing replacement acceptance/child-creation authorities may act later
```

No child lifecycle is created or governed by this intersection.

If the supervisor rejects the damage classification:

```text
v1.2 commits rejected review state
        ↓
routing deferred hook materialises exact quantity into customer review
        ↓
normal review/hold/shipment rules apply
```

## 8. Non-interference regressions

The routing regression must prove:

1. v1.2 supervisor bridge definitions and bindings are unchanged.
2. Physical guards are unchanged.
3. Refund grouping and supplier-invoice partitioning remain unchanged.
4. One physical replacement allocation still produces exactly one replacement dispute line.
5. Customer commercial value remains unchanged.
6. Existing replacement acceptance and child-creation authorities remain byte-for-byte unchanged.
7. No new child lifecycle, parent terminal rule or child-status authority is introduced.
8. Replacement-return records and shipper confirmations remain unchanged.
9. Routing reads refund/replacement allocations but never mutates them.
10. Replacement quantity produces shipment-ready quantity zero.
11. Originally clean quantity continues independently.
12. Rejected/no-action quantity is materialised only after final supervisor state.
13. A rolled-back supervisor decision creates no review membership.
14. No routing trigger fires for refund or replacement outcomes.

The unchanged v1.2 regression suite must pass after the routing build.

## 9. Build order

1. Start from current `main` containing the locked v1.2 bridge repair.
2. Capture protected definitions, ACLs and trigger bindings.
3. Implement private routing reads and customer-review timing.
4. Add the deferred supervisor handoff without changing supervisor RPCs.
5. Correct shipment candidate and creation authorities.
6. Run routing regressions.
7. Run the unchanged v1.2 regression suite.
8. Prove no downstream replacement authority or lifecycle rule was added or changed.

## 10. Final ownership rule

```text
v1.2 repairs the affected-quantity bridge into existing refund/replacement routes.
Routing decides whether exact quantity is awaiting review, diverted or shipment-ready.
Existing downstream authorities handle replacement acceptance and child creation.
No addendum here creates a child lifecycle.
```
