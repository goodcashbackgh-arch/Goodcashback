# Final Sale Value and Balance Due Addendum v1

Status: locked for build sequencing after 2026-06-05 design review. Updated to include sale credits/credit notes, authorisation reference display, and supervisor-approved ledger credit boundaries.

This addendum extends `docs/governing-pack/ui/FUNDING_ACTION_CONTRACT.md` and the customer/importer order portal rules. It does **not** replace the original purchase-funding threshold. It adds a final sale settlement layer so the platform can show and collect any remaining amount after Sage-posted sale documents confirm the final sale value.

## 1. Commercial framing

Goodcashback acts as principal. User-facing copy must present the transaction as Goodcashback's sale to the customer/importer.

Use these terms in customer/importer UI:

- Accepted estimate
- Authorisation ref
- Final sale value
- Final sale adjustment
- Sale credit
- Amount received
- Balance due
- Potential credit pending final review
- Credit added to account
- Available account credit
- Sale document

Do **not** use these terms in customer/importer UI:

- supplier invoice
- shipping supplementary invoice
- recharge invoice
- agency fee
- service provider fee
- customer funding target for final sale settlement
- overfunding, unless used in internal staff-only diagnostics

Internal database table names may still contain existing technical words such as `sales_invoices`, `invoice_type`, and `credit_note`. Those names are implementation details and must not drive customer-facing wording.

## 2. Existing funding threshold remains intact

The original order value remains the accepted estimate/pro-forma amount:

```text
accepted_estimate_gbp = orders.order_total_gbp_declared
```

The original quote/order authorisation reference remains:

```text
authorisation_ref = orders.payment_auth_id
```

The existing initial payment flow remains:

```text
initial_payment_received = cumulative order funding >= accepted_estimate_gbp
```

This initial payment unlocks the operational order flow. It must not be reversed merely because a later final sale document increases the total sale value.

Do not change `recompute_order_platform_funded(...)` to use final sale value. That function should continue to support the accepted-estimate threshold unless a later contract explicitly redesigns the order state model.

## 3. Authorisation ref display rule

The same order/payment authorisation reference must be visible wherever the accepted estimate, final sale value, sale documents, or balance due are shown.

Minimum customer/importer display fields:

```text
Order ref
Authorisation ref
Accepted estimate
Final sale value / estimated sale value
Amount received
Balance due / potential credit pending final review
```

This creates a clear audit trail between the original quote/order, the customer's payment reference, and final sale settlement.

## 4. Final sale value

Once Sage-posted sale documents exist for an order, the final sale value is the signed sum of posted Sage sale documents for that order.

Sale invoices and final sale adjustments increase the final sale value. Sale credits/credit notes reduce the final sale value.

```text
posted_sale_charge_gbp = SUM(sales_invoices.amount_gbp)
where sales_invoices.order_id = order.id
  and sales_invoices.sage_status = 'posted'
  and sales_invoices.sage_invoice_id is not null
  and sales_invoices.invoice_type in ('main', 'supplementary')

posted_sale_credit_gbp = SUM(sales_invoices.amount_gbp)
where sales_invoices.order_id = order.id
  and sales_invoices.sage_status = 'posted'
  and sales_invoices.sage_invoice_id is not null
  and sales_invoices.invoice_type = 'credit_note'

posted_sale_total_gbp = posted_sale_charge_gbp - posted_sale_credit_gbp
```

Credit note amounts are stored as positive source amounts. The sign is determined by `invoice_type = 'credit_note'`.

For UI/read-model purposes:

```text
final_sale_value_gbp =
  if posted sale document count > 0 then posted_sale_total_gbp
  else accepted_estimate_gbp
```

Before Sage-posted sale documents exist, show the value as an estimate. After they exist, show it as final.

## 5. Sale document download section

Customer/importer sale-document sections must include all posted customer-facing Sage sale document types:

- Sale document (`invoice_type = 'main'`)
- Final sale adjustment (`invoice_type = 'supplementary'`)
- Sale credit (`invoice_type = 'credit_note'`)

