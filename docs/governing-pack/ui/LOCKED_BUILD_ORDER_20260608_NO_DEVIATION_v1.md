# Locked Build Order — 2026-06-08 — No Deviation v1

Status: Active build-control note.

Purpose: preserve the agreed simplest/lowest-risk build order for the current Final Sale / Completion Loyalty / Main Bank / Operational Status contract set, so later work does not drift into unnecessary patches or broad refactors.

This note sits under the governing pack and must be checked before starting the next build in this sequence.

## 0) Explicitly excluded for now

Leave the shipper partial-payment patch out.

Reason: the business does not intend to partially pay a shipper invoice in the current process.

Do not build a shipper AP partial-payment UI patch unless later evidence proves it is needed and the change is impact-checked upstream and downstream.

Non-negotiables:

- Do not alter `staff_allocate_main_bank_line_to_shipper_ap_v1(...)`.
- Do not alter `main_bank_shipper_ap_allocations` for partial-payment experiments.
- Do not alter shipper AP Sage posting.
- Shipper AP regression in this build sequence is full-payment only.

## 1) Prove future-order loyalty credit auto-apply

No code first.

Goal: prove that the released completion-loyalty account credit can fund a new/future order through the existing credit machinery.

Existing machinery to test first:

- `internal_importer_available_account_credit_lots_v1(importer_id)`
- `customer_apply_available_credit_to_order_v1(order_id)`
- customer new-order action auto-apply path

Expected proof:

- New order created for the same importer/customer.
- Available loyalty credit is auto-applied.
- `importer_credit_ledger` gets a debit linked to the source credit lot.
- `order_funding_events` gets `event_type = credit_applied`.
- Customer order page shows account credit applied and lower cash due.

Only patch if this proof fails.

## 2) Prove loyalty + residual split

No code first.

Test A — loyalty + bank fee:

- Main-bank OUT line exceeds loyalty reward amount.
- Loyalty reward is matched/released.
- Remaining amount is allocated as `bank_fee` using existing residual route.
- Main-bank line becomes balanced.
- Cash posting workbench sees the bank-fee residual through the existing path.

Test B — loyalty + FX/card difference:

- Main-bank OUT line exceeds loyalty reward amount.
- Loyalty reward is matched/released.
- Remaining amount is allocated as `fx_card_difference` using existing residual route.
- Main-bank line becomes balanced.
- FX/card residual follows existing downstream residual/posting route.

Only patch if a proof fails.

## 3) Prove shipper AP regression

No partial-payment patch.

Goal: prove that main-bank shipper AP still works after adding completion-loyalty target mode and shared remaining-balance protection.

Proof must use a full-payment shipper AP scenario only.

Expected proof:

- Main-bank OUT line selected.
- Posted shipper AP target selected.
- Existing `staff_allocate_main_bank_line_to_shipper_ap_v1(...)` path succeeds.
- Main-bank line remaining is correct after allocation.
- No loyalty/residual change has damaged shipper AP allocation.

Patch only if full-payment shipper AP regression fails.

## 4) Build Final Sale Balance Due / True Credit

This is the next highest-value actual build.

Purpose: prevent DVA/card reconciliation from misclassifying final-balance payments as overfunding or true credit.

This build covers:

- final balance payment target
- DVA/card final-balance-first matching
- true surplus credit approval
- prevention of final-balance/overfunding misclassification

### 4.1 Add final-balance target read model

Small SQL only.

Suggested function:

- `internal_dva_final_balance_targets_v1(p_search text default null, p_limit integer default 100, p_offset integer default 0)`

Source:

- `internal_order_final_sale_settlement_v1(NULL)`

Target filter:

- `final_balance_due_gbp > 0.01`
- final sale value exists
- customer sale is posted

Return should include at least:

- `order_id`
- `order_ref`
- `importer_id`
- `final_sale_value_gbp`
- `amount_received_gbp`
- `final_balance_due_gbp`
- `target_type = final_balance_payment`

### 4.2 Add final-balance match RPC/action

Small SQL plus one server action.

Suggested function:

- `staff_match_dva_line_to_final_balance_payment_v1(p_dva_statement_line_id uuid, p_order_id uuid, p_amount_gbp numeric, p_notes text default null)`

The function must:

- require active staff/admin/supervisor access as appropriate for DVA/card reconciliation
- lock the DVA/card statement line
- require line direction = `in`
- confirm the statement/importer matches the order/importer
- require amount <= current `final_balance_due_gbp`
- insert `order_funding_events` as a funding contribution using the statement line as source evidence
- re-read settlement state and return before/after final balance due

Do not change accepted-estimate threshold logic.

### 4.3 Add true-surplus credit approval RPC/action

Small SQL plus one supervisor/admin button.

Suggested function:

- `staff_approve_final_sale_surplus_credit_v1(p_order_id uuid, p_approved_amount_gbp numeric, p_reason text default 'settlement_credit', p_notes text default null)`

The function must:

- require active admin/supervisor
- call `internal_order_final_sale_settlement_v1(p_order_id)`
- require `potential_credit_pending_review_gbp > 0`
- require approved amount <= potential pending credit
- insert `importer_credit_ledger` as available credit
- use `source_type = settlement_credit`
- use `source_entity_type = order`
- use `source_entity_id = order_id`
- use `linked_order_id = order_id`
- use `direction = credit`
- use `lock_reason = NULL`

Expected proof after this build:

- final sale value > amount received produces final balance due
- DVA/card final balance payment clears final balance due
- amount received > final sale value produces potential credit pending review
- supervisor approval creates available account credit only for the true surplus

## 5) Run operational status regression

No code first.

Regression cases should cover:

- clean complete order
- final balance due
- potential credit pending review
- credit added to account
- active customer hold
- open exception/dispute
- tracking missing
- tracking/package allocation incomplete
- export evidence missing
- POD missing
- shipper AP pending
- accounting/Sage not ready

Only patch statuses that fail the proof.

## 6) Build shipper hard-block only if chosen

This is a later-control gap, not part of the fastest close unless the business chooses to close it now.

If built, patch only:

- `shipper_shipment_batch_candidates_v1()`
- `shipper_create_shipment_batch_v1(...)`

Required behaviour:

- active customer holds with status `requested` or `supervisor_approved` must exclude/reject held order/tracking/line scope.

Do not redesign the customer review or hold workflow.

## 7) Then accounting closure control

Do not start live posting expansion before closure control.

The next accounting build is read-only closure proof, not new posting expansion.

Expected closure control should later prove, per order/lane:

- customer sales posted/closed
- supplier goods AP posted/closed
- shipper AP posted/closed
- payment allocation state known
- credit/refund/residual/hold state known
- Sage object IDs recorded
- attachment/evidence status known
- no duplicate idempotency keys
- no hidden FX/fee/refund/hold inside another payment

## Build discipline

Before any code change:

1. Check this locked build order.
2. Check the relevant contract/addendum.
3. Inspect the current repo file/RPC/table involved.
4. Prefer proof-first where machinery already exists.
5. Patch only the smallest failing gap.
6. Do not refactor unrelated flows.
7. Confirm deployment readiness before relying on the change.
