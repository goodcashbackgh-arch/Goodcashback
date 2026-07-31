# Main-Bank Shipper Cash Workbench Restoration Addendum v1

Status: locked corrective addendum.

Date: 31 July 2026

## 1. Purpose

This addendum restores an existing main-bank shipper AP cash-posting row family that was present in the cash-posting workbench on 24 May 2026 and was later omitted by a full replacement of the workbench read-model function.

This is a preservation correction. It does not create a new cash-posting architecture and must not roll back or reconstruct any currently working cash-posting, retailer-refund, DVA, loyalty, Sage-posting, allocation-review, allocation-reversal, batching, statement-control, or accounting-control implementation.

The required outcome is that confirmed `main_bank_shipper_ap_allocations` once again appear in the canonical cash-posting workbench as `shipper_invoice_payment` rows and continue through the already-existing freeze/batch/posting path.

## 2. Confirmed live evidence

Live database evidence on 31 July 2026 confirms:

- historical successful shipper cash snapshot source type: `main_bank_shipper_ap_allocation`;
- historical successful posting category: `shipper_invoice_payment`;
- historical queue-row contract: `cash:shipper_invoice_payment:<allocation_uuid>`;
- historical idempotency contract: `cash:shipper_invoice_payment:main_bank_shipper_ap_allocation:<allocation_uuid>`;
- counterparty type: `shipper`;
- active Sage bank mapping code: `DVA_CASH_BANK_ACCOUNT`;
- the mapping currently resolves through `sage_mapping_settings` to Sage bank account `1d21e52bed0a4fedb1b1dc21044b7d07`;
- the historical successful shipper snapshot reached `sage_posting_status = posted`;
- five confirmed shipper allocations are currently unfrozen, totalling GBP 102.00;
- each of those five rows has an active shipper-to-Sage contact mapping and a concrete Sage purchase-invoice id.

The existing `internal_freeze_cash_posting_rows_v2(text[], text)` function already explicitly accepts `shipper_invoice_payment`, requires a Sage contact and Sage purchase-invoice target, generates the historical four-part idempotency key, and constructs the OUT cash snapshot. The existing cash OUT payload-normalisation control already normalises both `supplier_invoice_payment` and `shipper_invoice_payment` to the current proven Sage vendor-payment contract.

Therefore the missing component is the read-model row producer, not the freeze, batch, or Sage-posting engine.

## 3. Preservation rule

The repair must be forward-only and preservation-first.

The following working implementations must remain unchanged in behaviour:

- the current canonical `internal_cash_posting_workbench_rows_v1(...)` implementation, including its retailer-refund readiness behaviour;
- `internal_cash_posting_workbench_rows_pre_refund_readiness_v1(...)`;
- `internal_freeze_cash_posting_rows_v2(...)`;
- `internal_create_cash_batch_v2(...)`;
- cash-posting batch/posting RPCs;
- retailer-refund settlement/readiness functions;
- existing DVA and final-balance workbench row producers;
- existing cash payload-normalisation functions/triggers;
- Sage posting code;
- the already-applied main-bank shipper allocation review/reversal migration.

The May 2026 workbench implementation must not be replayed wholesale because subsequent workbench families and controls have been added since then.

To preserve the current canonical implementation rather than re-copying it, the restoration may rename that exact function to a private `pre_shipper_restoration` name inside the same transaction and place a new canonical composition wrapper at the original name. The preserved function must remain the source of every pre-existing workbench row and every pre-existing retailer-refund readiness decision.

## 4. Required restored row contract

A dedicated internal shipper-row producer must emit the canonical 30-column cash-workbench row shape for confirmed main-bank shipper allocations.

Required values include:

```text
queue_row_id           cash:shipper_invoice_payment:<allocation_uuid>
source_type            main_bank_shipper_ap_allocation
source_id              main_bank_shipper_ap_allocations.id
statement_line_id      allocation.dva_statement_line_id
statement_id           statement line's dva_statement_id
direction              out
category               shipper_invoice_payment
counterparty_type      shipper
counterparty_id        shipping_documents.shipper_id
counterparty_name      current shipper name
amount_gbp             allocation.allocated_gbp_amount
matched_target_type    posted_shipper_purchase_invoice
matched_target_id      shipping_documents.id
matched_target_ref     shipper invoice/document reference
sage_contact_id        active shipper Sage party mapping
sage_bank_account_id   active `DVA_CASH_BANK_ACCOUNT` mapping result
target_sage_object_id  allocation/posting snapshot Sage purchase-invoice id
```

The Sage bank account id must never be hardcoded. The row producer must resolve `DVA_CASH_BANK_ACCOUNT` dynamically through `sage_mapping_settings`.

The shipper Sage contact must be resolved dynamically through the active `sage_party_mappings` record for `platform_party_type = 'shipper'` and the row's shipper id.

The Sage purchase-invoice target may use the allocation's stored `sage_purchase_invoice_id` first and retain the historical posted-snapshot/batch-row fallbacks where present.

## 5. Eligibility and reversal integration

Only `allocation_status = 'confirmed'` rows may be emitted by the shipper cash row producer.

A reversed allocation must therefore disappear automatically from the cash workbench without any deletion or rewrite of accounting history.

The already-installed `guard_main_bank_shipper_cash_snapshot_v1()` trigger remains authoritative at snapshot creation/reactivation time. It locks the source shipper allocation and rejects an active `shipper_invoice_payment` snapshot unless the allocation is still `confirmed`.

The already-installed `staff_reverse_main_bank_shipper_ap_allocation_v1(...)` remains authoritative for reversal and rejects reversal when an active shipper-payment cash snapshot already exists.

The restoration must not weaken or duplicate either control.

