# Supplier Invoice Header Net/VAT Review Addendum v1

## Status

This addendum is the governing source for the supplier invoice header Net/VAT correction build.

The scope is deliberately narrow. It extends the existing supplier invoice OCR/header-review path so an authorised supervisor can correct invoice-header Net and VAT without rewriting raw OCR evidence, weakening accounting guards, or introducing a second workflow.

No implementation outside the scope lock at the end of this document is authorised.

## Proven defect

Proven supplier invoice:

```text
NIN-300726-A
supplier_invoice_id = f390207f-02a3-4fae-b17b-879725203b61
```

Accepted gross:

```text
£239.99
```

Raw Mindee header fields:

```text
total_net    = £239.99   -- wrong
total_tax    = £40.00    -- correct
total_amount = £3,599.85 -- wrong
```

The tax object also contained:

```text
taxes[0].base   = £199.99
taxes[0].amount = £40.00
taxes[0].rate   = 20%
```

The accounting-coded invoice lines correctly reconcile to:

```text
Net   £199.99
VAT    £40.00
Gross £239.99
```

The defect is therefore not line accounting. The defect is that the existing accepted-header Net/VAT path had no persisted supervisor-reviewed values and therefore reconciliation continued to consume bad raw OCR header values.

## Governing source rule

Raw OCR remains immutable evidence of what Mindee returned.

Supervisor-reviewed header values become the accepted operational values only after explicit save through the existing header-review action.

Accepted source priority is:

```text
reviewed header value
-> raw OCR value
-> existing fallback, where one already exists
```

Do not rewrite `ocr_raw_json` to make OCR appear correct after review.

## Existing workflow remains the workflow

The correction point remains:

```text
/internal/invoice-review
```

The existing `Save header correction` form is extended with:

```text
Net
VAT
Total
```

No new page, review status, action endpoint, approval flow, or accounting workflow is introduced.

The existing write chain remains:

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
existing reconciliation/readiness/approval flow
```

The existing action revalidation paths remain unchanged:

```text
/internal/invoice-review
/internal/supplier-draft-ready
/internal/evidence/{orderId}
/importer/orders/{orderId}/operations
/importer/reconciliation/{orderId}
```

## OCR ingestion remains unchanged

The OCR path remains separate:

```text
Mindee
  ↓
staff_save_mindee_invoice_ocr_result
  ↓
