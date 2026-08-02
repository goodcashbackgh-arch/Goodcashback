# Hybrid Physical Receipt Implementation Alignment Addendum v1.2

**Subtitle:** Commercial Value, Dispute Partitioning and Replacement Original-Item Return Actions

**Status:** governing implementation clarification, locked technical specification and non-regression authority

**Effective date:** 2 August 2026

**Verified repository baseline:** `main` at `e69a7e290720f03b9d999b21a51f8a1231196703`

**Live-database evidence reviewed:** 2 August 2026

## 1. Purpose

This addendum governs the final repair of the physical-receipt-to-exception bridge.

It ensures that:

- one tracked package may contain clean, refund and replacement quantities at the same time;
- only affected quantities enter disputes;
- every affected quantity retains exact physical, tracking, supplier-invoice and remedy provenance;
- the exact customer commercial value is carried into the existing dispute routes instead of being written as an unknown zero;
- refunds are partitioned into downstream-compatible disputes;
- each physical replacement allocation enters the exact one-line dispute shape required by the existing replacement-child authority;
- a damaged or wrong original item may use the existing return-action records when the retailer requires return or collection;
- a missing item never creates a physical return action;
- the established refund, replacement-child, DVA/card, customer settlement, VAT, Sage, supplier-AP, shipping-AP and accounting authorities remain unchanged.

This is a surgical bridge repair. It is not permission to redesign working upstream or downstream areas.

A builder must be able to implement this addendum without relying on informal chat history. When the repository, live database, permissions, function definitions or trigger bindings differ from this document, the builder must stop and reconcile the difference explicitly. The builder must not guess.

## 2. Authority and precedence

This addendum must be read with:

1. `docs/governing-pack/architecture/HYBRID_PHYSICAL_RECEIPT_QUANTITY_FULFILMENT_AND_REMEDY_CONTROL_ADDENDUM_v1.md`;
2. `docs/governing-pack/architecture/HYBRID_PHYSICAL_RECEIPT_IMPLEMENTATION_ALIGNMENT_ADDENDUM_v1_1.md`;
3. `docs/governing-pack/architecture/HYBRID_PHYSICAL_RECEIPT_BUILD_4_LIFECYCLE_AND_RECONCILIATION_ALIGNMENT_ADDENDUM_v1.md`;
4. `docs/governing-pack/architecture/HYBRID_PHYSICAL_RECEIPT_BUILD_4_AUTHORITY_VERSIONING_CORRECTION_ADDENDUM_v1.md`;
5. `docs/governing-pack/ui/PHYSICAL_RETURN_TASK_BRIDGE_CONTRACT_v1.md`;
6. `docs/governing-pack/ui/EXCEPTION_REFUND_REPLACEMENT_ROUTE_CONTRACT.md`;
7. `docs/governing-pack/architecture/MULTI_SUPPLIER_INVOICE_ORDER_CONTROL_ADDENDUM_v1.md`;
8. the current refund evidence, supplier-credit, DVA/card, customer-settlement, VAT, Sage, supplier-AP, shipping-AP, funding, treasury and tenant-control authorities;
9. the current importer/operator, shipper, supervisor and admin role matrices.

Where this v1.2 addendum is more specific about physical customer commercial value, refund dispute partitioning, replacement dispute shape or replacement original-item return actions, this v1.2 addendum controls.

All other earlier requirements remain in force.

Historical migrations remain immutable. Every implementation correction must be an additive later migration or a deliberate later replacement of the current live function after exact-definition preflight. Never edit a deployed migration to make history appear correct.

## 3. Explicit refinements to v1.1

### 3.1 Commercial-value refinement

The v1.1 statement that the initial decision must not invent final financial values remains correct for:

- retailer refund value;
- supplier recovery;
- supplier replacement cost;
- DVA/card refund receipt;
- customer payout, credit or credit note;
- final accounting or settlement.

It is refined for customer commercial value as follows:

> The supervisor bridge must write the customer commercial value when that value is deterministically proven by the exact tracking-line allocation's governed `adjusted_net_value_gbp`. It must not replace a proven value with zero and must not use supplier cost as customer entitlement.

### 3.2 Dispute-grouping refinement

The v1.1 compatibility grouping rule is refined to the exact downstream-safe shape:

```text
refund dispute group:
physical review + order + original supplier invoice + issue type + desired outcome + liable party

replacement dispute group:
one distinct approved physical replacement remedy allocation
```

The review and order are fixed within one supervisor decision. The liable party is fixed by that decision. They remain part of the logical compatibility key and must still agree.

Two refund allocations may share a dispute only when they belong to the same original supplier invoice and have the same issue type. Refund allocations from different supplier invoices or different issue types must not share a dispute.

A physical replacement dispute must contain exactly one physical remedy-linked dispute line because the established final replacement acceptance authority requires that shape.

### 3.3 Return-action refinement

The existing return-action record family is shared operational infrastructure. Existing refund RPCs remain unchanged.

Additive replacement adapters may use the same records only when:

- the dispute outcome is replacement;
- the exact physical disposition is damaged or wrong;
- a retailer response has been recorded;
- the operator records actionable return or collection information before replacement-child creation.

Missing items are ineligible because there is no original item to return.

The original-item return action is operationally independent from the replacement child. It does not block replacement-child creation under this build.

## 4. Verified baseline facts

The following facts were verified from the repository and live definitions supplied during review.

### 4.1 Supervisor bridge

The application calls:

```text
staff_decide_physical_receipt_review_v2
```

The protected v2 gateway delegates to:

```text
staff_decide_physical_receipt_review_v1(
  uuid,
  text,
  jsonb,
  text,
  text
)
```

The current v1 authority:

