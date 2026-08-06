# Customer Release Queue Exact Shipment-Batch Draft Status Amendment v1

**Status:** governing queue-count amendment; sibling-block acceptance superseded

**Effective date:** 6 August 2026

**Current primary technical authority:**

`docs/governing-pack/architecture/INDEPENDENT_SHIPMENT_BATCH_CUSTOMER_SALES_DRAFT_COMPATIBILITY_CORRECTION_ADDENDUM_v1.md`

**Related existing contract:**

`docs/addenda/CUSTOMER_RELEASE_QUEUE_FULLY_RELEASED_SUPPRESSION_ADDENDUM_v1.md`

## 1. Queue rule retained

For `public.internal_customer_invoice_release_queue_v1()`:

```text
draft_exists
posted_exists
```

must be exact to the queue row's shipment batch.

A draft or posted invoice counts only when an active `public.customer_sales_release_lines` membership exists with:

```sql
release_line.sales_invoice_id = invoice.id
AND release_line.source_shipment_batch_id = preview.shipment_batch_id
AND release_line.release_status = 'active'
```

An invoice joined only through the shared commercial parent is not sufficient.

The installed exact shipment-batch queue-count migration correctly implements this rule. No further queue-function change is required.

## 2. Earlier acceptance error superseded

The earlier version of this amendment incorrectly required:

```text
J040826 = drafted
J040826v1 = blocked while J040826's draft remains active
```

That requirement is withdrawn.

The queue correction did not create the sibling blockage. It accurately reported:

```text
J040826 exact active draft memberships = 1
J040826v1 exact active draft memberships = 0
```

The remaining blockage was imposed by older Mini-build 3 resolver, creator and index rules. Those rules are corrected only under the current primary technical authority.

## 3. Final expected queue behaviour

```text
J040826
- exact active release membership exists
- draft_count = 1
- readiness_status = draft_exists
- queue_action = review_existing_draft

J040826v1 before its own draft
- no exact active release membership
- draft_count = 0
- sibling J040826 draft is not itself a blocker
- readiness follows only genuine resolver blockers and positive-delta readiness

J040826v1 after its own draft
- exact active release membership exists
- draft_count = 1
- readiness_status = draft_exists
- queue_action = review_existing_draft
```

## 4. Mini-build boundary

```text
Mini-builds 1 and 2: no change.
Mini-build 3: independent shipment-batch draft compatibility correction governed separately.
Mini-build 4: no lifecycle change; queue remains a read projection of ledger truth.
```

The queue's signature, return columns, batch admission, exact-clean compatibility, readiness-preview call, grouping, amounts, status vocabulary, actions, ordering and permissions remain unchanged.

## 5. Acceptance

A queue row represents one shipment batch. It may show `Draft already exists` or `Final invoice already posted` only when that exact batch is present in the active durable release membership of the relevant invoice.

The earlier regression requirement that J040826v1 remain blocked is not active acceptance authority.
