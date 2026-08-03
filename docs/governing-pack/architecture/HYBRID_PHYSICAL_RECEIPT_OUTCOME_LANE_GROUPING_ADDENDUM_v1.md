# Hybrid Physical Receipt Outcome Lane Grouping Addendum v1

**Status:** governing technical specification and implementation authority  
**Effective date:** 3 August 2026  
**Applies with:** Hybrid Physical Receipt quantity/remedy addenda, implementation alignment v1.2, and Same-Order Free Replacement Routing Addenda v1 and v1.1.

## 1. Purpose

This addendum governs how several affected quantities on one order are presented and resolved operationally when the approved outcomes include refunds, replacements, or both.

The system must preserve exact line-level quantity, value, evidence, supplier-invoice-line identity and audit records underneath, while avoiding a fragmented operator workflow.

The locked model is:

```text
one order/review case
├── one refund lane when at least one approved refund remedy exists
└── one replacement lane when at least one approved replacement remedy exists
```

Refund and replacement lanes must never be merged into one outcome lane.

Within each lane, several exact remedy allocations may be handled together through one grouped operator action.

## 2. Business examples

### 2.1 One supplier line, multiple affected units

```text
supplier line quantity: 4
clean quantity: 2
replacement quantity: 2
```

Required result:

```text
one replacement lane
one exact replacement remedy allocation with quantity 2
one same-order route with replacement quantity 2
```

The system must not split quantity 2 into two operational exceptions unless two distinct source identities require it.

### 2.2 Several supplier lines with the same outcome

```text
line A: quantity 1 replacement
line B: quantity 1 replacement
```

Required result:

```text
one replacement lane containing two exact line remedies
one grouped retailer update and one grouped supervisor acceptance action may cover both
one replacement confirmation may be associated with both
one tracking reference may carry two successor allocations
```

The underlying records remain separate by remedy, source allocation and supplier-invoice line.

### 2.3 Mixed outcomes

```text
line A: clean
line B: refund
line C: replacement
```

Required result:

```text
clean quantity continues through the existing clean path
one refund lane for line B
one replacement lane for line C
```

### 2.4 Six-item example

```text
two clean
two refund
two replacement
```

Required operator experience:

```text
one case view
one refund-lane action for the two refund quantities
one replacement-lane action for the two replacement quantities
```

The operator must not be forced through four separate exception journeys merely because four exact remedy allocations exist.

## 3. Locked terminology

### 3.1 Case

A case is the order/review-level operational workspace that contains all exact physical outcome records created from the same approved physical receipt review.

### 3.2 Outcome lane

An outcome lane is an operational grouping by final remedy outcome:

```text
refund
replacement
```

A lane is not an accounting aggregation and is not a substitute for exact remedy, dispute-line, source-allocation or supplier-line records.

### 3.3 Lane item

A lane item is one exact approved physical remedy allocation and its linked quantity/value/provenance.

A lane item may represent quantity greater than one where the exact source allocation and supplier line are identical.

## 4. Non-negotiable grouping rules

The grouping key must include at minimum:

```text
order_id
physical_receipt_review_id
approved_remedy_type
```

Refund and replacement must be separate lanes even when they originate from the same review, retailer reply, email thread or evidence submission.

A lane may contain:

- one remedy allocation with quantity greater than one;
- several remedy allocations on several supplier-invoice lines;
- several supplier invoices belonging to the same original order;
- several source tracking allocations;
- several dispute lines.

A lane must never combine records from different orders.

## 5. Exact line-level authority remains mandatory

Every lane item must retain its own exact:

```text
physical_remedy_allocation_id
physical_receipt_review_id
dispute_id and dispute_line_id, where applicable
supplier_invoice_line_id
source_tracking_line_allocation_id
source_receipt_line_disposition_id
approved quantity
customer commercial value
supplier cost mode
replacement route identity, where applicable
refund evidence and settlement identity, where applicable
```

Grouped operator actions must fan out atomically to exact records. They must not collapse several supplier lines into one accounting line or one undifferentiated remedy row.

## 6. Operational workload requirement

The importer must be able to resolve all items in one outcome lane through one grouped action.

Examples:

```text
one retailer message applies to two replacement lane items;
one credit note applies to two refund lane items;
one replacement confirmation applies to two replacement lane items;
one collection reference applies to several replacement lane items;
one tracking reference applies to several replacement lane items.
```

