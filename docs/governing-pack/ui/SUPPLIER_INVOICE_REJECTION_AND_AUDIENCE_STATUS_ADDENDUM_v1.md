# Supplier Invoice Rejection and Importer Status Addendum v1

Status: locked final implementation addendum.

Purpose: define the permanent canonical read-model repair for the importer-facing status regression introduced by the exceeded-order-amount and supplier-invoice rejection feature.

This addendum extends:

- `CANONICAL_AUDIENCE_STATUS_CONTRACT_v1.md`
- `PLATFORM_OPERATIONAL_STATUS_ENGINE_CONTRACT_v1.md`

## 1. Final governing decision

The permanent fix is not a page-level wording patch and not an importer-only masking overlay.

The final implementation must repair the canonical supplier status and reconciliation states first, then allow the canonical importer audience projection to consume those corrected states.

The required source-of-truth chain is:

```text
supplier invoice classification
    -> active supplier invoice aggregation
    -> active supplier-line reconciliation
    -> internal_platform_order_status_v1()
    -> order_audience_status_v1()
    -> importer dashboard and order operations UI
```

Both importer pages must display the same canonical audience result without local stale-status overrides.

## 2. Proven production defect

Production diagnostic for:

```text
order_ref = ORD-1784976429191
order_id = abf15b7b-771f-482f-9751-2af0ee0bcbb1
```

proved:

```text
all_invoice_count = 4
active_invoice_count = 3
excluded_no_resubmission_count = 1
genuine_resubmission_required_count = 0
```

The retired invoice is:

```text
invoice_ref = NIN-240726-D
review_status = rejected_resubmit_required
rejection_requires_resubmission_yn = false
is_current_for_order = false
blocked_from_sage_yn = true
```

The three active invoices are current and pending internal review.

The same diagnostic proved:

```text
active_line_count = 7
progressed_physical_line_count = 4
resolved_non_physical_line_count = 3
open_dispute_line_count = 0
genuinely_unresolved_line_count = 0
```

Despite that, the canonical read model returned:

```text
supplier_state = rejected_resubmit_required
reconciliation_state = incomplete
tracking_state = missing
```

and the canonical importer audience result returned:

```text
Invoice reconciliation open
Continue invoice reconciliation
```

The correct canonical states for the proven supplier evidence position are:

```text
supplier_state = review_needed
reconciliation_state = complete
tracking_state = missing
```

The correct importer result is:

```text
Invoice reconciled; tracking open
Add tracking
```

## 3. Scope

In scope:

```text
canonical active supplier-invoice aggregation
canonical active supplier-line reconciliation
canonical supplier_state
canonical reconciliation_state
importer audience precedence
removal of importer page-level stale-status compensation
alignment of importer status displays to one canonical source
```

Out of scope:

```text
customer status or actions
shipper status or actions
supervisor workflow or actions
funding status, calculations or payment allocation
initial-payment badge wording
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
audit banner wording
```

No unrelated workflow, audience, financial calculation or payment presentation may be changed.

## 4. Authoritative rejection classification

### 4.1 Genuine corrected evidence required

```text
review_status = rejected_resubmit_required
rejection_requires_resubmission_yn = true or null
is_current_for_order = true
```

Null is treated conservatively as requiring resubmission for legacy rows.

This state may contribute to:

```text
rejected_invoice_count
supplier_state = rejected_resubmit_required
importer_status_label = Evidence attention
importer_next_action = Upload corrected order evidence
```

### 4.2 Excluded with no resubmission required

```text
review_status = rejected_resubmit_required
rejection_requires_resubmission_yn = false
is_current_for_order = false
```

This invoice remains available for audit history but is retired from the active order evidence set.

It must not contribute to:

```text
supplier_invoice_count
approved_invoice_count
rejected_invoice_count
review_invoice_count
active supplier-line totals
active unresolved-line totals
supplier_state = rejected_resubmit_required
importer evidence warnings
corrected-evidence actions
```

`blocked_from_sage_yn = true` on a retired invoice does not make it an active supplier or importer blocker.

## 5. Canonical active-invoice predicate

The same predicate must govern supplier counts and supplier-line reconciliation:

```sql
COALESCE(si.is_current_for_order, true) = true
AND COALESCE(si.review_status, '') NOT IN (
  'superseded',
  'duplicate_blocked'
)
AND NOT (
  si.review_status = 'rejected_resubmit_required'
  AND si.rejection_requires_resubmission_yn = false
)
```

A historical invoice must not re-enter active status because its stored review status remains rejection-shaped or because it remains blocked from accounting posting.

## 6. Canonical supplier aggregation

