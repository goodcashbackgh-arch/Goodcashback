# Completion Loyalty Sage Accounting Posting Addendum v1

Status: locked implementation contract addendum to `COMPLETION_LOYALTY_MAIN_BANK_DVA_PAIRING_ACCOUNTING_CONTRACT_v1.md` and `COMPLETION_LOYALTY_APPLIED_ACCOUNTING_PREVIEW_ADDENDUM_v1.md`.

This addendum authorises the next MVP accounting/Sage build for completion loyalty without changing the already-locked loyalty activation, credit application, VAT return, DVA/card reconciliation, customer sales, supplier/AP, shipper/AP, or cash-posting flows except where this addendum explicitly approves the shared customer-receivable allocation prerequisite and final-balance customer-receipt bridge.

It deliberately does not rewrite the 23 June 2026 completion-loyalty contract. It narrows how the next Sage/accounting layer plugs into the existing platform.

This addendum does not invent a new Sage posting method. It creates dedicated completion-loyalty source lanes that feed existing proven Sage posting primitives already used elsewhere in the platform.

Existing proven Sage posting primitives to reuse:

```text
POST /contact_payments
POST /contact_allocations
POST /journals
```

Approved shared customer-receivable prerequisites now form part of this contract:

```text
confirmed final_balance_payment DVA/card IN allocations may be bridged into the existing customer receipt cash-posting workbench as source_type = dva_final_balance_allocation;
customer receipt allocation may allocate deterministically across multiple open posted customer_sales invoice snapshots for the same order and same Sage contact.
```

---

## 1. Locked accounting conclusion

Completion loyalty creates two different accounting events. They are linked, but they must not be collapsed into one posting.

### 1.1 Loyalty funding transfer event

When company money is moved from the main bank into the DVA/card/virtual-card account to fund/release loyalty, the accounting meaning is an internal transfer:

```text
Dr DVA/card/virtual-card bank / clearing asset
Cr main bank
```

This is cash movement only.

It is not customer funding.

It is not customer receipt.

It is not supplier/card spend.

It is not shipper/AP payment.

It does not create VAT timing.

### 1.2 Applied loyalty customer-settlement event

When the released completion-loyalty credit is actually applied to an order, the accounting meaning is customer balance settlement funded by the business:

```text
Dr loyalty reward expense / approved loyalty cost account
Cr customer account / customer receivable / customer settlement clearing
```

This is not cash movement at the date of application.

It is not a supplier/card payment.

It is not a shipper/AP payment.

It is not a sales credit note.

It must not reduce or rewrite the customer sales invoice.

---

## 2. Source events

### 2.1 Internal transfer source

The only source for the loyalty internal-transfer accounting control is:

```text
main_bank_completion_loyalty_funding_matches
```

A row is eligible for internal-transfer journal materialisation only when:

```text
transfer_pair_status = 'paired_released'
match_status = 'released_available_dashboard_credit'
source OUT statement line exists
destination IN statement line exists
matched_gbp_amount > 0
```

The OUT side must be the main company bank statement line.

The IN side must be the DVA/card/virtual-card statement line for the same importer.

### 2.2 Applied-loyalty settlement source

The only source for the applied-loyalty settlement accounting layer is:

```text
order_funding_events.event_type = 'credit_applied'
```

where the linked source credit is:

```text
importer_credit_ledger.source_type = 'completion_loyalty_reward'
```

The source chain must remain:

```text
completion-loyalty credit ledger row
  -> debit ledger row applied to order
  -> order_funding_events.credit_applied
```

Do not materialise a Sage/accounting posting from:

```text
pending loyalty approval
rejected loyalty approval
staged main-bank OUT
paired but unused DVA/card IN
released but unused loyalty credit
DVA/card transfer line alone
main-bank OUT line alone
```

---

## 3. MVP build order

The MVP must be built in this order.

### Phase 0 — Shared customer-receivable prerequisites

Before the loyalty settlement lane is built, the existing customer-receivable cash infrastructure must be capable of:

