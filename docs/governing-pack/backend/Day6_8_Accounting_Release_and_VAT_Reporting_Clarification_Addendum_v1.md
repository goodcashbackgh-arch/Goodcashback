# Day 6/8 Accounting Release and VAT Reporting Clarification Addendum v1

Multi Tenant Platform Build — clarification over Day 6 accounting-release wording and Day 8 VAT reporting behaviour.

## Purpose

This addendum clarifies a terminology conflict exposed after the progressive commercial release and VAT timing corrections.

The old phrase **accounting release** was too broad. The platform must distinguish:

1. **Stable subset customer invoice release** — allowed when a progressed subset is stable.
2. **Final whole-order accounting closure** — blocked while unresolved child exceptions remain.
3. **VAT return reporting** — driven by tax point / prepayment timing and sales invoice release records.
4. **Zero-rating evidence clearance** — controlled by export evidence and the 3-month evidence/export deadline.

## Authority effect

This addendum supplements and clarifies:

- Architecture Completion Addendum v2
- Canonical Schema Reference v1
- SAGE Posting Matrix v1
- Master End-to-End Orchestration v3
- Technical Resource Map by Node v2
- VAT Timing & Export Evidence Addendum v1
- Progressive Commercial Release & Replacement Invoicing Addendum v1

Where older Day 6 wording implies that any open child exception blocks all customer invoicing, this addendum overrides it.

## Corrected rules

### 1. Open child exceptions block final closure, not stable subset invoicing

If an order has 5 quoted items, 4 stable progressed items, and 1 unresolved replacement/refund child:

- The 4 stable items may be customer-invoiced / released.
- The unresolved child remains open.
- The whole order cannot be finally closed until the child outcome is resolved.

So the old test concept:

`DAY6_ACCOUNTING_RELEASE_BLOCKS_OPEN_CHILDREN_PASSED`

must be read as:

**Final whole-order accounting closure blocks open children. Stable subset invoice release does not.**

### 2. Replacement child orders do not own customer sales invoices

Replacement child orders are operational fulfilment records. They track replacement supplier invoice, tracking, shipping, and receipt.

They do not create a separate commercial parent sale.

If a late replacement item was not included in the first customer invoice, it may be invoiced later as a **supplementary customer invoice on the original parent order**.

Correct treatment:

- Original parent order: owns customer invoice releases.
- Replacement child order: owns operational/evidence trail.
- Late replacement item: supplementary invoice line/release on the original parent order, not a new child-owned customer invoice.

### 3. Missing export evidence blocks zero-rating clearance, not necessarily VAT return inclusion

The system often receives export evidence weeks after dispatch but within the 3-month export/evidence deadline.

Therefore:

- A sales invoice/prepayment-timed supply can appear in VAT return reporting while export evidence status is still `on_track` or `at_risk`.
- Missing evidence should block final zero-rating evidence clearance.
- Missing evidence should not automatically remove the value from the VAT return report if the evidence deadline has not expired.

### 4. VAT reporting should be sales-invoice based, not order-total based

Because the architecture now supports progressive release:

- first stable subset = main invoice
- later stable subset/replacement = supplementary invoice

VAT Box 6 reporting must sum released customer sales invoice records for the relevant VAT period, not blindly use the full order declared total.

### 5. Breach reporting remains separate

If the export/evidence deadline expires and evidence is still missing:

- the sales invoice appears in breach reporting;
- a Box 1 breach adjustment is recorded for the period in which the deadline expires;
- if evidence is later obtained, a reinstatement/reversal adjustment is recorded in the later period.

## Implementation note

This addendum requires a small SQL clarification:

- Add a VAT sales invoice reporting view.
- Add a period-based VAT workings helper.
- Replace `post_to_vat_return_workings(order_id)` so it can post VAT workings from sales invoice periods even before zero-rating evidence clearance is fully complete.

It does not require changing the main order lifecycle or replacement child architecture.
