# Hybrid Physical Receipt Foundation Impact Map v1

Status: audited Build 1 implementation boundary

Date: 1 August 2026

Branch: `agent/hybrid-receipt-foundation-v1`

Branch baseline: `7c9ca34badee38e92c86c546e6f53a93af8da0b9`

Governing authority: `docs/governing-pack/architecture/HYBRID_PHYSICAL_RECEIPT_QUANTITY_FULFILMENT_AND_REMEDY_CONTROL_ADDENDUM_v1.md`

## 1. Build 1 purpose

Build 1 creates only the additive database foundation required by the final hybrid physical-receipt workflow.

It does not activate the v2 shipper journey. The current application remains on:

```text
/shipper/package-receipts
  -> recordPackageReceiptAction
  -> shipper_record_package_receipt_v1
```

It does not replace current customer review, shipment, customer-sales, refund, replacement, return, VAT, Sage, AP, reconciliation, closure or order-status behaviour.

## 2. Ordered files

Build 1 is intentionally split into focused migrations:

```text
supabase/migrations/20260801130000_hybrid_physical_receipt_foundation_v1.sql
supabase/migrations/20260801131000_hybrid_physical_receipt_integrity_v1.sql
supabase/migrations/20260801131500_hybrid_physical_receipt_concurrency_v1.sql
supabase/migrations/20260801131700_hybrid_physical_receipt_legacy_fail_closed_v1.sql
supabase/migrations/20260801132000_hybrid_physical_receipt_position_v1.sql
```

Validation files:

```text
docs/testing/20260801_hybrid_physical_receipt_foundation_source_regression_v1.mjs
docs/testing/20260801_hybrid_physical_receipt_foundation_regression_v1.sql
```

These files form one foundation build. They are not separate business rollouts and do not introduce a feature flag.

## 3. Audited existing authorities

The preflight inspected current definitions for:

- `shipper_package_receipts` and `shipper_record_package_receipt_v1`;
- `order_tracking_line_allocations`;
- `customer_review_cycle_memberships` and the existing materialiser;
- `customer_hold_review_memberships` and customer-hold refund conversion;
- `shipper_shipment_batch_line_memberships` and `shipper_shipment_batch_effective_lines_v1`;
- `customer_sales_release_lines`;
- `disputes`, `dispute_lines`, `orders`, `importers`, `operators`, `operator_importers`, `shipper_users` and `staff`.

Audited live receipt-function fingerprint:

```text
shipper_record_package_receipt_v1(uuid,text,text,text)
27fb972b34258990cfa9d752cd2f927b
```

The schema and integrity migrations stop when that definition differs. They do not replace it.

## 4. Additive receipt-header extension

The schema migration adds compatibility metadata to `shipper_package_receipts`:

```text
receipt_model_version
receipt_state
receipt_submission_id
payload_fingerprint
finalised_at
correction_of_receipt_id
correction_reason
```

Existing and future v1 rows remain:

```text
receipt_model_version = 1
receipt_state = finalised
finalised_at = null
```

That preserves the current v1 insert shape and existing function signature.

A v2 receipt is assembled as `pending` inside one transaction. It must carry an idempotency identity and canonical payload fingerprint. It can become authoritative only after all exact line dispositions balance and the finalisation guard derives its compatibility header status.

A deferred database constraint prevents a pending v2 receipt from being committed. Existing package-level readers therefore cannot observe a persisted half-built v2 snapshot.

## 5. New provenance tables

### 5.1 `shipper_package_receipt_line_dispositions`

Stores exact clean, damaged, missing, wrong and held quantities against one existing tracking allocation.

It does not duplicate supplier invoice lines, OCR lines, order lines or tracking allocations.

### 5.2 `shipper_package_receipt_evidence`

Stores several immutable evidence references for one receipt, optionally linked to one exact affected disposition.

This build does not alter storage buckets or storage policies.

### 5.3 `physical_receipt_reviews`

Stores the physical triage bridge only:

- exact receipt, order, importer and tracking identity;
- importer proposal actor/time;
- supervisor decision actor/time and mandatory decision note;
- approved liability route;
- existing dispute link where the case enters the existing retailer route;
- controlled supersession by a later corrected receipt.

It is not a second retailer-conversation, refund or replacement state machine.

### 5.4 `physical_exception_remedy_allocations`

Stores exact affected-quantity proposals and supervisor-approved allocations separately:

```text
proposed_remedy_type / proposed_remedy_qty / proposed_by_operator_id
approved_remedy_type / approved_remedy_qty / approved_by_staff_id
```

This proves who proposed and who authorised the route without overwriting either decision.

It also retains exact disposition, tracking allocation, supplier line, dispute line, supplier cost mode and replacement-child provenance.

## 6. Integrity rules

The database enforces:

- every v2 header matches the current tracking, order shipper and active shipper user;
- every affected disposition has a factual note;
- cumulative dispositions cannot exceed the exact allocation;
- finalisation requires every positive allocation and exact balance;
- every affected disposition has linked or shared receipt evidence;
- the header status is derived from line facts;
- finalised receipt facts are immutable;
- a later receipt identifies the latest finalised receipt as its correction predecessor;
- a correction cannot reduce clean or affected quantity below irreversible downstream use;
- active legacy holds without exact membership fail closed;
- legacy source lines with dispute history but no package provenance fail closed;
- an existing retailer-linked or supervisor-progressed remedy cannot be silently erased by a corrected receipt;
- importer proposals and approved quantities cannot exceed the affected quantity;
- refund/replacement progression requires the existing exact dispute line;
- replacement progression requires exact parent/child provenance;
- completed replacement requires exact replacement-child tracking allocation;
- rejected, cancelled, rerouted and completed states cannot silently reopen.