- authenticates an active admin or supervisor;
- locks the review and remedy rows;
- acquires an order advisory transaction lock;
- validates the complete importer proposal set;
- requires whole-unit quantities for refund/replacement;
- preserves hold/investigate and no-action routes;
- currently creates one refund dispute and one replacement dispute per review;
- currently writes `0` to physical dispute-line and dispute-header amounts;
- currently does not write `customer_commercial_value_gbp` during the bridge;
- retains a deterministic compatibility primary link with refund before replacement and dispute UUID as the tie-breaker;
- uses the later `LINK_SHAPE_SEQUENCE_V1` ordering so the review receives its linked dispute before allocations progress to `linked_to_exception`.

### 4.2 Physical guards

The current physical guards protect exact source, quantity and lifecycle provenance, including:

```text
physical_remedy_allocation_guard_v2()
physical_remedy_sequence_guard_v1()
physical_receipt_review_guard_v1()
```

The implementation must preserve their definitions, owners, grants and trigger bindings.

### 4.3 Replacement path

The active final replacement authority is:

```text
staff_accept_replacement_outcome_v1(uuid,uuid,text)
```

For a physical replacement it requires exactly one active physical remedy-linked dispute line and calls:

```text
create_replacement_child_order_v2(uuid,uuid,uuid,text)
```

The child authority reads the approved physical quantity and uses:

```text
COALESCE(
  physical_exception_remedy_allocations.customer_commercial_value_gbp,
  dispute_lines.amount_impact_gbp,
  0
)
```

for the child commercial value.

It links and progresses the exact physical remedy, resolves the source dispute line, sets the replacement-child provenance and resolves the parent replacement dispute.

Therefore a missing or zero bridge value directly creates an incorrect child value unless repaired upstream.

### 4.4 Refund path

`operator_submit_refund_document_evidence(...)`:

- accepts one original supplier invoice identity;
- requires a refund dispute in `awaiting_refund_credit`;
- reads the complete dispute-header `amount_impact_gbp` as the expected exception amount;
- balances submitted refund evidence against that header amount.

A refund dispute must therefore contain only lines compatible with one original supplier invoice and its header amount must equal its line total.

### 4.5 Review-to-dispute links

`physical_receipt_review_dispute_links` has:

- a primary key on its own ID;
- a unique review/dispute pair;
- no uniqueness rule preventing several disputes with the same desired outcome from belonging to one review.

One review may therefore link several refund disputes and several replacement disputes. `physical_receipt_reviews.linked_dispute_id` remains only the compatibility primary link.

### 4.6 Return-action path

The existing return-action tables are:

```text
dispute_return_tracking_submissions
shipper_return_task_confirmations
```

The existing operator return record contains:

- courier;
- tracking or collection reference;
- tracking or collection date;
- tracking/evidence URL;
- retailer instructions file;
- return label file;
- operator return-proof file;
- note;
- final-return flag;
- supervisor review status and evidence.

The current refund-only boundaries are:

```text
operator_submit_return_collection_tracking(...)
shipper_return_tasks_v1()
shipper_submit_return_task_confirmation_v1(...)
```

The current supervisor review functions and internal confirmation worklist are outcome-neutral:

```text
staff_review_return_collection_tracking(...)
staff_review_shipper_return_task_confirmation_v1(...)
internal_shipper_return_task_confirmations_v1(boolean)
```

The current shipper task reader exposes a row only when at least one of these is present:

```text
retailer return-instructions file
return-label file
tracking reference
tracking-evidence URL
meaningful note
```

A courier, date or operator proof file alone does not satisfy the current shipper-visible predicate.

### 4.7 Current UI restrictions

The current shipper return page calls `shipper_return_tasks_v1()` and describes the queue as refund-only.

The current internal exception page shows the structured return-review panel only for:

```text
desired_outcome = refund
and status = awaiting_refund_credit
```

That panel must be widened for replacement return records without changing its review action.

### 4.8 Confirmed broken record

The verified live case is:

```text
order_id:
8c882f9d-aadc-4a6a-b50c-d013d1abffd7

order_ref:
SEED-REPL-0C7952EE44

physical_receipt_review_id:
1987393f-47ba-4460-96f6-598e0e52792d

physical_exception_remedy_allocation_id:
9e7f6c25-e920-4c90-a16a-0ffb6381a3d6

tracking_line_allocation_id:
5dbd95c5-c0d0-489d-973d-fab4c9083160

supplier_invoice_line_id:
0985538e-e9bb-42f2-8e3c-8cf11063705e

dispute_line_id:
126ed01a-09b4-47e4-a2db-c52e7480d814

dispute_id:
d7b32314-603e-49bf-83d1-1a01e2e4d29f

tracking allocated quantity:
1

tracking adjusted net value:
GBP 60.00

current remedy commercial value:
NULL

current dispute-line amount:
GBP 0.00

current dispute-header amount:
GBP 0.00

correct customer commercial value:
GBP 60.00
```

## 5. Required business result

A single package receipt may resolve as:

```text
6 units received

3 clean
-> existing clean customer-review, shipment and customer-sales route

2 refund
-> existing refund exception and refund-evidence route

1 replacement
-> existing replacement exception and replacement-child route
```

The package remains one physical receipt.

No supplier invoice line, tracking allocation or order line is duplicated merely to represent the split.

Clean quantity never enters a dispute.

Refund and replacement quantities never share a dispute.

Every affected quantity retains exact provenance to:

```text
receipt
receipt line disposition
tracking submission
tracking line allocation
supplier invoice
supplier invoice line
physical remedy allocation
dispute
dispute line
```

## 6. Non-negotiable invariants

For every exact tracking allocation:

```text
clean quantity + affected quantity = allocated quantity
```

For every affected disposition:

```text
sum of active proposed or approved remedy quantities <= disposition quantity
```

For every exact tracking allocation entering `approve_existing_exception`:

```text
sum of approved refund/replacement quantities <= qty_allocated
```

The same physical quantity must never be:

- shipped twice;
- released to customer sales twice;
- refunded twice;
- replaced twice;
- represented by more than one completed remedy;
- consumed by more than one replacement child.

The same physical remedy allocation may link to at most one dispute line.

The same dispute line may link to at most one physical remedy allocation.

## 7. Protected implementation boundary

### 7.1 Existing caller remains unchanged

