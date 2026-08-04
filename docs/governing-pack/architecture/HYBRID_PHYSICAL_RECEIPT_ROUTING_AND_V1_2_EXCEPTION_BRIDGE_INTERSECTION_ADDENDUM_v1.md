# Hybrid Physical Receipt Routing and v1.2 Exception Bridge Intersection Addendum v1

Status: Locked integration, ownership and non-interference specification  
Date: 4 August 2026

This addendum must be read with:

- `HYBRID_PHYSICAL_RECEIPT_EXACT_ROUTING_AND_SHIPMENT_CONTINUATION_CORRECTION_ADDENDUM_v1.md`;
- `HYBRID_PHYSICAL_RECEIPT_IMPLEMENTATION_ALIGNMENT_ADDENDUM_v1_2.md`;
- `HYBRID_PHYSICAL_RECEIPT_QUANTITY_FULFILMENT_AND_REMEDY_CONTROL_ADDENDUM_v1.md`;
- the current customer-review, customer-hold, shipment, refund and replacement authorities on `main`.

Its purpose is to define the exact intersection between the routing correction and the locked v1.2 physical-receipt-to-exception bridge so that either build can be implemented without silently changing the other.

## 1. Separation of responsibility

The v1.2 exception-bridge addendum owns the affected-quantity remedy lane:

```text
exact affected receipt quantity
→ importer proposal
→ supervisor decision
→ exact commercial value
→ refund dispute partition or one-line replacement dispute
→ replacement/refund operational path
```

The routing addendum owns continuation and shipment eligibility:

```text
originally clean quantity
or supervisor-released quantity
→ existing customer review
→ exact hold treatment
→ exact shipment-ready quantity
→ shipment membership
```

The routing build does not create, partition, value, accept or close refund/replacement disputes. The v1.2 build does not determine customer-review timing or shipment-ready quantity.

## 2. Exact handoff event

The handoff is the final committed physical-review and remedy-allocation state.

The v1.2 bridge writes and owns:

- `physical_receipt_reviews.status`;
- `physical_receipt_reviews.supervisor_decided_at`;
- `physical_receipt_reviews.linked_dispute_id` compatibility link;
- `physical_receipt_review_dispute_links`;
- `physical_exception_remedy_allocations` route, quantity, value and lifecycle state;
- exact refund/replacement dispute lines and headers.

After that state is complete, the routing authority may read it as follows:

```text
review status rejected
→ release the exact affected quantity into customer review

review status closed_no_action
→ release only exact approved no_action quantity into customer review

approved refund allocation
→ remain diverted

approved replacement allocation
→ remain diverted

approved investigation/hold route
→ remain diverted
```

The routing build must not infer a remedy from a dispute header, UI label or compatibility primary link. It must read the exact review and remedy-allocation records created by the v1.2 authority.

## 3. Shared objects and ownership matrix

### 3.1 `shipper_package_receipts`

- v1.2 ownership: read source receipt identity and provenance.
- routing ownership: read finalised receipt and add a narrow post-finalisation materialisation trigger.
- prohibited routing write: no receipt status, evidence, correction or disposition mutation.

### 3.2 `shipper_package_receipt_line_dispositions`

- v1.2 ownership: source evidence for affected quantity and issue type.
- routing ownership: read exact clean/affected quantities.
- prohibited routing write: no insert, update or delete.

### 3.3 `physical_receipt_reviews`

- v1.2 ownership: all importer/supervisor workflow writes, terminal status, decision note, liability and dispute linkage.
- routing ownership: read terminal status and `supervisor_decided_at`; optionally attach a deferred post-decision materialisation trigger.
- prohibited routing write: no status, liability, linked dispute, decision-note or sequence change.

### 3.4 `physical_exception_remedy_allocations`

- v1.2 ownership: proposal, approval, exact quantity, commercial value, dispute linkage and lifecycle progression.
- routing ownership: read exact approved route and quantity when deriving released versus diverted quantity.
- prohibited routing write: no remedy status, quantity, value, dispute-line link or lifecycle mutation.

### 3.5 Disputes and dispute lines

- v1.2 ownership: grouping, partitioning, amount, desired outcome, one-line replacement shape and compatibility links.
- routing ownership: none beyond optional diagnostic provenance.
- prohibited routing write: all dispute and dispute-line writes.

### 3.6 Customer-review tables

- v1.2 ownership: none.
- routing ownership: candidate derivation, exact membership timing, materialisation and completion state used by shipment.

### 3.7 Customer-hold tables

- v1.2 ownership: none.
- routing ownership: read existing exact hold memberships and preserve existing hold write authorities unchanged.

### 3.8 Shipment tables and RPCs

- v1.2 ownership: none.
- routing ownership: exact candidate quantity, exact shipment creation quantity and package-routing display.

### 3.9 Replacement child and return infrastructure

The following remain exclusively owned by v1.2 and established replacement authorities:

- `staff_accept_replacement_outcome_v1`;
- `create_replacement_child_order_v2`;
- replacement child parent linkage;
- replacement return adapters;
- `dispute_return_tracking_submissions`;
- `shipper_return_task_confirmations`;
- replacement child invoice, tracking and reconciliation routes.

