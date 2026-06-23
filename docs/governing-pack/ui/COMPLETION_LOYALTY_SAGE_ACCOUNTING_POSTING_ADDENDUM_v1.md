# Completion Loyalty Sage Accounting Posting Addendum v1

Status: locked implementation contract addendum to `COMPLETION_LOYALTY_MAIN_BANK_DVA_PAIRING_ACCOUNTING_CONTRACT_v1.md` and `COMPLETION_LOYALTY_APPLIED_ACCOUNTING_PREVIEW_ADDENDUM_v1.md`.

This addendum authorises the next MVP accounting/Sage build for completion loyalty without changing the already-locked loyalty activation, credit application, VAT return, DVA/card reconciliation, customer sales, supplier/AP, shipper/AP, or cash-posting flows.

It deliberately does not rewrite the 23 June 2026 completion-loyalty contract. It narrows how the next Sage/accounting layer plugs into the existing platform.

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

A row is eligible for internal-transfer readiness only when:

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

### Phase 1 — Applied-loyalty customer settlement posting

This is the first live-posting candidate because it is triggered by the existing `credit_applied` event and directly settles the customer account/order balance.

The implementation must not treat it as ordinary cash receipt from the customer. It must use a dedicated non-cash loyalty settlement lane.

### Phase 2 — Loyalty internal-transfer readiness

The internal-transfer accounting control must be visible and reconcilable, but live Sage posting for the internal bank transfer must remain disabled until the exact Sage method is proven.

This phase may materialise readiness rows and preview payloads.

It must not add a live posting button until a later endpoint/mapping proof confirms the correct Sage treatment.

---

## 4. Correct Sage treatment for applied loyalty

A pure GL journal is not sufficient if the business needs the Sage customer/contact account to show the customer invoice as settled.

For MVP correctness, the applied-loyalty settlement should use the existing proven customer-account pattern, but in a dedicated non-cash loyalty lane:

```text
Step 1: create a non-cash customer receipt/payment-on-account using a dedicated loyalty clearing bank/account.
Step 2: allocate that payment-on-account to the posted Sage customer sales invoice for the order.
Step 3: clear the loyalty clearing balance to loyalty reward expense using a VAT-safe journal/clearing entry.
```

Net accounting result:

```text
Dr loyalty reward expense / approved loyalty cost account
Cr customer account / receivable
```

Operational Sage result:

```text
Customer invoice is settled on the Sage customer/contact account.
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

The applied-loyalty customer settlement lane may use the same mechanics already proven by the existing cash receipt/allocation and journal posting code paths:

```text
POST /contact_payments
POST /contact_allocations
POST /journals or a separately proven clearing-offset endpoint
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

The target customer sales invoice must already be posted to Sage.

If multiple posted Sage customer sales invoices exist for the same order, the row must block for manual target selection. It must not guess.

If no posted Sage customer sales invoice exists, the row must block until customer sales posting is complete.

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

The settlement payment-on-account must be allocated to the posted Sage customer sales invoice for the same order/customer.

The allocation amount must equal the applied loyalty amount, capped only by the open invoice amount.

If the posted invoice open amount is lower than the applied loyalty amount, the row must block for accounting review. It must not silently part-post unless a later contract allows partial settlement.

### 5.6 Clearing offset

The clearing offset must record:

```text
Dr LOYALTY_REWARD_EXPENSE_LEDGER
Cr loyalty settlement clearing account/ledger
```

The preferred endpoint for the clearing offset is the existing VAT-safe journal pattern if the Sage ledger mapping supports it:

```text
POST /journals
```

The journal lines must use:

```text
include_on_tax_return = false
tax_rate_id = null
```

If Sage does not allow the chosen clearing account/ledger to be cleared by journal, a later mini-proof must approve the alternative endpoint before live posting is enabled.

---

## 6. Internal-transfer readiness mechanics

The internal transfer is not customer settlement. It is only the movement of company funds into the DVA/card/virtual-card account.

For MVP, create or extend read-only/internal readiness rows using:

```text
main_bank_completion_loyalty_funding_matches
```

Minimum readiness output:

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
posting_enabled = false
blocker
```

Readiness status examples:

```text
ready_internal_transfer_accounting_preview
blocked_missing_source_out_line
blocked_missing_destination_in_line
blocked_unpaired_or_not_released
blocked_internal_transfer_sage_method_not_proven
```

### 6.1 Internal-transfer accounting treatment

Preview accounting treatment:

```text
Dr DVA/card/virtual-card bank / clearing asset
Cr main bank
```

### 6.2 No live internal-transfer posting yet

Do not live-post internal transfers until a later proof confirms one of:

```text
Sage bank-transfer endpoint exists and is tested; or
Sage journal to the mapped bank/clearing ledger accounts is accepted and VAT-safe.
```

The first MVP must therefore keep internal-transfer live posting disabled.

---

## 7. VAT alignment

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

Internal-transfer posting/readiness is not the VAT source.

Sage journal lines used for loyalty clearing must be:

```text
include_on_tax_return = false
tax_rate_id = null
```

If any alternative Sage endpoint requires a tax rate, the row must remain blocked until the exact VAT-safe treatment is proven.

---

## 8. Proposed tables

Do not reuse VAT return adjustment journal tables.

Do not reuse generic cash posting tables for loyalty, except as reference patterns.

Create dedicated loyalty accounting posting tables, for example:

```text
completion_loyalty_sage_posting_groups
completion_loyalty_sage_posting_steps
completion_loyalty_sage_posting_step_logs
```

### 8.1 Posting group minimum fields

```text
id
posting_group_ref
posting_group_type = 'completion_loyalty_applied_settlement' | 'completion_loyalty_internal_transfer_preview'
order_id
order_ref
importer_id
order_funding_event_id
loyalty_match_id
source_credit_ledger_id
debit_ledger_id
amount_gbp
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

