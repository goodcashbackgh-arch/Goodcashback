# Portal and Order Operations Addendum v1

Status: locked addendum for portal role split, order operations, invoice intake, delivery/discount adjustments, final invoice draft preparation, customer order detail visibility, customer-safe final invoice documents, and post-progressed refund/return handling.

This addendum must be checked before changing Create Order, customer dashboard/order cards, customer order details, customer review-before-shipment flows, order operations, invoice upload, reconciliation, final invoice preparation, customer final invoice download, refund/return handling, shipper handoff, or Sage invoice generation.

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

## 14. Customer dashboard and order cards rule

The customer dashboard is the scan layer, not the full audit layer.

It should remain mobile-first and show only simple, confidence-building information:

```text
orders grouped by attention / in progress / completed
order reference / short order title
order value
item count
customer-friendly status
payment state
amount due / nothing due
open action
```

The dashboard may add small chips for customer-safe milestones:

```text
review needed
tracking available
invoice issued
delivery pending / delivered
```

The dashboard must not show detailed tracking records, Sage invoice IDs, VAT status, AP posting status, cash posting status, OCR status, internal adjustment mechanics, or supervisor-only blockers.

Detailed evidence and documents belong on the customer order details page.

## 15. Customer order details page rule

The customer order details page is the customer confidence page.

Its purpose is to answer:

```text
where is my order?
have you received my payment?
has the item been purchased/matched?
is there tracking?
has it been shipped or delivered?
is my final invoice available?
do I need to do anything?
```

The recommended page order is:

```text
header with order ref, item count, and customer-friendly status
next step
progress timeline
tracking
final invoice
delivery / POD status
payment summary
documents
credit and FX details
```

Customer-safe milestone mapping:

```text
orders.created_at -> Order created
order_funding_position_vw.threshold_met_yn -> Payment received
approved/current supplier invoice or progressed supplier lines -> Retailer purchase confirmed
supplier_invoice_lines.eligible_for_invoice_yn = 'Y' -> Invoice matched
order_tracking_submissions exists -> Tracking received
shipment batch package allocation exists -> Shipment arranged
sales_invoices.sage_status = 'posted' -> Final invoice issued
accepted final export/POD evidence exists -> Delivery evidence received / Delivered
```

The page must not expose the following labels or concepts to the customer:

```text
Sage object IDs
VAT return runs
cash posting rows
supplier AP posting rows
OCR pass/fail internals
shipping cost apportionment
margin/VAT recovery logic
internal DVA reconciliation labels
supervisor threshold rules
```

Customer wording must be customer-safe. For example:

```text
Sage sales invoice posted -> Final invoice issued
tracking submission -> Tracking received
shipment batch exists -> Shipment arranged
final export/POD accepted -> Delivery evidence received
```

## 16. Review-before-shipment gating rule

The customer review-before-shipment action is a narrow pre-shipment/customer-hold control.

It should surface only when:

```text
customer_review_ready_line_count > 0
AND no main/supplementary sales invoice is draft or posted
AND an active review link exists or the customer-active review-link RPC can create one
```

The review action should use customer wording:

```text
Review items before shipment
```

It should not be called final pro forma unless a later commercial decision changes the flow.

The review page may allow the customer/importer to:

```text
request whole-order hold
request package hold
request item hold
view hold request history
```

The review page must not expose supplier invoices, internal retailer-to-warehouse tracking mechanics, OCR controls, VAT/margin logic, Sage state, or supervisor decision mechanics.

Existing active review links should not continue to surface if the order no longer has review-ready lines or if a main/supplementary sales invoice has entered draft or posted status. Any RPC returning customer review links must re-check those gating conditions before returning a link.

## 17. Customer-safe final invoice document rule

The customer-facing invoice is called the final invoice, not the Sage invoice.

The customer order details page may show a final invoice action only when:

```text
sales_invoices.sage_status = 'posted'
AND sales_invoices.sage_invoice_id IS NOT NULL
```

Display fields should be customer-safe:

```text
Final invoice issued
Invoice ref
Invoice date
Final amount
Get invoice / Download invoice
```

The customer must not see Sage access tokens, Sage API paths, Sage object IDs, posting payloads, posting errors, ledger accounts, VAT code internals, or accounting command centre state.

Existing Sage PDF retrieval pattern:

```text
/shipper/shipments/[shipment_batch_id]/sales-invoices-zip
```

The platform already has a server-side Sage PDF retrieval pattern in the shipper shipment sales invoice ZIP route. That route resolves posted `sales_invoices` rows, checks `sage_status = 'posted'`, uses `sage_invoice_id`, calls Sage with:

```text
GET /sales_invoices/{id}
Accept: application/pdf
```

and returns the PDFs inside a ZIP for shipment/COS/export-evidence pack use.

This shipper ZIP route must not be reused directly as the customer final invoice route because the customer route needs single-order customer access checks, one-order document behaviour, and customer-safe persistence.

Final invoice PDF access must be server-side and access-controlled:

```text
verify authenticated customer/operator has access to the order/importer
verify the invoice belongs to that order
serve only posted final/supplementary customer invoices that are customer-visible
```

Preferred customer route:

```text
/customer/orders/[order_id]/final-invoice
```

Preferred persistence model:

```text
1. customer clicks Get invoice
2. server checks access and posted sales invoice state
3. if a stored platform PDF exists, serve it
4. if no stored PDF exists, fetch the PDF from Sage server-side using the existing Accept: application/pdf pattern
5. store the PDF in platform storage / document evidence under the order or sales invoice
6. save the storage path / document reference
7. serve the PDF to the customer
8. future clicks serve the stored platform copy
```

This avoids relying on live Sage availability for repeat customer downloads and preserves the customer document as part of the order evidence pack.

## 18. Bulk approval rule

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

## 19. Build sequencing rule

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
11. Add customer order detail confidence view: timeline, tracking, final invoice, delivery/POD status, documents.
12. Add persistent customer final invoice PDF storage/download after posted sales invoice exists.

## 20. Non-negotiable principle

```text
Reconciliation proves what was bought.
Finalisation decides what gets billed.
Shipping/handoff sees only physical goods.
Sage sees only approved final invoice drafts.
Customer sees only customer-safe order progress, payment, tracking, final invoice, delivery status, and documents.
```