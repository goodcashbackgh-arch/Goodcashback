# Cash Posting Workbench Contract v1

## Status

This contract formalises the Accounting Command Centre cash posting model for DVA/card/bank statement IN and OUT movements.

It supplements `COMMAND_CENTRES_AND_SAGE_CLOUD_ACCOUNTING_CONTRACT_v5.md`.

Version 5 says later cash, payment, credit and allocation flows come only after invoice posting is proven. Invoice posting is now being proven lane-by-lane, so this contract defines the next controlled layer: posting reconciled cash movements from the platform to Sage Cloud Accounting v3.1.

This contract does not replace the existing DVA reconciliation workbench, supplier invoice reconciliation, shipper AP workflow, supplier credit note flow, or Sage invoice posting batch model.

## Core principle

Cash posting must follow the platform match already confirmed upstream.

The Accounting Command Centre must not decide the retailer, shipper, importer, order, invoice, refund or exception by re-reading bank statement text at posting time.

The chain is:

```text
statement line
-> confirmed platform reconciliation/allocation
-> matched platform target
-> posted Sage target where required
-> cash posting snapshot
-> Sage cash/payment endpoint
```

## Non-negotiable rules

- Cash posting controls live only in the Accounting Command Centre.
- Operational reconciliation remains upstream in the DVA/card statement workbench, supplier invoice reconciliation, shipper AP controls, and exception/refund workflows.
- Do not post directly from raw statement lines.
- Do not infer the retailer/shipper/customer from raw statement text at cash posting stage.
- Do not post customer/importer IN money as revenue.
- Do not create or assume a deposit/prepayment sales invoice shell unless a separate accounting decision explicitly requires it.
- Customer/importer IN money is posted to Sage as a customer receipt/payment-on-account first.
- Final customer sales invoice allocation is a later allocation step after the real sales invoice exists.
- Supplier/retailer OUT payments must follow a confirmed allocation to a supplier invoice and a posted Sage purchase invoice.
- Shipper OUT payments must follow a confirmed match to a shipper AP document and a posted Sage purchase invoice.
- Retailer refund IN must not be live-posted in bulk until the exact Sage supplier-refund / purchase-credit-note allocation route is proven with a controlled test.
- FX/card differences, bank fees, and unmatched holds must not be hidden inside supplier/customer payments.
- Bulk actions must operate on selected rows only or on "select all visible" under the active filters. They must not silently include hidden rows.
- Frozen cash snapshots are immutable. Edits are allowed only before freeze.
- Posted rows must never be posted again except through an approved correction/reversal route.

## Primary route

```text
/internal/accounting-command-centre/cash-posting
```

This is one workbench, not multiple daily command centres.

## Workbench tabs

Minimum tabs:

1. All
2. IN — Customer/importer receipts
3. OUT — Supplier/retailer payments
4. OUT — Shipper payments
5. IN — Retailer refunds
6. Residuals — FX/card differences, bank fees, unmatched/holds
7. Posted / Failed / Blocked

Later optional tab:

8. Allocations — apply customer payment-on-account to final sales invoices

## Main grid contract

The main grid must stay simple because detailed matching already happened upstream.

Minimum visible columns:

- select checkbox
- direction: IN or OUT
- category
- statement date
- customer / retailer / shipper
- order ref
- auth/ref
- statement amount local currency
- GBP amount
- matched target
- posting status
- blocker
- details action

The grid must not display full payload JSON by default.

Example supplier payment row:

```text
[ ] | OUT | Supplier payment | 22/05/26 | Ninja | ORD-123 | AUTH-8891 | GHS 2,450 | £161.99 | Invoice 4004164248 | Ready | View
```

Example customer receipt row:

```text
[ ] | IN | Customer receipt | 22/05/26 | Importer A | ORD-123 | MOMO-7781 | GHS 3,000 | £199.99 | Payment on account | Ready | View
```

## Detail drawer / Posting Trace

Each row must have a detail drawer called `Posting Trace`.

The drawer shows the full audit pack:

### Statement line

- statement id
- statement batch/ref
- statement line id
- date
- direction
- raw description
- auth/ref
- local currency amount
- GBP amount
- FX rate / card markup context

### Match source

- DVA reconciliation id or statement allocation id
- allocation type
- allocation status
- matched by staff id/name where available
- matched/confirmed timestamp
- order id
- order ref
- supplier invoice id where applicable
- shipping document id where applicable
- dispute id where applicable

### Sage target

