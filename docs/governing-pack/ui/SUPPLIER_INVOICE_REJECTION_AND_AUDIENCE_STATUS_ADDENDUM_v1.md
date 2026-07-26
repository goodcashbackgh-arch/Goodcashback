# Supplier Invoice Rejection and Importer Status Addendum v1

Status: locked final implementation addendum.

Purpose: govern the permanent canonical read-model repair for the importer-facing status regression introduced by excluded supplier-invoice rejection handling.

This addendum extends:

- `CANONICAL_AUDIENCE_STATUS_CONTRACT_v1.md`
- `PLATFORM_OPERATIONAL_STATUS_ENGINE_CONTRACT_v1.md`

## 1. Final governing decision

The permanent fix is canonical SQL plus removal of the importer dashboard's local stale-status compensation.

The source-of-truth chain is:

```text
supplier invoice classification
    -> active supplier invoice aggregation
    -> active supplier-line reconciliation
    -> internal_platform_order_status_v1()
    -> existing operator-safe audience chain
    -> order_audience_status_v1()
    -> importer dashboard and order operations UI
```

The outer audience function must not call the staff-only internal status function directly. It must preserve the deployed operator-safe proxy chain.

Both importer pages must display the same canonical audience result without raw-order-status inference or local reconciliation overrides.

## 2. Proven production acceptance fixture

```text
order_ref = ORD-1784976429191
order_id = abf15b7b-771f-482f-9751-2af0ee0bcbb1
```

Proven supplier evidence position:

```text
all_invoice_count = 4
active_invoice_count = 3
excluded_no_resubmission_count = 1
genuine_resubmission_required_count = 0

active_line_count = 7
progressed_physical_line_count = 4
resolved_non_physical_line_count = 3
genuinely_unresolved_line_count = 0
```

The retired invoice is audit-only:

```text
invoice_ref = NIN-240726-D
review_status = rejected_resubmit_required
rejection_requires_resubmission_yn = false
is_current_for_order = false
blocked_from_sage_yn = true
```

Required canonical result:

```text
supplier_state = review_needed
reconciliation_state = complete
tracking_state = missing
funding_state = incomplete
current_stage = funding_incomplete
```

Required importer result:

```text
importer_status_label = Invoice reconciled; tracking open
importer_next_action = Add tracking
```

## 3. Scope

In scope:

```text
active supplier-invoice aggregation
active supplier-line reconciliation
supplier_state
reconciliation_state
supplier-derived stale-stage repair
importer audience precedence
removal of dashboard stale-status compensation
alignment of importer status surfaces
```

Out of scope:

```text
customer and shipper status or actions
supervisor workflow
funding, payment allocation and payment badges
exceeded-order-amount calculations
balances, settlement and potential-credit calculations
shipment and package allocation
tracking workflow after tracking is added
shipper AP
Sage, VAT and accounting rules
supplier invoice approval rules
audit banner wording
```

No order, invoice, line, funding, payment, settlement, shipment, approval or accounting data is mutated by this repair.

## 4. Canonical active-invoice predicate

The same predicate governs supplier counts and supplier-line reconciliation:

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

A historical invoice must not re-enter active status because its stored review status remains rejection-shaped or because it remains blocked from Sage.

## 5. Supplier aggregation

The canonical implementation must calculate explicitly:

```text
active_invoice_count
approved_invoice_count
genuine_rejected_count
```

An invoice is explicitly approved only when:

```sql
si.review_status IN ('approved_current', 'ref_corrected_approved')
AND COALESCE(si.blocked_from_sage_yn, false) = false
```

Supplier state is derived conservatively:

```sql
CASE
  WHEN active_invoice_count = 0
    THEN 'missing'
  WHEN genuine_rejected_count > 0
    THEN 'rejected_resubmit_required'
  WHEN approved_invoice_count = active_invoice_count
    THEN 'approved_current'
  ELSE 'review_needed'
END
```

Unknown, mixed or pending active statuses must not fall through to approved.

A current rejection contributes to `genuine_rejected_count` only when:

```sql
si.review_status = 'rejected_resubmit_required'
AND COALESCE(si.rejection_requires_resubmission_yn, true) = true
AND COALESCE(si.is_current_for_order, true) = true
```

Null resubmission flags are treated conservatively as requiring resubmission.

## 6. Active supplier-line reconciliation

Only lines belonging to invoices under the active-invoice predicate are counted.

An active line is unresolved only when all of the following hold:

```text
physical progression is absent
active non_physical_financial resolution is absent
active controlled dispute link is absent
```

Pending invoice review, accounting coding, Sage blocking or final supervisor approval do not by themselves make a line unresolved.

The existing zero-line contract is preserved exactly:

```sql
CASE
  WHEN active_line_count = 0
    THEN 'not_started'
  WHEN unresolved_active_line_count = 0
    THEN 'complete'
  ELSE 'incomplete'
END
```

An invoice with no active lines must not be marked complete.

## 7. Internal status repair

`internal_platform_order_status_v1()` remains staff-only.

The final implementation wraps the currently deployed internal spine and changes only:

```text
supplier_state
reconciliation_state
supplier-derived stale current-stage fields
```

All unrelated values pass through unchanged.

Stage repair is permitted only when the previous stage is one of:

```text
supplier_evidence_rejected
supplier_evidence_review_needed
supplier_reconciliation_incomplete
```

The corrected stage is selected in this order:

```text
genuine resubmission required -> supplier_evidence_rejected
active reconciliation incomplete -> supplier_reconciliation_incomplete
active supplier review needed -> supplier_evidence_review_needed
active reconciliation complete and tracking missing -> tracking_missing
otherwise preserve current stage
```

A higher-priority stage such as `exception_or_hold_open` or `funding_incomplete` must not be replaced.

For the acceptance fixture, `current_stage = funding_incomplete` remains unchanged even though supplier reconciliation is complete.

## 8. Audience-safe function chain

The deployed audience chain already contains an operator-safe SECURITY DEFINER proxy that establishes an active staff auth context before invoking the staff-only internal spine.

The final outer `order_audience_status_v1(uuid)` wrapper must consume:

```sql
public.order_audience_status_pre_importer_excluded_rejection_fix_v1(p_order_id)
```

It must not invoke `internal_platform_order_status_v1()` directly.

Corrected supplier and reconciliation values flow naturally through the existing audience-safe chain after the internal spine is repaired.

Customer and shipper columns pass through unchanged.

## 9. Importer precedence

Required precedence:

```text
1. genuine importer-owned final balance action
2. exception or hold requiring importer action
3. genuine current corrected supplier evidence required
4. active supplier reconciliation incomplete
5. active supplier reconciliation complete and tracking missing
6. remaining canonical importer rules
```

The outer importer projection may return:

```text
Invoice reconciliation open
Continue invoice reconciliation
```

only when no higher-priority balance, exception/hold or genuine current rejection exists.

It may return:

```text
Invoice reconciled; tracking open
Add tracking
```

only when:

```text
canonical_balance_due_gbp <= 0.01
internal_current_stage <> exception_or_hold_open
genuine_resubmission_required_count = 0
reconciliation_state = complete
tracking_state = missing
```

An internal `supplier_state = review_needed` must not become an importer evidence defect when the remaining review is internal accounting or approval work.

## 10. UI source-of-truth alignment

`app/importer/page.tsx` must render the canonical RPC fields directly:

```ts
const status = {
  status: canonicalStatus,
  action: canonicalAction,
};
```

The dashboard must not calculate or use:

```text
rawInvoiceReconciled
canonicalStaleReconciliation
orders.status = partially_progressed as reconciliation proof
invoice_reconciled_tracking_open as local override input
```

The following importer surfaces must agree:

```text
importer dashboard status
importer dashboard next action
order operations header status
order operations summary status
order operations next action
```

Removing the React override changes display sourcing only. It does not mutate order status, tracking, payment, funding or supplier evidence.

## 11. Audit banner

The informational banner:

```text
Rejected evidence kept for audit
```

may remain when retired rejected evidence exists alongside current evidence.

It is informational only and must not control supplier state, reconciliation state, importer status or importer action.

Its wording is unchanged.

## 12. Final implementation disposition

The final implementation is:

```text
supabase/migrations/20260726_supplier_rejection_canonical_status_final_v1.sql
app/importer/page.tsx
```

The SQL migration:

- repairs the current internal canonical spine;
- preserves the staff-only internal guard;
- preserves the operator-safe audience proxy;
- explicitly counts approved active invoices;
- excludes retired no-resubmission invoices and their lines;
- preserves zero-line `not_started` behaviour;
- limits stage correction to stale supplier-derived stages;
- applies importer precedence only in the outer audience projection;
- leaves customer and shipper fields unchanged.

The React change removes the temporary raw-status compensation and renders canonical status and action directly.

The prior migration:

```text
20260726_importer_excluded_supplier_rejection_status_overlay_v1.sql
```

is superseded as an independent symptom-masking source. Its preserved predecessor function remains part of the deployed wrapper chain, but final truth is governed by the corrected internal spine and the final outer audience projection.

## 13. Prohibited fixes

Do not:

- mutate rejected or excluded invoice rows merely to correct UI text;
- change exceeded-order-amount, funding, balance, settlement, Sage or VAT calculations;
- change Initial payment wording or payment badges;
- approve supplier invoices before their accounting controls pass;
- set `blocked_from_sage_yn = false` prematurely;
- hard-code an order or invoice UUID;
- hide a genuine current resubmission-required rejection;
- treat every pending internal review as an importer evidence defect;
- retain a dashboard raw-status override after canonical repair;
- count lines from retired invoices in active reconciliation;
- call the staff-only internal status function directly from the outer audience wrapper;
- classify unknown active invoice statuses as approved;
- mark an active invoice with zero active lines as reconciled complete;
- change customer or shipper presentation as part of this repair.

## 14. Required verification

Release verification must cover:

```text
retired no-resubmission invoice excluded
genuine current rejection still blocks
unknown active status does not become approved
zero active lines = not_started
resolved non-physical lines = complete
unresolved active line = incomplete
final balance outranks reconciliation
exception or hold outranks reconciliation
funding/internal stage remains unchanged
customer result unchanged
shipper result unchanged
dashboard contains no raw-status reconciliation compensation
Dashboard and Operations importer outputs agree
```

Acceptance fixture assertions:

```text
supplier_state = review_needed
reconciliation_state = complete
tracking_state = missing
funding_state = incomplete
current_stage = funding_incomplete
importer_status_label = Invoice reconciled; tracking open
importer_next_action = Add tracking
```

## 15. Release rule

This addendum is satisfied only when canonical SQL, the audience-safe chain and both importer UI surfaces agree without local stale-state inference.

Any implementation that fixes only wording, bypasses the operator-safe chain, changes unrelated financial truth or leaves the dashboard override in place is non-compliant.
