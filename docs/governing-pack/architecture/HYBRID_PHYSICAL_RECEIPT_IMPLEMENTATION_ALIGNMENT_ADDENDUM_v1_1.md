# Hybrid Physical Receipt Implementation Alignment Addendum v1.1

Status: governing implementation clarification and non-regression authority

Effective date: 1 August 2026

Applies to:

`docs/governing-pack/architecture/HYBRID_PHYSICAL_RECEIPT_QUANTITY_FULFILMENT_AND_REMEDY_CONTROL_ADDENDUM_v1.md`

Verified implementation baseline:

`main` at `f5bcbfd1fca5855826905bebdd6ea4eb4891a6f4`

## 1. Purpose and precedence

This v1.1 alignment addendum records repository and live-database facts discovered while implementing the original hybrid physical-receipt addendum.

It does not replace the original business outcome. It resolves implementation assumptions that the live exception model cannot safely support.

Where this document is more specific than the original addendum about dispute quantity, mixed remedies, unresolved-line uniqueness or physical-review-to-dispute linkage, this document controls.

All other original addendum requirements remain in force, including exact source provenance, no duplicate customer review or shipment route, reuse of the existing retailer conversation/refund/replacement controls, and no weakening of finance, VAT, Sage, settlement or tenant controls.

## 2. Verified live constraints

The following live facts were verified on 1 August 2026:

1. `physical_exception_remedy_allocations.proposed_remedy_qty` and `approved_remedy_qty` use exact `numeric(12,3)` quantities.
2. `dispute_lines.qty_impact` is `integer NOT NULL`.
3. `orders.total_qty_declared`, replacement-child quantities and the current `create_replacement_child_order` implementation use integer quantities.
4. `disputes.desired_outcome` is one header value limited to `refund` or `replacement`.
5. Refund evidence, return/collection, settlement and refund completion functions require a refund dispute header.
6. Replacement-child creation consumes one replacement dispute line and narrows quantity to integer.
7. `uq_dispute_lines_open` permits only one unresolved `dispute_lines` row per `supplier_invoice_line_id`.
8. `dispute_lines` also has `UNIQUE (dispute_id, supplier_invoice_line_id)`.
9. Existing reconciliation and return-task readers consume the current integer dispute-line contract.

These are not defects to be bypassed by rounding, coercion or removal of global protections.

## 3. Quantity compatibility decision

Exact physical quantity remains authoritative in `physical_exception_remedy_allocations`.

The implementation must not widen `dispute_lines.qty_impact` as part of the supervisor initial-decision bridge unless every dependent operational object is separately audited, replaced and regression-proved in a later governed build.

For Build 2:

- approved `refund` and `replacement` quantities entering the existing dispute route must be whole units;
- the RPC must reject any such quantity for which `approved_remedy_qty <> round(approved_remedy_qty)` within the governed tolerance;
- no fractional quantity may be silently rounded, truncated or expanded;
- `hold_investigate` and `no_action` quantities may remain exact `numeric(12,3)` because they do not enter the integer legacy dispute route at initial decision.

A fractional refund/replacement request therefore fails closed with a clear operator-facing error and remains unresolved for controlled staff handling.

## 4. Mixed remedy decision

One physical review may approve more than one route for the same affected supplier line, including a split such as one refund and one replacement.

The legacy dispute header cannot represent mixed outcomes because `disputes.desired_outcome` is singular and downstream functions use it as authority.

Therefore:

- refund and replacement allocations must not be combined in one dispute;
- the supervisor bridge creates or links separate disputes by compatible outcome;
- each resulting dispute retains its own existing refund or replacement state machine;
- retailer communications, refund evidence, return/collection, settlement and replacement-child creation continue to use the appropriate legacy dispute header.

The physical review remains one triage decision, while the existing disputes remain the operational outcome authorities after linkage.

## 5. Multi-dispute linkage

The original single `physical_receipt_reviews.linked_dispute_id` field remains a compatibility primary link. It cannot fully represent a split review.

Build 2 must add an auditable many-link structure with at least:

```text
physical_receipt_review_id
dispute_id
desired_outcome
created_by_staff_id
created_at
```

Required controls:

- each linked dispute belongs to the review order;
- `desired_outcome` agrees with the linked dispute header;
- a review/dispute pair is unique;
- direct ordinary-user writes are denied;
- links are created only by the supervisor decision authority;
- links are immutable after creation except through an explicit later remediation authority;
- `physical_receipt_reviews.linked_dispute_id` stores a deterministic primary link for backward compatibility, but the link table is authoritative for the complete set.

