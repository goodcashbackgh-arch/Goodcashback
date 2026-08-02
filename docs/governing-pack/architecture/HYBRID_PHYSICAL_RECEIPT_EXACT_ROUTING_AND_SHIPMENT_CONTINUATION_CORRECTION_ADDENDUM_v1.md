# Hybrid Physical Receipt Exact Routing and Shipment Continuation Correction Addendum v1

Status: Final governing correction and technical implementation specification  
Date: 2 August 2026

This addendum supplements:

- `HYBRID_PHYSICAL_RECEIPT_QUANTITY_FULFILMENT_AND_REMEDY_CONTROL_ADDENDUM_v1.md`
- `HYBRID_PHYSICAL_RECEIPT_QUANTITY_FULFILMENT_AND_REMEDY_CONTROL_ADDENDUM_v1_1.md`
- the existing customer-review, customer-hold, shipment-batch, dispute, refund and replacement authorities

Where this addendum is more specific about mixed clean/affected routing, supervisor rejection, customer-review timing, customer holds, shipment eligibility or shipment quantity, this addendum controls.

All deployed migrations remain immutable. Implementation must use additive migrations and fingerprint-guarded replacements only.

## 1. Purpose

The Hybrid Physical Receipt build correctly stores exact clean and affected quantities. The remaining defect is that the live customer-review, package-preview and shipment authorities still rely on old whole-package state and raw allocation quantity.

The final governed result is:

```text
Originally clean quantity progresses independently through the existing customer-review lane.
Affected quantity remains diverted while the physical review is unresolved.
Supervisor reject releases that exact affected quantity into the existing customer-review lane.
Supervisor-approved no-action quantity is also released into customer review.
Refund, replacement and investigation quantity remains diverted.
A customer hold diverts only the exact held quantity.
Only exact completed-review, unheld and unshipped quantity enters shipment.
No full-package quantity may leak into shipment.
```

No second customer-review system, shipment system, dispute route or receipt history is authorised.

## 2. Confirmed database facts

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

The latest receipt is a finalised v2 receipt with compatibility header status `received_damaged`.

Exact stored dispositions are correct:

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

The existing exact quantity position is also correct:

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

The defect is operational wiring, not corrupted receipt, remedy or dispute data.

## 3. Confirmed technical gaps

The repository and production extraction prove:

1. `customer_review_cycle_candidates_v1(uuid)` still uses whole-package `received_clean` and raw `qty_allocated` instead of exact `review_available_qty`.
2. No customer-review membership was materialised for the clean Product B quantity.
3. The existing materialiser anchors all review timing to `receipt_recorded_at`; that cannot give a later supervisor-released quantity its own full review period.
4. Existing review links are order-level, while routing and shipment must be exact-allocation-level.
5. `shipper_shipment_batch_candidates_v1()` still requires whole-package `received_clean` and uses raw allocation quantity.
6. `shipper_create_shipment_batch_v1(...)` still requires a whole clean package and snapshots raw `qty_allocated`.
7. Shipment creation does not independently recheck exact review completion under its write locks.
8. `shipper_package_contents_preview_v1(uuid)` returns original allocation quantity, causing the page to show 2 shipment-eligible and 0 diverted.
9. The package page derives diverted quantity from original minus shipment eligible, incorrectly treating clean quantity awaiting customer review as diverted.
10. The terminal receipt page renders blank editable defaults when correction is blocked, visually implying that every item is clean.
11. Supervisor `reject` currently closes the proposed remedy but does not release exact affected quantity into customer review.
12. Existing automatic materialisation triggers react to allocations and supplier-invoice changes, but not to v2 receipt finalisation or supervisor release decisions.

## 4. Governing routing rules

### 4.1 Originally clean quantity

Quantity stored as `clean` in the authoritative finalised receipt enters the existing customer-review lane immediately and independently of affected quantity in the same package.

For the controlled package, Product B quantity 1 must enter customer review even though Product A quantity 1 is damaged and linked to replacement.

### 4.2 Affected quantity before decision

Affected quantity remains diverted while the physical review is:

```text
awaiting_importer_proposal
awaiting_supervisor_review
returned_for_information
approved_for_investigation
```

### 4.3 Supervisor rejects affected classification

The existing server decision value `reject` means the supervisor rejects the shipper's affected classification and allows that exact quantity to proceed as clean routing quantity.