### 6.1 Active supplier invoice count

```sql
COUNT(*) FILTER (
  WHERE COALESCE(si.is_current_for_order, true) = true
    AND COALESCE(si.review_status, '') NOT IN (
      'superseded',
      'duplicate_blocked'
    )
    AND NOT (
      si.review_status = 'rejected_resubmit_required'
      AND si.rejection_requires_resubmission_yn = false
    )
) AS supplier_invoice_count
```

### 6.2 Genuine resubmission-required count

```sql
COUNT(*) FILTER (
  WHERE COALESCE(si.is_current_for_order, true) = true
    AND si.review_status = 'rejected_resubmit_required'
    AND COALESCE(si.rejection_requires_resubmission_yn, true) = true
) AS rejected_invoice_count
```

### 6.3 Active review count

```sql
COUNT(*) FILTER (
  WHERE COALESCE(si.is_current_for_order, true) = true
    AND COALESCE(si.review_status, '') NOT IN (
      'superseded',
      'duplicate_blocked'
    )
    AND NOT (
      si.review_status = 'rejected_resubmit_required'
      AND si.rejection_requires_resubmission_yn = false
    )
    AND (
      si.review_status IN ('pending_review', 'needs_action')
      OR COALESCE(si.blocked_from_sage_yn, false) = true
    )
) AS review_invoice_count
```

The order-level supplier state must then be derived from these corrected active counts.

For the acceptance fixture:

```text
supplier_invoice_count = 3
rejected_invoice_count = 0
review_invoice_count = 3
supplier_state = review_needed
```

## 7. Canonical supplier-line reconciliation

Supplier-line reconciliation must use lines belonging only to active invoices under section 5.

An active line is reconciled when one of the following is true:

```text
eligible physical line progressed
active non_physical_financial resolution exists
active controlled dispute/exception link exists
```

The unresolved-line predicate is therefore conceptually:

```sql
physical progression is false
AND active non-physical financial resolution does not exist
AND active controlled dispute/exception does not exist
```

A line is not unresolved merely because:

```text
supplier invoice review is pending
accounting coding is incomplete
blocked_from_sage_yn = true
final supervisor approval is pending
```

For the acceptance fixture:

```text
active_line_count = 7
progressed_physical_line_count = 4
resolved_non_physical_line_count = 3
genuinely_unresolved_line_count = 0
reconciliation_state = complete
```

## 8. Canonical internal status

The canonical internal function must expose the corrected supplier and reconciliation states while preserving unrelated internal truth.

Required result for the acceptance fixture:

```text
supplier_state = review_needed
reconciliation_state = complete
tracking_state = missing
funding_state = incomplete
current_stage = funding_incomplete
current_stage_label = Initial payment incomplete
next_action = Match/apply initial funding
```

This is not contradictory.

The supplier evidence can be reconciled while funding and internal accounting controls remain incomplete.

No funding, payment, accounting, Sage, settlement or approval state is made complete or reworded by this addendum.

## 9. Importer audience projection

The importer audience projection must use corrected canonical states.

Required importer precedence:

```text
1. genuine importer-owned balance action
2. exception or hold requiring importer action
3. genuine corrected supplier evidence required
4. active supplier reconciliation incomplete
5. active supplier reconciliation complete and tracking missing
6. remaining canonical importer rules
```

Where:

```text
genuine resubmission-required count = 0
reconciliation_state = complete
tracking_state = missing
no higher-priority importer-owned action exists
```

return exactly:

```text
importer_status_label = Invoice reconciled; tracking open
importer_next_action = Add tracking
```

An internal:

```text
supplier_state = review_needed
```

must not be translated into an importer evidence defect when the remaining review is internal accounting or approval work.

## 10. UI source-of-truth alignment

After the canonical SQL repair:

- `app/importer/page.tsx` must display `order_audience_status_v1()` directly;
- `app/importer/orders/[order_id]/operations/page.tsx` must display the same canonical importer label and action;
- the dashboard local stale-reconciliation override based on raw order status must be removed;
- no page may infer reconciled status from `orders.status = partially_progressed`;
- no page may override canonical reconciliation using a local line count that differs from the canonical active-invoice predicate.

The following importer status surfaces must agree:

```text
importer dashboard status
importer dashboard next action
order operations header status
order operations summary status
order operations next action
```

This requirement does not include the Initial payment card or any funding badge. Those remain governed by the existing funding presentation contract and are unchanged by this fix.

## 11. Audit banner

The informational banner:

```text
Rejected evidence kept for audit
```

may remain on the importer operations page when a retired rejected invoice exists alongside current evidence.