## 6. Integration seam

Preserve the current canonical cash-workbench implementation itself rather than rebuilding its internals.

Add one private shipper-row producer function with the same row contract as the canonical workbench.

Inside one migration transaction:

1. rename the exact current `internal_cash_posting_workbench_rows_v1(...)` implementation to `internal_cash_posting_workbench_rows_pre_shipper_restoration_v1(...)` if that preserved name does not already exist;
2. keep the preserved implementation private;
3. create a new function at the canonical `internal_cash_posting_workbench_rows_v1(...)` name;
4. obtain every pre-existing row from the preserved implementation;
5. obtain only shipper rows from the dedicated helper;
6. union the two sets with a defensive de-duplication guard for the shipper source/category/id tuple;
7. apply canonical ordering and final pagination to the combined set.

### 6.1 Status-preservation rule

The preserved current function must receive the caller's original `p_status` unchanged. It must not be called with `p_status = 'all'` and then have status filtering reconstructed outside the preserved function.

This is required because the preserved function already owns the established ordering, filtering and internal row cap for every existing row family. Changing the order of `status filter -> limit` into `limit -> status filter` can silently remove existing ready/blocked rows when more than 300 mixed-status rows exist.

Therefore:

- existing rows are filtered for status by the preserved function exactly as they are today;
- the shipper helper may return shipper rows independently;
- the new outer wrapper applies the same status predicate only to the shipper rows before combining them with the already-status-filtered preserved rows;
- the outer wrapper must not re-filter or reinterpret the status of existing preserved rows.

Direction/category/search filters must also be passed into both row sources before their internal 300-row caps. In particular, a request for `shipper_invoice_payment` must not lose valid shipper rows because unrelated workbench rows filled a cap first.

No existing non-shipper row family may be re-derived or copied into the new helper.

### 6.2 Non-shipper observational equivalence

For every request that excludes `shipper_invoice_payment`, the new canonical function must be observationally equivalent to the preserved function for the same parameters.

The comparison must cover the full returned row contract, including source/category identifiers, amounts, target identifiers, posting status, blocker, selectability and detail JSON. `total_count` must also remain equivalent for non-shipper requests.

This equivalence is a deployment requirement, not merely a documentation preference.

### 6.3 Search-semantics preservation

The restored shipper helper must preserve the original May 2026 shipper search surface. Search matching is limited to the same business-facing fields used by the historical workbench row family:

- counterparty name;
- order reference;
- auth reference;
- raw statement reference;
- matched target reference;
- category;
- blocker.

Internal implementation identifiers such as `source_type` must not be added to the search predicate. A restoration must not create new user-visible search matches that did not exist in the original shipper cash-workbench contract.

## 7. Freeze/posting contract

Do not modify the existing freeze RPC merely to support this restoration. It already recognises `shipper_invoice_payment` and uses the row's canonical fields.

The historical queue-row shape and the current freeze parser are compatible:

```text
cash:shipper_invoice_payment:<allocation_uuid>
```

The existing idempotency key remains:

```text
cash:shipper_invoice_payment:main_bank_shipper_ap_allocation:<allocation_uuid>
```

The existing cash OUT payload normaliser remains authoritative for the final Sage request contract:

```text
POST /contact_payments
transaction_type_id = VENDOR_PAYMENT
allocated_artefacts[] -> Sage purchase invoice id
```

## 8. No automatic backlog mutation

The five currently confirmed/unfrozen shipper allocations totalling GBP 102.00 must not be auto-frozen, auto-batched, or auto-posted by this migration.

After restoration they should become ordinary visible/selectable workbench candidates. Accounting staff must continue to choose and freeze them through the normal governed path.

## 9. Regression requirements

Before deployment approval, regression evidence must prove at minimum:

1. the preserved canonical function still exists and remains private;
2. current non-shipper workbench rows come from that preserved function rather than being re-derived;
3. retailer-refund readiness behaviour is unchanged because the preserved implementation remains authoritative;
4. the preserved implementation receives the original caller `p_status`, not a forced `all` status;
5. authenticated bidirectional `EXCEPT` comparisons show zero non-shipper row differences between the preserved and new canonical functions for representative `all`, `ready`, `blocked`, customer receipt, supplier payment, retailer refund, FX/card difference, bank fee, unmatched-hold and final-balance request shapes;
6. those equivalence comparisons include `total_count` so pagination/filter semantics are also protected;
7. confirmed shipper allocations appear with the historical source/category/queue-row contract;
8. the current confirmed/unfrozen shipper allocations are visible when queried by shipper category;
9. reversed shipper allocations are absent;
10. shipper Sage contact mapping resolves dynamically;
11. `DVA_CASH_BANK_ACCOUNT` resolves dynamically and no Sage bank UUID is hardcoded in the restoration migration;
12. target Sage purchase-invoice ids are populated;
13. a rollback-only authenticated freeze test creates the expected source/category/idempotency/payload shape;
14. the existing freeze/reversal database invariant still rejects reversed-source freeze and frozen-source reversal;
15. no migration automatically inserts, updates, deactivates, batches, or posts cash snapshots for the backlog;
16. the shipper helper search predicate matches the historical business-facing field list and does not include `source_type` or another new internal identifier.

Any non-zero non-shipper equivalence difference is a deployment blocker and must not be waived as part of this restoration.

## 10. Scope boundary

This correction is complete when the existing shipper cash-posting lane is restored through the current canonical cash-workbench contract without changing any other economic row family or posting architecture.

Any proposal to alter the preserved canonical implementation, private pre-refund function, freeze RPC, batch RPC, Sage poster, mapping-code model, existing applied reversal migration, or UI behaviour beyond consuming the restored canonical rows requires a separate explicit decision.
