# Hybrid Physical Receipt Same-Order Free Replacement Routing Addendum v1.2

**Status:** governing corrective addendum

**Effective date:** 17 August 2026

**Applies to:** `HYBRID_PHYSICAL_RECEIPT_SAME_ORDER_FREE_REPLACEMENT_ROUTING_ADDENDUM_v1.md` and `HYBRID_PHYSICAL_RECEIPT_SAME_ORDER_FREE_REPLACEMENT_ROUTING_ADDENDUM_v1_1.md`

**Verified repository baseline:** `main` at `36dd8e3a84844759049e9ce0adfeb3ed93b4777f`

## 1. Purpose

This correction governs one defect only:

`app/internal/exceptions/[dispute_id]/actions.ts` currently routes `acceptReplacementOutcomeAction()` to the legacy child-order acceptance authority.

That routing is prohibited for this supervisor replacement-acceptance action.

The already-built same-order replacement authority is the only permitted replacement-acceptance authority from this action.

This correction does not redesign replacement, physical receipt, tracking, shipment, reconciliation, accounting or any downstream flow.

## 2. Authority and precedence

This v1.2 correction is read with v1 and v1.1.

Where this document is more specific about `acceptReplacementOutcomeAction()`, this document controls.

For this action only, it supersedes the v1 section 20.1 branch:

```text
legacy manual replacement dispute
-> staff_accept_replacement_outcome_v1
```

There is no child-order fallback from `acceptReplacementOutcomeAction()` after this correction.

Historical child-order records and installed legacy child-order functions remain unchanged for compatibility. They are not deleted or rewritten by this correction.

## 3. Verified existing implementation

The live read-only preflight `SUPERVISOR_REPLACEMENT_RPC_ROUTING_PREFLIGHT_V1` returned no blockers and proved that:

```text
staff_accept_same_order_free_replacement_v1(uuid,uuid,text,text) exists
same-order authority md5 = 78e94d6d76bf1c160068a3fd97ae4a87
same-order authority is SECURITY DEFINER
same-order authority search_path = public, pg_temp
same-order authority does not call staff_accept_replacement_outcome_v1
same-order authority does not call create_replacement_child_order
same-order authority keeps replacement_child_order_id null
```

The preflight also showed existing successful same-order replacement records with a `physical_replacement_same_order_routes` row and no replacement child order.

The repository also already contains the grouped supervisor replacement implementation, which delegates replacement acceptance directly to:

```text
staff_accept_same_order_free_replacement_v1(
  dispute_id,
  staff_id,
  'free_replacement',
  note
)
```

That existing delegation pattern is the implementation pattern to reuse here. No new application routing model is introduced.

## 4. Locked functional change

Production functional scope is limited to:

```text
app/internal/exceptions/[dispute_id]/actions.ts
```

Inside that file, change only:

```text
acceptReplacementOutcomeAction()
```

Preserve every existing pre-acceptance guard unchanged, including:

```text
active staff authentication
replacement-outcome requirement
reconciliation-stage rejection
existing replacement-child rejection
retailer-message / accepted-outcome guard
```

After those existing guards pass, remove the current legacy child-order RPC call and call only:

```text
staff_accept_same_order_free_replacement_v1(
  p_dispute_id := disputeId,
  p_staff_id := guard.staffId,
  p_confirmed_supplier_cost_mode := 'free_replacement',
  p_notes := 'Final replacement outcome accepted by supervisor'
)
```

This is intentionally the same delegation pattern already used by the existing grouped supervisor replacement authority.

Do not add any new pre-routing database lookup, supplier-cost lookup, remedy lookup, branching model or duplicated replacement validation in TypeScript.

The existing same-order RPC remains responsible for its own authentication, physical-remedy identity, exact active-line requirements, retailer acceptance, remedy state, source provenance, quantity/value validation, locking, concurrency protection, route creation and child-null postconditions.

The returned UUID is a same-order replacement route ID.

It must never be interpreted as a child order ID.

## 5. Absolute child-order prohibition for this action

`acceptReplacementOutcomeAction()` must contain no invocation of:

```text
staff_accept_replacement_outcome_v1
create_replacement_child_order_v2
```

It must contain no fallback, alternate branch, retry branch or error-recovery branch that invokes a child-order authority.

If `staff_accept_same_order_free_replacement_v1` rejects the dispute for any reason, surface the returned error and stop.

A same-order rejection must never be converted into a child order.

The legacy child-order authority remains installed and unchanged, but it is not reachable from this supervisor action.

## 6. No duplicated application business logic

Do not add TypeScript logic for:

```text
supplier-cost reclassification
physical-remedy revalidation
quantity apportionment
value apportionment
source-allocation validation
source-disposition validation
remedy provenance validation
replacement-route uniqueness
locking
concurrency
supplier-line ownership
child-field nulling
route creation
```

Those controls remain inside the already-built database authority.

The application correction is only:

```text
wrong RPC -> correct existing RPC
```

## 7. Revalidation and success result

On successful same-order acceptance, preserve only these existing non-child revalidations:

