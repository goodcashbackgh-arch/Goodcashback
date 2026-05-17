# Command Centres and Sage Cloud Accounting Contract v4

## Status

This contract supersedes `COMMAND_CENTRES_AND_SAGE_RESOLVER_CONTRACT_v3.md` for the command-centre model and the route from platform readiness to Sage Cloud Accounting posting.

Version 3 was correct on scale, snapshots and revalidation, but still allowed too much visible page sprawl. Version 4 locks the simplified operating model:

1. Supervisor Command Centre = operational source-of-truth cockpit from order to clean delivery and accounting handoff.
2. Accounting Command Centre = Sage/accounting cockpit from approved facts to Sage Cloud Accounting v3.1 posting.

The platform must not grow as disconnected readiness pages. It must use two command centres plus drill-down/action pages.

## Non-negotiable rule

The project must stick to this model unless explicitly superseded by a later contract.

- No Sage posting controls in the Supervisor Command Centre.
- No operational exception resolution inside the Accounting Command Centre.
- No new top-level accounting/control page unless it is a true audit/detail page and cannot be a tab/filter/modal inside one of the two command centres.
- Sage is an execution target, not the platform source of truth.
- All Sage posting must be server-side, batch-driven, idempotent, based on frozen/revalidated snapshots, and confirmed by Sage object ids before the platform marks anything posted.

## Two-cockpit model

### 1. Supervisor Command Centre

Primary route:

- `/internal/supervisor-command-centre`

Purpose:

The Supervisor Command Centre is the operational cockpit. It answers:

- What is happening with each order?
- Where is the order or shipment grouping stuck?
- Who owns the next action?
- Which operational, customer, importer/operator, shipper, DVA/card, exception, delivery and accounting-handoff lanes are clean, blocked, waiting, or not reached?
- Can this order move toward clean delivery and accounting handoff?

It owns operational readiness into accounting. It does not post to Sage and must not duplicate Accounting Command Centre controls.

The page must be grid-first, not card-first. One row should represent an order or order-shipment grouping.

Minimum supervisor grid lanes:

- Order ref
- Importer
- Retailer
- Destination / country lane
- Shipper / batch
- Age / SLA
- Funding
- DVA/card
- Supplier goods invoice
- Exceptions / holds
- Operator/importer tasks
- Tracking / package
- Shipper receipt / allocation
- Customer confirmation / pro forma
- Customer sales / AR readiness
- Shipper AP / shipping readiness
- Export evidence / delivery / POD
- Accounting handoff
- Next owner
- Next action

Lane statuses should be compact chips:

- clean
- in progress
- blocked
- waiting external
- ready for accounting
- not reached
- not applicable

Supervisor actions route users into existing child task pages. The supervisor must not hunt across the app.

Examples of child action pages:

- DVA workspace
- Exception action page
- Invoice review
- Supplier draft ready
- Shipper document review
- Customer invoice release
- Order operations
- Shipping control detail

These child pages remain task rooms. They are not separate command centres.

### 2. Accounting Command Centre

Primary route:

- `/internal/accounting-command-centre`

Purpose:

The Accounting Command Centre is the Sage/accounting cockpit. It answers:

- Which documents are live-ready for Sage?
- Which documents are frozen?
- Which frozen snapshots need revalidation?
- Which frozen snapshots are safe to put into a posting batch?
- Which posted?
- Which failed?
- Which need retry, correction or reversal?

It owns:

- Sage mappings
- Sage connection/OAuth state
- Sage business/tenant selection
- snapshot freeze
- snapshot revalidation
- posting batch creation
- Sage Cloud Accounting v3.1 API posting
- posting failure/retry handling
- correction/reversal routes
- audit trail

It must not own:

- operational exception resolution
- shipper receipt approval
- DVA investigation workflow
- invoice OCR correction
- customer confirmation chasing
- manual operational status patching

Accounting consumes approved readiness facts from Supervisor-controlled lanes.

## Simplified page model

### Primary pages

Keep only these as daily operating cockpits:

- `/internal/supervisor-command-centre`
- `/internal/accounting-command-centre`

### Drill-down pages

Keep only these as justified drill-down pages:

- `/internal/accounting-command-centre/snapshots/[snapshot_id]`
- `/internal/accounting-command-centre/batches/[batch_id]`
- `/internal/supervisor-command-centre/orders/[order_id]` only if later needed as a detail cockpit

