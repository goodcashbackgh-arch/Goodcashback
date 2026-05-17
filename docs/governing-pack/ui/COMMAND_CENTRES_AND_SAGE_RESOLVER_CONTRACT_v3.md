# Command Centres and Sage Resolver Contract v3

## Purpose

This contract supersedes `COMMAND_CENTRES_AND_SAGE_RESOLVER_CONTRACT_v2.md` as the operating model for the platform command centres, Sage payload resolution, freeze controls, and high-volume accounting/operations workbenches.

The v2 contract was correct on control integrity. Version 3 adds the scale rule: the platform must be designed for hundreds or thousands of orders, invoices, frozen snapshots, and posting candidates without becoming a card-based demo interface.

The platform must not grow as disconnected readiness pages. Existing pages remain valid task rooms, but the primary user experience must be two high-volume command centres:

1. Supervisor Command Centre — grid-first order control workbench covering operations, customer, importer/operator, DVA/card, exceptions, logistics/shipper, and light accounting.
2. Admin Accounting Command Centre — grid-first Sage/accounting workbench covering mapping, resolved payload, approval, frozen snapshot, revalidation, posting, failures, batches and correction routes.

## Core model

The system is a controlled process graph, not a rigid linear flow.

- Use hard dependencies where a downstream step truly cannot proceed.
- Use parallel lanes where the process can progress independently.
- Route exceptions back to the affected lane or document, not always the whole order.
- Show the next action from the graph, not from raw database status alone.
- Make the command centres routing brains, not display-only pages.

The platform must explicitly separate these states:

1. Commercial draft facts
   - Stable internal facts such as order ref, amount, invoice type, tax treatment and ledger role.
   - These are not final Sage posting payloads.

2. Live resolved Sage payload
   - Resolver-on-read overlays current Sage mappings/configuration onto commercial facts.
   - Existing and future drafts must both resolve through the same resolver.

3. Frozen posting snapshot
   - Created only when a supervisor/admin approves a preview or batch.
   - Stores resolved payload, mapping snapshot, mapping provenance, approval audit fields and idempotency key.

4. Revalidated posting candidate
   - Frozen snapshot checked again against current resolved truth before posting.
   - If posting-critical mappings or payload facts changed, posting must be blocked.

5. Posted-to-Sage record
   - Immutable platform-side history.
   - Corrections require a correction/reversal route, not silent mutation.

## Primary routes

Target primary routes:

- `/internal/supervisor-command-centre`
- `/internal/accounting-command-centre`
- `/internal/accounting-command-centre/posting-preview`
- `/internal/accounting-command-centre/snapshots/[snapshot_id]`

Existing routes become child action pages, detail pages, or saved filters:

- `/internal/funding`
- `/internal/dva-reconciliation/workspace`
- `/internal/dva-reconciliation/review-pack`
- `/internal/dva-reconciliation/exception-actions`
- `/internal/status-control`
- `/internal/status-control/pre-sage-financial-readiness`
- `/internal/sage-ready`
- `/internal/sage-mapping`
- `/internal/shipping-control`
- `/internal/shipping-control/customer-invoice-release`
- `/internal/shipping-control/shipper-documents`
- `/internal/shipping-control/customer-invoice/[shipment_batch_id]`
- `/internal/invoice-review`
- `/internal/supplier-draft-ready`
- `/internal/customer-holds`

## High-volume command-centre rule

Command centres are workbenches, not card dashboards.

Cards are allowed only for:

- KPI summaries
- exception warnings
- current batch summary
- single-record detail pages

Cards must not be the primary way to handle hundreds or thousands of orders/invoices.

Production command centres must be:

- grid-first
- server-side filtered
- server-side paginated
- defaulted to actionable rows
- bulk-action capable
- drilldown-based for audit/detail

The default question is not `can I see every record?`.

The default question is:

`what needs action, who owns it, what is the next click, and which clean rows can be bulk-processed safely?`

## Server-side pagination and filter rule

Do not load thousands of rows into React and filter in memory.

Required command-centre read models must be server-side RPCs/views with:

- limit
- offset/cursor
- search
- status filter
- lane filter
- importer filter
- shipper filter
- country/lane filter where relevant
- age/SLA filter
- summary counts for the whole matching result set
- total count for pagination
- next action
- next action href

Target RPC shapes:

