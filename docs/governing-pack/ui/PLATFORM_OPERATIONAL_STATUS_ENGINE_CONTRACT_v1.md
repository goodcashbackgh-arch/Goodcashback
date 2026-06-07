# Platform Operational Status Engine Contract v1

Status: locked for current build sequencing after 2026-06-06 supervisor command centre, evidence-detail, tracking-coverage, and line-resolution review.

This contract governs how order status, next-owner and next-action labels are calculated across the platform. It prevents customer, importer, shipper and supervisor pages from independently inventing different meanings for the same order.

## 1. Core rule

There must be one canonical operational status source for an order.

Pages may format the status differently for their audience, but they must not calculate the underlying truth independently.

The current internal/staff canonical sources are:

```text
internal_platform_order_status_v1()
internal_platform_order_progress_v1()
```

The split is intentional:

```text
internal_platform_order_status_v1()
= current stage, state lanes, next owner, next action, monetary status, status tone/priority

internal_platform_order_progress_v1()
= fixed 12-gate progress model, derived downstream gate states, exception overlay summary
```

Customer/importer/shipper-facing pages may later consume scoped wrappers derived from the same logic. They must not reimplement contradictory status rules.

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

The platform uses a fixed denominator for progress reporting. Do not allow each order to show a different denominator merely because a downstream lane is not reached yet.

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

Progress must therefore be expressed as:

```text
gate_complete_count / 12
```

A gate may be `complete`, `in_progress`, `not_started`, `not_reached`, `review_needed`, `blocked`, `partial`, or `not_ready`. A `not_reached` gate still forms part of the denominator; it is not removed from the denominator.

This replaces the earlier UI-only progress shortcut where muted lanes were excluded from the denominator. Mixed values such as `6/7` and `6/8` are not acceptable as the long-term supervisor standard.

## 4. Line-resolution dependency

Supplier line state is an upstream dependency for supplier reconciliation, tracking/package allocation, shipment/export, customer sale release, Sage handoff, and VAT/compliance readiness.

The status engine must follow the non-physical supplier invoice line resolution contract:

```text
eligible_for_invoice_yn = 'Y'
= progressed physical/product line

eligible_for_invoice_yn = 'N' + active supplier_invoice_line_resolutions row
= explicitly parked non-physical financial line

eligible_for_invoice_yn = 'N' + active dispute/refund/replacement link
= exception-linked line

eligible_for_invoice_yn = 'N' + no active non-physical resolution + no active dispute link
= unresolved default-N line
```

`eligible_for_invoice_yn = 'N'` must never be treated as parked merely because it is `N`. The default `N` state is unresolved unless an explicit resolution or exception link proves otherwise.

Operational impact:

- unresolved default-N lines block supplier reconciliation/readiness;
- explicitly parked non-physical lines close the physical/logistics blocker only;
- parked non-physical lines must not enter tracking, shipper queues, shipment/export evidence, customer goods invoicing, or normal goods-line Sage payloads;
- progressed physical lines remain the only normal route into tracking/package allocation.

## 5. Partial shipment, export, POD, and customer-sale rules

A shipment/export/POD fact can be true for a shipment batch without being true for the whole order.

The canonical source must distinguish:

```text
allocated
accepted_current
posted
```

from:

```text
allocation_incomplete
partial_accepted_current
partial_posted
```

Universal coverage rule:

```text
An order is not full shipment/export/POD/customer-final complete while any active tracking submission or progressed physical supplier line remains outside the shipment/package allocation chain.
```

Required consequences:

- if one tracking ref is shipped/exported/POD-accepted and another active tracking ref is unallocated, shipment/export/POD are partial, not complete;
- accepted export evidence attached to one shipment batch cannot complete the whole order where another active tracking submission is outside shipment;
- accepted POD attached to one shipment batch cannot complete the whole order where another active tracking submission is outside shipment;
- a posted customer sale generated from a shipped subset must be treated as `partial_posted`, not final full-order sale;
- final balance due must not be treated as a full-order customer collection blocker until full physical shipment coverage exists.

## 6. Exception and hold overlay

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

Exception overlay categories should identify the current true blocker or open exception, not duplicate every downstream gate that is merely not ready because of an upstream blocker.

Example:

```text
If export evidence is missing, VAT/compliance may be not_ready, but the exception category should be export_evidence_exception, not both export_evidence_exception and vat_compliance_exception.
```

The supervisor command centre should show both:

```text
Progress: X/12 gates complete
Exceptions: clean / attention / open / hold open
Current blocker: [canonical current stage]
Next: [canonical next owner + action]
```

Open exception/hold state remains a top-priority blocker, but it should not be confused with gate completion.

## 7. Status hierarchy

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
9. Customer sale not posted or partial/final settlement blocker
10. Shipper AP not ready
11. Delivery/POD confirmation outstanding
12. Accounting/Sage handoff blocker
13. VAT/compliance evidence blocker
14. Complete
```

A downstream-complete fact must override stale lifecycle labels only where upstream coverage is complete. For example, accepted export evidence for a shipmented subset can prove that subset is exported, but it must not complete the order if another active tracking submission remains outside shipment.

## 8. Required canonical fields

The combined canonical internal status/progress layer must expose at least:

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

Current implementation note:

```text
internal_platform_order_status_v1()
= exposes the core operational states, monetary state, current stage, next owner/action, and priority.

internal_platform_order_progress_v1()
= exposes gate_total, gate_complete_count, gate_summary_json, exception_summary_state, exception_categories_json, plus derived dva/final-settlement/accounting/VAT states.
```

Do not force every derived field into one function if that creates unnecessary churn. The non-negotiable requirement is that pages consume the canonical pair consistently.

## 9. Upstream and downstream impact controls

Changes to this status engine are read-model changes unless explicitly stated otherwise.

They must not mutate:

- order totals or funding events;
- supplier invoice lines or OCR source values;
- line-resolution records;
- tracking submissions or package allocations;
- shipment batches or export/POD evidence;
- sales invoices already posted to Sage;
- shipper AP allocations;
- VAT return source snapshots.

Safe integration rule:

```text
Status can block, route, label, and surface incomplete coverage.
Status must not rewrite commercial, accounting, logistics, or VAT truth.
```

Before changing downstream workflows, use the status engine as a diagnostic control and verify the exact order/invoice/tracking/shipment examples.

## 10. Display rule

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

Evidence/detail pages may show deeper diagnostics, but they must label line state using the same canonical line-resolution rules. They must not label default-N unresolved lines as parked non-physical.

## 11. Non-goals

This contract does not redesign:

- the original order funding threshold
- checkout/order-creation credit application
- Sage posting eligibility
- VAT return logic
- shipper document upload flow
- customer-facing wording

Those remain governed by their own contracts/addenda.