```text
1. exposing confirmed final_balance_payment DVA/card IN allocations as customer receipt rows;
2. freezing/posting those rows through the existing customer receipt cash-posting route;
3. allocating a receipt/payment-on-account across one or more open posted customer_sales invoice snapshots for the same order and same Sage contact.
```

This prerequisite is already aligned with the final-balance bridge migration and the shared multi-invoice cash allocation resolver. It is not a loyalty posting lane and does not make loyalty IN/OUT lines generic cash.

### Phase 1 — Applied-loyalty customer settlement posting

This is the first live-posting candidate because it is triggered by the existing `credit_applied` event and directly settles the customer account/order balance.

The implementation must not treat it as ordinary cash receipt from the customer. It must use a dedicated non-cash loyalty settlement lane.

### Phase 2 — Loyalty internal-transfer journal posting

The internal-transfer journal uses the existing proven `/journals` posting primitive.

It does not need a new Sage posting mechanism.

It does require dedicated loyalty source rows, dedicated mappings, dry-run/local validation, admin approval, idempotency, and Sage request/response logging.

Live posting may be enabled only after the loyalty main-bank, DVA/card, and any required in-transit clearing ledger mappings are configured and a controlled dry-run passes.

---

## 4. Correct Sage treatment for applied loyalty

A pure GL journal is not sufficient if the business needs the Sage customer/contact account to show the customer invoice as settled.

For MVP correctness, the applied-loyalty settlement should use the existing proven customer-account pattern, but in a dedicated non-cash loyalty lane:

```text
Step 1: create a non-cash customer receipt/payment-on-account using a dedicated loyalty clearing bank/account.
Step 2: allocate that payment-on-account to the posted Sage customer sales invoice(s) for the order.
Step 3: clear the loyalty clearing balance to loyalty reward expense using a VAT-safe journal/clearing entry.
```

Net accounting result:

```text
Dr loyalty reward expense / approved loyalty cost account
Cr customer account / receivable
```

Operational Sage result:

```text
Customer invoice receivable is settled on the Sage customer/contact account.
The loyalty clearing account is cleared.
No real DVA/main-bank cash is faked.
No VAT timing is created by this Sage settlement layer.
```

This mirrors the existing proven cash receipt + customer allocation mechanics, but must not reuse the generic cash-posting lane or labels.

The lane must be named distinctly, for example:

```text
completion_loyalty_non_cash_customer_settlement
```

---

## 5. Applied-loyalty settlement posting mechanics

### 5.1 Required Sage endpoints/patterns

The applied-loyalty customer settlement lane uses the same mechanics already proven by the existing cash receipt/allocation and journal posting code paths:

```text
POST /contact_payments
POST /contact_allocations
POST /journals
```

But it must remain a separate loyalty posting lane with separate tables, statuses, idempotency keys, and UI labels.

### 5.2 Required mappings

Add or confirm these mappings before any live applied-loyalty posting:

```text
LOYALTY_SETTLEMENT_CLEARING_BANK_ACCOUNT
LOYALTY_REWARD_EXPENSE_LEDGER
LOYALTY_CLEARING_OFFSET_LEDGER_OR_BANK_LEDGER
```

If the clearing bank/account and clearing ledger are the same Sage-side object, the implementation must still prove that the offset clears the same balance and does not feed Sage VAT/MTD incorrectly.

### 5.3 Customer/contact mapping

Applied loyalty can be live-posted only when the importer/customer for the order has an active Sage contact mapping.

The target customer sales invoice snapshot(s) must already be posted to Sage.

The target customer sales invoice snapshot(s) must be for the same `order_id` as the `order_funding_events.credit_applied` row unless a later contract deliberately allows cross-order customer balance allocation.

The target Sage contact must match the Sage contact used on the loyalty settlement payment-on-account.

If no posted customer sales invoice exists for the order, the row must block until customer sales posting is complete.

### 5.4 Settlement receipt

The non-cash customer receipt must:

```text
use the Sage customer/contact id for the importer/customer
use a dedicated loyalty settlement clearing bank/account
use amount = absolute applied loyalty amount
use transaction_type_id = CUSTOMER_RECEIPT where the existing Sage endpoint requires it
create no platform VAT return row
carry idempotency key based on the order_funding_event_id
```

