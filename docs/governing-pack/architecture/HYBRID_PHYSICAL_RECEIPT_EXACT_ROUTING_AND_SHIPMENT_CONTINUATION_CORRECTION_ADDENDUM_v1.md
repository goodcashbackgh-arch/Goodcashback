# Hybrid Physical Receipt Exact Routing and Shipment Continuation Correction Addendum v1

Status: Governing correction and technical specification  
Date: 2 August 2026

This addendum supplements:

- `HYBRID_PHYSICAL_RECEIPT_QUANTITY_FULFILMENT_AND_REMEDY_CONTROL_ADDENDUM_v1.md`
- `HYBRID_PHYSICAL_RECEIPT_QUANTITY_FULFILMENT_AND_REMEDY_CONTROL_ADDENDUM_v1_1.md`
- the existing customer-review, customer-hold, shipment-batch, dispute, refund and replacement authorities

Where this addendum is more specific about mixed clean/affected routing, supervisor rejection, customer-review continuation or shipment quantity, this addendum controls.

All deployed migrations remain immutable. Implementation must be additive and fingerprint-guarded.

## 1. Confirmed database facts

Controlled package:

```text
order_id:               8c882f9d-aadc-4a6a-b50c-d013d1abffd7
order_ref:              SEED-REPL-0C7952EE44
tracking_submission_id: 96165f7d-afa7-4c26-a601-8bd6ee0f85b7
tracking_ref:           SEEDTRK-0C7952EE44
receipt_id:             570e1b73-8306-4203-ac06-f7a84e2de53e
review_id:              1987393f-47ba-4460-96f6-598e0e52792d
linked_dispute_id:      d7b32314-603e-49bf-83d1-1a01e2e4d29f
```

The latest receipt is a finalised v2 receipt with package compatibility status `received_damaged`.

Stored exact dispositions are correct:

```text
GHA Stress Product B
allocated 1
clean 1
affected 0

GHA Stress Product A
allocated 1
clean 0
damaged 1
note: Damaged - ripped
```

The existing exact quantity-position authority is also correct:

```text
Product B
physical_clean_qty       1
physical_exception_qty   0
review_available_qty     1
reviewed_qty              0
shipment_available_qty   0
position_valid_yn        true

Product A
physical_clean_qty       0
physical_exception_qty   1
remedy_assigned_qty      1
review_available_qty     0
shipment_available_qty   0
position_valid_yn        true
```

The physical review is `approved_to_existing_exception`; Product A is correctly linked to replacement and diverted.

The gap is operational wiring, not corrupted receipt data.

## 2. Governing routing rules

### 2.1 Originally clean quantity

Quantity stored as `clean` in the authoritative finalised receipt enters the existing customer-review lane independently of affected quantity in the same package.

For the controlled package, Product B quantity 1 must enter customer review even though Product A quantity 1 is damaged and linked to replacement.

### 2.2 Affected quantity before supervisor decision

Affected quantity remains diverted while the physical review is awaiting proposal, awaiting supervisor review, returned for information or approved for investigation.

### 2.3 Supervisor rejects the affected classification

The existing review decision value `reject` means the supervisor rejects the shipper's affected classification and permits that exact quantity to proceed as clean routing quantity.

```text
Supervisor rejects affected report
        ↓
Exact affected quantity is released to the existing customer-review lane
        ↓
Customer holds it → exact held quantity remains diverted
Customer accepts/review expires → exact quantity becomes shipment-ready
```

The original shipper receipt and evidence remain immutable for audit. No receipt row is deleted or rewritten.

The UI label must be explicit, for example:

```text
Reject affected report — allow customer review
```

No new decision enum or parallel endpoint is required.

### 2.4 Close no action

For `close_no_action`, only the exact approved `no_action` quantity is released to the existing customer-review lane. Any unapproved remainder remains diverted.

### 2.5 Refund, replacement and investigation

Exact quantity approved for refund, replacement or investigation remains diverted.

### 2.6 Customer review and hold

Originally clean quantity and supervisor-released quantity use the existing customer-review membership, deadline and hold workflow.

If the customer selects quantity to hold and the hold is approved:

```text
approved held quantity → diverted
remaining reviewed clean quantity → continues to shipment
```

### 2.7 Shipment

Only exact quantity that is:

```text
effective clean
customer-reviewed
not under an active hold
not already shipped
position-valid
```

may enter shipment membership.

Shipment creation must never copy full original `qty_allocated` when exact shipment-available quantity is lower.

