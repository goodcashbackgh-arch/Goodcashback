# Portal and Order Operations Addendum v1

Status: locked addendum for portal role split, order operations, invoice intake, delivery/discount adjustments, final invoice draft preparation, and post-progressed refund/return handling.

This addendum must be checked before changing Create Order, order operations, invoice upload, reconciliation, final invoice preparation, refund/return handling, shipper handoff, or Sage invoice generation.

## 1. Current naming reality

During the current MVP build, the `/importer` route is being used as the operator workbench.

For now:

```text
current /importer = operator/current-importer workbench
```

Future target split:

```text
/operator = operator workbench
/importer = true importer/customer portal
/internal = staff/supervisor/admin portal
/shipper = shipper portal
```

Do not rename current routes until the existing operational spine is stable.

## 2. True importer/customer portal rule

The true importer/customer may see:

```text
create order
order confirmation
pro forma estimate
final order amount
status
documents
refund/replacement approval prompts
```

The true importer/customer must not see internal mechanics such as:

```text
OCR reconciliation controls
delivery/discount adjustment approval mechanics
VAT recovery logic
platform margin logic
internal shipping apportionment logic
supervisor thresholds
Sage posting internals
```

Customer-facing financial display should be simple:

```text
original estimate
final order amount
status
documents
```

Do not expose the internal split of delivery, discount, margin, FX, VAT, or shipping apportionment unless a later commercial decision explicitly approves that.

## 3. Operator/current-importer workbench rule

The current `/importer` workbench may handle:

```text
create order
upload order screenshots
upload tracking evidence
upload supplier invoice evidence
manual/OCR invoice line review
reconciliation
exception creation from unresolved lines
retailer conversation logging
operational evidence capture
```

The operator/current-importer must not approve sensitive financial treatments reserved for staff/supervisor, including high delivery adjustments, discounts, final Sage invoice approval, post-progressed refunds, or customer-facing finalisation exceptions.

## 4. Supervisor/internal rule

Supervisor/internal users own approval and final control over:

```text
delivery adjustment over configured threshold
all discount adjustments
questionable invoice/order matches
refund pursuit approval
replacement final outcome acceptance
post-progressed refund/return approval
final invoice draft approval
bulk Sage invoice generation approval
```

Supervisor review must preserve the audit trail from first order step to final draft/Sage stage.

## 5. Create Order v1 locked rule

Create Order v1 remains simple and must not reintroduce categories for MVP.

Create Order v1 includes:

```text
assigned shipper
assigned destination hub/city
retailer selection
multiple order screenshots
total quantity declared
goods amount in GBP
local quote amount derived from importer country FX
restricted product confirmation
goods pro forma / payment authorisation reference
```

Create Order v1 excludes:

```text
category dropdowns
order_category_lines creation
shipping quote
internal FX rate display
card markup display
VAT/margin mechanics
```

The platform must derive importer country/currency from:

```text
importers.country_id -> countries.currency_id -> currencies.code
```

The platform may store FX and local quote fields internally, but the user-facing display should show only:

```text
goods amount in GBP
local quote amount in importer currency
```

## 6. Invoice upload and OCR matching rule

Normal path:

```text
operator/current-importer uploads invoice against a known order
supplier_invoices row is created
OCR extracts invoice header and lines
supplier_invoice_lines attach to supplier_invoices.id
lines become available for reconciliation only when the invoice/order match is acceptable
```

For MVP, invoice upload may require only:

```text
invoice_ref
invoice file
```

Retailer, importer, shipper, order date, declared amount, and quantity must be derived from the selected order where possible.

Invoice reference mismatch alone must not block a good invoice match if stronger signals agree. Match signals include:

```text
same importer
retailer match
amount match or close variance
invoice date within configured window, default 5 days
invoice ref uniqueness
qty or OCR line-count reasonableness
```

Wrong retailer or material mismatch must block automatic release and require supervisor review.

Importer/operator may identify or propose. The system and/or supervisor decides whether the invoice is safe to release for reconciliation.

## 7. Reconciliation boundary rule

Reconciliation proves what was bought and matched to retailer invoice evidence.

A progressed line means:

```text
supplier_invoice_lines.eligible_for_invoice_yn = 'Y'
```

Progressed lines must not be un-progressed merely because of later refund, return, customer change of mind, discount, delivery adjustment, shipping apportionment, or final invoice treatment.

Unresolved lines may go through the existing refund/replacement exception flow.

Progressed lines are handled later through finalisation/refund/return controls, not by reversing reconciliation.

## 8. Delivery and discount adjustment rule

Retailer delivery charges and discounts discovered during invoice intake/reconciliation are financial adjustments, not physical goods lines.

They must not appear as shipper-visible progressed goods.