The section must show the signed impact clearly:

```text
Sale document: +£X
Final sale adjustment: +£Y
Sale credit: -£Z
Final sale value: £A
```

The download action should use the existing customer-facing PDF route for every posted sale document type. The route already supports sale credits/credit notes as a document type; the UI must surface those rows rather than filtering them out.

## 6. Final sale settlement calculation

Amount received is all effective money/credit allocated to the order.

```text
amount_received_gbp = confirmed_dva_funding_gbp + applied_credit_gbp
```

Final balance due is:

```text
balance_due_gbp = max(final_sale_value_gbp - amount_received_gbp, 0)
```

Potential credit pending final review is:

```text
potential_credit_pending_review_gbp = max(amount_received_gbp - final_sale_value_gbp, 0)
```

Do not present this as available account credit until supervisor/admin approval creates a credit row in `importer_credit_ledger`.

## 7. Critical distinction: final balance is not overfunding

A payment above the accepted estimate is **not** automatically customer credit if the posted final sale value is higher.

Contract rule:

```text
If amount_received_gbp > accepted_estimate_gbp
and amount_received_gbp <= final_sale_value_gbp
then the extra amount settles the final sale balance.
It must not be treated as overfunding credit.
```

Only the amount above the final sale value becomes potential credit pending final review:

```text
potential_credit_pending_review_gbp = max(amount_received_gbp - final_sale_value_gbp, 0)
```

Only supervisor/admin-approved credit in `importer_credit_ledger` is available account credit:

```text
available_account_credit_gbp = importer_credit_ledger approved/unlocked credit balance
```

Do not allow final-balance payments to be misclassified as customer credit.

## 8. Supervisor-approved credit boundary

The existing supervisor/admin credit approval mechanism remains the only route for turning potential credit into usable account credit.

Credit can be added to the customer/importer's main account only when:

```text
All progressed/chargeable goods are finalised
AND final sale value is complete
AND shipping/export delivery charge is either:
  - included in the posted final sale value, or
  - posted as a final sale adjustment, or
  - formally closed as no further charge
AND no open disputes remain
AND no active holds remain
AND supervisor/admin approves credit
```

Once approved, the platform creates credit in `importer_credit_ledger`. That approved ledger credit is then available for future orders and can be auto-applied by the existing checkout/order-creation credit flow.

Do not bypass this with an automatic customer-page credit creation.

## 9. DVA/card statement matching implications

Staff/supervisor reconciliation must show three separate targets for an order:

1. Accepted estimate payment
2. Final balance payment
3. True credit/overpayment pending final review

A new statement-line match above the accepted estimate should be allowed when:

```text
balance_due_gbp > 0
```

In that case, label the match as:

```text
Final balance payment
```

not:

```text
Extra funding
Overfunding
Supplementary invoice payment
```

Once balance_due_gbp reaches zero, any additional matched amount becomes potential credit pending final review. It becomes available account credit only after supervisor/admin approval creates ledger credit.

## 10. FX display rule

Accepted estimate/pro-forma figures use the original locked quote FX snapshot.

Final balance due uses latest available FX for the importer/customer country at the time the balance is displayed.

UI rule:

```text
balance_due_local = balance_due_gbp * latest_available_fx_rate
```

Show the rate date clearly:

```text
Pay today: [LOCAL AMOUNT]
Based on latest available FX rate dated YYYY-MM-DD
```

If a same-day FX rate exists, label it as today's FX. If not, use the most recent available rate and show the date. Do not silently reuse the original quote FX for final balance due.

Potential credit pending final review may be shown in GBP. If local guidance is shown, it must be clearly marked as guidance and must not imply that account credit has already been approved.

## 11. UI layout rules

### Main orders list

Replace sole reliance on original order value with:

- Order ref
- Authorisation ref
- Accepted estimate
- Final sale value, where available
- Balance due, where final sale value exceeds amount received
- Potential credit pending final review, where amount received exceeds final sale value

Before Sage-posted sale documents exist:

```text
Estimated sale value: £X
Authorisation ref: AUTH-...
```

