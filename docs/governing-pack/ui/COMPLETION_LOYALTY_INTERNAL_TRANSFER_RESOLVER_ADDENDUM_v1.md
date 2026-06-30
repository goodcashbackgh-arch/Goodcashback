# Completion Loyalty Internal Transfer Resolver Addendum v1

Status: locked implementation clarification after reviewing the existing DVA/card statement import, DVA reconciliation, cash posting workbench, completion-loyalty pairing/release, and completion-loyalty Sage posting lifecycle.

This addendum supersedes only the internal-transfer account resolution and MVP in-transit wording in:

- `COMPLETION_LOYALTY_BULK_FUNDING_POT_AND_POSTING_CLARIFICATION_v1.md`
- `COMPLETION_LOYALTY_SAGE_ACCOUNTING_POSTING_ADDENDUM_v1.md`
- `COMPLETION_LOYALTY_SAGE_BATCH_POSTING_ADDENDUM_v1.md`

It does not change the applied-loyalty customer settlement lane already built from `order_funding_events.credit_applied`.

---

## 1. Core decision

For MVP, completion-loyalty internal transfer uses exactly three company-controlled bank/control accounts:

```text
Main GBP bank
DVA GHS wallet, posted in GBP equivalent
Virtual GBP wallet
```

No in-transit clearing account is required for MVP.

The internal-transfer journal is direct:

```text
Dr resolved destination wallet bank/control account
Cr resolved source main bank account
```

Examples:

```text
Dr DVA GHS wallet, GBP equivalent
Cr Main GBP bank
```

```text
Dr Virtual GBP wallet
Cr Main GBP bank
```

The journal must remain VAT-safe:

```text
include_on_tax_return = false
tax_rate_id = null
```

---

## 2. Existing repo paths to reuse

Do not build a separate posting workbench.

Reuse the existing completion-loyalty Sage lifecycle tables and UI path:

```text
completion_loyalty_sage_posting_groups
completion_loyalty_sage_posting_steps
completion_loyalty_sage_posting_batches
completion_loyalty_sage_posting_batch_items
/internal/accounting-command-centre/loyalty-controls
```

Use:

```text
posting_group_type = 'completion_loyalty_internal_transfer_journal'
step_type = 'loyalty_internal_transfer_journal'
```

Do not route completion-loyalty internal transfers through generic cash posting categories such as:

```text
customer_receipt_on_account
supplier_invoice_payment
shipper_invoice_payment
bank_fee
fx_card_difference
```

---

## 3. Statement account resolution

Do not add a new first-class `virtual` DVA reconciliation context.

The existing statement import context remains:

```text
main_company_bank_account
importer_dva_card_account
```

The resolver must use the statement context plus the currency selected before extraction/commit:

| Statement line | Resolver result |
| --- | --- |
| `statement_account_context = 'main_company_bank_account'` | existing mapped main GBP bank account |
| `statement_account_context = 'importer_dva_card_account'` and `local_ccy = 'GBP'` | Virtual GBP wallet |
| `statement_account_context = 'importer_dva_card_account'` and `local_ccy = 'GHS'` | DVA GHS wallet, using `amount_gbp_equivalent` |

For MVP, any unexpected importer DVA/card currency other than `GBP` or `GHS` must block for accounting review rather than guess.

This preserves the existing DVA reconciliation flow. If a virtual GBP statement is uploaded as importer payment account with `Statement already in GBP / sterling` selected, it can still use the existing DVA reconciliation workbench for matching and supplier allocation because the current validations do not require GHS.

---

## 4. Sage ID rule

All posting code must use Sage long IDs stored in mappings or frozen payloads.

Do not use GL/account numbers such as `1200`, `1240`, or `1250` as posting identifiers.

GL/account numbers and display names are UI/audit labels only.

The mapping layer must store and resolve Sage long IDs, for example through existing `sage_mapping_settings.sage_external_id` and frozen posting payload fields such as:

```text
bank_account_id
ledger_account_id
journal_lines[].ledger_account_id
```

The already-mapped main bank must be reused. Do not create a duplicate loyalty-only main-bank mapping unless the existing resolver cannot identify the source main bank long ID.

---

## 5. Minimum mapping impact

Keep existing mappings working.

Add or confirm only the destination wallet mappings needed by the resolver:

```text
VIRTUAL_GBP_BANK_ACCOUNT
DVA_GHS_BANK_ACCOUNT
```

