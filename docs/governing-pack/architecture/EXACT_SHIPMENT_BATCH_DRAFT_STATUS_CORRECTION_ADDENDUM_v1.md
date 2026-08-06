# Exact Shipment-Batch Draft Status Correction Addendum v1

**Status:** governing technical specification and non-regression authority

**Effective date:** 6 August 2026

## 1. Purpose

Correct the customer invoice release queue so that `Draft already exists` applies only to a shipment booking actually included in that draft.

A draft created from `J040826` must not cause `J040826v1` to display as drafted merely because both bookings share the same commercial parent order.

The existing invoice, release ledger and selection behaviour are correct. The defect is limited to the queue's status calculation.

## 2. Confirmed defect

The page sends only the checked `shipment_batch_id` values to the server action.

The draft creator resolves only those submitted shipment batches.

However, the queue currently counts drafts by matching:

```sql
sales_invoices.order_id = preview.order_id
```

This means every shipment booking attached to the same commercial parent sees the same draft count, even when the draft's release ledger contains only one exact shipment batch.

Confirmed live result:

```text
Draft invoice:
a3c939e4-0abb-4047-b828-cdc137130fd4

Included shipment batch:
J040826
1d8ed4af-4d35-4b2d-9913-9bae1a20a717

Active release memberships:
1

J040826v1 included:
false
```

Therefore the invoice and ledger are correct. Only the queue classification is wrong.

## 3. Governing invariant

A shipment batch may be classified as `draft_exists` or `posted_exists` only when the exact invoice contains an active release-ledger membership with:

```sql
customer_sales_release_lines.source_shipment_batch_id
=
queue shipment_batch_id
```

Order-level invoice existence alone is insufficient.

The invariant is:

```text
booking shown as drafted
<= exact active release-ledger membership for that booking
```

## 4. Smallest permitted patch

Change exactly one database function:

```sql
public.internal_customer_invoice_release_queue_v1()
```

Inside that function, change only:

```text
draft_count
posted_count
```

No other calculation, join, grouping, status order, return column, label or permission may change.

A new follow-up migration must be created. Previously installed migrations must not be rewritten.

## 5. Required SQL correction

### Existing logic

The existing counts operate at commercial-parent order level:

```sql
COUNT(DISTINCT invoice.id)
  FILTER (WHERE invoice.sage_status = 'draft')
  AS draft_count,

COUNT(DISTINCT invoice.id)
  FILTER (WHERE invoice.sage_status = 'posted')
  AS posted_count
```

### Required logic

Replace them with exact shipment-batch membership checks:

```sql
COUNT(DISTINCT invoice.id) FILTER (
  WHERE invoice.sage_status = 'draft'
    AND EXISTS (
      SELECT 1
      FROM public.customer_sales_release_lines release_line
      WHERE release_line.sales_invoice_id = invoice.id
        AND release_line.source_shipment_batch_id
            = preview.shipment_batch_id
        AND release_line.release_status = 'active'
    )
)::integer AS draft_count,

COUNT(DISTINCT invoice.id) FILTER (
  WHERE invoice.sage_status = 'posted'
    AND EXISTS (
      SELECT 1
      FROM public.customer_sales_release_lines release_line
      WHERE release_line.sales_invoice_id = invoice.id
        AND release_line.source_shipment_batch_id
            = preview.shipment_batch_id
        AND release_line.release_status = 'active'
    )
)::integer AS posted_count
```

The existing `sales_invoices` join must remain unchanged.

Do not join `customer_sales_release_lines` directly into the grouped rowset. A direct join could multiply preview rows and alter:

```text
line_count
ready_line_count
blocker_count
amounts
order_count
```

The correlated `EXISTS` checks avoid changing row cardinality.

## 6. Required queue behaviour

### J040826

Because its exact shipment batch has an active release membership:

```text
draft_count: 1
readiness_status: draft_exists
queue_action: review_existing_draft
```

### J040826v1

Because it has no release membership in the draft:

```text
draft_count: 0
```

While the sibling draft remains active, its existing resolver blocker determines the outcome:

```text
readiness_status: blocked
queue_action: resolve_blockers
```

It must not display:

```text
Draft already exists
```

After the sibling draft is posted or otherwise no longer blocks new release activity, `J040826v1` may return to the normal existing readiness route if it has a genuine unreleased positive amount. This patch must not permanently suppress it.

## 7. Existing status order remains unchanged

The queue's current status precedence must remain:

```sql
CASE
  WHEN draft_count > 0 THEN 'draft_exists'
  WHEN genuinely_ready THEN 'ready_to_create_draft'
  WHEN posted_count > 0 THEN 'posted_exists'
  WHEN blocker_count > 0 THEN 'blocked'
  ELSE 'blocked'
END
```

Only the meaning of `draft_count` and `posted_count` becomes exact to the shipment batch.

No new readiness status or blocker value is required.

