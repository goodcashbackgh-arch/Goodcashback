# Supplier Invoice Header Net/VAT Review Addendum v1

## Status

This addendum supplements the existing supplier invoice OCR/header review and supplier accounting reconciliation contracts.

It is intentionally narrow. It does not replace the current invoice-review workflow, does not alter raw Mindee evidence, and does not create a second invoice-header source of truth.

## Problem being corrected

The existing supervisor header-review flow can correct and save:

- invoice reference
- retailer/supplier name
- invoice date
- invoice gross/total

The existing live RPC is:

```text
staff_save_supplier_invoice_header_review(
  uuid,
  text,
  text,
  text,
  date,
  numeric,
  text
)
```

The current `supplier_invoices` row stores the reviewed gross in `ocr_invoice_total_gbp`, but there are no equivalent persisted reviewed header values for invoice net or invoice VAT.

The accounting reconciliation totals view therefore reads net and VAT directly from raw OCR JSON.

That creates a failure mode where the operator/supervisor has reviewed the invoice correctly but reconciliation is still blocked by a bad OCR header field.

### Proven example

Supplier invoice:

```text
NIN-300726-A
supplier_invoice_id = f390207f-02a3-4fae-b17b-879725203b61
```

Accepted/reviewed gross:

```text
£239.99
```

Raw Mindee header fields:

```text
total_net    = £239.99   -- wrong
total_tax    = £40.00    -- correct
total_amount = £3,599.85 -- wrong
```

Mindee also returned the correct tax base inside the tax object:

```text
taxes[0].base   = £199.99
taxes[0].amount = £40.00
taxes[0].rate   = 20%
```

The accounting-coded lines correctly reconcile to:

```text
Net   £199.99
VAT    £40.00
Gross £239.99
```

But the current totals view accepts raw `total_net = £239.99`, producing an artificial net variance of `-£40.00` while VAT variance and gross variance are both zero.

The coding is correct. The defect is the absence of persisted reviewed header net/VAT values.

## Governing rule

Raw OCR remains immutable evidence of what Mindee returned.

Supervisor-reviewed header values are the accepted operational values once explicitly saved through the existing header-review action.

Priority must be:

```text
reviewed header value
-> raw OCR value
-> existing fallback, where one already exists
```

Do not rewrite `ocr_raw_json` to make OCR appear correct after review.

## Minimal data-model extension

Add exactly two nullable columns to `public.supplier_invoices`:

```text
reviewed_invoice_net_gbp numeric(12,2) NULL
reviewed_invoice_vat_gbp numeric(12,2) NULL
```

No new table is required.

Do not move the existing gross workflow into `supplier_invoice_financial_summary` as part of this addendum.

Do not change the meaning of `supplier_invoice_financial_summary.invoice_total_gbp`.

## Existing gross behaviour remains unchanged

The existing header-review RPC currently saves the reviewed gross/total into:

```text
supplier_invoices.ocr_invoice_total_gbp
```

That behaviour remains authoritative for this addendum.

This addendum adds reviewed net and VAT alongside that existing reviewed total path; it does not redesign gross storage.

## Header-review RPC extension

Extend the existing function:

```text
public.staff_save_supplier_invoice_header_review
```

with two new nullable parameters:

```text
p_reviewed_invoice_net_gbp numeric DEFAULT NULL
p_reviewed_invoice_vat_gbp numeric DEFAULT NULL
```

The existing security, staff-role, status, review-stamp, and Sage-blocking behaviour must remain unchanged.

The function must continue to:

- require active admin/supervisor staff
- reject retired/rejected/superseded/duplicate-blocked invoices
- keep `review_status = 'pending_review'`
- keep `blocked_from_sage_yn = true`
- keep `is_current_for_order = false`
- stamp `reviewed_by_staff_id`
- stamp `reviewed_at`
- preserve the existing review-note behaviour
- resolve the same open/under-review supplier invoice review flags

The only new writes are:

```text
supplier_invoices.reviewed_invoice_net_gbp
supplier_invoices.reviewed_invoice_vat_gbp
```

## Header arithmetic guard

When reviewed net, reviewed VAT, and reviewed gross are all present, the save must fail closed unless:

```text
abs((net + VAT) - gross) <= £0.01
```

Example valid review:

```text
Net   £199.99
VAT    £40.00
Gross £239.99
```

Example invalid review:

```text
Net   £239.99
VAT    £40.00
Gross £239.99
```

The RPC must reject the second case rather than persist an internally contradictory reviewed header.

The guard is a header-integrity check only. It must not alter line coding, tax rates, discounts, delivery treatment, quantities, or invoice state.

## OCR/header review UI

Extend the existing invoice OCR/header review form only.

The same review card/form that already allows the supervisor to correct the invoice header must expose:

```text
Net
VAT
Total
```

No new page and no new workflow are required.

### Display/default rules

For Net, initial display should prefer:

```text
reviewed_invoice_net_gbp
-> OCR total_net
```

For VAT, initial display should prefer:

```text
reviewed_invoice_vat_gbp
-> OCR total_tax
```

For Total, preserve the existing reviewed/accepted gross behaviour.

The supervisor must be able to overwrite bad OCR net or VAT values before progressing the invoice.

### Save rules

Saving the form must call the existing `staff_save_supplier_invoice_header_review` route/action extended with the two new values.

Do not create a parallel write endpoint.

Do not write corrections into `ocr_raw_json`.

## Accounting reconciliation totals rule

Update only the accepted-header input logic inside:

```text
public.supplier_invoice_accounting_coding_totals_vw
```

