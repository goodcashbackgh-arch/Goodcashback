# Supplier Invoice Rejection and Audience Status Addendum v1

Status: locked implementation addendum.

Purpose: prevent status drift after a supplier invoice is excluded from an order without requiring replacement evidence, and prevent pending internal accounting coding from being exposed as an importer evidence problem.

This addendum extends:

- `CANONICAL_AUDIENCE_STATUS_CONTRACT_v1.md`
- `PLATFORM_OPERATIONAL_STATUS_ENGINE_CONTRACT_v1.md`

## 1. Authoritative rejection classification

Two rejection outcomes must remain distinct.

### Corrected evidence required

```text
review_status = rejected_resubmit_required
rejection_requires_resubmission_yn = true or null
```

This state may drive:

```text
supplier_state = rejected_resubmit_required
importer_status_label = Evidence attention
importer_next_action = Upload corrected order evidence
```

Null is treated conservatively as requiring resubmission for legacy rows.

### Excluded with no resubmission required

```text
review_status = rejected_resubmit_required
rejection_requires_resubmission_yn = false
is_current_for_order = false
```

This invoice is retired from the active order evidence set.

It must not contribute to:

```text
supplier_invoice_count
approved_invoice_count
rejected_invoice_count
review_invoice_count
active supplier-line reconciliation totals
supplier_state = rejected_resubmit_required
importer evidence warnings
corrected-evidence actions
```

`blocked_from_sage_yn = true` on a retired invoice does not make it an active review blocker.

## 2. Canonical supplier aggregation

The canonical supplier-status aggregation must apply these rules.

```sql
COUNT(*) FILTER (
  WHERE COALESCE(si.review_status, '') <> 'superseded'
    AND NOT (
      si.review_status = 'rejected_resubmit_required'
      AND si.rejection_requires_resubmission_yn = false
    )
) AS supplier_invoice_count
```

```sql
COUNT(*) FILTER (
  WHERE si.review_status = 'rejected_resubmit_required'
    AND COALESCE(si.rejection_requires_resubmission_yn, true) = true
) AS rejected_invoice_count
```

```sql
COUNT(*) FILTER (
  WHERE COALESCE(si.review_status, '') <> 'superseded'
    AND NOT (
      si.review_status = 'rejected_resubmit_required'
      AND si.rejection_requires_resubmission_yn = false
    )
    AND (
      si.review_status IN ('pending_review', 'needs_action', 'duplicate_blocked')
      OR COALESCE(si.blocked_from_sage_yn, false) = true
    )
) AS review_invoice_count
```

No implementation may count an excluded-no-resubmission invoice merely because its generic `review_status` is `rejected_resubmit_required` or because it remains blocked from accounting posting.

## 3. Active reconciliation scope

Supplier-line reconciliation must use active invoice evidence only.

The active line scope must exclude invoices where any of the following is true:

```text
review_status = rejected_resubmit_required
review_status = duplicate_blocked
review_status = superseded
is_current_for_order = false
```

A line is not open merely because final accounting coding or supervisor approval is pending.

Active reconciliation is complete when every active supplier line is either:

- progressed as an eligible physical line;
- covered by an active non-physical financial resolution; or
- linked to an unresolved controlled exception.

## 4. Accounting coding remains internal

The following state is valid and expected:

```text
supplier_state = review_needed
reconciliation_state = complete
tracking_state = missing
active invoices remain pending_review
active invoices remain blocked_from_sage_yn = true
```

Meaning:

```text
Supplier evidence has been reconciled.
Internal accounting coding and final approval remain outstanding.
The importer does not need to replace or correct evidence.
The importer may proceed to tracking.
```

Pending accounting coding must not be presented to the importer as:

```text
Evidence attention
Resolve evidence issue
Upload corrected order evidence
```

## 5. Locked importer-facing precedence

The audience wrapper must evaluate completed reconciliation plus missing tracking before the broad `supplier_state = review_needed` presentation rule.

