# Exact Shipment-Batch Draft Status Correction Addendum v1

**Status:** SUPERSEDED

**Effective date:** 6 August 2026

**Superseded by:**

`docs/governing-pack/architecture/INDEPENDENT_SHIPMENT_BATCH_CUSTOMER_SALES_DRAFT_COMPATIBILITY_CORRECTION_ADDENDUM_v1.md`

## Supersession reason

This document correctly identified that customer-release queue draft and posted counts must be exact to the queue row's shipment batch. That queue-count correction remains valid and installed.

However, this document incorrectly concluded that the remaining J040826v1 blockage was queue-only and should remain in place while J040826 had an active draft.

The later confirmed dependency analysis proved that the sibling blockage was independently imposed by:

1. parent-wide active-draft detection in `internal_customer_sales_release_sources_v1(uuid)`;
2. parent-wide iteration, aggregation and draft reuse in `internal_customer_invoice_release_create_drafts_v1(uuid[])`;
3. `uq_sales_invoices_active_release_draft_v1`.

The requirement that J040826v1 remain blocked is withdrawn. The prohibitions against correcting those three Mini-build 3 mechanisms are also withdrawn.

## Authority retained from this document

The following rule remains governing:

> A queue row may show `draft_exists` or `posted_exists` only when that exact shipment batch has an active durable release membership in the relevant invoice.

The installed exact shipment-batch queue-count migration remains correct and requires no further queue change.

## Authority no longer active

The following positions are superseded and must not be used for implementation or acceptance:

- the defect is limited to queue classification;
- Mini-build 3 requires no correction;
- J040826v1 must remain blocked by J040826's sibling draft;
- the resolver, creator and parent-wide active-draft index must remain unchanged;
- a regression should prove the sibling blockage as the expected result.

## Current governing position

The exact-clean corrections, exact queue counts and existing J040826 £10 draft remain unchanged.

The selected shipment batch is the draft-creation and retry unit. The commercial parent remains the document family, one-main and advisory-lock boundary. Active duplicate protection is enforced through exact durable membership fingerprints.
