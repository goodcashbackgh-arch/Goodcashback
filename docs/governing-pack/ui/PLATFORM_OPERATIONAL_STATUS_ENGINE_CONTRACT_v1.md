# Platform Operational Status Engine Contract v1

Status: locked for next build sequencing after 2026-06-06 supervisor command centre review.

This contract governs how order status, next-owner and next-action labels are calculated across the platform. It prevents customer, importer, shipper and supervisor pages from independently inventing different meanings for the same order.

## 1. Core rule

There must be one canonical operational status source for an order.

Pages may format the status differently for their audience, but they must not calculate the underlying truth independently.

The canonical source is:

```text
internal_platform_order_status_v1()
```

This is an internal/staff read model. Customer/importer-facing pages may later consume scoped wrappers derived from the same logic.

## 2. Supervisor command centre role

The supervisor command centre remains the overview cockpit.

It should show where every order is across the whole business and route the user to the correct child task page. It must not become a posting page, checkout page, invoice-entry page, or shipping-entry page.

It owns visibility of:

- funding/DVA state
- supplier evidence state
- reconciliation progress
- exception/hold state
- tracking/package allocation state
- shipment/export state
- customer sales/final sale state
- shipper AP readiness
- delivery/POD state
- next owner/action

## 3. Status hierarchy

The platform-wide current stage must be resolved in this order:

```text
1. Active exception or customer hold
2. Initial funding incomplete
3. Supplier evidence/invoice missing or rejected
4. Supplier evidence review/reconciliation incomplete
5. Tracking missing or not allocated into shipment/package
6. Shipment batch missing
7. Shipment/export controls incomplete
8. Customer final sale not posted/settled
9. Delivery/POD confirmation outstanding
10. Complete
```

A downstream-complete fact must override stale upstream labels. For example, if shipment package allocation and export evidence are already accepted, the page must not keep saying "tracking open" merely because an old order lifecycle label says tracking is open.

## 4. Required canonical fields

The canonical status source must expose at least:

```text
order_id
order_ref
raw_order_status
lifecycle_status
current_stage
current_stage_label
next_owner
next_action
next_href
status_tone
status_priority
funding_state
supplier_state
reconciliation_state
exception_state
hold_state
tracking_state
shipment_state
export_evidence_state
pod_delivery_state
customer_sales_state
shipper_ap_state
accepted_estimate_gbp
amount_received_gbp
signed_final_sale_value_gbp
final_balance_due_gbp
potential_credit_pending_review_gbp
```

## 5. Audience display rules

### Customer pages

Show customer-safe wording only. Do not expose internal supplier, DVA, Sage, AP or operator workflow detail.

### Importer/operator pages

Show operational next action, but do not imply that a completed upstream task is still open when downstream evidence proves otherwise.

### Supervisor command centre

Show the full operational overview and route to the responsible child task page.

### Accounting/Sage pages

Do not use this status source to override posting controls. It is an operational status read model, not an accounting posting authority.

## 6. Non-goals

Do not change:

- original funding threshold
- checkout credit application
- importer credit ledger mechanics
- Sage posting eligibility
- shipping evidence locks
- VAT return logic
- order creation logic

This contract is for status/read-model consistency only.

## 7. Test examples

### Awaiting POD only

If supplier lines are progressed, packages allocated, shipment batch exists, export evidence is accepted, but POD is not accepted:

```text
current_stage = awaiting_delivery_confirmation
next_owner = Shipper / Supervisor
next_action = Upload or accept delivery/POD evidence
```

It must not show:

```text
tracking open
upload supplier invoice
payment pending
```

### Supplier invoice missing

If no supplier evidence/invoice exists, even where funding is complete:

```text
current_stage = supplier_evidence_missing
next_owner = Operator
next_action = Upload supplier invoice/evidence
```

### Active exception

If an active dispute or customer hold exists:

```text
current_stage = exception_or_hold_open
next_owner = Supervisor
next_action = Resolve exception/hold
```

### Final balance due

If final sale value is posted and exceeds amount received:

```text
current_stage = final_balance_due
next_owner = Customer / Operator
next_action = Collect final balance
```

### Complete

If funding, supplier/reconciliation, shipment/export, customer sale settlement and POD are complete with no active exceptions/holds:

```text
current_stage = complete
next_owner = None
next_action = No action required
```
