# Mini-build 4 Shipper Canonical Review-State Amendment v1

Status: governing surgical clarification for the shipper review gate

Amends:

- `docs/governing-pack/architecture/MINI_BUILD_4_FIXED_DEADLINE_REVIEW_CYCLE_LIFECYCLE_AMENDMENT_v1.md`
- only the conflicting shipper countdown and shipment-eligibility wording

Effective evidence baseline:

- repository `main` after merged PR #183;
- live Supabase definitions and read-only database shape supplied on 27 July 2026;
- controlled order `ORD-1784976429191`;
- both packages have `received_clean` receipts less than 24 hours old;
- the review link is inactive;
- all four durable review memberships are expired;
- active review membership count is zero;
- active hold count is zero;
- active shipment membership count is zero;
- the shipper UI still displays a receipt-derived customer-review countdown.

Effective date: 27 July 2026

## 1. Purpose and precedence

This amendment resolves one isolated post-Mini-build-4 consumer defect.

The durable review-cycle state is correct. The shipper consumer is stale because it can infer customer-review state from `latest_receipt_recorded_at + interval '24 hours'` after the canonical review cycle has already closed.

Where this amendment conflicts with earlier wording that allowed shipper surfaces or shipment gates to consume a receipt-derived deadline independently of active durable review membership, this amendment controls.

Every other Mini-build 4 lifecycle rule, provenance rule, hold rule, shipment rule, accounting rule, permission boundary and regression requirement remains governing.

This amendment does not authorise implementation or merge. Implementation remains subject to a separate reviewed migration/diff, regression proof and release decision.

## 2. Proven defect boundary

For both `DPD240726` and `DHL240726A` on `ORD-1784976429191`, the live database proves:

```text
latest receipt status                 received_clean
receipt-derived 24-hour clock         still open
customer_order_review_links.is_active false
active review deadline                none
active review memberships             0
expired review memberships            2 per package
active holds                           0
active shipment membership            0
```

The deployed shipper client currently constructs the displayed deadline from:

```text
latest_receipt_recorded_at + 24 hours
```

The deployed shipment-candidate function also relies on a tracking review-deadline helper rather than directly proving active durable review membership.

The defect is therefore limited to shipper-side consumption of review state. It is not a receipt defect, membership defect, materialisation defect, hold defect or shipment-membership defect.

## 3. Canonical review-state rule

A package is in customer review only when the database proves all of the following for that exact tracking submission:

```text
one customer_order_review_links row
+ link is_active = true
+ link expires_at is not null
+ link expires_at > now()
+ at least one customer_review_cycle_memberships row
+ membership belongs to that exact link
+ membership belongs to that exact tracking_submission_id
+ membership_status = active
```

The authoritative countdown deadline is then, and only then:

```text
customer_order_review_links.expires_at
```

A clean receipt timestamp is evidence used to create or join a review cycle. It is not independently an active-review status after durable cycle state exists.

Therefore:

- an inactive link must never display a customer-review countdown;
- an expired, released or closed membership must never display a customer-review countdown;
- the absence of active exact membership means the package is not blocked by customer review;
- receipt age alone must never keep a package blocked after the canonical cycle closes;
- holds and every other shipment blocker remain separately authoritative.

## 4. Seamless implementation contract

The implementation must introduce or reuse one canonical database reader for exact tracking review state:

```text
exact order_id + exact tracking_submission_id
→ active review link identity, if any
→ stored expires_at, if active
→ active_review_yn
```

It must read only durable review-cycle truth:

- `customer_order_review_links`;
- `customer_review_cycle_memberships`;
- exact `order_id` and `tracking_submission_id`.

It must not reconstruct active review state from receipts, allocations or supplier lines.

Every affected shipper consumer must use this same canonical state:

1. shipper dashboard countdown presentation;
2. shipment candidate eligibility;
3. direct shipment creation server guard;
4. any existing tracking review-deadline helper feeding those routes.

No UI-only bypass is permitted. Candidate listing and direct creation must remain consistent at the database boundary.

## 5. Minimal-change and compatibility requirements

The patch must preserve existing public function signatures and return shapes unless an additive RPC is used.

The preferred low-risk pattern is:

1. add one small shipper-authorised canonical review-state RPC or SQL helper;
2. update the candidate function to block only where that helper proves active review;
3. update the direct-create guard to use the same helper;
4. update the shipper client to display the stored canonical deadline returned by that helper;
5. remove receipt-derived countdown calculation from the shipper client only.

The existing receipt-dashboard RPC should not be dropped or widened unless evidence proves that additive consumption is impossible.

If an existing helper already provides the exact durable state, reuse it rather than duplicating logic.

If `customer_tracking_review_deadline_v1` falls back to `latest_receipt_recorded_at + 24 hours` when no active exact membership exists, that fallback must not govern post-Mini-build-4 shipper blocking. It may remain only for an explicitly proven legacy route that cannot affect new timed cycles.

## 6. Protected routes

The implementation must not alter:

- receipt rows, receipt timestamps or receipt ordering;
- stored review deadlines;
- review-link identity or activation history;
- immutable membership provenance;
- membership status-transition rules;
- review-cycle materialisation;
- customer review payloads;
- hold creation, narrowing, approval or resolution;
- dispute, refund, return or credit-note routes;
- tracking allocations;
- shipment package membership;
- existing shipment batch contents;
- supplier invoice state;
- order status or audience status;
- customer sales releases or invoices;
- Sage, VAT, funding, cash-control or accounting routes;
- unrelated permissions or tenant boundaries.

## 7. Required shipper behaviour

For each exact package:

```text
active canonical review
→ show Customer review
→ count down to stored review-link expires_at
→ exclude from shipment candidates
→ direct shipment creation rejects

no active canonical review + another blocker exists
→ do not show a customer-review countdown
→ show the truthful remaining blocker
→ exclude from candidates only under that blocker
→ direct creation rejects under that same blocker

no active canonical review + no other blocker
→ do not show a customer-review countdown
→ expose Add to shipment
→ include in candidates
→ direct shipment creation may proceed
```

The client must never calculate an authoritative review deadline by adding 24 hours to a receipt timestamp.

## 8. Mandatory pre-implementation audit

Before writing the migration or UI diff, capture the live definitions of:

- `customer_tracking_review_deadline_v1`;
- `shipper_shipment_batch_candidates_v1`;
- `shipper_create_shipment_batch_v1`;
- `shipper_package_receipt_dashboard_v1`;
- every function invoking `customer_tracking_review_deadline_v1`;
- grants for every changed or additive function.

Search the repository for every consumer of:

- `latest_receipt_recorded_at`;
- `REVIEW_WINDOW_MS`;
- `customer_tracking_review_deadline_v1`;
- `shipper_shipment_batch_candidates_v1`;
- `shipper_create_shipment_batch_v1`.

No function may be patched from an assumed definition.

## 9. Mandatory regression proof

The patch is not complete until regression proves:

1. An active exact timed review continues to show the stored countdown.
2. A second source joining before expiry does not change the stored deadline.
3. An inactive link with expired memberships never shows a customer-review countdown.
4. Closing a review cycle immediately removes customer-review blocking from both candidate listing and direct creation.
5. An active hold still blocks after review closure.
6. A package already in an active shipment remains excluded.
7. A genuinely active review still blocks direct creation even if the client is bypassed.
8. Candidate and direct-create decisions are identical for the same package state.
9. Legacy untimed review compatibility remains unchanged.
10. Receipt history and receipt timestamps remain unchanged.
11. Review links and memberships remain unchanged by the patch.
12. Existing shipment batches and package memberships remain unchanged.
13. Unrelated one-invoice and multi-invoice orders retain their previous behaviour.
14. No customer-sales, refund, cash, Sage, VAT, funding or accounting row is created or modified.
15. For `ORD-1784976429191`, both packages stop showing customer review and become eligible only if no separate existing blocker applies.

## 10. Release discipline

The sequence is:

1. review and merge this contract amendment;
2. create the implementation branch from the merged contract baseline;
3. recapture the live helper, candidate, direct-create, dashboard and grant definitions;
4. implement the smallest additive helper plus surgical consumer patches;
5. preserve existing signatures and return shapes where possible;
6. add a Supabase SQL Editor-compatible read-only diagnostic and transaction-based regression;
7. run migration-order checks, lint/build, CI/Vercel and authenticated shipper workflow tests;
8. list every changed file and why it is required;
9. do not merge implementation until all protected-route regressions pass.
