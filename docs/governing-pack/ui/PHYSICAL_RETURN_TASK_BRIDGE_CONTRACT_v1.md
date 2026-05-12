# Physical Return Task Bridge Contract v1

## Purpose

This contract connects three already-built areas without creating a parallel workflow:

1. Customer pre-shipment holds that become refund exceptions.
2. Operator return/collection instructions for refund exceptions.
3. Shipper physical set-aside, return/collection confirmation, and package discrepancy evidence.

The goal is to close the physical item loop before refund evidence, DVA/card matching, customer sales invoice release, export evidence, and Sage readiness can clear.

## Core principle

The exception page remains the overview. Detailed return/collection records remain expandable/history-based and may open to a detail page only when the evidence volume requires it.

Do not replace the existing view-details accordion pattern with a separate page by default.

No operational page should be a dead end. If a page tells a user to hold, set aside, review, submit, or wait, it must also show the next state or next route where the flow continues.

## Roles

### Customer

Can request a pre-shipment hold through the customer extension.

Can narrow a broad hold to line-level selection when OCR/manual lines become available.

Cannot approve, reject, edit accounting values, edit supplier invoices, or manage refund evidence.

### Supervisor

Approves or rejects customer holds.

Approves narrowed line-level customer selections before they become final shipper-visible holds.

Reviews physical discrepancy evidence and decides whether it should be pushed into the normal refund/replacement exception route.

Reviews shipper return/collection proof.

Does not bypass existing refund evidence, DVA/card, supplier/current approval, VAT, or Sage gates.

### Operator

Owns the retailer-facing commercial route.

Contacts the retailer, logs retailer updates, uploads return/collection instructions, return labels, collection/tracking refs, tracking URLs, notes, and refund/CN/no-document evidence.

Operator return/collection records are the instruction/evidence source for shipper return actions.

### Shipper

Owns physical item truth only.

Can see supervisor-approved hold/set-aside instructions.

Can see return actions when operator return/collection instructions exist.

Can confirm collected/returned/not possible/query and upload proof/image/note.

Cannot see or change VAT, Sage, DVA/card, supplier coding, refund values, credit-note approval, or customer commercial decisions.

## Current operator return/collection record

The existing operator return/collection submission captures:

- courier
- tracking or collection reference
- tracking/collection date
- tracking/evidence URL
- retailer return instructions file
- return label file
- return proof file
- note
- whether this completes return/collection for the exception

This existing record should be reused. It is not merely a text note.

## UI principle: overview vs detail

The operator exception page remains the overview:

- refund route state
- return/collection state
- shipper return action state
- refund evidence state
- DVA/card refund state
- Sage readiness state

The current view-details accordion/history pattern remains valid and preferred for good UX.

A separate detail page may be added only as a convenience layer where needed:

- `/importer/exceptions/[dispute_id]/return-collection`
- `/internal/exceptions/[dispute_id]/return-collection`
- `/shipper/return-actions/[task_id]`

These detail pages must not become separate workflows. They should read/write the same underlying records.

## No dead-end page rule

Every operational page must show either:

1. the action the user must take now;
2. the next state being waited on;
3. the page/action where the flow continues; or
4. the closed-loop state proving no further action is needed.

Pages must not stop at a passive instruction when the business process has further steps.

### Customer hold page next-state rules

`/shipper/customer-holds` is the set-aside/do-not-ship page, but it must also show the next state for each hold:

- `Set aside only — waiting for operator return instructions`
- `Return action ready — open return action`
- `Return proof submitted — awaiting supervisor review`
- `Return accepted — physical return loop closed`
- `Cleared / superseded — no shipper action required`

When a return action exists for the same order/dispute/line/tracking context, the customer hold card should link to the return action page.

### Return action page rules

The preferred shipper route name is:

`/shipper/return-actions`

`/shipper/return-tasks` may remain as an alias or redirect for compatibility, but user-facing language should be "return actions".

The page should support filters:

- All
- Customer hold returns
- Shipper damage/missing returns
- Ready to action
- Submitted / awaiting review
- Accepted
- Held / query

The return action page should show the operational return/collection action until the physical loop is closed.

## Customer unwanted item route

1. Customer requests order/tracking/line hold.
2. Supervisor approves/rejects.
3. If broad hold is later narrowed, narrowed line selection is requested first.
4. Supervisor approves the narrowed final selection.
5. Approved line hold creates/links to a normal refund exception.
6. Refund exception is treated as refund-pursuit-approved because the supervisor already approved the customer hold/line selection.
7. Operator handles retailer route using existing exception flow.
8. Operator uploads return/collection instructions when retailer gives return route/label/collection details.
9. Shipper sees return action and confirms physical collection/return/proof.
10. Supervisor reviews shipper proof.
11. Operator/supervisor continue refund document evidence, DVA/card refund IN matching, and Sage readiness gates.

## Shipper physical discrepancy route

1. Shipper records package/intake status.
2. Clean receipt remains non-exceptional.
3. Damaged/wrong/missing/not received/held-query statuses enter supervisor physical triage.
4. Supervisor reviews physical issue.
5. If accepted, supervisor creates or links a normal refund/replacement exception.
6. Operator handles retailer route.
7. If retailer requires physical return, operator uploads return/collection instructions.
8. Shipper completes the same return action flow.
9. Supervisor reviews shipper return proof.
10. Existing refund/replacement, DVA/card, export evidence, and Sage gates continue.

## Shipper return action page

Route:

`/shipper/return-actions`

Alias/compatibility route:

`/shipper/return-tasks`

Suggested filters:

- All
- Customer hold returns
- Shipper damage/missing returns
- Ready to action
- Submitted / awaiting review
- Accepted
- Held / query

Each action should show only operational information:

- order ref
- tracking/package ref
- item line(s) or package context
- return instruction file
- return label file
- courier / collection ref / tracking ref
- note from operator
- source: customer hold return or shipper physical issue return
- required shipper action
- proof/image upload or URL
- shipper note

## Shipper action statuses

Minimum statuses:

- ready_to_action
- submitted_for_review
- accepted
- hold_query
- rejected
- cancelled_or_superseded

## Gates

Customer sales invoice release must exclude held/unresolved items.

Shipper shipment/export flow must not include items under approved hold or unresolved return action.

Pre-Sage readiness remains blocked while any approved/requested customer hold, unresolved physical discrepancy, unresolved shipper return action, missing refund evidence, or unmatched DVA/card refund remains open.

Supplier refund/CN/no-document evidence remains separate from physical return proof.

## Non-goals

Do not expose the full operator exception page to shippers.

Do not let shippers approve refunds, edit refund values, edit supplier invoice lines, approve credit notes, post to Sage, or reconcile DVA/card statements.

Do not create a second refund/replacement workflow.

Do not bypass existing exception, refund evidence, supplier readiness, DVA/card, VAT, or Sage gates.

## Build order

1. Keep exception page as overview and preserve view-details history UX.
2. Add shipper return-action read model from existing return/collection records plus approved holds/disputes.
3. Add shipper return proof submission.
4. Add supervisor review of shipper return proof.
5. Add return-action next-state links from customer-holds cards.
6. Rename/reframe `/shipper/return-tasks` as `/shipper/return-actions`, keeping compatibility where needed.
7. Connect shipper physical receipt issues to supervisor triage.
8. Allow supervisor to convert accepted physical issues into normal refund/replacement exceptions.
9. Feed unresolved shipper return/physical issue states into pre-Sage/customer invoice/shipment readiness.