It must not use the real DVA/card bank mapping.

It must not use the main bank mapping.

It must not appear as real customer cash on the DVA/main-bank cash posting workbench.

### 5.5 Customer allocation

The settlement payment-on-account must be allocated to posted Sage customer sales invoice snapshot(s) for the same order/customer.

The allocation amount must equal the applied loyalty amount in total, capped only by the combined open receivable amount of the selected invoice snapshot(s).

The implementation must not copy the old generic cash allocation limitation that blocked merely because more than one posted customer sales invoice snapshot existed for the same order. The approved shared resolver must be used as the reference pattern.

If one open posted customer sales invoice snapshot exists for the order, allocate to that invoice.

If multiple open posted customer sales invoice snapshots exist for the same order, allocate by a deterministic frozen target list:

```text
1. Same order_id as the credit_applied event.
2. Same Sage contact as the loyalty settlement payment-on-account.
3. document_lane = customer_sales.
4. sage_posting_status = posted.
5. Positive open receivable amount only.
6. Oldest invoice/document date first.
7. created_at then snapshot id as tie-breakers.
```

If the deterministic target list cannot be built safely, the group must block for accounting review. It must not guess from reference text.

If the total open receivable amount is lower than the applied loyalty amount, the row must block for accounting review. It must not silently part-post unless a later contract allows partial settlement.

### 5.6 Clearing offset

The clearing offset must record:

```text
Dr LOYALTY_REWARD_EXPENSE_LEDGER
Cr loyalty settlement clearing account/ledger
```

The clearing offset uses the existing VAT-safe journal primitive:

```text
POST /journals
```

The journal lines must use:

```text
include_on_tax_return = false
tax_rate_id = null
```

---

## 5A. Shared final-balance cash bridge and receivable allocation prerequisite

This section locks the repo-aligned prerequisite discovered during the loyalty build simulation.

### 5A.1 Final-balance DVA/card IN bridge

A supplementary/final-balance customer invoice is an additional customer receivable. It is settled by a customer IN payment, not by an OUT transaction.

Confirmed final-balance DVA/card IN allocations may be exposed to the existing Accounting Command Centre cash-posting workbench as customer receipt rows:

```text
source_type = 'dva_final_balance_allocation'
category = 'customer_receipt_on_account'
matched_target_type = 'payment_on_account_final_balance'
```

The source is:

```text
dva_statement_line_allocation_detail_vw
where allocation_type = 'final_balance_payment'
and allocation_status = 'confirmed'
and statement_direction = 'in'
```

Readiness must require:

```text
positive allocated_gbp_amount
active importer/customer Sage contact mapping
DVA_CASH_BANK_ACCOUNT mapping
same order_id carried from the final-balance allocation
```

This bridge is allowed to reuse the existing customer cash posting path:

```text
Cash Posting Workbench
  -> freeze
  -> cash posting batch
  -> POST /contact_payments
  -> customer receipt/payment-on-account
  -> POST /contact_allocations
```

This bridge does not create or mutate:

```text
order_funding_events
sales_invoices
vat_return_runs
vat_return_run_lines
vat_return_adjustment_journals
vat_return_adjustment_journal_lines
```

It is a Sage/customer-account bridge for confirmed customer cash that the platform has already classified as final-balance received.

### 5A.2 Shared multi-invoice customer allocation resolver

The existing customer cash allocation path, the final-balance customer receipt bridge, and the future loyalty non-cash settlement lane must all resolve open customer receivables using the same deterministic same-order/same-contact rule.

The resolver must select target invoice snapshot(s) by:

```text
1. Same order_id as the receipt/settlement source.
2. Same Sage contact as the payment-on-account/receipt.
3. document_lane = customer_sales.
4. sage_posting_status = posted.
5. Positive open receivable amount only.
6. Oldest invoice/document date first.
7. created_at then snapshot id as tie-breakers.
```