If the existing `DVA_CASH_BANK_ACCOUNT` already points to the DVA GHS wallet long ID, it may remain as the backward-compatible cash posting mapping. The new resolver may either use `DVA_GHS_BANK_ACCOUNT` directly or use a documented alias to the same Sage long ID.

The cash posting workbench must not be broken by this change. Any shared bank resolver must preserve existing behaviour for already-classified cash rows, except that importer DVA/card rows with `local_ccy = 'GBP'` may resolve to the Virtual GBP wallet where the row represents the GBP virtual wallet statement.

---

## 6. Internal-transfer source and amount

The source remains:

```text
main_bank_completion_loyalty_funding_matches
```

Eligible rows must remain:

```text
transfer_pair_status = 'paired_released'
match_status = 'released_available_dashboard_credit'
source OUT statement line exists
destination IN statement line exists
```

The posting group must be grouped by the actual paired statement-line transfer, not by one journal per reward:

```text
source_out_statement_line_id
destination_in_statement_line_id
importer_id
```

The group must show both amounts:

```text
transfer_amount_gbp          actual paired bank movement amount in GBP equivalent
loyalty_released_amount_gbp  sum of released loyalty match amounts
excess_remaining_gbp         transfer amount less released loyalty amount, if any
```

The internal-transfer journal amount must be the actual paired bank movement amount, not merely the loyalty amount consumed by reward releases. This keeps Sage bank/control account balances aligned with the statement movement while still retaining traceability to the loyalty matches funded by that movement.

If the actual paired transfer amount cannot be safely resolved from the source OUT and destination IN statement lines, the row must block for accounting review.

---

## 7. Posting date

For MVP direct journal posting, use the destination IN statement date as the journal date.

Retain the source OUT statement date in the posting group payload and audit display.

The batch/detail UI must show both dates:

```text
source_out_date
destination_in_date
posting_date = destination_in_date
```

No in-transit split is created in MVP.

---

## 8. Activation route

`activation_route` is trace metadata only for this MVP resolver.

Do not use `activation_route` as the primary Sage bank-account resolver.

The destination Sage bank/control account is resolved from the committed destination statement line currency:

```text
GBP -> Virtual GBP wallet
GHS -> DVA GHS wallet
```

---

## 9. Batch and posting integration

The existing completion-loyalty batch layer currently supports applied-loyalty settlement. The additive internal-transfer patch must extend it without changing that lane.

Minimum additive changes:

```text
1. allow batch_type = 'completion_loyalty_internal_transfer_journal';
2. create/approve batches from groups where posting_group_type = 'completion_loyalty_internal_transfer_journal';
3. post only `loyalty_internal_transfer_journal` steps for this batch type;
4. keep the existing applied-loyalty receipt/allocation/clearing sequence unchanged;
5. keep live posting behind `SAGE_LIVE_COMPLETION_LOYALTY_INTERNAL_TRANSFER_POSTING_ENABLED`.
```

The journal payload must use the existing `/journals` primitive and existing request/response/idempotency logging pattern.

---

## 10. No-impact boundary

This addendum must not change:

```text
DVA/card statement extraction
DVA/card reconciliation supplier allocation
main-bank loyalty reservation/release validations
completion-loyalty approval/rejection
customer dashboard available credit
staff apply-loyalty-to-order logic
order_funding_events
applied-loyalty customer settlement materialisation/posting
customer sales invoice posting
supplier/AP posting
shipper/AP posting
VAT return logic
bank fee posting
FX/card residual posting
```

The only approved integration impact is a shared bank-account resolver used by posting/materialisation code so that GBP importer-wallet statement rows resolve to the Virtual GBP wallet and GHS importer-wallet statement rows resolve to the DVA GHS wallet.

---

## 11. Acceptance checks

Before code implementation is accepted, prove:

```text
1. GBP importer DVA/card upload resolves to Virtual GBP wallet.
2. GHS importer DVA/card upload resolves to DVA GHS wallet using amount_gbp_equivalent.
3. main_company_bank_account source resolves to the already-mapped main bank long ID.
4. postings use Sage long IDs, not GL/account numbers.
5. internal-transfer materialisation creates one journal group per paired OUT/IN transfer, not one per reward.
6. journal amount equals the actual paired transfer amount.
7. released loyalty total and excess remaining are visible separately.
8. no in-transit steps are created.
9. applied-loyalty customer settlement still uses the existing receipt/allocation/clearing lane unchanged.
10. existing cash posting rows continue to freeze/batch/post as before.
11. no VAT rows are created or changed.
```
