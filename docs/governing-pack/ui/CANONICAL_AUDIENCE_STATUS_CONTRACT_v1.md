# Canonical Audience Status Contract v1

Status: locked implementation contract for removing status drift across supervisor, importer, customer and shipper-facing pages.

Purpose: prevent any user-facing page from independently calculating order truth in a way that contradicts the canonical operational status engine.

This contract extends:

- `PLATFORM_OPERATIONAL_STATUS_ENGINE_CONTRACT_v1.md`
- `FINAL_SALE_VALUE_AND_BALANCE_DUE_ADDENDUM_v1.md`
- `DVA_CARD_STATEMENT_CONTROL_WORKBENCH_V2_CONTRACT.md`
- `MAIN_BANK_LOYALTY_REWARD_FUNDING_INTEGRATION_ADDENDUM_v1.md`

## 1. Core rule

There must be one canonical status spine for every active order.

Pages may format labels differently for their audience, but they must not recalculate the underlying order truth independently.

Canonical sources:

```text
internal_platform_order_status_v1()
internal_platform_order_progress_v1()
```

A page-specific/audience-specific status may exist only as a wrapper derived from those canonical sources.

## 2. Prohibited page-level calculations

User-facing pages must not independently calculate any of the following as source-of-truth values:

```text
final_balance_due_gbp
potential_credit_pending_review_gbp
order_complete_yn
current_stage
next_owner
next_action
gate_complete_count
gate_total
customer_sales_state
shipper_ap_state
accounting_sage_state
vat_compliance_state
```

The following local pattern is prohibited outside a canonical SQL function or approved derived wrapper:

```text
finalBalanceDueGbp = finalSaleValueGbp - acceptedEstimateFundingOnly
```

This pattern is wrong because it ignores confirmed final-balance payments and other approved settlement credits.

## 3. Final-balance settlement source of truth

For final-sale settlement, amount received must include all effective settled value allocated to the order.

```text
canonical_settlement_received_gbp =
  accepted_estimate_amount_received_gbp
  + confirmed_final_balance_payment_gbp
  + applied_credit_gbp
```

Where:

```text
accepted_estimate_amount_received_gbp = accepted-estimate/order-funding money already allocated to the order.
confirmed_final_balance_payment_gbp = confirmed DVA/card statement-line allocations with allocation_type = final_balance_payment.
applied_credit_gbp = approved/unlocked account credit actually applied to this order.
```

Final balance due must be:

```text
canonical_balance_due_gbp = max(final_sale_value_gbp - canonical_settlement_received_gbp, 0)
```

Potential credit pending review must be:

```text
potential_credit_pending_review_gbp = max(canonical_settlement_received_gbp - final_sale_value_gbp, 0)
```

No page may show final balance due where canonical balance due is zero.

## 4. Audience status wrapper

A canonical audience wrapper must be introduced before further user-facing status patches are made.

Required function:

```text
order_audience_status_v1(p_order_id uuid default null)
```

Required behaviour:

```text
- call internal_platform_order_status_v1();
- call internal_platform_order_progress_v1();
- return one row per active order, or one row for p_order_id when supplied;
- expose canonical monetary, gate and next-action facts;
- expose audience-formatted labels derived from those same facts;
- not mutate order, funding, DVA/card, Sage, VAT, shipping, credit or AP records.
```

Minimum columns:

```text
order_id
order_ref
raw_order_status
lifecycle_status
importer_id
importer_name
retailer_id
retailer_name
accepted_estimate_gbp
final_sale_value_gbp
canonical_settlement_received_gbp
canonical_balance_due_gbp
potential_credit_pending_review_gbp
internal_current_stage
internal_current_stage_label
internal_next_owner
internal_next_action
internal_next_href
internal_status_tone
gate_complete_count
gate_total
funding_state
dva_state
supplier_state
reconciliation_state
tracking_state
shipment_state
export_evidence_state
pod_delivery_state
customer_sales_state
shipper_ap_state
accounting_sage_state
vat_compliance_state
internal_complete_yn
customer_complete_yn
importer_complete_yn
shipper_complete_yn
customer_status_label
customer_next_action
importer_status_label
importer_next_action
shipper_status_label
shipper_next_action
```

## 5. Audience meaning rules

### Internal/staff status

Internal/staff status is the strict 12-gate operational status.