### 8.2 Posting step minimum fields

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

Required internal-transfer readiness step:

```text
loyalty_internal_transfer_preview
```

Live internal-transfer step is reserved for a later endpoint-proof addendum.

---

## 9. Status flow

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

## 10. Feature flags

Use separate feature flags:

```text
SAGE_LIVE_COMPLETION_LOYALTY_SETTLEMENT_POSTING_ENABLED
SAGE_LIVE_COMPLETION_LOYALTY_INTERNAL_TRANSFER_POSTING_ENABLED
```

For MVP:

```text
SAGE_LIVE_COMPLETION_LOYALTY_SETTLEMENT_POSTING_ENABLED may be enabled only after controlled test approval.
SAGE_LIVE_COMPLETION_LOYALTY_INTERNAL_TRANSFER_POSTING_ENABLED must remain false until endpoint/mapping proof is complete.
```

---

## 11. UI placement

Use the existing Accounting Command Centre loyalty controls page:

```text
/internal/accounting-command-centre/loyalty-controls
```

Add sections:

```text
Applied loyalty customer settlement posting
Internal transfer accounting readiness
```

Do not put these rows into the VAT return workbench.

Do not put these rows into generic cash posting batches.

Do not make the existing preview rows selectable.

Do not add generic posting buttons to the DVA review pack.

---

## 12. Reversal rule

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
reverse by separate reversing internal-transfer entry only after the live method is proven.
```

No reversal may directly edit locked VAT return rows.

VAT correction remains governed by the existing VAT workbench/source-line/current-period correction pattern.

---

## 13. Non-impact boundaries

This build must not change:

```text
customer sales invoice creation
customer sales Sage posting
supplier goods/AP posting
shipper/AP posting
main-bank shipper/AP allocation
normal customer cash receipt posting
normal customer cash allocation
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

It may read from those areas, but must not mutate them except for its own dedicated loyalty posting tables/logs.

---

## 14. Required tests

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
9. Multiple posted customer sales invoices for the order block for manual target selection.
10. Missing loyalty clearing bank/account mapping blocks settlement posting.
11. Missing loyalty reward expense mapping blocks clearing offset.
12. Settlement receipt amount equals applied loyalty amount.
13. Settlement allocation amount equals applied loyalty amount.
14. Clearing offset amount equals applied loyalty amount.
15. Net accounting equals Dr loyalty reward expense / Cr customer receivable.
16. Feature flag blocks live settlement posting when disabled.
17. Admin approval is required before live posting.
18. Live settlement receipt writes Sage request log.
19. Live settlement receipt writes Sage response log.
20. Live allocation writes Sage request log.
21. Live allocation writes Sage response log.
22. Clearing offset writes Sage request log.
23. Clearing offset writes Sage response log.
24. Successful posting stores all Sage object ids and references.
25. A receipt success with allocation failure leaves partially_posted_needs_review.
26. A receipt/allocation success with clearing offset failure leaves partially_posted_needs_review.
27. No duplicate receipt is posted on retry after partial success.
28. Internal-transfer readiness appears only for paired_released loyalty matches.
29. Internal-transfer live posting remains disabled in MVP.
30. No loyalty posting creates vat_return_run_lines.
31. No loyalty posting creates vat_return_adjustment_journals.
32. No loyalty posting changes order_funding_events.
33. No loyalty posting changes sales_invoices.
34. VAT return still picks up credit_applied from order_funding_events.
35. VAT return still picks up funding_reversed from order_funding_events.
36. Existing customer cash receipt posting still works.
37. Existing customer cash allocation still works.
38. Existing VAT adjustment journal posting still works.
39. Existing supplier/AP posting still works.
40. Existing shipper/AP posting still works.
41. Existing DVA review pack classifications remain unchanged.
42. Existing completion-loyalty control rows remain unchanged.
```

---

## 15. Final implementation principle

The seamless MVP integration is:

```text
Use the existing loyalty pairing tables only for internal-transfer readiness.
Use the existing applied credit_applied event for customer settlement eligibility.
Settle the Sage customer account through a dedicated non-cash loyalty settlement lane, not through generic customer cash.
Clear the loyalty settlement clearing account to loyalty reward expense.
Keep VAT timing on order_funding_events.
Keep VAT workbench and VAT adjustment journals untouched.
Keep generic cash, supplier/AP, shipper/AP, and customer sales posting untouched.
```