```sql
internal_supervisor_command_centre_grid_v1(
  p_status text,
  p_importer_id uuid,
  p_shipper_id uuid,
  p_country_code text,
  p_search text,
  p_limit integer,
  p_offset integer
)
```

```sql
internal_accounting_command_centre_grid_v1(
  p_lane text,
  p_posting_gate text,
  p_mapping_status text,
  p_payload_status text,
  p_search text,
  p_limit integer,
  p_offset integer
)
```

Each should return row data plus summary/count metadata, either as separate RPCs or a stable JSON envelope.

## Default view rule

Default views must not be `all records`.

Supervisor default:

- needs supervisor action
- blocked
- ready for customer invoice
- DVA/card issue
- shipper/logistics issue
- exception/hold issue
- export/delivery pending

Accounting default:

- live ready not frozen
- frozen requires revalidation
- frozen ready to post
- blocked before posting
- posting failed

`All active` and `All documents` are allowed only as explicit filters.

## Supervisor Command Centre contract

Route: `/internal/supervisor-command-centre`

Primary grain: one row per active order or operational order/shipment grouping.

Purpose: give a supervisor a high-volume cockpit from order creation to clean delivery and closure.

Required top platform foundations bar:

- FX rates / quote basis
- settlement markup
- card markup
- Sage mappings
- DVA/card import freshness
- OCR/Mindee operational status where available
- critical exceptions/holds

For testing, supervisors may see and use foundation links. In production, foundation edits move to admin-only while supervisor keeps read-only visibility.

Required supervisor summary counts:

- total active orders
- needs action
- blocked
- ready for customer invoice
- awaiting shipper/AP
- DVA/card issue
- exception open
- export/delivery pending
- completed/clean

Required dense grid columns:

- order ref
- importer
- retailer
- country/lane/route
- shipper/batch where available
- order age/SLA
- overall graph status
- funding
- DVA/card
- supplier goods AP
- exceptions/holds
- tracking/package
- shipper receipt/allocation
- customer sales/AR
- shipper AP/freight
- export/delivery
- next owner
- next action
- open/detail

Each lane must be represented by compact text + coloured status chip. Colour must not be the only signal.

Required row lanes:

1. Progress
   - segmented process graph and `x/y applicable milestones`.
   - do not use a misleading single linear percentage alone.

2. Order / route
   - order ref, route, retailer, importer, shipper/batch where available.

3. Customer / importer
   - customer/importer status, customer confirmation/pro forma status, customer hold/balance signals.

4. Funding / DVA
   - funding threshold, DVA IN funding, credit application, funding gap, supplier OUT/refund IN allocation indicators.

5. Supplier goods AP
   - supplier invoice uploaded, approved/current, blocked, coding/accounting state.

6. Exceptions / holds
   - open exceptions, refund/replacement state, customer holds, issue severity and lane scope.

7. Logistics / shipper
   - tracking, content allocation, receipt truth, shipper/batch state.

8. Customer Sales / AR
   - main customer invoice draft, supplementary invoice if applicable, customer credit note if applicable, payload status.

9. Shipper AP / freight
   - shipper invoice/receipt, accepted current, apportionment, shipper AP payload status.

10. Export / delivery
    - export evidence, POD, delivered-clean and closure status.

11. Owner and next action
    - owner role/person, primary next action, reason, link.
    - if two independent parallel actions exist, show one primary and a `+1 parallel action` hint.

Supervisor row actions:

- Open cockpit/detail
- Go to next action
- Open exception lane
- Open DVA/card lane
- Open shipper/logistics lane
- Open customer sales lane

The command centre must route users to the exact child action page that resolves the blocker.

## Admin Accounting Command Centre contract

Route: `/internal/accounting-command-centre`

Primary grain: one row per Sage-bound document or one row per live-ready/frozen posting candidate.

Purpose: give accounting/admin users a high-volume workbench for preview, freeze, revalidation, posting control, failure handling, and corrections.

Required document lanes:

- customer sales invoice
- customer supplementary invoice
- customer credit note
- supplier goods AP invoice
- shipper AP invoice
- refund/credit documents
- FX/card residual or fee journals later

Required accounting summary counts:

- live ready not frozen
- frozen ready to post
- requires revalidation
- blocked mapping
- blocked payload
- posting failed
- posted today
- total ready value
- total selected value

Required dense grid columns:

- select
- document lane
- document type
- source/ref
- order ref
- counterparty
- amount/currency
- mapping state
- payload state
- freeze state
- revalidation state
- posting gate
- Sage status
- batch ref
- idempotency key
- age/SLA
- open preview

The accounting command centre must separate these views/queues:

1. Live ready, not frozen
2. Frozen, not revalidated
3. Frozen, ready to post
4. Frozen, blocked/drifted
5. Posting failed
6. Posted

## Selection and bulk action rule

For scale, bulk selection must support two modes:

1. Select visible page
2. Select all matching current filter

The UI must clearly distinguish them.

Required bulk actions:

- freeze selected
- freeze all clean matching filter
- revalidate selected
- revalidate all matching filter
- later post selected ready-to-post
- later post all ready-to-post matching filter
- export CSV
- retry failed only

Rules:

- blocked rows are excluded automatically
- warnings are excluded by default
- warnings require explicit inclusion
- posting requires revalidation immediately before the posting batch starts
- selection summary must show count and total value
- user must see excluded row counts and reasons before committing batch action

500 invoices must not require 500 manual approvals.

## Detail page rule

Detail pages are audit/inspection pages, not the main operating workflow.

Grid = operate.
Detail = inspect/audit.

Required detail pages:

- frozen snapshot final posting preview
- order cockpit/detail
- batch run detail
- posting failure detail
- correction/reversal detail

Frozen snapshot detail page must show:

- resolved payload
- mapping snapshot
- ledger account
- tax rate
- counterparty/contact target
- amount/currency
- reference
- source document id
- idempotency key
- approval/revalidation/posting audit
- raw resolved payload JSON
- raw commercial payload JSON
- raw mapping snapshot JSON

## Status vocabulary

Do not show raw DB status as the main status.

Preferred user-facing statuses:

- Complete
- In progress
- Waiting external
- Action needed
- Blocked
- Review
- Not reached
- Not applicable
- Draft exists
- Payload resolved
- Payload blocked
- Frozen for posting
- Mapping changed since approval
- Ready to post
- Posted to Sage
- Posting failed

Colours must not be the only signal. Each status needs short text and, where useful, an icon or label.

Status chips are status only. Links/buttons must be separate text/button controls.

## Split-flow rule

Main goods customer sales and shipper/AP shipping are separate after shared upstream facts.

Main customer goods sales must not be blocked merely because shipper AP is incomplete.

Correct split:

1. Main goods customer sales path
   - supplier goods invoice approved/current
   - customer confirmation/pro forma where required
   - customer sales draft created
   - customer sales Sage payload resolved
   - preview/freeze/post

2. Shipper AP / supplementary shipping path
   - tracking/package/batch state
   - shipper invoice/receipt uploaded
   - accepted current
   - apportionment approved
   - shipper AP payload resolved
   - supplementary shipping recharge where applicable
   - preview/freeze/post

## Resolver rule

Do not mutate every draft when mappings change.

Commercial draft JSON remains stable. Sage payload preview must be generated by resolver-on-read using current mappings and current posting-critical facts.

Minimum resolver contracts:

- `internal_resolved_customer_sales_sage_payload_v1(p_sales_invoice_id uuid default null)`
- `internal_resolved_shipper_ap_sage_payload_v1(...)`
- later supplier AP resolver if required

Resolver output must include:

- source table/id
- order id/ref
- document lane/type
- counterparty target
- amount/currency/reference
- commercial payload
- resolved payload
- mapping snapshot
- mapping semantic fingerprint
- payload status
- blocker/warnings

## Freeze and drift rule

Frozen does not mean blindly post later.

Before posting, every unposted frozen snapshot must be revalidated against current resolved truth.

If a posting-critical mapping or payload value changed, block posting with:

- `mapping_changed_since_approval`
- `posting_critical_payload_changed_since_approval`

Allowed revalidation states:

- `ok_to_post`
- `warning_only`
- `stale_reapproval_required`
- `blocked_source_not_ready`

## Sage posting batch rule

Posting must be batch/job-oriented, not row-by-row only.

Required posting model:

1. create posting batch
2. lock selected snapshot rows
3. revalidate immediately before posting
4. exclude blocked/stale rows
5. use idempotency key per document
6. call Sage only for posting-safe rows
7. record Sage invoice/id per row only after Sage confirmation
8. record success/failure per row
9. allow retry failed only
10. mark batch complete/partial/failed

