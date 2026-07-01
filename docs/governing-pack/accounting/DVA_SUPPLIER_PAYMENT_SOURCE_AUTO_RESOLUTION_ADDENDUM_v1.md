# DVA Supplier Payment Source Auto-Resolution Addendum v1

## Parent Contract

This addendum extends `docs/governing-pack/accounting/DVA_SUPPLIER_PAYMENT_SOURCE_SPLIT_CONTRACT_v1.md`.

Related contracts / implementation references:

- `docs/governing-pack/accounting/DVA_SUPPLIER_PAYMENT_SOURCE_SPLIT_CONTRACT_v1.md`
- `docs/governing-pack/backend/staff_dva_statement_allocation_wrappers_v2.sql`
- `supabase/migrations/20260701_dva_supplier_payment_explicit_source_selector_v1.sql`
- `supabase/migrations/20260701_dva_supplier_payment_source_auto_resolution_v1.sql`
- `supabase/migrations/20260701_dva_supplier_payment_source_bank_split_v1.sql`
- `supabase/migrations/20260630_completion_loyalty_internal_transfer_resolver_nullsafe_v1.sql`
- `supabase/migrations/20260630_completion_loyalty_internal_transfer_journal_lane_v1.sql`

## Decision

Supplier invoice payment source bank selection must remain inside the normal DVA statement allocation route.

Do not add or revive a separate supplier-wallet workbench, page, or cash posting route.

The source is selected once when the statement upload batch is created. Supplier allocation then inherits that source automatically, and cash posting uses the source stored on the confirmed `dva_statement_line_allocations` row.

## Explicit Source Selector

For importer payment statement uploads, staff must classify the statement source as one of:

| Upload source | Wallet code stored | Bank mapping code stored | Required Sage bank account id |
| --- | --- | --- | --- |
| Real DVA cash | `dva_cash` | `DVA_CASH_BANK_ACCOUNT` | `1d21e52bed0a4fedb1b1dc21044b7d07` |
| Loyalty DVA GHS wallet | `dva_ghs_wallet` | `LOYALTY_DVA_GHS_BANK_ACCOUNT` | `c7e2c4be463b4b41a9eca5ad39a06c18` |
| Loyalty virtual GBP wallet | `virtual_gbp_wallet` | `LOYALTY_VIRTUAL_GBP_BANK_ACCOUNT` | `1cf4a2cb34fe4775986ba7c5e0ead260` |

`DVA_CASH_BANK_ACCOUNT` is the default only for real DVA cash. It must not be used for loyalty DVA/GHS or loyalty virtual GBP supplier-payment legs.

## Source Resolution Rule

The source classification is carried through this chain:

1. `public.dva_statement_import_batches`
   - stores `statement_source_wallet_code` and `statement_source_bank_account_mapping_code` from the upload selection.

2. `public.dva_statements`
   - receives the same source fields when `staff_commit_dva_statement_import_batch(...)` creates the committed statement.

3. `public.dva_statement_line_import_links`
   - receives the same source fields for traceability from staged/imported rows to committed lines.

4. `staff_allocate_statement_line_to_supplier_invoice(...)`
   - reads the committed statement source fields for the selected statement line.
   - writes `source_wallet_code` and `source_bank_account_mapping_code` onto the confirmed `supplier_invoice` allocation row.

5. `internal_cash_posting_workbench_rows_v1(...)`
   - reads `dva_statement_line_allocations.source_bank_account_mapping_code` in its supplier `allocation_rows` branch.
   - resolves the Sage bank account from `sage_mapping_settings`.

Fallback behavior exists only for older committed statements that have no source metadata:

| Legacy context | Legacy line currency | Fallback source |
| --- | --- | --- |
| `importer_dva_card_account` | `GBP` | `virtual_gbp_wallet` / `LOYALTY_VIRTUAL_GBP_BANK_ACCOUNT` |
| `importer_dva_card_account` | anything else | `dva_cash` / `DVA_CASH_BANK_ACCOUNT` |

The legacy fallback is not the desired long-term source of truth. New uploads must use the explicit source selector.

## Impact Surface

This patch impacts the normal DVA statement allocation path only:

1. Upload page/action
   - `app/internal/dva-statement-import/page.tsx` exposes the statement source selector.
   - `app/internal/dva-statement-import/actions.ts` passes `p_statement_source_wallet_code` to the batch-create RPCs.

2. Import batch and committed statement metadata
   - `dva_statement_import_batches` stores selected source metadata.
   - `dva_statements` stores selected source metadata after commit.
   - `dva_statement_line_import_links` stores selected source metadata for audit trace.

3. Supplier allocation RPC
   - `staff_allocate_statement_line_to_supplier_invoice(...)` stamps source mapping onto `dva_statement_line_allocations`.

4. Cash posting workbench union
   - `customer_receipts` branch is unchanged.
   - `final_balance_receipts` branch is unchanged.
   - `allocation_rows` is the affected branch, because supplier invoice payment rows come from confirmed statement-line allocations.

5. Cash freeze / batch / Sage posting
   - unchanged code path.
   - receives the corrected `sage_bank_account_id` from the workbench row.

No browser write to allocation source fields is required during supplier matching. The selected upload source is the upstream source of truth.

## Cash Posting Requirement

The cash posting workbench must continue to use `dva_statement_line_allocations.source_bank_account_mapping_code` when present.

Existing frozen snapshots are immutable for this purpose. If a row was frozen before source resolution was corrected, it must be recreated or superseded before posting.

## Regression Scenario

Canonical test:

- Supplier invoice ref: `4004238649`
- Total: `GBP 199.99`
- Real DVA cash leg: `GBP 180.00`
- Virtual GBP leg: `GBP 19.99`

Expected cash posting rows:

```text
GBP 180.00  -> DVA_CASH_BANK_ACCOUNT -> 1d21e52bed0a4fedb1b1dc21044b7d07
GBP 19.99   -> LOYALTY_VIRTUAL_GBP_BANK_ACCOUNT -> 1cf4a2cb34fe4775986ba7c5e0ead260
```

If the second leg is loyalty DVA/GHS instead of virtual GBP, expected cash posting is:

```text
GBP 19.99   -> LOYALTY_DVA_GHS_BANK_ACCOUNT -> c7e2c4be463b4b41a9eca5ad39a06c18
```