ocr_raw_json + OCR lines + review flags
```

This build does not change:

- Mindee model selection
- enqueue endpoint
- polling
- inference fetch
- OCR result persistence
- OCR line creation
- OCR flags
- PDF evidence
- same-evidence fetch semantics

An ordinary fetch/save of the same Mindee inference for the same supplier-invoice row must not clear an already saved reviewed Net/VAT override.

A replacement invoice remains a separate supplier-invoice evidence row under the existing resubmission flow. Reviewed Net/VAT must not be copied to replacement evidence.

## Data-model extension

Add exactly two nullable writable columns to `public.supplier_invoices`:

```text
reviewed_invoice_net_gbp numeric(12,2) NULL
reviewed_invoice_vat_gbp numeric(12,2) NULL
```

No backfill is authorised.

No new table is required.

The existing reviewed gross/total path remains:

```text
supplier_invoices.ocr_invoice_total_gbp
```

Do not redesign gross storage and do not move gross into `supplier_invoice_financial_summary`.

## Header-review RPC extension

The existing RPC name remains:

```text
public.staff_save_supplier_invoice_header_review
```

Pre-build live signature:

```text
staff_save_supplier_invoice_header_review(uuid,text,text,text,date,numeric,text)
```

Extended signature adds:

```text
p_reviewed_invoice_net_gbp numeric DEFAULT NULL
p_reviewed_invoice_vat_gbp numeric DEFAULT NULL
```

The old seven-argument signature must be removed before creating the extended defaulted signature so PostgREST does not have ambiguous overloads.

After replacement:

```text
NOTIFY pgrst, 'reload schema'
```

The existing RPC security/state behaviour remains unchanged:

- active admin/supervisor required
- existing rejected/superseded/duplicate-blocked protections remain
- `review_status = 'pending_review'`
- `blocked_from_sage_yn = true`
- `is_current_for_order = false`
- reviewer and review time are stamped
- existing review-note behaviour remains
- the same open/under-review review flags are resolved

The only new writes are the two reviewed Net/VAT columns.

## Header arithmetic guard

When Net, VAT and Total are all present, save must fail closed unless:

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

The invalid case must not partially persist reviewed values.

Net and VAT remain non-negative optional money fields using the existing server-side money parser.

This guard does not change line coding, tax rates, discount treatment, delivery treatment, quantity logic, or invoice state.

## Lightweight OCR header read contract

The invoice-review queue must not fetch complete `supplier_invoices.ocr_raw_json` payloads merely to prefill Net and VAT.

The queue can load up to 100 invoice rows, so transferring up to 100 complete Mindee JSON documents is unnecessary.

Instead, the existing accounting totals view exposes exactly two lightweight read-only projections:

```text
ocr_invoice_net_gbp numeric
ocr_invoice_vat_gbp numeric
```

They are derived directly from the immutable OCR JSON:

```text
ocr_invoice_net_gbp = ocr_raw_json #>> '{inference,result,fields,total_net,value}'
ocr_invoice_vat_gbp = ocr_raw_json #>> '{inference,result,fields,total_tax,value}'
```

They are not new persisted OCR columns and are not a second OCR source of truth.

The review page must therefore use:

```text
Net default = reviewed_invoice_net_gbp ?? ocr_invoice_net_gbp
VAT default = reviewed_invoice_vat_gbp ?? ocr_invoice_vat_gbp
```

The page must not select `ocr_raw_json`, and any TypeScript helper whose sole purpose is traversing the JSON on this queue page must be removed.

The existing queue limit, filtering, routing, permissions, buttons, navigation and review behaviour remain unchanged except for the narrow fail-closed protection below.

## OCR header projection read failure rule

The lightweight OCR Net/VAT projection is a read dependency of the existing header-correction form. Its database query must not fail silently.

The page must distinguish these two states:

### Normal pre-OCR/null state

An invoice can legitimately appear in `/internal/invoice-review` before Mindee OCR has been run or before an OCR result has been saved.

In that state:

```text
ocr_invoice_net_gbp = NULL
ocr_invoice_vat_gbp = NULL
```

is valid and is **not** an error.

The invoice-review page must continue to load normally, the existing OCR start/fetch controls must remain available according to their existing rules, and no warning is required solely because these projected values are null.

Normal lifecycle:

```text
invoice uploaded
→ invoice may appear in /internal/invoice-review
→ OCR Net/VAT can legitimately be null
→ supervisor can start/fetch OCR using the existing controls
→ Mindee result is saved
→ page reloads
→ projected OCR Net/VAT are available for review
```

### Actual projection-query failure

If the database request for:

```text
supplier_invoice_id
ocr_invoice_net_gbp
ocr_invoice_vat_gbp
```

fails, that is a different state from legitimate null OCR values.

The page must capture the Supabase error from that lightweight query.

On an actual query error:

```text
page remains available for inspection
existing invoice/PDF/status/routing/OCR controls remain available
clear red warning is displayed
Save header correction is disabled
no header correction is submitted using unavailable OCR defaults
```

Required warning meaning:

```text
Invoice Net/VAT OCR values are temporarily unavailable.
Do not save a header correction until this is resolved.
```

The fail-closed block applies only to the existing `Save header correction` button. It must not disable:

- Start document extraction
- Fetch/save extraction result
- Open invoice
- Staff detail
- Open reconciliation
- Reject and request corrected invoice
- Exclude invoice — no corrected invoice required

This is an application read-safety control only. It does not change the migration, database write contract, OCR lifecycle, reconciliation logic, approval logic, or any downstream state.

## Accounting totals view contract

The existing object remains:

```text
public.supplier_invoice_accounting_coding_totals_vw
```

Its latest accounting-codable-line semantics must remain intact, including:

- progressed physical accounting-codable lines
- active `non_physical_financial` parked lines
- accounting adjustment lines

Accepted Net becomes:

```text
COALESCE(
  supplier_invoices.reviewed_invoice_net_gbp,
  raw OCR total_net,
  existing net fallback
)
```

Accepted VAT becomes:

```text
COALESCE(
  supplier_invoices.reviewed_invoice_vat_gbp,
  raw OCR total_tax
)
```

Accepted gross remains exactly the existing hierarchy:

```text
supplier_invoices.ocr_invoice_total_gbp
-> raw OCR total_amount
-> supplier_invoice_financial_summary.invoice_total_gbp
```

No other reconciliation formula or line-inclusion rule is authorised to change.

## Live production dependency evidence gathered before build

The database dependency checks were run before changing the view implementation.

### Dependent views/materialized views

Result:

```text
no rows
```

Therefore no dependent view or materialized view was found on `public.supplier_invoice_accounting_coding_totals_vw`.

### Functions/procedures referencing the totals view

Exactly two were returned:

```text
public.internal_supplier_goods_ap_ready_rows_pre_signed_nonphysical_v1()
public.staff_bulk_save_supplier_invoice_line_accounting_codes(
  p_supplier_invoice_id uuid,
  p_lines jsonb
)
```

These functions are not to be edited by this build.

Their existing referenced columns must continue to exist with compatible names/types.

### Live view column shape

The production view was proven to have exactly 19 existing columns:

```text
 1 supplier_invoice_id                    uuid
 2 order_id                               uuid
 3 accepted_invoice_gross_gbp             numeric
 4 total_coded_net_gbp                    numeric
 5 total_coded_vat_gbp                    numeric
 6 total_coded_gross_gbp                  numeric
 7 adjustment_gross_gbp                   numeric
 8 progressed_line_count                  integer
 9 coded_line_count                       integer
