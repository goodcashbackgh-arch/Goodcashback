# Supplier Invoice Rejection and Importer Status Addendum v1

Status: locked implementation addendum.

Purpose: correct a narrow importer-facing status regression introduced by the exceeded-order-amount and supplier-invoice rejection feature.

The regression occurs when an invoice is rejected and excluded from the order with no replacement evidence required, but the canonical importer status still treats that retired invoice as an active resubmission blocker.

This addendum extends:

- `CANONICAL_AUDIENCE_STATUS_CONTRACT_v1.md`
- `PLATFORM_OPERATIONAL_STATUS_ENGINE_CONTRACT_v1.md`

## 1. Scope

This addendum changes only the canonical supplier-status inputs and importer-facing audience projection required to remove the false evidence warning.

In scope:

```text
supplier invoice active-status aggregation
supplier-line reconciliation scope
importer status label
importer next action
```

Out of scope:

```text
customer status or actions
shipper status or actions
supervisor workflow or actions
funding calculations or payment allocation
exceeded-order-amount calculations
order balance calculations
shipment or package allocation
tracking workflow after tracking has been added
shipper AP
customer AR or settlement
Sage posting rules
VAT or compliance rules
invoice approval rules
accounting coding rules
```

No unrelated audience, workflow or calculation may be changed as part of this fix.

## 2. Regression cause

The exceeded-order-amount and rejection feature introduced a valid second rejection outcome:

```text
Exclude / No resubmission required
```

That outcome records:

```text
review_status = rejected_resubmit_required
rejection_requires_resubmission_yn = false
is_current_for_order = false
```

The row remains available for audit history, but it is retired from the active order evidence set.

The regression occurs because the canonical supplier aggregation still counts the generic rejection status without also checking whether resubmission is actually required and whether the invoice remains current for the order.

Broken behaviour:

```text
retired no-resubmission invoice
    -> supplier_state = rejected_resubmit_required
    -> importer_status_label = Evidence attention
    -> importer_next_action = Upload corrected order evidence
```

That importer message is false because the rejection decision explicitly says that no replacement evidence is required.

## 3. Authoritative rejection classification

The two rejection outcomes must remain distinct.

### 3.1 Corrected evidence required

```text
review_status = rejected_resubmit_required
rejection_requires_resubmission_yn = true or null
is_current_for_order = true
```

Null is treated conservatively as requiring resubmission for legacy rows.

This state may drive:

```text
supplier_state = rejected_resubmit_required
importer_status_label = Evidence attention
importer_next_action = Upload corrected order evidence
```

### 3.2 Excluded with no resubmission required

```text
review_status = rejected_resubmit_required
rejection_requires_resubmission_yn = false
is_current_for_order = false
```

This invoice is retained for audit history but retired from the active order evidence set.

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

`blocked_from_sage_yn = true` on a retired invoice does not make it an active importer evidence blocker.

## 4. Canonical active-invoice predicate

The same active-invoice predicate must be applied consistently to supplier counts and supplier-line reconciliation.

```sql
COALESCE(si.is_current_for_order, true) = true
AND COALESCE(si.review_status, '') <> 'superseded'
AND NOT (
  si.review_status = 'rejected_resubmit_required'
  AND si.rejection_requires_resubmission_yn = false
)
```

A retired invoice must not re-enter the active status set merely because its historical `review_status` remains `rejected_resubmit_required` or because it remains blocked from accounting posting.

## 5. Canonical supplier aggregation

### 5.1 Active supplier invoice count

```sql
COUNT(*) FILTER (
  WHERE COALESCE(si.is_current_for_order, true) = true
    AND COALESCE(si.review_status, '') <> 'superseded'
    AND NOT (
      si.review_status = 'rejected_resubmit_required'
      AND si.rejection_requires_resubmission_yn = false
    )
) AS supplier_invoice_count
```

### 5.2 Genuine resubmission-required rejection count

```sql
COUNT(*) FILTER (
  WHERE COALESCE(si.is_current_for_order, true) = true
    AND COALESCE(si.review_status, '') <> 'superseded'
    AND si.review_status = 'rejected_resubmit_required'
    AND COALESCE(si.rejection_requires_resubmission_yn, true) = true
) AS rejected_invoice_count
```

### 5.3 Active review count

