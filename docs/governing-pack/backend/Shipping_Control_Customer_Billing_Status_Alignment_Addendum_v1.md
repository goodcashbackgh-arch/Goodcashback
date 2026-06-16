# Shipping Control Customer Billing Status Alignment Addendum v1

**Project:** Multi Tenant Platform Build  
**Status:** Governing backend/UI read-model addendum  
**Parent contract:** `docs/governing-pack/backend/Shipping_Control_Centre_Document_Intake_and_Export_Evidence_Flow_Addendum_v1.md`

## 1. Purpose

This addendum locks the customer-billing status rule for the shipping/AP route preview pages.

The shipping/AP route preview must not infer customer billing completion from the shipper AP readiness route alone. It must show AP/shipping-cost readiness and customer billing readiness as separate read-model truths.

## 2. Locked read-model split

The route preview page must treat these as separate sources:

```text
Shipper AP / shipping-cost readiness:
internal_shipping_ap_recharge_readiness_preview_v1

Customer billing / final invoice readiness:
internal_shipping_customer_invoice_readiness_preview_v1
```

The AP route may show that a posted main invoice creates a supplementary shipping route. That must not automatically be displayed as `Customer: Check` where the customer invoice readiness model proves that the posted main invoice already bundled goods and apportioned shipping.

## 3. Display rule

Customer billing chips on shipping/AP route preview pages must use customer invoice readiness state, not a local helper that only recognises the main-invoice-release route.

Required labels:

```text
already_bundled_in_main_sales_invoice
main_sales_invoice_posted_bundled
→ Customer: Already billed

ready_for_main_invoice_release_preview
→ Customer: Main invoice ready

ready_for_supplementary_invoice_preview
→ Customer: Supplementary ready

blocked
→ Customer: Blocked

unknown / missing / unmatched state
→ Customer: Review
```

For an order where:

```text
posted main invoice amount = goods basis + apportioned shipping
```

the page must display:

```text
Customer: Already billed
```

not:

```text
Customer: Check
```

## 4. Customer hold and review gate is separate

This addendum does not weaken customer review or customer hold controls.

The customer pre-shipment review/hold gate remains governed by:

```text
customer_order_review_links
customer_pre_shipment_hold_requests
customer_order_has_active_pre_shipment_hold_v1
customer_block_sales_invoice_when_hold_active_v1
```

Active customer holds must continue to block customer sales invoice draft/post creation where the existing trigger/function rules require it.

Created or posted customer sales invoices may continue to close active customer review links under the existing trigger rule.

## 5. Non-negotiables

This is a display/read-model alignment rule only.

Do not mutate, recreate, void, or rewrite:

- sales invoices;
- draft invoices;
- posted invoices;
- customer review links;
- customer hold records;
- shipper AP readiness;
- shipping cost allocations;
- shipment batches;
- export evidence;
- VAT/export evidence clearance;
- Sage/AP/customer posting eligibility.

Do not change `internal_shipping_ap_recharge_readiness_preview_v1` unless a separate AP-readiness contract explicitly authorises it.

Do not change customer invoice draft creation logic unless a separate customer invoice release contract explicitly authorises it.

## 6. Acceptance test

For booking `Jobyco140626`, where the diagnostic shows:

```text
goods_amount_gbp = 100.00
shipping_amount_gbp = 20.00
bundled_amount_gbp = 120.00
posted_main_amount_gbp = 120.00
main_invoice_appears_bundled_for_this_batch = true
```

the shipping/AP route preview must show:

```text
Customer: Already billed
AP: Ready
```

and must not show:

```text
Customer: Check
```

The customer final invoice release queue and Ready-for-Sage queue behaviour must remain unchanged.
