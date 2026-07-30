# Supplier Invoice Header Net/VAT Review Addendum v1

## Status

This addendum supplements the existing supplier invoice OCR/header review and supplier accounting reconciliation contracts.

It is intentionally narrow. It does not replace the current invoice-review workflow, does not alter raw Mindee evidence, and does not create a second invoice-header source of truth.

This addendum is the governing source for the implementation. The build must remain inside the scope lock in this document.

## Problem being corrected

The existing supervisor header-review flow can correct and save:

- invoice reference
- retailer/supplier name
- invoice date
- invoice gross/total

The existing live RPC before this addendum is:

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

## Exact end-to-end behaviour

### A. OCR ingestion remains unchanged

Mindee continues to run and save through the existing OCR path. The raw inference is persisted unchanged in `supplier_invoices.ocr_raw_json`.

The addendum does not change:

```text
Mindee enqueue
Mindee polling
Mindee inference fetch
staff_save_mindee_invoice_ocr_result
OCR line creation
review-flag creation
```

### B. Existing invoice-review page remains the correction point

The existing page:

```text
/internal/invoice-review
```

remains the only supervisor header-correction UI.

The existing `Save header correction` form is extended with:

```text
Net
VAT
Total
```

No new page is created.

### C. Supervisor corrects only the header value that is wrong

For the proven invoice the intended accepted values are:

```text
Net   £199.99
VAT    £40.00
Total £239.99
```

Line coding is not changed by this action.

### D. Existing server action remains the write path

The existing action:

```text
saveSupplierInvoiceHeaderReviewAction
```

continues to be used. It is extended to read and pass:

```text
reviewed_invoice_net_gbp
reviewed_invoice_vat_gbp
```

No parallel endpoint or action is allowed.

### E. Existing RPC remains the database write boundary

The existing RPC name remains:

```text
public.staff_save_supplier_invoice_header_review
```

It is extended with the two reviewed values and remains the single database write boundary for header review.

### F. Database validates the reviewed header

When Net, VAT and Total are all present, the database must fail closed unless:

```text
abs((Net + VAT) - Total) <= £0.01
```

Valid:

```text
199.99 + 40.00 = 239.99
```

Invalid:

```text
239.99 + 40.00 != 239.99
```

The invalid save must not partially persist the reviewed Net/VAT.

### G. Reviewed Net/VAT are stored separately from raw OCR

Persist:

```text
supplier_invoices.reviewed_invoice_net_gbp
supplier_invoices.reviewed_invoice_vat_gbp
```

Do not mutate:

```text
supplier_invoices.ocr_raw_json
```

The system must retain both:

```text
what OCR returned
```

and

```text
what the authorised supervisor accepted
```

### H. Existing review state remains unchanged by save

Saving a valid header correction must continue to leave the invoice:

```text
review_status = pending_review
blocked_from_sage_yn = true
is_current_for_order = false
```

It must not approve, post, release, set current, or bypass any existing readiness rule.

### I. Accounting reconciliation consumes the reviewed values

The existing view:

```text
public.supplier_invoice_accounting_coding_totals_vw
```

must prefer reviewed Net/VAT when present.

The existing reconciliation UI and readiness code already consume this view, so no additional downstream endpoint is introduced.

### J. Existing accounting guard remains intact

The existing coding readiness rule continues to require:

```text
all progressed/accounting-codable lines coded
posting accounts present
coded gross > 0
Net reconciled
VAT reconciled
Gross reconciled
```

The build does not weaken that guard. It only corrects the accepted header source used by the guard.

### K. Legacy invoices remain unchanged

When:

```text
reviewed_invoice_net_gbp IS NULL
reviewed_invoice_vat_gbp IS NULL
```

the existing OCR/fallback behaviour must remain exactly as before.

No historical backfill is authorised.

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

The existing gross hierarchy in `supplier_invoice_accounting_coding_totals_vw` must remain:

```text
supplier_invoices.ocr_invoice_total_gbp
-> raw OCR total_amount
-> supplier_invoice_financial_summary.invoice_total_gbp
```

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

## RPC signature compatibility rule

The pre-build live signature is:

```text
staff_save_supplier_invoice_header_review(uuid,text,text,text,date,numeric,text)
```

The repo has one application caller for this RPC:

```text
app/internal/invoice-review/actions.ts
```

The migration and that caller must move together.

Do not leave both the old and new defaulted overloads active under the same RPC name because PostgREST resolution could become ambiguous.

The implementation must replace the old signature atomically and issue:

```text
NOTIFY pgrst, 'reload schema'
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

Net and VAT remain non-negative money fields, consistent with the existing header money parser.

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

For Net, initial display must prefer:

```text
reviewed_invoice_net_gbp
-> OCR total_net
```

For VAT, initial display must prefer:

```text
reviewed_invoice_vat_gbp
-> OCR total_tax
```

For Total, preserve the existing reviewed/accepted gross behaviour.

The supervisor must be able to overwrite bad OCR net or VAT values before progressing the invoice.

### Lightweight OCR header read rule

The invoice-review queue must **not** select or transfer the full `supplier_invoices.ocr_raw_json` document merely to prefill Net and VAT.

The page can load up to 100 invoice rows. Pulling the complete raw OCR payload for every row is unnecessary and must be removed.

The UI must consume only two lightweight numeric OCR header values:

```text
ocr_invoice_net_gbp
ocr_invoice_vat_gbp
```

These are read-only projections derived in SQL from the existing immutable `ocr_raw_json` fields:

```text
ocr_invoice_net_gbp = ocr_raw_json #>> '{inference,result,fields,total_net,value}'
ocr_invoice_vat_gbp = ocr_raw_json #>> '{inference,result,fields,total_tax,value}'
```

The projection must not copy, rewrite, normalise, or persist a second OCR payload. It exposes only the two numeric values already required by the review form.

Preferred implementation is a narrow existing/read-only invoice-review projection or equivalent SQL select surface so `/internal/invoice-review` fetches the two numerics and not the JSON blob.

The UI must therefore use:

```text
Net default = reviewed_invoice_net_gbp ?? ocr_invoice_net_gbp
VAT default = reviewed_invoice_vat_gbp ?? ocr_invoice_vat_gbp
```

and must remove any TypeScript helper whose only purpose is traversing `ocr_raw_json` on the queue page.

This optimisation changes no business rule, source precedence, OCR evidence, save path, reconciliation rule, or downstream behaviour.

It does **not** authorise:

- changes to Mindee ingestion
- new OCR persistence columns
- copying raw OCR JSON into another table
- changes to `ocr_raw_json`
- new write endpoints
- changes to the 100-row queue limit
- changes to queue filtering or navigation

### Save rules

Saving the form must call the existing `saveSupplierInvoiceHeaderReviewAction`, which calls the existing `staff_save_supplier_invoice_header_review` RPC extended with the two new values.

Do not create a parallel write endpoint.

Do not write corrections into `ocr_raw_json`.

## Exact integration endpoints and refresh path

The build connects only to these existing integration points:

```text
/internal/invoice-review
        ↓
saveSupplierInvoiceHeaderReviewAction
        ↓
public.staff_save_supplier_invoice_header_review(...)
        ↓
public.supplier_invoices reviewed Net/VAT
        ↓
public.supplier_invoice_accounting_coding_totals_vw
        ↓
/internal/reconciliation/[order_id]
        ↓
existing supplier-draft-ready / approval flow
```

The existing action already revalidates:

```text
/internal/invoice-review
/internal/supplier-draft-ready
/internal/evidence/{orderId}
/importer/orders/{orderId}/operations
/importer/reconciliation/{orderId}
```

That refresh chain is preserved.

The OCR path remains separate and unchanged:

```text
Mindee
  ↓
staff_save_mindee_invoice_ocr_result
  ↓
