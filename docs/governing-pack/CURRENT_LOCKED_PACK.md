# Current Locked Governing Pack — Multi Tenant Platform Build

Status: current control reference for UI/API wiring after the live Day 2–9 backend pass.

## Source of truth

The UI must follow the live-passed backend and the locked governing documents. Do not wire UI actions from memory or from older schema files.

## Locked backend pack / run order that passed

Use this run order as the backend source of truth:

1. `live_v3_to_v4_preflight_bridge_v2.sql` — live v3 to v4 bridge only, for existing live project upgrades.
2. `goodcashback-complete.v4.sql` — current clean baseline schema.
3. `closure_v2_migration_v2.sql` — closure v2 schema migration.
4. `closure_v2_functions_final_day6_8_clarified.sql` — final functions file with Day 6/8 clarification support.
5. `closure_v2_seed.sql` — seed/reference data.
6. `day2_to_day9_final_regression_v5.sql` — final combined regression smoke test.

Do not rely on `goodcashback-complete.v3.sql` or older `closure_v2_functions_v2...` files for UI action wiring.

## Live pass evidence to preserve

The final live run passed Day 2–9 plus the Day 6/8 VAT reporting clarification. Key proven areas:

- Day 2: DVA funding, overfunding credit, importer credit application.
- Day 3: tracking-first, invoice-first, OCR progressed subset, manual line deletion, OCR source-line protection.
- Day 4: replacement child creation/linkage, no fresh funding, duplicate replacement blocked, refund gate.
- Day 5: shipping quote draft/ready/booked flow, overscoped shipment value blocked, multi-order quote update.
- Day 6: accounting release gates, Sage posting queue contract, idempotency, VAT release gates, zero-rating checkpoint.
- Day 6/8 clarification: VAT reporting includes on-track prepayment releases; uses sales invoices not order totals; main and supplementary both feed Box 6; replacement child does not own VAT workings; period Box 1 breach helper works.
- Day 7: auth helper contracts, RLS on portal tables, portal policy coverage, read models, replacement child funding overlay.
- Day 8: prepayment-first VAT timing, carry-in/carry-out, Box 1 breach adjustment, export deadline breach reporting, progressive commercial release, supplementary replacement invoice, duplicate line release blocked.
- Day 9: hardening, uniqueness guards, required functions/triggers, VAT adjustment support, progressive release contract active.

## Governing documents / matrices to use

Authority / governing docs:

1. Architecture Completion Addendum v2.
2. Canonical Schema Reference v1.
3. Master End-to-End Orchestration v3.
4. Technical Resource Map by Node v2.
5. SAGE Posting Matrix v1.
6. UI Wiring Control Document v1.

Supplementary party-flow matrices:

1. Importer role stage matrix v7.
2. Supervisor role stage matrix v7.
3. Admin role stage matrix v6.
4. Shipper role stage matrix v5.

Later addendums:

1. VAT Timing & Export Evidence Addendum v1.
2. Progressive Commercial Release & Replacement Invoicing Addendum v1.
3. Day 6/8 Accounting Release and VAT Reporting Clarification Addendum v1.

## Non-negotiable UI wiring rules

1. Read-only first. Every queue page must first show live backend data without writes.
2. Action buttons only after confirming exact live function signatures.
3. Do not let importer-facing users operate staff-only funding/reconciliation controls.
4. Staff internal pages are protected by `app/internal/layout.tsx`.
5. Stable progressed subsets can be released; unresolved children block final whole-order closure, not stable subset movement.
6. Replacement child orders do not own fresh funding or customer VAT workings.
7. Late replacement value is supplementary invoice on the parent, not a second main invoice.
8. VAT is prepayment-first for known quoted goods.
9. VAT workings are sales-invoice based, not full order-total based.
10. On-track export evidence within deadline can still report before final evidence completion; breach creates Box 1 adjustment in the breach period.
11. Sage posting remains queue-driven and idempotent.
12. Shipper only acts on supervisor-confirmed progressed shipment scope.

## Funding page read-only sources

The first operational page to wire is `/internal/funding`.

Read-only sources:

- `day2_dva_review_worklist_vw`
- `order_funding_position_vw`
- `importer_balance_vw`
- `dva_statement_lines`
- `order_funding_events`

Do not wire these actions until function signatures are verified from the final functions file:

- `confirm_reconciliation_to_order(...)`
- `accept_order_match_suggestion_and_reconcile(...)`
- `apply_importer_credit_to_order(...)`

## Current repo/deploy state

- Active Vercel project: `goodcashback-v2`.
- Production alias: `https://goodcashback-v2.vercel.app`.
- Old project `goodcashback` should not be used for current deployment.
- Manual deploy command from Codespaces: `npx vercel --prod`.
- Codespaces is linked to Vercel project ID `prj_1jwy7mxMlE0IDPH1zDSpmlGjbvdN`.

## Next steps after this doc

1. Add the final locked backend pack files to GitHub if not already present.
2. Keep `/internal/funding` read-only until live data shape is confirmed.
3. Run `npm run build` locally before deployment where possible.
4. Deploy only after build passes.
5. Then add staff-only action wiring one function at a time.