Required precedence:

```text
1. genuine remaining order balance action;
2. reconciliation complete and tracking missing;
3. supplier evidence missing;
4. corrected supplier evidence genuinely required;
5. other importer-owned evidence review action;
6. remaining canonical audience rules.
```

Where:

```text
reconciliation_state = complete
and tracking_state = missing
```

The importer-facing result must be exactly:

```text
importer_status_label = Invoice reconciled; tracking open
importer_next_action = Add tracking
```

This applies even when:

```text
supplier_state = review_needed
```

provided the review need is internal accounting coding or final approval rather than an importer-owned evidence defect.

## 6. Internal status remains strict

This addendum does not mark accounting coding or final approval complete.

Internal controls must continue to show the true state, including as applicable:

```text
pending_review
blocked_from_sage_yn = true
accounting coding required
final supervisor approval required
```

The importer-facing tracking action is an audience projection, not an accounting approval.

## 7. Prohibited fixes

Do not:

- change rejected or excluded invoice rows merely to make the status card look correct;
- set `blocked_from_sage_yn = false` before all accounting and approval gates pass;
- approve supplier invoices before accounting coding is complete;
- hard-code a specific order or invoice reference;
- hide a genuine resubmission-required rejection;
- treat every `pending_review` invoice as an importer evidence defect;
- patch only page-level wording while leaving canonical status functions wrong;
- allow a retired invoice to contribute supplier lines, totals or review blockers.

## 8. Required implementation points

The permanent implementation must correct the canonical read-model chain, including:

```text
internal_platform_order_status_v1_before_shipper_ap_blocker()
internal_platform_order_status_v1()
order_audience_status_pre_canonical_settlement_v1()
order_audience_status_v1()
```

A wrapper may delegate to corrected lower-level functions, but final canonical outputs must obey this addendum.

## 9. Locked acceptance proof

Proof order:

```text
order_ref = ORD-1784976429191
order_id = abf15b7b-771f-482f-9751-2af0ee0bcbb1
```

Expected active evidence:

```text
NIN-240726-A = pending_review, active
NIN-240726-B = pending_review, active
NIN-240726-C = pending_review, active
```

Expected retired evidence:

```text
NIN-240726-D
review_status = rejected_resubmit_required
rejection_requires_resubmission_yn = false
is_current_for_order = false
```

Proven canonical result:

```text
supplier_invoice_count = 3
approved_invoice_count = 0
rejected_invoice_count = 0
review_invoice_count = 3
excluded_no_resubmission_count = 1
supplier_state = review_needed
reconciliation_state = complete
total_active_line_count = 7
unresolved_active_line_count = 0
tracking_state = missing
```

Required importer result:

```text
Invoice reconciled; tracking open
Add tracking
```

The following assertions must all be true before release:

```text
d_excluded_from_status
line_reconciliation_complete
accounting_pending_remains_internal
importer_sees_reconciled_tracking_open
importer_next_action_is_add_tracking
all_expected_assertions_pass
```

## 10. Regression cases

At minimum, acceptance tests must cover:

1. Excluded-no-resubmission invoice plus active pending invoices.
2. Genuine rejected invoice requiring corrected evidence.
3. Reconciled active invoices awaiting accounting coding with tracking missing.
4. Reconciled and coded invoices awaiting final internal approval.
5. Missing supplier evidence.
6. Incomplete supplier-line reconciliation.
7. Mixed rejected invoices with different resubmission classifications.
8. Legacy rejected row with null classification, treated conservatively as resubmission required.

## 11. Release rule

A release is blocked if an invoice explicitly excluded with no resubmission required causes either:

```text
supplier_state = rejected_resubmit_required
```

or:

```text
Upload corrected order evidence
```

A release is also blocked if completed supplier reconciliation plus missing tracking is shown as an importer evidence problem solely because accounting coding remains internal and pending.
