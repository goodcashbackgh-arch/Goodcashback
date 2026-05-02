# Supplier Line Accounting Coding Contract

## Purpose

Supervisor/admin codes reconciled supplier invoice lines before supplier AP draft preparation.

This is AutoEntry-style review: the OCR/reconciled gross amount is locked, while accounting treatment is selected and checked before Sage posting.

## Page

`/internal/reconciliation/[order_id]`

## Line fields

For each progressed supplier invoice line, staff can set:

- description override;
- SKU override;
- size override;
- GL / nominal account;
- Sage ledger account id;
- Sage tax rate id / tax code;
- VAT rate label;
- VAT rate percent;
- net amount GBP;
- VAT amount GBP;
- gross amount GBP.

## Hard controls

- Gross amount must equal the already-approved OCR/reconciled gross line amount.
- Net + VAT must equal gross.
- The sum of coded gross lines must continue to match the accepted invoice gross total.
- Coding does not post to Sage.
- Coding prepares data for the later supplier AP draft / Sage posting queue.

## Audit controls

A supervisor/admin coding save must record:

- staff id;
- timestamp;
- whether admin review is required;
- review reason.

Admin review should be required when staff changes source line description, SKU, size, or other treatment after operator reconciliation.

## Separation

Operator reconciliation decides whether goods are invoiceable or exception-linked.

Supervisor accounting coding decides how accepted supplier invoice lines will post to accounts/Sage.