### Demoted/merged accounting pages

These routes should not remain main workflow pages. They become tabs, saved filters, inline panels, or legacy/testing diagnostics inside Accounting Command Centre:

- `/internal/sage-ready` -> Accounting Command Centre Live Ready tab/filter
- `/internal/accounting-command-centre/posting-preview` -> Accounting Command Centre Frozen Snapshots tab/filter
- `/internal/sage-mapping` -> Accounting Command Centre Sage Settings tab
- `/internal/status-control/pre-sage-financial-readiness` -> diagnostic/legacy link only

### Child action pages

These may remain as focused task pages, but command centres route users into them:

- `/internal/funding`
- `/internal/dva-reconciliation/workspace`
- `/internal/dva-reconciliation/review-pack`
- `/internal/dva-reconciliation/exception-actions`
- `/internal/shipping-control`
- `/internal/shipping-control/customer-invoice-release`
- `/internal/shipping-control/shipper-documents`
- `/internal/shipping-control/customer-invoice/[shipment_batch_id]`
- `/internal/invoice-review`
- `/internal/supplier-draft-ready`
- `/internal/customer-holds`
- importer/order operations pages
- shipper receipt/evidence pages

## Process graph rule

The system is a controlled process graph, not a rigid straight line.

- Linear only where a true dependency exists.
- Parallel where lanes can progress independently.
- Exceptions route the item back into the correct lane, not always back to the whole order.
- Customer sales and shipper AP can split.
- A main customer goods invoice may become accounting-ready before shipper AP/shipping recharge is ready.
- Shipper AP/shipping recharge follows once shipper invoice/receipt, apportionment and shipping evidence are controlled.

## Supervisor-to-Accounting handoff

Supervisor-controlled lanes produce readiness signals. Accounting consumes those signals.

Examples:

1. Customer sales
   - Supervisor resolves supplier invoice, DVA/card, commercial exception, customer/pro forma confirmation and relevant customer-sales controls.
   - Customer sales row becomes live-ready.
   - Accounting freezes, revalidates, batches and posts it.

2. Shipper AP
   - Supervisor accepts shipper invoice/receipt and approves shipping AP/apportionment readiness.
   - Shipper AP row becomes live-ready.
   - Accounting freezes, revalidates, batches and posts it.

3. Exceptions/refunds/replacements
   - Supervisor resolves refund, replacement or hold outcome.
   - Accounting receives a ready document row, a blocked document row, a credit-note route, or a replacement route.

Accounting must see clear blockers when operational readiness is not achieved:

- blocked_by_operational_readiness
- blocked_by_missing_customer_confirmation
- blocked_by_missing_export_evidence
- blocked_by_unresolved_exception
- blocked_by_unmatched_dva
- blocked_by_unapproved_shipper_document
- blocked_by_missing_shipper_apportionment

Supervisor sees accounting status as read-only handoff outcome:

- awaiting accounting
- frozen
- ready to post
- posted
- failed
- correction required

## Existing Sage prototype reuse

The October 2025 Apps Script Sage integration is a prototype pattern, not the final production implementation.

Useful concepts to port server-side:

- Sage Accounting API base: `https://api.accounting.sage.com/v3.1`
- OAuth2 flow
- `sage_` HTTP wrapper -> `sageClient()`
- `ensureContact_` -> `ensureSageContact()`
- sales invoice creation -> `createSageSalesInvoice()`
- purchase invoice creation/logic -> `createSagePurchaseInvoice()`
- `contact_payments` -> `createSageContactPayment()`
- `contact_allocations` -> `createSageContactAllocation()`
- deposit reconciliation concepts
- credit note/refund handling
- ledger/tax mapping via config
- idempotency through references/idempotency keys
- audit snapshots/logging

Before coding final adapter field mappings, locate the actual Apps Script source or paste it into the build chat. Do not rely on remembered function behaviour alone.

## Sage Cloud Accounting v3.1 build path

### Phase 1 — Contract and page consolidation

- Lock this v4 contract.
- Make Accounting Command Centre the only daily Sage posting cockpit.
- Make Supervisor Command Centre the only daily order-to-clean-delivery cockpit.
- Demote legacy/readiness routes into tabs/filters/diagnostics.
- Do not delete working pages until replacement tabs are proven.

### Phase 2 — Supervisor Command Centre grid v1

