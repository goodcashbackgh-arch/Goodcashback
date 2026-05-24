# Cash Posting Workbench Contract v2 Addendum

## Status

This addendum supersedes the supplier/shipper OUT endpoint and allocation wording in `CASH_POSTING_WORKBENCH_CONTRACT_v1.md`.

It records the proven Sage behaviour from the controlled OUT payment test and the corrected production shape agreed after testing.

## Core correction

Cash posting is downstream execution only.

Allocation decisions remain in the main DVA/card cash allocation workbench. Cash posting must not create a parallel allocation workflow and must not decide matches from raw bank text.

```text
Main DVA/card allocation workbench
-> confirmed allocation rows
-> cash posting workbench freeze/batch/post
-> Sage cash endpoint
```

## Separation of responsibilities

### Main allocation workbench

The allocation workbench decides what each statement line relates to:

- customer/importer funding receipt
- supplier/retailer invoice payment
- shipper invoice payment
- retailer refund receipt
- FX/card difference
- bank/provider fee
- exception hold / unmatched hold

It may split one statement line into multiple confirmed allocation rows.

### Cash posting workbench

The cash posting workbench only executes accounting-ready confirmed outcomes:

- freeze selected confirmed rows
- validate required Sage contact / bank / target artefact fields
- batch selected rows
- post to Sage
- store Sage object ids, response payloads and posting trace

It must not expose allocation controls as a separate category-specific workbench.

## DVA split is the accounting source of truth

Where the DVA/card allocation workbench splits one statement line, cash posting must use that split exactly.

Example:

```text
Statement OUT: £164.00

Confirmed DVA allocation rows:
- £161.99 -> supplier_invoice_payment -> matched Sage purchase invoice
- £2.01 -> fx_card_difference -> FX/card loss ledger
```

Cash posting must not force the raw statement total into the supplier/shipper payment.

Correct accounting execution:

```text
Supplier part:
POST /contact_payments
transaction_type_id = VENDOR_PAYMENT
allocated_artefacts[] -> matched Sage purchase invoice
amount = £161.99

FX/card residual part:
separate posting to mapped FX/card gain/loss treatment
amount = £2.01
```

This keeps supplier/shipper payments matching the posted purchase invoices while keeping FX/card movement transparent.

## Correct supplier/retailer OUT posting model

Category: `supplier_invoice_payment`

Source truth:

```text
dva_statement_line_allocations
allocation_type = supplier_invoice
allocation_status = confirmed
supplier invoice already posted to Sage as purchase invoice
```

Sage endpoint:

```text
POST /contact_payments
```

Sage transaction type:

```text
VENDOR_PAYMENT
```

Allocation method:

```text
contact_payment.allocated_artefacts[]
```

Required payload shape:

```json
{
  "contact_payment": {
    "transaction_type_id": "VENDOR_PAYMENT",
    "contact_id": "sage_supplier_contact_id",
    "bank_account_id": "sage_bank_account_id",
    "date": "YYYY-MM-DD",
    "total_amount": 161.99,
    "reference": "GCB-OUT-...",
    "allocated_artefacts": [
      {
        "artefact_id": "sage_purchase_invoice_id",
        "amount": 161.99
      }
    ]
  }
}
```

The platform must send the exact Sage purchase invoice artefact id. Sage must not be relied on to infer the invoice from statement text or reference.

## Correct shipper OUT posting model

Category: `shipper_invoice_payment`

Build this alongside supplier/retailer OUT using the same posting engine and same Sage route, because Sage treats both as supplier/vendor payments once the shipper AP document is posted as a Sage purchase invoice.

Source truth:

```text
dva_statement_line_allocations or approved shipper AP cash bridge
allocation_type = shipper_invoice / shipper_ap_payment
allocation_status = confirmed
shipper AP document already posted to Sage as purchase invoice
```

Sage endpoint:

```text
POST /contact_payments
```

Sage transaction type:

```text
VENDOR_PAYMENT
```

Allocation method:

```text
contact_payment.allocated_artefacts[] -> posted Sage shipper purchase invoice id
```

Shipper OUT can be built in the same action family as supplier/retailer OUT, provided the upstream row carries:

- confirmed shipper AP allocation/match id
- shipper platform party id
- Sage shipper supplier contact id
- Sage bank account id
- posted Sage purchase invoice artefact id
- amount to pay from the confirmed allocation row