After Sage-posted sale documents exist:

```text
Final sale value: £Y
Accepted estimate: £X
Authorisation ref: AUTH-...
Balance due: £Z
Potential credit pending final review: £C
```

### Customer/order details

Show:

```text
Order ref
Authorisation ref
Accepted estimate
Final sale value
Amount received
Balance due / Potential credit pending final review
Pay today in local currency, where balance is due
```

Sale documents must be listed with customer-facing labels:

- Sale document
- Final sale adjustment
- Sale credit

not main/supplementary/credit_note agency-style or implementation wording.

### Importer/order operations details

Keep purchase/evidence controls operationally separate, but add a final sale summary block once Sage-posted sale documents exist:

```text
Order ref
Authorisation ref
Accepted estimate
Final sale value
Amount received
Balance due / Potential credit pending final review
```

## 12. Non-goals for this patch

Do not rewrite the original order funding threshold.

Do not overwrite `orders.order_total_gbp_declared`.

Do not make final balance due block goods already purchased, evidence review, or shipment controls unless a later contract explicitly adds a closure gate.

Do not expose internal procurement/shipping document wording in customer/importer UI.

Do not change VAT logic merely because this display layer is added. VAT return and Sage posting logic remain governed by their own contracts.

Do not change checkout/order-creation auto-credit application. It must continue to use approved/unlocked `importer_credit_ledger` credit only.

Do not create account credit from customer-facing UI calculations.

## 13. Build sequence

Minimum safe build order:

1. Patch final sale read calculation to include `credit_note` as a negative sale document.
2. Patch customer order details to show authorisation ref, signed final sale value, balance due, and potential credit pending final review.
3. Patch sale document download section to list sale document, final sale adjustment, and sale credit rows.
4. Patch importer main orders list to show authorisation ref, signed final sale value/balance due/pending credit.
5. Patch importer order operations page to show the same final sale summary.
6. Patch DVA/card reconciliation workbench to classify additional matched money as final balance payment before potential credit.
7. Tighten supervisor credit readiness so ledger credit cannot be approved before final sale/shipping closure is complete.
8. Only then consider whether generated overfunding credit needs backend correction once final sale value exists.

## 14. Acceptance tests

### Scenario A — no final sale document yet

```text
Accepted estimate: £250
Authorisation ref: AUTH-123
Amount received: £250
Final sale value shown as estimated £250
Balance due: £0
Potential credit pending final review: £0
Initial payment received: yes
```

### Scenario B — final sale value higher

```text
Accepted estimate: £250
Authorisation ref: AUTH-123
Posted sale document: +£250
Posted final sale adjustment: +£35
Final sale value: £285
Amount received: £250
Balance due: £35
Initial payment received: yes
Order is not reverted to unfunded
```

### Scenario C — extra payment settles final balance

```text
Accepted estimate: £250
Authorisation ref: AUTH-123
Final sale value: £285
Amount received after second payment: £285
Balance due: £0
Potential credit pending final review: £0
Second payment classified as final balance payment
```

### Scenario D — sale credit reduces final sale value

```text
Accepted estimate: £250
Authorisation ref: AUTH-123
Posted sale document: +£250
Posted sale credit: -£40
Final sale value: £210
Amount received: £250
Balance due: £0
Potential credit pending final review: £40
Credit is not available at checkout until supervisor/admin approval creates ledger credit
```

### Scenario E — true overpayment after final sale closure

```text
Accepted estimate: £250
Authorisation ref: AUTH-123
Final sale value: £285
Amount received: £300
Balance due: £0
Potential credit pending final review: £15
Supervisor/admin approval required before £15 becomes available account credit
```

## 15. Locked decision

The platform must preserve three separate concepts:

```text
Initial payment received = accepted estimate covered.
Final settlement complete = final sale value covered, including sale credits/credit notes.
Available account credit = supervisor/admin-approved ledger credit only.
```

The first unlocks operational fulfilment. The second settles the final customer/importer sale value. The third is the only credit that can be used against future orders at checkout/order creation.