The resolver may allocate one receipt/payment-on-account across more than one customer_sales invoice snapshot for the same order and same Sage contact.

This is required for orders with both a main customer sales invoice and a supplementary/final-balance invoice under the same order_id.

The resolver must not search by `parent_order_id` for normal customer cash. Replacement child order invoices must not be pulled into parent-order receipt allocation unless a later contract explicitly authorises that cross-order allocation.

If no open posted customer_sales target exists, block.

If Sage contact does not match, block.

If positive open amount cannot be calculated safely, block.

If the total open receivable amount is below the receipt/allocation amount and partial allocation has not been explicitly approved for that lane, block.

---

## 6. Internal-transfer journal mechanics

The internal transfer is not customer settlement. It is only the movement of company funds into the DVA/card/virtual-card account.

For MVP, create dedicated loyalty internal-transfer posting rows using:

```text
main_bank_completion_loyalty_funding_matches
```

Minimum output:

```text
loyalty_match_id
source_out_statement_line_id
destination_in_statement_line_id
importer_id
order_id
order_ref
matched_gbp_amount
transfer_pair_status
match_status
source_out_reference
destination_in_reference
source_out_date
destination_in_date
internal_transfer_accounting_status
posting_enabled
blocker
```

Readiness status examples:

```text
ready_internal_transfer_journal_materialisation
blocked_missing_source_out_line
blocked_missing_destination_in_line
blocked_unpaired_or_not_released
blocked_missing_main_bank_ledger_mapping
blocked_missing_dva_card_bank_ledger_mapping
blocked_missing_in_transit_ledger_mapping
```

### 6.1 Internal-transfer accounting treatment

When source OUT and destination IN have the same accounting date, journal accounting treatment may be:

```text
Dr DVA/card/virtual-card bank / clearing asset
Cr main bank
```

When source OUT and destination IN have different accounting dates, especially across period cut-off, the implementation must use an in-transit clearing method rather than forcing one artificial journal date:

```text
On main-bank OUT statement date:
Dr loyalty transfer in-transit clearing
Cr main bank

On DVA/card IN statement date:
Dr DVA/card/virtual-card bank / clearing asset
Cr loyalty transfer in-transit clearing
```

### 6.2 Required internal-transfer mappings

Add or confirm these mappings before live internal-transfer posting:

```text
LOYALTY_MAIN_BANK_LEDGER
LOYALTY_DVA_CARD_BANK_LEDGER
LOYALTY_TRANSFER_IN_TRANSIT_LEDGER
```

The in-transit ledger is required if the source OUT date and destination IN date can differ.

### 6.3 Required internal-transfer endpoint

The internal transfer uses the existing proven journal endpoint:

```text
POST /journals
```

It is not routed through:

```text
customer_receipt_on_account
supplier_invoice_payment
shipper_invoice_payment
bank_fee
fx_card_difference
```

### 6.4 Internal-transfer feature gate

Live internal-transfer posting is allowed only when:

```text
source OUT + destination IN are paired_released
required ledger mappings are configured
dry-run/local validation has passed
admin approval has been recorded
feature flag is enabled
no Sage journal id already exists for the pair/date step
```

---

## 7. Dating, short-reference, and source-correlation rules

### 7.1 Applied-loyalty settlement date

The applied-loyalty settlement date is:

```text
order_funding_events.created_at::date
```

where:

```text
order_funding_events.event_type = 'credit_applied'
```

Use this date for:

```text
loyalty non-cash contact payment date
loyalty clearing journal date
```

If the Sage allocation endpoint does not accept an explicit allocation date, the allocation must still be logged under the same settlement group and source event. The allocation attempt timestamp is audit only; it is not the source economic date.

Do not use these dates for the applied-loyalty customer settlement:

```text
reward approval date
main-bank OUT date
DVA/card IN date
Sage posting date
customer sales invoice date
```

### 7.2 Internal-transfer date

The internal-transfer date comes from the source bank statement date(s):

```text
source_out_date = main-bank OUT statement date
destination_in_date = DVA/card IN statement date
```

If the dates differ, use the in-transit clearing treatment in section 6.1.