```sql
COUNT(*) FILTER (
  WHERE COALESCE(si.is_current_for_order, true) = true
    AND COALESCE(si.review_status, '') <> 'superseded'
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

No implementation may count an excluded-no-resubmission invoice merely because its generic rejection status remains rejection-shaped.

## 6. Active supplier-line reconciliation scope

Supplier-line reconciliation must use active invoice evidence only.

Lines belonging to an invoice must be excluded when any of the following is true:

```text
is_current_for_order = false
review_status = rejected_resubmit_required and rejection_requires_resubmission_yn = false
review_status = duplicate_blocked
review_status = superseded
```

An active supplier line is reconciled when it is either:

- progressed as an eligible physical line;
- covered by an active non-physical financial resolution; or
- linked to an unresolved controlled exception.

A line is not open merely because final accounting coding or supervisor approval is pending.

## 7. Importer-only audience correction

This fix changes importer presentation only.

Pending accounting coding or final internal approval must remain visible to internal staff, but must not be translated into an importer evidence defect when supplier-line reconciliation is complete.

The importer audience wrapper must evaluate completed reconciliation plus missing tracking before the broad `supplier_state = review_needed` presentation rule.

Required precedence within importer presentation:

```text
1. genuine remaining importer-owned balance action
2. reconciliation complete and tracking missing
3. supplier evidence missing
4. corrected supplier evidence genuinely required
5. other importer-owned evidence review action
6. remaining canonical importer rules
```

Where:

```text
reconciliation_state = complete
tracking_state = missing
no genuine importer-owned evidence defect exists
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

provided the remaining review need is internal accounting coding or final approval rather than an importer-owned evidence defect.

This branch must not activate while:

```text
reconciliation_state = incomplete
```

An unfinished order must continue to follow the ordinary canonical importer workflow.

## 8. Internal truth remains unchanged

This addendum does not mark accounting coding, approval, funding or settlement complete.

Internal controls must continue to show the true state, including as applicable:

```text
pending_review
blocked_from_sage_yn = true
accounting coding required
final supervisor approval required
funding incomplete
reconciliation incomplete
```

The importer-facing tracking action is an audience projection only. It is not an accounting approval and does not change any internal gate.

## 9. No changes for other parties

No customer, shipper or supervisor status rule is modified by this addendum.

In particular:

- customer labels and actions remain unchanged;
- shipper labels and actions remain unchanged;
- supervisor workflow and actions remain unchanged;
- absence of a shipment package on an unfinished order is not treated as a defect by this addendum;
- this addendum does not define the importer status after tracking is no longer missing.

Any later change for those states requires separate evidence and a separate governing decision.

## 10. Required implementation points

The permanent implementation must correct the canonical read-model chain only where needed to produce the importer result:

```text
internal_platform_order_status_v1_before_shipper_ap_blocker()
internal_platform_order_status_v1()
order_audience_status_pre_canonical_settlement_v1()
order_audience_status_v1()
```

A wrapper may delegate to corrected lower-level functions, but the final canonical importer output must obey this addendum.

No page-level wording patch may substitute for correcting the canonical status functions.

## 11. Prohibited fixes

Do not:

- change rejected or excluded invoice rows merely to make the importer card look correct;
- alter the exceeded-order-amount calculation;
- alter order balance or funding calculations;
- set `blocked_from_sage_yn = false` before accounting and approval gates pass;
- approve supplier invoices before accounting coding is complete;
- hard-code a specific order or invoice reference;
- hide a genuine resubmission-required rejection;
- treat every `pending_review` invoice as an importer evidence defect;
- patch only importer page wording while leaving canonical status functions wrong;
- allow a retired invoice to contribute supplier lines, totals or review blockers;
- change customer, shipper or supervisor outputs as part of this fix.

## 12. Acceptance scenario

Order:

```text
order_ref = ORD-1784976429191
order_id = abf15b7b-771f-482f-9751-2af0ee0bcbb1
```

Active evidence:

```text
NIN-240726-A = pending_review, current
NIN-240726-B = pending_review, current
NIN-240726-C = pending_review, current
```

Retired evidence:

```text
NIN-240726-D
review_status = rejected_resubmit_required
rejection_requires_resubmission_yn = false
is_current_for_order = false
```

When the acceptance fixture has completed active supplier-line reconciliation and tracking remains missing, the required canonical result is:

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

Internal accounting review remains pending and unchanged.

The live order may still show `reconciliation_state = incomplete` before all active lines are reconciled. In that unfinished state, the tracking-open importer branch must not activate.

## 13. Regression cases

At minimum, acceptance tests must cover:

1. Excluded-no-resubmission invoice plus active pending-review invoices.
2. Genuine current rejected invoice requiring corrected evidence.
3. Reconciled active invoices awaiting accounting coding with tracking missing.
4. Incomplete supplier-line reconciliation.
5. Missing supplier evidence.
6. Mixed rejected invoices with different resubmission classifications.
7. Legacy rejected row with null classification, treated conservatively as resubmission required.
8. Verification that customer, shipper and supervisor outputs are unchanged by this patch.
9. Verification that exceeded-order-amount and balance calculations are unchanged.

## 14. Release rule

A release is blocked if an invoice explicitly excluded with no resubmission required causes either:

```text
supplier_state = rejected_resubmit_required
```

or:

```text
Upload corrected order evidence
```

A release is also blocked if completed active supplier reconciliation plus missing tracking is shown to the importer as an evidence problem solely because internal accounting review remains pending.

A release is blocked if this patch changes customer, shipper or supervisor status behaviour, exceeded-order-amount calculations, funding, balance, settlement, Sage, VAT or accounting approval rules.
