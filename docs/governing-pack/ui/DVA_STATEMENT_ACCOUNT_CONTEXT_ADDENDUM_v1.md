# DVA Statement Account Context Addendum v1

## Status

This addendum supplements the DVA/card statement import and reconciliation contracts.

Do not delete or replace existing importer-DVA rules. This addendum adds a second statement-account context for main/company bank accounts used for shipper and platform-level payments.

## Problem being corrected

The original statement import flow is importer-scoped.

That is correct for importer DVA/card accounts, but not correct for the main company bank account used to pay shippers.

A main/company bank account must not be represented as a fake importer.

## New account-context rule

Every statement import must have a statement account context.

Allowed first-phase account contexts:

```text
importer_dva_card_account
main_company_bank_account
```

### `importer_dva_card_account`

Used for importer/customer DVA/card activity.

Rules:

- importer is required
- statement lines may feed importer funding reconciliation
- statement lines may feed supplier/retailer purchase allocation where the purchase relates to importer/order activity
- existing DVA/card statement behaviour remains valid

### `main_company_bank_account`

Used for platform/company bank movements, especially shipper payments.

Rules:

- importer is not required
- statement lines must not be treated as importer/customer funding
- statement lines may be allocated to accepted/posted shipper AP invoices
- statement lines may be allocated to bank fees, FX/card differences, or holds
- customer/importer DVA funding RPCs must not consume these lines

## Upload UI rule

The statement upload page should select account context first:

```text
Statement account:
- Importer DVA/card account
- Main company bank account
```

If `Importer DVA/card account` is selected:

```text
Importer field = required
```

If `Main company bank account` is selected:

```text
Importer field = not required / hidden / disabled
```

Do not add `Main company bank account` as a fake importer option.

## Reconciliation rule for shipper payments

The intended flow is:

```text
Choose main company bank account
-> upload statement
-> commit statement lines
-> allocation workbench shows OUT lines
-> match OUT line to accepted shipper AP invoice
-> shipper AP invoice already posted to Sage as purchase invoice
-> cash posting creates Sage VENDOR_PAYMENT
-> allocated_artefacts[] clears the posted shipper purchase invoice
```

This uses the existing DVA/card allocation workbench pattern. It is not a separate shipper payment module.

## Required backend bridge

The backend must expose main-company-bank OUT lines to the allocation workbench without forcing importer linkage.

The shipper allocation target must carry enough information for cash posting:

- statement account context = `main_company_bank_account`
- statement line id
- shipper AP source id
- shipper id
- Sage shipper supplier contact id
- DVA/main bank Sage bank account id
- posted Sage purchase invoice artefact id
- confirmed allocation amount

## Cash posting handoff

Once a shipper AP allocation row is confirmed, the cash posting row should use:

```text
posting_category = shipper_invoice_payment
source_type = shipper_ap_cash_allocation
counterparty_type = shipper
```

Sage route:

```text
POST /contact_payments
transaction_type_id = VENDOR_PAYMENT
allocated_artefacts[] = posted Sage shipper purchase invoice id
```

## Safety rules

- Do not use fake importers for main/company bank accounts.
- Do not allow main/company bank lines into importer funding reconciliation.
- Do not post from raw bank text.
- Do not pay a shipper invoice unless the shipper AP invoice has already been accepted and posted to Sage as a purchase invoice.
- Do not hide FX/card differences or bank fees inside the shipper payment.
- Keep importer DVA/card behaviour unchanged.

## Implementation sequence

1. Add statement account context to import/upload/read models.
2. Keep importer required only for importer DVA/card account context.
3. Add main company bank account option to upload UI.
4. Allow committed main-bank statement lines into the allocation workbench.
5. Add shipper AP invoice allocation target.
6. Feed confirmed shipper AP allocation rows into the cash posting workbench.
7. Use the shared supplier/shipper `VENDOR_PAYMENT` posting engine.
