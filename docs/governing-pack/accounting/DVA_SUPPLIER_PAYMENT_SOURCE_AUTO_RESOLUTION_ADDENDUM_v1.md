# DVA Supplier Payment Source Auto-Resolution Addendum v1

## Parent Contract

This addendum extends `docs/governing-pack/accounting/DVA_SUPPLIER_PAYMENT_SOURCE_SPLIT_CONTRACT_v1.md`.

## Decision

Supplier invoice payment source bank selection should be automatic for the existing DVA reconciliation supplier-allocation route.

Do not add a separate supplier-wallet workbench, page, or cash posting route.

Do not require staff to manually choose the source bank during supplier allocation for the initial virtual GBP split case.

## Source Resolution Rule

When `staff_allocate_statement_line_to_supplier_invoice(...)` creates a confirmed `supplier_invoice` allocation, it must set the source fields on `public.dva_statement_line_allocations` before the row reaches cash posting.

For importer payment statements:

| Statement context | Statement line currency | Allocation source wallet | Allocation source bank mapping |
| --- | --- | --- | --- |
| `importer_dva_card_account` | `GBP` | `virtual_gbp_wallet` | `LOYALTY_VIRTUAL_GBP_BANK_ACCOUNT` |
| `importer_dva_card_account` | anything else | `NULL` | `DVA_CASH_BANK_ACCOUNT` |

This rule reuses the same GBP/virtual-wallet convention already used by the completion-loyalty internal-transfer resolver, but applies it only inside the normal DVA statement supplier-allocation path.

## Current Scope

This addendum intentionally solves the immediate seamless case:

- uploaded/imported importer payment statement is marked as already GBP/sterling,
- statement line is allocated to a supplier invoice,
- cash posting must credit the virtual GBP Sage bank account for that payment leg.

It does not attempt to infer `LOYALTY_DVA_GHS_BANK_ACCOUNT` from all GHS lines, because normal real DVA cash can also be GHS. A future explicit source marker can extend the rule for GHS loyalty-wallet lines without changing the normal supplier-allocation route.

## Required Backend Patch

Patch `public.staff_allocate_statement_line_to_supplier_invoice(uuid, uuid, numeric, text)` so the `INSERT INTO public.dva_statement_line_allocations` includes:

- `source_wallet_code`,
- `source_bank_account_mapping_code`.

The function should derive those values from the locked statement line and its parent `dva_statements.statement_account_context`.

## Cash Posting Requirement

The cash posting workbench must continue to use `dva_statement_line_allocations.source_bank_account_mapping_code` when present.

Existing frozen snapshots are immutable for this purpose. If a row was frozen before source resolution was corrected, it must be recreated or otherwise safely superseded before posting.

## Regression Scenario

Canonical test:

- Supplier invoice ref: `4004238649`
- Total: `GBP 199.99`
- Real DVA cash leg: `GBP 180.00`
- Virtual GBP leg: `GBP 19.99`

Expected cash posting rows:

```text
GBP 180.00  -> DVA_CASH_BANK_ACCOUNT
GBP 19.99   -> LOYALTY_VIRTUAL_GBP_BANK_ACCOUNT
```
