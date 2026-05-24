# Accounting Closure Control Contract v1

## Status

This contract locks the next build phase after the core Sage invoice, credit note and cash posting routes have been built or proven.

After invoice/cash/credit posting routes are built, `ACCOUNTING_CLOSURE_CONTROL_CONTRACT_v1.md` governs the next build phase before further endpoint expansion.

It supplements:

- `COMMAND_CENTRES_AND_SAGE_CLOUD_ACCOUNTING_CONTRACT_v5.md`
- `CASH_POSTING_WORKBENCH_CONTRACT_v1.md`
- `CASH_POSTING_WORKBENCH_CONTRACT_v2_ADDENDUM.md`

It does not replace the two-cockpit model.

The purpose is to prevent drift into more endpoint expansion before the platform can prove that posted accounting facts close cleanly between platform state, Sage object ids, Sage references, allocation status, evidence, and outstanding balances.

## Core rule

Posted is not closed.

A row can be posted but still not closed if it is:

- posted but unallocated;
- posted but outstanding in Sage;
- posted but missing the expected Sage object id/reference;
- posted but missing optional or mandatory attachment status;
- posted in Sage but not reflected back to the platform source row;
- posted with duplicate/idempotency risk;
- posted but needs review because Sage response did not expose the expected artefact id;
- posted but its related cash, credit note, refund, FX/card residual or fee treatment is incomplete.

The next build priority is therefore accounting closure control, not additional posting endpoints.

## Scope

Accounting closure control lives inside the Accounting Command Centre as an audit/diagnostic/closure section.

It must not become a third daily command centre.

It must not own operational exception resolution, shipper receipt approval, invoice OCR correction, DVA investigation, or retailer/customer chasing.

It consumes the platform source-of-truth records and the Sage posting/cash posting audit trail to answer one question:

```text
Does platform truth equal Sage execution truth, and is anything still outstanding, duplicated, unallocated, blocked or stale?
```

## Closure lanes

Closure control must cover, at minimum:

1. `customer_sales`
   - platform sales invoice / customer invoice source
   - Sage sales invoice object id/reference
   - customer receipt/payment-on-account state where relevant
   - later allocation state to customer sales invoice where relevant

2. `supplier_goods_ap`
   - supplier/retailer AP source invoice
   - Sage purchase invoice object id/reference
   - supplier/retailer payment state
   - attachment state
   - outstanding/unpaid state where known

3. `shipper_ap`
   - shipper/logistics AP source document
   - Sage purchase invoice object id/reference
   - shipper payment state
   - attachment state
   - outstanding/unpaid state where known

4. `supplier_credit_note`
   - supplier credit/refund evidence submission
   - Sage purchase credit note object id/reference
   - source PDF attachment state
   - allocation/settlement state against the intended supplier AP position
   - outstanding/unpaid state where known

5. `customer_receipt_on_account`
   - DVA/card/bank funding receipt source
   - Sage contact payment id
   - Sage payment-on-account artefact id where extractable
   - later allocation state to the final Sage sales invoice

6. `supplier_invoice_payment` and `shipper_invoice_payment`
   - confirmed DVA/card/main-bank allocation row
   - Sage contact payment id
   - allocated artefact target id
   - allocation status back to the posted Sage purchase invoice
   - grouped payment context where multiple allocation rows are posted as one Sage payment

## Required closure states

Every closure row should resolve to one simple state:

- `not_reached`
- `ready_for_posting`
- `posted_not_closed`
- `posted_closed`
- `posted_needs_review`
- `blocked`
- `failed`
- `duplicate_risk`
- `correction_required`

Definitions:

### `posted_not_closed`

Use when the Sage object exists, but required downstream allocation, settlement, attachment or source-row update is not complete.

### `posted_closed`

Use only when the platform can prove the posting and required downstream closure facts are complete for that lane.

### `posted_needs_review`

