# DVA Supplier Payment Source Split Contract v1

## Decision

The separate completion-loyalty supplier-wallet payment shortcut is retired as an accounting route.

Supplier AP settlement must flow through the DVA/card statement allocation and cash posting workbench path. Loyalty, virtual wallet, and real DVA cash funding are represented as source-specific payment legs, not as a separate supplier-wallet bridge.

## Correct Route

The only supported route for supplier invoice cash settlement is:

1. Upload/import the DVA, card, wallet, or virtual statement line.
2. Create a confirmed statement-line allocation to the supplier invoice.
3. Surface the allocation in the cash posting workbench.
4. Freeze and validate the cash posting row.
5. Create the cash posting batch.
6. Post the batch to Sage as a supplier/vendor payment.

## Required Accounting

Supplier AP settlement must split by source bank account.

For each supplier invoice payment leg, the cash posting row must carry:

- the supplier invoice target,
- the allocated GBP amount,
- the source statement/allocation reference,
- the Sage supplier contact,
- the correct Sage bank account for that funding source.

The workbench must not default every supplier invoice payment allocation to `DVA_CASH_BANK_ACCOUNT`.

## Example

Supplier invoice total: `GBP 199.99`

Funding split:

- `GBP 180.00` real DVA/customer cash
- `GBP 19.99` completion-loyalty or virtual wallet funding

Correct supplier payment rows:

| Amount | Debit | Credit |
| ---: | --- | --- |
| GBP 180.00 | Supplier AP | DVA_CASH_BANK_ACCOUNT |
| GBP 19.99 | Supplier AP | LOYALTY_DVA_GHS_BANK_ACCOUNT or virtual wallet bank |

This settles supplier AP for `GBP 199.99`, but credits the correct bank or wallet source for each leg.

## Forbidden Behaviour

Do not post the full supplier invoice amount from `DVA_CASH_BANK_ACCOUNT` unless the full amount was actually funded by real DVA/customer cash.

Do not create or use a separate `completion_loyalty_supplier_wallet_payment` bridge as a shortcut to supplier payment posting.

Do not create fake `credit_applied` or importer credit ledger rows purely to make a loyalty supplier payment candidate appear.

Do not bypass statement-line allocation provenance for loyalty or virtual wallet funding.

## Retired Path

The following route is retired and should be reversed or superseded:

```text
completion-loyalty released match
-> importer credit / order funding event candidate
-> completion_loyalty_supplier_wallet_payment cash snapshot
-> supplier wallet cash batch
-> Sage supplier payment
```

This path bypasses the DVA/card statement allocation model and can post the wrong credit bank account for split-funded supplier AP settlements.

## Replacement Requirement

The replacement implementation must make source-specific supplier invoice payment legs visible through the normal cash posting workbench.

At minimum, supplier invoice allocation rows or their workbench projection must identify the bank source mapping, for example:

- `DVA_CASH_BANK_ACCOUNT` for real DVA/customer cash,
- `LOYALTY_DVA_GHS_BANK_ACCOUNT` for loyalty-funded DVA wallet cash,
- the appropriate virtual wallet bank mapping for virtual wallet funding.

The existing freeze, batch, and Sage cash-out poster may continue to be used, provided each emitted workbench row carries the correct `amount_gbp` and `sage_bank_account_id`.

## Test Case

Use the split case below as the canonical regression scenario:

- Order ref: `ORD-1777655033603`
- Supplier invoice ref: `4004238649`
- Supplier invoice total: `GBP 199.99`
- Real DVA cash leg: `GBP 180.00`
- Loyalty/virtual leg: `GBP 19.99`

Expected cash posting output:

```text
supplier_invoice_payment GBP 180.00  -> DVA_CASH_BANK_ACCOUNT
supplier_invoice_payment GBP 19.99   -> LOYALTY_DVA_GHS_BANK_ACCOUNT or virtual wallet bank
```

Unexpected output:

```text
supplier_invoice_payment GBP 199.99 -> DVA_CASH_BANK_ACCOUNT
```

Also unexpected:

```text
supplier_invoice_payment GBP 180.00 -> DVA_CASH_BANK_ACCOUNT
supplier_invoice_payment GBP 19.99  -> DVA_CASH_BANK_ACCOUNT
```
