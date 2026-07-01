# Completion Loyalty Supplier Wallet Payment Addendum v1

## Status

Locked additive clarification for completion-loyalty supplier payments.

This addendum does not replace the existing DVA/card cash posting workbench. It defines the missing loyalty-funded supplier payment leg and requires the smallest integration path that preserves the current DVA cash posting route.

## Accounting correction

When loyalty value is used to pay a supplier invoice, the loyalty portion does not touch the DVA cash bank account.

Example:

```text
Supplier invoice/order payable: £100
Normal importer/DVA cash portion: £80
Completion-loyalty wallet portion: £20
```

Correct supplier payment execution:

```text
£80  -> existing DVA cash supplier payment route
£20  -> loyalty wallet supplier payment route
```

The £20 must post as a Sage vendor payment from the resolved loyalty wallet bank account:

```text
POST /contact_payments
transaction_type_id = VENDOR_PAYMENT
bank_account_id = LOYALTY_VIRTUAL_GBP_BANK_ACCOUNT or LOYALTY_DVA_GHS_BANK_ACCOUNT
allocated_artefacts[] = posted supplier purchase invoice artefact
```

It must not create:

```text
Dr DVA cash
Cr loyalty wallet
```

That reclassification is wrong for this flow because the loyalty wallet payment never enters DVA cash.

## Existing route to reuse

The repository already has the supplier OUT posting adapter:

```text
cash_posting_snapshots / cash_posting_batches / cash_posting_batch_rows
-> postSupplierOrShipperPaymentCashBatchToSage
-> POST /contact_payments
-> VENDOR_PAYMENT
-> allocated_artefacts[]
```

That adapter already validates and posts from the frozen `bank_account_id` on the cash posting row.

Therefore the minimum robust patch is additive:

```text
completion loyalty workbench creates a supplier_invoice_payment cash snapshot/batch
with bank_account_id = resolved loyalty wallet Sage bank account id
```

Do not change the existing DVA/card allocation workbench. Do not change `DVA_CASH_BANK_ACCOUNT`. Do not change the original supplier/DVA cash posting read model.

## Required mappings

These are Sage bank account ids for `/contact_payments`, not GL/display numbers and not `/journals` ledger account ids:

```text
LOYALTY_VIRTUAL_GBP_BANK_ACCOUNT
LOYALTY_DVA_GHS_BANK_ACCOUNT
```

These are separate from the existing internal-transfer journal mappings:

```text
LOYALTY_VIRTUAL_GBP_BANK_LEDGER
LOYALTY_DVA_GHS_BANK_LEDGER
LOYALTY_MAIN_GBP_BANK_LEDGER
```

The `_BANK_LEDGER` mappings are for `/journals` only. The `_BANK_ACCOUNT` mappings are for supplier/customer cash payment endpoints.

## Wallet resolver

Use the already established upload currency rule:

```text
statement_account_context = importer_dva_card_account + local_ccy = GBP
-> virtual_gbp_wallet
-> LOYALTY_VIRTUAL_GBP_BANK_ACCOUNT

statement_account_context = importer_dva_card_account + local_ccy = GHS
-> dva_ghs_wallet
-> LOYALTY_DVA_GHS_BANK_ACCOUNT
```

No OCR bank-account-number dependency is required for MVP.

## Eligibility gate

A loyalty supplier wallet payment can be frozen only when all are true:

```text
order_funding_events.event_type = credit_applied
source credit is completion_loyalty_reward
paired released funding match exists
funding match has destination_in_statement_line_id
wallet bank account mapping exists
supplier goods AP invoice for the order has already posted to Sage
retailer/supplier Sage contact mapping exists
loyalty amount is positive and does not exceed the posted supplier invoice amount
no active duplicate loyalty wallet supplier payment snapshot exists for that event/invoice/wallet
```

The posting date is the credit-applied event date unless a later UI override is explicitly added.

## Non-impact rule

This patch must not affect:

```text
DVA_CASH_BANK_ACCOUNT
existing DVA/card cash posting workbench rows
existing supplier_invoice_payment rows sourced from dva_statement_line_allocations
customer/importer receipt posting
supplier goods AP purchase invoice posting
completion-loyalty internal-transfer journals
completion-loyalty applied customer settlement
VAT treatment
```

The only new output is a loyalty-origin `supplier_invoice_payment` cash posting snapshot/batch whose frozen bank account is the loyalty wallet bank account.