Build read-only first.

Inputs:

- orders
- importer/customer/retailer/shipper context
- funding position
- DVA/card allocation state
- supplier invoice readiness
- exception/hold state
- tracking/package state
- shipper document/recharge state
- export/delivery evidence state
- accounting handoff state

Outputs:

- row-level lane chips
- next owner
- next action
- direct link to the action page
- accounting handoff state only as read-only

No write buttons in v1 except links to existing action pages.

### Phase 3 — Supervisor next-action routing

Add deterministic routing rules:

- If funding gap -> funding/DVA action
- If supplier invoice missing/blocked -> invoice upload/review/reconciliation action
- If exception open -> exception action
- If customer confirmation missing -> customer/pro forma action
- If tracking/package missing -> order operations/tracking action
- If shipper receipt/document missing -> shipper document/review action
- If export/delivery missing -> shipping/export evidence action
- If accounting ready -> Accounting Command Centre handoff link

Next action must come from the process graph, not raw order status alone.

### Phase 4 — Accounting Command Centre consolidation

Accounting Command Centre sections/tabs:

1. Live ready
2. Frozen snapshots
3. Posting batches
4. Sage connection/settings
5. Posting results/failures
6. Corrections/reversals

Existing grid/bulk freeze/revalidation work remains, but the page must not force users into separate `/sage-ready`, `/sage-mapping` or `/posting-preview` daily pages.

### Phase 5 — Sage connection foundation

Add server-side tables:

- `sage_connections`
- `sage_oauth_tokens`
- `sage_businesses`
- `sage_api_request_log`
- `sage_api_response_log`

Minimum fields:

- connection_id
- platform_tenant_id
- sage_business_id
- sage_business_name
- access_token_encrypted
- refresh_token_encrypted
- expires_at
- scopes
- status
- connected_by_staff_id
- connected_at
- last_refresh_at
- disabled_at

Rules:

- No Sage client secret in browser.
- No direct browser-to-Sage calls.
- Token refresh is server-side only.
- All Sage request/response logs tie back to a posting batch row or connection event.

### Phase 6 — Sage OAuth routes

Build:

- `/api/sage/oauth/start`
- `/api/sage/oauth/callback`
- `/api/sage/oauth/refresh`

UI lives inside Accounting Command Centre -> Sage connection/settings tab.

Controls:

- Connect to Sage
- Reconnect
- Show connected Sage business
- Show token health
- Show last refresh
- Disable connection
- Test connection

### Phase 7 — Sage adapter layer

Create:

- `src/lib/adapters/sage/client.ts`
- `src/lib/adapters/sage/auth.ts`
- `src/lib/adapters/sage/contacts.ts`
- `src/lib/adapters/sage/sales-invoices.ts`
- `src/lib/adapters/sage/purchase-invoices.ts`
- `src/lib/adapters/sage/credit-notes.ts`
- `src/lib/adapters/sage/payments.ts`
- `src/lib/adapters/sage/allocations.ts`
- `src/lib/adapters/sage/posting.ts`
- `src/lib/adapters/sage/errors.ts`

The adapter must be server-side only and must never be imported into client components.

### Phase 8 — Final Sage payload resolver

Every frozen snapshot must resolve into a Sage-ready payload with:

- Sage business id
- Sage contact id
- document type
- ledger account id
- tax rate id
- currency
- invoice date
- due date
- reference
- notes
- line items
- net/VAT/gross where relevant
- source snapshot id
- source document id
- idempotency key
- mapping version/configured_at values

Supported lanes, in build order:

1. customer sales invoice
2. shipper AP purchase invoice
3. customer supplementary invoice
4. supplier goods AP invoice later
5. customer credit note later
6. refund/credit document later
7. shipper liability recovery later

### Phase 9 — Posting batch model

Add:

- `sage_posting_batches`
- `sage_posting_batch_rows`

Batch fields:

- id
- batch_ref
- created_by_staff_id
- created_at
- status
- lane
- row_count
- total_amount_gbp
- posting_started_at
- posting_completed_at
- success_count
- failed_count
- blocked_count
- notes

Batch row fields:

- id
- batch_id
- snapshot_id
- idempotency_key
- posting_status
- sage_object_type
- sage_object_id
- sage_reference
- request_payload_json
- response_payload_json
- payload_hash
- error_code
- error_message
- attempt_count
- posted_at
- last_attempt_at

