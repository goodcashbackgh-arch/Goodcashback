# Command Centres and Sage Resolver Contract v2

## Purpose

This contract supersedes the narrower `SAGE_READINESS_COMMAND_CENTRE_CONTRACT_v1.md` as the operating model for the platform control layer.

The platform must not continue to grow as disconnected readiness pages. Existing pages remain valid task rooms, but the primary user experience must be two command centres:

1. Supervisor Command Centre — one row per order, covering operations, customer, importer/operator, DVA/card, exceptions, logistics/shipper, and light accounting.
2. Admin Accounting Command Centre — one row per Sage-bound document, covering mapping, resolved payload, approval, frozen snapshot, revalidation, posting and errors.

## Core model

The system is a controlled process graph, not a rigid linear flow.

- Use hard dependencies where a downstream step truly cannot proceed.
- Use parallel lanes where the process can progress independently.
- Route exceptions back to the affected lane or document, not always the whole order.
- Show the next action from the graph, not from raw database status alone.

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

4. Posted-to-Sage record
   - Immutable platform-side history.
   - Corrections require a correction route, not silent mutation.

## Primary routes

Target primary routes:

- `/internal/supervisor-command-centre`
- `/internal/accounting-command-centre`

Existing routes become child action pages or saved filters:

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

## Supervisor Command Centre contract

Route: `/internal/supervisor-command-centre`

Primary grain: one row per order.

Purpose: give a supervisor a cockpit view from order creation to clean delivery and closure.

Required top platform foundations bar:

- FX rates / quote basis
- settlement markup
- card markup
- Sage mappings
- DVA/card import freshness
- OCR/Mindee operational status where available
- critical exceptions/holds

For testing, supervisors may see and use foundation links. In production, foundation edits move to admin-only while supervisor keeps read-only visibility.

Required order row lanes:

1. Progress
   - segmented progress and `x/y applicable milestones`.
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

## Admin Accounting Command Centre contract

Route: `/internal/accounting-command-centre`

Primary grain: one row per Sage-bound document.

Required document lanes:

- customer sales invoice
- customer supplementary invoice
- customer credit note
- supplier goods AP invoice
- shipper AP invoice
- refund/credit documents
- FX/card residual or fee journals later

Required columns:

- select
- lane
- document/source
- order ref
- counterparty
- amount/currency
- mapping state
- payload state
- approval/freeze state
- drift/revalidation state
- Sage posting state
- next action
- batch id / age

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
- Posted to Sage

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

`mapping_changed_since_approval` or `posting_critical_payload_changed_since_approval`.

Allowed states:

- `ok_to_post`
- `warning_only`
- `stale_reapproval_required`

## Batch rule

500 invoices must not require 500 manual approvals.

The admin cockpit must support:

- select all clean
- unselect all
- select one
- exclude blocked rows automatically
- warnings included only by explicit choice
- batch freeze of selected clean/resolved rows
- later revalidation before posting

## First implementation phase

Do not build posting yet.

Phase 1 implementation must be read-only:

1. Keep existing task pages untouched.
2. Build Supervisor Command Centre shell.
3. Pull existing lane states from current RPCs/views.
4. Show top foundation bar.
5. Show one row per order with lane status, owner, next action and drilldown links.
6. Test against `ORD-1777736251155`.

## Non-negotiables

- Do not delete working pages during phase 1.
- Do not hide blockers.
- Do not relabel unresolved payloads as posted or posting-safe.
- Do not let shipper AP block main goods customer sales.
- Do not post from stale draft JSON.
- Do not trust placeholder Sage mappings for production posting.
- Do not allow batch approval of blocked rows.
- Do not silently post frozen payloads after mapping changes.
- Do not make raw `orders.status` the main user-facing status.

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