### 7.3 Short Sage references

Do not use a business-name prefix such as `GCB` for completion-loyalty Sage references.

Sage references are short display/audit references only. They are not the source of truth.

Use short neutral prefixes, for example:

```text
LT-<match6>   loyalty transfer
LA-<event6>   loyalty application/allocation
LC-<event6>   loyalty clearing
```

Keep references compact so they fit restrictive Sage reference fields.

The existing generic cash receipt references, including final-balance receipt references, are not completion-loyalty Sage references. This no-GCB rule applies to the new completion-loyalty Sage posting lane only.

### 7.4 Source IDs are the source of truth

Full traceability must live in the platform posting tables/logs, not in the Sage reference text.

The loyalty internal-transfer source chain must store at least:

```text
loyalty_match_id
source_out_statement_line_id
destination_in_statement_line_id
source_credit_ledger_id / credit_ledger_id
```

The applied-loyalty settlement source chain must store at least:

```text
source_credit_ledger_id / credit_ledger_id
debit_ledger_id
order_funding_event_id
order_id
target_sage_invoice_snapshot_id(s)
target_sage_invoice_id(s)
```

The relationship chain is:

```text
main_bank_completion_loyalty_funding_matches.id
  -> source_out_statement_line_id
  -> destination_in_statement_line_id
  -> source_credit_ledger_id / credit_ledger_id
  -> debit importer_credit_ledger row when applied
  -> order_funding_events.credit_applied
  -> order_id
  -> posted customer_sales Sage invoice snapshot(s)
```

---

## 8. VAT alignment

No completion-loyalty Sage/accounting posting may create VAT return source rows.

No completion-loyalty Sage/accounting posting may change:

```text
order_funding_events
sales_invoices
vat_return_runs
vat_return_run_lines
vat_return_adjustment_journals
vat_return_adjustment_journal_lines
```

VAT timing remains driven only by the existing VAT engine and the existing funding events:

```text
order_funding_events.credit_applied
order_funding_events.funding_reversed
```

Applied-loyalty settlement posting is not the VAT source.

Internal-transfer journal posting is not the VAT source.

The final-balance customer-receipt bridge is also not the VAT source. It posts customer cash already classified by the platform as final-balance received; VAT timing remains with the existing final-sale/funding/VAT engine.

Sage journal lines used for loyalty clearing or internal transfer must be:

```text
include_on_tax_return = false
tax_rate_id = null
```

If any alternative Sage endpoint requires a tax rate, the row must remain blocked until the exact VAT-safe treatment is proven.

---

## 9. Proposed tables

Do not reuse VAT return adjustment journal tables.

Do not reuse generic cash posting tables for loyalty, except as reference patterns.

Create dedicated loyalty accounting posting tables, for example:

```text
completion_loyalty_sage_posting_groups
completion_loyalty_sage_posting_steps
completion_loyalty_sage_posting_step_logs
```

### 9.1 Posting group minimum fields

```text
id
posting_group_ref
posting_group_type = 'completion_loyalty_applied_settlement' | 'completion_loyalty_internal_transfer_journal'
order_id
order_ref
importer_id
order_funding_event_id
loyalty_match_id
source_credit_ledger_id
debit_ledger_id
target_sage_invoice_snapshot_ids jsonb
target_sage_invoice_ids jsonb
amount_gbp
posting_date
status
blocker
created_by_staff_id
approved_by_staff_id
approved_at
posted_at
reversed_at
created_at
updated_at
```

### 9.2 Posting step minimum fields

```text
id
posting_group_id
step_type
source_table
source_id
endpoint_path
method
idempotency_key
request_payload
request_payload_hash
response_payload
sage_object_type
sage_object_id
sage_reference
status
retry_count
last_error
posted_at
created_at
updated_at
```

Required applied-loyalty settlement steps:

```text
loyalty_customer_receipt
loyalty_customer_allocation
loyalty_clearing_offset
```

Required internal-transfer step(s):

```text
loyalty_internal_transfer_journal
loyalty_internal_transfer_out_to_in_transit
loyalty_internal_transfer_in_transit_to_dva
```

