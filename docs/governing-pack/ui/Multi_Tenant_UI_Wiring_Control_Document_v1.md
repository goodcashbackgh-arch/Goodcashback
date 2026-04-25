# Multi Tenant Platform Build — UI Wiring Control Document v1

**Purpose:** Use this document at the start of every UI/API wiring chat so the build does not drift from the proven backend, governing architecture, role matrices, and live regression results.

**Current status:** Live backend Day 2–9 regression passed after the live v3→v4 bridge.

**Hard rule:** Do not change backend SQL unless a UI/integration test exposes a real defect. UI must wire to the proven backend contract.

---

## 1. Authority Stack

Use this order when there is conflict:

1. Architecture Completion Addendum v2 — governing business/control architecture.
2. goodcashback-complete.v4.sql — fresh baseline reference.
3. closure_v2_migration_v2.sql — v4 schema migration / additive migration.
4. closure_v2_functions_final_day6_8_clarified.sql — final functions/views/triggers/RLS contract.
5. closure_v2_seed.sql — status/config/rule seed truth.
6. Canonical Schema Reference v1 — schema/control explanation.
7. SAGE Posting Matrix v1 — accounting execution truth.
8. Master End-to-End Orchestration v3 — cross-role lifecycle/handoff truth.
9. Technical Resource Map by Node v2 — implementation resource map.

Supplementary role-flow documents:

10. Importer Role Stage Matrix v7.
11. Supervisor Role Stage Matrix v7.
12. Admin Role Stage Matrix v6.
13. Shipper Role Stage Matrix v5.

Clarification addendums that override older wording where relevant:

14. VAT Timing & Export Evidence Addendum v1.
15. Progressive Commercial Release & Replacement Invoicing Addendum v1.
16. Day 6/8 Accounting Release and VAT Reporting Clarification Addendum v1.

### Conflict rule
If a role matrix adds detail and does not conflict, use it. If it conflicts with the authority stack, the authority stack wins.

---

## 2. Locked Backend Source of Truth

Current locked live upgrade path that passed:

1. live_v3_to_v4_preflight_bridge_v2.sql
2. closure_v2_migration_v2.sql
3. closure_v2_functions_final_day6_8_clarified.sql
4. closure_v2_seed.sql
5. day2_to_day9_final_regression_v5.sql

Current final pack:

- final_locked_backend_pack_v4_day2_to_day9_v3.zip

Do not use older v3 baseline, older final packs, or old Day 6/Day 8 regression files.

---

## 3. Backend Proof Summary

The following areas are proven by live regression:

- Day 2: DVA funding, threshold funding, overfunding credit, importer credit application.
- Day 3: tracking-first, invoice-first, OCR/progressed subset, partial progress, OCR delete protection.
- Day 4: child exceptions, refund gate, replacement child order, replacement linkage, no fresh funding.
- Day 5: shipping handoff, quote confirmation, no no-progressed-subset shipping, no overscoped quote.
- Day 6: accounting release gates, Sage queue contract, idempotency, export evidence checkpoints.
- Day 6/8: VAT reporting uses released sales invoices, main + supplementary included, replacement child does not own VAT workings, Box 1 breach helper.
- Day 7: RLS and portal role-boundary/read-model coverage.
- Day 8: prepayment-first VAT timing, carry-in/carry-out, export deadline breach, progressive invoicing, no VAT duplication.
- Day 9: uniqueness guards, trigger coverage, function contracts, RLS still active, VAT and progressive-release contracts active.

---

## 4. Non-Negotiable Business Rules

1. Funding delay must not block real evidence capture or genuine operational progression.
2. Funding delay does block final financial/control closure.
3. Stable progressed subset can be invoiced even if other child exceptions remain open.
4. Open child exceptions block final whole-order closure, not stable subset release.
5. Shipper only handles progressed shipment-ready scope.
6. Shipper cannot act on draft quotes.
7. Shipping quote confirmation must be blocked if there is no progressed subset.
8. Unresolved child value must not be included in shipment scope.
9. Refund path is blocked until supervisor/admin approval.
10. Replacement child is operational tracking, not a new funded customer order.
11. Replacement child does not own customer invoice or VAT workings.
12. Late replacement item can become a supplementary invoice on the parent order if it was not included in the first invoice.
13. VAT timing is prepayment-first for known quoted goods.
14. VAT reporting uses released sales invoices, not whole order totals.
15. Main and supplementary invoices can both feed Box 6.
16. On-track exports can be reported before final evidence clearance if within deadline.
17. If export/evidence deadline is breached, Box 1 adjustment is needed in the breach period.
18. Sage posting is queue-driven only; no browser direct-to-Sage posting.
19. Idempotency keys must prevent duplicate Sage postings.
20. Portal access must obey RLS and role boundaries.

---

