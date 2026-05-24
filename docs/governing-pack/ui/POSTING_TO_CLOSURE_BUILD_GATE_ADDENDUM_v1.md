# Posting to Closure Build Gate Addendum v1

## Status

This addendum links the current command-centre, Sage posting and cash posting contracts to `ACCOUNTING_CLOSURE_CONTROL_CONTRACT_v1.md`.

After invoice/cash/credit posting routes are built, `ACCOUNTING_CLOSURE_CONTROL_CONTRACT_v1.md` governs the next build phase before further endpoint expansion.

It applies to:

- `COMMAND_CENTRES_AND_SAGE_CLOUD_ACCOUNTING_CONTRACT_v5.md`
- `CASH_POSTING_WORKBENCH_CONTRACT_v1.md`
- `CASH_POSTING_WORKBENCH_CONTRACT_v2_ADDENDUM.md`
- `ACCOUNTING_CLOSURE_CONTROL_CONTRACT_v1.md`

## Binding rule

The next build phase is accounting closure control.

The sequence is:

1. Posting routes built or proven.
2. Read-only accounting closure proof pack.
3. Full-order closure proof.
4. Later endpoint or allocation expansion.

## Gate

Until the closure proof pack is built and tested on at least one real full order lifecycle, additional live posting expansion must stay paused.

Those areas may remain visible as read-only or blocked diagnostic rows.

## Priority

For the next build phase, this addendum and `ACCOUNTING_CLOSURE_CONTROL_CONTRACT_v1.md` take priority over any older wording that could be read as permission to continue endpoint expansion before closure control.

This does not change the two-cockpit model. Closure control remains inside the Accounting Command Centre as an audit, diagnostic and closure section.

## Immediate next build

Build the read-only Accounting Command Centre closure section first.