## 7. Concurrency and compatibility rules

All receipt writes lock the current tracking record and use the existing order/tracking advisory-lock convention.

This prevents simultaneous receipt histories from both becoming authoritative.

After an exact finalised v2 receipt exists, a legacy v1 write for the same tracking package is rejected. V1 continues to work normally for packages that have never entered exact v2 history.

A correction has one transactional supersession authority. It can supersede only an unlinked preliminary physical review. Proposed remedy rows are cancelled in the same transaction. Supervisor-approved investigation, existing retailer exception linkage or progressed remedy work requires controlled remediation rather than silent supersession.

Remedy writes lock the exact tracking allocation so correction, review, shipment, release and remedy quantities cannot race independently.

## 8. Shared quantity authority

Build 1 adds:

```text
internal_tracking_allocation_fulfilment_position_v1(uuid,uuid,uuid)
tracking_allocation_fulfilment_position_v1
tracking_allocation_fulfilment_anomalies_v1
```

The scoped function is the operational source for later function adaptations. It limits shipment reads to shipment batches relevant to the requested order/package/allocation. The full views are private diagnostics.

Per exact tracking allocation it returns:

```text
allocated_qty
physical_clean_qty
physical_exception_qty
reviewed_qty
active_hold_qty
shipped_qty
customer_released_qty
remedy_assigned_qty
review_available_qty
shipment_available_qty
remedy_available_qty
position_valid_yn
position_blocker
source_receipt_id
source_receipt_model
```

Compatibility rules:

- latest legacy `received_clean` remains fully clean;
- finalised v2 uses exact dispositions;
- legacy damaged/held/not-received without quantities fails closed;
- no receipt fails closed;
- a broken cumulative invariant returns zero availability and an explicit blocker;
- legacy clean shipment basis remains compatible with the current fixed-deadline review route;
- v2 active hold, shipment and active-hold-plus-shipment quantities cannot exceed exact reviewed clean quantity.

Availability clipping occurs only after explicit validity checks. It does not hide over-review, over-hold, over-shipment, over-release or over-remedy anomalies.

## 9. Access boundary

All four new tables have RLS enabled.

Authenticated users receive scoped read access only:

- staff through `is_active_staff()`;
- shipper users for their own receipt facts and evidence;
- importer operators through active importer access.

Physical review/remedy queues are importer/staff data; they are not writable directly by authenticated clients.

Authenticated INSERT, UPDATE and DELETE privileges are revoked. Later workflow writes must use audited `SECURITY DEFINER` RPCs. The scoped quantity function and diagnostic views are private to `service_role` in this build.

## 10. Existing objects deliberately unchanged

No Build 1 migration performs `CREATE OR REPLACE` on an existing operational function or view, including:

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

## 11. Explicitly deferred later work

Build 1 does not include:

- `shipper_record_package_receipt_v2` or storage upload orchestration;
- upgraded shipper receipt UI;
- importer Physical Receipt Exceptions pages;
- supervisor Physical Receipt Reviews pages;
- conversion into the existing dispute route;
- quantity-aware replacements of review, shipment or customer-sales functions;
- replacement-child lifecycle/closure repair;
- reconciliation repair;
- current open-dispute uniqueness repair.

Those are later focused builds governed by the same addendum.

## 12. Validation

The source regression verifies the repository itself:

- exact changed-file scope;
- exact five-migration order;
- no application/runtime files;
- no `CREATE OR REPLACE` or `DROP ... CASCADE` in Build 1;
- no protected existing function/view creation;
- no stale `remedy_type` or `remedy_qty` columns;
- exact trigger ordering;
- single correction supersession authority;
- v1 fingerprint guard, v1-after-v2 block, v2 header identity, legacy dispute fail-closed, supervisor-note and quantity-position rules.

The rollback-only SQL regression verifies the installed database:

- all schema, integrity, concurrency and position objects;
- protected function fingerprints and signatures;
- RLS and direct-write denial;
- private quantity-position authority;
- existing receipts remain legacy v1 metadata only;
- legacy clean quantity remains unchanged;
- legacy uncertain and no-receipt allocations fail closed;
- valid rows satisfy all quantity invariants;
- a pending v2 receipt cannot pass the deferred commit constraint;
- incomplete, unbalanced or evidence-free affected receipts cannot finalise;
- final status is derived from exact line facts;
- receipt/evidence/remedy provenance is immutable;
- importer proposal and supervisor approval remain separate;
- quantity over-allocation is rejected;
- v1 cannot supersede finalised v2;
- a correction cannot bypass approved remedy work;
- a safe corrected clean receipt supersedes only the unlinked preliminary review;
- the entire write simulation rolls back.

When no unused live package satisfies the safe test criteria, the catalog, security, legacy-parity and live-invariant checks still run and the synthetic write section reports a skip notice.

## 13. Gate before database execution

1. Run the source regression against the exact branch head.
2. Confirm current `main` still matches the branch baseline or re-audit all drift.
3. Review the exact branch diff and migration order.
4. Apply the five migrations only in the approved Supabase test environment.
5. Run the rollback-only SQL regression and require `PASS`.
6. Inspect every row in `tracking_allocation_fulfilment_anomalies_v1`.
7. Smoke-test the existing legacy clean receipt, review, shipment and customer-release routes.
8. Do not merge, deploy or begin the v2 application switch until every foundation gate passes.

Any mismatch stops the build. No quantity, liability or provenance may be guessed.