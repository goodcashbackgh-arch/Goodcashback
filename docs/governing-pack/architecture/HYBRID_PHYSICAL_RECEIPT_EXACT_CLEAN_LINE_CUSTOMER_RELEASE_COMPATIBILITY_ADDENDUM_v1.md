# Hybrid Physical Receipt Exact Clean-Line Customer Release Compatibility Addendum v1

**Status:** governing technical specification and non-regression authority

**Effective date:** 6 August 2026

**Live database preflight:** `docs/testing/20260806_customer_sales_exact_clean_patch_db_preflight_v1.sql`

## 1. Purpose

This addendum governs the platform-wide customer-sales compatibility correction for a shipment batch where:

- the package-level receipt status is mixed or damaged;
- one or more exact tracking allocations were nevertheless received clean;
- only those exact clean quantities were admitted to the authoritative shipment-line snapshot; and
- the existing customer-sales resolver and queue still reject the line or batch because they rely on the parent package's aggregate receipt status.

The correction must permit only a strictly proven exact clean shipment membership to enter the existing Mini Build 3 and Mini Build 4 customer-sales route.

It must not relabel the package as clean, weaken legacy fail-closed behaviour, reconstruct excluded package allocations, or change any upstream receipt, review, hold, shipment, replacement or refund fact.

## 2. Confirmed live defect and evidence

The live preflight for booking `J040826` confirmed:

```text
shipment batch id: 1d8ed4af-4d35-4b2d-9913-9bae1a20a717
original allocations: 5
authoritative effective shipment lines: 1
proven unreleased exact-clean lines: 1
```

The single effective shipment line is:

```text
tracking_line_allocation_id: 9dd8c47c-9dd9-4191-910b-41095f15feee
source_mode: immutable_snapshot
qty_in_shipment: 1
shipment_goods_value_gbp: 10
source_receipt_model: v2_exact
physical_clean_qty: 1
reviewed_qty: 1
shipped_qty: 1
position_valid_yn: true
position_blocker: null
ledger_released_qty: 0
active sales draft: false
```

The parent package remains truthfully:

```text
receipt_status: received_damaged
receipt_model_version: 2
receipt_state: finalised
```

The other four allocations each have:

```text
physical_clean_qty: 0
physical_exception_qty: 1
shipped_qty: 0
no effective shipment membership
proposed exact-clean proof: false
```

Therefore the authoritative shipment snapshot and exact fulfilment position already separate the one clean line from the four diverted lines. The customer-sales path is the stale package-level consumer.

## 3. Governing invariant

Customer release must use the same exact physical boundary that admitted quantity to shipment.

For a fully clean legacy or v2 package, the existing package-level `received_clean` route remains unchanged.

For a mixed v2 package, customer release may proceed only for an exact immutable shipment membership that remains proven against the current fulfilment position.

The invariant is:

```text
customer releasable quantity
<= authoritative effective shipment quantity
<= valid exact physical clean quantity
```

A package-level damaged status must continue to block every line that lacks this exact proof.

## 4. Smallest permitted production patch

The production patch is limited to exactly three database objects:

1. add one private stable read-only helper:
   `public.internal_customer_sales_release_exact_clean_proof_v1(uuid, uuid)`;
2. change only the package-receipt qualification predicate inside:
   `public.internal_customer_sales_release_sources_v1(uuid)`;
3. change only the batch-admission predicate inside:
   `public.internal_customer_invoice_release_queue_v1()`.

No application file, table, column, index, trigger, view, enum, RLS policy or operational row may be changed by this patch.

## 5. Private exact-clean proof helper

Required signature:

```sql
public.internal_customer_sales_release_exact_clean_proof_v1(
  p_shipment_batch_id uuid,
  p_tracking_line_allocation_id uuid
)
RETURNS boolean
```

Required attributes:

```text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
```

Direct execution must be revoked from `PUBLIC`, `anon` and `authenticated`. A `service_role` diagnostic grant is permitted.

The helper may return `true` only when the exact effective line satisfies every condition below:

```sql
source_mode = 'immutable_snapshot'
AND qty_in_shipment > 0
AND source_receipt_model = 'v2_exact'
AND position_valid_yn = true
AND physical_clean_qty + 0.0005 >= shipped_qty
AND shipped_qty + 0.0005 >= qty_in_shipment
```

The helper must obtain shipment identity from `shipper_shipment_batch_effective_lines_v1(uuid)` and current physical position from `internal_tracking_allocation_fulfilment_position_v1(uuid, uuid, uuid)`.

It must not trust `immutable_snapshot` alone. Any missing membership, non-v2 receipt, invalid position, quantity mismatch or later integrity anomaly returns `false`.

It must not use current `shipment_available_qty` or `shipment_ready_qty`, because those quantities correctly become zero after shipment.

## 6. Resolver predicate correction

The signature, return columns, permissions, ownership, security attributes, calculations, blocker vocabulary and blocker order of `internal_customer_sales_release_sources_v1(uuid)` must remain unchanged.

Only this receipt condition may change:

```sql
WHEN latest_receipt_status IS DISTINCT FROM 'received_clean'
 AND NOT public.internal_customer_sales_release_exact_clean_proof_v1(
       batch_id,
       tracking_line_allocation_id
     )
THEN 'package_not_received_clean'
```

This preserves the original `received_clean` route exactly and adds one strictly proven alternative.

