# DVA Funding Consumption Workbench Visibility Addendum v1

Status: governing addendum amended after full repository and live-database statement-line authority audit.

The earlier read-model-only draft of this addendum is superseded. The existing PR #245 migration/regression must not be merged or applied unchanged because the live audit proved that the defect is not only presentation: two deployed allocation writers can also reuse value that the canonical statement-line control has already consumed through order funding.

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

For both lines the canonical usage evidence contains both:

- the `dva_reconciliation` order-funding row; and
- the confirmed `dva_statement_line_allocations` FX/card row.

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

## Live write-authority finding

The live trigger inventory contains an amount-aware guard on **order-funding INSERTs into `dva_reconciliation`**, but no generic amount-aware trigger on inserts into `dva_statement_line_allocations`.

Therefore every allocation writer that can operate on a line already consumed by another economic family must fail closed against the canonical statement position itself.

The live audit proved two deployed writers do not currently do that:

### `staff_allocate_statement_line_to_final_balance_payment_v1(...)`

The deployed function locks the physical IN line but derives `v_line_remaining_before` from:

```text
physical statement amount - confirmed dva_statement_line_allocations
```

It does not subtract active order-funding reconciliation consumption. On the two proved lines it can therefore see £719.21 / £20.00 as available even though canonical remaining is £0.00.

### `staff_allocate_statement_line_to_dispute_or_hold(...)`

For `retailer_refund` on an IN line, the deployed function likewise derives remaining value only from confirmed `dva_statement_line_allocations`. It can therefore reuse principal already consumed by order funding.

The absence of a generic allocation-table control trigger means these are real write-integrity defects, not merely stale display values.

## Funding-wrapper finding

`staff_reconcile_dva_line_to_order(...)` is already protected at INSERT by `trg_guard_order_funding_statement_line_v1`, which calls resolver v2 and prevents the funding amount from exceeding canonical remaining.

`staff_reconcile_dva_line_to_order_pending_surplus_v1(...)` also explicitly checks the physical statement amount and canonical remaining before creating its governed split.

`staff_reconcile_dva_line_to_order_customer_fx_gain_v1(...)`, however, creates the FX residual directly in `dva_statement_line_allocations` after the guarded funding INSERT. The deployed definition does not itself prove that the requested receipt amount is within the immutable physical/canonical line amount before inserting that residual.

Therefore this wrapper also requires a narrow canonical amount guard so the valid funding+FX split remains supported but can never create canonical overconsumption.

## Exact authorized interventions

Only the following four behavioural interventions are authorized.

### 1. Compatibility read-model correction

Update `dva_statement_line_allocation_summary_vw` only so its existing three aggregate availability fields also count `dva_reconciliation.reconciliation_type = 'order_funding'` consumption for the same physical line.

All other columns, allocation-family totals, loyalty handling, voided-import filtering, row cardinality and existing column order must remain unchanged.

### 2. Final-balance canonical amount guard

In `staff_allocate_statement_line_to_final_balance_payment_v1(...)` only:

- keep the existing physical-line lock and all existing order/final-settlement validation;
- before creating an allocation, read the canonical position for the locked statement line;
- fail closed if canonical remaining is `<= 0.005`;
- never allocate more than canonical remaining;
- after the function's inserts, re-read canonical position and fail/roll back if `overconsumed_gbp > 0.005`;
- preserve existing valid final-balance and optional residual behaviour otherwise.

The function must not treat compatibility-summary remaining as monetary authority.

### 3. Refund/hold canonical amount guard

In `staff_allocate_statement_line_to_dispute_or_hold(...)` only:

- preserve all existing role, direction, dispute, importer, order-status and duplicate-allocation gates;
- after the physical statement-line lock, read the canonical statement position;
- fail closed if canonical remaining is `<= 0.005`;
- reject any proposed allocation above canonical remaining;
- after insert, re-read canonical position and fail/roll back if `overconsumed_gbp > 0.005`;
- otherwise preserve existing behaviour exactly.

No new dispute or refund workflow is authorized.

### 4. Customer-FX funding split canonical amount guard

