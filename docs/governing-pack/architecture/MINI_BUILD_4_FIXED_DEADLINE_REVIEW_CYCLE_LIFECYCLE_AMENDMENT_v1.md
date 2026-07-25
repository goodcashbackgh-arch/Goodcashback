# Mini-build 4 Fixed-Deadline Review-Cycle Lifecycle Amendment v1

Status: governing lifecycle clarification for Mini-build 4

Amends: `docs/governing-pack/architecture/MULTI_SUPPLIER_INVOICE_MINI_BUILDS_3_4_IMPLEMENTATION_ALIGNMENT_ADDENDUM_v1.md`

Effective evidence baseline:

- repository `main` at `b81950157b4ad9a35d0081fe24d80e8be9fa8751`;
- live Supabase definitions supplied on 25 July 2026;
- live target order `ORD-1784498556959`.

Effective date: 25 July 2026

## 1. Purpose and precedence

This amendment resolves one lifecycle conflict identified by the completed repository and live-database audit of Mini-build 4.

It supersedes only the conflicting freeze-at-creation and later-cycle wording in sections 8.2, 8.3 and 8.4 of the amended alignment addendum. Every other protected route, invariant, role boundary, non-goal and regression requirement in that addendum remains governing.

Where this amendment conflicts with earlier wording about when review-cycle membership freezes or when a later eligible source must create a later cycle, this amendment controls.

This amendment does not authorise implementation. Implementation remains subject to a separate reviewed diff, migration, regression proof and release decision.

## 2. Existing route retained

Mini-build 4 must extend the existing route:

```text
received-clean package receipt
→ existing customer review-link route
→ customer_order_review_links
→ existing secure customer review page
→ existing customer hold submission RPCs
→ customer_pre_shipment_hold_requests
→ existing supervisor hold review
→ existing refund dispute / return / refund evidence route
→ existing DVA/card refund-IN, supplier-credit and Sage controls
```

It must not create a second customer review route, timer, hold workbench, exception workflow, shipment route, customer-sales route, refund-IN route or Sage route.

`customer_order_review_links.id` is the review-cycle identity. A separate review-cycle header family is not required.

`customer_order_review_links.expires_at` remains the one authoritative deadline consumed by the customer review route, customer order card and shipper surfaces.

## 3. Fixed-deadline cycle rule

For a new timed review cycle:

1. The first exact eligible `received_clean` source creates the cycle.
2. The cycle deadline is fixed once as:

```text
first eligible receipt recorded_at + 24 hours
```

3. The stored `expires_at` must never be extended, shortened or recalculated because another receipt, supplier invoice, supplier line, tracking allocation or package later becomes eligible.
4. Additional exact eligible membership may join the same cycle only while:

```text
now() < the already stored expires_at
```

5. Adding membership to an open cycle must not update `expires_at`.
6. Membership freezes when the fixed deadline expires.
7. Source eligibility arising at or after that deadline belongs to a later review cycle.
8. Creating a later cycle must not reopen, rewrite, remove or expand an expired cycle.
9. Retry or concurrency must not create duplicate active cycles or duplicate membership.

This rule preserves one shared customer review opportunity during the already-open fixed window without allowing a later receipt to reset or extend the customer's time.

## 4. Exact membership eligibility

A source quantity may enter an open or later review cycle only where exact structured evidence proves that it is:

- on an active supplier invoice;
- exact to a supplier invoice line;
- progressed under the existing progression truth;
- allocated to exact tracking/package scope;
- received clean;
- within the applicable fixed review deadline;
- not already actively released in `customer_sales_release_lines`;
- not already assigned beyond the exact remaining quantity to another review cycle;
- not under an active requested or supervisor-approved hold;
- not linked to an unresolved blocking exception or return action;
- not subject to a terminal refunded outcome;
- not already inside an active shipment where the existing review gate prohibits a new deadline-based hold.

Eligibility must not be inferred solely from description, amount equality, latest supplier invoice, current order-wide JSON or the existence or absence of one customer invoice.

A posted main or supplementary customer invoice must exclude only the exact quantity already released through the durable release ledger. Its existence must not permanently block a genuinely later unreleased source from a later cycle.

## 5. Membership provenance

Durable review membership must retain exact provenance behind the existing review link, including at least:

```text
review_link_id
order_id
supplier_invoice_id
supplier_invoice_line_id
tracking_submission_id
tracking_line_allocation_id
review_qty
goods_amount_gbp
delivery_share_gbp
discount_share_gbp
membership_status
created_at
```

The review payload and timed hold validation must resolve membership through the exact `review_link_id`, not through a fresh order-wide reconstruction.

A submitted order-, package- or line-scoped hold must retain exact provenance to the review membership and affected quantity it targeted.

Existing hold scope, duplicate-target, overlap and refund-exception protections remain attached and authoritative.

## 6. Legacy links