## 5. Actor Boundaries

### Importer
Does:
- create orders;
- upload screenshots;
- submit tracking and invoice evidence in either order;
- operate OCR reconciliation workspace;
- edit OCR line commercial fields;
- add/delete manual lines;
- mark clean lines progressed;
- select refund/replacement remedy;
- use AI-generated retailer drafts and paste replies;
- track shipment and confirm receipt/raise issue.

Does not:
- upload DVA statements;
- reconcile funding;
- apply credit internally;
- approve refunds;
- delete OCR source lines;
- perform shipper booking/evidence actions.

### Supervisor
Does:
- handle routine funding/DVA reconciliation;
- apply importer credit;
- monitor evidence and OCR;
- approve routine refund path;
- preserve ready-for-shipment handoff;
- create/confirm shipping quote;
- oversee accounting/VAT readiness.

Does not:
- create importer orders normally;
- upload importer evidence normally;
- bypass refund gate;
- convert unresolved child exceptions into false clearance;
- block evidence just because funding is late.

### Admin
Does:
- own governance/escalation;
- approve high-risk overrides;
- govern VAT/accounting release;
- control historical audit/reopen;
- handle non-routine liability/credit/payout decisions.

Does not:
- act as routine queue operator unless needed;
- use missing funding match to freeze real evidence/progression.

### Shipper
Does:
- see only confirmed shipper-lane work;
- use tracking context;
- book shipment after quote confirmation;
- mark hub receipt/dispatch/in transit/Ghana delivery;
- upload BOL/certificate/commercial invoice/POD;
- respond to shipper-side disputes.

Does not:
- create orders;
- touch funding;
- edit OCR;
- approve refunds;
- see unresolved child value as shippable;
- act on draft quotes.

---

## 6. UI Build Order

Build thin, working screens first. Do not optimise visuals before the workflow is correct.

1. Internal staff dashboard shell.
2. Funding queue.
3. Evidence/OCR queue.
4. Child exceptions/refund/replacement queue.
5. Shipping handoff queue.
6. Accounting/VAT release queue.
7. Shipper portal.
8. Importer portal.
9. AI retailer draft integration.
10. Mindee OCR integration.
11. Sage queue worker/adapter.
12. Demo data and final QA.

Rationale: internal staff screens control the handoffs. If these are wrong, importer and shipper portals will drift.

---

## 7. UI Contract Map

### /internal — Staff dashboard shell
Actor: supervisor/admin.
Reads: order_state_vw, admin_escalation_queue_vw, order_funding_position_vw, vat_sales_invoice_reporting_vw, sage_postings.
Actions: none initially.
Purpose: queue counts and navigation.
Cards: funding, evidence/OCR, exceptions, shipping, accounting/VAT, escalations.

### /internal/funding — Funding queue
Actor: supervisor/admin.
Reads: day2_dva_review_worklist_vw, order_funding_position_vw, importer_balance_vw, order_funding_events, dva_statement_lines, dva_reconciliation.
Writes/functions: confirm_reconciliation_to_order, accept_order_match_suggestion_and_reconcile, apply_importer_credit_to_order.
Buttons: match DVA line, apply credit, escalate, view funding history.
Disable when: wrong importer, wrong auth, line already used, order already funded, credit unavailable, replacement_child target.

### /internal/evidence — Evidence/OCR queue
Actor: supervisor/admin review; importer is normal uploader/editor.
Reads: order_state_vw, supplier_invoices, supplier_invoice_lines, order_tracking_submissions, order_reconciliation_vw.
Actions: view invoice, view tracking, view OCR, view progressed subset, query importer.
Rules: OCR source lines editable but not deletable; manual lines deletable; partial progress must not clear parent.

### /internal/exceptions — Child exception queue
Actor: supervisor/admin.
Reads: disputes, dispute_lines, dispute_messages, admin_escalation_queue_vw, order_state_vw.
Writes/functions: approve refund gate, reject/query refund, create_replacement_child_order.
Buttons: approve refund path, create replacement child, view AI trail, escalate.
Disable when: refund not approved, replacement already exists, replacement-of-replacement attempted, dispute line not linked to parent.

### /internal/shipping — Shipping handoff queue
Actor: supervisor.
Reads: order_reconciliation_vw, order_state_vw, shipping_quotes, shipping_quote_orders, order_tracking_submissions.
Writes/functions: mark_shipping_quote_confirmed_ready_for_booking.
Buttons: create draft quote, confirm ready for booking, view progressed subset, view unresolved child value.
Disable when: no progressed subset, quote includes unresolved child value, overscoped quote, draft not confirmed.

