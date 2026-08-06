# Customer Release Queue Parent-Draft Ownership Projection Addendum v1

**Status:** governing additive correction

**Effective date:** 6 August 2026

## Purpose

This addendum governs a read-model correction in `public.internal_customer_invoice_release_queue_v1()`.

The customer-sales creator, durable release ledger, parent-wide active-draft rule, Accounting route, VAT and Sage routes are already correct. The defect is limited to how the release queue counts preview rows and describes an active parent draft.

## Confirmed defect

The queue previously joined each readiness-preview row directly to every `sales_invoices` row for the commercial parent before calculating `COUNT(*)`.

For the controlled fixture parent there were four historical customer-sales records:

1. one posted £90 main;
2. one void £10 supplementary;
3. one void £20 supplementary;
4. one draft £30 supplementary.

The join therefore projected:

```text
J040826:   1 true line × 4 invoice rows = 4 displayed lines
J040826v1: 2 true lines × 4 invoice rows = 8 displayed lines
```

Historical and void invoices must remain in `sales_invoices`, but invoice history must not alter source-line cardinality.

The queue also used parent-wide draft existence as if it were batch ownership. Parent-wide existence is the correct concurrency block, but exact display ownership must come from active `customer_sales_release_lines` membership.

## Governing rules

1. Preview rows must be aggregated before invoice-state enrichment.
2. `line_count` is the count of readiness-preview rows for the shipment batch and must not depend on the number of historical invoices.
3. Parent draft and posted counts may be calculated separately from distinct batch/order pairs.
4. Exact active-draft ownership must be read only from active durable release membership joined to a draft customer-sales invoice.
5. A batch with active membership in the parent draft is `released_in_existing_draft`.
6. A batch without active membership while another draft exists for the parent is `blocked_by_another_active_draft`.
7. A genuinely ready batch with no active parent draft remains `ready_to_create_draft`.
8. Existing positive-delta suppression and posted-history behaviour remain unchanged.
9. The function signature, grants and caller contract remain unchanged.

## Protected boundary

This correction must not change:

- Mini-build 1 supplier-document identity, approval, rejection or order-bundle controls;
- Mini-build 2 upload, navigation, delivery allocation, payment or reconciliation controls;
- Mini-build 3 source eligibility, amount calculation, draft creator, durable membership, fingerprint, reversal, financial guard, one-main rule or repeated-supplementary rule;
- Mini-build 4 review-cycle, hold, exception, return, shipment or customer-credit controls;
- exact-clean mixed-package proof or receipt qualification;
- one-active-draft-per-commercial-parent enforcement;
- funding, Accounting, freeze, VAT, Sage validation or posting;
- any operational row.

The only database object permitted to change is:

```text
public.internal_customer_invoice_release_queue_v1()
```

Application callers may consume the two more precise status strings through the existing `readiness_status` text field. No return column is added or removed.

## Required regression evidence

The additive migration and rollback-only regression must prove:

- the diagnosed queue fingerprint is the expected starting definition;
- J040826 resolves to one owned line and £10 in the active £30 draft;
- J040826v1 resolves to two owned lines and £20 in the same draft;
- four parent invoice records do not produce line counts of four and eight;
- void invoices remain historically present;
- exact owners return `released_in_existing_draft`;
- a non-owning sibling under an active parent draft returns `blocked_by_another_active_draft`;
- a ready batch with no parent draft remains `ready_to_create_draft`;
- protected Mini-build 1–4, creator, ledger, Accounting, VAT and Sage definitions are unchanged;
- the £30 invoice and its three active memberships are unchanged.

## Acceptance statement

After deployment, invoice history no longer multiplies release-queue lines. Parent-wide draft blocking remains intact, while the queue accurately distinguishes a batch already included in the active draft from a sibling merely blocked by that draft. No customer-sales lifecycle or Mini-build 1–4 behaviour changes.