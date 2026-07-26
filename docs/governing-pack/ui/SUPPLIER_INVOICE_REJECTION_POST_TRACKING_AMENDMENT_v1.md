# Supplier Invoice Rejection Post-Tracking Amendment v1

Status: locked platform-wide amendment.

This amendment extends and, where necessary, supersedes:

- `SUPPLIER_INVOICE_REJECTION_AND_AUDIENCE_STATUS_ADDENDUM_v1.md`
- `CANONICAL_AUDIENCE_STATUS_CONTRACT_v1.md`
- `EVIDENCE_QUERY_IMPORTER_ACTION_CONTRACT.md`

## 1. Platform decision

The repair is a platform state-machine correction for every active order returned by:

```text
internal_platform_order_status_v1()
order_audience_status_v1(p_order_id uuid default null)
```

No migration branch, function branch or UI branch may identify a specific order UUID or order reference.

Known production orders are acceptance fixtures only. They prove the general rule but do not define it.

## 2. Canonical active supplier invariant

The active-invoice predicate remains:

```sql
COALESCE(si.is_current_for_order, true) = true
AND COALESCE(si.review_status, '') NOT IN ('superseded', 'duplicate_blocked')
AND NOT (
  si.review_status = 'rejected_resubmit_required'
  AND si.rejection_requires_resubmission_yn = false
)
```

Canonical supplier state must be derived in this order:

```text
no active invoices
-> missing

one or more genuine current resubmission-required rejections
-> rejected_resubmit_required

every active invoice explicitly approved and not blocked
-> approved_current

all other active mixtures or unknown states
-> review_needed
```

A single approved invoice must not hide a genuine current rejection.

A mixed set of approved and pending/review invoices must not be classified as approved.

Only a current invoice satisfying all of the following is a replacement-evidence blocker:

```sql
COALESCE(si.is_current_for_order, true) = true
AND si.review_status = 'rejected_resubmit_required'
AND COALESCE(si.rejection_requires_resubmission_yn, true) = true
```

Active-line reconciliation remains:

```text
zero active lines -> not_started
zero unresolved active lines -> complete
otherwise -> incomplete
```

Retired no-resubmission evidence and its lines remain audit-only.

## 3. Proven post-tracking regression class

The importer regression occurs when:

```text
active supplier-line reconciliation is complete
internal supplier review remains open
no current replacement evidence is genuinely required
tracking progresses from missing to allocation_incomplete or submitted
```

The legacy importer projection evaluates internal `supplier_state = review_needed` before tracking progression and can incorrectly return:

```text
Evidence attention
Resolve evidence issue
```

Internal accounting, approval or control review is not automatically importer-owned evidence work.

## 4. Separate evidence-query lane

`order_evidence_queries` is a controlled clarification lane. It does not mutate operational order state, but an open query is importer-owned work.

Only:

```sql
q.status = 'open'
```

creates an importer action.

An answered query remains pending staff review but does not require another importer answer unless reopened.

Required projection:

```text
importer_status_label = Evidence query open
importer_next_action = Answer query
```

Open queries outrank reconciliation and tracking actions. They do not outrank:

```text
remaining order balance
exception or hold
current replacement-evidence requirement
```

## 5. Canonical importer precedence

Required platform-wide precedence:

```text
1. remaining order balance due
2. exception or hold requiring importer action
3. genuine current resubmission-required rejection
4. open importer evidence query
5. active supplier reconciliation incomplete
6. active reconciliation complete and tracking missing
7. active reconciliation complete and tracking allocation incomplete
8. active reconciliation complete and tracking submitted
9. remaining canonical importer rule
```

Required projections:

```text
genuine current resubmission-required rejection
-> Evidence attention
-> Resolve evidence issue

open evidence query
-> Evidence query open
-> Answer query

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

## 6. Meaning of tracking states

Canonical tracking states remain distinct:

```text
missing
allocation_incomplete
submitted
```

`missing` means no active tracking reference exists.

`allocation_incomplete` means active tracking exists, but one or more progressed physical lines, tracking references or package relationships remain unallocated. The importer action is `Assign tracking`.

`submitted` means canonical tracking and allocation coverage is complete. The importer must not be sent back to evidence solely because internal supplier review remains open.

Where a stale supplier-derived internal stage is being repaired and tracking is allocation-incomplete, the corrected internal stage is:

```text
tracking_allocation_incomplete
```

Higher-priority internal stages remain untouched.

## 7. Importer completion invariant

`importer_complete_yn` is an audience fact and must agree with the final projected importer action.

It is true only when:

```text
importer_next_action = No importer action required
or
importer_next_action = Order complete
```

It is false for:

```text
Answer query
Resolve evidence issue
Continue invoice reconciliation
Add tracking
Assign tracking
Collect final balance
Resolve exception or hold
```

An internal incomplete stage may coexist with `importer_complete_yn = true` when the remaining work is not importer-owned.

## 8. UI action-source rule

`app/importer/page.tsx` must use raw canonical `importer_next_action` for routing and button eligibility.

Display cleaning may change visible terminology, but it must not change control logic.

Examples:

```text
raw action = Add tracking
-> show Add tracking button