Do not force shipper AP into `supplier_invoice_id` if the correct shipper AP bridge is not present. Add the smallest bridge/view needed so the cash posting row has the same shape as supplier OUT.

## Grouping rule for bulk OUT posting

The production rule is not:

```text
one statement line = one invoice = one payment
```

The production rule is:

```text
one posted Sage payment = approved allocation rows grouped by same payment context
```

Grouping key:

```text
posting category
+ Sage supplier/shipper contact
+ Sage bank account
+ posting date
+ statement line id/payment context
```

For a group, the Sage payment amount equals the sum of the confirmed allocation rows included in that group.

```text
Sage contact_payment.total_amount = sum(confirmed allocation rows in group)
```

Each supplier/shipper invoice allocation becomes one `allocated_artefacts[]` entry.

```text
allocated_artefacts[n].artefact_id = matched Sage purchase invoice id
allocated_artefacts[n].amount = that confirmed allocation amount
```

This supports multiple purchase invoices paid by the same statement payment, without forcing raw statement amount to equal one invoice amount.

Supplier/retailer and shipper OUT may share the same posting engine, but they must not be grouped together unless they share the same Sage supplier contact, Sage bank, posting date and statement payment context. In normal use, different retailers/shippers become separate Sage contact payments.

## FX/card differences and bank/provider fees

FX/card differences and bank/provider fees must use the allocation split from the DVA/card allocation workbench.

They must not be hidden inside supplier/shipper payments or customer receipts.

### `fx_card_difference`

Source truth:

```text
dva_statement_line_allocations
allocation_type = fx_card_difference
allocation_status = confirmed
```

Required mappings:

```text
FX_CARD_GAIN_LEDGER
FX_CARD_LOSS_LEDGER
DVA_CASH_BANK_ACCOUNT
```

Posting rule:

```text
confirmed FX/card gain -> mapped FX/card gain ledger
confirmed FX/card loss -> mapped FX/card loss ledger
```

Direction/sign treatment must be explicit in the posting preview before live posting. Do not infer silently at Sage post time.

### `bank_fee`

Source truth:

```text
dva_statement_line_allocations
allocation_type = bank_fee
allocation_status = confirmed
```

Required mappings:

```text
BANK_FEE_LEDGER
DVA_CASH_BANK_ACCOUNT
```

Posting rule:

```text
confirmed bank/provider fee -> mapped bank fee ledger
```

### Endpoint status

FX/card and bank fee rows should be visible, selectable for coding/freeze when mappings exist, and posted only after the exact Sage GL/bank transaction endpoint and payload are proven with a controlled test.

Once proven, they should be posted from the same confirmed allocation-row source as supplier/shipper OUT, not from raw statement text.

## Current safe bulk scope

Safe to batch/post separately:

```text
customer/importer IN receipts batch
supplier/retailer OUT payments batch
shipper OUT payments batch, where target AP bridge is proven
```

Do not mix IN receipts and OUT payments in the same live posting batch.

Supplier/retailer OUT and shipper OUT can be developed together because both use Sage `contact_payments` with `VENDOR_PAYMENT` and `allocated_artefacts[]`; the only difference is the upstream AP source/bridge.

Retailer refund IN, customer refund OUT, FX/card residuals, bank fees and holds remain visible but blocked from bulk live posting until their exact Sage endpoint/payload is proven.

## Superseded wording in v1

The v1 wording saying supplier/shipper OUT uses:

```text
POST /purchase_payments
POST /allocations
```

is superseded by this addendum.

The correct current Sage OUT payment route is:

```text
POST /contact_payments
transaction_type_id = VENDOR_PAYMENT
allocated_artefacts[] = matched posted purchase invoice artefacts
```

The v1 wording that described FX/card differences and bank fees as only visible/blocked remains true until the exact Sage endpoint is proven, but the intended accounting source is now fixed: confirmed DVA allocation split rows.

## Implementation discipline

Before further cash posting changes:

1. Check this addendum and the v1 contract together.
2. Keep allocation decisions in the main DVA/card allocation workbench.
3. Treat confirmed allocation rows as the source of truth for cash posting.
4. Do not post directly from raw statement lines.
5. Do not hide FX/card differences, bank fees or holds inside supplier/customer payments.
6. Build shipper OUT with supplier/retailer OUT only through the shared vendor-payment pattern, preserving separate upstream AP source truth.
7. Patch surgically and preserve existing flows.
8. Confirm Vercel deployment is READY before testing.