Statuses:

Batch:

- draft
- validated
- posting
- partial_success
- posted
- failed
- cancelled

Row:

- included
- excluded
- validated
- posting
- posted
- failed_retryable
- failed_terminal
- cancelled

### Phase 10 — Create posting batch, no Sage call yet

Inside Accounting Command Centre:

- Create posting batch from ready-to-post frozen snapshots.

Rules:

- Revalidate before batch creation.
- Include only `ok_to_post` snapshots.
- Exclude blocked/stale rows.
- Warnings excluded unless explicitly included.
- Lock rows to batch.
- Show included/excluded counts.
- Show total value.
- Show lane/document mix.

Batch detail route:

- `/internal/accounting-command-centre/batches/[batch_id]`

Batch detail shows:

- included rows
- excluded rows and reasons
- total value
- snapshot ids
- idempotency keys
- payload validation status
- posting disabled until adapter enabled

### Phase 11 — Sage dry-run / payload validation

Inside batch detail:

- Validate Sage payloads.

This checks without creating Sage invoices:

- Sage connection active
- Sage business selected
- contact exists or can be created
- ledger mapping exists
- tax mapping exists
- required fields present
- amounts balance
- currency valid
- reference valid
- no duplicate posted idempotency key
- payload matches frozen snapshot

### Phase 12 — Actual Sage posting

Only after dry-run is proven:

- Post batch to Sage.

Posting sequence:

1. Lock batch.
2. Refresh Sage token.
3. Revalidate all snapshots again.
4. Exclude rows no longer `ok_to_post`.
5. For each row:
   - check idempotency key
   - ensure Sage contact
   - create Sage sales invoice / purchase invoice / credit note
   - record Sage object id
   - record full request/response
6. Mark success/failure per row.
7. Mark batch posted / partial / failed.

Hard rule:

- No row is posted unless Sage returns a confirmed object id.

### Phase 13 — Failure, retry and correction

Inside Accounting Command Centre -> Posting results/failures tab:

Actions:

- Retry failed only
- Open failure detail
- Mark terminal
- Create correction route
- Export failure CSV

Correction rules:

- Posted snapshots are immutable.
- Do not edit posted payloads.
- Do not overwrite Sage ids.
- Corrections require a new correction snapshot.
- Credit note/reversal links back to original.

## Tightest build order from current state

The build must follow this order:

1. Lock this v4 contract.
2. Build Supervisor Command Centre grid v1 read-only.
3. Add Supervisor next-action routing.
4. Consolidate Accounting Command Centre tabs.
5. Add Sage connection/OAuth foundation.
6. Add Sage adapter skeleton.
7. Add final payload validation against Sage mappings/contact rules.
8. Add posting batch tables/RPCs.
9. Add batch creation from ready-to-post frozen snapshots.
10. Add batch detail page.
11. Add dry-run validation.
12. Add actual Sage posting for customer sales first.
13. Add actual Sage posting for shipper AP second.
14. Add retry/failure handling.
15. Add correction/reversal route.
16. Then expand to supplier goods AP, credit notes, refunds, payments and allocations.

Why customer sales first:

- draft exists
- frozen snapshot exists
- revalidation exists
- ready_to_post exists
- mapping resolver exists

Why shipper AP second:

- shipper AP intent exists
- snapshot freeze exists
- ready_to_post exists

Why payments/allocations later:

- payments and allocations involve cash movement, deposits, credit balances and reconciliation.
- They are more dangerous than invoice posting and should follow after invoice posting is proven.

## Compliance and security rules

- No service-role key in browser/client paths.
- No Sage token in browser/client paths.
- No posting from live mutable JSON.
- No posting without frozen snapshot.
- No posting without revalidation.
- No posting without idempotency key.
- No marking posted without Sage object id.
- No mutation of posted snapshots.
- No mixing supervisor operational controls with accounting posting controls.
- No deleting or replacing existing proven child workflows until replacement cockpit routes are tested.

## Implementation discipline

Before each build step:

1. Check this v4 contract.
2. Check existing governing pack / matrices / role contracts.
3. Check live DB schema/functions/views/RLS.
4. Check current repo files.
5. Patch surgically.
6. Confirm Vercel deployment READY.
7. Test exact target order/document/batch.

No guessing. If the contract, DB or repo does not confirm an assumption, inspect first.