In `staff_reconcile_dva_line_to_order_customer_fx_gain_v1(...)` only:

- preserve the existing funding-gap split and existing base funding RPC;
- prove the entered/requested receipt amount does not exceed the immutable/canonical amount still available on the physical line before the split begins;
- after the base funding reconciliation commits within the same transaction, prove the FX residual does not exceed canonical remaining before inserting the FX allocation;
- after the FX allocation insert, fail/roll back if canonical `overconsumed_gbp > 0.005`;
- do not create importer credit and do not change the valid economic result for an in-bounds funding+FX receipt.

## Read-consumer consequences

The compatibility correction is intended to remove the false positive remaining amount from legacy consumers such as the DVA hub, matching workspace, unmatched/control queues, review-pack/pre-Sage surfaces that still use the established summary fields.

Those surfaces may continue to use the existing category-specific allocation totals for display. Any action-enablement or economic-availability decision that is changed in a future build must use canonical `remaining_unconsumed_gbp`, not invent a third remaining-balance formula.

The existing Treasury Control Summary / resolver-v2 worklist already uses canonical `remaining_unconsumed_gbp` and must remain unchanged.

## Authorities proved safe or out of scope for this defect

No behaviour change is authorized to the following authorities unless a separate regression proves a defect:

- base `staff_reconcile_dva_line_to_order(...)` funding INSERT path and its amount-aware trigger;
- pending-surplus funding path;
- supplier-payment readiness and provenance;
- supplier invoice allocation direction/eligibility rules;
- `staff_allocate_statement_line_to_fx_card_or_fee(...)` existing OUT-line and main-bank external-consumption rules;
- completion-loyalty candidate consumption calculation;
- main-bank shipper/AP allocation, which already reads `statement_line_control_position_v1.remaining_unconsumed_gbp`;
- Sage/accounting release;
- statement extraction/import;
- statement physical monetary values;
- order funding totals, gaps, `funded_at`, funding-event sync, overfunding and importer-credit authorities.

## Frozen behaviour

The intervention must not:

- rewrite either live £726.40 or £20.18 physical statement line;
- rewrite the £719.21 or £20.00 funding reconciliations;
- rewrite the £7.19 or £0.18 FX allocations;
- manufacture balancing rows;
- change supplier-payment source provenance;
- change loyalty economics;
- change final-sale settlement values;
- change main-bank/shipper economics;
- change VAT/Sage/accounting posting behaviour;
- change statement interpretation or import lineage;
- relax existing role, importer, direction, content, terminal, accounting or reversal controls.

## Expected live result

After the governed intervention:

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

The replacement regression must prove all of the following.

1. Existing canonical statement-control definitions remain fingerprint-stable unless explicitly named above; this intervention must not replace the canonical usage/position/resolver chain.
2. The compatibility view adds exact `order_funding` consumption only and preserves existing allocation, loyalty and voided-import behaviour.
3. Both known live fixtures report compatibility remaining £0.00 / balanced and canonical remaining £0.00 / overconsumed £0.00.
4. A rollback-only fixture with a line already fully consumed by order funding cannot subsequently be allocated to final balance.
5. A rollback-only fixture with an IN line already consumed by order funding cannot subsequently be allocated as retailer refund/operational allocation beyond canonical remaining.
6. A valid customer funding + FX split continues to produce exactly funding + FX = physical statement amount with canonical remaining £0.00 and overconsumed £0.00.
7. An attempted customer-FX split whose entered amount exceeds canonical/physical available value fails atomically with no funding or allocation residue.
8. Supplier allocation, loyalty, main-bank shipper/AP, funding-event sync and accounting/Sage fingerprints remain unchanged.
9. No browser amount or client-side calculation becomes monetary authority.

Any behavioural change outside the four authorized interventions above is a build failure.

## PR #245 quarantine rule

PR #245 remains **not mergeable by governance** until its migration and regression are rebuilt to this amended addendum. Its earlier read-model-only implementation is incomplete because it does not harden the two deployed allocation writers or the customer-FX split authority identified by the live audit.