The system may still create several exact child records underneath. It must not require repeated entry of identical retailer text, evidence metadata, collection data or tracking data for every lane item.

## 7. Evidence reuse rules

Evidence reuse is allowed only when the user explicitly selects the lane items covered by that evidence.

One evidence object may be linked to several lane items when all of the following are true:

```text
same order;
same outcome lane;
explicit selected item IDs;
evidence truthfully covers every selected quantity;
no selected item already has conflicting final evidence;
actor has authority for every selected item.
```

Evidence reuse must create explicit many-to-many links or equivalent exact item references. Copying the same storage path into several unrelated rows without a governed link is prohibited.

Refund evidence must not satisfy replacement requirements. Replacement confirmation, collection or tracking evidence must not satisfy refund requirements.

## 8. Retailer communication grouping

A single retailer communication may apply to several items in one lane and, when explicitly selected, to both lanes in the same case.

However, final outcome acceptance remains lane-specific:

```text
refund acceptance updates only selected refund items;
replacement acceptance updates only selected replacement items.
```

The communication record must store the exact selected lane-item IDs or exact linked dispute-line IDs.

A shared email thread does not merge the two outcome lanes.

## 9. Required additive data model

Implementation must be additive and must not alter Mini Builds 1-4.

Add an outcome-lane sidecar model equivalent to:

```text
physical_receipt_outcome_lanes
- id uuid primary key
- order_id uuid not null
- physical_receipt_review_id uuid not null
- outcome_type text not null check in ('refund','replacement')
- lane_status text not null
- created_at timestamptz not null
- updated_at timestamptz not null
- unique (physical_receipt_review_id, outcome_type)
```

And an exact membership model equivalent to:

```text
physical_receipt_outcome_lane_items
- lane_id uuid not null
- physical_remedy_allocation_id uuid not null unique
- dispute_id uuid null
- dispute_line_id uuid null unique
- added_at timestamptz not null
- primary key (lane_id, physical_remedy_allocation_id)
```

Evidence association must use an additive exact-link model equivalent to:

```text
physical_receipt_outcome_evidence_links
- evidence_id uuid not null
- lane_id uuid not null
- physical_remedy_allocation_id uuid not null
- evidence_role text not null
- linked_by_actor_type text not null
- linked_by_actor_id uuid not null
- linked_at timestamptz not null
- primary key (evidence_id, physical_remedy_allocation_id, evidence_role)
```

Exact table names may differ only if the implementation preflight proves an existing additive table already provides the same governed identity and constraints.

## 10. Grouped importer update authority

Add a versioned authority equivalent to:

```text
operator_record_physical_outcome_lane_update_v1(
  p_lane_id uuid,
  p_remedy_allocation_ids uuid[],
  p_update_text text,
  p_retailer_response_classification text,
  p_evidence_ids uuid[] default null,
  p_note text default null
)
returns jsonb
```

It must:

1. authenticate an active operator with access to the order importer;
2. reject empty or duplicate remedy IDs;
3. lock the lane and selected remedy/dispute rows in deterministic UUID order;
4. require every selected item to belong to the lane;
5. require every selected item to remain open for that update;
6. write one grouped communication/update record;
7. link that update explicitly to every selected item;
8. link selected evidence explicitly to every selected item;
9. transition only the selected exact items;
10. return all updated item IDs;
11. roll back the entire action on any mismatch.

The function must not silently update unselected lane items.

## 11. Grouped supervisor decision authority

Add a versioned authority equivalent to:

```text
staff_decide_physical_outcome_lane_v1(
  p_lane_id uuid,
  p_staff_id uuid,
  p_item_decisions jsonb,
  p_note text default null
)
returns jsonb
```

Each `p_item_decisions` element must identify one exact remedy allocation and its final approved lane-specific decision.

The function must:

- authenticate active supervisor/admin authority;
- lock every selected item deterministically;
- require all selected items to belong to the same lane;
- reject mixed refund/replacement decisions inside one call;
- support one item or several items;
- invoke or reproduce only the approved additive lane-specific child-free authorities;
- return exact created refund/replacement route IDs and item statuses;
- roll back all selected decisions if one item fails.

For replacements, no child order may be created.

For refunds, the existing refund settlement/accounting path remains authoritative and must not be merged with replacement tracking.

## 12. Replacement lane technical requirements

The replacement lane must support both:

```text
one remedy allocation with approved quantity > 1
and
several remedy allocations across several supplier-invoice lines
```

Final replacement acceptance may create one exact same-order route per remedy allocation.

