# Final Sale Value and Balance Due Addendum v1

Status: locked for build sequencing after 2026-06-05 design review. Updated to include sale credits/credit notes, authorisation reference display, supervisor-approved ledger credit boundaries, conditional display rules so zero-value settlement rows are not surfaced prematurely, and the 2026-06-08 DVA/card final-balance allocation clarification.

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
- Final balance payment
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

Always show these fields on customer/importer order views:

```text
Order ref
Authorisation ref
Accepted estimate
Current status / initial payment status
```

Then show settlement fields only when their conditions are met:

```text
Amount received = show only when at least one payment/credit/funding event/final-balance allocation exists.
Final sale value = show only when a posted sale document, final sale adjustment, or sale credit exists.
Balance due = show only when final sale value exists and balance due > £0.00.
Potential credit pending final review = show only when final sale value exists and amount received > final sale value and no approved ledger credit exists for that surplus.
Credit added to account = show only when supervisor/admin-approved ledger credit exists for that order.
```

Do not show zero-value rows merely to fill the UI.

This creates a clear audit trail between the original quote/order, the customer's payment reference, and final sale settlement without creating premature settlement noise.

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

For calculation/read-model purposes:

```text
final_sale_value_gbp =
  if posted sale document count > 0 then posted_sale_total_gbp
  else accepted_estimate_gbp
```

For customer/importer UI purposes, do not surface a separate final sale value section before Sage-posted sale documents exist. Before then, show accepted estimate and payment status only. The accepted estimate may be used internally as the fallback calculation basis, but it should not be labelled as final sale value.

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

Amount received is all effective money/credit allocated to the order for final-sale settlement.

```text
amount_received_gbp = confirmed_dva_funding_gbp + confirmed_final_balance_payment_gbp + applied_credit_gbp
```

Where:

```text
confirmed_dva_funding_gbp = accepted-estimate/order-funding money already allocated to the order.
confirmed_final_balance_payment_gbp = confirmed DVA/card statement-line allocations with allocation_type = final_balance_payment.
applied_credit_gbp = approved/unlocked account credit actually applied to this order.
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

UI display conditions:

```text
Show amount_received_gbp only when amount_received_gbp > 0 or the page is a detailed payment breakdown.
Show balance_due_gbp only when final_sale_value_exists and balance_due_gbp > 0.
Show potential_credit_pending_review_gbp only when final_sale_value_exists and potential_credit_pending_review_gbp > 0 and approved ledger credit for that surplus does not exist.
Show credit_added_to_account only when approved ledger credit exists.
Hide zero balance/zero pending-credit rows in summary cards and customer-facing overview sections.
```

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

Do not route final-balance settlement through accepted-estimate order funding if that route would cause `sync_order_overfunding_credit(...)` or equivalent logic to create overfunding credit merely because final sale settlement takes total receipts above the accepted estimate.

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

Staff/supervisor reconciliation must show three separate internal targets for an order:

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

### Final-balance allocation rule

When matching a DVA/card IN statement line to an order with final balance due, the converted GBP value of the statement line must reduce the final balance first.

```text
statement_remaining_gbp = unallocated GBP remaining on the selected statement line
balance_due_gbp = current final sale balance still due
amount_to_final_balance_gbp = min(statement_remaining_gbp, balance_due_gbp)
fx_card_excess_gbp = max(statement_remaining_gbp - balance_due_gbp, 0)
balance_after_allocation_gbp = max(balance_due_gbp - statement_remaining_gbp, 0)
```

Do not create FX/card difference while the final balance is still open.

Only when `balance_due_gbp` reaches zero does any extra remaining amount on the selected statement line become FX/card difference, bank fee, unmatched hold, or another explicitly classified residual.

That residual is not automatically potential customer credit merely because it is above the balance. It becomes potential customer credit only where it represents a true commercial overpayment after final-sale review, not card/FX/provider variance.

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

Always show:

- Order ref
- Authorisation ref
- Accepted estimate
- Current status / initial payment status

Conditionally show:

- Amount received, only if payment/credit/funding/final-balance allocation exists
- Final sale value, only when posted sale document/adjustment/credit exists
- Balance due, only when final sale value exists and exceeds amount received
- Potential credit pending final review, only when final sale value exists and amount received exceeds final sale value and approved ledger credit does not yet exist
- Credit added to account, only when supervisor/admin-approved ledger credit exists for the order

Before Sage-posted sale documents exist, do **not** show final sale value, balance due, or potential credit pending final review as zero rows.

After Sage-posted sale documents exist:

```text
Final sale value: £Y
Accepted estimate: £X
Authorisation ref: AUTH-...
```

Add only the relevant settlement line:

```text
Balance due: £Z
```

or:

```text
Potential credit pending final review: £C
```

or:

```text
Credit added to account: £C
```

### Customer/order details

Always show:

```text
Order ref
Authorisation ref
Accepted estimate
Current status / initial payment status
```

Then conditionally show:

```text
Amount received
Final sale value
Balance due
Potential credit pending final review
Credit added to account
Pay today in local currency, where balance is due
```

Sale documents must be listed with customer-facing labels:

- Sale document
- Final sale adjustment
- Sale credit

not main/supplementary/credit_note agency-style or implementation wording.

### Importer/order operations details

Keep purchase/evidence controls operationally separate.

Always show:

```text
Order ref
Authorisation ref
Accepted estimate
Operational status
```

Add a final sale summary block only once Sage-posted sale documents/credits exist:

```text
Final sale value
Amount received, where relevant
Balance due, where > £0
Potential credit pending final review, where > £0 and not approved
Credit added to account, where approved
```

## 12. Non-goals for this patch

Do not rewrite the original order funding threshold.

Do not overwrite `orders.order_total_gbp_declared`.

Do not make final balance due block goods already purchased, evidence review, or shipment controls unless a later contract explicitly adds a closure gate.

Do not expose internal procurement/shipping document wording in customer/importer UI.

Do not change VAT logic merely because this display layer is added. VAT return and Sage posting logic remain governed by their own contracts.

Do not change checkout/order-creation auto-credit application. It must continue to use approved/unlocked `importer_credit_ledger` credit only.

Do not create account credit from customer-facing UI calculations.

Do not use `staff_reconcile_dva_line_to_order(...)` for final-balance settlement if that route would generate accepted-estimate overfunding credit or conflate final settlement with initial funding.

## 13. Build sequence

Minimum safe build order:

1. Patch final sale read calculation to include `credit_note` as a negative sale document.
2. Patch customer order details to show authorisation ref, signed final sale value, balance due, and potential credit pending final review only when conditions are met.
3. Patch sale document download section to list sale document, final sale adjustment, and sale credit rows.
4. Patch importer main orders list to show authorisation ref, signed final sale value/balance due/pending credit only when conditions are met.
5. Patch importer order operations page to show the same final sale summary only when sale documents/credits exist.
6. Patch DVA/card reconciliation workbench to allocate additional matched money as final balance payment before potential credit.
7. Patch DVA/card final-balance residual handling so converted GBP reduces balance first and only excess after balance closure is FX/card difference or held residual.
8. Tighten supervisor credit readiness so ledger credit cannot be approved before final sale/shipping closure is complete.
9. Only then consider whether generated overfunding credit needs backend correction once final sale value exists.

## 14. Acceptance tests

### Scenario A — no final sale document yet

```text
Accepted estimate: £250
Authorisation ref: AUTH-123
Initial payment received: yes
```

Do not show:

```text
Final sale value: Estimated £250
Balance due: £0
Potential credit pending final review: £0
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