The application continues calling `staff_decide_physical_receipt_review_v2`.

Do not change its signature, permissions, whole-unit gateway or source calls.

### 7.2 Corrected authority

Replace the complete reviewed live definition of:

```text
staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text)
```

Preserve:

- function signature;
- return type;
- owner;
- `SECURITY DEFINER`;
- search path;
- direct-execution restrictions;
- v2-only application entry;
- existing JSON response keys.

Only the approved existing-exception creation and monetary handover logic changes.

### 7.3 Protected downstream authorities

The implementation must not replace or alter:

```text
staff_decide_physical_receipt_review_v2(...)
staff_accept_replacement_outcome_v1(uuid,uuid,text)
create_replacement_child_order_v2(uuid,uuid,uuid,text)
operator_submit_refund_document_evidence(...)
operator_submit_return_collection_tracking(...)
shipper_return_tasks_v1()
shipper_submit_return_task_confirmation_v1(...)
staff_review_return_collection_tracking(...)
staff_review_shipper_return_task_confirmation_v1(...)
internal_shipper_return_task_confirmations_v1(boolean)
physical_remedy_allocation_guard_v2()
physical_remedy_sequence_guard_v1()
physical_receipt_review_guard_v1()
```

Their definitions, owners, grants and relevant trigger bindings are release fingerprints.

## 8. Migration A: physical value and dispute-shape repair

Create a new additive migration. Do not edit any deployed migration.

### 8.1 Transaction and preflight

The migration must:

1. start with `BEGIN`;
2. set a finite lock timeout;
3. set the governed statement timeout used by current authority migrations;
4. verify every referenced table, column, index, trigger and function exists;
5. capture the installed v1 function definition, owner, ACL and security attributes;
6. compare the installed definition with the exact reviewed live definition;
7. compare every protected function and guard with its reviewed fingerprint;
8. capture and verify the relevant trigger bindings;
9. abort if any object differs;
10. install one complete audited replacement definition rather than applying a loose text substitution;
11. recheck the installed definition, grants, owner, security mode and protected fingerprints;
12. issue `NOTIFY pgrst, 'reload schema'`;
13. commit only after all postflight assertions pass.

The migration must hardcode the exact definition fingerprint reviewed immediately before implementation. A builder must not invent a hash from this document. If the live definition cannot be obtained, implementation stops.

### 8.2 Existing behaviour that must remain unchanged

The corrected v1 authority must preserve:

- authentication through `auth.uid()`;
- active admin/supervisor validation;
- required factual decision note;
- liable-party validation;
- allocation payload shape validation;
- review row `FOR UPDATE`;
- order-level advisory transaction lock;
- physical remedy row locks;
- complete-proposal-set validation;
- duplicate proposal-row rejection;
- exact quantity limits;
- supplier-cost-mode validation;
- `return_for_information` behaviour;
- `reject` behaviour;
- `close_no_action` behaviour;
- `approve_investigation` behaviour;
- whole-unit refund/replacement validation;
- the unresolved legacy-exception ambiguity blocker;
- refund pursuit approval fields currently written by the bridge;
- review and remedy timestamps;
- all existing result keys;
- `LINK_SHAPE_SEQUENCE_V1`;
- the compatibility primary-dispute ordering.

### 8.3 Additional locking

Before reading customer commercial values, lock every referenced `order_tracking_line_allocations` row in deterministic ID order.

The lock must remain held until the supervisor transaction commits or rolls back.

This prevents a concurrent allocation-value edit from changing the basis between validation and dispute creation.

## 9. Exact customer commercial value

### 9.1 Authoritative source

For every approved refund or replacement remedy allocation, resolve:

```text
physical_exception_remedy_allocations.tracking_line_allocation_id
-> order_tracking_line_allocations.id
```

Use:

```text
order_tracking_line_allocations.adjusted_net_value_gbp
```

as the customer commercial-value total for that exact tracking allocation.

Do not use:

- supplier claim amount;
- supplier replacement cost;
- credit-note amount;
- DVA/card refund amount;
- order declared total apportioned without exact tracking identity;
- `COALESCE(value, 0)` as an unknown-value fallback.

A free replacement may have zero supplier cost and positive customer commercial value. These are separate facts.

### 9.2 Required identity and value checks

Before creating any refund or replacement dispute, require all of the following:

```text
remedy allocation belongs to the current physical review
remedy allocation is supervisor-approved in this transaction
remedy allocation has approved type refund or replacement
remedy allocation has a positive whole-unit approved quantity
receipt disposition belongs to the review receipt
receipt disposition is not clean or held
receipt disposition tracking allocation = remedy tracking allocation
receipt disposition supplier line = remedy supplier line
tracking allocation exists
tracking allocation order = review order
tracking allocation tracking submission = review tracking submission
tracking allocation supplier line = remedy supplier line
supplier invoice line exists
supplier invoice line belongs to a supplier invoice for the review order
qty_allocated > 0
adjusted_net_value_gbp IS NOT NULL
ROUND(adjusted_net_value_gbp, 2) > 0
sum approved refund/replacement qty for the allocation <= qty_allocated
```

Allowed physical issue mappings remain:

```text
missing -> missing
damaged -> damaged
wrong -> wrong_item
```

Any unsupported disposition or identity mismatch rolls back the complete supervisor decision.

## 10. Deterministic value apportionment

All remedy values for one tracking allocation must be calculated together.

For each exact tracking allocation:

```text
commercial_total = ROUND(adjusted_net_value_gbp, 2)
```

Create calculation buckets:

1. one bucket for every approved refund or replacement remedy allocation linked to that tracking allocation;
2. one synthetic remainder bucket when:

```text
qty_allocated - sum(approved refund/replacement qty) > 0
```

The synthetic remainder represents clean quantity in this existing-exception decision. It is calculation-only and is never inserted into a dispute.

For each bucket:

```text
raw_amount = commercial_total * bucket_quantity / qty_allocated
rough_amount = ROUND(raw_amount, 2)
```