```text
/internal/exceptions/{disputeId}
/importer/exceptions/{disputeId}
/importer
```

Remove the child-specific revalidation:

```text
/importer/orders/{childOrderId}/operations
```

because the returned UUID is a same-order route ID.

The action success message must no longer claim that a child order was created.

Use:

```text
Replacement accepted — awaiting successor tracking.
```

No new page, navigation path or replacement component is introduced.

## 8. Locked presentation alignment

Presentation correction is limited to these three existing files only:

```text
app/internal/exceptions/[dispute_id]/page.tsx
app/importer/exceptions/[dispute_id]/page.tsx
app/internal/exceptions/page.tsx
```

The only permitted presentation change is replacement terminal wording derived from the already-selected `replacement_child_order_id` fact.

Exact rules:

```text
replacement_child_order_id is not null
-> keep historical child-order wording

replacement_child_order_id is null on app/internal/exceptions/[dispute_id]/page.tsx
-> "Replacement accepted — same-order replacement."

replacement_child_order_id is null on app/internal/exceptions/page.tsx
-> "Replacement accepted — same-order replacement"

replacement_child_order_id is null on app/importer/exceptions/[dispute_id]/page.tsx
-> "Replacement accepted — awaiting successor tracking"
```

The importer detail already has the existing `ReplacementStatusEnhancer` which can advance that initial same-order wording as tracking progresses. Do not change that enhancer.

No other labels, layout, components, navigation, queries, status families, permissions or workflow behaviour may be changed in these three files.

No other presentation file is in scope.

## 9. Explicit non-scope

Do not change:

```text
staff_accept_same_order_free_replacement_v1
staff_accept_replacement_outcome_v1
create_replacement_child_order_v2
physical_replacement_same_order_routes schema or policies
staff_decide_physical_outcome_lane_v1
operator_allocate_same_order_replacement_tracking_v1
ReplacementStatusEnhancer
physical receipt authorities
customer review
holds
shipment selection or shipment membership
customer release
supplier invoice logic
refund logic
reconciliation
DVA/card funding
supplier AP
shipping AP
Sage
VAT
order accounting closure
Mini Builds 1-4
RLS
permissions
grants
existing migrations
legacy child-order records
```

No SQL migration is required.

## 10. Implementation scope ceiling

The implementation is rejected for scope creep if it:

```text
changes any database function
adds any migration
adds a replacement authority
adds a new database pre-read or routing branch to acceptReplacementOutcomeAction()
alters the existing importer same-order tracking handoff
alters ReplacementStatusEnhancer
alters receipt, shipment, reconciliation or accounting behaviour
changes Mini Build definitions
adds any child-order fallback
creates or links a replacement child from acceptReplacementOutcomeAction()
reimplements same-order validation in TypeScript
changes production files other than the one functional file and the three locked display-only files in section 8
```

The intended functional diff is one existing server action rewired from the wrong legacy authority to the already-built same-order authority.

The only additional permitted production edits are the three display-only wording corrections locked in section 8.

Any other production file requires a new governing decision before implementation.

## 11. Required regression proof before merge

Before merge, prove all of the following:

1. `acceptReplacementOutcomeAction()` contains zero references to `staff_accept_replacement_outcome_v1`;
2. `acceptReplacementOutcomeAction()` contains zero references to any child-order creator;
3. the action contains no newly-added database pre-read or replacement-routing branch;
4. the action calls `staff_accept_same_order_free_replacement_v1` using the existing grouped-authority call pattern;
5. one controlled eligible replacement acceptance creates one `physical_replacement_same_order_routes` row;
6. `disputes.replacement_child_order_id` remains null for that acceptance;
7. `dispute_lines.resolved_via_child_order_id` remains null for that acceptance;
8. the replacement-child-order population does not increase during the controlled acceptance;
9. the existing importer same-order successor-tracking handoff remains available after acceptance;
10. the same-order authority fingerprint remains `78e94d6d76bf1c160068a3fd97ae4a87`;
11. no protected Mini Build authority changes;
12. TypeScript/build checks pass for the touched application code;
13. the three locked presentation files follow the exact child-vs-same-order wording rules in section 8.

Any failing regression stops the merge. Do not fix a regression by changing downstream working parts without a new governing decision.

## 12. Existing incorrectly-created child record

This correction is forward-looking.

It does not mutate, delete, reverse or convert the already-created child record for the observed dispute.

Any repair of an already-created child order is a separate data-correction task with its own preflight and governing authority.

## 13. Locked implementation instruction

The builder must implement exactly this:

```text
keep existing acceptReplacementOutcomeAction guards unchanged
remove staff_accept_replacement_outcome_v1 from that action
call existing staff_accept_same_order_free_replacement_v1 directly using the established grouped-authority pattern
never fall back to a child-order authority
treat returned UUID as a same-order route ID
remove child-order-specific revalidation
make only the three exact display-only wording corrections in section 8
preserve every existing downstream same-order component and authority unchanged
```

Nothing else is required to correct this defect.