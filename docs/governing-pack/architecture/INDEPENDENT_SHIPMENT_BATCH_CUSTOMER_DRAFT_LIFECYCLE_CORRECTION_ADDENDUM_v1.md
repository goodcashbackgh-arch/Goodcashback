# Independent Shipment-Batch Customer Draft Lifecycle Correction Addendum v1

**Status:** governing correction and superseding authority

**Effective date:** 6 August 2026

## 1. Supersession

This addendum supersedes any prior statement in:

- `EXACT_SHIPMENT_BATCH_DRAFT_STATUS_CORRECTION_ADDENDUM_v1.md`; and
- `CUSTOMER_RELEASE_QUEUE_EXACT_SHIPMENT_BATCH_DRAFT_STATUS_AMENDMENT_v1.md`

that requires an uninvoiced sibling shipment batch to remain blocked merely because another shipment batch on the same commercial parent has an active draft.

That blocked-sibling acceptance rule was incorrect.

The exact shipment-batch queue counting installed by `20260806142500_exact_shipment_batch_draft_status_v1.sql` remains valid and is retained.

## 2. Required business behaviour

Each shipment booking is an independent customer-release draft unit.

For two shipment batches that share one commercial parent order:

```text
J040826
J040826v1
```

creating a draft for `J040826` must:

- include only `J040826` release memberships;
- leave `J040826v1` uninvoiced;
- leave `J040826v1` evaluated against its own source readiness;
- allow `J040826v1` to be selected later and create its own separate draft.

The existence of a draft for one shipment batch must not block, absorb, reuse or relabel a different shipment batch solely because both share a commercial parent order.

## 3. Last known-good baseline retained

The following already-installed behaviour is correct and must not be rolled back or rewritten:

- exact immutable clean-line proof;
- exact-clean resolver receipt compatibility;
- exact-clean queue batch admission;
- exact-clean release-ledger guard compatibility;
- the existing £10 supplementary draft for `J040826`;
- the single active `J040826` release membership;
- exact shipment-batch queue draft and posted counts;
- Mini Build 1 and 2 receipt, tracking, allocation and shipment authorities;
- Mini Build 3 durable release ledger, cumulative release guards and Sage payload authority;
- Mini Build 4 queue fields and UI contract.

No existing invoice, release membership, receipt, shipment, order or accounting row may be edited, reversed, recreated or deleted.

## 4. Confirmed original blocking chain

Three pre-existing parent-order controls prevent independent sibling drafts.

### 4.1 Resolver gate

`public.internal_customer_sales_release_sources_v1(uuid)` currently sets `has_active_draft` when any main or supplementary draft exists for the commercial parent order.

This causes every sibling shipment batch on that parent to receive:

```text
customer_sales_release_draft_already_exists
```

even when that exact shipment batch has no release membership in the draft.

### 4.2 Draft creator reuse gate

`public.internal_customer_invoice_release_create_drafts_v1(uuid[])` currently finds any active draft by commercial parent order and returns:

```text
skipped_draft_already_exists
```

It does not require the selected shipment batch to be represented in that draft.

The creator also groups selected rows only by commercial parent order, so sibling shipment batches selected together may be absorbed into one draft.

### 4.3 Database uniqueness gate

The partial unique index:

```sql
public.uq_sales_invoices_active_release_draft_v1
```

permits only one active main or supplementary draft per commercial parent order.

Even after correcting the resolver and creator, that index would reject insertion of a separate sibling draft.

## 5. Governing invariants

### 5.1 Existing draft identity

A shipment batch has an existing active draft only when an active release-ledger membership exists with:

```sql
release_line.source_shipment_batch_id = selected shipment_batch_id
AND release_line.release_status = 'active'
AND invoice.sage_status = 'draft'
AND invoice.invoice_type IN ('main', 'supplementary')
```

Order-level invoice existence alone is insufficient.

### 5.2 Independent draft unit

