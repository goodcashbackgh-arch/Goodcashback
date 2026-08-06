# Independent Shipment-Batch Customer Sales Draft Compatibility Correction Addendum v1

**Status:** governing technical specification and non-regression authority

**Effective date:** 6 August 2026

**Implementation type:** new forward Mini-build 3 compatibility migration

## 1. Purpose

Correct the inherited parent-wide active-draft restriction without reversing or weakening the installed exact-clean customer-release work.

The commercial parent order remains the sales-document family, one-non-void-main and advisory-lock boundary. Each selected shipment batch becomes its own draft-creation, retry and active-membership unit.

```text
commercial parent order = document family, main decision and concurrency boundary
selected shipment batch = draft creation and retry boundary
active membership fingerprint = duplicate release identity
```

## 2. Technical history retained

The original mixed-receipt defect and the later sibling-draft defect are separate consecutive gates.

The following installed corrections remain governing and must not be rolled back:

- `20260806131500_exact_clean_line_customer_release_compatibility_v1.sql`;
- `20260806133500_exact_clean_line_release_guard_compatibility_v1.sql`;
- `20260806142500_exact_shipment_batch_draft_status_v1.sql`.

They correctly preserve exact-clean proof, queue admission, release-guard qualification and exact shipment-batch draft/posted counting.

The existing J040826 £10 supplementary draft and its active release membership are correct operational records and must not be edited, deleted, reversed, recreated or absorbed into another document.

## 3. Confirmed remaining defect

The remaining parent-wide restriction is imposed by:

1. `internal_customer_sales_release_sources_v1(uuid)` detecting any active draft on the commercial parent;
2. `internal_customer_invoice_release_create_drafts_v1(uuid[])` grouping selected rows by commercial parent and reusing any parent draft;
3. `uq_sales_invoices_active_release_draft_v1` permitting only one active main/supplementary draft per parent.

The exact queue-count correction did not create this restriction. It correctly proves that J040826 has one exact draft membership and J040826v1 has none.

## 4. Governing invariants

### 4.1 Exact active-draft identity

A shipment batch has an existing active draft only when an active durable release membership for that exact batch belongs to a draft invoice:

```sql
release_line.source_shipment_batch_id = selected_shipment_batch_id
AND release_line.release_status = 'active'
AND invoice.invoice_type IN ('main', 'supplementary')
AND invoice.sage_status = 'draft'
```

An unrelated draft on the same commercial parent is insufficient.

### 4.2 Independent selection units

Each distinct selected shipment batch must be processed independently. Two sibling batches selected together must not be recombined into one parent-order draft.

### 4.3 Parent lock retained

The existing parent advisory transaction lock and parent order row lock remain. They serialise main/supplementary decisions and overlapping release attempts but must not prohibit disjoint sibling drafts.

Where one invocation contains batches from more than one commercial parent, processing must be deterministically ordered by `commercial_parent_order_id`, then `shipment_batch_id`, before taking parent locks. This preserves batch-level creation while preventing inconsistent multi-parent lock ordering.

### 4.4 Main and supplementary routing retained

`uq_sales_invoices_nonvoid_main_v1` remains unchanged.

The first non-void release for a commercial parent is `main`. Every later eligible release is `supplementary` and links to the existing main under the current contract. Multiple active supplementary drafts may coexist only where their active release memberships are disjoint.

### 4.5 Exact retry

Retrying one shipment batch must return only the active draft containing that batch's active membership and must create neither a second invoice nor a duplicate membership.

## 5. Permitted production changes

One new migration may change only:

```text
public.internal_customer_sales_release_sources_v1(uuid)
public.internal_customer_invoice_release_create_drafts_v1(uuid[])
public.uq_sales_invoices_active_release_draft_v1
```

It may add only:

```text
public.idx_sales_invoices_active_release_draft_v2
public.uq_csrl_active_membership_fingerprint_v1
```

No queue function change is permitted or required.

## 6. Resolver correction

Replace only the parent-wide `has_active_draft` expression with an exact active-membership lookup joining `customer_sales_release_lines` to `sales_invoices` for the current shipment batch.

The blocker value remains:

```text
customer_sales_release_draft_already_exists
```

Its scope becomes exact to the selected batch.

All unrelated resolver logic must remain semantically unchanged, including:

- exact-clean proof and package receipt compatibility;
- supplier approval and progression;
- remaining quantity and value calculations;
- delivery, discount and shipment-batch shipping deltas;
- legacy provenance, hold and exception blockers;
- shipping-only-main and fully-released rules;
- membership fingerprint construction;
- signature, return structure, security and grants.

## 7. Draft creator correction

The creator must:

1. retain the current input and return contract;
2. load only submitted shipment batches through the current resolver;
3. iterate by distinct `shipment_batch_id`, not commercial parent, while ordering work by `commercial_parent_order_id`, then `shipment_batch_id`;
4. prove each batch maps to exactly one commercial parent;
5. retain the parent advisory and row locks;
6. detect an existing draft only through active membership for that exact batch;
7. return `skipped_draft_already_exists` only for that exact batch;
8. aggregate amount, payload and release inserts only from the current batch;
9. retain the existing parent-wide main lookup and main/supplementary routing;
10. return one result per selected batch.

## 8. Index correction

Keep unchanged:

```text
uq_sales_invoices_nonvoid_main_v1
```

Remove:

```text
uq_sales_invoices_active_release_draft_v1
```

Replace its lookup role with a non-unique partial index on active main/supplementary drafts by parent order.

Add a partial unique index on:

```text
customer_sales_release_lines.membership_fingerprint
WHERE release_status = 'active'
```

The migration must transactionally prove zero active fingerprint collisions immediately before creating that unique index. A previous v6 result is evidence, not a substitute for migration preflight.

## 9. Mini-build boundary

### Mini-builds 1 and 2

No change to supplier-invoice identity, reconciliation, progression, tracking, package, shipment or payment-allocation authorities.

### Mini-build 3

Only the draft-identity compatibility correction in sections 6–8 is authorised. Quantity, value, delivery, discount, shipping, receipt, hold, exception, financial, total, release-ledger, Sage, VAT and accounting guards remain unchanged.

### Mini-build 4

No change to review, hold, dispute, refund, credit, replacement, return, shipment-blocking or lifecycle behaviour. The current queue remains a projection consuming Mini-build 3 ledger truth.

## 10. Operational-data boundary

The production migration is DDL/function-definition only. It must perform no operational-row `INSERT`, `UPDATE` or `DELETE`.

In particular, it must not alter the existing J040826 invoice or release line.

## 11. Required preflight

Before DDL, fail closed unless:

- required functions, tables and indexes exist;
- the creator has the expected installed fingerprint and governed parent-wide shape;
- the resolver contains the installed exact-clean predicate and exactly one governed parent-wide draft expression;
- `uq_sales_invoices_nonvoid_main_v1` is unchanged;
- `uq_sales_invoices_active_release_draft_v1` has the expected parent-wide definition;
- no duplicate active membership fingerprint exists.

Index validation must use PostgreSQL catalogue structure and parsed predicates, not formatting-sensitive comparisons against `pg_get_indexdef()` output.

## 12. Required rollback-only regression

The authoritative regression must prove:

- J040826's invoice ID, £10 amount, payload hash, release-line ID and membership fingerprint remain unchanged;
- retrying J040826 returns its own existing draft without duplication;
- J040826v1 is not blocked solely by J040826's draft;
- J040826v1 creates a different supplementary draft containing only its own memberships;
- retrying J040826v1 returns that exact draft without duplication;
- selecting J040826 and J040826v1 together returns two isolated batch results and never one combined parent draft;
- active membership fingerprints remain unique;
- the one-non-void-main rule remains effective;
- all protected Mini-build 1–4 authorities remain unchanged;
- the transaction rolls back completely.

## 13. Supersession

This addendum supersedes any requirement in:

- `EXACT_SHIPMENT_BATCH_DRAFT_STATUS_CORRECTION_ADDENDUM_v1.md`;
- `CUSTOMER_RELEASE_QUEUE_EXACT_SHIPMENT_BATCH_DRAFT_STATUS_AMENDMENT_v1.md`;

that treats J040826v1's sibling-draft blockage as expected, classifies the defect as queue-only, or prohibits correction of the resolver, creator or parent-wide active-draft index.

Their exact shipment-batch queue-count rule remains valid.

## 14. Acceptance statement

The commercial parent remains the sales-document family, main-invoice and concurrency boundary. The selected shipment batch is the draft-creation and retry unit. Duplicate protection operates on active exact release membership, not by prohibiting independent sibling drafts under one commercial parent.