# Hybrid Physical Receipt Same-Order Free Replacement Routing Addendum v1.3

**Status:** governing corrective addendum

**Effective date:** 17 August 2026

**Applies to:** `HYBRID_PHYSICAL_RECEIPT_SAME_ORDER_FREE_REPLACEMENT_ROUTING_ADDENDUM_v1.md`, `HYBRID_PHYSICAL_RECEIPT_SAME_ORDER_FREE_REPLACEMENT_ROUTING_ADDENDUM_v1_1.md`, and `HYBRID_PHYSICAL_RECEIPT_SAME_ORDER_FREE_REPLACEMENT_ROUTING_ADDENDUM_v1_2.md`

**Verified pre-correction application baseline:** `36dd8e3a84844759049e9ce0adfeb3ed93b4777f`

**Current corrected main baseline:** `b35c256653847369820276fb4656fd26b54087b9`

## 1. Purpose

This addendum locks the corrective objective to one thing only:

```text
supervisor accepts a replacement
-> existing same-order replacement authority
-> existing tested same-order replacement path
```

The supervisor acceptance action must never call the legacy child-order replacement authority and must never create or fall back to a replacement child order.

This addendum does not authorise a new replacement workflow, a new importer handoff, a new page mode, new routing, new filtering, new navigation, or any redesign of the already-tested replacement path.

## 2. Governing rule

The already-built and tested same-order replacement path is frozen and must be reused exactly.

The correction is only:

```text
wrong supervisor acceptance RPC
-> correct existing same-order RPC
```

The downstream tested path is not to be rebuilt, moved, reconnected, duplicated, or modified to compensate for the RPC correction.

If the existing tested path does not behave as expected after the correct RPC is used, stop and diagnose the exact data/API/state failure before changing code.

No inference is sufficient authority for a code change.

## 3. Correct supervisor acceptance authority

Within:

```text
app/internal/exceptions/[dispute_id]/actions.ts
```

inside:

```text
acceptReplacementOutcomeAction()
```

the only permitted replacement-acceptance RPC is:

```text
staff_accept_same_order_free_replacement_v1
```

called with:

```text
p_dispute_id := disputeId
p_staff_id := guard.staffId
p_confirmed_supplier_cost_mode := 'free_replacement'
p_notes := 'Final replacement outcome accepted by supervisor'
```

The returned UUID is a same-order replacement route ID.

It must never be interpreted as a child order ID.

## 4. Absolute child-order prohibition

`acceptReplacementOutcomeAction()` must contain zero invocations of:

```text
staff_accept_replacement_outcome_v1
create_replacement_child_order_v2
```

It must contain no:

```text
child-order fallback
legacy retry branch
alternate child-order branch
child-order creation
child-order link creation
child-order operations revalidation using the returned route UUID
```

If `staff_accept_same_order_free_replacement_v1` rejects the acceptance, surface the error and stop.

A same-order rejection must never be converted into a child order.

Historical child-order functions and records remain installed and unchanged for compatibility only. They are not part of this supervisor acceptance path.

## 5. Correct revalidation semantics

After successful same-order acceptance, the existing non-child revalidations are permitted:

```text
/internal/exceptions/{disputeId}
/importer/exceptions/{disputeId}
/importer
```

The following child-order revalidation is prohibited:

```text
/importer/orders/{childOrderId}/operations
```

because the acceptance RPC no longer returns a child order ID.

`revalidatePath` invalidates cached route data. It does not create navigation and it must not be used as a substitute for a workflow handoff.

## 6. Frozen tested downstream implementation

The following files are verified as byte-identical between the pre-correction baseline `36dd8e3a84844759049e9ce0adfeb3ed93b4777f` and corrected `main` at `b35c256653847369820276fb4656fd26b54087b9` and are therefore frozen for this correction:

```text
app/importer/ReplacementOrdersPanel.tsx
app/importer/replacement-orders-data/route.ts
app/importer/exceptions/[dispute_id]/layout.tsx
```

They must not be edited as part of this correction.

In particular, do not:

```text
add a disputeId prop or dispute-scoped mode
render ReplacementOrdersPanel on the exception detail page
add new filtering
add a new importer handoff
change the existing /importer pathname gate
change allocation mechanics
change the replacement API
change tracking-submission loading
change replacement progress rendering
```

Any proposal to alter one of these files requires a separate governing decision based on a proved defect in that exact file.

## 7. Existing tested same-order continuation