10 adjustment_line_count                  integer
11 all_progressed_lines_coded_yn          boolean
12 gross_reconciled_to_invoice_yn         boolean
13 gross_variance_gbp                     numeric
14 accepted_invoice_net_gbp               numeric
15 accepted_invoice_vat_gbp               numeric
16 net_reconciled_to_invoice_yn           boolean
17 vat_reconciled_to_invoice_yn           boolean
18 net_variance_gbp                       numeric
19 vat_variance_gbp                       numeric
```

The migration must preserve columns 1-19 in exactly this name/type/order sequence.

Only two columns are appended:

```text
20 ocr_invoice_net_gbp numeric
21 ocr_invoice_vat_gbp numeric
```

## Dependency-safe migration rule

Because the live dependency and column-shape checks are now known, the totals view must be changed using:

```text
CREATE OR REPLACE VIEW public.supplier_invoice_accounting_coding_totals_vw AS ...
```

The migration must not use:

```text
DROP VIEW
CASCADE
```

for this view.

This preserves the existing view identity and avoids unnecessary dependency churn while keeping every existing output column compatible and appending only the two new read-only OCR projections.

The two known function consumers above remain untouched.

## Deliberate downstream effect

Only consumers of:

```text
accepted_invoice_net_gbp
accepted_invoice_vat_gbp
```

see a different value when a non-null supervisor-reviewed override exists.

That is the intended behavioural change.

For legacy invoices where:

```text
reviewed_invoice_net_gbp IS NULL
reviewed_invoice_vat_gbp IS NULL
```

accepted Net/VAT must behave exactly as before.

## Existing readiness guards remain intact

`assertSupplierInvoiceAccountingCodingReady()` remains unchanged and continues to require the existing Net/VAT/Gross reconciliation controls.

`assertInvoiceReadyForCurrentApproval()` remains unchanged and continues to independently enforce the existing gross/line/delivery/discount support rules.

The build corrects the accepted header source; it does not weaken a gate.

## Areas explicitly outside the blast radius

Do not change:

- supplier invoice line accounting codes
- discount approval/treatment
- delivery approval/treatment
- VAT-rate selection
- posting accounts/nominal codes
- supplier payment allocation
- supplier payment readiness except through existing invoice approval state
- DVA reconciliation
- importer/customer funding
- bundle limits
- shipment allocation
- tracking
- customer sales
- Sage payload construction
- Sage posting routes
- VAT source generation logic
- exception handling architecture
- invoice-current selection rules
- permissions
- navigation
- unrelated UI labels
- `supplier_invoice_financial_summary` semantics

Existing downstream consumers continue to use the same totals view and the same columns they already consume.

## Required implementation sequence

1. Add the two nullable reviewed Net/VAT columns.
2. Replace the old seven-argument header-review RPC with the extended signature.
3. Preserve the existing RPC security/state/review-flag behaviour.
4. Add the Net + VAT = Total tolerance guard.
5. Keep the existing invoice-review server action and pass the two reviewed values.
6. Keep the existing invoice-review form and add Net/VAT fields only.
7. Use `CREATE OR REPLACE VIEW`, preserving existing columns 1-19 exactly.
8. Append `ocr_invoice_net_gbp` and `ocr_invoice_vat_gbp` as columns 20-21.
9. Preserve current accepted gross and accounting-codable-line semantics.
10. Remove `ocr_raw_json` from the invoice-review queue query.
11. Read only the two lightweight OCR Net/VAT columns from the totals view for the loaded invoice IDs.
12. Capture an actual lightweight projection-query error; do not treat legitimate null pre-OCR values as an error.
13. On an actual projection-query error, show the scoped warning and disable only `Save header correction`.
14. Preserve the existing 100-row queue limit, filtering, navigation, status logic and all other actions.
15. Reload the PostgREST schema cache.
16. Run focused regression checks before merge.

## Required regression checks

### A — proven bad OCR invoice

Save:

```text
Net   £199.99
VAT    £40.00
Total £239.99
```

Expected:

```text
accepted_invoice_net_gbp      = 199.99
accepted_invoice_vat_gbp      = 40.00
accepted_invoice_gross_gbp    = 239.99
net_variance_gbp               = 0.00
vat_variance_gbp               = 0.00
gross_variance_gbp             = 0.00
net_reconciled_to_invoice_yn   = true
vat_reconciled_to_invoice_yn   = true
gross_reconciled_to_invoice_yn = true
```

Raw OCR must retain the original bad values.

### B — legacy invoice

With reviewed Net/VAT both null, accepted Net/VAT must equal the pre-build result.

### C — invalid arithmetic

Attempt:

```text
Net   £239.99
VAT    £40.00
Total £239.99
```

Expected:

```text
save rejected
no reviewed Net/VAT persistence
invoice remains pending_review
Sage remains blocked
```

### D — state preservation

A valid header save must not approve, post, set current, unblock Sage, or alter supplier invoice lines.

### E — line coding preservation

Existing coded lines for the proven invoice remain unchanged, including the existing goods/discount/delivery coding.

### F — accounting-codable-line preservation

Active parked `non_physical_financial` lines and accounting adjustment lines must be counted exactly as before.

### G — readiness preservation

For invoices with null reviewed Net/VAT, existing gross readiness and accounting readiness must remain unchanged.

### H — RPC resolution

After migration/schema reload, the application must resolve exactly one `staff_save_supplier_invoice_header_review` signature.

### I — OCR lifecycle

Fetching/saving the same Mindee evidence must not clear reviewed Net/VAT.

### J — lightweight queue read

`/internal/invoice-review` must not select `ocr_raw_json`.

It must read only:

```text
supplier_invoice_id
ocr_invoice_net_gbp
ocr_invoice_vat_gbp
```

from the totals view for the invoice IDs already loaded by the queue.

### K — view shape/dependency preservation

Post-migration view columns 1-19 must retain the proven live names/types/order, with only columns 20-21 appended.

The two known function consumers must remain unchanged and continue resolving their existing fields.

### L — legitimate pre-OCR null state

For an invoice that has not yet completed OCR, a successful projection query returning null OCR Net/VAT must not be treated as an error.

Expected:

```text
page loads normally
no projection-read warning solely because values are null
existing Start document extraction / Fetch-save extraction controls retain their existing behaviour
```

### M — actual projection-query failure

If the lightweight totals-view query itself returns an error:

```text
page remains available
red OCR Net/VAT availability warning is shown
Save header correction is disabled
no header correction can be submitted through that button
all unrelated inspection/OCR/reject/exclude/navigation controls remain unchanged
```

## Acceptance criteria

The build is complete only when:

1. Supervisor can edit Net and VAT on the existing invoice-review page.
2. Reviewed Net/VAT are stored separately from raw OCR.
3. Raw OCR remains immutable.
4. Header arithmetic is fail-closed within £0.01.
5. Accepted Net/VAT prefer reviewed values when present.
6. Legacy null-reviewed invoices preserve existing behaviour.
7. Gross behaviour is unchanged.
8. Existing line/discount/delivery/readiness controls are unchanged.
9. The view is changed with `CREATE OR REPLACE VIEW`, not DROP/CASCADE.
10. Existing live columns 1-19 remain compatible and in the same order.
11. Only read-only OCR Net/VAT columns 20-21 are appended.
12. The invoice-review queue no longer fetches complete `ocr_raw_json` payloads.
13. A successful lightweight query with null pre-OCR values is not treated as an error.
14. An actual lightweight projection-query failure is surfaced and disables only `Save header correction`.
15. Existing OCR start/fetch, reject/exclude, inspection, queue behaviour, routes, permissions and refresh paths remain unchanged.
16. The two known function consumers are not edited.
17. No unrelated payment, Sage, funding, shipment, exception, status, permission, navigation or UI logic is changed.

## Scope lock

Implementation is limited to:

```text
public.supplier_invoices
+ existing public.staff_save_supplier_invoice_header_review RPC
+ existing app/internal/invoice-review/actions.ts caller
+ existing app/internal/invoice-review/page.tsx UI/read path
+ public.supplier_invoice_accounting_coding_totals_vw
+ supabase/migrations/20260730_supplier_invoice_header_net_vat_review_v1.sql
+ this addendum
```

For this final fail-closed refinement, only these existing files are authorised to change:

```text
app/internal/invoice-review/page.tsx
docs/governing-pack/ui/SUPPLIER_INVOICE_HEADER_NET_VAT_REVIEW_ADDENDUM_v1.md
```

The current migration file is intentionally unchanged by this refinement.

No other application or database object may be modified without separate explicit approval.