The routing build must not replace, wrap or call these authorities.

## 4. Protected v1.2 authorities

Before applying any routing migration, capture exact definitions, owners, ACLs and trigger bindings for at least:

```text
staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text)
staff_decide_physical_receipt_review_v2(...current exact signature...)
physical_remedy_allocation_guard_v2()
physical_remedy_sequence_guard_v1()
physical_receipt_review_guard_v1()
staff_accept_replacement_outcome_v1(uuid,uuid,text)
create_replacement_child_order_v2(uuid,uuid,uuid,text)
```

The routing migration must fail before any write if a captured authority differs from the approved current-main baseline.

After the routing migration, the exact definitions, owners, ACLs and trigger bindings must remain unchanged.

## 5. Safe supervisor integration

The routing build must not rewrite either supervisor-decision RPC.

Customer-review materialisation after `rejected` or `closed_no_action` must use a separate deferred post-decision mechanism that runs only after the v1.2 transaction has completed all review, remedy, dispute and link writes.

The integration mechanism must:

- execute after the final state is internally consistent;
- call only the existing customer-review materialiser;
- do nothing for refund, replacement or investigation outcomes;
- be idempotent;
- fail closed if exact released quantity cannot be proven;
- never alter the supervisor transaction's chosen dispute, value, line shape or remedy lifecycle.

A normal immediate row trigger that runs before the v1.2 sequence is complete is prohibited.

## 6. Routing derivation from v1.2 state

For each allocation, the routing v2 authority must distinguish:

```text
source clean quantity
source affected quantity
approved no_action quantity
approved refund quantity
approved replacement quantity
approved investigation/hold quantity
```

The following balance must hold:

```text
released_to_clean_qty
+ remaining_diverted_affected_qty
= source_affected_qty
```

Where:

```text
released_to_clean_qty =
  source affected quantity when the review is rejected
  + exact approved no_action quantity when closed_no_action

remaining_diverted_affected_qty =
  approved refund quantity
  + approved replacement quantity
  + approved investigation/hold quantity
  + any unresolved or unproven remainder
```

Any overlap, over-allocation, missing exact route or inconsistent lifecycle must make the routing position invalid and shipment quantity zero.

## 7. End-to-end journey

```text
Shipper finalises mixed receipt
        |
        +-- Product B clean qty 1
        |       |
        |       +-- routing addendum owns
        |               → customer-review membership
        |               → exact 24-hour timing
        |               → hold or completion
        |               → shipment-ready qty 1
        |
        +-- Product A damaged qty 1
                |
                +-- v1.2 exception bridge owns
                        → importer proposal
                        → supervisor approves replacement
                        → exact commercial value
                        → one-line replacement dispute
                        → replacement acceptance/child path
                |
                +-- routing addendum reads final outcome only
                        → replacement qty remains diverted
                        → shipment-ready qty 0
```

If the supervisor instead rejects Product A's affected classification:

```text
v1.2 owns and commits the rejected review state
        ↓
routing deferred hook materialises Product A into customer review
        ↓
Product A receives its own review period
        ↓
only after completion and no hold may it enter shipment
```

## 8. Non-interference regressions

The routing regression must prove:

1. v1.2 supervisor bridge fingerprints are identical before and after.
2. Physical guard OIDs, owners, ACLs and trigger bindings are unchanged.
3. Refund grouping and supplier-invoice partitioning remain unchanged.
4. One physical replacement allocation still creates exactly one replacement dispute line.
5. Customer commercial value on remedy, dispute and replacement child remains unchanged.
6. `staff_accept_replacement_outcome_v1` still accepts the proven one-line shape.
7. Replacement child creation, parent linkage and terminal progression remain unchanged.
8. Replacement return records and shipper confirmations remain unchanged.
9. Routing reads replacement/refund allocations but never mutates them.
10. Replacement quantity produces shipment-ready quantity zero.
11. Originally clean quantity continues independently through customer review and shipment.
12. A rejected/no-action quantity is materialised only after the final supervisor state is complete.
13. A failed or rolled-back supervisor transaction creates no customer-review membership.
14. No routing trigger fires for replacement/refund outcomes.

The v1.2 regression suite must also be run unchanged after the routing build. Any failure blocks merge.

## 9. Build order

The routing implementation must proceed from current `main`, where v1.2 and its restoration commits are already present.

Required order:

1. Create a fresh routing implementation branch from current `main`.
2. Capture v1.2 protected fingerprints and bindings.
3. Implement private routing reads and customer-review timing first.
4. Add the deferred supervisor handoff without changing the supervisor RPCs.
5. Implement shipment candidate and creation corrections.
6. Run routing regressions.
7. Run the complete unchanged v1.2 regression suite.
8. Compare protected definitions and ACLs before and after.
9. Merge only when both suites pass and the diff contains no replacement/refund authority changes.

## 10. Final ownership rule

```text
The v1.2 addendum decides what the affected quantity becomes and builds its remedy path.
The routing addendum decides whether exact quantity is awaiting review, diverted or shipment-ready.
```

Neither build may silently assume ownership of the other's writes.
