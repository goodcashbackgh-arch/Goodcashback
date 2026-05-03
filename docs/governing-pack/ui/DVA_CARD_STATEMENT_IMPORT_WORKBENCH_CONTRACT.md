# DVA/Card Statement Import Workbench Contract v1

Status: governing contract for the next DVA/card statement ingestion build stage.

## 1. Correct input requirement

The statement import workbench must be **PDF-first but format-detecting**.

It must support:

- PDF/card/bank statements as the main expected upload route.
- CSV where the bank/provider supplies a structured export.
- XLSX where the bank/provider supplies spreadsheet export.
- Plain text or extracted text as a fallback diagnostic path.

The system must detect the file type and route it to the correct parser.

```text
Upload statement file
→ detect format: PDF / CSV / XLSX / text
→ if PDF: OCR/extract statement rows
→ if CSV/XLSX: parse structured rows directly
→ stage parsed rows
→ dedupe
→ show row-level errors
→ commit clean rows
→ generate match suggestions
→ allocate in DVA/card reconciliation workbench
```

CSV/XLSX import is a useful fast path, but it is not the only route and must not replace PDF statement ingestion.

## 2. Boundary

This contract governs DVA/card/bank statement ingestion before allocation.

It does not replace:

- `staff_reconcile_dva_line_to_order(...)` for order funding.
- `staff_allocate_statement_line_to_supplier_invoice(...)` for supplier invoice allocation.
- `staff_allocate_statement_line_to_fx_card_or_fee(...)` for FX/card/bank-fee residuals.
- Refund/dispute allocation logic, which remains a separate exception-control lane.

The importer/operator must not upload or reconcile DVA/card statements. Staff/supervisor owns this workstream.

## 3. Pattern reused from invoice OCR build

The statement import flow should reuse the control pattern proven by supplier invoice/Mindee work:

```text
staff uploads file
→ metadata captured
→ OCR/parse status lifecycle
→ extracted/staged rows
→ row-level errors and duplicate report
→ supervisor review
→ commit clean rows
→ generate match suggestions
→ allocation workbench
```

Statement ingestion differs from supplier invoice OCR because one source file can contain many rows and mixed transaction types.

## 4. Required upload metadata

Staff must capture:

- importer
- source bank/provider
- statement period from/to
- local currency
- uploaded file URL/path
- file type detected
- upload batch reference
- optional card last 4 / wallet/card identifier
- FX source context, e.g. Bank of Ghana daily rate source
- card markup percentage/default for the upload, editable per row if needed

## 5. Parse status lifecycle

Each import batch must have its own lifecycle. If existing `dva_statements.parse_status` cannot support the full lifecycle without widening constraints, use additive import-batch/staging tables rather than mutating core constraints.

Required lifecycle:

```text
uploaded
→ detecting_format
→ ocr_or_parsing
→ parsed_clean
→ parsed_with_errors
→ committed
→ void_requested
→ voided
→ failed
```

## 6. Row staging before commit

Parsed/extracted rows must land in staging first, not directly into `dva_statement_lines`.

Each staged row should preserve:

- import batch id
- source row/page number
- raw text/raw JSON
- statement date
- transaction/effective date where parsed
- direction candidate: `in` or `out`
- local amount
- balance after, if available
- local currency
- FX rate applied
- card markup percentage applied
- GBP equivalent
- card last 4, if present
- merchant raw
- merchant normalised
- bank reference
- auth/settlement reference
- transaction family reference, if extracted
- parser confidence
- parse status
- error code/message
- duplicate fingerprint hash
- duplicate source line id, if skipped

## 7. PDF statement extraction requirement

PDF extraction must support multi-line transaction descriptions such as:

```text
04-Feb-2026
VISA REFUND SETTL DD 02/02/2026
TRXN DD 22/01/2026
400149******5757 Zara.com
74875306030002200777223
137ERFU26035ABY3
03-Feb-2026
2,342.76
2,511.59
```

