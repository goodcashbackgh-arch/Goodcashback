# Non-physical supplier invoice line resolution contract v1

## Purpose

Add a controlled closure path for supplier invoice OCR/manual lines that are real invoice rows but are not physical goods. Examples include delivery, shipping, postage, carriage, discount, promo, voucher, fee, rounding, and zero-value informational rows.

The purpose is to let operator reconciliation and supplier draft readiness close without falsely progressing non-physical rows into tracking, package allocation, shipper queues, shipment evidence, export packs, customer invoicing, or Sage goods-line payloads.

This contract is also an upstream dependency for final settlement and completion loyalty reward basis calculations. Non-physical rows can affect the signed qualifying net spend only when they have been explicitly classified/resolved and their commercial sign is known.

## Non-goals

- Do not change `supplier_invoice_lines.eligible_for_invoice_yn`; live constraint allows only `Y` or `N`.
- Do not change `supplier_invoice_lines.line_source`; live constraint allows only `ocr_extracted` or `manually_added`.
- Do not use `dispute_lines` for normal delivery/discount/fee rows.
- Do not mutate OCR source description, quantity, or amount simply to make reconciliation easier.
- Do not auto-hide non-physical lines silently.
- Do not weaken unresolved physical-product controls.
- Do not infer non-physical status purely from `eligible_for_invoice_yn = 'N'`.
- Do not infer completion loyalty reward basis from unclassified delivery, discount, fee, or other financial rows.

## Current live limitation

Today a supplier invoice line can be:

1. progressed/invoiceable through `eligible_for_invoice_yn = 'Y'`;
2. unprogressed and attached to a refund/replacement dispute;
3. unprogressed but explicitly resolved as non-physical financial; or
4. unprogressed and unresolved.

A non-physical OCR line falls into bucket 4 unless it is explicitly resolved. That can block readiness while still being unsafe to send to tracking or shipper workflows. This is intentional: unresolved is safer than silently treating a default `N` line as parked.

## Required line-state model

Every active supplier invoice line must resolve into one of these lanes:

1. **Physical product progressed**
   - `supplier_invoice_lines.eligible_for_invoice_yn = 'Y'`.
   - Can be accounting coded as a product/current supplier invoice line.
   - Can be allocated to tracking/package refs.
   - Can flow to shipper/shipment/export controls.

2. **Exception-linked**
   - `supplier_invoice_lines.eligible_for_invoice_yn = 'N'`.
   - Linked through `dispute_lines` to refund/replacement handling.
   - Must not be allocated as normal product goods unless later resolved by the exception workflow.

3. **Non-physical financial resolution**
   - `supplier_invoice_lines.eligible_for_invoice_yn = 'N'`.
   - Has an active `supplier_invoice_line_resolutions` record with `resolution_type = 'non_physical_financial'`.
   - Must not be allocated to tracking/package refs.
   - Must not enter shipper queues as goods.
   - Remains visible for audit and supervisor accounting treatment.

4. **Unresolved default-N**
   - `supplier_invoice_lines.eligible_for_invoice_yn = 'N'`.
   - No active dispute link.
   - No active non-physical financial resolution.
   - Must continue to block supplier draft readiness and supplier reconciliation.

## Default-N rule

`eligible_for_invoice_yn = 'N'` is a default unresolved state, not proof that a line is non-physical.

The system must treat these differently:

```text
N + no active resolution + no active dispute link
= unresolved_default_n

N + active non-physical financial resolution
= parked_non_physical

N + active dispute/refund/replacement link
= exception_linked

Y
= physical_product_progressed
```

The UI may suggest likely non-physical rows using description and amount patterns, but it must not silently reclassify them. The operator/staff action must create the active resolution row.

## Non-physical resolution rules

A non-physical line resolution is an explicit operator or staff action. The UI may suggest likely lines using description/amount patterns, but the system must not silently auto-resolve the line.

Allowed MVP financial types:

- `delivery`
- `discount`
- `fee`
- `zero_value_delivery`
- `rounding`
- `other_non_physical`

A resolved non-physical line remains an invoice-evidence row. Its source `qty`, `description`, and `amount_inc_vat_gbp` remain unchanged.

## Readiness rules

Supplier draft readiness should accept a non-progressed supplier invoice line only if either:

- it is safely linked to refund/replacement exception handling; or
- it has an active non-physical financial resolution.

Unprogressed physical-product lines without either route must still block.

A zero-value delivery row with `eligible_for_invoice_yn = 'N'` but no active non-physical resolution remains unresolved. It may be a likely candidate for parking, but it is not parked until the explicit resolution exists.

## Tracking/allocation rules

Tracking allocation must remain product-only. A line with an active non-physical financial resolution must be rejected by allocation actions even if a future bug or manual change attempts to allocate it.