It is informational only and its wording is unchanged by this addendum.

It must not control:

```text
supplier_state
reconciliation_state
importer_status_label
importer_next_action
```

## 12. Temporary overlay disposition

The migration:

```text
20260726_importer_excluded_supplier_rejection_status_overlay_v1.sql
```

is a temporary importer presentation overlay.

It must not be treated as the final source of truth because it does not repair:

```text
canonical supplier_state
canonical reconciliation_state
internal progress gates
```

The final canonical migration must supersede its symptom-masking behaviour.

After the canonical repair is deployed and verified, the audience wrapper may either:

- be replaced by the final canonical implementation; or
- remain only as a pass-through wrapper with no independent stale-state inference.

## 13. Required implementation points

The final implementation must correct the deployed canonical function chain as applicable:

```text
internal_platform_order_status_v1_before_shipper_ap_blocker()
internal_platform_order_status_v1()
internal_platform_order_progress_v1()
order_audience_status_pre_canonical_settlement_v1()
order_audience_status_v1()
```

The exact wrapper layer may vary according to the deployed function chain, but the resulting canonical states and audience output must satisfy this addendum.

No data mutation is required for the affected order or supplier invoices.

## 14. Prohibited fixes

Do not:

- alter rejected or excluded invoice rows merely to make UI text correct;
- alter the exceeded-order-amount calculation;
- alter funding, payment, balance, settlement, Sage or VAT calculations;
- alter Initial payment badge wording or funding presentation;
- approve supplier invoices before accounting controls pass;
- set `blocked_from_sage_yn = false` prematurely;
- hard-code an order or invoice UUID;
- hide a genuine current resubmission-required rejection;
- treat every pending internal review as an importer evidence defect;
- patch only React wording while canonical SQL remains wrong;
- retain a dashboard-only raw-status override after canonical repair;
- count lines from retired invoices in active reconciliation;
- change the audit banner wording as part of this fix;
- change customer, shipper or supervisor outputs as part of this fix.

## 15. Acceptance scenario

Order:

```text
order_ref = ORD-1784976429191
order_id = abf15b7b-771f-482f-9751-2af0ee0bcbb1
```

Active invoices:

```text
NIN-240726-A = pending_review, current
NIN-240726-B = pending_review, current
NIN-240726-C = pending_review, current
```

Retired invoice:

```text
NIN-240726-D
review_status = rejected_resubmit_required
rejection_requires_resubmission_yn = false
is_current_for_order = false
```

Active line position:

```text
active_line_count = 7
progressed_physical_line_count = 4
resolved_non_physical_line_count = 3
genuinely_unresolved_line_count = 0
```

Required canonical result:

```text
supplier_invoice_count = 3
rejected_invoice_count = 0
review_invoice_count = 3
excluded_no_resubmission_count = 1
supplier_state = review_needed
reconciliation_state = complete
tracking_state = missing
```

Required importer result:

```text
Invoice reconciled; tracking open
Add tracking
```

Required internal result remains independently truthful:

```text
funding_state = incomplete
current_stage = funding_incomplete
next_action = Match/apply initial funding
```

Existing funding and payment presentation remains unchanged.

## 16. Regression requirements

At minimum, tests must cover:

1. Retired no-resubmission rejection plus active pending-review invoices.
2. Genuine current rejection requiring replacement evidence.
3. Physical lines plus active non-physical financial resolutions.
4. A genuinely unresolved active line.
5. Lines belonging to retired invoices.
6. Mixed rejected invoices with different resubmission classifications.
7. Legacy null resubmission classification treated conservatively.
8. Canonical internal status and canonical audience status agreement.
9. Importer dashboard and Operations page status agreement.
10. Removal of raw-order-status UI compensation.
11. Initial payment badge and funding presentation unchanged.
12. Audit banner wording unchanged.
13. Customer, shipper and supervisor outputs unchanged.
14. Exceeded-order-amount, funding and balance calculations unchanged.

## 17. Release rule

A release is blocked if any retired no-resubmission invoice causes:

```text
supplier_state = rejected_resubmit_required
```

A release is blocked if active supplier lines are fully reconciled but canonical status returns:

```text
reconciliation_state = incomplete
```

A release is blocked if the canonical importer result for completed reconciliation plus missing tracking is not:

```text
Invoice reconciled; tracking open
Add tracking
```

A release is blocked if importer status surfaces disagree with each other or require a raw-order-status override to appear correct.

A release is blocked if this patch changes the Initial payment badge, funding presentation, audit banner wording, customer, shipper, supervisor, exceeded-order-amount, funding, balance, settlement, Sage, VAT or accounting approval behaviour.