Then calculate:

```text
residual = commercial_total - SUM(rough_amount)
```

Assign the complete residual to one deterministic bucket ordered by:

```text
raw_amount DESC
synthetic remainder bucket before remedy bucket when raw amounts tie
stable bucket key ASC
```

For a remedy bucket, the stable key is the remedy-allocation UUID text.

For the synthetic remainder bucket, use a fixed stable key that sorts before remedy UUIDs when the preceding tie rules also match.

Required postconditions:

```text
SUM(final bucket amounts) = commercial_total
all final remedy-bucket amounts > 0
all final amounts have two-decimal precision
repeated execution against identical locked source data produces identical values
```

If any approved remedy receives a zero or negative final amount, fail closed. Do not silently move value between unrelated tracking allocations.

## 11. Required monetary writes

Before an approved refund or replacement allocation becomes `linked_to_exception`, write:

```text
physical_exception_remedy_allocations.customer_commercial_value_gbp
= final remedy-bucket amount
```

The linked dispute line must receive:

```text
dispute_lines.amount_impact_gbp
= the same final remedy-bucket amount
```

Each dispute header must receive:

```text
disputes.amount_impact_gbp
= SUM(all active dispute-line amounts created for that dispute)
```

Required assertions before return:

```text
allocation commercial value = linked dispute-line amount
dispute header amount = sum of its active dispute-line amounts
no created physical refund/replacement amount is null or zero
```

The supervisor decision must roll back completely if any assertion fails.

## 12. Refund dispute partitioning

### 12.1 Grouping key

Approved refund allocations may share a dispute only when all of these match:

```text
physical review
order
original supplier invoice ID
issue type
approved liable party
desired outcome = refund
```

Resolve original supplier invoice ID through:

```text
physical remedy supplier invoice line
-> supplier_invoice_lines.supplier_invoice_id
```

A null or mismatched supplier invoice identity is a hard failure.

### 12.2 Creation rule

For each compatible refund group:

- create one refund dispute;
- create one exact dispute line per physical remedy allocation;
- write each exact approved quantity and commercial value;
- calculate the header amount from those lines;
- create one immutable physical-review/dispute link.

Preserve the existing refund header semantics:

```text
desired_outcome = refund
status = raised
stage_detected = at_ghana_delivery
liable_party = supervisor-approved liable party
refund_approved_by_staff_id = deciding supervisor
refund_approved_at = decision timestamp
```

### 12.3 Examples

Same supplier invoice and same issue type:

```text
2 refund allocations
-> 1 refund dispute
-> 2 exact dispute lines
```

Different supplier invoices:

```text
2 refund allocations
-> 2 refund disputes
```

Same supplier invoice but different issue types:

```text
1 missing refund allocation
1 damaged refund allocation
-> 2 refund disputes
```

This preserves truthful header issue classification while keeping each dispute compatible with one original supplier invoice.

## 13. Replacement dispute partitioning

For every distinct approved physical replacement remedy allocation:

```text
create one replacement dispute
create exactly one physical remedy-linked dispute line
```

One remedy allocation may contain several units from the same exact physical source.

Example:

```text
one replacement remedy allocation
approved quantity = 3
-> one replacement dispute
-> one dispute line
-> qty_impact = 3
```

Two distinct replacement remedy allocations create two replacement disputes.

Each replacement dispute receives:

```text
desired_outcome = replacement
status = raised
stage_detected = at_ghana_delivery
liable_party = supervisor-approved liable party
amount_impact_gbp = exact allocation commercial value
```

Each replacement line receives:

```text
supplier_invoice_line_id = exact source line
qty_impact = exact whole approved quantity
amount_impact_gbp = exact allocation commercial value
intended_remedy = replacement
physical_remedy_allocation_id = exact remedy allocation
```

Do not modify the replacement acceptance or child-order authorities.

## 14. Audit wording

The bridge must not continue writing wording that says financial value is unproven after it has written a proven customer commercial value.

Use wording with this meaning:

```text
Created from physical receipt review <review-id>.
Customer commercial value derived from the exact tracking allocation.
Retailer remedy outcome remains pending.
```

This statement does not claim that supplier recovery, retailer refund receipt, customer settlement or replacement completion has occurred.

## 15. Review-to-dispute linking and compatibility response

Insert every created dispute into:

```text
physical_receipt_review_dispute_links
```

Preserve the compatibility primary link exactly:

```text
refund before replacement
dispute UUID as final tie-breaker
LIMIT 1
```

Store that result in:

```text
physical_receipt_reviews.linked_dispute_id
```

The link table is the complete authority for all linked disputes.

Preserve the existing sequence:

```text
approve remedy allocations
-> create disputes and dispute lines
-> set the review primary linked dispute
-> progress linked refund/replacement allocations to linked_to_exception
```

Preserve every existing JSON response key.

Where the existing response has a singular refund or replacement dispute ID but several such disputes now exist, return the deterministic first dispute for that outcome using dispute UUID ordering. Do not return whichever loop row happened to execute last.

No caller may use a singular compatibility field as the complete linked-dispute collection.

## 16. Migration B: exact confirmed-record repair

Create a separate additive migration for the confirmed broken record only.

Do not perform a broad historical backfill.

### 16.1 Exact target

Use the IDs in section 4.8.

### 16.2 Broken-state preconditions

Before updating, verify all of the following exactly:

```text
review status = approved_to_existing_exception
remedy status = linked_to_exception
remedy approved type = replacement
remedy approved quantity = 1
remedy tracking allocation = confirmed tracking allocation
remedy supplier line = confirmed supplier line
remedy dispute line = confirmed dispute line
tracking allocation order = confirmed order
tracking allocation supplier line = confirmed supplier line
tracking qty_allocated = 1
tracking adjusted_net_value_gbp = 60.00
dispute desired_outcome = replacement
dispute order = confirmed order
dispute replacement_child_order_id IS NULL
dispute resolved_at IS NULL
dispute line belongs to confirmed dispute
dispute line physical remedy allocation = confirmed remedy
dispute line resolved_via_child_order_id IS NULL
dispute line resolved_at IS NULL
no order exists with replacement_source_dispute_line_id = confirmed dispute line
remedy replacement_child_order_id IS NULL
remedy customer_commercial_value_gbp IS NULL
dispute-line amount_impact_gbp = 0.00
dispute-header amount_impact_gbp = 0.00
exactly one dispute line belongs to the replacement dispute
```

