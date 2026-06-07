# Current Locked Governing Pack — Multi Tenant Platform Build

Status: current control reference for UI/API wiring after the live Day 2–9 backend pass, updated for the final settlement, partial-coverage, non-physical line-resolution, cash-backed completion-loyalty reward control, and shipper customer-hold hard-block later control.

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

Later addendums and current build contracts:

1. VAT Timing & Export Evidence Addendum v1.
2. Progressive Commercial Release & Replacement Invoicing Addendum v1.
3. Day 6/8 Accounting Release and VAT Reporting Clarification Addendum v1.
4. Portal and Order Operations Addendum v1 (`docs/governing-pack/architecture/PORTAL_AND_ORDER_OPERATIONS_ADDENDUM_V1.md`).
5. Platform Operational Status Engine Contract v1 (`docs/governing-pack/ui/PLATFORM_OPERATIONAL_STATUS_ENGINE_CONTRACT_v1.md`).
6. Non-physical Supplier Invoice Line Resolution Contract v1 (`docs/governing-pack/ui/NON_PHYSICAL_SUPPLIER_INVOICE_LINE_RESOLUTION_CONTRACT_v1.md`).
7. Final Sale Value and Balance Due Addendum v1 (`docs/governing-pack/ui/FINAL_SALE_VALUE_AND_BALANCE_DUE_ADDENDUM_v1.md`).
8. Completion Loyalty Reward Cash-Backed Credit Addendum v2 (`docs/governing-pack/ui/COMPLETION_LOYALTY_REWARD_CASH_BACKED_CREDIT_ADDENDUM_v2.md`) — supersedes `COMPLETION_LOYALTY_REWARD_AND_SAGE_POSTING_ADDENDUM_v1.md` for future build work.
9. Shipper Customer Hold Hard Block Later Contract v1 (`docs/governing-pack/ui/SHIPPER_CUSTOMER_HOLD_HARD_BLOCK_LATER_CONTRACT_v1.md`) — later control only; not built.

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
13. Reconciliation proves what was bought; finalisation decides what gets billed; shipping/handoff sees only physical goods; Sage sees only approved final invoice drafts.
14. Partial shipment/export/POD/customer sale must not be treated as full-order completion.
15. Default-N supplier invoice lines remain unresolved unless an active non-physical resolution or exception link exists.
16. Final sale settlement is a separate closure layer and must not change the accepted-estimate funding threshold or `recompute_order_platform_funded(...)`.
17. Completion loyalty reward is not dashboard-available merely on clean completion or approval-in-principle; supervisor/admin must fund/pay the customer DVA/customer account and confirm evidence before available dashboard credit is released.
18. Completion loyalty reward v1 Sage-at-approval treatment is superseded; do not queue approval itself for Sage posting in future work.
19. Shipper customer-hold hard block is not built; current control is visible shipper set-aside instruction plus SOP/audit trail, with hard block documented as a later control.

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

## Current final settlement and loyalty reward build sequence

The next durable build must follow this corrected order:

1. Final sale settlement read model / RPC.
2. Completion readiness overlay using the operational status engine.
3. Qualifying net spend read model using resolved/classified supplier/customer sale facts.
4. Completion loyalty reward proposal read model.
5. Supervisor/admin approval-in-principle state that does **not** create available dashboard credit.
6. Supervisor/admin funding-proof lane: customer DVA/customer account top-up/payment evidence and/or matched DVA/card/bank statement line.
7. Funding confirmation RPC that releases available dashboard credit only after funding proof.
8. Customer/order details and sale document UI patches.
9. Importer order list and importer operations page patches.
10. DVA/card reconciliation final-balance-first logic plus loyalty-funding match controls.
11. Supervisor credit readiness gate.
12. Reuse existing future-order credit application machinery after funded loyalty credit is released.
13. Sage/customer-account posting must follow the cash-backed v2 addendum; do not use the v1 reward-approval journal trigger.

The final sale settlement read model is first because customer display, DVA/card classification, supervisor credit readiness, loyalty reward eligibility, and posting controls must all consume one settlement truth.

## Current repo/deploy state

- Active Vercel project: `goodcashback-v2`.
- Production alias: `https://goodcashback-v2.vercel.app`.
- Old project `goodcashback` should not be used for current deployment.
- Manual deploy command from Codespaces: `npx vercel --prod`.
- Codespaces is linked to Vercel project ID `prj_1jwy7mxMlE0IDPH1zDSpmlGjbvdN`.

## Next steps after this doc

1. Confirm the governing documents above are in the repo and aligned.
2. Treat v1 completion-loyalty Sage-at-approval code as superseded for future work.
3. Build the funding-proof / customer DVA top-up confirmation layer before dashboard-credit release.
4. Run SQL simulations against real orders before wiring write actions.
5. Keep `/internal/funding` and `/internal/sage-ready` read-only for new lanes until live function signatures are confirmed.
6. Run `npm run build` locally before deployment where possible.
7. Deploy only after build passes.
8. Then add staff-only action wiring one function at a time.