The existing queue contract already defines `draft_exists`, `posted_exists`, `ready_to_create_draft` and `blocked`; this patch refines their exact booking scope without changing the external contract.

## 8. Mini Build impact boundary

### Mini Builds 1 and 2

No changes.

Do not change:

```text
receipt facts
physical quantities
review memberships
shipment membership
tracking allocations
effective shipment lines
```

### Mini Build 3

No changes.

Do not change:

```text
internal_customer_sales_release_sources_v1
internal_customer_invoice_release_create_drafts_v1
customer_sales_release_lines
customer_sales_release_guard_v1
customer_sales_release_financial_guard_v1
invoice creation
duplicate protection
main/supplementary routing
release values
```

### Mini Build 4

One queue-only classification correction:

```text
order-level invoice count
-> exact shipment-batch ledger membership count
```

No readiness-preview change.

## 9. Explicit non-scope

Do not change:

```text
UI files
server actions
checkbox defaults
submitted selection values
draft creator
existing £10 draft
existing release-ledger row
sales invoice payload
sales invoice amount
Sage posting
VAT
supplier AP
shipping control
shipment batches
receipts
reviews
holds
disputes
refunds
returns
replacements
accounting readiness
order status
```

No operational-row DML is permitted.

No existing invoice or release membership may be edited, reversed, recreated or deleted.

## 10. Function contract protection

The following properties of `internal_customer_invoice_release_queue_v1()` must remain unchanged:

```text
function name
arguments
return columns
return-column order
return types
LANGUAGE plpgsql
SECURITY DEFINER
search_path
owner
PUBLIC revocation
authenticated execution grant
batch admission logic
readiness-preview call
grouping
totals
status vocabulary
queue actions
ordering
```

Only the two aggregate count expressions may change.

## 11. Migration preflight

The migration must:

1. confirm these objects exist:

```sql
public.internal_customer_invoice_release_queue_v1()
public.customer_sales_release_lines
public.sales_invoices
```

2. capture and require the exact current live MD5 of:

```sql
pg_get_functiondef(
  'public.internal_customer_invoice_release_queue_v1()'::regprocedure
)
```

Do not reuse the historical fingerprint:

```text
7c4587e4ca91e5bf246f3f02281b2b98
```

That fingerprint predates the already-installed exact-clean batch-admission correction.

The correct starting fingerprint must be obtained from the current installed database immediately before implementation.

3. require the current queue definition to contain exactly one existing `draft_count` expression and one existing `posted_count` expression matching the governed starting body.

A mismatch must stop the migration.

## 12. Migration implementation

The migration should use an exact guarded function-definition replacement.

It must verify that:

```text
the old draft count occurs exactly once
the old posted count occurs exactly once
the new exact membership predicate is installed twice
the function signature remains unchanged
the return structure remains unchanged
```

Then:

```sql
NOTIFY pgrst, 'reload schema';
```

The migration performs DDL only.

## 13. Required regression

A rollback-only or read-only regression must prove:

1. `J040826` has:

```text
draft_count = 1
readiness_status = draft_exists
created_draft_count = 1
```

2. `J040826v1` has:

```text
draft_count = 0
readiness_status = blocked
created_draft_count = 0
```

3. The existing draft still has:

```text
sales_invoice_id:
a3c939e4-0abb-4047-b828-cdc137130fd4

amount:
£10

invoice type:
supplementary
```

4. The draft payload contains only:

```text
J040826
1d8ed4af-4d35-4b2d-9913-9bae1a20a717
```

5. The active release ledger contains exactly one line:

```text
allocation:
9dd8c47c-9dd9-4191-910b-41095f15feee

quantity:
1

goods:
£10
```

6. `J040826v1` has no active release membership linked to that invoice.

7. Queue amounts, ready counts, blocker counts and line counts remain unchanged apart from the corrected draft/posted classification.

8. Function permissions and return schema remain unchanged.

9. Protected Mini Build 1–3 function fingerprints remain unchanged, including:

```text
internal_customer_sales_release_sources_v1
internal_customer_invoice_release_create_drafts_v1
internal_shipping_customer_invoice_readiness_preview_v1
internal_shipping_customer_invoice_remaining_preview_v1
customer_sales_release_guard_v1
customer_sales_release_financial_guard_v1
shipper_shipment_batch_effective_lines_v1
```

10. No table rows are inserted, updated or deleted by the regression.

## 14. Rollback

The compensating rollback must restore the exact previous queue definition captured by the migration preflight.

Rollback must not change:

```text
existing invoices
release-ledger memberships
exact-clean helper
resolver correction
release guard correction
readiness preview
draft creator
```

## 15. Acceptance statement

A queue row represents one shipment booking.

Therefore:

> A booking may show `Draft already exists` only when that exact shipment batch is present in the active release ledger of the draft.

An invoice on the same commercial parent order must not make an unincluded sibling booking appear drafted.

This is a single Mini Build 4 read-only classification correction with no effect on Mini Builds 1–3 or any operational data.
