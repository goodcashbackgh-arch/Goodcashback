# DVA Funding Consumption Workbench Visibility Addendum v1

Status: governing addendum amended after full repository and live-database statement-line authority audit and post-build review.

The earlier read-model-only draft of this addendum is superseded. The existing PR #245 migration/regression must not be merged or applied unless they conform exactly to this addendum and pass the required rollback regression.

## Problem proved in live testing

A customer/importer IN statement line may already be consumed through the accepted-estimate funding path (`dva_reconciliation.reconciliation_type = 'order_funding'`) while a separate residual on the same physical line is confirmed in `dva_statement_line_allocations`, for example as `fx_card_difference`.

Two live lines on `ORD-1786284488818` prove the split-authority symptom:

```text
£726.40 physical IN
= £719.21 order-funding reconciliation
+ £7.19 confirmed FX/card allocation
= £0.00 true remaining

£20.18 physical IN
= £20.00 order-funding reconciliation
+ £0.18 confirmed FX/card allocation
= £0.00 true remaining
```

The deployed compatibility summary currently reports only the allocation-side consumption for these lines, therefore:

```text
£726.40 line -> confirmed_allocated £7.19, confirmed_unallocated £719.21, balanced false
£20.18 line  -> confirmed_allocated £0.18, confirmed_unallocated £20.00, balanced false
```

The deployed canonical amount-aware statement control reports:

```text
£726.40 line -> active_consumed £726.40, remaining_unconsumed £0.00, overconsumed £0.00
£20.18 line  -> active_consumed £20.18,  remaining_unconsumed £0.00, overconsumed £0.00
```

For both lines the canonical usage evidence contains both the `dva_reconciliation` order-funding row and the confirmed `dva_statement_line_allocations` FX/card row.

## Canonical authority

The canonical economic amount authority for one physical statement line is the already-deployed amount-aware control chain:

```text
statement_line_control_usage_v1
        -> statement_line_control_position_v1
        -> internal_statement_line_control_resolver_v2(...)
```

`statement_line_control_position_v1.active_consumed_gbp`, `active_reserved_gbp`, `remaining_unconsumed_gbp`, and `overconsumed_gbp` are the authoritative economic position because the usage model combines the active economic-use families rather than only one storage table.

For availability/reuse decisions:

```text
canonical remaining = statement_line_control_position_v1.remaining_unconsumed_gbp
canonical overuse   = statement_line_control_position_v1.overconsumed_gbp
```

A line with canonical remaining `<= 0.005` has no money available for another economic use even if a compatibility view or individual source table shows a positive residual.

The existing `internal_statement_line_control_resolver_v2(...)` remains the governing directional/classification resolver. No parallel economic resolver may be introduced.

## Compatibility summary boundary

`dva_statement_line_allocation_summary_vw` remains an established compatibility/read model used by older DVA surfaces. It already combines confirmed `dva_statement_line_allocations` with completion-loyalty consumption, but it does not currently include order-funding reconciliation consumption.

This addendum authorizes one narrow compatibility correction for the existing fields:

- `confirmed_allocated_gbp`;
- `confirmed_unallocated_gbp`;
- `confirmed_balanced_yn`.

For those three fields only, confirmed `order_funding` reconciliation consumption for the same statement line may be added to the families already counted by the view.

This is a compatibility mirror of an already-governed consumption family. It does **not** make the compatibility view the canonical authority and does not authorize replacing or weakening `statement_line_control_position_v1` / resolver v2.

Required compatibility calculation:

```text
confirmed_consumed_gbp =
  confirmed dva_statement_line_allocations
+ completion-loyalty consumption already included by the current view
+ order-funding reconciliation consumption

confirmed_unallocated_gbp = statement_gbp_amount - confirmed_consumed_gbp
confirmed_balanced_yn = abs(confirmed_unallocated_gbp) < 0.01
```

Order-funding consumption for this compatibility correction is:

```text
SUM(ABS(dva_reconciliation.reconciled_gbp_amount))
WHERE dva_reconciliation.dva_statement_line_id = statement line
  AND reconciliation_type = 'order_funding'
```

No synthetic allocation row may be created.

The existing completion-loyalty governance and deployed loyalty source/destination behaviour are frozen. This build must preserve them exactly but must not edit the loyalty governing addendum or loyalty runtime authorities.

## Live write-authority finding

The live trigger inventory contains an amount-aware guard on order-funding INSERTs into `dva_reconciliation`, but no generic amount-aware trigger on inserts into `dva_statement_line_allocations`.

Therefore every allocation writer changed by this build must fail closed against the canonical statement position itself.

The live audit proved two deployed writers do not currently do that:

### `staff_allocate_statement_line_to_final_balance_payment_v1(...)`

The deployed function locks the physical IN line but derives `v_line_remaining_before` from physical statement amount minus confirmed `dva_statement_line_allocations`. It does not subtract active order-funding reconciliation consumption.

### `staff_allocate_statement_line_to_dispute_or_hold(...)`

For `retailer_refund` on an IN line, the deployed function likewise derives remaining value only from confirmed `dva_statement_line_allocations`.

The absence of a generic allocation-table control trigger means these are write-integrity defects as well as stale display values.

## Funding-wrapper finding

`staff_reconcile_dva_line_to_order(...)` is already protected at INSERT by `trg_guard_order_funding_statement_line_v1`, which calls resolver v2 and prevents the funding amount from exceeding canonical remaining.

`staff_reconcile_dva_line_to_order_pending_surplus_v1(...)` also explicitly checks the physical statement amount and canonical remaining before creating its governed split.

`staff_reconcile_dva_line_to_order_customer_fx_gain_v1(...)`, however, creates the FX residual directly in `dva_statement_line_allocations` after the guarded funding INSERT. It therefore requires a narrow canonical amount guard so the valid funding+FX split remains supported but can never create canonical overconsumption.

## Exact authorized interventions

Only the following four behavioural interventions are authorized.

### 1. Compatibility read-model correction

Update `dva_statement_line_allocation_summary_vw` only so its existing three aggregate availability fields also count `dva_reconciliation.reconciliation_type = 'order_funding'` consumption for the same physical line.

All other columns, allocation-family totals, completion-loyalty source and destination handling, `control_match_reason`, voided-import filtering, row cardinality and existing column order must remain unchanged. No new output columns are authorized.

### 2. Final-balance canonical amount guard

In `staff_allocate_statement_line_to_final_balance_payment_v1(...)` only:

- keep the existing physical-line lock and all existing order/final-settlement validation;
- before creating an allocation, read the canonical position for the locked statement line;
- fail closed if canonical remaining is `<= 0.005`;
- never allocate more than canonical remaining;
- after the function's inserts, re-read canonical position and fail/roll back if `overconsumed_gbp > 0.005` or `principal_lane_count > 1`;
- preserve existing valid final-balance and optional residual behaviour otherwise.

### 3. Retailer-refund canonical amount guard

In `staff_allocate_statement_line_to_dispute_or_hold(...)` only the existing `retailer_refund` / IN branch is authorized to change:

- preserve all existing role, direction, dispute, importer, order-status and duplicate-allocation gates;
- after the physical statement-line lock, read the canonical statement position;
- fail closed if canonical remaining is `<= 0.005`;
- reject any proposed retailer-refund allocation above canonical remaining;
- after insert, re-read canonical position and fail/roll back if `overconsumed_gbp > 0.005` or `principal_lane_count > 1`.

The existing OUT `exception_hold`, `not_charged_closure` and `unmatched_hold` branches are frozen and must remain behaviourally unchanged.

### 4. Customer-FX funding split canonical amount guard

In `staff_reconcile_dva_line_to_order_customer_fx_gain_v1(...)` only:

- preserve the existing funding-gap split and existing base funding RPC;
- prove the entered/requested receipt amount does not exceed the canonical amount currently available on the physical line before the split begins;
- after the base funding reconciliation runs within the same transaction, prove the FX residual does not exceed canonical remaining before inserting the FX allocation;
- after the FX allocation insert, fail/roll back if canonical `overconsumed_gbp > 0.005`;
- do not create importer credit and do not change the valid economic result for an in-bounds funding+FX receipt.

## Migration implementation rule

The migration must carry forward the exact audited live definitions and insert only the authorised guards/calculations.

Because `pg_get_functiondef(...)` text may contain either LF or CRLF line endings, patch anchors must not depend on a multiline newline sequence. Each function patch must use unique single-line anchors, or another equivalently line-ending-agnostic exact anchor, and must fail closed if an anchor is missing or non-unique.

The migration must not normalize, reformat or reconstruct the untouched parts of any live function. The preflight fingerprints remain the authority for proving the expected starting definition.

## Read-consumer boundary

The compatibility correction fixes consumers that actually derive their availability from the three corrected compatibility-summary aggregate fields.

It does **not** authorize a UI change and does not claim to correct every independently calculated display in the platform.

The existing `/internal/dva-reconciliation/review-pack` has a separate `hasFunding` branch that calculates open value from physical statement amount minus funding amount and can therefore ignore a coexisting FX allocation. That Review Pack calculation is explicitly **out of scope for this PR**. It must not be altered here. If it is to be corrected, it requires a separately governed follow-up after this database integrity correction is complete.

The existing Treasury Control Summary / resolver-v2 worklist already uses canonical `remaining_unconsumed_gbp` and is frozen.

Any economic-availability decision changed by this build must use canonical `remaining_unconsumed_gbp`; no third remaining-balance formula may be introduced.

## Authorities proved safe or out of scope

No behaviour change is authorized to:

- base `staff_reconcile_dva_line_to_order(...)` and its amount-aware trigger;
- pending-surplus funding;
- canonical usage, position, interpretation or resolver objects;
- supplier-payment readiness and provenance;
- supplier invoice allocation direction/eligibility;
- `staff_allocate_statement_line_to_fx_card_or_fee(...)`;
- completion-loyalty matching/release economics or governing addenda;
- main-bank shipper/AP allocation;
- Sage/accounting release;
- VAT;
- statement extraction/import;
- statement physical monetary values;
- order funding totals, gaps, `funded_at`, funding-event sync, overfunding and importer-credit authorities;
- application/UI code, including Review Pack.

## Frozen live fingerprint gate

The build is authorized only against the exact live database state audited on 11 August 2026. Before any replacement DDL, the migration must reproduce these pre-change fingerprints and abort if any differs.

Authorized change targets:

```text
dva_statement_line_allocation_summary_vw                         1219ed77fd0db05f59624e508fc64357
staff_reconcile_dva_line_to_order_customer_fx_gain_v1(...)      6f369fcd2a64a67736d77bf97d55e4cc
staff_allocate_statement_line_to_dispute_or_hold(...)           b90f7d7a2e6293a4c44acab6d08e649a
staff_allocate_statement_line_to_final_balance_payment_v1(...)  61c8d9289a8b42ff72e6e4d78aaabb96
```

Frozen authorities:

```text
staff_reconcile_dva_line_to_order(...)                           3d888918bff171d132049104b5692937
trg_sync_order_funding_event_from_dva_reconciliation()           28fa4b6b255956601d84ed813dfca47e
internal_guard_order_funding_statement_line_v1()                 b687d2343908cc3b526efaebd3d820d9
statement_line_effective_interpretation_v1                       b9f63595b613c69715fe807836bdd4ef
internal_completion_loyalty_destination_in_candidates_v1(...)   4c77b96b38121b879ccf273b829b5aa6
staff_pair_loyalty_destination_in_and_release_v1(...)            49d05f8d9400611d74582fd6d5e3e0c5
staff_reconcile_dva_line_to_order_pending_surplus_v1(...)        93d34501d77c71d4c3ace0424f1d29b5
statement_line_control_position_v1                               fe6ee2fc8909e383b8d584995b30cc78
internal_statement_line_control_resolver_v2(...)                 eb9bfa5ea572335272217c372fa02f53
staff_allocate_main_bank_line_to_shipper_ap_v1(...)              233823bb26a631cc6e2e51a36ee89e27
staff_allocate_statement_line_to_supplier_invoice_incremental_v  b4f70e857141436a585bfb0a1b472d5c
internal_supplier_payment_readiness_v1(...)                      004105ba835a28c500e6b697cb4b75bb
internal_supplier_payment_bundle_source_v1(...)                  7f4499adddc7c7433cae6e2a17c68282
statement_line_control_usage_v1                                  581d367a31ab0f689f3d31b46df5922e
internal_statement_line_control_worklist_v1(...)                 021697c6302f2cedb39610a79dba2e1f
```

Frozen trigger fingerprints:

```text
trg_guard_order_funding_statement_line_v1                        138e59bd4364968240d0ab0b091e9541
trg_reverse_pending_surplus_with_funding_v1                      9a4b8bb6215fc62fad9dda9124a86ac8
trg_sync_dva_line_status_from_order_funding_v1                   406a73e25a5687dc26a00cdad5dc6e3b
trg_sync_order_funding_event_from_dva_reconciliation             b6ac2d75684239db99580da7157bbaa3
```

After installing the four authorized object replacements, every frozen fingerprint above must be checked again in the same transaction. Any mismatch is a build failure and must roll back the whole migration.

## Frozen behaviour

The intervention must not rewrite either live statement line, either funding reconciliation, either FX allocation, or manufacture balancing rows. It must not change supplier provenance, loyalty economics, final-sale settlement values, main-bank/shipper economics, VAT/Sage/accounting posting, statement interpretation/import lineage, or any existing role/importer/direction/content/terminal/accounting/reversal control.

## Expected live result

```text
£726.40 = £719.21 order funding + £7.19 FX/card difference
compatibility remaining £0.00
canonical remaining £0.00
canonical overconsumed £0.00
not available for final balance/refund/another funding use

£20.18 = £20.00 order funding + £0.18 FX/card difference
compatibility remaining £0.00
canonical remaining £0.00
canonical overconsumed £0.00
not available for final balance/refund/another funding use
```

## Regression requirements

The replacement regression must run inside `BEGIN ... ROLLBACK` and prove:

1. canonical statement-control definitions remain fingerprint-stable;
2. the compatibility view adds exact `order_funding` consumption only and preserves existing allocation, loyalty and voided-import behaviour;
3. both known live fixtures report compatibility remaining £0.00 / balanced and canonical remaining £0.00 / overconsumed £0.00;
4. a fully consumed funding line is rejected by the final-balance writer before target-specific mutation;
5. a fully consumed funding line is rejected by the retailer-refund writer before target-specific mutation;
6. a fully consumed funding line is rejected by the customer-FX writer before funding or FX residue is created;
7. one valid final-balance allocation path executes successfully under rollback and preserves its existing result contract while canonical overconsumption remains zero;
8. one valid retailer-refund allocation path executes successfully under rollback and preserves its existing result contract while canonical overconsumption remains zero;
9. one valid customer funding+FX split executes successfully under rollback, produces the existing exact `funding + FX = entered receipt` economic result, creates no importer credit, and leaves canonical remaining/overconsumption correct;
10. supplier allocation, loyalty, main-bank shipper/AP, base funding, funding-event sync and other frozen fingerprints remain unchanged after the success-path exercises;
11. no browser amount or client-side calculation becomes monetary authority.

Source inspection alone is not sufficient for requirements 7-9. The actual post-patch RPCs must execute successfully against eligible rollback-only fixtures or eligible rollback-only live-path records.

Any behavioural change outside the four authorized interventions above is a build failure.

## PR #245 quarantine rule

PR #245 remains not mergeable until the migration and rollback regression conform to this amended addendum and the regression passes against the audited database.