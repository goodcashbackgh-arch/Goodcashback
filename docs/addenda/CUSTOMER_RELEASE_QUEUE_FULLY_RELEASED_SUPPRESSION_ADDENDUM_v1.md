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

---

## Exact clean-line mixed-package compatibility amendment — 6 August 2026

### Authority

This amendment must be read with:

`docs/governing-pack/architecture/HYBRID_PHYSICAL_RECEIPT_EXACT_CLEAN_LINE_CUSTOMER_RELEASE_COMPATIBILITY_ADDENDUM_v1.md`

Where this amendment is more specific about an exact clean shipment line inside a mixed or damaged package, it controls over the earlier implementation-boundary and non-scope wording above.

The earlier fully-released suppression behaviour remains unchanged.

### Confirmed live facts

The read-only live database preflight confirmed for booking `J040826`:

```text
original allocations: 5
authoritative effective shipment lines: 1
proven unreleased exact-clean lines: 1
```

The exact admitted line is:

```text
tracking_line_allocation_id: 9dd8c47c-9dd9-4191-910b-41095f15feee
source_mode: immutable_snapshot
qty_in_shipment: 1
shipment goods value: £10
source_receipt_model: v2_exact
physical_clean_qty: 1
reviewed_qty: 1
shipped_qty: 1
position_valid_yn: true
position_blocker: null
sales release exists: false
active sales draft exists: false
```

The four excluded allocations each have zero clean quantity, exception quantity `1`, shipped quantity `0`, no effective shipment membership and failed exact-clean proof.

### Revised surgical boundary for this compatibility correction

For this exact platform-wide compatibility patch, the permitted production change is limited to:

1. add `public.internal_customer_sales_release_exact_clean_proof_v1(uuid,uuid)`;
2. change only the receipt-qualification predicate inside `public.internal_customer_sales_release_sources_v1(uuid)`;
3. change only the batch-admission predicate inside `public.internal_customer_invoice_release_queue_v1()`;
4. add rollback-only regression proof.

No readiness-preview definition, draft creator, remaining preview, release guard, financial guard, ledger, Sage, VAT, AP, receipt, shipment, refund, replacement or UI object may be changed.

### Resolver compatibility rule

The existing package-level clean route remains unchanged.

The resolver may bypass `package_not_received_clean` only when the new private helper proves the exact effective shipment membership:

```sql
source_mode = 'immutable_snapshot'
AND qty_in_shipment > 0
AND source_receipt_model = 'v2_exact'
AND position_valid_yn = true
AND physical_clean_qty + 0.0005 >= shipped_qty
AND shipped_qty + 0.0005 >= qty_in_shipment
```

The permitted predicate is:

```sql
WHEN latest_receipt_status IS DISTINCT FROM 'received_clean'
 AND NOT public.internal_customer_sales_release_exact_clean_proof_v1(
       batch_id,
       tracking_line_allocation_id
     )
THEN 'package_not_received_clean'
```

No blocker name, return column, amount calculation, blocker order, main/supplementary rule or membership fingerprint may change.

### Queue compatibility rule

The existing batch-admission route must remain the first branch:

```sql
COALESCE(receipt_status_summary, '') = 'received_clean'
```

A non-clean batch may be additionally admitted only when an `EXISTS` check finds at least one authoritative effective shipment line whose exact-clean helper proof is true.

The unchanged readiness preview must continue to determine line readiness, values and blockers after batch admission.

### Live dependency protection

The live database found exactly three consumers of `internal_customer_sales_release_sources_v1(uuid)`:

```text
internal_customer_invoice_release_create_drafts_v1(uuid[])
MD5 2e75a619e3cc3cc2fc364d3cb5a85cc3

internal_shipping_customer_invoice_readiness_preview_v1(uuid)
MD5 25be89183956fe7f756472b0075b4f58

internal_shipping_customer_invoice_remaining_preview_v1(uuid)
MD5 0d6c54c50d5594a72b2af79700655020
```

None may be edited. All must continue consuming the resolver's unchanged signature and return structure.

### Live starting fingerprints

The migration preflight must require:

```text
internal_customer_sales_release_sources_v1(uuid)
1ae9d8f827ee5f08a7103fbc2157e130

internal_customer_invoice_release_queue_v1()
7c4587e4ca91e5bf246f3f02281b2b98
```

A mismatch stops the migration.

### Protected unchanged fingerprints

The regression must confirm these remain unchanged:

```text
internal_tracking_allocation_fulfilment_position_v1(uuid,uuid,uuid)
ae13557433f5e8500985b00266347807

internal_tracking_allocation_fulfilment_routing_position_v2(uuid,uuid,uuid)
77b92854c8cdaca46db4471a32337b1f

shipper_shipment_batch_effective_lines_v1(uuid)
82b4ec6bfd8f9fba09d37871917d0dc4

shipper_create_shipment_batch_v2(...)
62f5a84b0dd79ec7b09c5ef048747c65

internal_customer_invoice_release_create_drafts_v1(uuid[])
2e75a619e3cc3cc2fc364d3cb5a85cc3

internal_shipping_customer_invoice_readiness_preview_v1(uuid)
25be89183956fe7f756472b0075b4f58

internal_shipping_customer_invoice_remaining_preview_v1(uuid)
0d6c54c50d5594a72b2af79700655020

customer_sales_release_guard_v1()
d50b362d97a46f36a07acdb237231b46

customer_sales_release_financial_guard_v1()
c492d47d33c6419d14d4cb26799fbfb9

internal_resolved_customer_sales_sage_payload_v1(uuid)
4f8266c7932461b4e19afc789817d31f

internal_customer_sales_sage_payload_pre_ledger_v1(uuid)
e3bd71d7ec951731d60b0f04a18f5960

approve_vat_release(uuid,uuid,jsonb)
13491a2d250a480ebb1ac607ce7acce5

mark_order_accounting_release_ready(uuid,uuid)
dacaf00c6470a626cfc2d7e7aac2ccb8

recompute_order_status(uuid)
f7c40c868381252a5432f70894ca2b2f
```

### Mini Build impact boundary

```text
Mini Builds 1–2: definitions and behaviour unchanged.
Mini Build 3: one receipt-qualification predicate expanded for strictly proven exact clean shipment lines.
Mini Build 4: one queue batch-admission predicate expanded so the existing queue can discover those lines.
```

All downstream signatures and return structures remain unchanged.

The four damaged `J040826` allocations remain excluded by authoritative effective shipment membership before customer-sales calculations begin.

### Amendment acceptance statement

Existing clean-package and fully-released suppression behaviour must remain output-identical. Existing uncertain or damaged legacy packages remain blocked. Only exact immutable shipment memberships currently proven within valid v2 clean quantity may enter the unchanged customer-sales draft pipeline.