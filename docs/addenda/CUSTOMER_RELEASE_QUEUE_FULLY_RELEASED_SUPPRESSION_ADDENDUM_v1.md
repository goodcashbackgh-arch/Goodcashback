# CUSTOMER RELEASE QUEUE FULLY-RELEASED SUPPRESSION ADDENDUM v1

## Objective

Stop fully released, already invoiced shipment batches from reappearing as selectable customer invoice drafts after the existing draft is posted to Sage.

## Confirmed defect

The authoritative source resolver correctly returns exhausted source rows with:

- `blocker = source_fully_released`;
- zero remaining goods, shipping and customer charge;
- `sales_invoice_state = main_sales_invoice_exists` where applicable.

The release queue must never treat those rows as ready or carry their historical allocation values into the actionable totals.

## Surgical implementation boundary

This patch may change only:

1. `public.internal_shipping_customer_invoice_readiness_preview_v1(uuid)`;
2. `public.internal_customer_invoice_release_queue_v1()`;
3. a rollback-only regression proof file.

The existing draft creator is not replaced because it already recalculates the authoritative source resolver, accepts only `blocker IS NULL`, and refuses a non-positive total.

## Required behaviour

### Readiness preview

- Only rows with `blocker IS NULL` and `customer_charge_amount_gbp > 0` contribute to ready totals and line payloads.
- A blocked row remains visible only as blocked diagnostic evidence when there are no genuinely ready rows.
- Blocked rows contribute zero to proposed goods, shipping and customer totals.

### Queue

- A batch is `ready_to_create_draft` only when it has at least one genuinely ready positive-value line and a positive proposed total.
- An existing draft remains `draft_exists`.
- A fully released batch with a posted invoice is `posted_exists` and is not selectable.
- A later genuine positive goods or approved shipping delta remains eligible and is routed by the existing resolver as supplementary.

## Explicit non-scope

Do not change:

- Mini-build 4 review cycles or memberships;
- `internal_customer_sales_release_sources_v1(uuid)`;
- the durable `customer_sales_release_lines` ledger;
- main/supplementary routing rules;
- supplier invoices, supplier lines or progression;
- shipment batches, tracking, receipts or allocations;
- shipping documents or approved shipping allocations;
- shipper AP or customer recharge accounting separation;
- Sage payloads, snapshots, posting status or posted invoices;
- VAT, funding, settlement, credit, refund or order-status functions;
- UI files;
- historical rows or existing invoices.

## Required regression proof

The rollback-only regression must prove:

1. blocked `source_fully_released` rows contribute zero ready count and zero ready value;
2. a fully released posted batch resolves to `posted_exists`, never `ready_to_create_draft`;
3. an existing draft remains `draft_exists`;
4. a genuine positive unblocked delta remains actionable;
5. the draft creator still contains authoritative source recalculation, `blocker IS NULL` filtering and the non-positive amount guard;
6. protected source, ledger, Sage, Mini-build 4, AP, VAT and status definitions are unchanged by the migration.

## Acceptance statement

After deployment, creating a customer invoice draft removes the batch from the ready list; posting that draft to Sage does not make the same exhausted batch reappear; only a genuine later positive delta can make it actionable again.