No posting action may use stale commercial draft JSON directly.

No posting action may post a frozen snapshot whose revalidation status is not `ok_to_post` unless an explicit warning-only policy is agreed and logged.

## Correction route rule

Posted snapshots are immutable.

Corrections require explicit routes:

- void/reverse platform-side where allowed
- Sage correction/credit note where required
- new corrected posting snapshot
- link original and correction
- preserve audit trail

Do not edit posted snapshot payloads.
Do not silently change ledger/tax after posting.
Do not overwrite Sage IDs.

## First implementation phases

### Phase 1 — control shells

1. Keep existing task pages untouched.
2. Build Supervisor Command Centre shell.
3. Pull existing lane states from current RPCs/views.
4. Show top foundation bar.
5. Show order lanes, owner, next action and drilldown links.
6. Test against `ORD-1777736251155`.

### Phase 2 — accounting resolver/freeze spine

1. Build customer sales resolver.
2. Resolve existing drafts through live mapping rather than stale JSON.
3. Build freeze snapshot tables.
4. Freeze customer sales snapshots.
5. Revalidate frozen snapshots.
6. Build accounting command centre.
7. Build shipper AP freeze/resolver path.
8. Build frozen snapshot final posting preview.

### Phase 3 — high-volume workbench hardening

1. Replace card-heavy command centres with dense grids.
2. Add server-side pagination/filter RPCs.
3. Add summary counts for matching result set.
4. Default to actionable queues.
5. Add `select visible page` and `select all matching filter`.
6. Add exclusion counts and warnings-inclusion logic.
7. Keep detail pages as drilldown only.

### Phase 4 — remaining document lanes

1. Customer supplementary invoice resolver/freeze if not already covered by customer sales resolver.
2. Customer credit note resolver/freeze.
3. Supplier goods AP invoice resolver/freeze.
4. Refund/credit document resolver/freeze.
5. FX/card residual or fee journal resolver/freeze later.

### Phase 5 — posting adapter

1. Build Sage posting adapter against frozen snapshots only.
2. Create posting batches.
3. Revalidate immediately before batch posting.
4. Use idempotency keys.
5. Record Sage confirmation fields.
6. Handle posting failures and retry failed only.
7. Build correction/reversal routes.

## Non-negotiables

- Do not delete working pages during command-centre migration.
- Do not hide blockers.
- Do not relabel unresolved payloads as posted or posting-safe.
- Do not let shipper AP block main goods customer sales.
- Do not post from stale draft JSON.
- Do not trust placeholder Sage mappings for production posting.
- Do not allow batch approval of blocked rows.
- Do not silently post frozen payloads after mapping changes.
- Do not make raw `orders.status` the main user-facing status.
- Do not build command centres as primary card dashboards for production scale.
- Do not load thousands of rows into React and filter client-side.
- Do not make detail pages the main operating workflow.
- Do not build actual Sage posting before freeze, revalidation, preview, batch and idempotency controls are proven.

## Acceptance test for `ORD-1777736251155`

The Supervisor Command Centre must show in one row:

- funding complete
- supplier goods invoice approved/current
- DVA/card explained enough or relevant warning
- customer main invoice draft exists
- customer sales mapping/payload state visible
- shipper AP blocked/missing if no shipper invoice exists
- main goods customer sales path not blocked by shipper AP
- export/delivery not reached or tracked separately
- next owner/action visible with a direct link

The Admin Accounting Command Centre must show:

- customer sales live payload resolved
- customer sales frozen snapshot created
- revalidation `ok_to_post`
- posting gate `ready_to_post`
- not posted until Sage adapter exists
- frozen snapshot detail shows mapping, payload, lines, source, amount, reference and idempotency key

## Scale acceptance tests

The platform must support the following without UX or query breakdown:

1. 1,000 active orders in Supervisor Command Centre.
2. 1,000 live-ready accounting documents in Admin Accounting Command Centre.
3. Server-side search/filter/pagination without client-side full-load filtering.
4. Batch freeze all clean matching filter without selecting each row manually.
5. Revalidate all matching frozen rows without loading every row into the browser.
6. Exclude blocked/warning rows with visible counts and reasons.
7. Open a single row preview without changing the batch/grid state.
8. Export filtered accounting rows for review.