### Accepted net

Use:

```text
COALESCE(
  supplier_invoices.reviewed_invoice_net_gbp,
  raw OCR total_net,
  existing net fallback
)
```

### Accepted VAT

Use:

```text
COALESCE(
  supplier_invoices.reviewed_invoice_vat_gbp,
  raw OCR total_tax
)
```

### Accepted gross

Preserve the existing gross hierarchy exactly unless a separately approved addendum changes it.

This addendum must not broaden the change into gross-source redesign.

## Raw OCR evidence rule

`ocr_raw_json` must remain unchanged after supervisor review.

The platform must retain both facts:

```text
what OCR originally returned
```

and

```text
what an authorised supervisor accepted after reviewing the invoice
```

This distinction is required for auditability and diagnosis of OCR extraction failures.

## Explicit non-goals

This addendum does not authorise any of the following:

- changing Mindee models or prompts
- changing OCR ingestion
- rewriting `ocr_raw_json`
- introducing automatic OCR correction logic
- changing invoice line coding
- changing discount treatment
- changing delivery treatment
- changing VAT-rate selection
- changing nominal/Sage ledger codes
- changing supplier invoice approval rules
- changing `is_current_for_order` behaviour
- changing Sage posting readiness beyond the existing net/VAT/gross reconciliation result
- changing supplier payment allocation
- redesigning `supplier_invoice_financial_summary`
- adding new review statuses
- creating a new invoice-review page
- creating a new header-review table

## Existing dependency protection

Known current dependants of `supplier_invoice_financial_summary` include:

```text
flag_order_bundle_limit_after_summary_v1
staff_allocate_statement_line_to_supplier_invoice_bundle_core_v
staff_find_supplier_invoice_ocr_duplicates
supplier_invoice_accounting_coding_totals_vw
supplier_invoice_match_decision_pre_bundle_limit_v1
supplier_payment_candidate_status_vw
trg_supplier_invoice_post_ocr_duplicate_gate
```

This addendum does not require changing those dependants merely to add reviewed net/VAT support.

The implementation should avoid unnecessary edits to them.

The only known downstream accounting object that must consume the new reviewed values is:

```text
supplier_invoice_accounting_coding_totals_vw
```

## Backward compatibility

Existing invoices must continue to work without backfill.

Because the new columns are nullable:

```text
reviewed_invoice_net_gbp IS NULL
reviewed_invoice_vat_gbp IS NULL
```

must preserve current OCR/fallback behaviour.

Historical invoices must not be rewritten automatically.

No existing reviewed gross values should be changed by the migration.

## Required implementation sequence

1. Add nullable `reviewed_invoice_net_gbp` and `reviewed_invoice_vat_gbp` columns to `supplier_invoices`.
2. Extend `staff_save_supplier_invoice_header_review` with the two nullable parameters.
3. Add the `net + VAT = gross` tolerance guard to that RPC when all three reviewed values are present.
4. Extend the existing invoice-review server action to pass the new values.
5. Add Net and VAT inputs to the existing invoice OCR/header review form.
6. Update `supplier_invoice_accounting_coding_totals_vw` so reviewed net/VAT override raw OCR net/VAT.
7. Preserve the current accepted gross hierarchy.
8. Run focused regression checks before merge.

## Required regression checks

### Regression A — proven bad OCR invoice

For `NIN-300726-A`, save:

```text
Net   £199.99
VAT    £40.00
Total £239.99
```

Expected reconciliation:

```text
accepted_invoice_net_gbp   = 199.99
accepted_invoice_vat_gbp   = 40.00
accepted_invoice_gross_gbp = 239.99
net_variance_gbp            = 0.00
vat_variance_gbp            = 0.00
gross_variance_gbp          = 0.00
net_reconciled_to_invoice_yn   = true
vat_reconciled_to_invoice_yn   = true
gross_reconciled_to_invoice_yn = true
```

Raw OCR must still show its original bad values.

### Regression B — legacy invoice without reviewed net/VAT

An existing invoice with both new columns null must return the same accepted net/VAT values it returned before this addendum.

### Regression C — invalid reviewed arithmetic

Attempt to save:

```text
Net   £239.99
VAT    £40.00
Total £239.99
```

Expected:

```text
save rejected
no reviewed net/VAT persistence
invoice remains pending_review and blocked from Sage
```

### Regression D — status preservation

Saving a valid header correction must not:

- approve the invoice
- set it current for order
- unblock Sage
- post anything
- alter supplier invoice lines

### Regression E — line coding preservation

For the proven invoice, existing coded lines must remain unchanged, including:

```text
5000 goods
5010 discount
5100 delivery
```

The addendum fixes accepted header values only.

## Acceptance criteria

This addendum is complete only when all of the following are true:

1. Supervisor can edit Net and VAT on the existing OCR/header review page.
2. Reviewed Net and VAT are persisted separately from raw OCR JSON.
3. Reviewed header values are used by accounting reconciliation when present.
4. Raw Mindee evidence remains unchanged.
5. Header save rejects reviewed values that do not arithmetically reconcile within £0.01.
6. Legacy invoices with null reviewed Net/VAT retain existing behaviour.
7. Gross/total behaviour is not redesigned.
8. No unrelated invoice, payment, Sage, discount, delivery, or status logic is changed.

## Scope lock

Implementation must remain limited to the smallest existing path:

```text
supplier_invoices
+ existing supplier invoice header-review RPC
+ existing invoice-review UI/action
+ supplier_invoice_accounting_coding_totals_vw
```

Any proposed change outside that path requires a separate explicit justification before implementation.