An unresolved default-N line must also not be allocated to tracking/package refs. It must first be progressed as physical, linked to an exception, or explicitly resolved as non-physical.

## Accounting rules

Parking a non-physical line closes the operational/reconciliation blocker only. It does not by itself prove accounting coding is complete.

Positive delivery/fee/rounding amounts that affect invoice gross should be handled through the supplier accounting adjustment route where required. Zero-value delivery/informational rows may require no accounting adjustment line.

Discount sign treatment must be explicit in supervisor accounting. OCR source values are preserved; financial type/treatment determines whether the amount increases or reduces final coded value.

## Qualifying net spend dependency for completion loyalty rewards

The Completion Loyalty Reward and Sage Posting Addendum depends on this contract for delivery, discount, fee, and other non-physical financial rows.

A non-physical supplier invoice row may affect the completion loyalty reward basis only when it is explicitly resolved/classified and the qualifying net spend read model can prove its commercial treatment.

Default treatment for completion loyalty reward basis:

```text
Unresolved default-N line
= block proposal

Resolved qualifying delivery/charge line
= may increase signed qualifying gross basis

Resolved qualifying discount/credit line
= may decrease signed qualifying gross basis

Resolved non-qualifying charge or informational line
= excluded from qualifying basis

Mixed or unclear allocation
= block proposal for supervisor/admin review
```

The qualifying net spend read model must not guess. It must block reward proposal when any of the following remain unresolved:

```text
- default-N supplier invoice line without active resolution or exception link;
- delivery/discount/fee row without explicit financial type;
- unknown commercial sign;
- unproven allocation of a discount or credit across qualifying and non-qualifying rows;
- missing or ambiguous accounting coding for a row that could affect the signed basis;
- active dispute or active hold affecting the row/order;
- partial shipment/export/POD/customer sale coverage.
```

The signed qualifying gross basis for loyalty proposal may include qualifying standard-rate components with their commercial signs:

```text
+ qualifying physical goods gross
+ qualifying delivery/charge gross where classified as qualifying
- qualifying discount gross where linked/apportioned to qualifying spend
- qualifying credit/refund/return gross where linked to qualifying spend
```

The derived qualifying net spend is then calculated by the loyalty reward basis read model, not by this line-resolution contract.

## Status and display rules

Pages that display supplier invoice line state must use the same line-state model:

```text
Physical progressed
Exception-linked
Parked non-physical: [financial_type]
Unresolved default N
```

Evidence/detail pages, reconciliation pages, supervisor pages, and readiness pages must not label a line as parked non-physical merely because `eligible_for_invoice_yn = 'N'`.

Recommended summary display:

```text
Progressed physical lines / qty / amount
Unresolved default-N rows / qty / amount
Explicit parked non-physical rows / amount
Exception-linked rows
```

## Upstream and downstream controls

The line-resolution model affects status, readiness, routing, display, final settlement readiness, qualifying net spend readiness, completion loyalty reward proposal readiness, and Sage/accounting handoff readiness. It must not mutate source facts unless the relevant user action is performed.

It must not automatically change:

- OCR line description, quantity, or amount;
- `eligible_for_invoice_yn`;
- supplier invoice approval/current state;
- tracking allocations;
- shipment packages;
- export/POD evidence;
- customer sales invoices;
- customer loyalty reward approvals;
- Sage postings;
- VAT return snapshots.

## Acceptance tests

1. Clean physical invoice: progressing all product lines still works unchanged.
2. Unprogressed physical product line: still blocks draft readiness.
3. Default `N` product line with positive amount and no resolution: displays as unresolved default-N and blocks readiness.
4. Zero-value delivery OCR line with no resolution: displays as unresolved default-N and blocks readiness.
5. Zero-value delivery OCR line with active non-physical resolution: displays as parked non-physical and no longer blocks physical readiness.
6. Positive delivery OCR line: can be resolved non-physical, excluded from shipper/tracking, and handled in accounting adjustments.
7. Discount OCR line: can be resolved non-physical, excluded from shipper/tracking, and requires explicit accounting sign treatment.
8. Parked line allocation attempt: allocation action must reject it.
9. Existing dispute/refund/replacement flows remain unchanged.
10. Existing `eligible_for_invoice_yn = 'Y'` product lines remain the only normal route into tracking/package allocation.
11. Completion loyalty reward proposal must block when a default-N delivery/discount/fee row has no active resolution.
12. Completion loyalty reward proposal may include resolved qualifying delivery/charge rows only through the qualifying net spend read model.
13. Completion loyalty reward proposal must reduce the signed qualifying gross basis for resolved qualifying discount/credit rows.
14. Completion loyalty reward proposal must block, not guess, when a discount or credit cannot be safely allocated across qualifying and non-qualifying rows.