# DVA Supplier Payment Source Auto-Resolution Addendum v1

## Parent Contract

This addendum extends `docs/governing-pack/accounting/DVA_SUPPLIER_PAYMENT_SOURCE_SPLIT_CONTRACT_v1.md`.

Related contracts / implementation references:

- `docs/governing-pack/accounting/DVA_SUPPLIER_PAYMENT_SOURCE_SPLIT_CONTRACT_v1.md`
- `docs/governing-pack/backend/staff_dva_statement_allocation_wrappers_v2.sql`
- `supabase/migrations/20260701_dva_supplier_payment_source_auto_resolution_v1.sql`
- `supabase/migrations/20260701_dva_supplier_payment_source_bank_split_v1.sql`
- `supabase/migrations/20260630_completion_loyalty_internal_transfer_resolver_nullsafe_v1.sql`
- `supabase/migrations/20260630_completion_loyalty_internal_transfer_journal_lane_v1.sql`

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

Implementation migration:

- `supabase/migrations/20260701_dva_supplier_payment_source_auto_resolution_v1.sql`

## Impact Surface

This patch impacts the normal DVA statement allocation path only:

1. `staff_allocate_statement_line_to_supplier_invoice(...)`
   - writes the source mapping onto the allocation row at creation time.

2. `public.dva_statement_line_allocations`
   - stores `source_wallet_code` and `source_bank_account_mapping_code` for supplier invoice allocations.

3. `internal_cash_posting_workbench_rows_v1(...)`
   - already reads `dva_statement_line_allocations.source_bank_account_mapping_code` in its `allocation_rows` CTE.
   - keeps using `DVA_CASH_BANK_ACCOUNT` only when the allocation source mapping is blank/default.

4. Cash posting row union
   - `customer_receipts` stays unchanged.
   - `final_balance_receipts` stays unchanged.
   - `allocation_rows` is the only union branch affected because supplier invoice payment rows come from confirmed statement-line allocations.

5. Cash freeze / batch / Sage posting
   - unchanged code path.
   - receives the corrected `sage_bank_account_id` from the workbench row.

No UI page, route, table write from the browser, or separate completion-loyalty supplier-wallet path is required.

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