Existing legacy links with `expires_at IS NULL` retain the compatibility behaviour already protected by PR #116.

Mini-build 4 must not:

- invent a retrospective deadline for a historical untimed link;
- reactivate an inactive historical link;
- guess historical membership where exact source identity cannot be proven;
- create any new untimed review link.

Ambiguous legacy membership fails closed and remains subject to controlled review rather than fabricated membership.

## 7. Protected target-order evidence

The completed live audit of `ORD-1784498556959` is the mandatory protected regression baseline.

The following historical outputs must retain their existing identities and states:

```text
order status
partially_progressed

historical review link
9408064e-81b8-43bf-af95-c7c9c78264fd
inactive and untimed

customer hold
80f046a1-1055-4909-b03a-1ae26ba6033b
resolved

refund dispute
904d1bd3-86e9-47ad-bbf9-96859d900d22
refunded
£179.99

active customer-sales release total
£819.97

posted customer sales invoice
aa66f2a5-360a-4763-9c2e-81cf81432a4d
£819.97

posted Sage customer invoice
c1e63ef3a680477087347aa619220f19

active customer-sales Sage snapshot
c0bd5f5c-badf-4de4-bdd2-c5e23ee4f3ea
£819.97
posting attempt count 1
```

The held/refunded Ninja Detect Power Blender Pro source remains:

```text
supplier/refund amount: £179.99
customer-sale allocation basis: £184.99
including delivery share: £5.00
active released quantity: 0
terminal refund outcome: complete
```

Mini-build 4 must not create a new review cycle, customer release, customer invoice, customer credit, refund, cash posting or Sage posting for that historical source.

## 8. Explicitly protected routes

Mini-build 4 review-cycle work must not rewrite or reclassify:

- supplier invoice upload, OCR or evidence;
- reconciliation selection, `Select all` or `Clear selection` behaviour;
- delivery or signed discount calculations;
- progression, order status or audience status;
- tracking allocations or receipt evidence;
- shipment membership, shipment candidates or direct shipment creation;
- existing `customer_sales_release_lines` rows;
- existing customer sales invoices;
- customer-sales Sage payloads, snapshots, batching, posting, write-back or idempotency;
- supplier AP or supplier payment allocation;
- supplier credit evidence or supplier-credit Sage posting;
- refund evidence or DVA/card refund-IN allocation;
- funding, surplus, loyalty or customer payment allocation;
- cash posting snapshots, batches, rows or Sage posting;
- VAT, Box 6, export evidence or zero-rating;
- permissions, tenant boundaries or unrelated RLS policies;
- customer, supervisor, importer or shipper page styling, wording, navigation or selection controls.

Any later implementation must state exactly which existing consumers read new provenance. It must not describe unaffected routes merely as having “no impact”.

## 9. Mandatory regression proof

Mini-build 4 is not complete until regression proves at least:

1. The first eligible receipt creates one timed link and fixes `expires_at`.
2. A second exact eligible source before expiry joins the same link without changing `expires_at`.
3. A source becoming eligible at or after expiry creates a later link containing only newly eligible exact membership.
4. An expired cycle never changes after later receipts, allocations or supplier-state changes.
5. A posted customer invoice does not block genuinely later unreleased membership.
6. Active release-ledger quantity cannot re-enter review.
7. Active holds, unresolved blocking exceptions and terminal refunded quantities cannot re-enter review.
8. A package already in an active shipment is not assigned a new deadline-based hold.
9. Timed hold submission can target only membership belonging to its exact `review_link_id`.
10. The existing four hold-table triggers remain installed and enabled.
11. Existing duplicate, overlap and refund-dispute behaviour retains its previous result.
12. Existing customer and shipper countdowns continue to consume the same stored deadline.
13. Existing shipment candidate and direct-creation gates retain their previous behaviour.
14. Delivery and signed discount amounts remain attached to their existing exact allocations.
15. The target order retains the exact £819.97 release, customer invoice and Sage snapshot.
16. The £179.99 terminal refund remains complete and the excluded £184.99 customer-sale value is not released.
17. No new customer document, dispute, refund allocation, cash posting or Sage posting is created for the target order.
18. Unrelated one-invoice and multi-invoice orders receive their exact previous operational and accounting behaviour.

## 10. Release discipline

The sequence remains:

1. Review and merge this contract amendment.
2. Create the Mini-build 4 implementation branch from the merged contract baseline.
3. Reconfirm the latest live functions, triggers, constraints, grants and target-order fingerprints before writing SQL.
4. Implement through additive structures and surgical in-place function patches preserving existing signatures and return shapes.
5. Provide a Supabase SQL Editor-compatible read-only diagnostic and transaction-based regression; authenticated workflow tests remain separate.
6. Review every changed file against the last working version.
7. Run migration-order checks, lint/build, CI/Vercel and affected-role workflow tests.
8. List every changed file and why it is required.
9. Do not merge implementation until all protected-route regressions pass.
