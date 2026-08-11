# Pre-Final-Sale Pending Credit Visibility Addendum v1

Status: locked corrective UI governing addendum after repository-wide customer/importer settlement-consumer audit.

## 1. Proven defect

`order_settlement_audience_v1(...)` deliberately exposes the canonical unresolved settlement amount together with `resolution_status` for shared audience use. Before any posted final-sale document exists, the canonical settlement position correctly reports:

```text
resolution_status = not_ready_no_final_sale
```

and may still expose a positive raw `potential_additional_credit_gbp` / unresolved amount because the final order value is not yet established.

That raw diagnostic value is not customer/importer-visible potential credit at this stage.

The locked `FINAL_SALE_VALUE_AND_BALANCE_DUE_ADDENDUM_v1` requires:

```text
Potential credit pending final review = show only when final sale value exists
AND amount received > final sale value
AND approved ledger credit for that surplus does not exist.
```

The current customer order layout violates this rule by showing `Pending final review` whenever `potential_additional_credit_gbp > 0.01`, even when `resolution_status = not_ready_no_final_sale`.

The same missing presentation gate exists in three additional customer/importer presentation points identified by the full consumer audit:

1. customer order `Payment details` pending-credit row;
2. importer home `SettlementImporterSummary` pending-review amount/status;
3. importer order operations `Credit due` helper line.

Two audited surfaces already enforce the intended boundary and are frozen:

- importer main order card: pending credit is nested under `finalSaleConfirmed`;
- importer reconciliation settlement banner: requires both a closed supplier-invoice cycle and `resolution_status <> not_ready_no_final_sale`.

## 2. Canonical authority remains unchanged

Do not modify:

- `order_settlement_resolution_position_v1`;
- `order_settlement_audience_v1(...)`;
- `order_audience_status_v1(...)`;
- `internal_platform_order_status_v1()`;
- `internal_platform_order_progress_v1()`;
- `order_funding_events`;
- `order_funding_position_vw`;
- DVA/card reconciliation or allocation;
- account-credit ledger/application/reversal;
- final-balance payment allocation;
- pending receipt residual settlement;
- FX/payment variance classification;
- sales documents or Sage/accounting/VAT;
- supplier, shipment, tracking, hold, dispute or loyalty controls.

The shared RPC may continue exposing raw unresolved settlement diagnostics before final sale. Presentation surfaces must use the canonical readiness/final-sale fact to decide whether that raw amount is user-visible as potential credit.

No page may recalculate the monetary amount independently.

## 3. Exact authorised runtime changes

Only these four existing files may change:

```text
app/customer/orders/[order_id]/operations/layout.tsx
app/customer/orders/[order_id]/operations/page.tsx
app/importer/SettlementImporterSummary.tsx
app/importer/orders/[order_id]/operations/page.tsx
```

### 3.1 Customer top credit-update banner

Continue reading `order_settlement_audience_v1(...)` exactly once.

Use its existing `resolution_status` to suppress only the pending-review component when:

```text
resolution_status = not_ready_no_final_sale
```

An already-approved `credit_added_to_account_gbp` may still display according to its existing rule.

Do not add a new sale-document query or another settlement calculation to the layout.

### 3.2 Customer Payment details

The page already derives `finalSaleValueConfirmed` from canonical customer-sales state and posted customer sale-document evidence.

Show `Potential credit pending final review` only when:

```text
finalSaleValueConfirmed
AND pendingCreditGbp > 0.01
```

Do not change the pending-credit amount itself.

### 3.3 Importer home settlement summary

For display only, treat `potential_additional_credit_gbp` as visible pending review only when:

```text
resolution_status <> not_ready_no_final_sale
```

Do not suppress approved credit or existing classified settlement adjustments merely because final sale is not ready.

Do not change `order_settlement_audience_v1(...)` or add queries.

### 3.4 Importer order operations

The page already derives `finalSaleValueConfirmed` from canonical customer-sales state and posted sale-document evidence.

Show the existing `Credit due` helper line only when:

```text
finalSaleValueConfirmed
AND creditDueGbp > 0.01
```

Do not change the amount or any operational status/balance calculation.

## 4. Frozen correct surfaces

Do not change:

```text
app/importer/page.tsx
app/importer/reconciliation/[order_id]/layout.tsx
```

The importer main order card already nests pending-credit presentation beneath `finalSaleConfirmed`.

The importer reconciliation banner already requires:

```text
!supplierInvoiceCycleOpen
AND settlement.resolution_status <> not_ready_no_final_sale
```

Its stricter invoice-cycle readiness is intentional and remains unchanged.

## 5. Expected behaviour for the live motivating order

For `ORD-1786284488818` before posted final-sale documents exist:

```text
accepted estimate = £740.00
initial payment/funding complete = £740.00
raw unresolved settlement diagnostic may be positive
resolution_status = not_ready_no_final_sale
```

Customer/importer UI must not present that raw unresolved amount as:

```text
Pending final review
Potential credit pending final review
Credit due
```

The order remains in its normal payment-received/processing state.

After final-sale value exists, the existing canonical amount becomes eligible for display under the existing positive-value rules.

## 6. Regression requirements

Before merge prove:

1. exactly the four authorised runtime files plus this addendum and one focused source regression are changed;
2. no SQL/migration/database object changes;
3. no new Supabase query or admin-client dependency is introduced;
4. customer top banner suppresses pending review for `not_ready_no_final_sale` while preserving approved credit display;
5. customer Payment details requires `finalSaleValueConfirmed` for pending credit;
6. importer settlement summary suppresses only the pending component for `not_ready_no_final_sale`;
7. importer order operations requires `finalSaleValueConfirmed` for its credit helper;
8. importer main page retains its existing final-sale gate unchanged;
9. importer reconciliation retains both supplier-invoice-cycle and `not_ready_no_final_sale` gates unchanged;
10. no funding, canonical balance, status, next-action, completion, credit, FX, settlement, supplier, Sage, VAT, shipment or accounting calculation is modified.

## Locked implementation rule

> Raw unresolved settlement may exist before final sale for canonical diagnostics, but customer/importer potential-credit presentation must remain hidden until final sale exists. Gate presentation only; never rewrite the canonical amount or its upstream authorities.
