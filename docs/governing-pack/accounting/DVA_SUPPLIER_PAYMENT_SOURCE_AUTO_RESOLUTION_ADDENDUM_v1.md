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
- `supabase/migrations/20260702_dva_supplier_payment_released_loyalty_source_resolution_v1.sql`

## Decision

Supplier invoice payment source bank selection must be automatic inside the existing DVA reconciliation supplier-allocation route.

Do not add a separate supplier-wallet workbench, page, or cash posting route.

Do not infer loyalty/virtual source from statement currency alone. `importer_dva_card_account + GBP` is not enough proof that a supplier payment leg is virtual GBP.

## Source Resolution Rule

When `staff_allocate_statement_line_to_supplier_invoice(...)` creates a confirmed `supplier_invoice` allocation, it must set the source fields on `public.dva_statement_line_allocations` before the row reaches cash posting.

The resolver must use order funding provenance:

```text
supplier invoice
-> order
-> credit_applied order_funding_events
-> applied importer_credit_ledger debit
-> source completion-loyalty credit ledger
-> main_bank_completion_loyalty_funding_matches
-> paired released destination_in_statement_line_id
-> internal_completion_loyalty_statement_ledger_resolver_v1(...)
```

For exact remaining released completion-loyalty funding:

| Resolved destination wallet | Allocation source wallet | Allocation source bank mapping |
| --- | --- | --- |
| `virtual_gbp_wallet` | `virtual_gbp_wallet` | `LOYALTY_VIRTUAL_GBP_BANK_ACCOUNT` |
| `dva_ghs_wallet` | `dva_ghs_wallet` | `LOYALTY_DVA_GHS_BANK_ACCOUNT` |

For non-loyalty/customer cash funding:

| Condition | Allocation source wallet | Allocation source bank mapping |
| --- | --- | --- |
| Cash funding covers the allocation amount, or no released loyalty source is proven | `NULL` | `DVA_CASH_BANK_ACCOUNT` |

If released loyalty exists but the allocation cannot be cleanly matched to an exact remaining loyalty source and cash funding cannot cover it, the RPC must block with:

```text
source_funding_required_for_supplier_payment_bank_resolution
```

If more than one released loyalty source can exactly match the allocation, the RPC must block with:

```text
source_funding_ambiguous_for_supplier_payment_bank_resolution
```

## Required Backend Patch

Patch `public.staff_allocate_statement_line_to_supplier_invoice(uuid, uuid, numeric, text)` so the `INSERT INTO public.dva_statement_line_allocations` includes:

- `source_wallet_code`,
- `source_bank_account_mapping_code`.

The function must derive those values from released completion-loyalty provenance where present, not from statement currency alone.

Implementation migration:

- `supabase/migrations/20260702_dva_supplier_payment_released_loyalty_source_resolution_v1.sql`

## Impact Surface

This patch impacts the normal DVA statement allocation path only:

1. `staff_allocate_statement_line_to_supplier_invoice(...)`
   - writes the source mapping onto the allocation row at creation time.
   - replaces the retired GBP shortcut with released-loyalty provenance resolution.

2. `public.dva_statement_line_allocations`
   - stores `source_wallet_code` and `source_bank_account_mapping_code` for supplier invoice allocations.

3. `main_bank_completion_loyalty_funding_matches`
   - read-only provenance source for released/pair-confirmed completion-loyalty funding.
   - no writes from this patch.

4. `internal_completion_loyalty_statement_ledger_resolver_v1(...)`
   - read-only resolver used to classify the paired destination IN as `virtual_gbp_wallet` or `dva_ghs_wallet`.
   - no change to the internal-transfer journal lane.

5. `internal_cash_posting_workbench_rows_v1(...)`
   - already reads `dva_statement_line_allocations.source_bank_account_mapping_code` in its `allocation_rows` CTE.
   - keeps using `DVA_CASH_BANK_ACCOUNT` only when the allocation source mapping is blank/default.

6. Cash posting row union branches
   - `customer_receipts` unchanged.
   - `final_balance_receipts` unchanged.
   - `allocation_rows` is the only union branch affected because supplier invoice payment rows come from confirmed statement-line allocations.

7. Cash freeze / batch / Sage posting
   - unchanged code path.
   - receives the corrected `sage_bank_account_id` from the workbench row.

No upload UI change, DVA reconciliation page change, browser-supplied source selector, or separate completion-loyalty supplier-wallet path is required.

## Cash Posting Requirement

The cash posting workbench must continue to use `dva_statement_line_allocations.source_bank_account_mapping_code` when present.

The migration must not hard-code Sage bank ids. Sage external ids remain governed by `sage_mapping_settings`. If a required mapping code has no active Sage external id, cash posting must block rather than silently use `DVA_CASH_BANK_ACCOUNT`.

Existing frozen snapshots are immutable for this purpose. If a row was frozen before source resolution was corrected, it must be recreated or safely superseded before posting.

## Regression Scenario

Canonical test:

- Supplier invoice ref: `4004238649`
- Total: `GBP 199.99`
- Real DVA cash leg: `GBP 180.00`
- Released virtual GBP completion-loyalty leg: `GBP 19.99`

Expected cash posting rows:

```text
GBP 180.00  -> DVA_CASH_BANK_ACCOUNT
GBP 19.99   -> LOYALTY_VIRTUAL_GBP_BANK_ACCOUNT
```

Alternative released DVA GHS case:

```text
GBP 19.99   -> LOYALTY_DVA_GHS_BANK_ACCOUNT
```

Invalid behaviour:

```text
GBP 19.99 GBP importer statement -> LOYALTY_VIRTUAL_GBP_BANK_ACCOUNT without released-loyalty provenance
```