Use the one-step internal-transfer journal only when source OUT date and destination IN date are the same accounting date.

---

## 10. Status flow

Use a controlled status flow:

```text
draft
blocked
locally_validated
admin_approved
posting_to_sage
partially_posted_needs_review
posted_to_sage
failed_retryable
failed_terminal
cancelled
reversal_required
reversed
```

No live posting is allowed from `draft`.

No live posting is allowed from `blocked`.

No live posting is allowed before `admin_approved`.

No second live post is allowed once the relevant Sage object id exists.

Partial success must not be hidden. If the receipt posts but allocation or clearing offset fails, the group must be marked:

```text
partially_posted_needs_review
```

and the successful Sage object ids must be preserved.

---

## 11. Feature flags

Use separate feature flags:

```text
SAGE_LIVE_COMPLETION_LOYALTY_SETTLEMENT_POSTING_ENABLED
SAGE_LIVE_COMPLETION_LOYALTY_INTERNAL_TRANSFER_POSTING_ENABLED
```

For MVP:

```text
SAGE_LIVE_COMPLETION_LOYALTY_SETTLEMENT_POSTING_ENABLED may be enabled only after controlled test approval.
SAGE_LIVE_COMPLETION_LOYALTY_INTERNAL_TRANSFER_POSTING_ENABLED may be enabled only after controlled journal dry-run approval.
```

The existing cash receipt/final-balance bridge remains governed by the existing cash posting and cash allocation feature flags, not by the completion-loyalty feature flags.

---

## 12. UI placement

Use the existing Accounting Command Centre loyalty controls page:

```text
/internal/accounting-command-centre/loyalty-controls
```

Add sections:

```text
Applied loyalty customer settlement posting
Internal transfer journal posting
```

Do not put these rows into the VAT return workbench.

Do not put loyalty posting groups into generic cash posting batches.

Do not make the existing loyalty preview rows selectable.

Do not add generic loyalty posting buttons to the DVA review pack.

Final-balance customer receipt rows are not loyalty posting groups. They may remain in the existing Cash Posting Workbench because they are real customer cash receipts that settle supplementary/final-balance receivables.

---

## 13. Source workbench handoff rule

The DVA/card and main-bank workbenches remain the source reconciliation, classification, and pairing workbenches.

They are not the Sage posting workbench for completion loyalty.

### 13.1 Main-bank workbench role

The main-bank workbench may:

```text
show main-bank OUT statement lines
reserve a main-bank OUT line against a completion-loyalty reward target
show completion-loyalty classification/status
show whether the OUT has been paired with a DVA/card IN
show a link/status to the Accounting Command Centre loyalty posting group
```

The main-bank workbench must not:

```text
post the loyalty transfer to Sage directly
send the loyalty OUT line to generic cash posting
classify the loyalty OUT as shipper_invoice_payment
classify the loyalty OUT as supplier_invoice_payment
classify the loyalty OUT as bank_fee or fx_card_difference
```

### 13.2 DVA/card workbench role

The DVA/card side may:

```text
show eligible DVA/card/virtual-card IN lines
allow staff to pair the DVA/card IN line with the reserved loyalty OUT
mark the IN line as consumed/explained by completion-loyalty internal transfer
show a link/status to the Accounting Command Centre loyalty posting group
```

The DVA/card side must not:

```text
post the loyalty IN line to Sage directly
send the loyalty IN line to customer_receipt_on_account
classify the loyalty IN as real customer cash
create order_funding_events.funding_contribution from the loyalty IN
```

This restriction is for completion-loyalty transfer IN lines only. It does not block genuine customer final-balance IN payments from being bridged to customer_receipt_on_account through `source_type = dva_final_balance_allocation`.

### 13.3 Handoff to Accounting Command Centre

Once the main-bank OUT and DVA/card IN are paired and released, the pair becomes a candidate for the dedicated Accounting Command Centre loyalty internal-transfer journal lane.

The handoff source is:

```text
main_bank_completion_loyalty_funding_matches
```

The Sage posting workbench is:

```text
/internal/accounting-command-centre/loyalty-controls
```

The posted internal-transfer journal must include both sides, either directly or through in-transit clearing:

```text
Dr DVA/card/virtual-card bank / clearing asset
Cr main bank
```

This is how the loyalty IN is posted. It is the debit line of the internal-transfer journal, not a standalone customer receipt.

---

## 14. Reversal rule

Operational reversal stays with the existing funding model:

```text
order_funding_events.funding_reversed
```

Sage/accounting reversal must reverse the specific Sage objects created by the loyalty posting group.

For applied-loyalty settlement:

```text
reverse customer allocation/payment-on-account treatment as supported by Sage, or create approved correcting entries if direct reversal is not available;
reverse the loyalty clearing offset;
keep full request/response logs;
never edit a posted Sage object silently.
```

For internal transfer:

```text
If one-step journal was used:
  reverse by separate reversing internal-transfer journal;
  Dr main bank
  Cr DVA/card/virtual-card bank / clearing asset

If in-transit two-step journals were used:
  reverse the exact posted step(s) with equal and opposite dated journals;
  preserve the in-transit clearing audit trail.
```

No reversal may directly edit locked VAT return rows.

VAT correction remains governed by the existing VAT workbench/source-line/current-period correction pattern.

---

## 15. Non-impact boundaries

This build must not change:

```text
customer sales invoice creation
customer sales Sage posting
supplier goods/AP posting
shipper/AP posting
main-bank shipper/AP allocation
supplier invoice payment posting
bank fee posting
FX/card residual posting
VAT return workbench
VAT adjustment journal posting
DVA/card reconciliation core
order creation
shipment/export/POD flow
completion loyalty approval/rejection
completion loyalty pairing/release
customer self-service credit display
staff apply-loyalty-to-order logic
```

Approved shared prerequisite exceptions:

```text
normal customer cash receipt posting may read confirmed final_balance_payment DVA/card IN allocations through source_type = dva_final_balance_allocation;
normal customer cash allocation may use the shared deterministic multi-invoice same-order/same-contact resolver;
these changes must not alter supplier/AP, shipper/AP, bank fee, FX/card residual, VAT, order, shipment, loyalty approval, or loyalty application logic.
```

The loyalty Sage build may read from the approved shared customer-receivable resolver, but must not mutate non-loyalty areas except through its own dedicated loyalty posting tables/logs.

---

## 16. Required tests

Minimum tests before implementation acceptance:

```text
1. Pending loyalty does not materialise.
2. Rejected loyalty does not materialise.
3. Staged main-bank OUT does not materialise as applied settlement.
4. Released but unused loyalty does not materialise as customer settlement.
5. Applied credit_applied completion-loyalty event materialises exactly one settlement posting group.
6. Duplicate materialisation attempt does not create a second active group.
7. Missing customer Sage contact blocks settlement posting.
8. Missing posted customer sales invoice blocks settlement posting.
9. Multiple posted customer sales invoices for the same order do not automatically block if a deterministic same-order/same-contact/open-balance allocation target list can be built.
10. Ambiguous multiple-invoice target list blocks for accounting review.
11. Missing loyalty clearing bank/account mapping blocks settlement posting.
12. Missing loyalty reward expense mapping blocks clearing offset.
13. Settlement receipt amount equals applied loyalty amount.
14. Settlement allocation total equals applied loyalty amount.
15. Clearing offset amount equals applied loyalty amount.
16. Applied-loyalty settlement date equals credit_applied.created_at::date.
17. Net accounting equals Dr loyalty reward expense / Cr customer receivable.
18. Loyalty Sage references do not use a business-name prefix such as GCB.
19. Loyalty Sage references fit the short-reference limit used by the posting payload.
20. Feature flag blocks live settlement posting when disabled.
21. Admin approval is required before live posting.
22. Live settlement receipt writes Sage request log.
23. Live settlement receipt writes Sage response log.
24. Live allocation writes Sage request log.
25. Live allocation writes Sage response log.
26. Clearing offset writes Sage request log.
27. Clearing offset writes Sage response log.
28. Successful posting stores all Sage object ids and references.
29. Successful posting stores source IDs, not only short reference text.
30. A receipt success with allocation failure leaves partially_posted_needs_review.
31. A receipt/allocation success with clearing offset failure leaves partially_posted_needs_review.
32. No duplicate receipt is posted on retry after partial success.
33. Internal-transfer journal materialises only for paired_released loyalty matches.
34. Internal-transfer journal uses POST /journals only.
35. Missing internal-transfer main-bank ledger mapping blocks posting.
36. Missing internal-transfer DVA/card ledger mapping blocks posting.
37. Different source OUT and destination IN dates use in-transit clearing instead of a forced single date.
38. Internal-transfer journal has include_on_tax_return = false and tax_rate_id = null.
39. Source workbenches show handoff/link/status but do not post loyalty to Sage directly.
40. Loyalty IN is not routed to customer_receipt_on_account.
41. Loyalty OUT is not routed to shipper_invoice_payment, supplier_invoice_payment, bank_fee, or fx_card_difference.
42. No loyalty posting creates vat_return_run_lines.
43. No loyalty posting creates vat_return_adjustment_journals.
44. No loyalty posting changes order_funding_events.
45. No loyalty posting changes sales_invoices.
46. VAT return still picks up credit_applied from order_funding_events.
47. VAT return still picks up funding_reversed from order_funding_events.
48. Existing customer cash receipt posting still works.
49. Existing customer cash allocation still works.
50. Existing VAT adjustment journal posting still works.
51. Existing supplier/AP posting still works.
52. Existing shipper/AP posting still works.
53. Existing DVA review pack classifications remain unchanged.
54. Existing completion-loyalty control rows remain unchanged.
55. Confirmed final_balance_payment DVA/card IN appears in the Cash Posting Workbench as customer_receipt_on_account with source_type = dva_final_balance_allocation.
56. Unconfirmed final_balance_payment does not become selectable for cash posting.
57. Final-balance OUT lines are blocked and cannot post as customer receipt.
58. Final-balance customer receipt uses the same importer/customer Sage contact as the order.
59. Final-balance customer receipt uses DVA_CASH_BANK_ACCOUNT mapping, not loyalty clearing or main-bank mapping.
60. Final-balance customer receipt can be frozen and posted through the existing customer receipt cash-posting flow.
61. Final-balance customer receipt can allocate to an open supplementary customer_sales invoice for the same order.
62. Initial customer receipt plus final-balance receipt can clear main and supplementary customer_sales invoices for the same order.
63. Replacement child invoice does not get pulled into parent receipt allocation through parent_order_id.
64. Final-balance bridge does not create VAT rows, does not mutate order_funding_events, and does not mutate sales_invoices.
```

---

## 17. Final implementation principle

The seamless MVP integration is:

```text
Use the existing DVA/card and main-bank workbenches only to reconcile, classify, and pair the loyalty IN/OUT source lines.
Use the existing loyalty pairing tables for the internal-transfer journal source.
Use the existing applied credit_applied event for customer settlement eligibility.
Treat confirmed final_balance_payment DVA/card IN allocations as ordinary customer cash receipts through source_type = dva_final_balance_allocation, outside the loyalty lane.
Use the shared deterministic customer-receivable allocation resolver for normal cash receipts, final-balance receipts, and loyalty non-cash settlement receipts.
Settle the Sage customer account through a dedicated non-cash loyalty settlement lane, not through generic customer cash.
Allocate applied loyalty against open posted customer_sales invoice snapshot(s) for the same order and same Sage contact using a deterministic frozen target list.
Clear the loyalty settlement clearing account to loyalty reward expense.
Post the paired main-bank OUT and DVA/card IN transfer through the existing /journals primitive, using in-transit clearing where statement dates differ.
Keep VAT timing on order_funding_events.
Keep VAT workbench and VAT adjustment journals untouched.
Keep supplier/AP, shipper/AP, bank fee, FX/card residual, customer sales posting, order, shipment, and DVA reconciliation core untouched.
```
