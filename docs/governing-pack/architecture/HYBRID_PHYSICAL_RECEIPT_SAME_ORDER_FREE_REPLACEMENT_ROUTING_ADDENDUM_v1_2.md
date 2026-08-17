# Hybrid Physical Receipt Same-Order Free Replacement Routing Addendum v1.2

**Status:** governing corrective addendum

**Effective date:** 17 August 2026

**Applies to:** `HYBRID_PHYSICAL_RECEIPT_SAME_ORDER_FREE_REPLACEMENT_ROUTING_ADDENDUM_v1.md` and `HYBRID_PHYSICAL_RECEIPT_SAME_ORDER_FREE_REPLACEMENT_ROUTING_ADDENDUM_v1_1.md`

**Verified repository baseline:** `main` at `36dd8e3a84844759049e9ce0adfeb3ed93b4777f`

## 1. Purpose

This correction governs one defect only:

`app/internal/exceptions/[dispute_id]/actions.ts` currently routes `acceptReplacementOutcomeAction()` to the legacy child-order acceptance authority.

For this supervisor replacement-acceptance surface, that routing is prohibited.

The already-built same-order free-replacement authority is the only permitted acceptance authority for this action.

No replacement flow, quantity logic, value logic, tracking logic, receipt logic, shipment logic, reconciliation logic, accounting logic or downstream operational logic is redesigned by this correction.

## 2. Authority and precedence

This v1.2 correction is read with v1 and v1.1.

Where this document is more specific about `acceptReplacementOutcomeAction()`, this document controls.

It specifically supersedes the v1 section 20.1 application-routing branch that permitted:

```text
legacy manual replacement dispute
-> staff_accept_replacement_outcome_v1
```

That fallback is no longer permitted from `acceptReplacementOutcomeAction()`.

Historical child-order records and installed legacy child-order database functions remain unchanged for compatibility. This correction only removes child-order routing from this supervisor action.

## 3. Verified live preflight

The read-only production preflight `SUPERVISOR_REPLACEMENT_RPC_ROUTING_PREFLIGHT_V1` returned no blockers and proved:

```text
staff_accept_same_order_free_replacement_v1(uuid,uuid,text,text) exists
same-order authority md5 = 78e94d6d76bf1c160068a3fd97ae4a87
staff_accept_replacement_outcome_v1(uuid,uuid,text) exists
same-order authority is SECURITY DEFINER
same-order authority search_path = public, pg_temp
same-order authority does not call staff_accept_replacement_outcome_v1
same-order authority does not call create_replacement_child_order
same-order authority requires free_replacement
same-order authority keeps replacement_child_order_id null
```

The same preflight also identified successful existing same-order replacement records with non-null `physical_replacement_same_order_routes` rows and null child-order provenance.

Therefore the required replacement authority and downstream same-order route already exist. They must be reused unchanged.

## 4. Locked functional change

Production functional scope is limited to:

```text
app/internal/exceptions/[dispute_id]/actions.ts
```

Inside that file, change only:

```text
acceptReplacementOutcomeAction()
```

The action must preserve its existing pre-acceptance guards unchanged, including:

```text
active staff authentication
replacement-outcome requirement
reconciliation-stage rejection
existing replacement-child rejection
retailer-message / accepted-outcome guard
```

After those existing guards pass, add only the minimum server-side read needed to prevent an unproven supplier-cost classification from being converted into a same-order free replacement:

1. read the unresolved dispute line(s) for the dispute and identify the existing `physical_remedy_allocation_id`;
2. fail closed if there is not exactly one unambiguous linked physical remedy for the action to use;
3. read that existing remedy's `supplier_cost_mode` only;
4. require the stored value to be exactly `free_replacement` before invoking the same-order authority;
5. if the stored value is `pending_supplier_evidence`, `charged_repurchase`, null, missing or anything other than `free_replacement`, return an error and stop;
6. never convert any failed or non-free case into a child order.

This read is a routing safety check only. It must not reimplement the same-order authority's quantity, value, source, provenance, locking, concurrency or route-creation controls.

After the stored `free_replacement` fact is proven, call only:

```text
staff_accept_same_order_free_replacement_v1(
  p_dispute_id := disputeId,
  p_staff_id := guard.staffId,
  p_confirmed_supplier_cost_mode := 'free_replacement',
  p_notes := 'Final replacement outcome accepted by supervisor'
)
```

The returned UUID is a same-order replacement route ID.

It must never be interpreted as a child order ID.

## 5. Absolute child-order prohibition for this action

`acceptReplacementOutcomeAction()` must contain no invocation of:

```text
staff_accept_replacement_outcome_v1
create_replacement_child_order_v2
```

It must contain no fallback, alternate branch, retry branch or error-recovery branch that invokes a child-order authority.

If the stored physical-remedy facts do not prove `free_replacement`, the action must surface an error and stop.

If `staff_accept_same_order_free_replacement_v1` rejects the dispute because any of its exact existing database prerequisites are not satisfied, the action must surface that returned error and stop.

It must never convert either type of rejection into a child order.

The legacy child-order authority remains installed and unchanged. It is simply not reachable from this supervisor action.