```text
internal_complete_yn = gate_complete_count = 12
```

A staff page may show `Complete` only where internal completion is true.

### Customer status

Customer-facing completion is narrower than internal operational completion.

A customer order may show complete when:

```text
canonical_balance_due_gbp <= 0.01
and pod_delivery_state = accepted_current
```

Customer-facing pages must still use canonical monetary values from the audience wrapper.

Customer-facing status must not expose internal-only blockers such as shipper AP unless deliberately surfaced as a neutral informational message.

### Importer/operator status

Importer/operator status must reflect what the importer/operator can or must do next.

An importer page must not show `Final balance due` when:

```text
canonical_balance_due_gbp <= 0.01
```

Importer/operator pages may show:

```text
- open evidence/query action;
- tracking action;
- reconciliation action;
- final balance action;
- no importer action required;
- order complete/customer complete.
```

These labels must be derived from the audience wrapper.

### Shipper status

Shipper-facing status must reflect shipper-owned actions only.

Shipper-facing pages must not compute customer final balance independently.

## 6. Pages that must consume the wrapper

The following pages must consume `order_audience_status_v1` or a thin route/helper backed by it before further status work is considered complete:

```text
app/importer/page.tsx
app/importer/orders/[order_id]/operations/page.tsx
app/customer/orders/[order_id]/operations/page.tsx
app/internal/supervisor-command-centre/page.tsx
app/internal/evidence/[order_id]/page.tsx
```

Supervisor Command Centre may continue to call the internal canonical functions directly if it does not perform any contradictory page-level status or balance calculation.

Importer/customer/shipper pages must not keep local source-of-truth status calculations after the wrapper is available.

## 7. Drift audit

A permanent drift audit must exist.

Required function or view:

```text
internal_order_status_drift_audit_v1
```

It must return rows where canonical and legacy/local-style calculations would disagree.

At minimum it must detect:

```text
- LOCAL_PAGE_BALANCE_DRIFT:
  legacy balance due differs from canonical balance due;

- CANONICAL_STATUS_BALANCE_DRIFT:
  internal_platform_order_status_v1().final_balance_due_gbp differs from the independently recomputed canonical balance;

- AUDIENCE_STATUS_DRIFT:
  any audience wrapper label/action conflicts with canonical monetary/gate facts.
```

Normal expected result:

```text
0 rows
```

Any non-zero result blocks release of status-related UI changes.

## 8. Acceptance proof

For every active order, the following must be true:

```text
No importer/customer/shipper page displays final balance due where canonical_balance_due_gbp = 0.
No user-facing page calculates final balance using final sale value minus accepted-estimate funding only.
No page displays a next action that contradicts internal_next_action for its audience-owned responsibility.
Supervisor Command Centre 12-gate result matches internal_platform_order_progress_v1().
Customer/importer pages use audience-specific labels only after receiving canonical monetary/status facts.
```

Known proof case:

```text
Order: ORD-1777736251155
Final sale value: £211.99
Accepted-estimate received: £199.99
Confirmed final-balance payment: £12.00
Canonical balance due: £0.00
Correct result: no page may show Final balance due.
```

## 9. Non-negotiables

Do not fix drift by hard-coding a single order.

Do not fix drift by changing customer, importer, supervisor and shipper pages separately without a shared wrapper.

Do not remove the distinction between customer-complete and internal-complete.

Do not change Sage posting, VAT, shipper AP posting, DVA/card allocation, credit ledger or accepted-estimate funding logic merely to fix display status drift.

Do not treat absence of a document as proof of completion. A lane closes only from a positive completion fact, an approved no-action closure fact, or a canonical rule explicitly approved in the governing pack.

## 10. Implementation sequence

```text
1. Add order_audience_status_v1 wrapper.
2. Add internal_order_status_drift_audit_v1.
3. Patch app/importer/page.tsx to consume the wrapper.
4. Patch app/importer/orders/[order_id]/operations/page.tsx to consume the wrapper.
5. Patch app/customer/orders/[order_id]/operations/page.tsx to consume the wrapper.
6. Re-check app/internal/supervisor-command-centre/page.tsx and app/internal/evidence/[order_id]/page.tsx for local drift.
7. Run drift audit across all active orders.
8. Only then continue with new workflow builds.
```
