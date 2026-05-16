# DVA/Card Reconciliation Next Build Sequence

Status: active build tracker.

Purpose: lock the remaining DVA/card reconciliation sequence so the build does not drift into duplicate pages, duplicate logic, or premature Sage posting.

## Critical build operating protocol

This protocol is mandatory before any code, SQL, RPC, view, migration, Vercel, or workflow change in the DVA/card, funding, exception, Sage-readiness, invoice, refund, or shipment-control paths.

### 1. Verify before changing

Before proposing or applying any change, the builder must verify the current state in this order:

1. Check this governing pack / active build tracker.
2. Check the current GitHub files that own the relevant flow.
3. Check live Supabase objects using read-only SQL where the change depends on tables, views, columns, constraints, RLS, functions, RPCs, allocation state, funding state, or Sage-readiness state.
4. Check current Vercel deployment state before relying on UI behaviour.
5. Report what is already built, partly built, not built, and not yet verified.

Repo evidence alone is not enough for DB/RPC/view-dependent work.

### 2. Normal conversation is not write approval

User phrases such as “proceed”, “continue”, “check”, “review”, “what next”, or “fix” mean investigate, verify, and propose.

They do not authorize:

- GitHub file updates;
- SQL migrations;
- RPC/view/function changes;
- Vercel environment changes;
- full-file replacements;
- refactors;
- workflow rewrites.

A write action requires explicit approval for the exact file or SQL being changed.

### 3. No regression-risk shortcuts

Every proposed build step must be regression-proof:

- do not duplicate an existing page or workflow;
- do not create a parallel route if an existing route owns the job;
- do not change working RPCs/views unless live verification proves the defect;
- do not widen constraints or alter schema casually;
- do not replace a whole file when a targeted section change is enough;
- do not mix unrelated fixes in one patch;
- do not touch Sage posting until readiness and review-pack controls are proven.

### 4. Required report before any patch

Before a patch, report using this structure:

- Confirmed from governing pack:
- Confirmed from GitHub:
- Confirmed from live SQL:
- Confirmed from Vercel:
- Already working:
- Actual gap:
- Regression risk:
- Smallest safe patch:
- Exact files affected:
- Exact test after deploy:
- Do not touch:

If live SQL is required but has not been run, the patch must not proceed.

### 5. One change at a time

Each patch must have one purpose, one affected flow, one rollback path, and one exact test.

Example:

- Fix standalone `bank_fee` allocation only.
- Do not also change supplier allocation, refund allocation, FX formula, review pack, or layout in the same patch.

### 6. Live truth beats assumptions

For anything involving DVA/card allocation, importer funding, import voiding, exception outcome actions, grouped review, or Sage readiness, live Supabase truth beats assumptions from memory or repo reading.

If live DB and GitHub differ, stop and report the mismatch before changing anything.

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
