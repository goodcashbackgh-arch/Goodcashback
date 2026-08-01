# Hybrid Physical Receipt Foundation Impact Map v1

Status: implementation preflight for foundation build only

Date: 1 August 2026

Branch baseline: `7c9ca34badee38e92c86c546e6f53a93af8da0b9`

Governing authority: `docs/governing-pack/architecture/HYBRID_PHYSICAL_RECEIPT_QUANTITY_FULFILMENT_AND_REMEDY_CONTROL_ADDENDUM_v1.md`

## Frozen scope

This build is limited to three files:

1. this impact map;
2. one additive Supabase foundation migration;
3. one rollback-only SQL regression.

It does not change application pages, server actions, existing RPC/view bodies, review behaviour, shipment behaviour, customer-sales behaviour, replacement-child behaviour, closure or reconciliation.

It does not activate the new shipper, importer or supervisor workflow.

## Existing authorities inspected

The preflight inspected the current repository definitions for:

- `shipper_package_receipts` and `shipper_record_package_receipt_v1`;
- `order_tracking_line_allocations`;
- `customer_review_cycle_memberships` and materialisation;
- `customer_hold_review_memberships` and customer-hold refund conversion;
- `shipper_shipment_batch_line_memberships` and `shipper_shipment_batch_effective_lines_v1`;
- `customer_sales_release_lines`;
- `disputes`, `dispute_lines`, `orders`, `operators`, `operator_importers`, `shipper_users` and `staff`.

The current exact review, hold, shipment and customer-release ledgers remain authoritative.

## Additive objects allowed in this build

The migration may add only:

- receipt model/finalisation/idempotency columns on `shipper_package_receipts`;
- `shipper_package_receipt_line_dispositions`;
- `shipper_package_receipt_evidence`;
- `physical_receipt_reviews`;
- `physical_exception_remedy_allocations`;
- narrowly scoped integrity/finalisation functions and triggers for those objects;
- private `tracking_allocation_fulfilment_position_v1`;
- required indexes, constraints, comments, RLS and grants.

The existing receipt-status vocabulary remains unchanged.

## Existing contracts protected from replacement

The migration must not replace:

```text
shipper_record_package_receipt_v1
shipper_package_dashboard_v1
customer_review_cycle_candidates_v1
internal_materialize_customer_review_cycles_v1
customer_review_receipt_materialize_v1
shipper_tracking_review_state_v1
shipper_shipment_batch_candidates_v1
shipper_create_shipment_batch_v1
shipper_shipment_batch_effective_lines_v1
internal_customer_sales_release_sources_v1
customer_sales_release_guard_v1
customer_sales_release_financial_guard_v1
customer_hold_create_refund_exception_v2
customer_hold_refund_target_lines_v1
create_replacement_child_order
order_has_open_child_exceptions
approve_vat_release
mark_order_accounting_release_ready
recompute_order_status
order_reconciliation_vw
```

No application file is modified.

## Position sources

For each exact tracking allocation, the private position model reads:

- allocated quantity from `order_tracking_line_allocations`;
- finalised v2 dispositions, or full clean quantity from a legacy latest `received_clean` receipt;
- immutable reviewed quantity from `customer_review_cycle_memberships`;
- exact active hold quantity from `customer_hold_review_memberships`;
- legacy unresolved holds from `customer_pre_shipment_hold_requests`, failing closed where exact quantity is unproven;
- shipped quantity from `shipper_shipment_batch_effective_lines_v1`;
- released quantity from active `customer_sales_release_lines`;
- assigned remedy quantity from `physical_exception_remedy_allocations`.

The read model is private to `service_role` in this build.

## Legacy rule

A legacy latest `received_clean` receipt remains fully clean in the new read model.

A legacy latest `received_damaged`, `held_query` or `not_received` receipt receives no invented quantity. Automatic availability is zero and the position is marked invalid.

Existing receipt rows are not rewritten; they receive only additive default model metadata. `shipper_record_package_receipt_v1` keeps its current signature and grant.

## Integrity and access boundary

A v2 receipt becomes authoritative only after all positive allocations have exact dispositions and each disposition total equals the exact allocation quantity.

Line dispositions and evidence are immutable. Corrections use a later receipt snapshot.

Physical review/remedy records retain provenance but do not replace the existing dispute and retailer-conversation state machine.

Authenticated users receive scoped read access only. New writes remain RPC/service-role controlled; no direct authenticated insert/update/delete policy is introduced.

## Explicitly excluded later work

This foundation does not include:

- `shipper_record_package_receipt_v2` or upload orchestration;
- shipper/importer/supervisor page changes;
- conversion into the existing dispute route;
- quantity-aware review, shipment or customer-sales replacements;
- replacement-child and closure hardening;
- reconciliation repair;
- changes to current open-dispute uniqueness.

## Validation gate

Before merge or production use:

1. apply the foundation migration in the target Supabase environment;
2. run the rollback-only regression and require `PASS`;
3. prove protected function fingerprints and signatures remain unchanged;
4. smoke-test existing legacy clean receipt, review, shipment and release paths;
5. confirm the branch contains only the three frozen files.

Any mismatch stops the build. No quantity or provenance may be guessed.
