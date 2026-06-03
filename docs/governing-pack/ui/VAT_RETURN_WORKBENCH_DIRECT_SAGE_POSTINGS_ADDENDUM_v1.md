# VAT Return Workbench Direct Sage Postings Addendum v1

## 0. Status

This addendum extends `VAT_RETURN_WORKBENCH_AND_SAGE_JOURNAL_CONTRACT_v1.md` for one specific reconciliation scenario:

```text
Sage contains purchase-side postings that are not represented by platform posting snapshots.
```

The controlling VAT workbench contract still controls the overall flow. This addendum governs how the platform identifies, reviews, accepts, and prevents repeat actioning of direct Sage postings not via the platform.

## 1. Goal

The VAT workbench must reconcile the platform VAT return pack to Sage natural VAT without hiding or duplicating values.

Direct Sage purchase-side postings must be handled as follows:

```text
1. Identify purchase invoices / purchase credit notes that exist in Sage.
2. Exclude any Sage document already linked to platform posting snapshots.
3. Present remaining Sage postings as “Direct Sage postings not on platform”.
4. Allow admin review in the Box 4 / Box 7 workbench.
5. Allow admin acceptance only when selected postings reconcile Box 4 and Box 7 to nil difference.
6. Save accepted postings as platform-recognised VAT source lines.
7. Do not create Sage adjustment journals for accepted direct Sage postings, because Sage already contains them.
8. Prevent accepted direct Sage postings from being re-raised as missing/unreconciled in later actions or reports.
```

## 2. Definitions

### Platform-controlled Sage posting

A Sage purchase-side document is platform-controlled when its Sage document id is found in platform posting evidence, including `sage_posting_snapshots` / `sage_posting_batch_rows` or successor posting evidence tables.

Platform-controlled examples include:

```text
supplier_goods_ap
shipper_ap
supplier_credit_note
```

These documents are not review candidates. They should be shown as covered by platform posting, or hidden from action lists.

### Direct Sage posting not on platform

A direct Sage posting not on platform is a Sage purchase invoice or purchase credit note that:

```text
exists in Sage;
is active/included for the relevant VAT period;
impacts Box 4 and/or Box 7;
is not linked to a platform posting snapshot or platform posting batch row;
has not already been accepted into the platform VAT return.
```

## 3. Required saved evidence per Sage document

For every direct Sage posting not on platform, the reconstruction snapshot must store enough evidence for audit and downstream controls.

Visible review fields:

```text
Sage document/ref
Supplier/contact name
Document date
Status
Ledger account/name
Tax rate/name
Line description if available
Net amount
VAT amount
Gross amount
Box 4 effect
Box 7 effect
Classification reason
```

Hidden technical fields:

```text
Sage document id
Sage API path / href if available
Sage connection/business context where available
Source type: purchase_invoice or purchase_credit_note
Platform-controlled flag
Platform-link source if matched
Snapshot id
```

The Sage API id should not be surfaced as a primary user-facing field unless needed in a technical audit section. The user-facing reference should be the Sage document/ref and supplier/contact name.

## 4. Box 4 / Box 7 workbench UX

The Box 4 / Box 7 tab on the VAT return pack detail page is the reconciliation workbench.

Route:

```text
/internal/accounting-vat/returns/[return_run_id]?tab=purchases
```

It must show:

```text
Platform Box 4 / Box 7
Sage natural Box 4 / Box 7
Difference
Platform-controlled Sage postings excluded from action
Direct Sage postings not on platform
Review-required Sage postings
Accepted direct Sage postings
Source VAT lines
```

Direct Sage posting table columns:

```text
Select
Document/ref
Supplier/contact
Document date
Status
Ledger
Tax rate
Net
VAT
Gross
Box 4 effect
Box 7 effect
Reason
Actions
```

Actions:

```text
Copy Sage ref
Open Sage / Open in Sage, only if a verified Sage UI deep link exists
View saved evidence, if needed
```

If a verified Sage UI deep link is not available, the safe action is:

```text
Open Sage app manually + copy Sage ref
```

No guessed Sage browser URLs should be committed.

## 5. Selection and nil-balance gate

The workbench must allow:

```text
Select all direct Sage postings
Unselect all
Selected Box 4 total
Selected Box 7 total
Remaining Box 4 difference
Remaining Box 7 difference
```

Proceed to final approval is enabled only when:

```text
remaining Box 4 difference is nil within £0.01;
remaining Box 7 difference is nil within £0.01;
no selected item is platform-controlled;
no selected item has unresolved review-required classification;
the relevant snapshot id is still current for the review context.
```

If only Box 4 or only Box 7 reconciles, the page must block progress.

## 6. Final approval page

The final approval page is not the review workbench. It is only a confirmation page.

It must show:

```text
Selected direct Sage postings not on platform
Before Platform Box 4 / Box 7
After Platform Box 4 / Box 7
Sage natural Box 4 / Box 7
Remaining difference = £0.00 / £0.00
```

Final action:

```text
Confirm approval into platform VAT return
```

It must not show a broad table of all Sage documents. It must not be used as the primary investigation screen.

## 7. Approval result

On approval, the platform must create source-linked VAT return lines for the accepted direct Sage posting.

Line-kind pattern:

```text
direct_sage_purchase_posting_not_via_platform_box4
direct_sage_purchase_posting_not_via_platform_box7
```

The source line must record:

```text
source_table = vat_return_sage_reconstruction_snapshots
source_id = snapshot_id
source_ref = Sage document/ref
source_json = visible + hidden Sage evidence
source_lineage_json = snapshot id, Sage document id/path, approval metadata
natural_sage_covered = true
adjustment_required = false
adjustment_reason = admin_accepted_direct_sage_posting_not_via_platform
status = active
```

Because Sage already contains the posting, accepted direct Sage postings must not create Sage VAT adjustment journals.

## 8. Downstream integration

Accepted direct Sage postings must integrate with the downstream VAT workbench flow:

```text
1. Platform expected Box 4 / Box 7 recalculates including accepted direct Sage source lines.
2. Sage natural Box 4 / Box 7 remains unchanged.
3. Difference reduces to nil where selected postings fully explain the difference.
4. Journal proposal preview must not create journals for accepted direct Sage postings.
5. Journal materialisation must ignore accepted direct Sage postings where natural_sage_covered = true and adjustment_required = false.
6. VAT source-line audit must show the direct Sage posting and admin approval evidence.
7. Submission evidence and match/lock must compare Sage submitted values to the platform pack including accepted direct Sage postings.
8. Prior locked returns must never be mutated; later discoveries must be current-period corrections linked back to the original evidence.
```

## 9. Reporting / no repeat actioning

Once accepted, a direct Sage posting must not continue to appear as:

```text
missing from platform;
unreconciled Sage-only posting;
needs action;
journal adjustment candidate.
```

It may appear only as:

```text
accepted direct Sage posting;
included in platform VAT return;
naturally covered by Sage;
admin approved.
```

## 10. Definition of done for this control

The direct Sage postings control is done only when:

```text
1. Platform-controlled Sage postings are excluded from action candidates.
2. Direct Sage postings not on platform are shown line-by-line with supplier/contact name.
3. Admin can inspect or copy enough Sage information to locate the document in Sage.
4. Selection totals and remaining Box 4 / Box 7 differences are visible.
5. Proceed to approval is blocked unless Box 4 and Box 7 reconcile to nil.
6. Approval creates source-linked VAT return lines, not Sage journals.
7. Accepted direct Sage postings stop appearing as unresolved in later workbench/reporting actions.
8. The approval page is confirmation-only.
9. The UI is clear enough for an admin to know the next action without SQL.
```