Several routes may then be passed together to:

```text
operator_allocate_same_order_replacement_tracking_v1(
  p_order_id,
  p_tracking_submission_id,
  p_route_ids,
  p_note
)
```

One tracking submission may therefore carry several exact successor allocations.

Collection-only, tracking-only, and collection-plus-tracking states must be represented explicitly. A collection reference is not a tracking reference and must not be stored as one.

## 13. Refund lane technical requirements

The refund lane may contain several exact refund remedy allocations.

One credit note or retailer refund document may cover several selected refund items, but each item must retain its own exact quantity and commercial value.

The refund lane must continue through the existing refund, settlement-credit, accounting, VAT and reconciliation authorities.

No replacement route or successor tracking allocation may be created for refund lane items.

## 14. Lane status model

Recommended persisted lane statuses are:

```text
open
retailer_contacted
retailer_response_partial
retailer_response_complete
awaiting_supervisor_decision
partially_resolved
resolved
cancelled
```

Lane status must be derived or recomputed from exact item states where practical.

A lane is `resolved` only when every lane item is terminal in the correct outcome path.

A case may remain partially resolved when one lane is complete and the other is not.

## 15. Idempotency and concurrency

Grouped actions must be safe against duplicate submissions and concurrent operators.

Required controls:

- deterministic row locking;
- duplicate item-array rejection;
- exact item membership checks;
- unique evidence-item links;
- no second active same-order route for one remedy;
- no second final refund consumption for one remedy;
- idempotency token or exact duplicate-detection for browser retries;
- atomic rollback if any selected item is invalid.

Partial success inside one submitted grouped action is prohibited unless the user explicitly submitted separate lane actions.

## 16. UI contract

The operational UI must present:

```text
one order/review case header
clean quantities as existing fulfilment information
one refund lane card when required
one replacement lane card when required
exact item rows within each lane
select-all and selected-item grouped actions within a lane
shared evidence entry once, with explicit selected-item coverage
```

The UI must not display one separate top-level exception card per remedy when those remedies belong to the same order/review/outcome lane.

The UI must show partial coverage clearly. Example:

```text
refund lane: 2 of 2 items covered by credit note
replacement lane: 1 of 2 confirmed, 0 of 2 tracked
```

## 17. Migration and compatibility boundary

This build must:

- use later additive migrations;
- preserve historical migrations;
- preserve legacy child-order replacement behaviour;
- preserve Mini Builds 1-4 definitions, triggers, grants, owners, RLS and lifecycle rules;
- preserve exact existing dispute, remedy, refund, tracking and accounting records;
- add grouping sidecars and versioned grouped authorities only.

Existing per-remedy disputes may remain as exact backend records for compatibility, but they must be grouped into one operational lane and must not force repeated user entry.

A later approved migration may introduce a shared order-level dispute container only after a complete call-graph and constraint preflight. This addendum does not authorize destructive consolidation of existing dispute records.

## 18. Mandatory regressions before merge

Prove all of the following in rollback tests:

1. one supplier line with quantity 2 replacement creates one lane item and one route for quantity 2;
2. two replacement lines create one replacement lane with two exact items;
3. both replacement routes can be accepted through one grouped decision and allocated to one tracking submission atomically;
4. two refund lines create one refund lane with two exact items;
5. one credit note can be explicitly linked to both refund items;
6. refund and replacement items from one review create two separate lanes;
7. one retailer communication may be linked to selected items without merging lane outcomes;
8. an invalid selected item rolls back the entire grouped action;
9. duplicate IDs and cross-order IDs are rejected;
10. no replacement child order or child link is created for new free replacements;
11. effective replacement quantity and value remain unchanged after multi-route tracking;
12. refund settlement/accounting remains unchanged;
13. Mini Builds 1-4 fingerprints and behaviour remain unchanged;
14. legacy child-order replacement cases remain unchanged;
15. UI/API result payloads return exact per-item outcomes and grouped lane status.

## 19. Final locked instruction

Build for operator sanity and exact audit simultaneously:

```text
group by outcome lane for workflow;
retain exact remedy records for control;
allow one grouped action per lane;
allow explicit evidence reuse within a lane;
never merge refund and replacement outcomes;
never create a new child order for governed free replacements;
never weaken Mini Builds 1-4.
```

Any implementation that creates one top-level operational exception per exact remedy without a grouped lane interface fails this addendum, even if the underlying line-level records are technically correct.