ocr_raw_json + OCR lines + review flags
```

## Accounting reconciliation totals rule

Update only the accepted-header input logic inside:

```text
public.supplier_invoice_accounting_coding_totals_vw
```

The latest accounting-codable-line contract must be preserved, including active `non_physical_financial` parked lines and accounting adjustment lines.

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

Preserve the existing gross hierarchy exactly.

This addendum must not broaden the change into gross-source redesign.

## Upstream impact and protection

### Expected upstream behavioural impact: none

The build must not change:

- invoice upload
- operator-entered financial summary
- Mindee model selection
- Mindee enqueue endpoint
- Mindee job polling
- Mindee inference fetch
- OCR result persistence
- OCR line extraction
- OCR flags
- PDF evidence

### Real upstream compatibility risk: RPC signature

The header-review RPC signature changes. The migration and server-action caller must ship together and the PostgREST schema cache must be reloaded.

### Form parsing protection

Reuse the existing non-negative optional-money parsing behaviour. Do not loosen the generic parser and do not change line/adjustment money semantics.

## Downstream impact and protection

### Deliberate downstream change

Consumers of:

```text
supplier_invoice_accounting_coding_totals_vw.accepted_invoice_net_gbp
supplier_invoice_accounting_coding_totals_vw.accepted_invoice_vat_gbp
```

will see reviewed values when present.

That is the intended propagation point.

### Approval readiness

The existing `assertSupplierInvoiceAccountingCodingReady()` remains unchanged. It already consumes the totals view and requires Net/VAT/Gross reconciliation.

The build must not weaken or bypass that rule.

### Gross/line/adjustment readiness

The existing `assertInvoiceReadyForCurrentApproval()` remains unchanged. It independently checks invoice total against supported line/delivery/discount representations.

Reviewed Net/VAT must not affect this gross/line gate.

### Line coding

No line accounting code is changed by this build.

For the proven invoice the existing coding remains:

```text
5000 goods
5010 discount
5100 delivery
```

### Other downstream areas that must remain untouched

- supplier payment allocation
- supplier payment readiness except through the existing invoice approval state
- bundle limits
- DVA reconciliation
- importer/customer funding
- shipment allocation
- tracking
- customer sales
- Sage payload construction
- Sage posting routes
- exception handling
- discount approval
- delivery approval
- invoice-current selection rules

## Reviewed-value lifecycle rule

A reviewed Net/VAT override belongs to the specific uploaded `supplier_invoices` row/evidence record.

A corrected/replacement invoice is represented by a different supplier-invoice evidence row under the existing resubmission flow. Therefore reviewed Net/VAT must not be copied to replacement evidence.

Fetching/saving the result for the same existing Mindee job on the same invoice row must not silently rewrite or clear an already saved reviewed Net/VAT override.

This build must not add a blanket OCR-result hook that clears reviewed values.

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
- changing reconciliation navigation
- changing UI labels unrelated to Net/VAT fields
- changing permissions
- changing totals outside the accepted Net/VAT header source

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

The implementation must avoid unnecessary edits to them.

The only downstream accounting object that must consume the new reviewed values is:

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

Adding the nullable columns must not require rewrites to unrelated `supplier_invoices` consumers.

## Required implementation sequence

1. Add nullable `reviewed_invoice_net_gbp` and `reviewed_invoice_vat_gbp` columns to `supplier_invoices`.
2. Replace the existing seven-argument `staff_save_supplier_invoice_header_review` signature with the extended signature in the same migration.
3. Preserve all existing RPC security/state/review-flag behaviour.
4. Add the `net + VAT = gross` tolerance guard to that RPC when all three values are present.
5. Extend the existing invoice-review server action to pass the new values.
6. Add Net and VAT inputs to the existing invoice OCR/header review form.
7. Expose lightweight read-only `ocr_invoice_net_gbp` and `ocr_invoice_vat_gbp` projections for the invoice-review queue; do not select full `ocr_raw_json` on that page.
8. Remove queue-page TypeScript traversal of `ocr_raw_json` and use the two numeric projections for defaults.
9. Update only the accepted Net/VAT source precedence in the latest `supplier_invoice_accounting_coding_totals_vw` definition.
10. Preserve the current accepted gross hierarchy and accounting-codable-line logic.
11. Reload the PostgREST schema cache.
12. Run focused regression checks before merge.

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

### Regression F — latest accounting-codable line semantics preserved

Active parked `non_physical_financial` lines and accounting adjustment lines must be counted exactly as before the change.

### Regression G — gross readiness preserved

`assertInvoiceReadyForCurrentApproval()` must produce the same result before and after the migration for invoices whose reviewed Net/VAT are null.

### Regression H — accounting readiness changes only when reviewed Net/VAT require it

`assertSupplierInvoiceAccountingCodingReady()` must retain every existing guard. Only the accepted Net/VAT input may differ when reviewed values are non-null.

### Regression I — RPC resolution

After migration and PostgREST schema reload, the existing invoice-review action must resolve exactly one `staff_save_supplier_invoice_header_review` RPC signature and save successfully.

### Regression J — same-evidence OCR fetch does not erase review override

Fetching/saving an already-created Mindee inference for the same supplier-invoice row must not clear `reviewed_invoice_net_gbp` or `reviewed_invoice_vat_gbp`.

### Regression K — invoice-review queue does not fetch raw OCR payload

The `/internal/invoice-review` query must not select `ocr_raw_json`.

It must receive only the lightweight OCR Net/VAT numeric projections required for form defaults. Existing filtering, row limit, navigation, and review behaviour must remain unchanged.

## Acceptance criteria

This addendum is complete only when all of the following are true:

1. Supervisor can edit Net and VAT on the existing OCR/header review page.
2. Reviewed Net and VAT are persisted separately from raw OCR JSON.
3. Reviewed header values are used by accounting reconciliation when present.
4. Raw Mindee evidence remains unchanged.
5. Header save rejects reviewed values that do not arithmetically reconcile within £0.01.
6. Legacy invoices with null reviewed Net/VAT retain existing behaviour.
7. Gross/total behaviour is not redesigned.
8. Existing gross/line/delivery/discount readiness remains unchanged.
9. Existing accounting coding guards remain unchanged.
10. Existing OCR endpoints and result persistence remain unchanged.
11. Existing refresh/revalidation paths remain unchanged.
12. Same-evidence OCR result fetch does not silently clear reviewed Net/VAT.
13. `/internal/invoice-review` does not fetch full `ocr_raw_json`; it consumes only lightweight OCR Net/VAT numeric projections for defaults.
14. No unrelated invoice, payment, Sage, discount, delivery, funding, shipment, exception, status, permission, navigation, or UI logic is changed.

## Scope lock

Implementation must remain limited to the smallest existing path:

```text
supplier_invoices
+ existing supplier invoice header-review RPC
+ existing invoice-review UI/action
+ lightweight read-only OCR Net/VAT projection for invoice-review defaults
+ supplier_invoice_accounting_coding_totals_vw
+ one scoped migration implementing the above
```

No other application behaviour may be modified.

Any proposed change outside that path requires separate explicit approval before implementation.
