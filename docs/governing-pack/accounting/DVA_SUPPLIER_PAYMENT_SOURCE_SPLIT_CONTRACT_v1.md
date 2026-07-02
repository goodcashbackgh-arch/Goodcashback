# DVA Supplier Payment Source Split Contract v1

## Decision

The separate completion-loyalty supplier-wallet payment shortcut is retired as an accounting route.

Supplier AP settlement must flow through the DVA/card statement allocation and cash posting workbench path. Loyalty, virtual wallet, and real DVA cash funding are represented as source-specific payment legs, not as a separate supplier-wallet bridge.

## Correct Route

The only supported route for supplier invoice cash settlement is:

1. Upload/import the DVA, card, wallet, or virtual statement line.
2. Create a confirmed statement-line allocation to the supplier invoice.
3. Stamp the allocation with the source bank mapping derived from proven funding provenance.
4. Surface the allocation in the cash posting workbench.
5. Freeze and validate the cash posting row.
6. Create the cash posting batch.
7. Post the batch to Sage as a supplier/vendor payment.

## Required Accounting

Supplier AP settlement must split by source bank account.

For each supplier invoice payment leg, the cash posting row must carry:

- the supplier invoice target,
- the allocated GBP amount,
- the source statement/allocation reference,
- the Sage supplier contact,
- the correct Sage bank account for that funding source.

The workbench must not default every supplier invoice payment allocation to `DVA_CASH_BANK_ACCOUNT`.

The allocation layer must not infer loyalty/virtual source from statement currency alone. A GBP importer statement line remains real DVA/card cash unless the order has an exact remaining released completion-loyalty funding source that resolves to `virtual_gbp_wallet`.

## Example

Supplier invoice total: `GBP 199.99`

Funding split:

- `GBP 180.00` real DVA/customer cash
- `GBP 19.99` released completion-loyalty virtual GBP funding

Correct supplier payment rows:

| Amount | Debit | Credit |
| ---: | --- | --- |
| GBP 180.00 | Supplier AP | DVA_CASH_BANK_ACCOUNT |
| GBP 19.99 | Supplier AP | LOYALTY_VIRTUAL_GBP_BANK_ACCOUNT |

If the released completion-loyalty funding resolves to DVA GHS instead, the second credit is `LOYALTY_DVA_GHS_BANK_ACCOUNT`.

This settles supplier AP for `GBP 199.99`, but credits the correct bank or wallet source for each leg.

## Forbidden Behaviour

Do not post the full supplier invoice amount from `DVA_CASH_BANK_ACCOUNT` unless the full amount was actually funded by real DVA/customer cash.

Do not create or use a separate `completion_loyalty_supplier_wallet_payment` bridge as a shortcut to supplier payment posting.

Do not create fake `credit_applied` or importer credit ledger rows purely to make a loyalty supplier payment candidate appear.

Do not bypass statement-line allocation provenance for loyalty or virtual wallet funding.

Do not map `importer_dva_card_account + GBP` to `LOYALTY_VIRTUAL_GBP_BANK_ACCOUNT` unless the order funding chain proves an exact remaining released virtual GBP completion-loyalty source.

Do not hard-code Sage bank ids in migrations for this route. Sage external ids are controlled by `sage_mapping_settings`; missing mappings must block cash posting.

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

At minimum, supplier invoice allocation rows or their workbench projection must identify the bank source mapping:

- `DVA_CASH_BANK_ACCOUNT` for real DVA/customer cash,
- `LOYALTY_DVA_GHS_BANK_ACCOUNT` for released loyalty-funded DVA GHS wallet cash,
- `LOYALTY_VIRTUAL_GBP_BANK_ACCOUNT` for released loyalty-funded virtual GBP wallet cash.

The existing freeze, batch, and Sage cash-out poster may continue to be used, provided each emitted workbench row carries the correct `amount_gbp` and `sage_bank_account_id`.

## Cash Posting Workbench Union Impact

The source split is consumed in `internal_cash_posting_workbench_rows_v1(...)`.

Only the `allocation_rows` union branch is affected:

```text
dva_statement_line_allocation_detail_vw
-> dva_statement_line_allocations.source_bank_account_mapping_code
-> sage_mapping_settings
-> supplier_invoice_payment row sage_bank_account_id
```

The following union branches are intentionally unaffected:

- `customer_receipts`
- `final_balance_receipts`

Cash freeze, batch creation, and Sage posting remain downstream consumers of the resolved workbench row. They must not re-resolve source provenance.

## Test Case

Use the split case below as the canonical regression scenario:

- Order ref: `ORD-1777655033603`
- Supplier invoice ref: `4004238649`
- Supplier invoice total: `GBP 199.99`
- Real DVA cash leg: `GBP 180.00`
- Released loyalty/virtual leg: `GBP 19.99`

Expected cash posting output:

```text
supplier_invoice_payment GBP 180.00  -> DVA_CASH_BANK_ACCOUNT
supplier_invoice_payment GBP 19.99   -> LOYALTY_VIRTUAL_GBP_BANK_ACCOUNT or LOYALTY_DVA_GHS_BANK_ACCOUNT
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

Also unexpected:

```text
supplier_invoice_payment GBP 19.99 from a normal GBP importer statement -> LOYALTY_VIRTUAL_GBP_BANK_ACCOUNT without released-loyalty provenance
```