The existing tested continuation remains:

```text
staff_accept_same_order_free_replacement_v1
-> physical_replacement_same_order_routes
-> route_status = approved_waiting_tracking
-> existing /importer Replacement tracking handoff
```

The existing `/importer` handoff:

```text
reads physical_replacement_same_order_routes
reads active order_tracking_submissions for the original order
allows the approved same-order route to be attached to an existing tracking submission
posts to /importer/replacement-orders-data
calls operator_allocate_same_order_replacement_tracking_v1
```

If the original order has no active tracking submission, the existing handoff links to the original order Operations page so the tracking submission can be added there first.

The continuation remains on the original order. No child order is created.

After allocation, the existing tested route continues through the already-built replacement progress, receipt, shipment-eligibility and shipment path.

## 8. Protected downstream authorities

Do not change:

```text
operator_allocate_same_order_replacement_tracking_v1
staff_accept_same_order_free_replacement_v1
physical_replacement_same_order_routes
ReplacementOrdersPanel.tsx
replacement-orders-data/route.ts
importer exception layout replacement progress logic
original-order tracking submission flow
physical receipt authorities
shipment eligibility
shipment membership
```

No wrapper, replacement RPC version, duplicate route, or TypeScript reimplementation is authorised.

## 9. Presentation changes are not part of this correction

The wording changes already merged in v1.2 are not the mechanism that connects the accepted replacement to the tested handoff.

This v1.3 does not authorise further wording, layout, label, colour, navigation, component, or status-presentation changes.

Do not reverse or add presentation changes as part of this correction unless a separate governing decision explicitly authorises them.

## 10. Explicit rejection of the abandoned reconnect approach

The approach represented by PR #276, `Reconnect accepted replacement to tested same-order handoff`, is not an authorised implementation of this addendum.

Specifically rejected:

```text
adding a dispute-scoped ReplacementOrdersPanel mode
rendering that panel directly on importer exception detail
introducing a new exception-page handoff presentation
```

The existing tested `/importer` handoff is the governing path.

## 11. Database and migration prohibition

No changes are authorised to:

```text
database schema
migrations
RLS
policies
grants
triggers
indexes
existing RPC definitions
historical child-order data
```

No SQL migration is required by this addendum.

## 12. Other explicit non-scope

Do not change:

```text
refunds
credit notes
supplier invoices
reconciliation
DVA/card funding
supplier AP
shipping AP
customer review
holds
customer release
Sage
VAT
accounting closure
authentication
permissions
navigation outside the existing tested replacement flow
```

## 13. Mandatory evidence-before-change rule

Before any additional production code is changed, prove all of the following from the current repository and controlled test state:

```text
which exact file is wrong
which exact line/condition is wrong
how it differs from the tested baseline
why that exact difference prevents the tested path from working
```

If that proof does not exist, no production change is authorised.

Whole-file restoration, whole-page replacement, speculative reconnects, redesigns, and inferred fixes are prohibited.

Any permitted correction must be a line-level/hunk-level change only.

## 14. Required validation

For one controlled eligible replacement acceptance, prove:

```text
staff_accept_same_order_free_replacement_v1 is called
staff_accept_replacement_outcome_v1 is not called
create_replacement_child_order_v2 is not called
one same-order route is created
route_status = approved_waiting_tracking
disputes.replacement_child_order_id remains null
dispute_lines.resolved_via_child_order_id remains null
replacement-child-order population does not increase
```

Then prove the existing tested `/importer` handoff sees that exact route.

Continue through the existing tested flow:

```text
tracking submission on original order
-> operator_allocate_same_order_replacement_tracking_v1
-> tracking_allocated
-> existing replacement receipt/progress path
-> shipment eligibility
-> shipment
```

No substitute path counts as a pass.

## 15. Scope ceiling

Under this addendum, the intended production-code change is already represented by the corrected supervisor acceptance RPC wiring on current `main`.

No additional production-code change is authorised unless section 13 first proves a specific remaining regression.

If such proof exists, the new production diff must be limited to the exact line/hunk responsible for that proved regression.

Any change to more than one additional production file requires a new governing decision before implementation.

## 16. Acceptance criterion

The correction is complete only when it can be stated truthfully:

> The supervisor acceptance action uses only the existing same-order replacement authority, never creates or falls back to a child order, and the resulting route continues through the already-built and tested same-order replacement path without any redesign or downstream code change.
