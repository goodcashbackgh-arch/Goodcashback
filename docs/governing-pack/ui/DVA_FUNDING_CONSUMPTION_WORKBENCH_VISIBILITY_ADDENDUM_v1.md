# DVA Funding Consumption Workbench Visibility Addendum v1

Status: governing addendum for one narrow read-model correction.

## Problem proved in live testing

A customer/importer IN statement line may already be consumed through the existing accepted-estimate funding path (`dva_reconciliation.reconciliation_type = 'order_funding'`) while a separate residual on the same statement line is confirmed in `dva_statement_line_allocations` as `fx_card_difference`.

The current `dva_statement_line_allocation_summary_vw` subtracts confirmed allocation rows and completion-loyalty consumption, but does not subtract confirmed order-funding reconciliation consumption. The DVA matching workspace therefore can show the FX residual as allocated while showing the already-funded principal as still remaining.

Example proved on `ORD-1786284488818`:

- statement IN £726.40;
- confirmed order-funding reconciliation £719.21;
- confirmed FX/card difference £7.19;
- true remaining £0.00;
- current workspace display incorrectly shows allocated £7.19 and remaining £719.21.

Second proved line:

- statement IN £20.18;
- confirmed order-funding reconciliation £20.00;
- confirmed FX/card difference £0.18;
- true remaining £0.00;
- current workspace display incorrectly shows allocated £0.18 and remaining £20.00.

## Governing authority

Existing accepted-estimate funding remains owned by the existing `dva_reconciliation` -> funding-event path. The DVA/Card Statement Control Workbench remains a financial-control/read-model consumer and must not recreate funding writes.

`statement_line_control_usage_v1` already treats `dva_reconciliation.reconciled_gbp_amount` as active statement-line consumption and classifies `reconciliation_type = 'order_funding'` as the `customer_order_funding` economic lane. This addendum aligns the older allocation-summary view with that already-installed authority for the one missing consumption family.

## Exact authorized intervention

Only this behavioural correction is authorized:

> In `dva_statement_line_allocation_summary_vw`, confirmed `order_funding` reconciliation amounts for the same `dva_statement_line_id` must count as confirmed consumed/allocated GBP when calculating `confirmed_allocated_gbp`, `confirmed_unallocated_gbp`, and `confirmed_balanced_yn`.

The correction must be read-model only.

## Required calculation

For each statement line:

```text
confirmed_consumed_gbp =
  confirmed dva_statement_line_allocations
+ confirmed completion-loyalty consumption already included by the current view
+ order-funding reconciliation consumption

confirmed_unallocated_gbp = statement_gbp_amount - confirmed_consumed_gbp
confirmed_balanced_yn = abs(confirmed_unallocated_gbp) < 0.01
```

Order-funding consumption is:

```text
SUM(ABS(dva_reconciliation.reconciled_gbp_amount))
WHERE dva_reconciliation.dva_statement_line_id = statement line
  AND reconciliation_type = 'order_funding'
```

The view must not create synthetic `dva_statement_line_allocations` rows.

## Frozen behaviour

This addendum does **not** authorize changes to:

- `staff_reconcile_dva_line_to_order(...)`;
- `dva_reconciliation` writes or constraints;
- `order_funding_events` writes or sync triggers;
- order funding totals, gaps, `funded_at`, overfunding or importer credit;
- FX/card-difference allocation RPCs or allocation rows;
- supplier invoice allocation RPCs;
- supplier payment readiness/provenance;
- final-balance allocation;
- completion loyalty;
- main-bank/shipper allocation;
- Sage/accounting release;
- statement extraction/import;
- statement-line monetary values;
- any existing workbench action button behaviour.

No funding or FX amount may be rewritten to repair presentation.

## Non-duplication rule

The same economic consumption must not be counted twice. Therefore this patch counts only `dva_reconciliation` rows whose `reconciliation_type = 'order_funding'`; existing allocation and loyalty families remain unchanged.

## Expected live result

For the two proved lines:

```text
£726.40 = £719.21 order funding + £7.19 FX/card difference -> remaining £0.00 -> balanced
£20.18  = £20.00 order funding  + £0.18 FX/card difference -> remaining £0.00 -> balanced
```

The workbench must no longer offer these fully consumed lines as remaining money available for another allocation.

## Regression requirement

A regression must prove:

1. the view includes exact `order_funding` consumption only;
2. existing allocation and loyalty calculation families remain present;
3. no funding/FX/supplier write function is modified;
4. a live fixture, when present, reports the two known lines as balanced with zero remaining;
5. the regression is rollback/read-only with respect to business data.

Any change outside the exact read-model intervention above is a build failure.
