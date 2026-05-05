# DVA/Card Reconciliation Next Build Sequence

Status: active build tracker.

Purpose: lock the remaining DVA/card reconciliation sequence so the build does not drift into duplicate pages, duplicate logic, or premature Sage posting.

## Current boundary

The existing split remains:

```text
/internal/funding
= importer money received -> order funding / importer credit spine

/internal/dva-reconciliation
= card/bank/DVA money spent or refunded -> supplier invoice / refund / exception / FX allocation
```

Do not reuse `staff_reconcile_dva_line_to_order(...)` for supplier purchases, refunds, exception holds, replacement charges, FX/card differences, or statement-line allocation.

## Current completed layer

- Statement upload, extraction, staging, balance-chain review, and clean-row commit exist.
- Committed statement lines feed the DVA/card workspace.
- `dva_statement_line_allocations` is the allocation spine.
- Supplier invoice allocation is live.
- Operational exception/refund/hold allocation is live.
- FX/card/bank-fee residual allocation is live.
- Single allocation reversal is live and reopens only the reversed amount.
- Active allocation review page exists and must show active allocations only; reversed rows stay in DB audit history but not in the working page.

## Non-negotiable next sequence

### 1. Workspace DB-backed allocation status

Make `/internal/dva-reconciliation/workspace` consume `dva_statement_line_allocation_status_vw` as the truth for statement-line status and balances.

Required visible fields:

- statement total;
- source used now;
- source open now;
- allocation status bucket: `unmatched`, `part_allocated`, `balanced`, `held`, `reversed_only`;
- selectable state from DB-backed status, not client-side hiding alone.

Do not rely on old UI-only hiding/selection logic as the source of truth.

### 2. Workspace JSX used/open chips

Replace the temporary CSS-based highlight for bank-line allocated/remaining text with proper JSX chips/cards:

```text
USED £x.xx
OPEN £x.xx
```

This must be rendered in the workspace statement-line card itself, not as a global CSS hack.

### 3. Import void / rollback

Add controlled void/rollback for statement imports.

Rules:

- void unallocated committed imports;
- block void where any committed statement line has confirmed/held allocations;
- require allocations to be reversed first;
- do not delete history;
- preserve who/when/why;
- voided imports should disappear from active matching/workspace views but remain auditable.

### 4. Exception outcome actions

Add supervisor/admin exception outcome actions that do not fake a bank allocation where no bank movement exists.

Required actions:

- close as not charged / no refund due;
- hold/query operator;
- refund expected / awaiting refund.

Important distinction:

```text
Retailer did not charge = exception closure action.
Retailer charged and later refunded = statement IN line allocation to refund exception.
Retailer charged and replacement/hold needed = statement OUT line allocation to exception/replacement hold.
```

### 5. Grouped statement-line review pack

Only after items 1-4, build grouped review:

```text
Statement line: £90 OUT
- £88.88 supplier invoice
- £1.12 FX/card difference
Open: £0.00
Status: balanced
```

This is the supervisor pre-Sage review pack. It should group by source statement line, not show every allocation row as an isolated card.

### 6. Sage payload readiness

Only after grouped statement-line review is reliable, prepare Sage payload readiness.

Do not post to Sage yet.

The payload should be created only when:

- statement extraction/commit is complete;
- FX source/rate/markup are present or explicitly overridden;
- supplier invoice/refund/exception allocations are linked;
- open balance is zero or deliberately held/classified;
- supervisor approval is recorded;
- idempotency key and Sage matrix mapping are present.

## Duplication guard

Do not create another page that repeats the same matching workflow.

Current page purposes:

```text
/internal/dva-reconciliation/statements
or import route = upload/stage/commit statement rows

/internal/dva-reconciliation/workspace
= two-pane matching workspace for statement lines vs operational truth

/internal/dva-reconciliation/allocations
= active allocation records and single-allocation reversal only

Future grouped review page
= pre-Sage statement-line control pack, grouped by source statement line
```