The parser should preserve the raw block and extract structured fields where possible:

```text
card_last4 = 5757
merchant_raw = Zara.com
merchant_normalised = zara
bank_reference = 74875306030002200777223
auth_or_settlement_ref = 137ERFU26035ABY3
statement_date = 2026-02-04
transaction_date/effective_date = 2026-02-03 or parsed source date
transaction_type_candidate = retailer_refund_candidate
```

Merchant normalisation examples:

```text
SharkNinja Leeds GB → sharkninja / ninja
asos.com London GB → asos
Zara.com → zara
```

The parser must not decide final accounting treatment. It only prepares structured data for staff review, dedupe and matching.

## 8. Direction and transaction classification

Initial parser classes:

- supplier_purchase_candidate
- retailer_refund_candidate
- inbound_funding_candidate
- bank_fee_candidate
- transfer_candidate
- unmatched_candidate

Direction mapping:

- card purchases to retailers: `out`
- retailer/card refunds: usually `in`
- importer funding/top-ups: `in`
- bank/MOMO/card fees: usually `out`
- internal transfers: classify but do not auto-match to supplier invoice

## 9. FX conversion

For non-GBP local currency rows, GBP equivalent must be calculated before matching.

Daily FX is preferred over monthly FX because African currencies can be volatile.

The calculation must store:

- local amount
- local currency
- FX rate date
- rate source country/provider
- quote/settlement rate used
- card markup percentage used
- calculated GBP amount

Rows must show errors when FX rate, date, currency, or amount cannot be derived.

## 10. Deduplication

Overlapping statement uploads are expected. Duplicate protection is mandatory before commit.

Each staged row must have a deterministic fingerprint hash from fields such as:

```text
importer_id
source_bank/provider
statement_date
transaction/effective_date
direction
amount_local_ccy
balance_after
local_ccy
card_last4
merchant_normalised
bank_reference
auth_or_settlement_ref
```

Duplicate rows must be skipped from active insertion but retained in import history with duplicate reason/source where possible.

## 11. Commit rules

Only valid non-duplicate staged rows may be committed into active `dva_statement_lines`.

Rows with parse errors, missing FX, invalid dates, invalid amounts, or duplicate status must not be inserted into active statement lines.

## 12. Rollback / void import

Rollback/void must not delete history.

Void rules:

- If committed lines have no allocations, the import may be voided and removed from active views using an additive mechanism.
- If any committed line has confirmed allocations, void must be blocked until those allocations are reversed.
- Voided imports remain visible with who/when/why.

## 13. Row-level error report

The UI must show:

- parsed successfully
- duplicate skipped
- missing date
- invalid amount
- unknown direction
- missing FX rate
- merchant not parsed
- unsupported currency
- committed
- voided

## 14. Matching after commit

After clean rows are committed, suggestion generation may run.

Supplier-purchase suggestions should use:

- same importer
- direction `out`
- merchant normalised / retailer alias match
- GBP amount close to approved supplier invoice total
- transaction date close to invoice/OCR/upload date
- invoice `approved_current`
- invoice not blocked
- invoice not already fully allocated

Refund suggestions should use:

- direction `in`
- refund/card wording
- merchant normalised / retailer alias match
- amount close to dispute/refund outcome
- date after original charge
- transaction family/card references where available

Funding suggestions route to funding queue. Bank fee suggestions route to bank-fee allocation.

## 15. UI requirements

Staff UI must include:

- upload form
- upload history
- detected file type
- parse/OCR status badge
- row count summary
- clean/error/duplicate counts
- row-level error table
- commit clean rows action
- void import action
- link to DVA/card reconciliation workbench after commit

Mobile must use card-style rows, not wide tables only.

## 16. Sage boundary

Statement ingestion does not post to Sage.

Sage payload readiness comes later, after committed statement lines are allocated and residual FX/card/bank-fee/refund/exception outcomes are classified.