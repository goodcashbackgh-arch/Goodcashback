# Platform Operational Status Engine Contract v1

Status: locked for next build sequencing after 2026-06-06 supervisor command centre review. Updated after SQL coverage check to separate fixed gate progress from cross-lane exceptions/holds.

This contract governs how order status, next-owner and next-action labels are calculated across the platform. It prevents customer, importer, shipper and supervisor pages from independently inventing different meanings for the same order.

## 1. Core rule

There must be one canonical operational status source for an order.

Pages may format the status differently for their audience, but they must not calculate the underlying truth independently.

The current internal/staff canonical source is:

```text
internal_platform_order_status_v1()
```

Customer/importer/shipper-facing pages may later consume scoped wrappers derived from the same logic.

## 2. Supervisor command centre role

The supervisor command centre remains the overview cockpit.

It should show where every order is across the whole business and route the user to the correct child task page. It must not become a posting page, checkout page, invoice-entry page, shipping-entry page, or VAT submission page.

It owns visibility of:

- funding/customer payment state
- DVA/card allocation state
- supplier evidence state
- supplier reconciliation progress
- cross-lane exception/hold state
- tracking/package allocation state
- shipment/export state
- customer sales/final sale state
- final balance/potential credit state
- shipper AP readiness
- delivery/POD state
- accounting/Sage handoff state
- VAT/compliance evidence state
- next owner/action

## 3. Standard gate model

The platform should use a fixed denominator for progress reporting. Do not allow each order to show a different denominator merely because a downstream lane is not reached yet.

The standard gate set is:

```text
1. Funding / customer payment
2. DVA / card allocation
3. Supplier evidence
4. Supplier reconciliation
5. Tracking
6. Shipment / package allocation
7. Export evidence
8. Delivery / POD
9. Customer sales / final settlement
10. Shipper AP
11. Accounting / Sage
12. VAT / compliance evidence
```

Progress should therefore be expressed as:

```text
gate_complete_count / 12
```

A gate may be `complete`, `in_progress`, `not_started`, `not_reached`, `review_needed`, or `blocked`. A `not_reached` gate still forms part of the denominator; it is not removed from the denominator.

This replaces the earlier UI-only progress shortcut where muted lanes were excluded from the denominator. The old mixed values such as `6/7` and `6/8` are not acceptable as the long-term supervisor standard.

## 4. Exception and hold overlay

Exceptions are not one ordinary gate.

Exceptions and holds are a platform-wide overlay that can attach to any gate. They must be surfaced separately from the gate denominator because a gate can be otherwise complete but still blocked by an exception.

Exception/hold categories should include, at minimum:

```text
funding_exception
dva_card_exception
supplier_invoice_exception
supplier_reconciliation_exception
tracking_package_exception
shipment_logistics_exception
export_evidence_exception
pod_delivery_exception
customer_sale_final_balance_exception
shipper_ap_exception
accounting_sage_exception
vat_compliance_exception
customer_hold
```

The supervisor command centre should show both:

```text
Progress: X/12 gates complete
Exceptions: clean / open / hold open
Current blocker: [canonical current stage]
Next: [canonical next owner + action]
```

Open exception/hold state remains a top-priority blocker, but it should not be confused with gate completion.

## 5. Status hierarchy

The platform-wide current stage must be resolved in this order:

```text
1. Active exception or customer hold
2. Initial funding incomplete
3. DVA/card allocation incomplete or exception
4. Supplier evidence/invoice missing or rejected
5. Supplier evidence review/reconciliation incomplete
6. Tracking missing or not allocated into shipment/package
7. Shipment batch/package allocation incomplete
8. Export evidence incomplete
9. Customer final sale not posted/settled
10. Shipper AP not ready
11. Delivery/POD confirmation outstanding
12. Accounting/Sage handoff blocker
13. VAT/compliance evidence blocker
14. Complete
```

A downstream-complete fact must override stale upstream labels. For example, if shipment package allocation and export evidence are already accepted, the page must not keep saying "tracking open" merely because an old order lifecycle label says tracking is open.

## 6. Required canonical fields

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
dva_state
supplier_state
reconciliation_state
exception_state
hold_state
tracking_state
shipment_state
export_evidence_state
pod_delivery_state
customer_sales_state
final_settlement_state
shipper_ap_state
accounting_sage_state
vat_compliance_state
accepted_estimate_gbp
amount_received_gbp
signed_final_sale_value_gbp
final_balance_due_gbp
potential_credit_pending_review_gbp
gate_total
gate_complete_count
gate_summary_json
exception_summary_state
exception_categories_json
```

Current `internal_platform_order_status_v1()` already exposes the core operational states used for today's supervisor command centre. It still needs extension for the new standard fields, specifically:

```text
dva_state
final_settlement_state
accounting_sage_state
vat_compliance_state
gate_total
gate_complete_count
gate_summary_json
exception_summary_state
exception_categories_json
```

## 7. Display rule

The supervisor command centre should preserve its existing overview layout unless a separate UI redesign is explicitly requested.

The data source may change to the canonical status engine, but the established cockpit structure should remain:

```text
Order ref
Importer / retailer
Age / status
Funding / DVA
Supplier / exceptions
Shipper / export
Customer sales / Shipper AP
Next owner/action
```

The display should not invent a new visual structure merely because the backend source changed.

## 8. Non-goals

This contract does not redesign:

- the original order funding threshold
- checkout/order-creation credit application
- Sage posting eligibility
- VAT return logic
- shipper document upload flow
- customer-facing wording

Those remain governed by their own contracts/addenda.
