# Hybrid Physical Receipt Build 2 Impact Map v1

Status: implementation boundary for Build 2

Governing authorities:

1. `docs/governing-pack/architecture/HYBRID_PHYSICAL_RECEIPT_QUANTITY_FULFILMENT_AND_REMEDY_CONTROL_ADDENDUM_v1.md`
2. `docs/governing-pack/architecture/HYBRID_PHYSICAL_RECEIPT_IMPLEMENTATION_ALIGNMENT_ADDENDUM_v1_1.md`

The v1.1 alignment addendum controls where the original contract assumed that exact physical quantities, mixed refund/replacement routes or several open physical allocations could be represented directly by the current legacy dispute model.

Build baseline:

`main` at `f5bcbfd1fca5855826905bebdd6ea4eb4891a6f4`

Branch:

`agent/hybrid-receipt-build-2-v1`

## 1. Purpose

Build 2 adds the atomic v2 receipt write authority and the controlled importer/supervisor physical-triage bridge over the foundation merged by PR #212.

It does not activate the final production shipper UI, replace existing review/shipment/customer-sales functions, complete a retailer refund, create a replacement child, alter parent closure, or replace reconciliation.

The Build 2 outcome is:

```text
shipper v2 receipt facts can be recorded atomically;
affected quantity creates one physical receipt review header;
importer proposals reserve exact affected quantity;
supervisor initial decisions approve, change, return, reject or close the route;
whole-unit refund/replacement approval links to outcome-specific existing disputes;
exact hold/investigate and no-action quantities remain in physical triage;
no physical triage record independently claims retailer or remedy completion.
```

## 2. Existing authorities reused

Build 2 must reuse rather than duplicate:

- `shipper_package_receipts` as the receipt header and history family;
- `shipper_package_receipt_line_dispositions` for exact clean/affected quantity;
- `shipper_package_receipt_evidence` for multiple immutable evidence references;
- `physical_receipt_reviews` for importer proposal and supervisor initial route approval;
- `physical_exception_remedy_allocations` for proposed and approved affected-quantity splits;
- `operator_importers` and `operators` for importer access;
- `staff` and `is_active_staff()` for supervisor authority;
- `disputes` and `dispute_lines` for the existing retailer-facing exception route;
- `/importer/exceptions/[dispute_id]` and `/internal/exceptions/[dispute_id]` after linkage.

Build 2 must not create another receipt header, customer-review timer, shipment route, retailer conversation, refund process, replacement operations page, customer invoice route or Sage route.

## 3. Verified legacy compatibility boundary

Live inspection established:

- `physical_exception_remedy_allocations` stores `numeric(12,3)` exact quantity;
- `dispute_lines.qty_impact` is integer;
- replacement-child order quantity and `create_replacement_child_order` are integer based;
- `disputes.desired_outcome` is one header-level refund or replacement value;
- refund evidence, return/collection and settlement functions require a refund header;
- `uq_dispute_lines_open` currently allows one unresolved dispute line per supplier invoice line;
- reconciliation and return-task readers consume the existing integer dispute-line contract.

Build 2 therefore must not widen `dispute_lines.qty_impact`, round physical quantities, place refund and replacement lines in one mixed-outcome dispute, or simply remove the legacy open-line protection.

## 4. Ordered database work

### 4.1 Atomic receipt RPC

Add `shipper_record_package_receipt_v2(uuid,uuid,jsonb,jsonb,uuid,text)` with the already governed authentication, locking, idempotency, exact-balance, evidence, correction, finalisation and review-creation controls.

No pending v2 receipt may commit.

### 4.2 Importer proposal RPC

Add one transaction authority for submitting or replacing the active importer proposal while the review is in `awaiting_importer_proposal` or `returned_for_information`.

It must allow split exact proposals, preserve prior proposals by audited cancellation rather than deletion, enforce affected-quantity ceilings and prevent importer writes to supervisor, dispute, supplier-cost, customer-commercial, settlement or replacement-child facts.

### 4.3 Additive dispute compatibility migration

Before the supervisor RPC, add an audited compatibility migration that:

1. creates an immutable many-link table between one physical review and every linked legacy dispute;
2. retains `physical_receipt_reviews.linked_dispute_id` as a deterministic compatibility primary link;
3. adds nullable `dispute_lines.physical_remedy_allocation_id` provenance;
4. makes that identity unique when present;
5. preserves one unresolved legacy dispute line per supplier invoice line where the physical identity is null;
6. allows separate unresolved physical lines for the same supplier line only when each has a different exact physical remedy allocation;
7. proves review, order, supplier line, approved route, dispute header outcome and integer quantity agreement;
8. does not reclassify existing legacy lines as physical;
9. fails closed on ambiguous existing open exceptions;
10. leaves protected refund, return, replacement, reconciliation and customer-sales functions unchanged.

### 4.4 Supervisor initial-decision RPC

Add one transaction authority for:

- return for information;
- reject;
- approve exact hold/investigate;
- approve exact no action with reason;
- approve whole-unit refund/replacement quantities into outcome-specific existing disputes.

Required controls:

- active supervisor/admin staff only;
- review, proposal, source disposition and relevant exception rows locked;
- input accepted only while `awaiting_supervisor_review`;
- approved quantities may be reduced, split or rerouted but cannot exceed source affected quantity;
- every approved route has positive exact quantity;
- refund/replacement quantities must equal whole units and must fail closed rather than round;
- replacement approval requires an explicit supplier-cost mode;
- decision note is mandatory;
- final approval is stored separately from importer proposal;
- refund allocations create/link only refund disputes and refund dispute lines;
- replacement allocations create/link only replacement disputes and replacement dispute lines;
- one physical remedy allocation links to at most one dispute line;
- a mixed refund/replacement decision creates separate disputes and complete many-link provenance;
- the compatibility primary link is deterministic: refund first, then replacement, then lowest dispute UUID;
- `approved_to_existing_exception` is reached only when every active refund/replacement allocation is linked;
- remedy rows advance no further than `linked_to_exception`;
- no retailer acceptance, refund receipt, customer settlement, supplier recovery or replacement completion is written;
- unproven monetary values are not guessed.

Hold/investigate and no-action remain exact in physical triage and do not create legacy disputes at initial decision.

## 5. Application work allowed in Build 2

Build 2 may add server actions and read pages for importer Physical Receipt Exceptions, supervisor Physical Receipt Reviews, the importer and supervisor RPCs, and redirects to each linked existing exception.

The current shipper v1 action and UI remain preserved until the coordinated production cutover. Storage access may not be weakened.

## 6. Explicit exclusions

There is no feature flag, pilot account or staged business rollout.

Build 2 does not modify customer-review, shipment or customer-sales functions; create or complete a replacement child; complete a supplier refund or customer settlement; alter AP, VAT or Sage; replace `order_has_open_child_exceptions`; replace `order_reconciliation_vw`; activate the v2 shipper UI; widen legacy quantity columns; or remove global protections without an equivalent compatibility rule.

## 7. Required regression gates

Regression must prove:

1. original and v1.1 governing documents are present and referenced;
2. protected receipt, refund, return, replacement, reconciliation and customer-sales objects remain unchanged;
3. receipt idempotency, exact balance, evidence and correction controls still pass;
4. importer access and prohibited-write controls still pass;
5. fractional refund/replacement approval fails closed;
6. whole-unit physical and dispute quantities are exactly equal;
7. hold/investigate and no-action create no disputes;
8. one review can link to separate refund and replacement disputes;
9. no mixed-outcome dispute is created;
10. complete review/dispute links and deterministic primary link are recorded;
11. legacy unresolved-line uniqueness remains effective;
12. distinct physical remedy allocations for one supplier line may coexist safely;
13. ambiguous open legacy exceptions block automatic linkage;
14. replacement approval requires supplier-cost mode;
15. no retailer outcome, remedy completion or financial settlement is written;
16. terminal review/remedy/link provenance remains immutable;
17. no Build 3, Build 4 or unrelated application changes enter the branch;
18. every production dry run ends in `ROLLBACK` and leaves production unchanged.

## 8. Stop conditions

Implementation stops rather than guesses when a protected definition drifts, exact source identity cannot be proven, a fractional quantity is proposed for the integer legacy route, an existing open exception makes linkage ambiguous, storage access would need weakening, or the current role matrix cannot authorise the action.

Any conflict requires an explicit additive compatibility migration or a further governing clarification. No quantity may be rounded and no global protection may be removed merely to force the workflow through the legacy model.
