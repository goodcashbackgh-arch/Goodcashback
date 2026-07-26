# Supplier Invoice Rejection Post-Tracking Amendment v1

Status: locked amendment.

This amendment extends and, where necessary, supersedes the post-tracking boundary in:

- `SUPPLIER_INVOICE_REJECTION_AND_AUDIENCE_STATUS_ADDENDUM_v1.md`
- `CANONICAL_AUDIENCE_STATUS_CONTRACT_v1.md`

## 1. Proven regression

For:

```text
order_ref = ORD-1784976429191
order_id = abf15b7b-771f-482f-9751-2af0ee0bcbb1
```

The canonical pre-tracking result was correct:

```text
reconciliation_state = complete
tracking_state = missing
importer_status_label = Invoice reconciled; tracking open
importer_next_action = Add tracking
```

After tracking was submitted, the importer-facing status incorrectly fell back to:

```text
Evidence attention
Resolve evidence issue
```

The audit-only rejected evidence banner remained informational and was not the defect.

## 2. Root cause

The legacy audience projection evaluated:

```text
supplier_state = review_needed
```

as an importer evidence defect before evaluating the completed reconciliation and tracking progression.

For this class of order, `review_needed` represents internal accounting, approval or control work. It does not require corrected importer evidence.

Only a current invoice satisfying all of the following is an importer evidence blocker:

```sql
COALESCE(si.is_current_for_order, true) = true
AND si.review_status = 'rejected_resubmit_required'
AND COALESCE(si.rejection_requires_resubmission_yn, true) = true
```

## 3. Canonical importer progression

After all higher-priority importer blockers, importer status follows active reconciliation and tracking state.

Required precedence:

```text
1. final balance due
2. exception or hold
3. genuine current resubmission-required rejection
4. active reconciliation incomplete
5. reconciliation complete, tracking missing
6. reconciliation complete, tracking allocation incomplete
7. reconciliation complete, tracking submitted
8. remaining canonical importer rules
```

Required projections:

```text
reconciliation_state = incomplete
-> Invoice reconciliation open
-> Continue invoice reconciliation

reconciliation_state = complete
tracking_state = missing
-> Invoice reconciled; tracking open
-> Add tracking

reconciliation_state = complete
tracking_state = allocation_incomplete
-> Tracking submitted
-> Assign tracking

reconciliation_state = complete
tracking_state = submitted
pod_delivery_state <> accepted_current
-> No importer action required
-> No importer action required

reconciliation_state = complete
tracking_state = submitted
pod_delivery_state = accepted_current
-> Order complete
-> Order complete
```

## 4. Meaning of tracking states

Canonical tracking states remain:

```text
missing
allocation_incomplete
submitted
```

`allocation_incomplete` means an active tracking reference exists, but one or more progressed physical lines, tracking references or package relationships remain unallocated. The importer owns the next action `Assign tracking`.

`submitted` means the canonical tracking/allocation coverage is complete. The importer must not be sent back to evidence merely because an internal supplier review remains open.

## 5. Scope boundary

This amendment changes only importer audience projection.

It does not change:

```text
supplier_state
reconciliation_state
tracking_state
internal current stage
customer status or action
shipper status or action
funding or balances
supplier invoice approval
tracking records
tracking allocations
shipment records
Sage, VAT or accounting rules
audit banner wording
```

## 6. Implementation

The governing migration is:

```text
supabase/migrations/20260726234000_importer_post_tracking_projection_final_v1.sql
```

It replaces the current `order_audience_status_v1(uuid)` definition in place and continues to consume the existing audience-safe predecessor:

```sql
public.order_audience_status_pre_supplier_rejection_final_v1(p_order_id)
```

It must not add another permanent wrapper layer and must not call the staff-only internal status function directly.

## 7. Required verification

For the production fixture after tracking submission but before line allocation:

```text
supplier_state = review_needed
reconciliation_state = complete
tracking_state = allocation_incomplete
importer_status_label = Tracking submitted
importer_next_action = Assign tracking
```

After all progressed physical lines and active tracking references are allocated:

```text
reconciliation_state = complete
tracking_state = submitted
importer_status_label must not equal Evidence attention
importer_next_action must not equal Resolve evidence issue
```

Also verify:

```text
genuine current resubmission still returns evidence action
final balance still outranks tracking
exception or hold still outranks tracking
customer output unchanged
shipper output unchanged
Dashboard and Order Operations agree
```

## 8. Prohibited fixes

Do not:

- change `supplier_state` to approved merely to clear importer wording;
- mutate or delete the retired rejection;
- hide a genuine current resubmission-required rejection;
- use raw order status to infer tracking progression;
- add a React-only status override;
- treat any active tracking row as fully allocated;
- collapse `allocation_incomplete` and `submitted`;
- change customer or shipper presentation;
- hard-code the production order UUID.
