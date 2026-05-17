# Sage Readiness Command Centre Contract v1

## Purpose

This contract replaces the current scattered Sage-readiness user experience with one accountant-led command centre model.

The current pages were created as build/control fragments: funding, DVA workspace, DVA review pack, status control, pre-Sage readiness, Sage-ready queue, shipping control, customer invoice release, shipper documents and mapping. These are valid control surfaces, but they are too fragmented as a daily operating model.

The product must move to one primary accounting control view that shows the end-to-end state of each order/document and routes the user to focused child actions only when needed.

## Core principle

Commercial draft facts, resolved Sage payload, frozen posting payload and Sage-posted records are separate states.

1. Commercial draft facts
   - Internal operational/commercial record.
   - Examples: order ref, booking ref, amount, invoice type, tax treatment, ledger role.
   - Must not be treated as final Sage payload.

2. Resolved Sage payload preview
   - Live resolver overlays current Sage mapping settings onto commercial facts.
   - Used for preview/readiness.
   - Existing drafts and future drafts must both resolve through the same resolver.

3. Frozen posting payload
   - Created only when supervisor approves the preview or batch.
   - Stores mapping snapshot and approval details.
   - Must be revalidated before posting if still unposted.

4. Posted to Sage
   - Historical record.
   - Immutable from platform side except via proper correction route.

## UX rule

There must be one primary entry point:

`/internal/sage-command-centre` or `/internal/accounting-control`

Existing pages may remain as focused child routes, but they must not be the user’s main way to understand Sage readiness.

## Pages to consolidate under the command centre

The command centre must pull signals from, or link to, these existing surfaces:

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

The command centre is the overview and decision surface. Child pages are only for drilldown/action.

## Accountant-led lanes

Each order/document must be displayed across accounting lanes, not across build-history pages.

Required lanes:

1. Funding / customer money received
   - DVA IN funding
   - importer credit applied
   - overfunding/credit balance
   - unresolved funding gaps

2. Supplier AP - goods purchases
   - supplier invoice uploaded
   - OCR/review status
   - operator reconciliation status
   - coding status
   - supplier AP draft/approval status

3. Customer Sales / AR
   - main goods customer invoice draft
   - supplementary shipping invoice where applicable
   - credit note/refund document where applicable
   - customer holds
   - resolved Sage payload status

4. DVA/card reconciliation
   - supplier OUT allocations
   - refund IN allocations
   - FX/card residuals
   - fees
   - exception/hold allocations

5. Exceptions / refunds / replacements
   - missing items
   - retailer refund path
   - replacement path
   - final outcome and DVA/refund control

6. Shipper AP / freight
   - shipper invoice/receipt uploaded
   - accepted current
   - shipping apportionment
   - shipper AP resolved payload status

7. Export / logistics evidence
   - goods receipt
   - shipment batch
   - POD/export evidence status
   - logistics discrepancies

8. Sage payload / posting control
   - resolved payload preview
   - batch approval
   - frozen payload snapshot
   - mapping-drift check before posting
   - posting status and errors

## Naming rule

Never use the word `Ready` without qualification.

Use these labels instead:

- Draft-ready
- Accounting-ready
- Payload-resolved
- Preview-approved
- Frozen-for-posting
- Posting-blocked
- Posted-to-Sage
- Posted-confirmed
- Mapping-changed-since-approval
- Tracked-in-shipping-control
- Not-evaluated-on-this-page

Raw database statuses must not be the main user-facing status. Raw statuses can be shown as smaller diagnostic text only.

## One-row operating model

For each order or posting document, the command centre row must show:

- order ref / document ref
- importer/customer
- retailer/shipper/counterparty
- amount
- document lane
- funding state
- supplier AP state
- DVA/card state
- exception state
- customer sales state
- shipper AP state
- payload state
- posting state
- owner
- next action
- blocker summary
- warning summary
- drilldown/action links

The user should not need to open five pages to understand one order.

## Child action pages

Focused action pages are still allowed. They must be treated as task drawers/pages, not as primary status dashboards.

Examples:

- Funding match
- DVA allocation workspace
- Supplier invoice review
- Supplier draft approval
- Customer invoice release
- Shipper document review
- Sage mapping config
- Payload preview approval
- Posting monitor

## Batch approval rule

The product must support batch approval. A 500-invoice run must not require 500 manual approvals.

The system must classify rows as:

- clean/resolved
- warning
- blocked
- mapping changed since approval
- already frozen
- posted

Default selection must include only clean/resolved rows. Warnings require explicit inclusion. Blocked rows cannot be selected.

Supervisor can approve a batch of clean rows. The batch approval creates frozen posting snapshots for selected rows.

## Frozen payload rule

Frozen does not mean blindly post later.

Before posting, every unposted frozen payload must be revalidated against current Sage mappings.

If mapping snapshot differs from current mapping, posting must be blocked with:

`mapping_changed_since_approval`

Supervisor must either refresh/re-approve or explicitly follow an override/correction process.

Posted records must remain immutable. Corrections must go through a proper correction route.

## Mapping resolver rule

Do not mutate every draft when mappings change.

Commercial drafts must remain stable. The resolver must apply current mappings at preview time.

Final frozen posting snapshots must store:

- resolved Sage tax rate id
- resolved Sage tax rate display name
- resolved ledger account id
- resolved ledger account display name
- customer/contact target
- amount
- reference
- source invoice/document id
- mapping code used
- mapping configured_at value
- mapping configured_by_staff_id
- approved_by
- approved_at
- approval_batch_id
- idempotency key

## Split-flow rule

Main goods customer sales invoice and shipper/supplementary shipping path are separate.

The main goods customer sales invoice must not be blocked merely because shipper AP is incomplete.

Correct split:

1. Main goods customer sales path
   - supplier goods invoice approved/current
   - customer sales draft created
   - customer sales Sage mappings resolved
   - customer sales payload preview/freeze/post

2. Shipper AP / supplementary shipping path
   - shipper invoice/receipt uploaded
   - accepted current
   - shipping apportionment approved
   - shipper AP payload preview/freeze/post
   - supplementary shipping recharge only where applicable

## First build under this contract

The next build must not create another fragmented page.

Build sequence:

1. Create read-only Sage Command Centre shell.
2. Pull current lane statuses into one order/document table using existing RPCs/views.
3. Add clear lane labels and owner/next-action fields.
4. Add customer sales Sage payload resolver.
5. Show resolver status in the command centre and Sage-ready queue.
6. Add batch approval/freeze table and RPCs.
7. Add mapping-drift revalidation before posting.
8. Only then build idempotent Sage posting actions.

## Non-negotiables

- Do not remove existing working pages during the first phase.
- Do not hide blockers.
- Do not relabel unresolved payloads as Sage-ready.
- Do not let shipper AP block main goods customer sales.
- Do not post from stale draft JSON.
- Do not trust placeholder Sage mappings for real posting.
- Do not allow batch approval of blocked rows.
- Do not silently post frozen payloads after mapping changes.
- Do not use raw `orders.status` as the main status.

## Success test

For a test order such as `ORD-1777736251155`, the command centre must show in one row:

- customer funding complete
- supplier goods invoice approved/current
- customer main invoice draft exists
- customer sales mapping configured
- customer sales payload resolved or stale/unresolved
- shipper AP blocked/missing if no shipper invoice exists
- main goods sales path not blocked by shipper AP
- next owner/action clearly shown

A supervisor should understand the order state without opening several separate dashboard pages.
