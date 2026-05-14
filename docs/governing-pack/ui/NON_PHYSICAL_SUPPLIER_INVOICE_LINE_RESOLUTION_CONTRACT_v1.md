# Non-physical supplier invoice line resolution contract v1

## Purpose

Add a controlled closure path for supplier invoice OCR/manual lines that are real invoice rows but are not physical goods. Examples include delivery, shipping, postage, carriage, discount, promo, voucher, fee, rounding, and zero-value informational rows.

The purpose is to let operator reconciliation and supplier draft readiness close without falsely progressing non-physical rows into tracking, package allocation, shipper queues, shipment evidence, export packs, customer invoicing, or Sage goods-line payloads.

## Non-goals

- Do not change `supplier_invoice_lines.eligible_for_invoice_yn`; live constraint allows only `Y` or `N`.
- Do not change `supplier_invoice_lines.line_source`; live constraint allows only `ocr_extracted` or `manually_added`.
- Do not use `dispute_lines` for normal delivery/discount/fee rows.
- Do not mutate OCR source description, quantity, or amount simply to make reconciliation easier.
- Do not auto-hide non-physical lines silently.
- Do not weaken unresolved physical-product controls.

## Current live limitation

Today a supplier invoice line can be:

1. progressed/invoiceable through `eligible_for_invoice_yn = 'Y'`;
2. unprogressed and attached to a refund/replacement dispute; or
3. unprogressed and unresolved.

A non-physical OCR line currently falls into bucket 3 unless it is incorrectly progressed or incorrectly exceptioned. That can block readiness while still being unsafe to send to tracking or shipper workflows.

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
   - Has an active non-physical line-resolution record.
   - Must not be allocated to tracking/package refs.
   - Must not enter shipper queues as goods.
   - Remains visible for audit and supervisor accounting treatment.

4. **Unresolved**
   - `supplier_invoice_lines.eligible_for_invoice_yn = 'N'`.
   - No active dispute link.
   - No active non-physical resolution.
   - Must continue to block supplier draft readiness.

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

## Tracking/allocation rules

Tracking allocation must remain product-only. A line with an active non-physical financial resolution must be rejected by allocation actions even if a future bug or manual change attempts to allocate it.

## Accounting rules

Parking a non-physical line closes the operational/reconciliation blocker only. It does not by itself prove accounting coding is complete.

Positive delivery/fee/rounding amounts that affect invoice gross should be handled through the supplier accounting adjustment route where required. Zero-value delivery/informational rows may require no accounting adjustment line.

Discount sign treatment must be explicit in supervisor accounting. OCR source values are preserved; financial type/treatment determines whether the amount increases or reduces final coded value.

## Acceptance tests

1. Clean physical invoice: progressing all product lines still works unchanged.
2. Unprogressed physical product line: still blocks draft readiness.
3. Zero-value delivery OCR line with qty: can be resolved non-physical and no longer blocks readiness.
4. Positive delivery OCR line: can be resolved non-physical, excluded from shipper/tracking, and handled in accounting adjustments.
5. Discount OCR line: can be resolved non-physical, excluded from shipper/tracking, and requires explicit accounting sign treatment.
6. Parked line allocation attempt: allocation action must reject it.
7. Existing dispute/refund/replacement flows remain unchanged.
8. Existing `eligible_for_invoice_yn = 'Y'` product lines remain the only normal route into tracking/package allocation.