- posting category
- Sage contact id
- Sage contact display name
- Sage bank account id
- target Sage invoice / credit note / payment-on-account artefact where applicable
- amount to post
- short Sage reference
- idempotency key

### Payload preview

- frozen request payload after freeze
- validation result
- blocker reason
- response payload after post
- Sage object id after post

## Filters and bulk controls

Filters:

- direction: IN / OUT
- category
- customer/importer
- retailer/supplier
- shipper
- order ref
- auth/ref
- statement date range
- statement batch
- amount range
- posting status
- blocker status

Bulk controls:

- Select all visible
- Unselect all
- Freeze selected
- Validate selected
- Post selected
- Retry failed selected

`Select all visible` means all rows under the currently applied filters. It must not include hidden rows.

## Official cash posting categories

### 1. `customer_receipt_on_account`

Purpose:

Customer/importer IN money received into the DVA/card/bank account before the final customer sales invoice exists.

Source truth:

- `dva_reconciliation`
- `order_funding_events`
- `dva_statement_lines`
- `orders`

Required upstream state:

- DVA statement line direction is IN.
- Line has been reconciled to an original order/importer funding event.
- Importer/customer Sage contact mapping exists.
- Sage bank account mapping exists.
- Line has not already been cash-posted.

Sage endpoint:

```text
POST /contact_payments
```

Sage transaction type:

```text
CUSTOMER_RECEIPT
```

Sage result to store:

- contact payment id
- payment-on-account artefact id
- bank account id
- response payload

Accounting meaning:

```text
Dr Bank
Cr Customer/payment-on-account
```

This is not revenue and not a final sales invoice allocation.

### 2. `customer_payment_on_account_allocation`

Purpose:

Later allocation of existing customer payment-on-account to a posted final customer sales invoice.

Source truth:

- posted customer sales invoice snapshot / Sage sales invoice id
- existing `customer_receipt_on_account` Sage payment-on-account id

Sage endpoint:

```text
POST /contact_allocations
```

Artefact pattern:

```text
+ final Sage sales invoice artefact
- Sage payment-on-account artefact
```

This is a later step and must not be mixed into initial customer receipt posting.

### 3. `supplier_invoice_payment`

Purpose:

Payment OUT to retailer/supplier for goods already posted as supplier goods AP.

Source truth:

- `dva_statement_line_allocations`
- allocation type `supplier_invoice`
- `supplier_invoices`
- posted Sage supplier goods AP purchase invoice id

Required upstream state:

- DVA/card statement line direction is OUT.
- Allocation is confirmed.
- Allocation targets `supplier_invoice_id`.
- Supplier invoice has posted Sage purchase invoice id.
- Retailer/supplier Sage contact mapping exists or is inherited from the posted purchase invoice snapshot.
- Sage bank account mapping exists.
- Allocation has not already been cash-posted.

Sage endpoints:

```text
POST /purchase_payments
POST /allocations
```

Accounting meaning:

```text
Dr Supplier AP
Cr Bank
```

The correct retailer/supplier is derived from the matched supplier invoice and posted Sage purchase invoice, not from the statement text.

### 4. `shipper_invoice_payment`

Purpose:

Payment OUT to shipper/logistics provider for shipper AP already posted as a Sage purchase invoice.

Source truth:

- confirmed shipper AP statement match/allocation
- `shipping_documents` or approved shipper AP source record
- posted Sage shipper AP purchase invoice id

Required upstream state:

- DVA/card statement line direction is OUT.
- Shipper AP match/allocation is confirmed.
- Shipper AP document has posted Sage purchase invoice id.
- Shipper Sage supplier contact mapping exists or is inherited from the posted purchase invoice snapshot.
- Sage bank account mapping exists.
- Match/allocation has not already been cash-posted.

Sage endpoints:

```text
POST /purchase_payments
POST /allocations
```

Accounting meaning:

```text
Dr Shipper AP
Cr Bank
```

The correct shipper is derived from the matched shipper AP document and posted Sage purchase invoice, not from the statement text.

If the current allocation table cannot safely target `shipping_documents`, add the smallest approved bridge for shipper AP cash allocation targets. Do not force shipper AP into `supplier_invoice_id`.

### 5. `retailer_refund_received`

Purpose:

Money IN from retailer/supplier refund following an approved refund/credit-note process.

Source truth:

- `dva_statement_line_allocations`
- allocation type `retailer_refund`
- `disputes`
- posted supplier credit note / purchase credit note where applicable

Required upstream state:

- DVA/card statement line direction is IN.
- Allocation is confirmed.
- Refund dispute/source is approved.
- Supplier credit note/purchase credit note treatment is posted where required.
- Sage refund-in endpoint/payload has been proven in a controlled test before bulk posting is enabled.

Initial workbench behaviour:

- show row
- show trace
- allow coding/freeze if safe
- block live posting with `endpoint_prove_required` until tested

### 6. `customer_refund_paid`

Purpose:

Cash refund OUT to importer/customer where the business refunds the customer.

Source truth:

- approved customer refund route
- posted sales credit note where required
- DVA/card OUT statement line or approved payment instruction

Sage endpoint pattern may use:

```text
POST /contact_payments
```

with transaction type:

```text
CUSTOMER_REFUND
```

This category is not first-phase bulk posting unless separately proven and approved.

### 7. `fx_card_difference`

Purpose:

Recognise FX/card/provider residuals separately from customer/supplier/shipper payments.

Source truth:

- `dva_statement_line_allocations`
- allocation type `fx_card_difference`

Required mapping:

- FX/card gain ledger
- FX/card loss ledger

Initial behaviour:

- show in workbench
- require coding
- block live posting until Sage GL/bank transaction endpoint is confirmed

### 8. `bank_fee`

Purpose:

Recognise bank/provider/card fees separately from customer/supplier/shipper payments.

Source truth:

- `dva_statement_line_allocations`
- allocation type `bank_fee`

Required mapping:

- bank fee ledger

Initial behaviour:

- show in workbench
- require coding
- block live posting until Sage GL/bank transaction endpoint is confirmed

### 9. `unmatched_hold`

Purpose:

Hold unmatched or unresolved balances without forcing them into a customer/supplier/shipper posting.

Source truth:

- `dva_statement_line_allocations`
- allocation type `unmatched_hold` or `exception_hold`

Initial behaviour:

- show in workbench
- not live-post by default
- require supervisor/accounting decision

## Mapping model

Use existing Sage party mappings for:

- importer/customer -> Sage customer contact
- retailer/supplier -> Sage supplier contact
- shipper -> Sage supplier contact

Use existing Sage mapping settings for ledgers/tax/bank/defaults.

Minimum additional mapping rows:

| Mapping code | Value kind | Purpose |
|---|---|---|
| `DVA_CASH_BANK_ACCOUNT` | `free_text` initially | Default Sage bank account id for DVA/card IN and OUT postings. UI must populate from Sage `/bank_accounts`. |
| `CUSTOMER_RECEIPT_PAYMENT_METHOD` | `free_text` | Optional Sage payment method/default such as `ELECTRONIC`. |
| `SUPPLIER_PAYMENT_METHOD` | `free_text` | Optional supplier payment method/default. |
| `FX_CARD_GAIN_LEDGER` | `ledger_account_id` | Ledger for FX/card gains or favourable residuals. |
| `FX_CARD_LOSS_LEDGER` | `ledger_account_id` | Ledger for FX/card losses or unfavourable residuals. |
| `BANK_FEE_LEDGER` | `ledger_account_id` | Ledger for bank/provider/card fees. |
| `UNMATCHED_HOLD_LEDGER` | `ledger_account_id` | Optional suspense/hold ledger. |

Simplification rule:

Use one default `DVA_CASH_BANK_ACCOUNT` first. Add per-provider/per-country bank mappings later only if needed.

Bank account ids must come from Sage `/bank_accounts`. Do not treat ordinary nominal ledger ids as bank account ids unless the exact Sage endpoint explicitly accepts that shape and the behaviour has been proven.

## Editable coding before freeze

Rows may be pre-completed from mappings but editable before freeze:

- posting category
- Sage contact
- Sage bank account
- target Sage artefact
- posting date
- amount
- short Sage reference
- notes
- FX/card residual treatment

After freeze:

- no payload editing
- revalidate only
- post
- retry failed
- correct/reverse through separate correction route

## Reference and traceability rules

Every cash posting row must carry both a short Sage reference and a full internal reference JSON.

### Short Sage references

Examples:

```text
GCB-IN-{order_ref}-{auth_short}
GCB-OUT-{invoice_ref}-{auth_short}
GCB-SHIP-{booking_or_order_ref}-{auth_short}
GCB-REF-{dispute_ref}-{auth_short}
GCB-FX-{statement_line_short}-{auth_short}
GCB-FEE-{statement_line_short}-{auth_short}
```

The short reference is for Sage display/search.

### Full internal reference JSON

Frozen payload must include:

```json
{
  "statement_id": "...",
  "statement_batch_ref": "...",
  "statement_line_id": "...",
  "statement_date": "...",
  "direction": "in_or_out",
  "auth_id_ref": "...",
  "reference_raw": "...",
  "order_id": "...",
  "order_ref": "...",
  "dva_reconciliation_id": "...",
  "allocation_id": "...",
  "supplier_invoice_id": "...",
  "shipping_document_id": "...",
  "dispute_id": "...",
  "posting_category": "...",
  "target_sage_object_id": "...",
  "target_sage_contact_id": "...",
  "target_sage_bank_account_id": "..."
}
```

## Snapshot and batch model

Cash posting must follow the same control discipline as invoice posting:

```text
workbench row
-> selected row
-> frozen snapshot
-> validation
-> posting batch row
-> Sage API call
-> Sage object id stored
-> response logged
```

Recommended object model:

- cash posting snapshots, batch rows and batches; or
- reuse existing `sage_posting_*` tables only after checking live constraints allow cash lanes safely.

Do not guess constraints. Inspect live DB first.

Minimum frozen snapshot fields:

- posting category
- source statement line id
- DVA reconciliation id or allocation id
- source target id
- order id/ref
- counterparty type/name
- Sage contact id snapshot
- Sage bank account id snapshot
- target Sage invoice/credit/payment-on-account id where applicable
- amount local currency
- amount GBP
- posting date
- short Sage reference
- full internal reference JSON
- idempotency key
- mapping fingerprint
- validation status

## Idempotency keys

Examples:

```text
cash:customer_receipt:dva_reconciliation:{dva_reconciliation_id}
cash:supplier_payment:allocation:{allocation_id}
cash:shipper_payment:allocation:{allocation_id}
cash:retailer_refund:allocation:{allocation_id}
cash:customer_refund:allocation:{allocation_id}
cash:fx_card_difference:allocation:{allocation_id}
cash:bank_fee:allocation:{allocation_id}
```

Each idempotency key may post successfully only once.

## Blocker rules

Rows must show a single simple blocker in the grid and full blocker detail in the drawer.

Minimum blockers:

- missing Sage contact
- missing Sage bank account
- target invoice not posted
- target credit note not posted
- allocation not confirmed
- statement line reversed or voided
- statement import voided
- amount invalid
- already posted
- endpoint prove required
- FX residual not coded
- bank fee ledger missing
- unmatched hold requires decision

## First build sequence

### Phase 1 — Read-only workbench

Build the route and show rows from existing reconciliations/allocations.

No write buttons.

### Phase 2 — Mapping rows

Add minimum mapping rows for DVA cash bank account, FX gain/loss, bank fees and payment method defaults.

### Phase 3 — Bulk selection controls

Add select all visible, unselect all, filters, and row detail drawer.

Still no live posting.

### Phase 4 — Customer/importer IN freeze and validation

Freeze selected `customer_receipt_on_account` rows.

Validate:

- customer contact exists
- bank account mapping exists
- statement line is IN
- DVA reconciliation/funding event exists
- not already posted
- amount is positive

### Phase 5 — Customer/importer IN live posting

Post:

```text
POST /contact_payments
```

with:

```text
transaction_type_id = CUSTOMER_RECEIPT
```

Store:

- Sage contact payment id
- Sage payment-on-account id
- Sage response payload

### Phase 6 — Supplier/retailer OUT freeze and validation

Validate:

- confirmed allocation type `supplier_invoice`
- statement line is OUT
- posted Sage purchase invoice id exists
- bank account mapping exists
- allocation not already posted

### Phase 7 — Supplier/retailer OUT live posting

Post:

```text
POST /purchase_payments
POST /allocations
```

### Phase 8 — Shipper OUT

Repeat supplier payment pattern for confirmed shipper AP matches and posted shipper AP purchase invoices.

### Phase 9 — Retailer refund IN, customer refund OUT and residuals

Keep visible and coded, but live-post only after each exact Sage endpoint/payload has been proven with a controlled test.

## Implementation discipline

Before coding:

1. Check this contract.
2. Check `COMMAND_CENTRES_AND_SAGE_CLOUD_ACCOUNTING_CONTRACT_v5.md`.
3. Check live DB tables, constraints, views, RPCs and RLS.
4. Check current repo files.
5. Prefer additive views/RPCs and wrapper functions.
6. Do not alter existing reconciliations or invoice posting logic unless explicitly required.
7. Patch surgically.
8. Confirm Vercel deployment is READY before testing.
9. Test exact statement line / allocation / invoice / order refs.