### Scenario C — extra payment partially settles final balance

```text
Accepted estimate: £250
Authorisation ref: AUTH-123
Final sale value: £285
Amount received before second payment: £250
Balance due before second payment: £35
Second DVA/card IN statement line: £20
```

Expected result:

```text
£20 allocated as final_balance_payment
Balance due after allocation: £15
No FX/card difference created
No overfunding credit created
No importer credit created
```

### Scenario D — final payment settles balance with FX/card excess

```text
Accepted estimate: £250
Authorisation ref: AUTH-123
Final sale value: £285
Amount received before final payment: £265
Balance due before final payment: £20
Final DVA/card IN statement line: £20.12
```

Expected result:

```text
£20 allocated as final_balance_payment
£0.12 classified as fx_card_difference or held residual after staff confirmation
Balance due after allocation: £0
No overfunding credit created
No importer credit created
```

### Scenario E — sale credit reduces final sale value

```text
Accepted estimate: £250
Authorisation ref: AUTH-123
Posted sale document: +£250
Posted sale credit: -£40
Final sale value: £210
Amount received: £250
Potential credit pending final review: £40
Credit is not available at checkout until supervisor/admin approval creates ledger credit
```

Do not show zero-value balance due.

### Scenario F — true overpayment after final sale closure

```text
Accepted estimate: £250
Authorisation ref: AUTH-123
Final sale value: £285
Amount received: £300
Potential credit pending final review: £15
Supervisor/admin approval required before £15 becomes available account credit
```

Do not show zero-value balance due.

## 15. Locked decision

The platform must preserve three separate concepts:

```text
Initial payment received = accepted estimate covered.
Final settlement complete = final sale value covered, including sale credits/credit notes and confirmed final-balance payment allocations.
Available account credit = supervisor/admin-approved ledger credit only.
```

The first unlocks operational fulfilment. The second settles the final customer/importer sale value. The third is the only credit that can be used against future orders at checkout/order creation.

## 16. 2026-06-08 final-balance DVA allocation clarification

This clarification supersedes any looser wording in Section 9 about additional matched amounts once final balance reaches zero.

The correct sequence is:

```text
1. Converted GBP on a DVA/card IN line reduces final balance while balance_due_gbp > 0.
2. Only excess after balance_due_gbp reaches zero may be classified as fx_card_difference, bank_fee, unmatched_hold, or another staff-confirmed residual.
3. That excess is not customer credit unless supervisor/admin later confirms it is a true commercial surplus after final-sale review.
```

Worked example:

```text
Initial final balance due: £100.00
Payment 1 DVA/card IN line: £60.38
Allocate to final balance: £60.38
Balance after payment 1: £39.62
FX/card difference after payment 1: £0.00

Payment 2 DVA/card IN line: £39.74
Allocate to final balance: £39.62
Balance after payment 2: £0.00
FX/card difference after payment 2: £0.12
```

No overfunding credit or importer account credit is created by either payment in that example.