## 3. Confirmed technical gaps

The database extraction proved:

1. `customer_review_cycle_candidates_v1(uuid)` still uses the whole-package `received_clean` condition and raw allocation quantity. It does not consume exact `review_available_qty`.
2. `shipper_shipment_batch_candidates_v1()` still uses the whole-package `received_clean` condition and raw allocation quantity. It does not consume exact `shipment_available_qty`.
3. `shipper_create_shipment_batch_v1(...)` still requires a whole clean package and snapshots raw `qty_allocated`.
4. `shipper_package_contents_preview_v1(uuid)` returns raw allocation quantity, so the package page falsely shows 2 shipment-eligible and 0 diverted.
5. The package page calculates diverted quantity as original minus shipment eligible, which wrongly classifies clean quantity awaiting customer review.
6. The terminal receipt page renders a blank correction form with affected quantity defaulted to zero, making the stored damaged line appear clean even though correction is blocked.
7. Supervisor `reject` currently cancels remedy proposals and marks the review rejected but does not release the exact quantity into customer review.

## 4. Required technical implementation

### 4.1 Add a private exact routing authority

Create a versioned private authority, recommended signature:

```sql
public.internal_tracking_allocation_fulfilment_routing_position_v2(
  p_order_id uuid DEFAULT NULL,
  p_tracking_submission_id uuid DEFAULT NULL,
  p_tracking_line_allocation_id uuid DEFAULT NULL
)
```

It must preserve all v1 provenance and derive:

```text
source_physical_clean_qty
source_physical_exception_qty
supervisor_released_to_clean_qty
effective_clean_qty
effective_exception_qty
reviewed_qty
active_hold_qty
shipped_qty
customer_released_qty
review_available_qty
shipment_available_qty
diverted_qty
position_valid_yn
position_blocker
source_receipt_id
source_physical_review_id
source_supervisor_decision
```

Required release logic:

```text
review status rejected
→ release all exact physical-exception quantity belonging to that review

review status closed_no_action
→ release only exact approved no_action quantity

refund / replacement / investigation
→ release zero
```

Required formulas:

```text
effective_clean_qty = source_physical_clean_qty + supervisor_released_to_clean_qty

effective_exception_qty = source_physical_exception_qty - supervisor_released_to_clean_qty

review_available_qty = max(
  effective_clean_qty - max(reviewed_qty, shipped_qty, customer_released_qty),
  0
)

shipment_available_qty = max(
  min(effective_clean_qty, reviewed_qty) - active_hold_qty - shipped_qty,
  0
)

diverted_qty = effective_exception_qty + active_hold_qty
```

Release must be tied to the same receipt, review, tracking allocation and disposition. Cross-review inference is prohibited. Broken balances fail closed.

The authority must not be executable by `PUBLIC`, `anon` or ordinary `authenticated` callers.

### 4.2 Correct customer-review candidates

Replace only the body of:

```sql
public.customer_review_cycle_candidates_v1(p_order_id uuid)
```

Keep its signature, columns, grants and existing materialiser callers unchanged.

It must:

- use the new exact routing authority;
- require `position_valid_yn = true`;
- include only `review_available_qty > 0`;
- set `review_qty = review_available_qty`;
- preserve existing invoice, allocation, tracking, receipt-time and value provenance;
- apportion monetary values to the exact review quantity;
- retain the existing deadline and materialisation workflow.

Controlled result before supervisor rejection:

```text
Product B review quantity 1
Product A review quantity 0
```

Controlled result after supervisor rejection of Product A:

```text
Product A released review quantity 1
```

### 4.3 Reuse the existing review materialiser

Do not create a new materialiser.

Continue using:

```sql
public.internal_materialize_customer_review_cycles_v1(uuid,uuid)
```

After the corrected candidate function is applied and proven, invoke it for the controlled order so Product B receives one exact customer-review membership.

No broad historical backfill is authorised.

### 4.4 Correct shipment candidates

Replace only the body of:

```sql
public.shipper_shipment_batch_candidates_v1()
```

Keep the signature, columns and shipper boundary unchanged.

It must:

- remove the whole-package `received_clean` requirement for v2 exact receipts;
- preserve legacy v1 clean-package compatibility;
- use exact `shipment_available_qty`;
- preserve the active customer-review-window gate;
- preserve shipper, importer, tracking and active-batch checks;
- return packages only when total exact shipment-available quantity is above zero.

### 4.5 Correct shipment creation

Replace only the body of the existing:

```sql
public.shipper_create_shipment_batch_v1(...)
```

Keep the existing RPC signature, grants, batch tables and line-membership table.

Under the existing locks it must re-read exact routing and insert only rows where:

```text
position_valid_yn = true
shipment_available_qty > 0
```

Set:

```text
qty_in_shipment = shipment_available_qty
```

Adjusted value must be apportioned to the exact quantity. Raw `qty_allocated` may be used only where exact equality is proven.

For the controlled package it must insert Product B quantity 1 only, never Product A and never package quantity 2.

### 4.6 Correct package routing read and page

Keep immutable original package contents visible.

Add a narrow authenticated shipper routing read returning per allocation:

```text
original_qty
awaiting_customer_review_qty
shipment_eligible_qty
diverted_qty
routing_reason
```

The package page must show three separate buckets:

```text
Awaiting customer review
Shipment eligible
Diverted from shipment
```

Before Product B review:

```text
Awaiting customer review: Product B qty 1
Shipment eligible:         0
Diverted:                  Product A qty 1
```

After Product B review with no hold:

```text
Awaiting customer review: 0
Shipment eligible:         Product B qty 1
Diverted:                  Product A qty 1
```

Do not calculate diverted as original minus shipment eligible.

### 4.7 Correct terminal receipt display

When correction is blocked, do not render blank all-clean defaults.

Display the immutable snapshot:

```text
Product A — damaged 1 — Damaged - ripped
Product B — clean 1
```

The correction lock remains unchanged.

### 4.8 Clarify supervisor reject UI

Keep server value `reject`, but label it:

```text
Reject affected report — allow customer review
```

Confirmation text must state that the exact affected quantity enters the existing customer-review lane.

Refund, replacement and investigation labels must state that quantity remains diverted.

## 5. Migration safety requirements

The additive migration must fingerprint and fail closed on drift before replacing:

- `customer_review_cycle_candidates_v1(uuid)`
- `shipper_shipment_batch_candidates_v1()`
- `shipper_create_shipment_batch_v1(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text)`
- any existing read function that is replaced

It must verify prerequisite objects and preserve owners, ACLs and role boundaries.

Do not edit any deployed migration. Do not broaden privileges.

## 6. Required regression proof

Rollback-only database regression must prove:

1. Mixed clean/damaged receipt remains valid.
2. Originally clean quantity enters customer review before affected review completion.
3. Unresolved affected quantity does not enter customer review or shipment.
4. Supervisor `reject` releases exact affected quantity into customer review without rewriting receipt history.
5. `close_no_action` releases only exact approved no-action quantity.
6. Refund, replacement and investigation quantities remain diverted.
7. Existing materialiser creates exact memberships only.
8. Customer hold diverts only exact held quantity.
9. Remaining reviewed clean quantity becomes shipment available.
10. Shipment candidates use exact available quantity.
11. Shipment creation snapshots exact quantity and value.
12. Already shipped quantity cannot be reused.
13. Legacy v1 clean packages remain compatible.
14. Uncertain legacy non-clean packages remain fail closed.
15. Grants and protected authorities are unchanged.

Controlled assertion:

```text
Product A diverted quantity 1; shipment membership 0
Product B customer-review quantity 1; eventual shipment membership 1
Total shipment membership for package 1, never 2
```

## 7. Protected non-scope

Do not redesign or replace:

- receipt submission or immutable receipt history;
- importer proposal or supervisor gateway permissions;
- dispute, refund or replacement linkage;
- customer-review links, deadlines or materialiser;
- customer-hold request and approval routes;
- shipment batch or line-membership tables;
- freight, AP/recharge, BOL or export evidence;
- Sage, VAT, supplier AP, customer sales, DVA, payout or credit-note authorities;
- tenant isolation, RLS or storage access.

No new business table, second shipment endpoint or parallel customer-review workflow is authorised.

## 8. Final governed flow

```text
Shipper records exact receipt
        |
        +-- originally clean quantity
        |       -> existing customer review
        |       -> approved customer hold: held qty diverted
        |       -> remaining reviewed qty shipment-ready
        |
        +-- affected quantity
                -> importer proposal
                -> supervisor decision
                       |
                       +-- reject affected report
                       |       -> exact qty enters existing customer review
                       |
                       +-- close no action
                       |       -> exact approved no-action qty enters customer review
                       |
                       +-- refund / replacement / investigation
                               -> exact approved qty remains diverted

Shipment creation snapshots only exact shipment_available_qty.
```