```text
Supervisor rejects affected report
        ↓
Exact affected quantity is released into the existing customer-review lane
        ↓
Customer holds it → exact held quantity remains diverted
Customer accepts / review expires → exact quantity becomes shipment-ready
```

The original receipt and evidence remain immutable for audit. No receipt row or disposition is rewritten.

The UI label must be explicit:

```text
Reject affected report — allow customer review
```

### 4.4 Close no action

For `close_no_action`, only exact quantity covered by an approved `no_action` remedy allocation is released into customer review.

Any unapproved remainder remains diverted and fails closed.

### 4.5 Refund, replacement and investigation

Exact quantity approved for refund, replacement or investigation remains diverted from customer review and shipment.

### 4.6 Customer hold

Originally clean quantity and supervisor-released quantity use the existing customer-review and hold workflow.

```text
approved held quantity → diverted
remaining completed-review clean quantity → continues to shipment
```

### 4.7 Review period

Every newly eligible exact quantity receives a full 24-hour customer-review period.

```text
Originally clean quantity:
review_eligible_at = receipt finalised/recorded time

Supervisor-released quantity:
review_eligible_at = supervisor_decided_at

review_expires_at = review_eligible_at + 24 hours
```

One quantity's later review period must not prevent another quantity whose own review is complete from becoming shipment-ready.

### 4.8 Shipment

Only exact quantity that is:

```text
effective clean
customer-review completed
not under an active hold
not already shipped
position-valid
```

may enter shipment membership.

## 5. Required database implementation

### 5.1 Add per-membership review timing

Add nullable columns to `customer_review_cycle_memberships`:

```sql
review_eligible_at timestamptz
review_expires_at  timestamptz
```

For deterministic existing timed memberships, backfill:

```text
review_eligible_at = receipt_recorded_at
review_expires_at  = existing review link expires_at
```

Legacy untimed memberships remain compatible and may retain null timing.

Add a check requiring either both timing columns to be null or:

```text
review_expires_at > review_eligible_at
```

Do not create a new membership table.

### 5.2 Add private exact routing authority v2

Create:

```sql
public.internal_tracking_allocation_fulfilment_routing_position_v2(
  p_order_id uuid DEFAULT NULL,
  p_tracking_submission_id uuid DEFAULT NULL,
  p_tracking_line_allocation_id uuid DEFAULT NULL
)
```

It must preserve v1 provenance and derive per allocation:

```text
source_physical_clean_qty
source_physical_exception_qty
supervisor_released_to_clean_qty
effective_clean_qty
effective_exception_qty
review_enrolled_qty
active_review_qty
completed_review_qty
active_hold_qty
shipped_qty
customer_released_qty
remedy_assigned_qty
review_available_qty
awaiting_customer_review_qty
shipment_ready_qty
diverted_qty
position_valid_yn
position_blocker
source_receipt_id
source_physical_review_id
source_supervisor_decision
```

Release logic:

```text
physical review status rejected
→ release all exact physical-exception quantity belonging to that review

physical review status closed_no_action
→ release only exact approved no_action quantity

refund / replacement / investigation
→ release zero
```

Required quantities:

```text
effective_clean_qty =
  source_physical_clean_qty + supervisor_released_to_clean_qty

effective_exception_qty =
  source_physical_exception_qty - supervisor_released_to_clean_qty

review_available_qty =
  max(
    effective_clean_qty
    - max(review_enrolled_qty, shipped_qty, customer_released_qty),
    0
  )

awaiting_customer_review_qty =
  review_available_qty + active_review_qty

shipment_ready_qty =
  max(
    min(effective_clean_qty, completed_review_qty)
    - active_hold_qty
    - shipped_qty,
    0
  )

diverted_qty =
  effective_exception_qty + active_hold_qty
```

`completed_review_qty` must exclude memberships whose own review period remains active. It may include exact memberships whose deadline passed or whose customer-review link was explicitly closed through the existing acceptance path.

The authority must fail closed where quantities exceed source allocation, clean, exception, review, hold or shipment limits.

The release must be tied to the same receipt, review, tracking allocation and disposition. Cross-review inference is prohibited.

Revoke execution from `PUBLIC`, `anon` and ordinary `authenticated`; retain only the privileged internal caller boundary.

### 5.3 Correct customer-review candidates