The draft creator must process each selected shipment batch as a separate unit, even when several selected batches share one commercial parent order.

One created invoice may contain release memberships for only one selected shipment batch.

### 5.3 Main and supplementary routing

The existing one-non-void-main rule remains unchanged.

For one commercial parent:

- the first non-void customer sales release may be `main`;
- every later independent shipment-batch release is `supplementary` and links to the existing main where the current route requires it.

Multiple active supplementary drafts for different shipment batches on the same parent are permitted.

### 5.4 Duplicate and concurrency protection

Removing the one-draft-per-order index must not weaken duplicate release protection.

The following controls must remain or be added:

- parent-order advisory transaction lock remains unchanged;
- exact tracking-allocation cumulative quantity and value guards remain unchanged;
- exact shipment-batch shipping cumulative guard remains unchanged;
- exact active membership fingerprint must be unique across active release-ledger rows;
- an exact shipment batch already represented in an active draft is skipped/reused only for that exact draft;
- legacy invoices without durable release provenance remain blocked through the existing legacy-issue route.

## 6. Permitted implementation boundary

A new follow-up migration may change only:

1. `public.internal_customer_sales_release_sources_v1(uuid)` active-draft predicate;
2. `public.internal_customer_invoice_release_create_drafts_v1(uuid[])` draft-unit grouping and exact existing-draft lookup;
3. the active-draft concurrency indexes required to replace `uq_sales_invoices_active_release_draft_v1` safely;
4. one private helper used only to resolve an exact shipment batch's active draft, if required.

The already-installed queue count correction remains unchanged.

## 7. Explicit non-scope

Do not change:

```text
exact-clean helper logic
receipt predicates other than preserving the installed compatibility
queue batch admission
queue draft/posted exact count logic
readiness preview signature or body
remaining preview
draft result signature
release-ledger columns
release guard
financial guard
invoice-to-ledger total guard
Sage payload resolver
VAT
supplier AP
shipping documents
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
UI files
server actions
existing invoices
existing release memberships
```

No persistent operational-row DML is permitted in the migration.

## 8. Required queue behaviour

After installation and before creating the second draft:

```text
J040826
- exact active membership exists
- readiness_status = draft_exists
- created_draft_count = 1
- queue_action = review_existing_draft

J040826v1
- no active membership exists
- created_draft_count = 0
- must not contain customer_sales_release_draft_already_exists
- must be ready_to_create_draft when its own lines have no other legitimate blocker
- queue_action = create_draft
```

A legitimate source-specific blocker may still block `J040826v1`; the sibling draft itself may not.

## 9. Required creator behaviour

A rollback-only authenticated regression must select only `J040826v1` and call the real draft creator.

Inside the transaction it must prove:

- result status is `draft_created`;
- the new invoice ID differs from `a3c939e4-0abb-4047-b828-cdc137130fd4`;
- the new invoice has the same commercial parent order;
- the new invoice is supplementary where the existing main route requires it;
- every active membership on the new invoice has `source_shipment_batch_id = J040826v1`;
- no `J040826` membership is attached to the new invoice;
- the existing £10 `J040826` invoice and membership remain byte-for-byte unchanged;
- a repeated creator call for `J040826v1` returns the exact existing-draft skip and creates no duplicate membership;
- the entire test transaction is rolled back.

## 10. Index replacement requirement

Before dropping `uq_sales_invoices_active_release_draft_v1`, migration preflight must prove there are no duplicate active membership fingerprints.

The migration must then install:

- a non-unique lookup index for active release drafts by commercial parent; and
- a partial unique index on active `customer_sales_release_lines.membership_fingerprint`.

The exact names and definitions must be regression-tested.

## 11. Acceptance statement

A commercial parent may have several shipment bookings and several supplementary customer-release drafts.

Therefore:

> A draft for one shipment batch must never prevent a different shipment batch from being independently selected and drafted later.

Duplicate protection attaches to exact active release membership, not to the commercial parent order as a whole.
