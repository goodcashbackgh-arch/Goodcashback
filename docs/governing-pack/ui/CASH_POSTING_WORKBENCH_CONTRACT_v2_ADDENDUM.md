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

## Residuals, FX and fees

FX/card differences and bank/provider fees must remain separate allocation rows.

They must not be hidden inside supplier/shipper payments.

Example:

```text
Statement OUT: £164.00
- £161.99 supplier invoice allocation -> supplier payment posting
- £2.01 FX/card residual allocation -> residual route, blocked until endpoint proven
```

The supplier payment should post £161.99 only. The residual must remain separately visible and separately controlled.

## Shipper OUT posting model

Category: `shipper_invoice_payment`

Use the same Sage pattern as supplier OUT once the upstream allocation target is a confirmed shipper AP document with a posted Sage purchase invoice id.

```text
POST /contact_payments
transaction_type_id = VENDOR_PAYMENT
allocated_artefacts[] -> posted Sage shipper purchase invoice id
```

Do not force shipper AP into supplier invoice targets if the correct shipper AP bridge is not present.

## Current safe bulk scope

Safe to batch/post separately:

```text
customer/importer IN receipts batch
supplier/retailer OUT payments batch
shipper OUT payments batch, where target AP bridge is proven
```

Do not mix IN receipts and OUT payments in the same live posting batch.

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

## Implementation discipline

Before further cash posting changes:

1. Check this addendum and the v1 contract together.
2. Keep allocation decisions in the main DVA/card allocation workbench.
3. Treat confirmed allocation rows as the source of truth for cash posting.
4. Do not post directly from raw statement lines.
5. Do not hide FX/card differences, bank fees or holds inside supplier/customer payments.
6. Patch surgically and preserve existing flows.
7. Confirm Vercel deployment is READY before testing.