They should be captured separately from supplier invoice item lines.

Recommended adjustment types:

```text
retailer_delivery
retailer_discount
```

Rules:

```text
retailer_delivery <= configured threshold, default £10, may auto-approve
retailer_delivery > configured threshold requires supervisor approval
retailer_discount always requires supervisor approval
```

Original pro forma amount must not be overwritten.

Do not update `orders.order_total_gbp_declared` to include missed delivery or discounts. That field preserves the original pro forma/order baseline.

Approved delivery/discount adjustments are apportioned only across included/progressed item lines for final invoice drafting.

## 9. Physical goods scope vs financial invoice scope

Physical goods scope is what the shipper/handoff sees.

Includes:

```text
progressed item lines
qty
description
SKU/size if available
order/ref
```

Excludes:

```text
retailer delivery charge
discount adjustment
platform pricing
VAT/margin logic
customer final invoice mechanics
```

Financial invoice scope is what prepares the customer/Sage final invoice draft.

Includes:

```text
progressed item lines
approved retailer delivery adjustment apportioned to included lines
approved retailer discount adjustment apportioned to included lines
approved shipper/shipping quote apportioned to included lines
```

## 10. Final invoice draft layer rule

A final invoice draft layer is required before Sage posting.

Do not post directly to Sage from progressed lines.

Recommended tables:

```text
order_final_invoice_drafts
order_final_invoice_draft_lines
```

The draft should prepare the final customer/Sage invoice from:

```text
progressed item lines
+ approved delivery adjustments
- approved discounts where passed to importer/customer
+ approved/apportioned shipping/shipper fees
= final invoice draft
```

The draft then feeds:

```text
sales_invoices.line_items_json
Sage posting queue
```

Supervisor should be able to review one draft or bulk approve draft invoices for Sage generation.

## 11. Final invoice draft visibility rule

Supervisor final draft review should show the complete order pack:

```text
original pro forma/order confirmation
local quote/order auth reference
order screenshots
supplier invoice PDF
progressed item lines
approved and pending delivery/discount adjustments
shipping quote and shipping apportionment
refund/replacement exceptions
replacement child status
return/refund requests
final draft amount
```

The final customer/Sage invoice must not show delivery/discount as separate lines if the commercial model requires bundled/apportioned pricing. Those values should be apportioned into final line amounts.

Supervisor may still see separate internal adjustment rows for audit and approval.

## 12. Post-progressed refund/return rule

If a line is already progressed and later the customer/importer wants a refund/return before final Sage invoice posting, do not send it back through reconciliation.

Use a finalisation refund/return process.

Recommended principle:

```text
progressed line remains progressed
final invoice draft line is excluded/held/refund-approved
operator may be assigned to pursue retailer refund
supervisor accepts final refund outcome
customer/operator dashboards update from finalisation status
```

Recommended draft line statuses:

```text
included
excluded_pending_refund
excluded_refund_approved
held
```

After Sage invoice posting, refunds should use a credit note/refund path instead of draft exclusion.

## 13. Return/collection and shipper rule

If goods are already with the shipper/hub and a progressed item is later excluded/refunded, create a shipper-visible return/collection task.

Shipper should see only physical return data:

```text
item description
qty
order ref
return/collection date
courier
tracking ref
proof upload
notes
confirm collected
```

Shipper should not see internal discount/delivery/platform economics.

If approved return/refund changes shipment scope before final shipping quote, mark the shipment/quote as requiring requote.

If shipping quote already exists, the quote should be refreshed or superseded before final invoice draft approval.

## 14. Bulk approval rule

Supervisor can bulk approve final invoice drafts only when each draft is clean:

```text
all included item lines are progressed
required adjustments are approved
refund/return exclusions are resolved or intentionally held
shipping quote/apportionment is approved where required
replacement child dependencies are clear
no blocking open supervisor review flags remain
```

Bulk approval must not bypass required supervisor review flags.

## 15. Build sequencing rule

To avoid damaging the working MVP spine, build in this order:

1. Lock this addendum.
2. Add `order_value_adjustments` and configurable adjustment policy.
3. Add delivery/discount inputs to invoice upload.
4. Show approved/pending adjustments on reconciliation without making them supplier invoice lines.
5. Add final invoice draft tables and draft generation from progressed lines plus approved adjustments.
6. Add shipping apportionment into final draft after shipping quote flow is ready.
7. Add supervisor draft review and bulk approval.
8. Add post-progressed refund/return flow.
9. Add shipper return/collection task and requote handling.
10. Add Sage posting from approved final invoice drafts.

## 16. Non-negotiable principle

```text
Reconciliation proves what was bought.
Finalisation decides what gets billed.
Shipping/handoff sees only physical goods.
Sage sees only approved final invoice drafts.
```