Everything else remains unchanged, including:

- unresolved legacy provenance;
- active-draft suppression;
- supplier-invoice approval;
- supplier-line progression;
- customer holds;
- unresolved exceptions;
- terminal refunds;
- released quantity and value arithmetic;
- approved shipping allocation;
- over-released shipping protection;
- shipping-only main restriction;
- fully released suppression;
- main versus supplementary routing;
- membership fingerprint calculation.

No new blocker value is introduced.

## 7. Queue batch-admission correction

The signature, return columns, permissions, grouping, totals, readiness states, ordering and action labels of `internal_customer_invoice_release_queue_v1()` must remain unchanged.

The existing clean-package route must remain the first branch:

```sql
COALESCE(receipt_status_summary, '') = 'received_clean'
```

One alternative `EXISTS` branch may admit a non-clean batch only when at least one line returned by `shipper_shipment_batch_effective_lines_v1(shipment_batch_id)` passes `internal_customer_sales_release_exact_clean_proof_v1(shipment_batch_id, tracking_line_allocation_id)`.

The queue must continue to pass every admitted batch through the unchanged readiness preview. The helper is only a batch-discovery adapter; it does not calculate invoice values or override downstream blockers.

## 8. Live dependency boundary

The live database found exactly three function consumers of `internal_customer_sales_release_sources_v1(uuid)`:

```text
internal_customer_invoice_release_create_drafts_v1(uuid[])
MD5: 2e75a619e3cc3cc2fc364d3cb5a85cc3

internal_shipping_customer_invoice_readiness_preview_v1(uuid)
MD5: 25be89183956fe7f756472b0075b4f58

internal_shipping_customer_invoice_remaining_preview_v1(uuid)
MD5: 0d6c54c50d5594a72b2af79700655020
```

None of these consumers may be edited. They must continue consuming the resolver's existing unchanged return contract.

## 9. Exact live fingerprints

### 9.1 Definitions intentionally replaced

The migration preflight must require these exact starting fingerprints:

```text
internal_customer_sales_release_sources_v1(uuid)
1ae9d8f827ee5f08a7103fbc2157e130

internal_customer_invoice_release_queue_v1()
7c4587e4ca91e5bf246f3f02281b2b98
```

A mismatch stops the migration.

### 9.2 Definitions that must remain unchanged

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

The migration postflight and regression must verify these fingerprints remain identical.

## 10. Mini Build boundary

### Mini Builds 1 and 2

Definitions and behaviour remain unchanged.

The patch consumes their existing exact receipt, fulfilment-position and shipment-membership facts without modifying them.

### Mini Build 3

One receipt-qualification predicate is expanded for strictly proven exact clean shipment lines.

The release ledger, draft creator, guards, value arithmetic, duplicate protection and main/supplementary route remain unchanged.

### Mini Build 4

One batch-admission predicate is expanded so the existing queue can discover a proven mixed-package line.

Readiness preview, remaining preview, draft creation, Sage, VAT, accounting and status authorities remain unchanged.

## 11. Explicit non-scope

Do not change:

- package receipt status or receipt facts;
- receipt line dispositions;
- review cycles or memberships;
- customer holds;
- shipment candidates, creation or memberships;
- `internal_shipping_control_v1()`;
- disputes, refunds, returns or replacements;
- supplier invoices, supplier lines or AP;
- shipping documents or approved shipping allocations;
- customer-sales release ledger schema or existing rows;
- draft creation;
- Sage payloads or posting;
- VAT approval;
- accounting readiness;
- reconciliation or order status;
- UI pages, components or actions.

The package must remain `received_damaged`. Relabelling it would affect broader platform consumers and is prohibited.

## 12. Required regression proof

Before production deployment, rollback-only regression must prove:

1. every currently successful `received_clean` batch produces identical resolver rows, blockers, quantities and values;
2. legacy damaged or uncertain packages remain blocked and absent unless they have exact v2 proof;
3. `J040826` gains exactly one ready source line;
4. that line is allocation `9dd8c47c-9dd9-4191-910b-41095f15feee`, quantity `1`, goods `£10` and blocker `NULL`;
5. the four exception allocations remain absent from effective shipment and customer release;
6. active draft, supplier approval, line progression, hold, exception, terminal refund, shipping-over-release, shipping-only-main and fully-released behaviours remain unchanged;
7. rollback draft creation writes exactly one active release membership for the proven allocation;
8. a repeated creation attempt creates no duplicate draft or ledger membership;
9. supplier AP, Sage, VAT, refund, replacement, receipt and shipment rows have zero durable differences;
10. every protected fingerprint in section 9.2 remains unchanged.

## 13. Rollback

A compensating migration must:

1. restore the exact previous resolver definition;
2. restore the exact previous queue definition;
3. drop `internal_customer_sales_release_exact_clean_proof_v1(uuid,uuid)`.

The production migration itself performs no operational-row DML, so no business-data rollback is expected.

## 14. Acceptance statement

Existing clean-package sales releases must remain output-identical. Existing uncertain or damaged legacy packages must remain blocked. Only exact immutable shipment memberships that are currently proven within valid v2 clean quantity may gain access to the unchanged customer-sales and accounting pipeline.

This is a platform-wide compatibility correction within the customer-sales release subsystem. It is not a package-specific exception and it does not broaden any upstream or downstream authority beyond the exact proven line.