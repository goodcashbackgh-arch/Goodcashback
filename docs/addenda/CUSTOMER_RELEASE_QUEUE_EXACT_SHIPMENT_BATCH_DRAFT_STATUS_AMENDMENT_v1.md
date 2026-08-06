# Customer Release Queue Exact Shipment-Batch Draft Status Amendment v1

**Status:** governing queue-contract amendment

**Effective date:** 6 August 2026

**Primary technical authority:**

`docs/governing-pack/architecture/EXACT_SHIPMENT_BATCH_DRAFT_STATUS_CORRECTION_ADDENDUM_v1.md`

**Related existing contract:**

`docs/addenda/CUSTOMER_RELEASE_QUEUE_FULLY_RELEASED_SUPPRESSION_ADDENDUM_v1.md`

## Purpose

Clarify the existing customer-release queue contract after authenticated acceptance proved that two shipment bookings on one commercial parent can receive the same order-level draft classification even when only one exact booking is present in the release ledger.

The existing fully-released suppression, positive-delta readiness, exact-clean batch admission and external queue status vocabulary remain unchanged.

## Governing queue rule

For `public.internal_customer_invoice_release_queue_v1()`:

```text
draft_exists
posted_exists
```

must be exact to the queue row's shipment batch.

A draft or posted invoice counts for a queue row only when an active `public.customer_sales_release_lines` membership exists with:

```sql
release_line.sales_invoice_id = invoice.id
AND release_line.source_shipment_batch_id = preview.shipment_batch_id
AND release_line.release_status = 'active'
```

An invoice joined only through the shared commercial-parent order is not sufficient to classify an unincluded sibling booking as drafted or posted.

## Permitted implementation boundary

A follow-up migration may change only the existing `draft_count` and `posted_count` aggregate expressions inside:

```sql
public.internal_customer_invoice_release_queue_v1()
```

The required implementation uses correlated `EXISTS` checks against `customer_sales_release_lines`. It must not directly join the ledger into the grouped preview rowset because that could change row cardinality, amounts or counts.

The queue function's signature, columns, return types, permissions, batch admission, readiness-preview call, grouping, totals, status precedence, actions and ordering remain unchanged.

## Required live result

```text
J040826
- exact active release membership exists
- draft_count = 1
- readiness_status = draft_exists
- queue_action = review_existing_draft

J040826v1
- no active release membership for its shipment batch
- draft_count = 0
- readiness_status = blocked while the sibling draft blocker remains
- queue_action = resolve_blockers
```

`J040826v1` must not display `Draft already exists` unless its exact shipment batch later gains an active release membership in a draft.

## Mini Build boundary

```text
Mini Builds 1–2: no change.
Mini Build 3: no change.
Mini Build 4: queue-only read classification correction.
```

No UI, server action, draft creator, resolver, preview, ledger schema, trigger, invoice, payload, Sage, VAT, AP, receipt, shipment, review, refund, replacement, accounting-readiness or order-status change is permitted.

No operational-row DML is permitted.

## Fingerprint and regression requirement

Implementation must first obtain and require the exact current installed fingerprint of `internal_customer_invoice_release_queue_v1()` after the exact-clean batch-admission migration. The historical fingerprint `7c4587e4ca91e5bf246f3f02281b2b98` must not be reused.

Regression must prove:

1. `J040826` remains exactly linked to its existing £10 supplementary draft and one active release membership;
2. `J040826v1` has no membership and resolves as blocked rather than drafted;
3. amounts, line counts, ready counts and blocker counts are unchanged apart from exact draft/posted classification;
4. Mini Build 1–3 protected definitions remain unchanged;
5. no rows are inserted, updated or deleted.

## Acceptance statement

A queue row represents one shipment booking. Therefore a booking may show `Draft already exists` or `Final invoice already posted` only when that exact shipment batch is present in the active release ledger of the relevant invoice.