A deterministic primary-link rule must be documented and regression-tested. Unless an existing UI contract requires otherwise, refund precedes replacement, then the lowest dispute UUID is used as the final tie-breaker.

## 6. Physical dispute-line identity and open-line protection

The existing global one-open-line-per-supplier-line rule must not simply be dropped.

Build 2 must add a nullable exact physical source identity to `dispute_lines`, for example:

```text
physical_remedy_allocation_id uuid NULL
```

It must reference `physical_exception_remedy_allocations(id)` and be unique when present.

The current `uq_dispute_lines_open` rule must be replaced only by an equivalent compatibility pair of rules:

1. legacy unresolved dispute lines, where `physical_remedy_allocation_id IS NULL`, retain one unresolved line per `supplier_invoice_line_id`;
2. physical unresolved dispute lines are unique by exact `physical_remedy_allocation_id` and may coexist for the same supplier line only when they represent different approved remedy allocations.

Additional required controls:

- the physical remedy allocation and dispute line must identify the same supplier invoice line and order;
- the dispute header outcome must equal the approved physical remedy type;
- the dispute line integer quantity must equal the whole approved physical quantity exactly;
- a physical allocation may link to at most one dispute line;
- no existing legacy dispute line is reclassified as physical without explicit proven provenance;
- existing open legacy exceptions remain ambiguity blockers for automatic physical linkage unless an exact compatible reuse can be proven.

## 7. Dispute creation and grouping

The supervisor initial-decision authority may group approved allocations into one dispute only when all of the following match:

- order;
- desired outcome;
- issue type;
- liable party;
- current compatible open-state requirements;
- no uniqueness or provenance conflict.

One dispute line is created per distinct approved physical remedy allocation, subject to the exact-source controls above.

A refund allocation must create a refund dispute line. A replacement allocation must create a replacement dispute line. No header outcome may be chosen merely to make a mixed payload fit.

The initial decision does not record retailer acceptance, refund receipt, replacement completion, customer settlement, supplier recovery or final financial values.

Where an authoritative monetary amount is not yet proven, the existing dispute amount must remain conservative and must not be populated from guessed supplier cost or customer entitlement. Later existing retailer/refund evidence controls remain authoritative.

## 8. Review states

The original review-state meaning remains unchanged:

- `returned_for_information`: importer action required;
- `approved_for_investigation`: exact hold/investigate quantity approved, no legacy dispute required;
- `closed_no_action`: exact no-action quantity approved with reason, no legacy dispute required;
- `approved_to_existing_exception`: every active refund/replacement allocation is linked to its exact legacy dispute line and all required review/dispute links exist.

For a split refund/replacement review, `approved_to_existing_exception` means linkage to the complete set of outcome-specific disputes, not merely the compatibility `linked_dispute_id`.

## 9. Example

A supplier invoice line contains three phones. The finalised receipt records:

```text
clean: 1.000
damaged: 1.000
missing: 1.000
```

The supervisor approves:

```text
replacement: 1.000 from the damaged disposition
refund: 1.000 from the missing disposition
```

The implementation creates:

- one replacement physical remedy allocation and one replacement dispute line in a replacement dispute;
- one refund physical remedy allocation and one refund dispute line in a refund dispute;
- two immutable review/dispute links;
- one deterministic compatibility primary `linked_dispute_id` on the review.

The clean phone continues through the existing clean review/shipment/customer-sales path. The missing phone follows the existing refund route. The damaged phone follows the existing replacement route.

No supplier invoice line, tracking allocation or order line is duplicated. No quantity is rounded. No mixed-outcome dispute is invented.

## 10. Build and regression requirements

Before the supervisor decision RPC may be accepted, source and rollback-only database regressions must prove:

1. the verified live constraint fingerprints or exact definitions used by this decision have not drifted;
2. no protected refund, return, replacement, reconciliation or customer-sales function is replaced in Build 2;
3. fractional refund/replacement approval fails closed;
4. whole-unit refund and replacement allocations preserve exact equality between physical and dispute quantities;
5. one review can link to separate refund and replacement disputes;
6. the compatibility primary link is deterministic;
7. legacy unresolved-line uniqueness remains effective;
8. separate physical allocations for the same supplier line can coexist without weakening legacy protection;
9. an existing ambiguous open legacy exception blocks automatic linkage;
10. hold/investigate and no-action do not create disputes;
11. no retailer outcome, remedy completion or financial settlement is written by the initial-decision RPC;
12. the entire production dry run ends in `ROLLBACK` and leaves the live database unchanged.

Any mismatch stops the build. The implementation must not guess, round or remove a global protection merely to force the new workflow through the legacy model.