Replace only the body of:

```sql
public.customer_review_cycle_candidates_v1(p_order_id uuid)
```

Keep its existing public signature, return shape, grants and callers unless a return-shape extension is proven safe against all callers. Prefer a private v2 candidate source and adapt the existing v1 wrapper to its established return contract.

The corrected candidate source must:

- use the exact routing authority;
- require `position_valid_yn = true`;
- include only `review_available_qty > 0`;
- set `review_qty = review_available_qty`;
- derive `review_eligible_at` from receipt time for original clean quantity and supervisor decision time for released quantity;
- derive `review_expires_at = review_eligible_at + 24 hours`;
- preserve supplier-invoice, line, allocation, tracking and monetary provenance;
- proportion monetary values to exact review quantity;
- include receipt identity, allocation identity, routing decision and eligibility timestamp in its fingerprint.

Controlled result:

```text
Product B review quantity 1
Product A review quantity 0
```

### 5.4 Correct the existing materialiser

Keep the existing signature:

```sql
public.internal_materialize_customer_review_cycles_v1(uuid,uuid)
```

Do not create a parallel materialiser.

Replace its body so that it:

1. uses candidate `review_eligible_at` and `review_expires_at`, not only `receipt_recorded_at`;
2. inserts exact membership timing into the new columns;
3. expires memberships individually when their own `review_expires_at <= now()`;
4. keeps an order review link active until the maximum active membership deadline;
5. permits later exact candidates to join the existing customer link without resetting earlier membership timing;
6. does not treat one active membership as blocking completion of another membership;
7. remains idempotent through deterministic membership fingerprints;
8. preserves legacy untimed-link fail-closed behaviour.

The customer-facing link remains the existing link. Timing authority becomes exact membership timing.

### 5.5 Add automatic materialisation hooks

#### Receipt finalisation hook

Add one narrow trigger function and trigger on `shipper_package_receipts`:

```text
AFTER a v2 receipt changes to finalised
→ call internal_materialize_customer_review_cycles_v1(NEW.order_id, NULL)
```

The trigger fires only for finalised v2 receipts and therefore automatically admits originally clean exact quantity.

Do not replace the large receipt RPC merely to add this call.

#### Supervisor release hook

Materialisation after `reject` or `close_no_action` must occur only after the complete supervisor decision transaction has finalised its review and remedy-allocation state.

Use either:

- an explicit final call at the end of the authoritative supervisor decision RPC; or
- a deferred constraint trigger that executes after the transaction's review/remedy writes are complete.

The hook must call:

```sql
public.internal_materialize_customer_review_cycles_v1(NEW.order_id, NULL)
```

It must not run for refund, replacement or investigation decisions.

### 5.6 Correct exact review state used by shipment

Add or version an internal exact review-state read that reports active review by tracking allocation, not merely by whole tracking package.

It must use membership-level timing and return, at minimum:

```text
tracking_line_allocation_id
active_review_qty
completed_review_qty
next_review_expires_at
```

Keep the existing package-level review-state RPC for compatibility where still needed, but shipment routing must use the exact allocation-level authority.

### 5.7 Correct shipment candidates

Replace only the body of:

```sql
public.shipper_shipment_batch_candidates_v1()
```

Keep its signature, return columns and shipper boundary.

It must:

- remove whole-package `received_clean` for v2 exact receipts;
- preserve legacy v1 `received_clean` compatibility;
- aggregate exact `shipment_ready_qty` only;
- preserve shipper, importer, tracking and active-batch ownership checks;
- expose a package when at least one exact allocation has `shipment_ready_qty > 0`;
- report quantity and value from exact ready quantity, not raw allocation quantity.

A different allocation in the same package having an active review must not block an allocation whose own review is complete.

### 5.8 Correct shipment creation

Replace only the body of:

```sql
public.shipper_create_shipment_batch_v1(
  p_importer_id uuid,
  p_tracking_submission_ids uuid[],
  p_booking_ref text,
  p_shipment_cutoff_at timestamptz,
  p_dispatched_at timestamptz,
  p_box_count integer,
  p_container_ref text,
  p_bol_ref text,
  p_notes text
)
```

Keep the existing RPC signature, grants, batch tables and line-membership table.

Under the existing order/tracking locks, it must independently re-read the exact routing authority and fail closed unless every inserted row satisfies:

```text
position_valid_yn = true
shipment_ready_qty > 0
active_review_qty = 0 for the inserted quantity
active_hold_qty does not consume the inserted quantity
quantity has not already been shipped
```

Insert:

```text
qty_in_shipment = shipment_ready_qty
```

Never insert raw `qty_allocated` unless exact equality is proven under the same lock.

Adjusted value must be apportioned to exact shipment quantity using the existing value basis.

For the controlled package:

```text
Product B shipment membership 1
Product A shipment membership 0
Total package shipment quantity 1, never 2
```

### 5.9 Correct package-routing read and page

Keep original package allocation history visible and immutable.

Add a narrow authenticated shipper routing read returning per allocation:

```text
original_qty
awaiting_customer_review_qty
shipment_eligible_qty
diverted_qty
routing_reason
next_review_expires_at
```

The package page must render three distinct current-routing buckets:

```text
Awaiting customer review
Shipment eligible
Diverted from shipment
```

Before Product B review completes:

```text
Awaiting customer review: Product B qty 1
Shipment eligible:         0
Diverted:                  Product A qty 1
```

After Product B review completes with no hold:

```text
Awaiting customer review: 0
Shipment eligible:         Product B qty 1
Diverted:                  Product A qty 1
```

Do not calculate diverted as original minus shipment eligible.

### 5.10 Correct terminal receipt display

When correction is blocked, do not render blank all-clean defaults.

Display the immutable stored snapshot:

```text
Product A — damaged 1 — Damaged - ripped
Product B — clean 1
```

The existing correction lock remains unchanged.

### 5.11 Clarify supervisor decision UI

Keep server value `reject`, but label it:

```text
Reject affected report — allow customer review
```

Confirmation text must state that exact affected quantity enters the existing customer-review lane.

Refund, replacement and investigation labels must state that quantity remains diverted.

No new decision enum or second supervisor RPC is authorised.

## 6. Controlled recovery for the proven omitted clean quantity

The production defect omitted the customer-review membership for:

```text
order_id:                    8c882f9d-aadc-4a6a-b50c-d013d1abffd7
tracking_submission_id:      96165f7d-afa7-4c26-a601-8bd6ee0f85b7
tracking_line_allocation_id: 129f543d-5d0a-4696-8535-810ccd128d45
quantity:                    1
```

Because the original receipt-based 24-hour period may already have expired, this addendum authorises one guarded recovery in the corrective migration.

The recovery may create a fresh 24-hour review membership only if all conditions still hold:

```text
latest authoritative v2 receipt remains 570e1b73-8306-4203-ac06-f7a84e2de53e
stored exact clean quantity remains 1
stored affected quantity remains 0
position remains valid
no customer-review membership exists for the allocation
no active hold exists
shipped quantity remains 0
customer released quantity remains 0
```

The recovery must set:

```text
review_eligible_at = migration recovery timestamp
review_expires_at  = review_eligible_at + 24 hours
review_qty         = 1
```

It must use the existing review-link and membership tables and deterministic fingerprinting.

No generic historical backfill or second recovery mechanism is authorised.

## 7. Migration safety requirements

The corrective migration must fingerprint and fail closed on drift before replacing or extending:

- `customer_review_cycle_candidates_v1(uuid)`
- `internal_materialize_customer_review_cycles_v1(uuid,uuid)`
- `shipper_shipment_batch_candidates_v1()`
- `shipper_create_shipment_batch_v1(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text)`
- any read function replaced rather than versioned
- existing customer-review membership table shape and constraints

It must verify prerequisite objects including:

- `internal_tracking_allocation_fulfilment_position_v1(uuid,uuid,uuid)`
- `customer_order_review_links`
- `customer_review_cycle_memberships`
- `customer_hold_review_memberships`
- `shipper_shipment_batch_line_memberships`
- `physical_receipt_reviews`
- `physical_exception_remedy_allocations`
- `shipper_package_receipt_line_dispositions`

Preserve owners, ACLs, RLS and authenticated boundaries.

Do not edit any deployed migration. Do not broaden privileges.

## 8. Required rollback-only database regression

The regression must prove:

1. A mixed clean/damaged v2 receipt remains valid.
2. Originally clean quantity is automatically materialised immediately after receipt finalisation.
3. Originally clean quantity does not wait for the affected physical review.
4. Unresolved affected quantity does not enter customer review or shipment.
5. Supervisor `reject` releases exact affected quantity into customer review without rewriting receipt history.
6. Supervisor-released quantity receives a full 24-hour membership review period from supervisor decision time.
7. `close_no_action` releases only exact approved no-action quantity.
8. Refund, replacement and investigation quantity remains diverted.
9. Membership deadlines operate independently within the existing customer link.
10. One active later membership does not block an earlier completed allocation from shipment.
11. Customer hold diverts only exact held quantity.
12. Remaining completed-review clean quantity becomes shipment-ready.
13. Shipment candidates aggregate exact ready quantity.
14. Shipment creation independently rechecks review, hold and shipped quantities under lock.
15. Shipment creation snapshots exact quantity and proportional value.
16. Already shipped quantity cannot be reused.
17. Legacy v1 clean packages remain compatible.
18. Uncertain legacy non-clean packages remain fail closed.
19. The exact controlled recovery creates Product B membership quantity 1 only.
20. Existing grants and protected authority boundaries remain unchanged.

Controlled assertion:

```text
Product A diverted quantity 1; shipment membership 0
Product B customer-review quantity 1; eventual shipment membership 1
Total shipment membership for package 1, never 2
```

## 9. Required source and UI regression

Source regression must fail if:

- v2 customer-review or shipment authorities still require whole-package `received_clean`;
- shipment creation inserts raw `qty_allocated` without exact equality proof;
- receipt finalisation does not automatically invoke the existing materialiser;
- supervisor reject/close-no-action does not automatically invoke the existing materialiser after final decision state;
- supervisor-released quantity uses the original receipt timestamp instead of supervisor decision time;
- active review remains only package-level for shipment routing;
- the package page calculates diverted as original minus shipment eligible;
- the terminal receipt page renders blank all-clean defaults while correction is blocked;
- the supervisor reject label does not state its customer-review effect;
- a parallel customer-review, hold, shipment or dispute workflow is introduced.

## 10. Protected non-scope

Do not redesign or replace:

- receipt submission or immutable receipt history;
- importer proposal permissions;
- supervisor gateway permissions or proven replacement/refund linkage sequence;
- customer-review link identity or customer access route;
- customer hold request and approval routes;
- shipment batch or line-membership tables;
- freight, AP/recharge, BOL or export evidence;
- dispute conversation, refund evidence, replacement child or return actions;
- Sage, VAT, supplier AP, customer sales, DVA, payout or credit-note authorities;
- tenant isolation, RLS or storage access.

No new business table, second shipment endpoint or parallel customer-review workflow is authorised.

## 11. Build and acceptance order

1. Capture current production fingerprints, owners, ACLs and table constraints.
2. Add membership timing columns and deterministic compatibility backfill.
3. Add the private exact routing authority v2.
4. Correct the existing candidate and materialiser bodies.
5. Add automatic receipt-finalisation and supervisor-release materialisation hooks.
6. Add exact allocation-level review state.
7. Correct shipment candidate and creation bodies.
8. Add the narrow package-routing read.
9. Correct the two shipper displays and supervisor reject wording.
10. Add source regressions.
11. Run rollback-only database regression.
12. Apply the migration.
13. Execute the guarded controlled recovery.
14. Verify Product B receives review quantity 1 and Product A receives none.
15. Complete the normal customer review.
16. Verify package shipment candidate quantity is 1.
17. Create a controlled shipment and prove Product B membership 1, Product A membership 0.
18. Merge only after CI, database proof and final scope review succeed.

## 12. Final governed flow

```text
Shipper finalises exact receipt
        |
        +-- originally clean quantity
        |       -> automatically materialised into existing customer review
        |       -> its own 24-hour membership period
        |       -> approved customer hold: exact held qty diverted
        |       -> completed-review remainder shipment-ready
        |
        +-- affected quantity
                -> importer proposal
                -> supervisor decision
                       |
                       +-- reject affected report
                       |       -> exact qty automatically enters customer review
                       |       -> fresh 24-hour membership period
                       |
                       +-- close no action
                       |       -> exact approved no-action qty enters customer review
                       |
                       +-- refund / replacement / investigation
                               -> exact approved qty remains diverted

Shipment candidates and shipment creation use only exact shipment_ready_qty.
```