### 16.3 Repair

Under row locks, atomically write:

```text
remedy customer commercial value = 60.00
dispute-line amount = 60.00
dispute-header amount = 60.00
```

### 16.4 Idempotent rerun state

If all identities still match and all three amounts are already exactly `60.00`, the migration may emit an already-repaired notice and continue.

Any state other than the exact broken state or exact already-repaired state is a hard failure.

Do not reverse this data repair merely because a later application deployment is rolled back. Restoring null/zero would reintroduce the proven defect.

## 17. Migration C: replacement original-item return adapters

Reuse:

```text
dispute_return_tracking_submissions
shipper_return_task_confirmations
```

Do not create a replacement-specific return table, status family or supervisor queue.

Existing refund functions remain unchanged.

### 17.1 Shared pending-confirmation invariant

Before creating a new partial unique index, verify there is no existing return-tracking submission with more than one confirmation in `pending_review`.

Then add an index with this invariant:

```text
one pending shipper confirmation per return-tracking submission
```

Recommended identity:

```sql
CREATE UNIQUE INDEX uq_shipper_return_task_one_pending_v1
ON public.shipper_return_task_confirmations(return_tracking_submission_id)
WHERE review_status = 'pending_review';
```

If that index name already exists, inspect it and require exact equivalence. Do not replace an unexpected object.

This enforces the intention already present in the existing v1 function without changing the function.

## 18. New operator replacement-return RPC

Add:

```text
operator_submit_replacement_return_collection_tracking_v1(
  p_dispute_id uuid,
  p_courier_id uuid DEFAULT NULL,
  p_tracking_ref text DEFAULT NULL,
  p_tracking_date date DEFAULT NULL,
  p_tracking_evidence_url text DEFAULT NULL,
  p_is_final_return_yn boolean DEFAULT false,
  p_retailer_return_instructions_file_url text DEFAULT NULL,
  p_return_label_file_url text DEFAULT NULL,
  p_return_proof_file_url text DEFAULT NULL,
  p_note text DEFAULT NULL
)
RETURNS jsonb
```

Use `SECURITY DEFINER` and the existing governed search path.

### 18.1 Authentication and tenant access

Require:

- `auth.uid()`;
- an active operator account;
- an active non-revoked `operator_importers` relationship to the parent order importer;
- an existing replacement dispute.

Lock the dispute row `FOR UPDATE` before lifecycle validation.

### 18.2 Lifecycle

New replacement return instructions may be created only while:

```text
disputes.replacement_child_order_id IS NULL
disputes.resolved_at IS NULL
```

Require at least one retailer reply message for the dispute.

Require every active dispute line to have:

```text
conversation_status = retailer_response_received
```

Require exactly one active physical remedy-linked dispute line and no mixed legacy line.

This deliberately allows the operator to record instructions after retailer response and before final replacement acceptance.

The existing replacement acceptance function also locks the dispute. Therefore a concurrent operator submission and final acceptance serialize: either the return instructions commit first, or the operator submission sees the child/resolved state and fails.

### 18.3 Physical eligibility

Resolve:

```text
dispute line
-> physical remedy allocation
-> receipt line disposition
```

Require:

```text
dispute desired_outcome = replacement
dispute-line intended_remedy = replacement
physical remedy approved type = replacement
physical remedy dispute line = exact dispute line
physical disposition = damaged or wrong
```

Reject:

```text
missing
clean
held
non-physical legacy replacement lines
```

### 18.4 Actionable shipper information

Require at least one of:

```text
retailer return-instructions file
return-label file
tracking or collection reference
tracking-evidence URL
meaningful note
```

Courier, date and operator return-proof file may supplement those fields but cannot be the only information, because they do not satisfy the existing shipper task visibility predicate.

If `p_is_final_return_yn = true`, also require:

```text
valid courier
tracking or collection reference
tracking or collection date
```

If a courier ID is supplied, it must identify an existing courier.

### 18.5 Write and return

Insert one row into `dispute_return_tracking_submissions` with:

```text
dispute_id = exact replacement dispute
submitted_by_operator_id = active operator
review_status = pending_review
```

Write no dispute message through the existing refund-only compatibility policy. The structured row is authoritative.

Do not change:

- dispute status;
- dispute-line status;
- physical-remedy status;
- replacement-child state;
- refund state;
- accounting or settlement state.

Return at least:

```text
ok
return_tracking_submission_id
dispute_id
review_status
```

## 19. New shipper task reader

Add:

```text
shipper_return_tasks_v2()
```

It must return exactly the same column names, order and types as `shipper_return_tasks_v1()`:

```text
return_tracking_submission_id uuid
dispute_id uuid
order_id uuid
order_ref text
importer_name text
retailer_name text
courier_name text
tracking_ref text
tracking_date date
tracking_evidence_url text
retailer_return_instructions_file_url text
return_label_file_url text
operator_return_proof_file_url text
operator_note text
is_final_return_yn boolean
operator_review_status text
submitted_at timestamptz
affected_lines jsonb
latest_confirmation_id uuid
latest_shipper_outcome text
latest_shipper_proof_url text
latest_shipper_note text
latest_shipper_submitted_at timestamptz
latest_shipper_review_status text
latest_shipper_review_notes text
task_status text
```

### 19.1 Refund half

Return all rows from:

```text
shipper_return_tasks_v1()
```

Do not duplicate or reinterpret its refund conditions.

### 19.2 Replacement half before child creation

Include a replacement return submission when:

```text
order shipper = authenticated active shipper user's shipper
dispute desired_outcome = replacement
dispute unresolved
dispute replacement_child_order_id IS NULL
exact physical dispute line unresolved
physical remedy approved type = replacement
physical disposition = damaged or wrong
actionable shipper information exists
```

### 19.3 Replacement half after child creation

After child creation, do not require an unresolved dispute or unresolved dispute line.

Instead require exact equality:

```text
disputes.replacement_child_order_id
= physical_exception_remedy_allocations.replacement_child_order_id
= dispute_lines.resolved_via_child_order_id
```

Also require:

```text
physical remedy approved type = replacement
physical disposition = damaged or wrong
actionable shipper information exists
```

Exclude a resolved replacement dispute with no replacement child.

### 19.4 Task state

Use the latest confirmation by:

```text
submitted_at DESC
id DESC
```

Preserve the existing task-state mapping:

```text
no confirmation -> ready_to_action
pending_review -> submitted_for_review
accepted -> accepted
hold -> held_query
rejected -> ready_to_action
```

Globally order the refund and replacement union using the same priority as v1, followed by return-submission time descending.

Use the existing affected-line JSON shape and include resolved replacement source lines after child creation.

## 20. New shipper confirmation RPC

Add:

```text
shipper_submit_return_task_confirmation_v2(
  p_return_tracking_submission_id uuid,
  p_outcome text,
  p_proof_file_url text DEFAULT NULL,
  p_proof_url text DEFAULT NULL,
  p_note text DEFAULT NULL
)
RETURNS jsonb
```

### 20.1 Authentication and lock order

1. require `auth.uid()`;
2. resolve the active shipper user and shipper;
3. validate the requested outcome;
4. lock the exact `dispute_return_tracking_submissions` row `FOR UPDATE`;
5. resolve and lock the linked dispute/order context;
6. branch by dispute outcome.

The return-submission lock must be acquired before checking for a pending confirmation.

### 20.2 Refund branch

For a refund dispute, call:

```text
shipper_submit_return_task_confirmation_v1(...)
```

while the outer v2 transaction still holds the return-submission lock.

Do not change v1.

### 20.3 Replacement branch

Require:

- the order belongs to the authenticated shipper;
- the return row belongs to a replacement dispute;
- the exact physical source is damaged or wrong;
- before child creation, the physical line and dispute remain unresolved;
- after child creation, the exact child-provenance equality in section 19.3 holds;
- a resolved replacement dispute without a child is rejected;
- no pending confirmation exists for the return submission.

Allowed outcomes remain:

```text
collected
handed_to_courier
returned_to_retailer
unable_to_return
query
```

Insert into the existing `shipper_return_task_confirmations` table.

Return the same JSON shape as v1:

```text
ok
confirmation_id
return_tracking_submission_id
review_status = pending_review
```

The row lock plus the partial unique index prevents duplicate pending confirmations through the v2 application path and at database level.

## 21. Existing supervisor review path

Reuse unchanged:

```text
staff_review_return_collection_tracking(...)
staff_review_shipper_return_task_confirmation_v1(...)
internal_shipper_return_task_confirmations_v1(boolean)
```

The existing structured return-submission review and shipper-proof review remain separate controls.

Physical return proof remains separate from:

- supplier refund or credit-note evidence;
- DVA/card refund matching;
- customer settlement;
- replacement-child fulfilment.

## 22. Replacement sequencing

The original-item return is optional and parallel under this build.

Permitted sequence A:

```text
retailer accepts replacement
-> operator records return instructions
-> shipper returns original item
-> supervisor reviews proof
-> supervisor accepts replacement outcome
-> replacement child is created
```

Permitted sequence B:

```text
retailer accepts replacement
-> operator records return instructions
-> supervisor accepts replacement outcome
-> replacement child is created
-> original-item return remains open
-> shipper returns original item
-> supervisor reviews proof
```

Do not add a return-proof prerequisite to `staff_accept_replacement_outcome_v1`.

Making completed return proof mandatory before child creation is a different governed build because it requires a downstream acceptance gate. It is out of scope here.

## 23. Application changes

### 23.1 Importer/operator exception detail

Permitted files:

```text
app/importer/exceptions/[dispute_id]/page.tsx
app/importer/exceptions/[dispute_id]/actions.ts
```

Keep the existing refund return form and refund action unchanged.

Add a replacement original-item return form only when server-derived data proves:

```text
desired_outcome = replacement
exact physical disposition = damaged or wrong
retailer response accepted
replacement_child_order_id IS NULL
dispute unresolved
```

Label the form:

```text
Original damaged item return / collection
```

Do not label it as replacement delivery tracking.

Call:

```text
operator_submit_replacement_return_collection_tracking_v1
```

Use the existing upload/storage mechanisms. Do not create a replacement-only storage bucket.

### 23.2 Shipper return actions

Permitted file:

```text
app/shipper/return-actions/page.tsx
```

Change the reader call from:

```text
shipper_return_tasks_v1
```

only to:

```text
shipper_return_tasks_v2
```

Keep the existing filters, task cards, affected-line display, upload fields and proof form.

Update the introduction so it does not say every return action comes only from an approved refund exception.

When any affected line has `intended_remedy = replacement`, show:

```text
Original item return for replacement
```

Do not classify a missing replacement as a shipper return action.

### 23.3 Shipper submit action

Permitted file:

```text
app/shipper/actions.ts
```

Inside `submitReturnTaskConfirmationAction`, change only the RPC call from v1 to v2.

Do not change:

- upload behaviour;
- form parsing;
- outcome validation;
- redirects;
- cache revalidation;
- success/error presentation.

### 23.4 Internal supervisor exception detail

Permitted file:

```text
app/internal/exceptions/[dispute_id]/page.tsx
```

The structured return-review panel must render for:

```text
refund + awaiting_refund_credit
```

or:

```text
replacement + at least one structured return-tracking submission
```

For a replacement, keep the panel visible after child creation so the supervisor can review the outstanding original-item return.

Reuse the existing `reviewReturnCollectionEvidenceAction` unchanged.

