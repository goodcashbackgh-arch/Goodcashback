# Importer Tracking Assignment Status Seamless Patch Addendum v1

Status: scoped implementation addendum for one importer audience-status defect only.

## 1. Purpose

Correct one status/action inconsistency after supplier evidence is approved and supplier reconciliation is complete.

Observed controlled case:

- order `ORD-1785274708774`;
- all active supplier invoices are approved current;
- no supplier invoice requires review;
- no genuine supplier rejection exists;
- no unresolved supplier invoice lines remain;
- no open supplier review flags remain;
- tracking has already been submitted;
- progressed physical supplier lines exist;
- no tracking-line allocations yet exist.

The importer card correctly reaches `Tracking submitted`, but its next action can inherit the stale earlier-stage action `Resolve evidence issue`.

This is an audience-status projection defect. It is not an invoice, reconciliation, tracking-write, shipment, accounting or workflow-state defect.

## 2. Governing contract

This addendum is subordinate to `CANONICAL_AUDIENCE_STATUS_CONTRACT_v1.md`.

The governing rule remains:

- the canonical operational status spine remains authoritative;
- importer/operator status must reflect what the importer/operator can or must do next;
- audience wrappers may format/derive importer-facing action from canonical operational facts;
- audience wrappers must not mutate order, funding, tracking, shipping, accounting, VAT, credit, AP or other operational records.

## 3. Exact defect

For the controlled state:

```text
supplier_state = approved_current
reconciliation_state = complete
tracking_state = submitted
progressed physical lines > 0
unallocated progressed physical lines > 0
```

The importer-facing status label is correctly projected as:

```text
Tracking submitted
```

but the importer-facing next action is allowed to fall through to an earlier supplier-evidence action.

The missing projection is the importer-owned tracking assignment step.

## 4. Required seamless behaviour

The importer audience-status projection must represent the existing operational sequence as follows:

```text
No submitted tracking
  -> importer action: Add tracking

Submitted tracking exists
AND supplier reconciliation is complete
AND at least one live/progressed physical supplier line remains unallocated to tracking
  -> importer status: Tracking submitted
  -> importer action: Assign tracking

Submitted tracking exists
AND supplier reconciliation is complete
AND no live/progressed physical supplier line remains unallocated to tracking
  -> importer must not retain Add tracking, Assign tracking, Resolve evidence issue, or another earlier importer action solely from this lane
  -> downstream canonical stage continues unchanged
```

`Assign tracking` must be derived from existing tracking-allocation facts. No new lifecycle state is introduced.

## 5. Source-of-truth requirement

The patch must use existing canonical/live facts only.

The assignment-needed condition must be based on the existing relationship between:

- current supplier invoices;
- progressed/eligible physical supplier invoice lines;
- active submitted tracking;
- existing `order_tracking_line_allocations`.

The implementation must not infer assignment completion merely from the existence of tracking.

The implementation must not infer assignment need from UI state, button visibility, route presence, copied text, or page-local calculations.

## 6. Permitted implementation scope

Production implementation is limited to the smallest canonical audience-status projection required to make the importer next action agree with the already-existing tracking/allocation facts.

Permitted:

- a narrowly scoped change to the canonical importer audience-status SQL wrapper/layer;
- a narrowly scoped read-only derivation of whether progressed physical lines remain unallocated to submitted tracking, if that fact is not already exposed at the required wrapper layer;
- regression SQL proving the exact transition and non-regression boundaries.

No application/page change is required or permitted for this patch.

## 7. Explicitly out of scope

Do not change any of the following:

- importer page components;
- customer page components;
- supervisor page components;
- shipper page components;
- buttons, button behaviour, button visibility or button text;
- headings, labels, helper text, warnings, badges or general wording outside the single canonical `importer_next_action` projection required by this defect;
- routes or navigation;
- tracking submission creation or editing;
- tracking assignment write actions;
- `order_tracking_line_allocations` write semantics;
- supplier invoice upload, OCR/document-read logic or review flags;
- supplier invoice approval/finalisation;
- supplier line reconciliation or non-physical resolution logic;
- disputes, holds or exceptions;
- shipment batch creation;
- shipment/package allocation logic;
- shipper receipt logic;
- export evidence;
- POD/delivery evidence;
- customer sales document creation/posting;
- final-balance or settlement logic;
- funding or statement allocation;
- shipper AP/apportionment;
- accounting/Sage logic;
- VAT/compliance logic;
- RLS, permissions or authentication;
- schema/table redesign;
- historical operational data mutation;
- any unrelated status wording or status branch.

## 8. No upstream/downstream behavioural change

The patch must be projection-only.

It must not alter the facts that cause any operational stage to open or close.

Before and after the patch, the same database facts must determine:

- supplier approval;
- supplier reconciliation completeness;
- tracking existence;
- tracking-line allocation records;
- shipment readiness;
- export/POD readiness;
- customer sales readiness;
- final settlement;
- shipper AP;
- accounting/VAT readiness.

The only intended behavioural difference is:

```text
When tracking already exists and an importer tracking-assignment action is genuinely outstanding,
the importer audience wrapper returns Assign tracking instead of retaining an earlier stale action.
```

## 9. Fail-closed rules

The patch must not return `Assign tracking` where any of the following is true:

- supplier reconciliation is still incomplete;
- no active submitted tracking exists;
- there are no progressed/live physical lines requiring tracking assignment;
- all relevant progressed/live physical lines are already assigned;
- an earlier higher-priority canonical importer blocker legitimately applies, including a genuine supplier evidence issue, rejection, open exception/hold, or balance condition that the existing audience-status contract gives precedence.

Existing precedence must be preserved.

## 10. Regression requirements

The implementation regression must prove at minimum:

1. Controlled case `ORD-1785274708774` has approved supplier evidence and complete supplier reconciliation.
2. Active tracking exists.
3. Progressed physical lines exist.
4. No tracking-line allocations exist in the controlled pre-assignment state.
5. Importer status remains `Tracking submitted`.
6. Importer next action becomes `Assign tracking`.
7. A rollback-only simulated complete tracking allocation removes the `Assign tracking` condition and permits the existing downstream canonical projection to take over.
8. A rollback-only missing-tracking case remains `Add tracking`, not `Assign tracking`.
9. A rollback-only unresolved supplier/evidence case preserves the existing higher-priority evidence/reconciliation action.
10. Supplier invoice rows are unchanged.
11. Supplier line rows are unchanged.
12. Tracking submission rows are unchanged.
13. Tracking allocation rows are unchanged outside rollback-only test manipulation.
14. Shipment, export, POD, sales, funding, settlement, shipper AP, accounting and VAT facts are unchanged.
15. No application/UI file is modified.

## 11. Release gate

Do not merge unless:

- the production diff is confined to the canonical importer audience-status projection required by this addendum plus regression proof;
- no UI/application file changes are present;
- no unrelated status branch is changed;
- regression passes;
- status drift audit remains clean for unaffected orders.

Any additional requested improvement must be treated as a separate scope and must not be folded into this patch.