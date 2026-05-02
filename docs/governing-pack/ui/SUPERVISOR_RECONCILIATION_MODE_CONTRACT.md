# Supervisor Reconciliation Mode Contract

## Purpose

Allow admin/supervisor staff to open the same order reconciliation workspace used by the operator, with the same invoice PDF, screenshots, OCR lines, progressed status, and exception state.

## Access

`/importer/reconciliation/[order_id]` must support two modes:

1. Operator mode
   - Active operator user.
   - Must have active `operator_importers` access for the order importer.

2. Supervisor mode
   - Active staff user.
   - `role_type in ('admin','supervisor')`.
   - No `operator_importers` requirement.

All other users are redirected away.

## Evidence visibility

Both modes must show:

- uploaded supplier invoice PDF;
- original order screenshots;
- OCR/manual invoice lines;
- progressed status;
- refund/replacement exception links;
- order baseline qty/value comparison.

## Permissions

Operator mode can:

- progress clean lines;
- create refund/replacement exception cases;
- add manual lines where allowed by existing operator rules.

Supervisor mode can initially:

- review the same evidence and lines;
- open the invoice and screenshots;
- use existing line progression/exception controls only where existing actions permit staff-safe behaviour.

Supervisor accounting controls are a later slice:

- GL/nominal account;
- Sage tax/VAT code;
- description override;
- SKU/size correction;
- net/VAT/gross preview;
- admin flag/audit on edits.

## Hard controls

- Supervisor edits must not make total line value exceed the accepted OCR/operator invoice gross total.
- Any supervisor edit after operator reconciliation must create an admin/audit flag.
- Sage posting must not happen from the reconciliation page.
- Reconciliation prepares the invoice for supplier draft readiness only.

## Routing

Supplier draft ready should link to this workspace for final checks.

The button label should remain simple:

`Open reconciliation`