Update explanatory copy so it describes operational return evidence and does not imply that the panel itself approves supplier refund value.

### 23.5 Physical review and exception labels

Permitted files:

```text
app/internal/physical-receipts/[review_id]/page.tsx
app/internal/exceptions/[dispute_id]/page.tsx
app/importer/exceptions/[dispute_id]/page.tsx
lib/exception-display.ts
```

Create one shared display helper.

Preferred display:

```text
Order: SEED-REPL-0C7952EE44
Dispute: SEED-REPL-0C7952EE44 · Replacement · D7B32314
```

The short token is the first eight uppercase characters of the dispute UUID and is presentation-only.

Keep full UUID primary keys, routes and foreign keys. Keep the full UUID available through details or copy controls.

Do not add a `dispute_ref` database column in this build.

## 24. Permissions and RLS

For each new RPC:

```sql
REVOKE ALL ON FUNCTION ... FROM PUBLIC;
REVOKE ALL ON FUNCTION ... FROM anon;
GRANT EXECUTE ON FUNCTION ... TO authenticated;
```

Grant `service_role` only when the exact current convention for the equivalent existing function requires it and the need is proven during preflight.

Every new `SECURITY DEFINER` function must perform its own actor, tenant and ownership checks.

Do not grant direct insert or update permission on the underlying return tables.

Do not widen current RLS unless an authenticated regression proves the validated RPC cannot operate. An RLS change requires separate explicit review and must not broaden direct ordinary-user writes.

The existing return-tracking read policy is already outcome-neutral for authorised staff and linked operators.

## 25. Required implementation files

The governed implementation is limited to:

### Database migrations

```text
one migration replacing the exact current supervisor v1 bridge
one exact-record repair migration
one replacement-return adapter migration
```

Migration filenames must use the next available repository timestamp at implementation time. Do not invent an earlier timestamp or reorder deployed history.

### New database objects

```text
operator_submit_replacement_return_collection_tracking_v1
shipper_return_tasks_v2
shipper_submit_return_task_confirmation_v2
uq_shipper_return_task_one_pending_v1
```

### Existing database object deliberately replaced

```text
staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text)
```

### Application files

Only the files listed in section 23, plus tests and implementation documentation.

Any change outside this manifest requires explicit senior review before implementation continues.

## 26. Required database regressions

All database regressions must run inside transactions and end with `ROLLBACK` unless they are validating an already-applied migration in an isolated environment.

### 26.1 Six-unit split

Fixture:

```text
6 allocated units
3 clean
2 refund
1 replacement
```

Assert:

- the clean quantity remains outside disputes;
- the refund quantities enter only refund disputes;
- the replacement quantity enters only a replacement dispute;
- review/dispute links include every created dispute;
- no quantity is duplicated or lost;
- the compatibility primary link is deterministic.

### 26.2 Same-invoice, same-issue refund

```text
2 refund allocations
same original supplier invoice
same issue type
```

Assert:

```text
1 refund dispute
2 exact dispute lines
header amount = line sum
```

### 26.3 Different-invoice refund

```text
2 refund allocations
different original supplier invoices
```

Assert:

```text
2 refund disputes
one supplier-invoice identity per dispute
```

### 26.4 Same-invoice, different-issue refund

```text
1 missing refund allocation
1 damaged refund allocation
same supplier invoice
```

Assert:

```text
2 refund disputes
truthful issue type on each header
```

### 26.5 Multiple replacements

```text
2 distinct replacement remedy allocations
```

Assert:

```text
2 replacement disputes
1 physical dispute line per dispute
```

Both disputes must remain acceptable by the unchanged replacement finalisation authority.

### 26.6 Multi-unit replacement

```text
1 replacement remedy allocation
approved quantity = 3
```

Assert:

```text
1 replacement dispute
1 dispute line
qty_impact = 3
```

### 26.7 Penny apportionment

Use values and quantities that produce repeating decimals and a non-zero residual.

Assert:

- deterministic repeated output;
- exact two-decimal remedy values;
- exact source-total reconciliation including the synthetic remainder;
- no penny is created or lost;
- allocation, line and header values agree;
- a zero-value remedy fails closed.

### 26.8 Existing refund non-regression

Run an established refund through:

```text
retailer reply
-> final refund acceptance
-> awaiting_refund_credit
-> operator refund evidence
-> expected amount balance
```

Compare status, expected amount and evidence behaviour with the pre-change baseline.

### 26.9 Existing missing replacement non-regression

Run a missing physical item through:

```text
replacement dispute
-> retailer reply
-> final replacement acceptance
-> replacement child
```

Assert:

- no return action is created;
- child quantity is exact;
- child commercial value is exact;
- existing replacement functions are unchanged.

### 26.10 Damaged replacement return

Run:

```text
damaged physical item
-> replacement dispute
-> retailer response accepted
-> operator return instructions
-> shipper v2 task visible
-> shipper confirmation
-> supervisor return-proof review
```

Also create the replacement child after operator instructions and before shipper confirmation.

Assert the task remains visible through exact child provenance and can still be confirmed and reviewed.

### 26.11 Wrong-item replacement return

Repeat the replacement return test for a `wrong` disposition.

### 26.12 Missing-item rejection

Assert the replacement operator RPC rejects a missing disposition and no return row is inserted.

### 26.13 Actionable-information rejection

Assert the operator RPC rejects:

- courier only;
- date only;
- operator proof file only.

Assert it accepts a meaningful note or any other shipper-visible actionable field.

### 26.14 Concurrency

Test concurrent:

```text
operator replacement-return submission
versus
staff replacement final acceptance
```

The result must serialize on the dispute row. It must never create a new return instruction after child creation.

Test two concurrent shipper confirmations. The database must contain at most one pending confirmation for the return submission.

### 26.15 Security

Assert:

- anonymous calls fail;
- inactive actors fail;
- an operator without importer access fails;
- a shipper cannot read or confirm another shipper's task;
- the replacement RPC rejects refund disputes;
- ordinary staff cannot perform supervisor reviews;
- no direct table-write permission is opened.