### /shipper — Shipper portal
Actor: shipper user.
Reads: shipping_quotes, shipping_quote_orders, order_tracking_submissions, order_state_vw, shipper-side disputes.
Writes: booking_ref, hub received, dispatched, evidence uploads, Ghana delivered, POD, shipper dispute response.
Rules: shipper only sees their lane and only progressed shipment-ready work.

### /internal/accounting-vat — Accounting/VAT release queue
Actor: admin/finance supervisor.
Reads: sales_invoices, sage_postings, vat_sales_invoice_reporting_vw, vat_return_workings, vat_return_adjustments, export_deadline_breach_report_vw.
Writes/functions: release_sales_invoice_for_order_subset, post_to_vat_return_workings, post_to_vat_return_workings_for_period, queue Sage posting, mark zero-rating evidence checkpoint.
Rules: stable subset can invoice; late replacement supplementary invoice on parent; VAT timing prepayment-first; released invoices drive Box 6; breach creates Box 1 adjustment.

### /importer/orders and child pages — Importer portal
Actor: importer/operator.
Reads: own orders, own evidence, own invoice lines, own disputes, own shipment status, own credit balance.
Writes: create order, upload screenshots, submit tracking, upload invoice, edit OCR line fields, add/delete manual lines, mark progressed, select remedy, paste retailer reply, confirm receipt/raise issue.
Rules: importer cannot access other importers; cannot delete OCR source lines; cannot bypass refund gate.

---

## 8. Clean Business Flow Simulations

### Smooth path
Importer creates order, pays/prepays, uploads invoice/tracking, OCR matches all lines, supervisor reconciles funding, supervisor confirms shipping handoff, shipper books/dispatches, evidence arrives, Sage queue/VAT reporting proceed.

### Tracking first
Importer submits courier/tracking before invoice. System accepts it. Invoice arrives later and starts OCR. Funding delay does not block evidence.

### Invoice first
Importer uploads invoice before tracking. OCR/reconciliation can start. Tracking can arrive later for shipper awareness.

### Partial progress
Five items ordered, four progress, one missing. Four can ship/invoice when stable. One becomes child exception. Parent not fully closed until child outcome resolves.

### Refund exception
Importer chooses refund. Refund communication remains blocked until supervisor/admin approval. After approval, retailer communication can proceed.

### Replacement exception
Replacement child order tracks the item. It has no fresh customer funding and does not own customer invoice/VAT workings. If the first invoice covered only the four stable items, the late replacement can be supplementary invoice on the parent order.

### Overfunding
Customer pays more than order gap. Gap funds order; excess becomes importer credit. Credit can be applied later under control.

### VAT timing
Known quoted goods paid in advance: VAT timing is the prepayment date. Released sales invoices drive Box 6. Evidence supports zero-rating. If evidence/export deadline breaches, Box 1 adjustment is reported in breach period.

---

## 9. API / Server Action Rules

Use server actions/API routes for writes. Do not write complex business transitions directly from UI components.

Preferred approach:
- UI reads from views and scoped tables.
- UI writes through functions or narrowly controlled server actions.
- Every action returns clear success/error state.
- Disable buttons based on backend state, not just frontend assumptions.
- For financial/accounting/VAT actions, write queue/intention rows first; process external integrations separately.

Never:
- post directly to Sage from browser;
- trust UI-only validation for funding, refunds, VAT, replacement, or shipping scope;
- let shipper see unresolved child value as shippable;
- let replacement child create its own customer invoice;
- duplicate VAT Box 6 on final invoice after prepayment reporting.

---

## 10. Definition of Done for Each UI Page

A page is done only when:

1. It reads from the correct backend object.
2. It shows the correct status/state labels.
3. It disables invalid actions.
4. It calls the correct function/server action.
5. It handles the first backend error clearly.
6. It respects actor/RLS boundaries.
7. It is checked against the relevant smoke-test proof.
8. It does not introduce raw-table shortcuts where a function/view exists.

---

## 11. Do-Not-Drift Checklist for Future Chats

At the start of any future UI/API build chat, paste this section:

- We are building against live backend passed by day2_to_day9_final_regression_v5.sql.
- Final functions file: closure_v2_functions_final_day6_8_clarified.sql.
- Do not change backend SQL unless a UI/integration test exposes a real defect.
- Use the authority stack and role matrices listed in this document.
- Stable subset invoicing is allowed; final whole-order closure waits for unresolved children.
- VAT is prepayment-first and sales-invoice based; not dispatch-only.
- Replacement child is operational tracking, not a new customer-funded order.
- Shipper only acts on confirmed progressed shipment-ready scope.
- Sage is queue-driven and idempotent.

---

## 12. Immediate Next Task

Build `/internal` staff dashboard shell first.

Initial cards:
- Funding queue
- Evidence/OCR queue
- Child exceptions
- Shipping handoff
- Accounting/VAT
- Admin escalations

Do not build final styling first. Build thin, correct, role-safe screens.