Use when Sage accepted the posting but the response did not expose a required artefact id, the platform could not derive a settlement id, or the closure state cannot be proven automatically.

### `duplicate_risk`

Use when more than one active platform row or Sage object appears to represent the same intended accounting fact, or when idempotency keys/object refs collide.

### `correction_required`

Use when a posted immutable snapshot needs a correction route, credit note, reversal, or controlled compensating entry. Do not edit the original posted payload.

## Minimum closure grid columns

The Accounting Command Centre closure grid must expose:

- order ref / booking ref
- closure lane
- platform source table
- platform source id
- source document/reference
- source amount
- source approval/current state
- Sage object type
- Sage object id
- Sage reference
- posted at
- posting batch id/ref
- posting row id
- cash/credit allocation status
- Sage target artefact id where applicable
- attachment state where applicable
- outstanding amount if known
- idempotency key
- duplicate warning
- blocker
- next action

The grid must stay readable. Full payloads belong in a drill-down trace, not the main grid.

## Posting trace drill-down

Each closure row must provide a trace showing:

- source platform record
- frozen snapshot
- batch row
- request payload hash
- Sage API request log
- Sage API response log
- Sage object id/reference returned
- platform source update result
- attachment request/response where applicable
- cash allocation / contact payment state where applicable
- outstanding or unresolved state where known
- blocker explanation

## Build freeze rule before endpoint expansion

Until closure control is built and tested on at least one full order lifecycle, do not build or enable new live bulk posting for:

- retailer refund IN;
- customer refund OUT;
- FX/card residual posting;
- bank/provider fee posting;
- unmatched/hold posting;
- customer payment-on-account allocation to final sales invoice;
- manual supplier AP no-formal-invoice expansion.

These lanes may remain visible as blocked/read-only diagnostic rows, but must not be turned into live posting routes before closure control is proven.

## Full-order proof requirement

Before endpoint expansion resumes, prove one full order lifecycle through the closure grid:

1. Customer sales invoice posted to Sage.
2. Supplier goods AP posted to Sage where applicable.
3. Shipper AP posted to Sage where applicable.
4. Supplier credit note posted to Sage where applicable.
5. Customer receipt posted to Sage as contact payment/payment-on-account where applicable.
6. Supplier/shipper payment posted via `contact_payments` with `VENDOR_PAYMENT` and `allocated_artefacts[]` where applicable.
7. Attachments recorded or explicitly marked failed/optional.
8. No duplicate idempotency keys or duplicate active posting facts.
9. No row marked posted without a Sage object id unless explicitly `posted_needs_review`.
10. No FX/card residual, fee, refund or hold hidden inside a customer/supplier/shipper payment.
11. Closure state is explainable from platform records and Sage posting logs.

## Source-of-truth rule

The platform remains the source of operational and accounting-control truth.

Sage is the execution target and external accounting ledger.

Closure control reconciles platform state to Sage execution state. It must not let Sage screen status alone override the platform source facts without storing the supporting Sage object ids, response payloads, references and closure evidence.

## Implementation discipline

Before coding closure control:

1. Check this contract.
2. Check `COMMAND_CENTRES_AND_SAGE_CLOUD_ACCOUNTING_CONTRACT_v5.md`.
3. Check `CASH_POSTING_WORKBENCH_CONTRACT_v2_ADDENDUM.md`.
4. Inspect live DB tables, views, functions, constraints and RLS before writing SQL.
5. Inspect current repo routes/actions/adapters.
6. Prefer additive views/RPCs and diagnostic pages.
7. Do not rename/drop/widen existing schema casually.
8. Do not delete existing posting or cash flows.
9. Confirm Vercel deployment is READY before testing.
10. Test against real posted batches/Sage object ids, not theoretical rows.

## Immediate next build

Build an Accounting Command Centre closure/audit section that reads existing posting and cash posting facts and shows whether each lane is posted, closed, blocked, failed, duplicate-risk or needs review.

This must be read-only first.