## 6. No duplicated replacement logic in the application

Apart from the narrow stored `supplier_cost_mode = free_replacement` proof in section 4, the application action must not reimplement or broaden the existing same-order authority's database rules.

Do not add TypeScript logic for:

```text
quantity apportionment
value apportionment
source-allocation validation
source-disposition validation
remedy provenance validation beyond locating the linked remedy needed for supplier-cost proof
replacement-route uniqueness
locking
concurrency
supplier-line ownership
child-field nulling
route creation
```

Those controls already belong to `staff_accept_same_order_free_replacement_v1` and remain authoritative.

The application action only proves the already-stored free-replacement classification and delegates to the existing authority.

## 7. Revalidation and success result

On successful same-order acceptance, preserve revalidation only for existing non-child surfaces required to show the accepted result:

```text
/internal/exceptions/{disputeId}
/importer/exceptions/{disputeId}
/importer
```

Remove the child-specific revalidation:

```text
/importer/orders/{childOrderId}/operations
```

because the returned UUID is a route ID, not a child order ID.

The action success message must state the same-order result:

```text
Replacement accepted — awaiting successor tracking.
```

No new navigation or replacement page is introduced.

## 8. Locked presentation alignment

Presentation correction is limited to these three existing files only:

```text
app/internal/exceptions/[dispute_id]/page.tsx
app/importer/exceptions/[dispute_id]/page.tsx
app/internal/exceptions/page.tsx
```

The only permitted presentation change is replacement terminal wording derived from the already-stored `replacement_child_order_id` fact:

```text
replacement_child_order_id is not null
-> historical child-order wording remains

replacement_child_order_id is null
-> same-order wording is shown, e.g. "Replacement accepted — awaiting successor tracking"
```

No other labels, layout, components, navigation, queries, status families, permissions or workflow behaviour may be changed in these files.

These edits are display-only and must be separately identifiable in the implementation diff.

No other presentation file is in scope.

## 9. Explicit non-scope

Do not change:

```text
staff_accept_same_order_free_replacement_v1
staff_accept_replacement_outcome_v1
create_replacement_child_order_v2
physical_replacement_same_order_routes schema or policies
tracking allocation authorities
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

No SQL migration is required by this correction.

## 10. Implementation scope ceiling

The implementation is rejected for scope creep if it does any of the following:

```text
changes a database function
adds a migration
adds a new replacement authority
alters the existing importer same-order tracking handoff
alters receipt, shipment, reconciliation or accounting behaviour
changes Mini Build definitions
adds a new fallback route
creates or links a replacement child from acceptReplacementOutcomeAction()
reimplements same-order business validation in TypeScript
changes production files other than the one functional file and the three locked display-only files in section 8
```

The intended functional diff is one existing server action rewired from the wrong legacy authority to the already-built same-order authority, with one narrow fail-closed read of the already-stored supplier-cost classification.

The only additional permitted production edits are the three display-only wording corrections locked in section 8.

Any other production file requires a separately documented reason and approval before implementation.

## 11. Required regression proof before merge

Before merge, prove all of the following:

1. source inspection shows `acceptReplacementOutcomeAction()` contains zero references to `staff_accept_replacement_outcome_v1` and zero references to a child-order creator;
2. source inspection shows the action requires the stored linked remedy `supplier_cost_mode` to equal `free_replacement` before calling the same-order RPC;
3. a controlled eligible replacement acceptance creates one `physical_replacement_same_order_routes` row through the existing authority;
4. `disputes.replacement_child_order_id` remains null for that acceptance;
5. `dispute_lines.resolved_via_child_order_id` remains null for that acceptance;
6. the total replacement-child order population does not increase during the controlled test;
7. a controlled non-free or unproven supplier-cost case fails closed and creates neither a same-order route nor a child order;
8. the existing importer same-order successor-tracking handoff remains available after acceptance;
9. the same-order authority fingerprint remains `78e94d6d76bf1c160068a3fd97ae4a87`;
10. no protected Mini Build authority changes;
11. TypeScript/build checks pass for the touched application code;
12. the three locked presentation files show child wording only when `replacement_child_order_id` is non-null and same-order wording when it is null.

A failing regression stops the merge. Do not repair a regression by changing downstream working parts without a new governing decision.

## 12. Existing incorrectly-created child record

This correction is forward-looking.

It does not mutate, delete, reverse or convert the already-created child record for the observed production/test dispute.

Any repair of an already-created child order is a separate data-correction task with its own read-only preflight, governing authority and rollback proof.

## 13. Locked implementation instruction

The builder must implement exactly this:

```text
keep existing acceptReplacementOutcomeAction guards
prove the linked existing remedy already stores supplier_cost_mode = free_replacement
fail closed otherwise
remove legacy child-order RPC invocation from that action
call existing staff_accept_same_order_free_replacement_v1 only
never fall back to a child-order authority
treat returned UUID as same-order route ID
remove child-order-specific revalidation from the same-order result
make only the three locked child-vs-same-order wording corrections
preserve all existing downstream same-order infrastructure unchanged
```

Nothing else is required to correct the routing defect.