## 27. Required source and application regressions

Add source tests that prove:

- the application still calls `staff_decide_physical_receipt_review_v2` rather than v1;
- the shipper page calls `shipper_return_tasks_v2`;
- the shipper action calls `shipper_submit_return_task_confirmation_v2`;
- the existing refund operator action still calls the existing refund RPC;
- the internal supervisor return panel supports replacement records;
- no protected function source is altered by the new migration;
- readable references do not replace UUID routes.

Run:

- repository source regressions;
- TypeScript type checking;
- production build;
- authenticated browser acceptance for importer/operator, shipper and supervisor roles.

## 28. Fingerprint release gate

Before and after deployment, compare definition, owner, ACL, security mode and relevant configuration for:

```text
staff_decide_physical_receipt_review_v2(...)
staff_accept_replacement_outcome_v1(uuid,uuid,text)
create_replacement_child_order_v2(uuid,uuid,uuid,text)
operator_submit_refund_document_evidence(...)
operator_submit_return_collection_tracking(...)
shipper_return_tasks_v1()
shipper_submit_return_task_confirmation_v1(...)
staff_review_return_collection_tracking(...)
staff_review_shipper_return_task_confirmation_v1(...)
internal_shipper_return_task_confirmations_v1(boolean)
physical_remedy_allocation_guard_v2()
physical_remedy_sequence_guard_v1()
physical_receipt_review_guard_v1()
```

Also compare all relevant physical-remedy and review trigger bindings.

They must remain unchanged.

For the deliberately replaced v1 bridge, assert:

- the exact new audited definition is installed;
- it remains `SECURITY DEFINER`;
- ordinary authenticated users cannot execute it directly;
- the v2 gateway remains the application entry;
- the exact monetary and partitioning markers are present;
- `LINK_SHAPE_SEQUENCE_V1` remains present.

## 29. Deployment order

1. create an implementation branch from the verified baseline;
2. fetch the exact current live function definitions, owners, ACLs and trigger bindings;
3. freeze and review those fingerprints in the migration preflight;
4. implement Migration A;
5. run bridge, monetary, partitioning and downstream non-regression tests;
6. implement Migration B;
7. verify the exact GBP 60 record;
8. implement Migration C;
9. run replacement-return, security and concurrency tests;
10. implement the minimal application patch;
11. run source tests, type checking and production build;
12. run authenticated browser acceptance;
13. recheck every protected fingerprint;
14. merge only when every gate passes.

Any failure stops deployment.

## 30. Rollback and compatibility

Migration A must retain the exact prior v1 definition in implementation review material so an explicit later rollback migration can restore it if required. Do not edit the applied repair migration.

Migration C is backward-compatible because existing refund v1 functions remain installed and unchanged. An older application can continue calling v1.

The exact GBP 60 data repair is a correction of proven data. Do not automatically revert it during an application rollback.

Do not drop v2 replacement-return RPCs merely because the application is rolled back. They may remain unused until the application is redeployed.

## 31. Stop conditions

Implementation must stop instead of improvising when any of the following occurs:

- live function definition differs from the reviewed fingerprint;
- a protected function or trigger binding has drifted;
- a named column or relation does not exist;
- the exact tracking allocation cannot be proven;
- supplier invoice identity cannot be proven;
- customer commercial value is null or non-positive;
- quantity does not reconcile;
- an existing unresolved legacy exception creates ambiguous provenance;
- the confirmed GBP 60 record differs from both the exact broken and exact repaired states;
- existing pending shipper confirmations violate the proposed unique invariant;
- application source has moved so the listed minimal patch no longer applies cleanly;
- any existing refund or replacement regression changes behaviour.

The builder must report the exact mismatch and obtain an updated governing decision.

## 32. Non-goals

This build does not create or change:

- a second physical receipt workflow;
- a second retailer conversation;
- a second refund route;
- a second replacement route;
- a second return-action table family;
- a replacement-of-a-replacement route;
- a return-proof prerequisite for child creation;
- supplier credit or refund accounting;
- DVA/card matching;
- customer payout or credit;
- customer credit-note treatment;
- VAT timing;
- Sage posting;
- supplier AP;
- shipping AP;
- funding or treasury gates;
- settlement or closure authorities;
- UUID data identity.

## 33. Final acceptance criteria

The build is accepted only when all of the following are true:

```text
physical refund/replacement disputes no longer receive an unknown GBP 0 value;

one package can contain clean, refund and replacement quantities;

clean quantity remains in the existing clean route;

refund disputes contain only one original supplier invoice and one issue type;

each distinct physical replacement allocation produces one downstream-compatible replacement dispute;

approved remedy quantity and value retain exact source provenance;

allocation value equals linked dispute-line value;

dispute header equals its active line sum;

penny allocation reconciles exactly to the tracking allocation value;

the confirmed record is GBP 60 on allocation, line and header;

the existing refund route behaves exactly as before;

the existing replacement-child route behaves exactly as before;

missing replacements do not create return actions;

damaged and wrong replacements may reuse the existing return-action records;

replacement return actions remain operable after child creation through exact child provenance;

supervisors can review replacement return submissions and shipper proof through existing review authorities;

no parallel return, refund, replacement, accounting or settlement workflow exists;

protected definitions, grants and trigger bindings remain unchanged;

UUIDs remain internal authorities while users receive readable display references.
```

## 34. Locked implementation instruction

The approved implementation scope is exactly:

```text
one corrected physical supervisor bridge
+ one exact guarded GBP 60 data repair
+ one pending-confirmation uniqueness invariant
+ three additive replacement-return RPCs
+ minimal operator, shipper and supervisor UI wiring
+ readable display references
+ database, source, security, concurrency and browser regressions
```

A builder, including Codex, must implement this document exactly and must not broaden the scope merely to simplify coding.

Merge is prohibited unless every preflight, fingerprint, monetary, quantity, partitioning, security, concurrency and existing-route regression passes.