raw action = Assign tracking
-> show Assign tracking button

raw action = Answer query
-> show Answer query button

raw action = No importer action required
-> do not show Add tracking or Assign tracking
```

The dashboard must not infer action availability merely from:

```text
an invoice row existing
any tracking row existing
raw orders.status
```

Dashboard action counts must count canonical importer actions, not overlapping local heuristics.

The dashboard evidence-present metric must use the active-invoice predicate and exclude retired audit-only evidence.

## 9. Scope boundary

This amendment changes only read-model and UI sourcing:

```text
canonical supplier_state precedence for active invoice mixtures
supplier-derived stale-stage repair for tracking allocation
importer audience status
importer audience next action
importer_complete_yn
importer dashboard button eligibility
importer dashboard action count
importer dashboard active-evidence display
```

It does not mutate or change:

```text
invoice review rows
invoice approval decisions
reconciliation records
tracking records
tracking allocations
query records or query lifecycle
shipment records
funding or balances
customer status or action
shipper status or action
Sage, VAT or accounting rules
audit banner wording
```

No operational data is mutated by this repair.

## 10. Implementation

Governing implementation files:

```text
supabase/migrations/20260726234000_importer_post_tracking_projection_final_v1.sql
app/importer/page.tsx
docs/testing/20260726234000_importer_post_tracking_projection_regression_v1.sql
```

The migration replaces both functions in place:

```text
internal_platform_order_status_v1()
order_audience_status_v1(uuid)
```

It continues to consume the existing safe predecessors:

```sql
public.internal_platform_order_status_pre_supplier_rejection_final_v1()
public.order_audience_status_pre_supplier_rejection_final_v1(p_order_id)
```

It must not add another permanent wrapper layer.

The audience function must not call the staff-only internal function directly; it continues through the deployed audience-safe predecessor.

Customer and shipper columns pass through unchanged.

## 11. Platform release gate

The regression proof must evaluate every active order returned by:

```sql
public.internal_platform_order_status_v1()
public.order_audience_status_v1(NULL)
```

It must fail the release when any of the following occurs:

```text
supplier_state differs from the active-invoice invariant
reconciliation_state differs from active-line truth
audience row identity changes
importer status differs from governed precedence
importer action differs from governed precedence
importer_complete_yn disagrees with the projected action
customer completion/status/action changes
shipper completion/status/action changes
```

The proof must not require a specific order UUID to pass.

Known production fixtures may be inspected separately after the all-orders gate succeeds.

## 12. Acceptance fixture

The order below remains a regression example only:

```text
order_ref = ORD-1784976429191
order_id = abf15b7b-771f-482f-9751-2af0ee0bcbb1
```

Expected after tracking submission but before line allocation:

```text
supplier_state = review_needed
reconciliation_state = complete
tracking_state = allocation_incomplete
importer_status_label = Tracking submitted
importer_next_action = Assign tracking
importer_complete_yn = false
```

Expected after full tracking allocation:

```text
reconciliation_state = complete
tracking_state = submitted
importer_status_label <> Evidence attention
importer_next_action <> Resolve evidence issue
```

## 13. Prohibited fixes

Do not:

- hard-code an order UUID or order reference in migration logic;
- let an approved invoice hide a genuine current rejection;
- classify a mixed active invoice set as approved;
- mutate or delete retired rejection evidence;
- hide a genuine current resubmission-required rejection;
- hide an open evidence query behind tracking status;
- use raw order status to infer progression;
- add a React-only status override;
- show Assign tracking merely because any tracking row exists;
- treat any active tracking row as fully allocated;
- collapse `allocation_incomplete` and `submitted`;
- let display-text sanitising determine routing logic;
- change customer or shipper presentation;
- change unrelated financial or accounting truth.
