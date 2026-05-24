# Posting to Closure Build Gate Addendum v1

## Status

This addendum links the current command-centre, Sage posting and cash posting contracts to `ACCOUNTING_CLOSURE_CONTROL_CONTRACT_v1.md`.

It applies to:

- `COMMAND_CENTRES_AND_SAGE_CLOUD_ACCOUNTING_CONTRACT_v5.md`
- `CASH_POSTING_WORKBENCH_CONTRACT_v1.md`
- `CASH_POSTING_WORKBENCH_CONTRACT_v2_ADDENDUM.md`
- `ACCOUNTING_CLOSURE_CONTROL_CONTRACT_v1.md`

## Binding rule

The next build phase is accounting closure control.

The required sequence is:

1. Posting routes built or proven.
2. Read-only accounting closure proof pack.
3. Full-order closure proof.
4. Later endpoint or allocation expansion.

## Gate

Until the closure proof pack is built and tested on at least one real full order lifecycle, do not expand live posting into additional refund, residual, fee, hold, allocation or manual AP edge-case routes.

Those areas may remain visible as read-only or blocked diagnostic rows.

## Reason

The platform now has multiple posting paths for invoices, credit notes, receipts and payments. The immediate risk is no longer endpoint breadth. The immediate risk is posting without one closure view that proves platform source truth, frozen snapshot truth, Sage request and response truth, Sage object ids, allocation or settlement state, attachment state, idempotency, duplicates and outstanding items.

## Priority

For the next build phase, this addendum and `ACCOUNTING_CLOSURE_CONTROL_CONTRACT_v1.md` take priority over any older wording that could be read as permission to continue endpoint expansion before closure control.

This does not change the two-cockpit model. Closure control remains inside the Accounting Command Centre as an audit, diagnostic and closure section.

## Immediate next build

Build the read-only Accounting Command Centre closure section first.
